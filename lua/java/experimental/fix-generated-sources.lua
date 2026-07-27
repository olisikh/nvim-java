local path_utils = require('java-core.utils.path')
local log = require('java-core.utils.log2')

local M = {}

local POM_MARKER = '<!-- nvim-java: generated sources -->'

---Normalize path separators to `/` for .classpath operations.
---Eclipse .classpath files always use `/` regardless of OS.
---@param p string
---@return string
local function classpath_normalize(p)
	return p:gsub('\\', '/')
end

---Set or update the `excluding` attribute on a classpathentry line.
---Parses any existing exclusions, merges with the new set (union),
---and writes the sorted result back.
---@param line string
---@param exclusions string[]
---@return string
local function set_exclusions(line, exclusions)
	-- Parse existing exclusions from the line
	local existing = {}
	local existing_match = line:match('excluding="([^"]+)"')
	if existing_match then
		for entry in existing_match:gmatch('[^|]+') do
			existing[entry] = true
		end
	end

	-- Merge: union existing + new (new keys take no precedence — it's a set union)
	local merged = vim.deepcopy(existing)
	for _, excl in ipairs(exclusions) do
		merged[excl] = true
	end

	local merged_list = vim.tbl_keys(merged)
	table.sort(merged_list)
	local exclusion_value = table.concat(merged_list, '|')

	if existing_match then
		return line:gsub('excluding="[^"]+"', 'excluding="' .. exclusion_value .. '"', 1)
	end

	return line:gsub('<classpathentry ', '<classpathentry excluding="' .. exclusion_value .. '" ', 1)
end

---Get the relative path from root. Result is normalized to `/`
---for .classpath compatibility.
---@param root string
---@param absolute_path string
---@return string
local function get_relative_path(root, absolute_path)
	-- vim.fs.find always joins children with '/' regardless of OS, so
	-- normalize both sides before stripping the prefix.
	local normalized_root = classpath_normalize(root)
	local normalized_path = classpath_normalize(absolute_path)
	local prefix = normalized_root .. '/'
	if normalized_path:sub(1, #prefix) == prefix then
		return normalized_path:sub(#prefix + 1)
	end
	return normalized_path
end

---@param lines string[]
---@param entry_path string
---@return boolean
local function has_classpath_entry(lines, entry_path)
	local pattern = 'path="' .. entry_path .. '"'
	for _, line in ipairs(lines) do
		if line:find(pattern, 1, true) then
			return true
		end
	end
	return false
end

---Find the index of the target/generated-sources classpathentry.
---Assumes .classpath uses double or single quotes and one tag per line.
---@param lines string[]
---@return integer|nil
local function find_generated_sources_entry(lines)
	for index, line in ipairs(lines) do
		if line:find('path="target/generated%-sources"') or line:find("path='target/generated%-sources'") then
			return index
		end
	end
	return nil
end

---Insert a new classpathentry before the <classpathentry kind="output"> line.
---@param lines string[]
---@param entry_path string
local function add_classpath_entry(lines, entry_path)
	local entry = {
		'\t<classpathentry kind="src" output="target/classes" path="' .. entry_path .. '">',
		'\t\t<attributes>',
		'\t\t\t<attribute name="optional" value="true"/>',
		'\t\t\t<attribute name="maven.pomderived" value="true"/>',
		'\t\t</attributes>',
		'\t</classpathentry>',
	}

	local output_index = #lines + 1
	for index, line in ipairs(lines) do
		if line:find('<classpathentry kind="output"') then
			output_index = index
			break
		end
	end

	for offset = #entry, 1, -1 do
		table.insert(lines, output_index, entry[offset])
	end
end

---Find generated source roots under target/generated-sources that
---match the pattern `*/src/{segment}/java`.
---@param module_root string
---@return string[]
local function get_generated_source_roots(module_root)
	local generated_root = path_utils.join(module_root, 'target', 'generated-sources')
	if not vim.uv.fs_stat(generated_root) then
		return {}
	end

	-- vim.fs.find always yields '/'-separated paths regardless of OS, so
	-- match against a '/'-normalized substring even on Windows.
	local target_gen_src = 'target/generated-sources'
	local java_roots = vim.fs.find(function(name, generated_path)
		return name == 'java' and classpath_normalize(generated_path):find(target_gen_src, 1, true) ~= nil
	end, {
		path = generated_root,
		type = 'directory',
		limit = 500,
	})

	local source_roots = {}
	local seen_roots = {}
	for _, java_root in ipairs(java_roots) do
		local relative_to_generated_root = get_relative_path(generated_root, java_root)
		-- Split on / since get_relative_path normalizes
		local segments = vim.split(relative_to_generated_root, '/', { plain = true })
		local segment_count = #segments

		if segment_count >= 3 and segments[segment_count] == 'java' and segments[segment_count - 2] == 'src' then
			local source_root = get_relative_path(module_root, java_root)
			if not seen_roots[source_root] then
				seen_roots[source_root] = true
				table.insert(source_roots, source_root)
			end
		end
	end

	table.sort(source_roots)
	return source_roots
end

---Add generated source roots to Maven when a generator does not expose them
---to m2e/JDTLS. JDTLS recreates the Eclipse classpath during Maven import, so
---this must be expressed in pom.xml rather than only patched in .classpath.
---@param module_root string
---@param source_roots string[]
---@return boolean changed
local function add_maven_source_roots(module_root, source_roots)
	if #source_roots == 0 then
		return false
	end

	local pom_file = path_utils.join(module_root, 'pom.xml')
	if not vim.uv.fs_stat(pom_file) then
		return false
	end

	local pom_lines = vim.fn.readfile(pom_file)
	local pom = table.concat(pom_lines, '\n')
	if pom:find(POM_MARKER, 1, true) then
		return false
	end

	---@param lines string[]
	---@param line_index integer
	---@param new_lines string[]
	local function insert_lines(lines, line_index, new_lines)
		for index = #new_lines, 1, -1 do
			table.insert(lines, line_index, new_lines[index])
		end
	end

	---@param lines string[]
	---@param closing_index integer
	---@param parent_indent string
	---@return string
	local function get_indent_unit(lines, closing_index, parent_indent)
		for index = closing_index - 1, 1, -1 do
			local child_indent = lines[index]:match('^(%s*)<plugin>')
			if child_indent and child_indent:sub(1, #parent_indent) == parent_indent then
				local unit = child_indent:sub(#parent_indent + 1)
				if unit ~= '' then
					return unit
				end
			end
		end

		if parent_indent:find('\t', 1, true) then
			return '\t'
		end
		return '    '
	end

	---@param plugin_indent string
	---@param indent_unit string
	---@return string[]
	local function make_plugin(plugin_indent, indent_unit)
		local plugin_field_indent = plugin_indent .. indent_unit
		local execution_indent = plugin_field_indent .. indent_unit
		local execution_field_indent = execution_indent .. indent_unit
		local source_indent = execution_field_indent .. indent_unit
		local source_value_indent = source_indent .. indent_unit

		local lines = {
			'',
			plugin_indent .. POM_MARKER,
			plugin_indent .. '<plugin>',
			plugin_field_indent .. '<groupId>org.codehaus.mojo</groupId>',
			plugin_field_indent .. '<artifactId>build-helper-maven-plugin</artifactId>',
			plugin_field_indent .. '<version>3.6.0</version>',
			plugin_field_indent .. '<executions>',
			execution_indent .. '<execution>',
			execution_field_indent .. '<id>nvim-java-generated-sources</id>',
			execution_field_indent .. '<phase>generate-sources</phase>',
			execution_field_indent .. '<goals>',
			source_indent .. '<goal>add-source</goal>',
			execution_field_indent .. '</goals>',
			execution_field_indent .. '<configuration>',
			source_indent .. '<sources>',
		}

		for _, source_root in ipairs(source_roots) do
			table.insert(lines, source_value_indent .. '<source>${project.basedir}/' .. source_root .. '</source>')
		end

		vim.list_extend(lines, {
			source_indent .. '</sources>',
			execution_field_indent .. '</configuration>',
			execution_indent .. '</execution>',
			plugin_field_indent .. '</executions>',
			plugin_indent .. '</plugin>',
		})
		return lines
	end

	local changed = false
	for index, line in ipairs(pom_lines) do
		local plugins_indent = line:match('^(%s*)</plugins>%s*$')
		if plugins_indent then
			local indent_unit = get_indent_unit(pom_lines, index, plugins_indent)
			insert_lines(pom_lines, index, make_plugin(plugins_indent .. indent_unit, indent_unit))
			changed = true
			break
		end
	end

	if not changed then
		for index, line in ipairs(pom_lines) do
			local build_indent = line:match('^(%s*)</build>%s*$')
			if build_indent then
				local indent_unit = get_indent_unit(pom_lines, index, build_indent)
				local plugins_indent = build_indent .. indent_unit
				local build_plugins = { plugins_indent .. '<plugins>' }
				vim.list_extend(build_plugins, make_plugin(plugins_indent .. indent_unit, indent_unit))
				table.insert(build_plugins, plugins_indent .. '</plugins>')
				insert_lines(pom_lines, index, build_plugins)
				changed = true
				break
			end
		end
	end

	if not changed then
		for index, line in ipairs(pom_lines) do
			local project_indent = line:match('^(%s*)</project>%s*$')
			if project_indent then
				local indent_unit = '    '
				local build_indent = project_indent .. indent_unit
				local plugins_indent = build_indent .. indent_unit
				local build = { build_indent .. '<build>', plugins_indent .. '<plugins>' }
				vim.list_extend(build, make_plugin(plugins_indent .. indent_unit, indent_unit))
				vim.list_extend(build, { plugins_indent .. '</plugins>', build_indent .. '</build>' })
				insert_lines(pom_lines, index, build)
				changed = true
				break
			end
		end
	end

	if not changed then
		return false
	end

	vim.fn.writefile(pom_lines, pom_file)
	log.info('nvim-java: adding generated sources to Maven project', pom_file)
	return true
end

---Build exclusion list for the parent target/generated-sources entry.
---Always seeds `annotations/` — Eclipse/Maven convention excludes the
---annotations subdirectory from generated-sources to avoid processing
---compiled annotation processor output as source.
---@param source_roots string[]
---@return string[]
local function get_generated_source_exclusions(source_roots)
	local exclusions = { ['annotations/'] = true }
	-- Normalize prefix to / for comparison with source_roots (which are /-normalized)
	local generated_root_prefix = classpath_normalize(path_utils.join('target', 'generated-sources')) .. '/'

	for _, source_root in ipairs(source_roots) do
		if source_root:sub(1, #generated_root_prefix) == generated_root_prefix then
			local relative_to_generated_root = source_root:sub(#generated_root_prefix + 1)
			local first_segment = vim.split(relative_to_generated_root, '/', { plain = true })[1]
			if first_segment then
				exclusions[first_segment .. '/'] = true
			end
		end
	end

	local ordered_exclusions = vim.tbl_keys(exclusions)
	table.sort(ordered_exclusions)
	return ordered_exclusions
end

---Patch a single .classpath file to include generated source roots
---and exclude them from the parent generated-sources entry.
---Safe to re-run — idempotent (has_classpath_entry + set_exclusions
---no-op when already applied).
---@param classpath_file string
---@return boolean changed
local function patch_module_classpath(classpath_file)
	local module_root = vim.fs.dirname(classpath_file)
	local lines = vim.fn.readfile(classpath_file)
	local generated_sources_entry_index = find_generated_sources_entry(lines)
	if not generated_sources_entry_index then
		return false
	end

	local file_changed = false
	local source_roots = get_generated_source_roots(module_root)
	local line = lines[generated_sources_entry_index]
	local patched = set_exclusions(line, get_generated_source_exclusions(source_roots))

	if patched ~= line then
		lines[generated_sources_entry_index] = patched
		file_changed = true
	end

	for _, source_root in ipairs(source_roots) do
		if not has_classpath_entry(lines, source_root) then
			add_classpath_entry(lines, source_root)
			file_changed = true
		end
	end

	if file_changed then
		log.info('nvim-java: patching .classpath with generated sources', classpath_file)
		vim.fn.writefile(lines, classpath_file)
	end

	return file_changed
end

---Patch a Maven module whose Eclipse metadata has not yet been generated.
---@param pom_file string
---@return boolean changed
local function patch_module_pom(pom_file)
	local module_root = vim.fs.dirname(pom_file)
	local classpath_file = path_utils.join(module_root, '.classpath')
	if vim.uv.fs_stat(classpath_file) then
		local lines = vim.fn.readfile(classpath_file)
		if find_generated_sources_entry(lines) then
			return false
		end
	end

	return add_maven_source_roots(module_root, get_generated_source_roots(module_root))
end

---Patch all .classpath files under `root` to include generated source roots.
---This is an experimental workaround for JDTLS import failures caused by
---nested generated sources under target/generated-sources.
---@param root string # Project root directory
---@return boolean changed # true if any .classpath file was modified
function M.patch(root)
	local changed = false
	local start = vim.uv.hrtime()
	local count = 0
	local LIMIT = 500

	for _, file in ipairs(vim.fs.find('.classpath', { path = root, type = 'file', limit = LIMIT })) do
		if patch_module_classpath(file) then
			changed = true
		end
		count = count + 1
	end

	for _, file in ipairs(vim.fs.find('pom.xml', { path = root, type = 'file', limit = LIMIT })) do
		if patch_module_pom(file) then
			changed = true
		end
	end

	if count >= LIMIT then
		log.warn(
			'nvim-java: fix_generated_sources hit .classpath find limit (' .. LIMIT .. ') — some files may be missed'
		)
	end

	local elapsed = (vim.uv.hrtime() - start) / 1e6
	log.debug(('nvim-java: fix_generated_sources scanned %d .classpath files in %.2fms'):format(count, elapsed))

	return changed
end

return M

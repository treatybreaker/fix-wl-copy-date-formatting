local opts = require("silicon.config").opts
local Job = require("plenary.job")
local fmt = string.format

local request = {}

local utils = {}

utils.os_capture = function(cmd, raw)
	local f = assert(io.popen(cmd, "r"))
	local s = assert(f:read("*a"))
	f:close()
	if raw then
		return s
	end
	s = string.gsub(s, "^%s+", "")
	s = string.gsub(s, "%s+$", "")
	s = string.gsub(s, "[\n\r]+", " ")
	return s
end

local config_dir = string.match(utils.os_capture("silicon --config-file"), "^(.*[\\\\/])")
local themes_path = config_dir .. "/themes"
local syntaxes_path = config_dir .. "/syntaxes"

utils.installed_colorschemes = function()
	return vim.fn.readdir(themes_path)
end

--- Check if a file or directory exists in this path
---@param file string path of file or directory
utils.exists = function(file)
	local ok, err, code = os.rename(file, file)
	if not ok then
		if code == 13 then
			-- Permission denied, but it exists
			return true
		end
	end
	return ok, err
end

utils.build_tmTheme = function()
	local tmTheme = require("silicon.build_tmTheme")()
	local file = fmt("%s/%s.tmTheme", themes_path, vim.g.colors_name)
	os.execute(fmt("touch %s", file))
	local theme = io.open(file, "w+")
	theme:write(tmTheme)
	theme:close()
end

utils.replace_placeholders = function(str)
	return str:gsub("${time}", fmt("%s:%s", os.date("%H"), os.date("%M")))
		:gsub("${year}", os.date("%Y"))
		:gsub("${month}", os.date("%m"))
		:gsub("${date}", os.date("%d"))
end

request.exec = function(show_buffer, copy_to_board, debug)
	local starting, ending = vim.api.nvim_buf_get_mark(0, "<")[1] - 1, vim.api.nvim_buf_get_mark(0, ">")[1]

	local lines = vim.api.nvim_buf_get_lines(0, starting, ending, true)

	if show_buffer then
		lines = vim.api.nvim_buf_get_lines(0, 0, -1, true)
	end

	if opts.gobble == true then
		local whitespace = nil
		local current_whitespace = nil
		-- Get least leading whitespace
		for idx = 1, #lines do
			lines[idx] = lines[idx]:gsub("\t", string.rep(" ", vim.bo.tabstop))
			current_whitespace = string.len(string.match(lines[idx], "^[\r\n\t\f\v ]*") or "")
			whitespace = current_whitespace < (whitespace or current_whitespace + 1) and current_whitespace
				or whitespace
			print(vim.inspect(fmt("CURRENT %s GLOBAL %s", current_whitespace, whitespace)))
		end
		-- Now remove whitespace
		for idx = 1, #lines do
			lines[idx] = lines[idx]:gsub(string.rep(" ", whitespace), "")
		end
	end

	local textCode = table.concat(lines, "\n")

  local default_themes = {
"1337",
"Coldark-Cold",
"Coldark-Dark",
"DarkNeon",
"Dracula",
"GitHub",
"Monokai Extended",
"Monokai Extended Bright",
"Monokai Extended Light",
"Monokai Extended Origin",
"Nord",
"OneHalfDark",
"OneHalfLight",
"Solarized (dark)",
"Solarized (light)",
"Sublime Snazzy",
"TwoDark",
"Visual Studio Dark+",
"ansi",
"base16",
"base16-256"}

	if string.lower(opts.theme) == "auto" or not(vim.tbl_contains(default_themes, opts.theme)) then
		if utils.os_capture("silicon --version") ~= "silicon 0.5.1" then
			vim.notify("silicon v0.5.1 is required for automagically creating theme", vim.log.levels.ERROR)
			return
		end
		opts.theme = vim.g.colors_name
		if utils.exists(themes_path) ~= true then
			os.execute(fmt("mkdir -p %s %s", themes_path, syntaxes_path))
		end
		if vim.tbl_contains(utils.installed_colorschemes(), fmt("%s.tmTheme", opts.theme)) then
			goto skip_build
		end
		utils.build_tmTheme()
		Job:new({
			command = "silicon",
			args = { "--build-cache" },
			cwd = config_dir,
			on_stderr = function(_, data, ...)
				if debug then
					print(vim.inspect(data))
				end
			end,
		}):sync()
	end

	::skip_build::

	opts.output = utils.replace_placeholders(opts.output)
	if #textCode ~= 0 then
		local args = {
			"--font",
			opts.font,
			"--language",
			vim.bo.filetype,
			"--line-offset",
			opts.lineOffset,
			"--line-pad",
			opts.linePad,
			"--pad-horiz",
			opts.padHoriz,
			"--pad-vert",
			opts.padVert,
			"--shadow-blur-radius",
			opts.shadowBlurRadius,
			"--shadow-color",
			opts.shadowColor,
			"--shadow-offset-x",
			opts.shadowOffsetX,
			"--shadow-offset-y",
			opts.shadowOffsetY,
			"--theme",
			opts.theme,
		}
		if not opts.roundCorner then
			table.insert(args, "--no-round-corner")
		end
		if not opts.lineNumber then
			table.insert(args, "--no-line-number")
		end
		if not opts.windowControls then
			table.insert(args, "--no-window-controls")
		end
		if #opts.bgImage ~= 0 then
			table.insert(args, "--background-image")
			table.insert(args, opts.bgImage)
		else
			table.insert(args, "--background")
			table.insert(args, opts.bgColor)
		end
		if show_buffer then
			table.insert(args, "--highlight-lines")
			table.insert(args, fmt("%s-%s", starting + 1, ending))
		end
		if copy_to_board and vim.fn.executable("wl-copy") == 0 then
			table.insert(args, "--to-clipboard")
		elseif vim.fn.executable("wl-copy") == 1 and copy_to_board then
			-- Save output to /tmp then copy from there
			table.insert(args, "--output")
			opts.output = utils.replace_placeholders("/tmp/SILICON_${year}-${month}-${date}_${time}.png")
			table.insert(args, opts.output)
		else
			table.insert(args, "--output")
			table.insert(args, opts.output)
		end
		local job = Job:new({
			command = "silicon",
			args = args,
			on_exit = function(_, code, ...)
				if code == 0 then
					local msg = ""
					if copy_to_board then
						msg = "Snapped to clipboard"
						vim.defer_fn(function()
							if vim.fn.executable("wl-copy") == 1 then
								vim.api.nvim_exec(fmt("silent !cat %s | wl-copy", opts.output), false)
							end
						end, 0)
					else
						msg = string.format("Snap saved to %s", opts.output)
					end
					vim.defer_fn(function()
						vim.notify(msg, vim.log.levels.INFO, { plugin = "silicon.lua" })
					end, 0)
				else
					vim.defer_fn(function()
						vim.notify(
							"Some error occured while executing silicon",
							vim.log.levels.ERROR,
							{ plugin = "silicon.lua" }
						)
					end, 0)
				end
			end,
			on_stderr = function(_, data, ...)
				if debug then
					print(vim.inspect(data))
				end
			end,
			writer = textCode,
			cwd = vim.fn.getcwd(),
		})
		job:sync()
	else
		vim.notify("Please select code snippet in visual mode first!", vim.log.levels.WARN)
	end
end

return request

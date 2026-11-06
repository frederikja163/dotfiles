-- What to launch: which program a project builds, and how its launchSettings.json
-- says to run it. Everything here is about files and MSBuild, nothing about a
-- debugger, which is why it is not in ide.debug -- and why a test of it can load
-- it without loading a plugin.
--
-- The program to run is asked of MSBuild -- `dotnet msbuild -getProperty:TargetPath`
-- -- and not guessed from bin/Debug/<framework>/<name>.dll, which is wrong as soon as
-- a project sets its AssemblyName or OutputPath, and takes a third of a second to
-- ask. A project that targets several frameworks has no TargetPath until it is told
-- one; the highest that runs here is used.
--
-- Properties/launchSettings.json is where a web project says what it runs with, and
-- leaving it out is why an application starts under a debugger and fails to find its
-- configuration. The first profile that runs the project (commandName "Project") is
-- the default, which is what `dotnet run` does, and a profile can be asked for by
-- name. Its environment variables, command line and working directory are used, and
-- its applicationUrl becomes ASPNETCORE_URLS. launchBrowser and the rest of what
-- Visual Studio does with a profile are not.
--
-- The profiles keep the order they were written in, which Neovim's decoder loses
-- and which is what "first" means, so the keys are read from the text. A byte
-- order mark is taken off. Comments and trailing commas, which .NET allows and
-- Neovim's decoder refuses, are not handled: Visual Studio and Rider write neither,
-- and a file with them is reported as not valid JSON and launched without a profile.
-- Stripping them correctly (never from inside a string: "http://localhost" has two
-- slashes that are not a comment) was about seventy lines, and was cut as not worth
-- them.

local dotnet = require('ide.dotnet')

local M = {}

-- The end of the string whose opening quote is at `i`.
local function string_end(text, i)
    local j = i + 1
    while j <= #text do
        local c = text:sub(j, j)
        if c == '\\' then
            j = j + 2
        elseif c == '"' then
            return j
        else
            j = j + 1
        end
    end
    return #text
end

-- The keys of the object whose `{` is at `open`, in the order they are written.
local function key_names(text, open)
    local keys, depth, i = {}, 1, open + 1
    local expecting_key = true
    while i <= #text and depth > 0 do
        local c = text:sub(i, i)
        if c == '"' then
            local close = string_end(text, i)
            if depth == 1 and expecting_key then
                local ok, key = pcall(vim.json.decode, text:sub(i, close))
                keys[#keys + 1] = ok and key or text:sub(i + 1, close - 1)
                expecting_key = false
            end
            i = close
        elseif c == '{' or c == '[' then
            depth = depth + 1
        elseif c == '}' or c == ']' then
            depth = depth - 1
        elseif c == ',' and depth == 1 then
            expecting_key = true
        end
        i = i + 1
    end
    return keys
end

--- The launch profiles in a launchSettings.json, in the order written.
---@param text string
---@return { name: string, profile: table }[]? list  nil if it is not JSON at all
---@return string? err
function M.parse_profiles(text)
    local cleaned = text:gsub('^\239\187\191', '')
    local ok, decoded = pcall(vim.json.decode, cleaned)
    if not ok or type(decoded) ~= 'table' then
        return nil, 'launchSettings.json is not valid JSON (comments and trailing commas are not read)'
    end
    local profiles = decoded.profiles
    if type(profiles) ~= 'table' then
        return {}
    end
    local open = select(2, cleaned:find('"profiles"%s*:%s*{'))
    local order = open and key_names(cleaned, open) or vim.tbl_keys(profiles)
    local list = {}
    for _, name in ipairs(order) do
        if type(profiles[name]) == 'table' then
            list[#list + 1] = { name = name, profile = profiles[name] }
        end
    end
    return list
end

--- The profile to use: the one asked for by name, else the first that runs the
--- project. nil with no reason means there is none to use, which is not an error.
---@param list { name: string, profile: table }[]
---@param wanted? string
---@return { name: string, profile: table }? entry
---@return string? err
function M.choose_profile(list, wanted)
    if wanted and wanted ~= '' then
        for _, entry in ipairs(list) do
            if entry.name == wanted then
                return entry
            end
        end
        local names = vim.tbl_map(function(entry) return entry.name end, list)
        return nil, ('No launch profile called %s (there is %s)'):format(wanted, #names > 0 and table.concat(names, ', ') or 'none')
    end
    for _, entry in ipairs(list) do
        if entry.profile.commandName == 'Project' then
            return entry
        end
    end
end

--- What a profile sets for the program: its environment, its arguments and the
--- directory it runs in.
---@param entry { name: string, profile: table }
---@param project_dir string
---@return { env: table<string,string>, args: string[], cwd: string }
function M.launch_options(entry, project_dir)
    local profile = entry.profile
    local env = {}
    if type(profile.environmentVariables) == 'table' then
        for key, value in pairs(profile.environmentVariables) do
            env[key] = tostring(value)
        end
    end
    -- Set by `dotnet run` too, which is how a program can tell what it was started with.
    env.DOTNET_LAUNCH_PROFILE = env.DOTNET_LAUNCH_PROFILE or entry.name
    if type(profile.applicationUrl) == 'string' and profile.applicationUrl ~= '' and env.ASPNETCORE_URLS == nil then
        env.ASPNETCORE_URLS = profile.applicationUrl
    end
    local args = type(profile.commandLineArgs) == 'string' and dotnet.split_args(profile.commandLineArgs) or {}
    local cwd = project_dir
    if type(profile.workingDirectory) == 'string' and profile.workingDirectory ~= '' then
        local dir = profile.workingDirectory
        cwd = dir:sub(1, 1) == '/' and dir or vim.fs.joinpath(project_dir, dir)
    end
    return { env = env, args = args, cwd = vim.fs.normalize(cwd) }
end

----------------------------------------------------------------------------
-- What to run
----------------------------------------------------------------------------

--- The properties in what `dotnet msbuild -getProperty` printed, which is a JSON
--- object that may have warnings in front of it.
---@param output string
---@return table<string,string>?
function M.parse_properties(output)
    -- The first braces are not necessarily the JSON: a warning in front can have
    -- some of its own ("{odd}"), so each balanced pair is tried until one is the
    -- object that holds the properties.
    local from = 1
    while true do
        local first, last = output:find('%b{}', from)
        if not first then
            return nil
        end
        local ok, decoded = pcall(vim.json.decode, output:sub(first, last))
        if ok and type(decoded) == 'table' and type(decoded.Properties) == 'table' then
            return decoded.Properties
        end
        from = first + 1
    end
end

--- The newest framework in a `TargetFrameworks` list that runs on this machine:
--- net5.0 and later, and netcoreapp. Not net48, netstandard or a platform-specific
--- one (net8.0-windows), none of which can be launched here.
---@param list string
---@return string?
function M.runnable_framework(list)
    local best, best_version
    for framework in list:gmatch('[^;]+') do
        framework = vim.trim(framework)
        local major, minor = framework:match('^net(%d+)%.(%d+)$')
        if not major then
            major, minor = framework:match('^netcoreapp(%d+)%.(%d+)$')
        end
        if major then
            local version = tonumber(major) * 100 + tonumber(minor)
            if not best_version or version > best_version then
                best, best_version = framework, version
            end
        end
    end
    return best
end

local function msbuild(project, properties, extra, callback)
    local cmd = { 'dotnet', 'msbuild', project, '-nologo' }
    for _, name in ipairs(properties) do
        cmd[#cmd + 1] = '-getProperty:' .. name
    end
    vim.list_extend(cmd, extra or {})
    local ok, err = pcall(vim.system, cmd, {
        text = true,
        env = { DOTNET_NOLOGO = '1', DOTNET_CLI_UI_LANGUAGE = 'en' },
    }, function(result)
        vim.schedule(function()
            local props = M.parse_properties(result.stdout or '')
            if result.code ~= 0 or not props then
                return callback(nil, vim.trim((result.stderr or '') .. (result.stdout or '')))
            end
            callback(props)
        end)
    end)
    if not ok then
        callback(nil, tostring(err))
    end
end

--- Where a project builds to, and what kind of thing it builds.
---@param project string
---@param callback fun(found?: { program: string, kind: string }, err?: string)
function M.find_program(project, callback)
    msbuild(project, { 'TargetPath', 'OutputType', 'TargetFrameworks' }, nil, function(props, err)
        if not props then
            return callback(nil, err)
        end
        local function finish(found)
            if not found.TargetPath or found.TargetPath == '' then
                return callback(nil, 'MSBuild did not say where this project builds to')
            end
            callback({ program = found.TargetPath, kind = found.OutputType or '' })
        end
        if props.TargetPath and props.TargetPath ~= '' then
            return finish(props)
        end
        local framework = props.TargetFrameworks and props.TargetFrameworks ~= '' and M.runnable_framework(props.TargetFrameworks)
        if not framework then
            return callback(nil, 'None of the target frameworks (' .. tostring(props.TargetFrameworks) .. ') runs here')
        end
        msbuild(project, { 'TargetPath', 'OutputType' }, { '-p:TargetFramework=' .. framework }, function(chosen, chosen_err)
            if not chosen then
                return callback(nil, chosen_err)
            end
            finish(chosen)
        end)
    end)
end


return M

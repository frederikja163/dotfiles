-- env: bare
-- What to launch (lua/ide/launch.lua): launchSettings.json read the way .NET reads
-- it, which profile is the default, what a profile sets, and which program a
-- project builds -- the last asked of the real `dotnet msbuild`, on projects made
-- here, and skipped where there is no dotnet.
--
-- Bare, with no plugin and no config, which is the reason for the module being
-- separate: ide.debug loads nvim-dap, and a bare Neovim shares the real data
-- directory and the lockfile in the repo with the one being used.

local T = dofile(os.getenv('NVIM_TESTS') .. '/lib.lua')
package.path = os.getenv('NVIM_LUA') .. '/?.lua;' .. package.path

local launch = require('ide.launch')


----------------------------------------------------------------------------
T.section('the file as it is read')
local with_bom, bom_err = launch.parse_profiles('\239\187\191{ "profiles": { "a": { "commandName": "Project" } } }')
T.check('a byte order mark in front, which Windows editors write', with_bom and with_bom[1].name, 'a')
local commented, why = launch.parse_profiles('{ // a comment\n "profiles": { "a": {} } }')
T.check('a comment is refused, not half read', commented, nil)
T.ok('and the reason names it', why:find('comments and trailing commas', 1, true) ~= nil, why)
T.check('so is a trailing comma', (launch.parse_profiles('{ "profiles": { "a": {}, } }')), nil)
T.check('a URL in a string is nothing special', launch.parse_profiles('{ "profiles": { "a": { "applicationUrl": "http://localhost:5000" } } }')[1].profile.applicationUrl, 'http://localhost:5000')

----------------------------------------------------------------------------
T.section('profiles, in the order they were written')
local settings = [[
{
  "$schema": "https://json.schemastore.org/launchsettings.json",
  "iisSettings": { "windowsAuthentication": false, "iisExpress": { "applicationUrl": "http://localhost:1" } },
  "profiles": {
    "zeta": { "commandName": "Project", "applicationUrl": "http://localhost:5001" },
    "IIS Express": { "commandName": "IISExpress", "environmentVariables": { "a": "1", "b": { "nested": true } } },
    "alpha": {
      "commandName": "Project",
      "commandLineArgs": "--verbose \"two words\"",
      "environmentVariables": { "ASPNETCORE_ENVIRONMENT": "Development", "COUNT": 3, "FLAG": true }
    },
    "mid \"quoted\" é": { "commandName": "Executable" }
  }
}
]]
local list, err = launch.parse_profiles(settings)
T.check('there is a list', err, nil)
T.check('in file order, which the decoder alone would lose', vim.tbl_map(function(e) return e.name end, list),
    { 'zeta', 'IIS Express', 'alpha', 'mid "quoted" é' })
T.check('each has what it said', list[3].profile.commandLineArgs, '--verbose "two words"')
T.check('a key with escapes in it is decoded', list[4].name, 'mid "quoted" é')
T.check('nested objects do not add profiles', #list, 4)
T.check('keys of the first, which may be the only', list[1].profile.applicationUrl, 'http://localhost:5001')

local backwards = launch.parse_profiles('{ "profiles": { "c": {}, "b": {}, "a": {} } }')
T.check('reverse alphabetical stays reverse alphabetical', vim.tbl_map(function(e) return e.name end, backwards), { 'c', 'b', 'a' })
local many = {}
for i = 20, 1, -1 do many[#many + 1] = ('"p%02d": { "commandName": "Project" }'):format(i) end
local twenty = launch.parse_profiles('{ "profiles": { ' .. table.concat(many, ', ') .. ' } }')
T.check('twenty of them, in order, not in the decoder\'s', { twenty[1].name, twenty[20].name }, { 'p20', 'p01' })

T.check('"profiles" mentioned in a string before the real one does not confuse it', vim.tbl_map(function(e) return e.name end,
    launch.parse_profiles('{ "note": "\\"profiles\\": { \\"x\\": 1 }", "profiles": { "real": {} } }')), { 'real' })
T.check('no profiles key is an empty list, not an error', launch.parse_profiles('{ "iisSettings": {} }'), {})
T.check('profiles that is not an object is an empty list', launch.parse_profiles('{ "profiles": 3 }'), {})
T.check('a profile that is not an object is not a profile', #launch.parse_profiles('{ "profiles": { "a": 1, "b": {} } }'), 1)
local broken, message = launch.parse_profiles('{ "profiles": { ')
T.check('JSON that is not JSON is refused', broken, nil)
T.ok('and says so', message:find('is not valid JSON', 1, true) ~= nil, message)
T.check('so is an empty file', (launch.parse_profiles('')), nil)

----------------------------------------------------------------------------
T.section('which profile')
local entry = launch.choose_profile(list)
T.check('the first that runs the project, which is what dotnet run does', entry.name, 'zeta')
T.check('not the one before it in the file if that is not one', launch.choose_profile({ list[2], list[3] }).name, 'alpha')
T.check('one asked for by name', launch.choose_profile(list, 'alpha').name, 'alpha')
T.check('even if it is not a Project one', launch.choose_profile(list, 'IIS Express').name, 'IIS Express')
local none, why = launch.choose_profile(list, 'nope')
T.check('one that is not there is refused', none, nil)
T.check('with what there is to choose from', why, 'No launch profile called nope (there is zeta, IIS Express, alpha, mid "quoted" é)')
T.check('an empty name is no name', launch.choose_profile(list, '').name, 'zeta')
T.check('with only profiles that run something else there is none, and that is not an error', { launch.choose_profile({ list[2], list[4] }) }, {})
T.check('an empty list: none', { launch.choose_profile({}) }, {})
T.check('asked for by name in an empty list says there is none', select(2, launch.choose_profile({}, 'x')), 'No launch profile called x (there is none)')

----------------------------------------------------------------------------
T.section('what a profile sets')
local options = launch.launch_options(list[3], '/work/App')
T.check('its environment, every value a string', { options.env.ASPNETCORE_ENVIRONMENT, options.env.COUNT, options.env.FLAG }, { 'Development', '3', 'true' })
T.check('and which profile it is, as dotnet run says', options.env.DOTNET_LAUNCH_PROFILE, 'alpha')
T.check('its command line, split as a shell would', options.args, { '--verbose', 'two words' })
T.check('and where it runs: the project, unless told otherwise', options.cwd, '/work/App')
T.check('no applicationUrl, no ASPNETCORE_URLS', options.env.ASPNETCORE_URLS, nil)

local web = launch.launch_options(list[1], '/work/App')
T.check('applicationUrl becomes ASPNETCORE_URLS', web.env.ASPNETCORE_URLS, 'http://localhost:5001')
T.check('a profile with no command line has no arguments', web.args, {})

local explicit = launch.launch_options({ name = 'x', profile = {
    applicationUrl = 'http://a', environmentVariables = { ASPNETCORE_URLS = 'http://b', DOTNET_LAUNCH_PROFILE = 'mine' },
} }, '/p')
T.check('an ASPNETCORE_URLS of its own wins over applicationUrl', explicit.env.ASPNETCORE_URLS, 'http://b')
T.check('and so does a DOTNET_LAUNCH_PROFILE', explicit.env.DOTNET_LAUNCH_PROFILE, 'mine')
T.check('a relative working directory is from the project', launch.launch_options({ name = 'x', profile = { workingDirectory = 'bin/../data' } }, '/work/App').cwd, '/work/App/data')
T.check('an absolute one is as it is', launch.launch_options({ name = 'x', profile = { workingDirectory = '/srv/app' } }, '/work/App').cwd, '/srv/app')
T.check('an empty one is the project', launch.launch_options({ name = 'x', profile = { workingDirectory = '' } }, '/work/App').cwd, '/work/App')
T.check('a command line that is not a string is no arguments', launch.launch_options({ name = 'x', profile = { commandLineArgs = 5 } }, '/p').args, {})

----------------------------------------------------------------------------
T.section('what MSBuild printed')
local printed = '{\n  "Properties": {\n    "TargetPath": "/p/bin/Debug/net10.0/A.dll",\n    "OutputType": "Exe"\n  }\n}\n'
T.check('the properties', launch.parse_properties(printed), { TargetPath = '/p/bin/Debug/net10.0/A.dll', OutputType = 'Exe' })
T.check('with a warning in front of them', launch.parse_properties('warning NU1701: something {odd}\n' .. printed).OutputType, 'Exe')
T.check('with a message after them', launch.parse_properties(printed .. 'Build succeeded.\n').OutputType, 'Exe')
T.check('an error is not properties', launch.parse_properties('A.csproj(1,1): error MSB4025: The project file could not be loaded.'), nil)
T.check('JSON that has none', launch.parse_properties('{ "Other": {} }'), nil)
T.check('nothing', launch.parse_properties(''), nil)

T.section('which framework runs')
T.check('the newest', launch.runnable_framework('net8.0;net10.0;net9.0'), 'net10.0')
T.check('and not by the order in the list', launch.runnable_framework('net10.0;net6.0'), 'net10.0')
T.check('10 is more than 9', launch.runnable_framework('net9.0;net10.0'), 'net10.0')
T.check('.NET Framework cannot be launched here', launch.runnable_framework('net48;net6.0'), 'net6.0')
T.check('nor can a platform-specific one', launch.runnable_framework('net10.0-windows;net8.0'), 'net8.0')
T.check('nor netstandard', launch.runnable_framework('netstandard2.0;net6.0'), 'net6.0')
T.check('.NET Core is older than .NET 5', launch.runnable_framework('netcoreapp3.1;net5.0'), 'net5.0')
T.check('but is chosen when it is all there is', launch.runnable_framework('netstandard2.0;netcoreapp3.1'), 'netcoreapp3.1')
T.check('spaces around are fine', launch.runnable_framework(' net8.0 ; net9.0 '), 'net9.0')
T.check('nothing runnable', launch.runnable_framework('net48;netstandard2.0'), nil)
T.check('nothing', launch.runnable_framework(''), nil)

----------------------------------------------------------------------------
T.section('which program a project builds, from the real MSBuild')
if vim.fn.executable('dotnet') == 0 then
    print('  SKIPPED: dotnet is not installed')
    T.finish()
end

local root = vim.fn.tempname()
vim.fn.mkdir(root, 'p')
root = vim.uv.fs_realpath(root)

local function project(path, xml)
    local full = root .. '/' .. path
    vim.fn.mkdir(vim.fn.fnamemodify(full, ':h'), 'p')
    vim.fn.writefile(vim.split(xml, '\n'), full)
    return full
end

local function ask(path)
    local found, problem, done
    launch.find_program(path, function(f, e) found, problem, done = f, e, true end)
    T.wait(60000, function() return done end)
    return found, problem
end

local app = project('App/App.csproj', [[<Project Sdk="Microsoft.NET.Sdk">
  <PropertyGroup><OutputType>Exe</OutputType><TargetFramework>net10.0</TargetFramework></PropertyGroup>
</Project>]])
local found = ask(app)
T.check('a program', found and { found.kind, found.program }, { 'Exe', root .. '/App/bin/Debug/net10.0/App.dll' })

local library = project('Lib/Lib.csproj', [[<Project Sdk="Microsoft.NET.Sdk">
  <PropertyGroup><TargetFramework>net10.0</TargetFramework></PropertyGroup>
</Project>]])
T.check('a library is a Library, and has a path all the same', (function() local f = ask(library); return f and { f.kind, f.program:match('[^/]+$') } end)(), { 'Library', 'Lib.dll' })

local renamed = project('Renamed/Renamed.csproj', [[<Project Sdk="Microsoft.NET.Sdk">
  <PropertyGroup><OutputType>Exe</OutputType><TargetFramework>net10.0</TargetFramework><AssemblyName>Acme.Tool</AssemblyName><OutputPath>out/</OutputPath></PropertyGroup>
</Project>]])
found = ask(renamed)
T.check('an AssemblyName and an OutputPath are what a guess at bin/Debug would miss', found and found.program, root .. '/Renamed/out/net10.0/Acme.Tool.dll')

local multi = project('Multi/Multi.csproj', [[<Project Sdk="Microsoft.NET.Sdk">
  <PropertyGroup><OutputType>Exe</OutputType><TargetFrameworks>net48;net8.0-windows;netstandard2.0;net9.0;net10.0</TargetFrameworks></PropertyGroup>
</Project>]])
found = ask(multi)
T.check('a project for several frameworks: the newest that runs here', found and found.program, root .. '/Multi/bin/Debug/net10.0/Multi.dll')

local only_old = project('OnlyOld/OnlyOld.csproj', [[<Project Sdk="Microsoft.NET.Sdk">
  <PropertyGroup><OutputType>Exe</OutputType><TargetFrameworks>net48;netstandard2.0</TargetFrameworks></PropertyGroup>
</Project>]])
local nothing, reason = ask(only_old)
T.check('and when none of them does, it says so', nothing, nil)
T.ok('naming them', reason:find('net48;netstandard2.0', 1, true) ~= nil, reason)

local invalid = project('Bad/Bad.csproj', 'this is not xml')
nothing, reason = ask(invalid)
T.check('a project that cannot be read has no program', nothing, nil)
T.ok('and MSBuild\'s reason', reason:find('MSB4025', 1, true) ~= nil, reason)
nothing, reason = ask(root .. '/Nowhere/Missing.csproj')
T.check('one that is not there', nothing, nil)
T.ok('says so', reason ~= nil and reason ~= '', reason)

T.finish()

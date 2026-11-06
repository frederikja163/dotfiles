---
name: neovim-config
description: Use when editing neovim/ in this dotfiles repo - init.lua, the lua/ide/ modules, a keymap, a mode, the picker, completion, treesitter, the Roslyn or debugger setup, or tests/nvim. Records behaviour of Neovim 0.12, its plugins, Roslyn and netcoredbg that is silent or misleading, how the test harness works and where it bites, and what must not be done to the live config.
---

# The Neovim config

`~/.config/nvim` is a symlink into `neovim/`. **Editing a file there edits the
editor the user starts next**, and `vim.pack` installs missing plugins into
their real data directory the first time the config runs, so booting it
installs things (and rewrites `nvim-pack-lock.json`, which is tracked).

## How it is put together

`init.lua` is a list of modules under `lua/ide/`, loaded in an order that is
written down there and is not arbitrary (`options` before anything that makes a
`<leader>` map; `dotnet` and `debug` before `sessions`). Each is loaded with
`pcall`: one failing leaves a working editor and names itself in
`vim.g.ide_failed`, which every full test asserts is empty.

- **Every key has a `desc`.** `ide.mapped` tells this config's maps from Neovim's
  and the plugins' by their script id, and `test_keys.lua` fails for one of ours
  without a description. The cheatsheet (`<leader>?`) is generated from live maps
  and the mode registry, so a key that is not described is not findable.
- **Commands are declared through `ide.registry`**, which is what makes them
  appear in the palette. A bare `nvim_create_user_command` works and is
  invisible there.
- **Modes are `ide.modal`.** A `getcharstr()` loop, not a layer of keymaps (the
  reasons are in its header). A key the mode does not own *ends* it and is
  replayed; `pass` keys run as Normal commands and stay; `leave = true` marks a
  key that ends the mode by itself.
- **A module that calls `vim.pack.add` must not be required by a bare test.**
  See below. That is why `ide.launch` is separate from `ide.debug`.

## Running the tests

```sh
./tests/test_nvim.sh              # all, about two minutes
./tests/test_nvim.sh review       # by substring of the file name, without .lua
```

Each `tests/nvim/test_*.lua` says on its first line what it needs:

- `-- env: bare`: `nvim -u NONE` with `lua/` on `package.path`. For pure logic.
  **It shares your real data directory and the lockfile** (`-u NONE` does not move
  `stdpath`), so nothing it requires may call `vim.pack.add`.
- `-- env: full`: the real config, in a throwaway XDG tree. The config is a *copy*
  (the lockfile would otherwise be this repo's), the plugin directory is copied
  from the machine's, state and cache are empty.

Tests that need a program (`dotnet`, `roslyn-language-server`, `netcoredbg`) say
`SKIPPED` and carry on when it is missing, so a green run on a machine without
them proves less. `netcoredbg-bin` is in `packages/aur.txt`; to run its test
before installing it, put a copy of the release tarball on `PATH`.

### Writing one

`tests/nvim/lib.lua` has `check`, `ok`, `section`, `wait`, `finish`, a watchdog
that names the section that hung, and:

- `T.async(fn)`: runs `fn` as a coroutine from timers while the editor idles in
  its real main loop, with `T.sleep`, `T.keys`, `T.until_true`. **Insert mode, the
  completion menu and anything that reacts to typed keys only exist there.**
- `T.fake_server{...}`: a language server written in Lua, for tests of what the
  config does with an answer. It replies as a real client sees replies (`nil`,
  not `vim.NIL`, for JSON null).
- `T.picker_script{...}`: keys and functions fed to mini.pick once it has items.

Mistakes that cost an hour each, so that they cost none again:

- `feedkeys(..., 'x')` runs keys as `:normal` does, and under `:normal`
  `getcharstr()` returns `<Esc>` the moment the typeahead is empty. Anything that
  blocks reading keys (a mode, a picker) must be started by calling the mapping's
  `callback` directly, with its keys typed by `vim.defer_fn` + `nvim_input`.
- A key that ends a mode by itself (`q`, a foreign key) must **not** be followed
  by an `<Esc>` in the typed keys: it stays in the keyboard buffer and ends the
  *next* mode before its own keys arrive, and every later call is one behind.
- `-c` commands run before `VimEnter`, where `getcharstr()` on a stdin that is not
  a terminal reads EOF as an interrupt. The driver runs tests from a `VimEnter`
  handler for that reason, and an autocmd run from there needs `++nested` for
  `:edit` to fire `BufRead` and `FileType`.
- `:edit` on the buffer already open frees and re-reads it, which **detaches a
  language server attached by hand** (`vim.lsp.start`) for good.
- Stubbing `vim.lsp.get_clients` for longer than the call that needs it breaks
  Neovim's own handlers, which call methods on whatever it returns while anything
  waits. Stub for the one call.
- A request answered before it returns its id is not one Neovim expects, so the
  fake replies from `vim.schedule`.
- A stopped fake client stays registered until it reports its exit
  (`dispatchers.on_exit`), and goes on being asked.

After writing a test of a guarantee, **break the code on purpose and watch it
fail**.

## What is silent or misleading

### Neovim 0.12

- `ZR` is `:restart`, a command and not a mapping: `maparg('ZR')` is empty.
- A map's `sid` says who made it: -8 for Neovim's own defaults, the plugin's
  script for a plugin's, and **init.lua's for everything this config makes**, since
  the modules are `require`d from it and run in its context. That is how "is this
  key ours?" is answered (`ide.mapped`). It was first done with a startup snapshot
  and then a wrapper round `vim.keymap.set`, both built on the unchecked belief that
  every Lua map has -8; only the defaults do. A map made from a timer or
  `vim.schedule` has no script of its own.
- `nvim_get_keymap().lhs` is already in notation (`<C-H>`); `keytrans` on it escapes
  the bracket. Use `lhsraw`.
- `vim.lsp.enable` attaches only to buffers whose `buftype` is empty. A `nofile`
  buffer needs `vim.lsp.buf_attach_client` by hand.
- `vim.lsp.completion` reads `triggerCharacters` once at `enable`; Roslyn answers a
  letter sent as a trigger character with nothing mid-word. Letters are asked for
  as invoked completions from `InsertCharPre` (`ide.completion`).
- `complete_info({ 'preview_winid' })` is empty. The ids come back only when
  something else is asked for with them (`{ 'selected' }`).
- A plain `setqflist(' ')` after the current list frees every newer list. Add with
  `nr = '$'`, and keep a list you own by its **id** (the number changes).
- `vim.system` and luv callbacks are fast events: schedule before touching the
  API. `nvim_input` is the one input call a timer callback may make.
- A mapping callback cannot be called from `feedkeys('x')` if it blocks; see above.
- `vim.json.decode` refuses comments, trailing commas and a BOM, all of which .NET
  allows. `ide.launch` strips the BOM only; a launchSettings.json with comments is
  reported as invalid and used without a profile.
- `vim.pack` compares a plugin's source, never its branch: a plugin on the wrong
  branch stays there. The lockfile records `version` with its quotes (`"'main'"`).
- A bare `nvim -u NONE` still has the parsers nvim-treesitter built, from the data
  directory's `site/`, which is on the runtimepath.

### nvim-treesitter

`master` is archived and breaks markdown injections on 0.12 (a directive reads a
capture as one node where Neovim passes a list: "attempt to call method 'range'").
`main` is a different plugin: it needs `tree-sitter-cli` to build, installs
nothing and starts nothing by itself (`ide.treesitter` does both).

### Roslyn

- It watches files itself. Neovim does not tell a server about files that change
  on disk behind its back on Linux and Roslyn does not need it to.
- Go to definition into the framework opens a decompiled file under
  `<tmp>/MetadataAsSource`, which no solution contains: `root_dir` has to attach
  the running server to it (`ide.lsp`).
- A source generator's output has no file: a `roslyn-source-generated://` URI, text
  from `workspace/textDocumentContent`, attached by hand. **The text the buffer
  sends back on `didOpen` must equal the generated text to the byte**, or Roslyn's
  call hierarchy returns nothing *for every method in the solution* until the buffer
  is closed. `ide.csharp.put_text` sets `eol` and `fileformat` for that reason.
- No `source.organizeImports`. "Remove unnecessary usings" is a quickfix on a
  `using` line, with "Fix All: ..." beside it that is for the whole project.
- `///` is `textDocument/_vs_onAutoInsert`, which Neovim never sends; the edit's
  `$0` is the cursor and is applied as plain text.
- The references code lens runs `roslyn.client.peekReferences` with only a URI and
  a position: the client looks the references up itself.

### gitsigns

Changing the base clears each buffer's `compare_text` at once and refills it in an
update that finishes later, while the status dict keeps the *old* base's counts.
Asking for `diffthis` in that gap trips `assert(bcache.compare_text)` inside its
own task, where nothing can catch it. `ide.review`'s `diff_ready` checks both.

### mini.pick

`MiniPick.setup` replaces `vim.ui.select`. A mapping's function returning true stops
the picker; `set_picker_items` resets the marks; `choose` runs with the picker window
still current (schedule anything that needs another window or another picker).

### dotnet

- `dotnet msbuild -getProperty:TargetPath` is the way to find the program (0.3 s).
  A multi-targeted project has an empty `TargetPath` until `-p:TargetFramework=` is
  given.
- A failed build prints every diagnostic **twice**. The two test runners print
  failures differently (`  Failed X [3 ms]` against `failed X (3ms)`), and
  Microsoft Testing Platform mode (`global.json`) wants `--project` where VSTest takes
  a path and refuses `-nologo`.
- Only the ASP.NET *runtime* may be installed: a Web SDK project cannot build
  offline here (no targeting pack). Fixtures use the plain SDK.

### netcoredbg

Found by running it, not documented:

- No `runInTerminal`: `console = "integratedTerminal"` is silently ignored, the
  program's output arrives as events (nvim-dap's REPL) and **its stdin never
  arrives**: a program that reads the console waits for ever.
- No logpoints and no hit counts (`supportsLogPoints` is absent), so a "logpoint"
  is a plain breakpoint that stops. Conditions work.
- Stepping into a method stops at its opening `{` first, not the first statement.
- `terminate` kills the program even for an attach; use
  `disconnect({ terminateDebuggee = false })` to let go.
- Attaching to a process that is not the debugger's child needs
  `kernel.yama.ptrace_scope = 0`; Arch ships 1.
- nvim-dap's hover float takes focus and never closes; `K` in the mode returns
  focus and closes it on the next cursor movement.

## Checking your own work

Everything that follows is safe; the rest is not.

- A headless boot of the real config: `nvim --headless -i NONE <a file> -c 'qa!'`.
  **Give it a file**, or the session code reads and writes the one for this
  directory. It installs missing plugins (a `vim.pack` confirmation is printed and
  answered) and updates the lockfile.
- **Never `pkill` or `killall` with a pattern.** One that matches the running command
  line kills the shell executing it (this happened here, with a pattern of a test's
  own file name). List with `pgrep -fa '[x]pattern'` (the bracket keeps it from
  matching itself) and kill by pid, and only pids whose `/proc/<pid>/cmdline` holds
  the temporary directory the test made.
- A test that starts a program must be able to prove it left none behind
  (`test_debug.lua` does, by pid).

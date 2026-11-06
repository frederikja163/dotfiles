#!/usr/bin/env bash
# Run the Neovim config tests: tests/nvim/test_*.lua, each in a headless nvim.
#
#   ./tests/test_nvim.sh              all of them
#   ./tests/test_nvim.sh modal        the ones whose name contains "modal"
#
# Neither quits when the script returns: a test ends the process itself, with
# T.finish(), so that one that needs the editor's real main loop (tests/nvim/
# lib.lua, T.async) can have it. A test that never finishes is ended by the
# watchdog in lib.lua, and by `timeout` below if even that fails.
#
# Both run the test from a VimEnter handler rather than from -c directly. A -c
# command runs during startup, before the main loop, and there getcharstr() on
# a stdin that is not a terminal reads end-of-file as an interrupt, so no test
# of a key loop could pass. Once the loop is running it behaves as it does for
# a person.
#
# A test file says what it needs on its first line:
#
#   -- env: bare    no config and no plugins: plain nvim with the config's lua/
#                   directory on package.path. For pure logic.
#   -- env: full    the real config, started the way it is started for real, in
#                   an environment of its own (below).
#
# The full environment is a throwaway XDG tree. The config is a *copy*, not a
# link: vim.pack writes nvim-pack-lock.json beside init.lua, and through a link
# that would be this repo's tracked lockfile. Plugins are copied from the
# machine's own directory when it has them, so a run does not clone a dozen
# repositories; on a machine without them vim.pack fetches what the lockfile
# names, which is slower and needs the network, and is what a fresh install does
# anyway. State and cache are empty, so no session, shada or swap file of the
# user's is read or written.
#
# A file argument is always given: with none, a directory or an empty buffer,
# the config restores or writes a session for the directory (sessions.lua).
set -uo pipefail

cd "$(dirname "${BASH_SOURCE[0]}")/.."

NVIM="${NVIM:-$(command -v nvim || true)}"
[ -x "$NVIM" ] || NVIM="$HOME/.local/share/bob/nvim-bin/nvim"
if [ ! -x "$NVIM" ]; then
    echo "SKIPPED: nvim not found (install.sh installs it through bob)"
    exit 0
fi

filter="${1:-}"
ROOT="$PWD"
TMP="$(mktemp -d)"
trap 'rm -rf "$TMP"' EXIT

full_env() {
    local home="$TMP/full"
    if [ ! -d "$home" ]; then
        mkdir -p "$home/config" "$home/data/nvim/site/pack/core" "$home/state" "$home/cache"
        cp -a "$ROOT/neovim" "$home/config/nvim"
        local plugins="${XDG_DATA_HOME:-$HOME/.local/share}/nvim/site/pack/core/opt"
        [ -d "$plugins" ] && cp -a "$plugins" "$home/data/nvim/site/pack/core/opt"
        # Parsers nvim-treesitter has built, which are what make highlighting
        # and the C# queries work; building them needs a compiler and minutes.
        local parsers="${XDG_DATA_HOME:-$HOME/.local/share}/nvim/site/parser"
        [ -d "$parsers" ] && cp -a "$parsers" "$home/data/nvim/site/parser"
        local queries="${XDG_DATA_HOME:-$HOME/.local/share}/nvim/site/queries"
        [ -d "$queries" ] && cp -a "$queries" "$home/data/nvim/site/queries"
        echo x > "$home/probe.txt"
    fi
    echo "$home"
}

# Git as the tests need it to behave, whoever is running them: no user or system
# config (an alias, a diff algorithm or a signing key of the user's would change
# what a fixture repository says), and an identity to commit with. Inherited by
# everything nvim starts, gitsigns' git calls included.
export GIT_CONFIG_GLOBAL=/dev/null GIT_CONFIG_SYSTEM=/dev/null
export GIT_AUTHOR_NAME=t GIT_AUTHOR_EMAIL=t@t GIT_COMMITTER_NAME=t GIT_COMMITTER_EMAIL=t@t

total_fail=0
ran=0
for test in tests/nvim/test_*.lua; do
    name="$(basename "$test" .lua)"
    case "$name" in *"$filter"*) ;; *) continue ;; esac

    env_kind="$(sed -n '1s/^-- env: *//p' "$test")"
    echo "==> $test ($env_kind)"
    ran=$((ran + 1))

    run='local ok, err = pcall(dofile, vim.env.NVIM_TEST); if not ok then io.stderr:write(tostring(err), "\n"); os.exit(2) end'
    case "$env_kind" in
        bare)
            NVIM_TEST="$ROOT/$test" NVIM_ROOT="$ROOT" NVIM_TESTS="$ROOT/tests/nvim" NVIM_LUA="$ROOT/neovim/lua" \
                NVIM_LOG_FILE=/dev/null \
                timeout 120 "$NVIM" --headless -u NONE -i NONE -c "autocmd VimEnter * ++once ++nested lua $run" 2>&1 </dev/null
            status=$?
            ;;
        full)
            home="$(full_env)"
            NVIM_TEST="$ROOT/$test" NVIM_ROOT="$ROOT" NVIM_TESTS="$ROOT/tests/nvim" NVIM_LUA="$home/config/nvim/lua" \
                NVIM_LOG_FILE="$home/nvim.log" \
                XDG_CONFIG_HOME="$home/config" XDG_DATA_HOME="$home/data" \
                XDG_STATE_HOME="$home/state" XDG_CACHE_HOME="$home/cache" \
                timeout "${NVIM_TEST_TIMEOUT:-300}" "$NVIM" --headless -i NONE "$home/probe.txt" \
                -c "autocmd VimEnter * ++once ++nested lua $run" 2>&1 </dev/null
            status=$?
            ;;
        *)
            echo "  FAIL $test: first line must be '-- env: bare' or '-- env: full'"
            status=1
            ;;
    esac
    if [ "$status" -ne 0 ]; then
        echo "  (exit status $status)"
        total_fail=1
    fi
    echo
done

if [ "$ran" -eq 0 ]; then
    echo "no test matches '$filter'"
    exit 1
fi
[ "$total_fail" -eq 0 ]

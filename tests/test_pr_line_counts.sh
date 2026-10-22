#!/usr/bin/env bash
# Harness for bin/pr-line-counts, the table every PR description ends with.
#
# Real git against a scratch repository, since the script's job is reading what
# git says a branch added. The C# is chosen to hit what a line-by-line match
# gets wrong: a // inside a string, a verbatim string spanning lines, a quote
# in a char literal, a raw string, a block comment that opens before the added
# lines and one that shares a line with code.
set -uo pipefail

cd "$(dirname "${BASH_SOURCE[0]}")/.."
SCRIPT="$PWD/bin/pr-line-counts"

TMP="$(mktemp -d)"
trap 'rm -rf "$TMP"' EXIT
export GIT_CONFIG_GLOBAL=/dev/null GIT_CONFIG_SYSTEM=/dev/null
export GIT_AUTHOR_NAME=t GIT_AUTHOR_EMAIL=t@t GIT_COMMITTER_NAME=t GIT_COMMITTER_EMAIL=t@t

pass=0; fail=0
check() {
    if [ "$2" = "$3" ]; then
        pass=$((pass + 1)); printf '  ok   %-54s %s\n' "$1" "$2"
    else
        fail=$((fail + 1)); printf '  FAIL %-54s got %s want %s\n' "$1" "$2" "$3"
    fi
}

# COL is the table column: 3 added, 4 removed, 5 change.
count() { "$SCRIPT" "$@" 2>/dev/null | awk -F'|' -v k="$CAT" -v c="${COL:-3}" '$2 ~ k {gsub(/ /, "", $c); print $c}'; }
row() { CAT="$1"; shift; count "$@"; }
removed() { COL=4 row "$@"; }
change() { COL=5 row "$@"; }

r="$TMP/r"
git init -q -b main "$r"
cd "$r"
printf 'x\n' > README.md
git add . && git commit -qm base

git checkout -q -b feat
mkdir -p src docs Foo.Tests
cat > src/A.cs <<'CS'
using System;

namespace Foo;

/// <summary>Does things.</summary>
public class A
{
    // a line comment
    public string Url = "http://x"; // trailing
    public char Q = '"';
    /* block
       continues
    */
    public string V = @"multi
// not a comment
line";
    public string R = """
        /* nope */
        """;
    public int N = 1; /* inline */
}
CS
printf 'public class T { }\n// c\n' > Foo.Tests/T.cs
printf 'a\nb\n\nc\n' > docs/x.md
printf 'echo hi\n' > run.sh
git add . && git commit -qm feat

echo "scenario: a branch of C#, a test project, docs and a script"
check "code" "$(row Code main)" 15
check "comments: doc, line and block, not the ones in strings" "$(row Comments main)" 5
check "docs, blank lines left out" "$(row Docs main)" 3
check "tests, comments in a test file included" "$(row Tests main)" 2
check "an unknown language is said to be counted as code" \
    "$("$SCRIPT" main 2>&1 >/dev/null | grep -c '\.sh')" 1

echo "scenario: only what the branch adds"
git checkout -q -b more
python3 - <<'PY'
p = "src/A.cs"
s = open(p).read().replace("    /* block\n", "    // x\n    /* block\n")
open(p, "w").write(s)
PY
git commit -qam more
check "one more comment" "$(row Comments feat)" 1
check "and nothing else" "$(row Code feat)" 0

echo "scenario: a block comment that opened above the added line"
git checkout -q feat && git checkout -q -b block
python3 - <<'PY'
p = "src/A.cs"
s = open(p).read().replace("       continues\n", "       continues\n       and more\n")
open(p, "w").write(s)
PY
git commit -qam block
check "the added line inside it is a comment" "$(row Comments feat)" 1
check "not code" "$(row Code feat)" 0

echo "scenario: lines removed, and the change between the two"
git checkout -q feat && git checkout -q -b cut
python3 - <<'PY'
s = open("src/A.cs").read()
s = s.replace("    // a line comment\n", "")
s = s.replace("    public int N = 1; /* inline */\n", "    public int N = 2; /* inline */\n")
open("src/A.cs", "w").write(s)
PY
git rm -q run.sh
printf 'a\n' > docs/x.md
git commit -qam cut
check "a comment removed" "$(removed Comments feat)" 1
check "code replaced counts as removed" "$(removed Code feat)" 2
check "and as added" "$(row Code feat)" 1
check "a deleted script is removed code" "$(change Code feat)" -1
check "docs shrunk by two" "$(change Docs feat)" -2
check "a removal is negative" "$(change Comments feat)" -1
check "total added" "$(row Total feat)" 1
check "total removed, a deleted file included" "$(removed Total feat)" 5
check "total change" "$(change Total feat)" -4

echo "scenario: a removed line that starts with dashes is not a header"
git checkout -q feat && git checkout -q -b dashes
printf 'x\n-- y\n' > docs/d.md && git add . && git commit -qm d
git checkout -q -b dashes2 && printf 'x\n' > docs/d.md && git commit -qam d2
check "counted as one removed doc line" "$(removed Docs dashes)" 1

echo "scenario: -u counts staged, unstaged and untracked work, and without it none is"
git checkout -q feat && git checkout -q -b wip
printf 'public class W { }\n// c\n' > src/Staged.cs
git add src/Staged.cs
printf '// edit\n' >> src/A.cs
printf 'one\ntwo\n\nthree\n' > docs/new.md
printf 'junk\n' > ignored.log; printf '*.log\n' > .git/info/exclude
mkdir -p sub; printf 'a\nb\n' > sub/note.md
check "without -u the work is not counted" "$(row Total feat)" 0
check "-u: staged file, unstaged edit and untracked file as code" "$(CAT=Code; count -u feat)" 1
check "-u: a comment among them" "$(CAT=Comments; count -u feat)" 2
check "-u: untracked docs, blank line left out" "$(CAT=Docs; count -u feat)" 5
check "-u: run from a subdirectory finds the same files" "$(cd sub && CAT=Docs count -u feat)" 5
check "-u: the flag may come after the base" "$(CAT=Docs; count feat -u)" 5
git rm -q --cached src/Staged.cs; rm -f src/Staged.cs docs/new.md; rm -rf sub; git checkout -q -- src/A.cs
check "-u: a clean tree counts nothing" "$(CAT=Total; count -u feat)" 0

echo "scenario: nothing to compare against"
git -C "$TMP" init -q -b other "$TMP/e"
check "no main to compare to is an error" "$(cd "$TMP/e" && "$SCRIPT" >/dev/null 2>&1; echo $?)" 1

echo
printf '%d passed, %d failed\n' "$pass" "$fail"
[ "$fail" -eq 0 ]

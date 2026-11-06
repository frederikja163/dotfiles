#!/usr/bin/env bash
# Harness for bin/lines-changed, the table every PR description ends with.
#
# Real git against a scratch repository, since the tool's job is reading what
# git says a change added. The C# is chosen to hit what a line-by-line match
# gets wrong: a // inside a string, a verbatim string spanning lines, a quote
# in a char literal, a raw string, a block comment that opens before the added
# lines and one that shares a line with code. The other languages get one small
# file each, with the traps their comment syntax sets (a # in $#, a -- inside a
# SQL string, a // inside a JavaScript template).
#
# Each scenario runs the tool once and reads several cells out of that one run:
# it is a dotnet-script, so a call costs a quarter of a second, and thirty
# separate ones would be most of the time this file takes.
set -uo pipefail

cd "$(dirname "${BASH_SOURCE[0]}")/.."
SCRIPT="$PWD/bin/lines-changed"

if ! command -v dotnet-script >/dev/null; then
    echo "SKIPPED: dotnet-script not found (dotnet tool install -g dotnet-script; ~/.dotnet/tools on PATH)"
    exit 0
fi

TMP="$(mktemp -d)"
trap 'rm -rf "$TMP"' EXIT
export GIT_CONFIG_GLOBAL=/dev/null GIT_CONFIG_SYSTEM=/dev/null
export GIT_AUTHOR_NAME=t GIT_AUTHOR_EMAIL=t@t GIT_COMMITTER_NAME=t GIT_COMMITTER_EMAIL=t@t

pass=0; fail=0
check() {
    if [ "$2" = "$3" ]; then
        pass=$((pass + 1)); printf '  ok   %-58s %s\n' "$1" "$2"
    else
        fail=$((fail + 1)); printf '  FAIL %-58s got %s want %s\n' "$1" "$2" "$3"
    fi
}

# run <args>: one run of the tool. out is stdout, err is stderr, status is the
# exit status; cell reads one number out of the table.
out=""; err=""; status=0
run() {
    out="$("$SCRIPT" "$@" 2>"$TMP/err")"; status=$?
    err="$(<"$TMP/err")"
}
# cell <category> <column>: 3 added, 4 removed, 5 change.
cell() { awk -F'|' -v k="$1" -v c="$2" '$2 ~ "^ *" k " *$" { gsub(/ /, "", $c); print $c }' <<<"$out"; }
added() { cell "$1" 3; }
removed() { cell "$1" 4; }
change() { cell "$1" 5; }
note() { grep -c -- "$1" <<<"$err"; }

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
printf 'echo hi\n' > tool.xyz
git add . && git commit -qm feat

echo "scenario: a branch of C#, a test project, docs and a file of a language it does not know"
run main
check "code" "$(added Code)" 15
check "comments: doc, line and block, not the ones in strings" "$(added Comments)" 5
check "docs, blank lines left out" "$(added Docs)" 3
check "tests, comments in a test file included" "$(added Tests)" 2
check "an unknown language is said to be counted as code" "$(note '\.xyz')" 1
check "and the note is not on stdout, where a pipe would take it" "$(grep -c 'lines-changed:' <<<"$out")" 0
check "nothing was removed" "$(removed Total)" 0

echo "scenario: only what the branch adds"
git checkout -q -b more
sed -i 's|^    /\* block$|    // x\n    /* block|' src/A.cs
git commit -qam more
run feat
check "one more comment" "$(added Comments)" 1
check "and nothing else" "$(added Code)" 0

echo "scenario: a block comment that opened above the added line"
git checkout -q feat && git checkout -q -b block
sed -i 's|^       continues$|       continues\n       and more|' src/A.cs
git commit -qam block
run feat
check "the added line inside it is a comment" "$(added Comments)" 1
check "not code" "$(added Code)" 0

echo "scenario: lines removed, and the change between the two"
git checkout -q feat && git checkout -q -b cut
sed -i '/^    \/\/ a line comment$/d; s|^    public int N = 1; /\* inline \*/$|    public int N = 2; /* inline */|' src/A.cs
git rm -q tool.xyz
printf 'a\n' > docs/x.md
git commit -qam cut
run feat
check "a comment removed" "$(removed Comments)" 1
check "code replaced counts as removed" "$(removed Code)" 2
check "and as added" "$(added Code)" 1
check "a deleted file is removed code" "$(change Code)" -1
check "docs shrunk by two" "$(change Docs)" -2
check "a removal is negative" "$(change Comments)" -1
check "total added" "$(added Total)" 1
check "total removed, a deleted file included" "$(removed Total)" 5
check "total change" "$(change Total)" -4

echo "scenario: a removed line that starts with dashes is not a header"
git checkout -q feat && git checkout -q -b dashes
printf 'x\n-- y\n' > docs/d.md && git add . && git commit -qm d
git checkout -q -b dashes2 && printf 'x\n' > docs/d.md && git commit -qam d2
run dashes
check "counted as one removed doc line" "$(removed Docs)" 1

echo "scenario: staged, unstaged and untracked work is counted, and --committed leaves it out"
git checkout -q feat && git checkout -q -b wip
printf 'public class W { }\n// c\n' > src/Staged.cs
git add src/Staged.cs
printf '// edit\n' >> src/A.cs
printf 'one\ntwo\n\nthree\n' > docs/new.md
printf 'junk\n' > ignored.log; printf '*.log\n' > .git/info/exclude
mkdir -p sub; printf 'a\nb\n' > sub/note.md
run feat
check "by default: staged file, unstaged edit and untracked file as code" "$(added Code)" 1
check "by default: a comment among them" "$(added Comments)" 2
check "by default: untracked docs, blank line left out" "$(added Docs)" 5
check "by default: nothing to warn about" "$(note 'not counted')" 0
run -u feat
check "-u says what the default does" "$(added Docs)" 5
run feat -u
check "-u: the flag may come after the ref" "$(added Docs)" 5
run --committed feat
check "--committed: the work is not counted" "$(added Total)" 0
check "--committed: and it says so" "$(note 'not counted')" 1
check "--committed: it says how to count them" "$(note 'leave out --committed')" 1
check "--committed: the warning goes to stderr, not into a pipe" "$(grep -c 'not counted' <<<"$out")" 0
run -c feat
check "-c is the short form" "$(added Total)" 0
run feat --committed
check "--committed may come after the ref" "$(added Total)" 0
run -u --committed feat
check "-u and --committed contradict: usage error" "$status" 2
run --committed -u feat
check "in either order" "$status" 2
(cd sub && run feat; echo "$out" > "$TMP/sub.out")
out="$(<"$TMP/sub.out")"
check "run from a subdirectory it finds the same files" "$(added Docs)" 5

echo "scenario: --require-clean refuses a dirty tree, tracked or untracked"
run --require-clean feat
check "dirty: exit status 3" "$status" 3
check "dirty: no table is printed" "$out" ""
check "dirty: it says what to do" "$(note 'commit them first')" 1
run -u --require-clean feat
check "-u and --require-clean contradict: usage error" "$status" 2
git rm -q --cached src/Staged.cs; rm -f src/Staged.cs docs/new.md; rm -rf sub; git checkout -q -- src/A.cs
run feat
check "a clean tree counts nothing more" "$(added Total)" 0
run --committed feat
check "and --committed counts the same, with nothing to say" "$(added Total):$(note 'not counted')" 0:0
run --require-clean --committed feat
check "clean: --committed with it is the same thing said twice" "$status" 0
run --require-clean feat
check "clean: exit status 0" "$status" 0
check "clean: the table is there" "$(added Total)" 0
check "clean: ignored files do not make it dirty" "$(note 'uncommitted')" 0
printf 'x\n' > untracked.txt
run --require-clean feat
check "an untracked file is dirty too" "$status" 3
rm untracked.txt

echo "scenario: BASE, branch tips, tags, hashes and suffixes"
b="$TMP/b"
git init -q -b main "$b"
cd "$b"
printf 'x\n' > README.md && git add . && git commit -qm c0
c0="$(git rev-parse --short HEAD)"
printf 'int a;\nint b;\n' > c1.cs && git add . && git commit -qm c1
git tag v1
c1="$(git rev-parse --short HEAD)"
git checkout -q -b topic
printf 'int a;\nint b;\nint c;\n' > t1.cs && git add . && git commit -qm t1
git checkout -q main
printf 'int a;\nint b;\nint c;\nint d;\nint e;\nint f;\nint g;\n' > m2.cs && git add . && git commit -qm m2
git checkout -q topic
run
check "no ref: BASE, what the branch added" "$(added Total)" 3
check "BASE leaves out what main gained since" "$(removed Total)" 0
run BASE
check "BASE spelled out is the same" "$(added Total)" 3
run BASE:main
check "BASE:main is the same here" "$(added Total)" 3
run main
check "a plain name is the tip: the branch's own work" "$(added Total)" 3
check "and main's newer commit shows as removed" "$(removed Total)" 7
run 'BASE~1'
check "BASE~1: one commit before the merge base" "$(added Total)" 5
run v1
check "a tag" "$(added Total)" 3
run "$c1"
check "a commit" "$(added Total)" 3
run "$c0"
check "an older commit" "$(added Total)" 5
run HEAD~1
check "HEAD~1" "$(added Total)" 3
git branch old "$c0"
git config lines-changed.base old
run
check "lines-changed.base picks another default branch" "$(added Total)" 5
git config --unset lines-changed.base
run BASE:old
check "BASE:<branch> names another one" "$(added Total)" 5
run BASE:nope
check "BASE:<unknown branch> is an error" "$status" 1
run nope
check "an unknown ref is an error" "$status" 1
run -x
check "an unknown option is a usage error" "$status" 2
run main v1
check "two refs are a usage error" "$status" 2
run --json "$c0"
check "--json names the base commit" "$(grep -c "\"base\": \"$(git rev-parse "$c0")\"" <<<"$out")" 1
check "--json is an object with the totals" "$(grep -c '"total": {' <<<"$out")" 1
check "--json: code added" "$(grep -A3 '"Code": {' <<<"$out" | grep -c '"added": 5')" 1
check "--json: compared against the working tree, by default" "$(grep -c '"against": "working tree"' <<<"$out")" 1
run --json --committed "$c0"
check "--json: against HEAD with --committed" "$(grep -c '"against": "HEAD"' <<<"$out")" 1

echo "scenario: the comment rules of each language"
l="$TMP/l"
git init -q -b main "$l"
cd "$l"
printf 'x\n' > README.md && git add . && git commit -qm base
# lang <file> <code> <comments> <label>: the file is read from stdin, committed
# on its own, and counted as the one commit.
lang() {
    cat > "$1"
    git add . && git commit -qm "$1"
    run HEAD~1
    check "$4: code" "$(added Code)" "$2"
    check "$4: comments" "$(added Comments)" "$3"
}
lang a.lua 4 5 "lua: --, --[[ ]], long strings" <<'EOF'
-- comment
local s = "-- not a comment"
--[[ block
still block ]]
local x = [[ long -- string
]]
--[==[ another
]==]
return x -- trailing
EOF
lang a.ts 4 3 "typescript: a // in a template and in quotes" <<'EOF'
// c1
const t = `http://x // not a comment
second line`;
/* block
   spans */
const y = 1; // trailing
const re = '//';
EOF
lang a.py 2 4 "python: shebang, docstring, # in strings" <<'EOF'
#!/usr/bin/env python3
"""Module docstring
spans two lines."""
x = "a # b"  # trailing
y = f"{x}" if x else '$#'
# done
EOF
lang a.sh 2 2 "shell: \$# and \${#x} are not comments" <<'EOF'
#!/bin/sh
echo "$#" # args
n=${#x}
# end
EOF
lang a.sql 1 3 "sql: -- inside a string" <<'EOF'
-- c
select 'a--b' /* inline */ from t; -- end
/* multi
   line */
EOF
lang a.xml 1 4 "xml: <!-- -->" <<'EOF'
<!-- c -->
<a x="1"/> <!-- t -->
<!--
multi
-->
EOF
lang a.css 2 1 "css: a /* */ inside a string" <<'EOF'
/* c */
a { content: "/* x */"; }
b { color: red; } /* t */
EOF
lang a.json 1 0 "json: no comments" <<'EOF'
{"a": 1}
EOF
check "json is not reported as an unknown language" "$(note 'no comment rules')" 0
lang a.rs 2 1 "rust: a char literal and a lifetime" <<'EOF'
fn f<'a>(x: &'a str) -> &'a str { x } // c
let c = '"'; let s = "//";
// full
EOF

echo "scenario: generated files, and .gitattributes"
g="$TMP/g"
git init -q -b main "$g"
cd "$g"
printf 'x\n' > README.md && git add . && git commit -qm base
printf '{\n  "a": 1,\n  "b": 2\n}\n' > package-lock.json
printf 'int g;\n' > Thing.g.cs
printf 'int p;\n' > Real.cs
git add . && git commit -qm gen
run HEAD~1
check "lockfile and generated source are left out" "$(added Total)" 1
check "and named on stderr" "$(note 'left out 2')" 1
check "and not on stdout" "$(grep -c 'left out' <<<"$out")" 0
mkdir -p vendor scripts bad
printf 'int v;\nint w;\n' > vendor/v.cs
printf 'int s;\n// c\nint t;\n' > scripts/s.cs
printf 'int z;\n' > bad/b.cs
cat > .gitattributes <<'EOF'
vendor/** lines-changed=ignore
scripts/*.cs lines-changed=tests
package-lock.json lines-changed=code
bad/** lines-changed=oops
EOF
git add . && git commit -qm attrs
# Two commits back, so the lockfile from the first one is in the comparison
# with the rules from the second: package-lock.json 4 + Real.cs 1 + b.cs 1 +
# .gitattributes 4 as code, s.cs 3 as tests, and Thing.g.cs and vendor/ left out.
run HEAD~2
check "total added" "$(added Total)" 13
check "tests: a path forced to count as tests, comment included" "$(added Tests)" 3
check "code: a lockfile opted back in, a vendored directory not" "$(added Code)" 10
check "an invalid value is warned about" "$(note 'oops')" 1
check "the generated file and the ignored directory are named" "$(note 'left out 2')" 1

echo "scenario: a path with spaces, a rename, and text that is not ASCII"
u="$TMP/u"
git init -q -b main "$u"
cd "$u"
mkdir "my dir"
printf '// héllo wörld\nint a;\nint b;\n' > "my dir/Fil e.cs"
git add . && git commit -qm a
git mv "my dir/Fil e.cs" "my dir/Renamed.cs"
printf '// héllo wörld\nint a;\nint b;\n// ünï\n' > "my dir/Renamed.cs"
git add . && git commit -qm b
run HEAD~1
check "a renamed file counts only what changed in it" "$(added Total)" 1
check "and it is a comment, in a path with a space" "$(added Comments)" 1
check "nothing is removed by a rename" "$(removed Total)" 0

echo "scenario: nothing to compare against"
git init -q -b other "$TMP/e"
printf 'x\n' > "$TMP/e/f" && git -C "$TMP/e" add . && git -C "$TMP/e" commit -qm c
(cd "$TMP/e" && "$SCRIPT" >/dev/null 2>&1; echo $? > "$TMP/e.status")
check "no main to compare to is an error" "$(<"$TMP/e.status")" 1
mkdir "$TMP/nogit"
(cd "$TMP/nogit" && "$SCRIPT" >/dev/null 2>&1; echo $? > "$TMP/nogit.status")
check "outside a repository is an error" "$(<"$TMP/nogit.status")" 1

echo
printf '%d passed, %d failed\n' "$pass" "$fail"
[ "$fail" -eq 0 ]

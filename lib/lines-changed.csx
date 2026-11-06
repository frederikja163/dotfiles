#!/usr/bin/env dotnet-script
// lines-changed: how many lines a change adds and removes, as code, comments,
// docs and tests. Started by bin/lines-changed; read that for how to run it.
//
// It is a script and not left to whoever writes the pull request description,
// because the split into comments and code cannot be read off a diff. A diff
// at --unified=0 shows only the lines that changed, and cannot say whether one
// of them sits inside a block comment that opened further up. So the diff is
// used only to learn which line numbers changed, and each file is classified
// whole: added lines from the file as it is now (the working tree, or HEAD
// with --committed), removed lines from the file as it was at REF, where they
// still were.
//
// Why a lexer and not a regex over lines: "http://x" holds a // that is not a
// comment, a verbatim string can span lines and contain anything, and '"' is a
// char literal, not the start of a string. A line-by-line match gets all three
// wrong in ordinary C#. C# has a lexer of its own for that reason; the other
// languages share one that is driven by a Profile (comment openers, string
// quotes, a few flags), so adding a language is a line in Profiles, not code.
// The shared one is approximate for exotic quoting (interpolation that nests
// quotes, Python's string prefixes, shell here-documents); a line that holds
// both code and a comment counts as code, and doc comments are comments.
//
// Where a line goes is decided by its file first and its content second: a
// doc file is all docs, a test file is all tests, comments inside it included,
// and only what is left is split into comments and code. Blank lines are not
// counted, on either side.
//
// Per-repo rules live in .gitattributes, which every repo already has and git
// already knows how to evaluate (including patterns, directories and
// precedence), so there is no config format of our own to learn:
//
//     docs/old/**       lines-changed=ignore
//     tools/**          lines-changed=code
//     **/Fixtures/**    lines-changed=tests
//
// The values are code, docs, tests and ignore. Obvious generated files
// (lockfiles, minified bundles, *.g.cs, *.Designer.cs) are ignored by default,
// and the ones that were skipped are named on stderr, so a number is never
// quietly smaller than the diff. `code` is how a repo opts one back in.
//
// What REF means. The old side is always a commit; the new side is the working
// tree, or HEAD with --committed. BASE is the merge base of HEAD and the default
// branch -- what a pull request shows -- and is the default, which keeps a
// branch's own commits in the count and leaves out whatever the default branch
// gained since. `main` is the tip of main, as git itself would read it. BASE
// takes the suffixes HEAD does (BASE~2, BASE^), and BASE:<branch> names
// another branch for a pull request that is not aimed at the default one.
//
// The default branch is, in order: `git config lines-changed.base`, then
// origin/HEAD, origin/main, main, origin/master, master.
//
// Uncommitted work is counted by default: the question asked while working is
// how big the change in front of you is, and that is the edits too. It used to be
// the other way round, with -u to add them, and the number a person wanted was
// the one that needed the flag. -u is still accepted and says what the default
// does, so a script that passes it keeps working.
//
// --committed leaves them out, which is what a pull request would show of the
// branch as it stands, and the script says so when there is some, because that
// number is then smaller than the change on disk. --require-clean turns that
// sentence into a refusal, for a caller that must not publish a number the
// pull request would not show: it implies --committed, and on a clean tree the
// two modes count the same lines, so it never needs to say which it means.
//
// Tried and not done: a diff-based classifier. `git diff` hands over the lines
// but not what they are inside of (see above), and `git diff --word-diff`,
// `-W` and friends do not change that. Counting per file with a tool such as
// tokei does not either: it totals a file, not the lines a change touched.

using System.Diagnostics;
using System.Text;
using System.Text.Json;
using System.Text.RegularExpressions;

enum Role { Source, Docs, Tests, Ignore }

static class Exit
{
    public const int Failure = 1, Usage = 2, Dirty = 3;

    public static void Now(string message, int code = Failure)
    {
        Console.Out.Flush();
        Console.Error.WriteLine("lines-changed: " + message);
        Environment.Exit(code);
    }
}

static class Git
{
    public static string Root;

    public static (int Code, string Out, string Err) Run(string input, params string[] args)
    {
        var psi = new ProcessStartInfo("git")
        {
            RedirectStandardOutput = true,
            RedirectStandardError = true,
            RedirectStandardInput = input != null,
            StandardOutputEncoding = Encoding.UTF8,
            StandardErrorEncoding = Encoding.UTF8,
            UseShellExecute = false,
        };
        if (input != null) psi.StandardInputEncoding = new UTF8Encoding(false);
        if (Root != null) psi.WorkingDirectory = Root;
        // A read-only question should not take the index lock: it would make
        // an editor's own `git status` fail while this runs.
        psi.Environment["GIT_OPTIONAL_LOCKS"] = "0";
        psi.ArgumentList.Add("-c");
        psi.ArgumentList.Add("core.quotepath=off");
        foreach (var arg in args) psi.ArgumentList.Add(arg);

        Process process = null;
        try { process = Process.Start(psi); }
        catch (Exception e) { Exit.Now("cannot run git: " + e.Message); }

        var stdout = process.StandardOutput.ReadToEndAsync();
        var stderr = process.StandardError.ReadToEndAsync();
        if (input != null)
        {
            process.StandardInput.Write(input);
            process.StandardInput.Close();
        }
        process.WaitForExit();
        return (process.ExitCode, stdout.Result, stderr.Result);
    }

    public static string Must(params string[] args)
    {
        var r = Run(null, args);
        if (r.Code != 0) Exit.Now("git " + string.Join(" ", args) + ": " + r.Err.Trim());
        return r.Out;
    }

    // The commit a name points at, or null.
    public static string Commit(string name)
    {
        var r = Run(null, "rev-parse", "--verify", "--quiet", name + "^{commit}");
        return r.Code == 0 ? r.Out.Trim() : null;
    }

    // A branch as the user wrote it, or as origin has it.
    public static string Branch(string name) => Commit(name) ?? Commit("origin/" + name);

    // A file's text at a commit, or "" if it was not there.
    public static string Blob(string rev, string path)
    {
        var r = Run(null, "cat-file", "blob", rev + ":" + path);
        return r.Code == 0 ? r.Out : "";
    }
}

class Profile
{
    public string[] Line = new string[0];
    public string[][] Block = new string[0][];
    // "#" opens a comment only at the start of a line or after whitespace, so
    // $# and a URL fragment are not comments.
    public bool LineAfterSpace;
    public string Quotes = "\"";
    public bool Backslash = true;
    // C-style 'x' literals. A quote that does not close right after one
    // character is plain code, which is what a Rust lifetime is.
    public bool Chars;
    public bool Backtick;
    public bool LuaBrackets;
    // A triple-quoted string that starts its line is a docstring: a comment.
    public bool Docstrings;
    public bool CSharp;
    public bool Plain;
}

static class Profiles
{
    static readonly string[][] CBlock = { new[] { "/*", "*/" } };

    // `strings`: single quotes open a string (JavaScript, PHP, ...) rather than a
    // one-character literal (C, Java, Go, Rust, ...). Getting that wrong turns
    // '//' into a comment.
    static Profile CLike(bool backtick = false, bool strings = false) =>
        new Profile
        {
            Line = new[] { "//" },
            Block = CBlock,
            Quotes = strings ? "\"'" : "\"",
            Chars = !strings,
            Backtick = backtick,
        };

    static Profile Hash() =>
        new Profile { Line = new[] { "#" }, LineAfterSpace = true, Quotes = "\"'" };

    static readonly Dictionary<string, Profile> ByExtension = new Dictionary<string, Profile>();
    static readonly Dictionary<string, Profile> ByName = new Dictionary<string, Profile>();

    static void Add(Profile profile, params string[] extensions)
    {
        foreach (var ext in extensions) ByExtension[ext] = profile;
    }

    static Profiles()
    {
        Add(new Profile { CSharp = true }, ".cs", ".csx");
        Add(CLike(), ".c", ".h", ".cpp", ".cc", ".cxx", ".hpp", ".hh", ".hxx", ".cu", ".java", ".kt",
            ".kts", ".scala", ".swift", ".rs", ".zig");
        Add(CLike(strings: true), ".php", ".dart", ".proto", ".jsonc", ".scss", ".less");
        // Backticks open a string that may span lines in these.
        Add(CLike(true), ".go");
        Add(CLike(true, true), ".js", ".jsx", ".mjs", ".cjs", ".ts", ".tsx", ".mts", ".cts");
        Add(new Profile { Block = CBlock, Quotes = "\"'" }, ".css");
        Add(Hash(), ".sh", ".bash", ".zsh", ".rb", ".yml", ".yaml", ".toml", ".mk", ".pl", ".pm");
        var python = Hash();
        python.Docstrings = true;
        Add(python, ".py", ".pyi");
        Add(new Profile { Line = new[] { "--" }, Quotes = "\"'", LuaBrackets = true }, ".lua");
        Add(new Profile { Line = new[] { "--" }, Block = CBlock, Quotes = "'\"", Backslash = false }, ".sql");
        Add(new Profile { Block = new[] { new[] { "<!--", "-->" } }, Quotes = "" },
            ".xml", ".xaml", ".axaml", ".html", ".htm", ".svg", ".csproj", ".vbproj", ".fsproj", ".props",
            ".targets", ".config", ".resx", ".nuspec", ".xsd", ".xslt");
        // No comment syntax at all: counting these as code is right, not a gap.
        Add(new Profile { Plain = true }, ".json", ".csv", ".tsv");

        foreach (var name in new[] { "makefile", "gnumakefile", "dockerfile", ".gitignore", ".gitattributes",
                                     ".dockerignore", ".editorconfig" })
            ByName[name] = Hash();
    }

    public static string Extension(string name)
    {
        var dot = name.LastIndexOf('.');
        return dot > 0 ? name.Substring(dot).ToLowerInvariant() : "";
    }

    public static Profile For(string path)
    {
        var name = path.Substring(path.LastIndexOf('/') + 1).ToLowerInvariant();
        if (ByName.TryGetValue(name, out var named)) return named;
        return ByExtension.TryGetValue(Extension(name), out var found) ? found : null;
    }
}

static class Lexer
{
    const byte Code = 1, Comment = 2;

    static int Lines(string text)
    {
        var count = 0;
        foreach (var c in text) if (c == '\n') count++;
        return count + 2;
    }

    static bool Starts(string text, string token, int at) =>
        string.CompareOrdinal(text, at, token, 0, token.Length) == 0;

    // 0 for none, 1 for code, 2 for a comment, indexed by line number. A line
    // with both is code.
    public static byte[] Classify(string text, Profile profile) =>
        profile.CSharp ? CSharp(text) : Generic(text, profile);

    static byte[] CSharp(string text)
    {
        var kinds = new byte[Lines(text)];
        int line = 1, i = 0, n = text.Length;

        void Put(byte kind)
        {
            if (kind == Code) kinds[line] = Code;
            else if (kinds[line] == 0) kinds[line] = Comment;
        }
        void Span(byte kind, int from, int to)
        {
            for (var x = from; x < to; x++)
            {
                if (text[x] == '\n') line++;
                else if (!char.IsWhiteSpace(text[x])) Put(kind);
            }
        }

        while (i < n)
        {
            var c = text[i];
            if (c == '\n') { line++; i++; }
            else if (char.IsWhiteSpace(c)) i++;
            else if (Starts(text, "//", i))
            {
                Put(Comment);
                var end = text.IndexOf('\n', i);
                i = end < 0 ? n : end;
            }
            else if (Starts(text, "/*", i))
            {
                var end = text.IndexOf("*/", i + 2, StringComparison.Ordinal);
                end = end < 0 ? n : end + 2;
                Span(Comment, i, end);
                i = end;
            }
            else if (c == '\'')
            {
                var j = i + 1;
                if (j < n && text[j] == '\\')
                {
                    j += 2;
                    while (j < n && text[j] != '\'' && text[j] != '\n') j++;
                }
                else j++;
                var end = j < n && text[j] == '\'' ? Math.Min(j + 1, n) : Math.Min(i + 1, n);
                Span(Code, i, end);
                i = end;
            }
            else if (c == '$' || c == '@' || c == '"')
            {
                var j = i;
                while (j < n && (text[j] == '$' || text[j] == '@')) j++;
                if (j >= n || text[j] != '"')
                {
                    Put(Code);
                    i = j > i ? j : i + 1;
                    continue;
                }
                var verbatim = text.IndexOf('@', i, j - i) >= 0;
                var quotes = 0;
                while (j + quotes < n && text[j + quotes] == '"') quotes++;
                int end;
                if (quotes >= 3)
                {
                    end = text.IndexOf(new string('"', quotes), j + quotes, StringComparison.Ordinal);
                    end = end < 0 ? n : end + quotes;
                }
                else if (quotes == 2) end = j + 2;
                else
                {
                    end = j + 1;
                    while (end < n)
                    {
                        if (text[end] == '\\' && !verbatim) end += 2;
                        else if (text[end] == '"')
                        {
                            if (verbatim && Starts(text, "\"\"", end)) { end += 2; continue; }
                            end++;
                            break;
                        }
                        else if (text[end] == '\n' && !verbatim) break;
                        else end++;
                    }
                    end = Math.Min(end, n);
                }
                Span(Code, i, end);
                i = end;
            }
            else { Put(Code); i++; }
        }
        return kinds;
    }

    static byte[] Generic(string text, Profile p)
    {
        var kinds = new byte[Lines(text)];
        int line = 1, i = 0, n = text.Length;

        void Put(byte kind)
        {
            if (kind == Code) kinds[line] = Code;
            else if (kinds[line] == 0) kinds[line] = Comment;
        }
        void Span(byte kind, int from, int to)
        {
            for (var x = from; x < to; x++)
            {
                if (text[x] == '\n') line++;
                else if (!char.IsWhiteSpace(text[x])) Put(kind);
            }
        }
        // The end of a Lua long bracket opened at `at` ([[ or [==[), or -1.
        int LongBracketEnd(int at)
        {
            if (at >= n || text[at] != '[') return -1;
            var level = 0;
            while (at + 1 + level < n && text[at + 1 + level] == '=') level++;
            if (at + 1 + level >= n || text[at + 1 + level] != '[') return -1;
            var close = "]" + new string('=', level) + "]";
            var end = text.IndexOf(close, at + 2 + level, StringComparison.Ordinal);
            return end < 0 ? n : end + close.Length;
        }
        bool AtLineStart(int at)
        {
            for (var x = at - 1; x >= 0 && text[x] != '\n'; x--)
                if (!char.IsWhiteSpace(text[x])) return false;
            return true;
        }

        while (i < n)
        {
            var c = text[i];
            if (c == '\n') { line++; i++; continue; }
            if (char.IsWhiteSpace(c)) { i++; continue; }

            if (p.LuaBrackets && Starts(text, "--", i))
            {
                var end = LongBracketEnd(i + 2);
                if (end >= 0) { Span(Comment, i, end); i = end; continue; }
            }

            string opener = null;
            foreach (var token in p.Line)
                if (Starts(text, token, i)) { opener = token; break; }
            if (opener != null && (!p.LineAfterSpace || i == 0 || char.IsWhiteSpace(text[i - 1])))
            {
                Put(Comment);
                var end = text.IndexOf('\n', i);
                i = end < 0 ? n : end;
                continue;
            }

            var matched = false;
            foreach (var pair in p.Block)
            {
                if (!Starts(text, pair[0], i)) continue;
                var end = text.IndexOf(pair[1], i + pair[0].Length, StringComparison.Ordinal);
                end = end < 0 ? n : end + pair[1].Length;
                Span(Comment, i, end);
                i = end;
                matched = true;
                break;
            }
            if (matched) continue;

            if (p.Docstrings && (Starts(text, "\"\"\"", i) || Starts(text, "'''", i)))
            {
                var triple = text.Substring(i, 3);
                var end = text.IndexOf(triple, i + 3, StringComparison.Ordinal);
                end = end < 0 ? n : end + 3;
                Span(AtLineStart(i) ? Comment : Code, i, end);
                i = end;
                continue;
            }

            if (p.LuaBrackets && c == '[')
            {
                var end = LongBracketEnd(i);
                if (end >= 0) { Span(Code, i, end); i = end; continue; }
            }

            if (p.Backtick && c == '`')
            {
                var end = i + 1;
                while (end < n && text[end] != '`') end += text[end] == '\\' ? 2 : 1;
                end = Math.Min(end + 1, n);
                Span(Code, i, end);
                i = end;
                continue;
            }

            if (p.Chars && c == '\'')
            {
                var j = i + 1;
                if (j < n && text[j] == '\\')
                {
                    j += 2;
                    while (j < n && text[j] != '\'' && text[j] != '\n') j++;
                }
                else j++;
                var end = j < n && text[j] == '\'' ? Math.Min(j + 1, n) : Math.Min(i + 1, n);
                Span(Code, i, end);
                i = end;
                continue;
            }

            if (p.Quotes.IndexOf(c) >= 0)
            {
                var end = i + 1;
                while (end < n)
                {
                    if (p.Backslash && text[end] == '\\') end += 2;
                    else if (text[end] == c) { end++; break; }
                    else if (text[end] == '\n') break;
                    else end++;
                }
                end = Math.Min(end, n);
                Span(Code, i, end);
                i = end;
                continue;
            }

            Put(Code);
            i++;
        }
        return kinds;
    }
}

static class Rules
{
    static readonly HashSet<string> DocExtensions = new HashSet<string> { ".md", ".mdx", ".rst", ".adoc", ".txt" };
    static readonly string[] DocNames = { "readme", "changelog", "license", "contributing", "authors" };
    static readonly HashSet<string> DocDirs = new HashSet<string> { "doc", "docs" };

    static readonly HashSet<string> TestDirs = new HashSet<string> { "test", "tests", "spec", "specs", "__tests__" };
    static readonly string[] TestProjectSuffixes = { ".tests", ".test", ".unittests", ".integrationtests", ".specs" };
    // fnmatch-style, matched against the lowercased file name.
    static readonly Regex[] TestNames = new[]
    {
        "*_test.*", "test_*.*", "*.test.*", "*.spec.*", "*_spec.*", "*tests.cs", "*test.cs",
    }.Select(Glob).ToArray();
    // The Java and Kotlin convention is a capital T, and `latest.java` is not a test.
    static readonly Regex[] TestNamesExact = new[]
    {
        "*Test.java", "*Tests.java", "*Test.kt", "*Tests.kt",
    }.Select(Glob).ToArray();

    static readonly HashSet<string> GeneratedNames = new HashSet<string>
    {
        "package-lock.json", "npm-shrinkwrap.json", "yarn.lock", "pnpm-lock.yaml", "bun.lock", "bun.lockb",
        "cargo.lock", "poetry.lock", "pipfile.lock", "gemfile.lock", "composer.lock", "go.sum",
        "packages.lock.json", "paket.lock", "gradle.lockfile", "flake.lock",
    };
    static readonly string[] GeneratedSuffixes =
    {
        ".min.js", ".min.css", ".g.cs", ".g.i.cs", ".designer.cs", ".generated.cs", ".pb.go",
    };

    static Regex Glob(string pattern) =>
        new Regex("^" + Regex.Escape(pattern).Replace("\\*", ".*") + "$", RegexOptions.Singleline);

    public static bool IsGenerated(string path)
    {
        var name = path.Substring(path.LastIndexOf('/') + 1).ToLowerInvariant();
        return GeneratedNames.Contains(name) || GeneratedSuffixes.Any(s => name.EndsWith(s, StringComparison.Ordinal));
    }

    public static bool IsDoc(string path)
    {
        var parts = path.ToLowerInvariant().Split('/');
        var name = parts[parts.Length - 1];
        return DocExtensions.Contains(Profiles.Extension(name))
            || DocNames.Any(s => name.StartsWith(s, StringComparison.Ordinal))
            || parts.Take(parts.Length - 1).Any(DocDirs.Contains);
    }

    public static bool IsTest(string path)
    {
        var parts = path.Split('/');
        var dirs = parts.Take(parts.Length - 1).Select(p => p.ToLowerInvariant()).ToArray();
        var name = parts[parts.Length - 1];
        var lower = name.ToLowerInvariant();
        return dirs.Any(TestDirs.Contains)
            || dirs.Any(d => TestProjectSuffixes.Any(s => d.EndsWith(s, StringComparison.Ordinal)))
            || TestNames.Any(r => r.IsMatch(lower))
            || TestNamesExact.Any(r => r.IsMatch(name));
    }

    public static Role RoleOf(string path, Dictionary<string, string> forced)
    {
        if (forced.TryGetValue(path, out var value))
        {
            switch (value)
            {
                case "docs": return Role.Docs;
                case "tests": return Role.Tests;
                case "ignore": return Role.Ignore;
                default: return Role.Source;
            }
        }
        if (IsGenerated(path)) return Role.Ignore;
        if (IsDoc(path)) return Role.Docs;
        if (IsTest(path)) return Role.Tests;
        return Role.Source;
    }

    // What .gitattributes says about each path, for the paths that say
    // something valid. One git call for all of them.
    public static Dictionary<string, string> Forced(IEnumerable<string> paths, List<string> warnings)
    {
        var forced = new Dictionary<string, string>();
        var list = paths.Distinct().ToList();
        if (list.Count == 0) return forced;
        var r = Git.Run(string.Join("\0", list) + "\0", "check-attr", "-z", "--stdin", "lines-changed");
        if (r.Code != 0) return forced;
        var fields = r.Out.Split('\0');
        for (var k = 0; k + 2 < fields.Length; k += 3)
        {
            var value = fields[k + 2];
            if (value == "unspecified" || value == "unset" || value == "set") continue;
            if (value == "code" || value == "docs" || value == "tests" || value == "ignore") forced[fields[k]] = value;
            else warnings.Add($"{fields[k]}: lines-changed={value} is not code, docs, tests or ignore; ignored");
        }
        return forced;
    }
}

static class Diff
{
    // ({path: line numbers}, {path: line numbers}) for the lines `git diff`
    // adds (numbered in the new file) and removes (numbered in the old one).
    //
    // The ---/+++ headers are read only until a file's first hunk: after that
    // a removed line that begins "-- " would look like one.
    public static (Dictionary<string, List<int>> Added, Dictionary<string, List<int>> Removed) ChangedLines(string diff)
    {
        var added = new Dictionary<string, List<int>>();
        var removed = new Dictionary<string, List<int>>();
        string oldPath = null, newPath = null;
        var header = false;

        foreach (var line in diff.Split('\n'))
        {
            if (line.StartsWith("diff --git ", StringComparison.Ordinal))
            {
                header = true;
                oldPath = newPath = null;
            }
            else if (header && line.StartsWith("--- ", StringComparison.Ordinal))
                oldPath = Target(line, "a/");
            else if (header && line.StartsWith("+++ ", StringComparison.Ordinal))
                newPath = Target(line, "b/");
            else if (line.StartsWith("@@", StringComparison.Ordinal))
            {
                header = false;
                var fields = line.Split(' ');
                Add(removed, oldPath, fields[1]);
                Add(added, newPath, fields[2]);
            }
        }
        return (added, removed);
    }

    static string Target(string line, string prefix)
    {
        var target = line.Substring(4).Split('\t')[0];
        if (target == "/dev/null") return null;
        return target.StartsWith(prefix, StringComparison.Ordinal) ? target.Substring(prefix.Length) : target;
    }

    // "-12,3" or "+12" (a count of 1 is left out) -> lines 12, 13, 14.
    static void Add(Dictionary<string, List<int>> into, string path, string range)
    {
        if (path == null) return;
        var parts = range.Substring(1).Split(',');
        var start = int.Parse(parts[0]);
        var count = parts.Length > 1 ? int.Parse(parts[1]) : 1;
        if (!into.TryGetValue(path, out var numbers)) into[path] = numbers = new List<int>();
        for (var n = start; n < start + count; n++) numbers.Add(n);
    }
}

const string Help = @"lines-changed: count the lines a change adds and removes, as code, comments, docs and tests.

  lines-changed [REF]                 the working tree against REF (default BASE): committed work,
                                      uncommitted edits and untracked files
  lines-changed --committed [REF]     committed work only, as a pull request would show it (-c)
  lines-changed --require-clean ...   refuse, with exit status 3, if the working tree has uncommitted work
  lines-changed -u ...                what the default does; kept for scripts that pass it
  lines-changed --json ...            the numbers as JSON, not a markdown table

REF is HEAD, a branch, a tag, a commit, or one of:

  BASE            the merge base of HEAD and the default branch: what a pull request shows
  BASE:<branch>   the merge base of HEAD and <branch>
  BASE~2, BASE^   BASE with the suffixes HEAD takes

The default branch is `git config lines-changed.base`, else origin/HEAD, origin/main, main,
origin/master, master. A plain branch name is that branch's tip, as git reads it.

Prints a markdown table of lines added, removed, and the change between them. Blank lines are not
counted. A file is docs or tests by its path, and the rest is split into comments and code by what
is in it. Lockfiles, minified bundles and generated sources are left out and named on stderr.

Rules for one repository go in .gitattributes:

  docs/old/**       lines-changed=ignore
  tools/**          lines-changed=code
  **/Fixtures/**    lines-changed=tests

Exit status: 0 done, 1 an error, 2 a usage error, 3 --require-clean on a dirty tree.";

// ---------------------------------------------------------------------------
// Arguments
// ---------------------------------------------------------------------------

bool? includeWorking = null;
var requireClean = false;
var asJson = false;
string refArg = null;

foreach (var arg in Args)
{
    switch (arg)
    {
        case "-h":
        case "--help":
            Console.Out.WriteLine(Help);
            return;
        case "-u":
        case "--uncommitted":
            if (includeWorking == false)
                Exit.Now("-u counts uncommitted work and --committed leaves it out; use one or the other", Exit.Usage);
            includeWorking = true;
            break;
        case "-c":
        case "--committed":
            if (includeWorking == true)
                Exit.Now("-u counts uncommitted work and --committed leaves it out; use one or the other", Exit.Usage);
            includeWorking = false;
            break;
        case "--require-clean":
            requireClean = true;
            break;
        case "--json":
            asJson = true;
            break;
        default:
            if (arg.StartsWith('-') || refArg != null)
                Exit.Now("usage: lines-changed [-c | --require-clean] [--json] [REF]", Exit.Usage);
            refArg = arg;
            break;
    }
}

if (includeWorking == true && requireClean)
    Exit.Now("-u counts uncommitted work and --require-clean refuses it; use one or the other", Exit.Usage);
// --require-clean has already refused a dirty tree by the time this matters, and
// a clean one counts the same either way, so it is the committed mode.
var uncommitted = includeWorking ?? !requireClean;
refArg = refArg ?? "BASE";

// ---------------------------------------------------------------------------
// The repository, and whether it is clean
// ---------------------------------------------------------------------------

var top = Git.Run(null, "rev-parse", "--show-toplevel");
if (top.Code != 0) Exit.Now("not inside a git repository");
Git.Root = top.Out.Trim();

// Untracked files that are not ignored count as dirty: they are what the working
// tree adds, so they are what a number with --committed would be missing.
var dirtyFiles = Git.Must("status", "--porcelain", "-z", "--no-renames")
    .Split('\0', StringSplitOptions.RemoveEmptyEntries).Length;

if (requireClean && dirtyFiles > 0)
    Exit.Now($"the working tree has {dirtyFiles} uncommitted file{(dirtyFiles == 1 ? "" : "s")}; "
        + "commit them first, or leave out --require-clean", Exit.Dirty);

// ---------------------------------------------------------------------------
// REF -> a commit
// ---------------------------------------------------------------------------

string oldRev;
var baseMatch = Regex.Match(refArg, @"^BASE(?::([^~^]+))?([~^].*)?$");
if (baseMatch.Success)
{
    string tip;
    if (baseMatch.Groups[1].Success)
    {
        tip = Git.Branch(baseMatch.Groups[1].Value);
        if (tip == null) Exit.Now($"no branch called {baseMatch.Groups[1].Value} (tried origin/ too)");
    }
    else
    {
        tip = null;
        var configured = Git.Run(null, "config", "--get", "lines-changed.base");
        var name = configured.Code == 0 ? configured.Out.Trim() : "";
        if (name != "")
        {
            tip = Git.Branch(name);
            if (tip == null) Exit.Now($"lines-changed.base is {name}, which is not a branch here (tried origin/ too)");
        }
        else
        {
            foreach (var candidate in new[] { "refs/remotes/origin/HEAD", "refs/remotes/origin/main", "refs/heads/main",
                                              "refs/remotes/origin/master", "refs/heads/master" })
            {
                tip = Git.Commit(candidate);
                if (tip != null) break;
            }
            if (tip == null)
                Exit.Now("no origin/HEAD, main or master to compare against; name a base: BASE:<branch>, or a ref");
        }
    }

    var mergeBase = Git.Run(null, "merge-base", tip, "HEAD");
    if (mergeBase.Code != 0) Exit.Now("HEAD and that branch share no history, so there is no merge base");
    oldRev = mergeBase.Out.Trim();
    var suffix = baseMatch.Groups[2].Value;
    if (suffix != "")
    {
        oldRev = Git.Commit(oldRev + suffix);
        if (oldRev == null) Exit.Now($"{refArg} does not name a commit");
    }
}
else
{
    oldRev = Git.Commit(refArg);
    if (oldRev == null) Exit.Now($"unknown revision: {refArg}");
}

// ---------------------------------------------------------------------------
// What changed
// ---------------------------------------------------------------------------

var diffArgs = new List<string> { "diff", "--unified=0", "--no-color", "--no-ext-diff", oldRev };
if (!uncommitted) diffArgs.Add("HEAD");
var (addedLines, removedLines) = Diff.ChangedLines(Git.Must(diffArgs.ToArray()));

if (uncommitted)
{
    // Untracked files are not in any diff. Every line of one is added.
    var untracked = Git.Must("ls-files", "--others", "--exclude-standard", "-z")
        .Split('\0', StringSplitOptions.RemoveEmptyEntries);
    foreach (var path in untracked)
    {
        var text = ReadWorktree(path);
        var count = text.Split('\n').Length;
        if (!addedLines.TryGetValue(path, out var numbers)) addedLines[path] = numbers = new List<int>();
        for (var n = 1; n <= count; n++) numbers.Add(n);
    }
}

string ReadWorktree(string path)
{
    try
    {
        var text = File.ReadAllText(Path.Combine(Git.Root, path));
        return text.Contains('\0') ? "" : text;
    }
    catch (Exception) { return ""; }
}

var warnings = new List<string>();
var forced = Rules.Forced(addedLines.Keys.Concat(removedLines.Keys), warnings);
var roles = new Dictionary<string, Role>();
Role RoleOf(string path)
{
    if (!roles.TryGetValue(path, out var role)) roles[path] = role = Rules.RoleOf(path, forced);
    return role;
}

// ---------------------------------------------------------------------------
// Counting
// ---------------------------------------------------------------------------

var categories = new[] { "Code", "Comments", "Docs", "Tests" };
var added = new int[4];
var removed = new int[4];
var unknown = new SortedSet<string>();
var ignored = new SortedSet<string>();

void Count(int[] totals, Dictionary<string, List<int>> found, Func<string, string> textOf)
{
    foreach (var (path, numbers) in found)
    {
        var role = RoleOf(path);
        if (role == Role.Ignore) { ignored.Add(path); continue; }

        var text = textOf(path);
        if (text.Length > 0 && text[0] == '\uFEFF') text = text.Substring(1);
        var lines = text.Split('\n');
        var wanted = numbers.Where(n => n <= lines.Length && lines[n - 1].Trim().Length > 0).ToList();

        if (role == Role.Docs) totals[2] += wanted.Count;
        else if (role == Role.Tests) totals[3] += wanted.Count;
        else
        {
            var profile = Profiles.For(path);
            if (profile == null || profile.Plain)
            {
                totals[0] += wanted.Count;
                var ext = Profiles.Extension(path.Substring(path.LastIndexOf('/') + 1));
                if (profile == null && wanted.Count > 0 && ext != "") unknown.Add(ext);
                continue;
            }
            var kinds = Lexer.Classify(text, profile);
            foreach (var n in wanted) totals[kinds[n] == 2 ? 1 : 0]++;
        }
    }
}

Count(added, addedLines, uncommitted
    ? (Func<string, string>)ReadWorktree
    : path => Git.Blob("HEAD", path));
Count(removed, removedLines, path => Git.Blob(oldRev, path));

// ---------------------------------------------------------------------------
// Output
// ---------------------------------------------------------------------------

string Signed(int number) => number > 0 ? "+" + number : number.ToString();

var totalAdded = added.Sum();
var totalRemoved = removed.Sum();

if (asJson)
{
    object Row(int plus, int minus) => new { added = plus, removed = minus, change = plus - minus };
    var rows = new Dictionary<string, object>();
    for (var k = 0; k < 4; k++) rows[categories[k]] = Row(added[k], removed[k]);
    Console.Out.WriteLine(JsonSerializer.Serialize(new
    {
        @ref = refArg,
        @base = oldRev,
        against = uncommitted ? "working tree" : "HEAD",
        categories = rows,
        total = Row(totalAdded, totalRemoved),
        ignored,
        unknownExtensions = unknown,
    }, new JsonSerializerOptions { WriteIndented = true }));
}
else
{
    Console.Out.WriteLine("| Category | Added | Removed | Change |");
    Console.Out.WriteLine("|----------|------:|--------:|-------:|");
    for (var k = 0; k < 4; k++)
        Console.Out.WriteLine($"| {categories[k],-8} | {added[k]} | {removed[k]} | {Signed(added[k] - removed[k])} |");
    Console.Out.WriteLine($"| {"Total",-8} | {totalAdded} | {totalRemoved} | {Signed(totalAdded - totalRemoved)} |");
}

// Notes go to stderr after the table, so a caller that pastes stdout gets only
// the table and one that shows both gets the reasons the number is what it is.
if (unknown.Count > 0)
    Console.Error.WriteLine("lines-changed: no comment rules for " + string.Join(", ", unknown) + "; counted as code");
if (ignored.Count > 0)
    Console.Error.WriteLine($"lines-changed: left out {ignored.Count} generated or ignored file{(ignored.Count == 1 ? "" : "s")} "
        + $"({string.Join(", ", ignored.Take(3))}{(ignored.Count > 3 ? ", ..." : "")}); "
        + "lines-changed=code in .gitattributes counts one");
foreach (var warning in warnings)
    Console.Error.WriteLine("lines-changed: " + warning);
if (!uncommitted && dirtyFiles > 0)
    Console.Error.WriteLine($"lines-changed: {dirtyFiles} uncommitted file{(dirtyFiles == 1 ? " is" : "s are")} not counted; "
        + "leave out --committed to count them, --require-clean refuses to run");

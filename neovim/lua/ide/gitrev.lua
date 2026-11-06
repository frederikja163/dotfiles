-- What a revision means: HEAD, a branch, a tag, a commit, and BASE.
--
-- This is the same grammar as bin/lines-changed, written a second time because
-- one is C# and one is Lua, and the two have to agree: a review of BASE and a
-- line count of BASE are the same change, and the numbers are quoted next to
-- each other in a pull request. tests/nvim/test_review.lua checks that by
-- asking the tool what base it resolved (`lines-changed --json` says) and
-- comparing it with what this resolves, over the same repository.
--
--   HEAD, a branch, a tag, a commit   exactly what git says
--   BASE                              the merge base of HEAD and the default
--                                     branch: where this branch left it, which
--                                     is what a pull request shows
--   BASE:<branch>                     the merge base of HEAD and <branch>, for
--                                     a pull request aimed somewhere else
--   BASE~2, BASE^, BASE:dev~1         the suffixes HEAD takes
--
-- A plain branch name is that branch's tip, as git reads it. It used to mean
-- "where this branch left it" -- `:Review main` compared against the merge base
-- -- and that is now spelled BASE, because the other meaning had no spelling at
-- all: there was no way to ask for main as it is today.
--
-- The default branch is, in order: `git config lines-changed.base`, then
-- origin/HEAD, origin/main, main, origin/master, master. The key keeps the name
-- the tool gave it, so that setting it once changes both.
--
-- Everything here shells out and waits. A revision is a few milliseconds of
-- git, and the caller is a command or a key that cannot go on without the
-- answer.

local M = {}

local function git(args, cwd)
    local cmd = { 'git', '-c', 'core.quotepath=off' }
    vim.list_extend(cmd, args)
    local ok, result = pcall(function()
        return vim.system(cmd, { text = true, cwd = cwd }):wait()
    end)
    if not ok then
        return 127, '', tostring(result)
    end
    return result.code, vim.trim(result.stdout or ''), vim.trim(result.stderr or '')
end

--- The commit a name points at, or nil.
---@param name string
---@param cwd? string
---@return string?
function M.commit(name, cwd)
    local code, out = git({ 'rev-parse', '--verify', '--quiet', name .. '^{commit}' }, cwd)
    if code == 0 and out ~= '' then
        return out
    end
end

--- A branch as written, or as origin has it.
---@param name string
---@param cwd? string
---@return string?
function M.branch(name, cwd)
    return M.commit(name, cwd) or M.commit('origin/' .. name, cwd)
end

--- The default branch: its tip commit and a name for it.
---@param cwd? string
---@return string? tip
---@return string? name_or_error
function M.default_branch(cwd)
    local code, configured = git({ 'config', '--get', 'lines-changed.base' }, cwd)
    if code == 0 and configured ~= '' then
        local tip = M.branch(configured, cwd)
        if not tip then
            return nil, ('lines-changed.base is %s, which is not a branch here (tried origin/ too)'):format(configured)
        end
        return tip, configured
    end
    for _, candidate in ipairs({
        'refs/remotes/origin/HEAD', 'refs/remotes/origin/main', 'refs/heads/main',
        'refs/remotes/origin/master', 'refs/heads/master',
    }) do
        local tip = M.commit(candidate, cwd)
        if tip then
            local _, short = git({ 'rev-parse', '--abbrev-ref', candidate }, cwd)
            return tip, short ~= '' and short or candidate
        end
    end
    return nil, 'no origin/HEAD, main or master to compare against; name a base: BASE:<branch>, or a ref'
end

--- Whether `spec` is spelled as a BASE (and so is not a branch called BASEBALL).
---@param spec string
---@return string? branch  the part after BASE:, or '' for none
---@return string? suffix  ~2, ^ and so on, or ''
local function parse_base(spec)
    local rest = spec:match('^BASE(.*)$')
    if not rest then
        return nil
    end
    local branch = ''
    if rest:sub(1, 1) == ':' then
        local name, tail = rest:match('^:([^~^]+)(.*)$')
        if not name then
            return nil
        end
        branch, rest = name, tail
    end
    if rest ~= '' and not rest:match('^[~^]') then
        return nil
    end
    return branch, rest
end

--- Resolve a revision to a commit.
---@param spec? string  nil or '' means HEAD
---@param cwd? string
---@return { commit: string, label: string }? resolved
---@return string? err
function M.resolve(spec, cwd)
    if spec == nil or spec == '' then
        spec = 'HEAD'
    end

    local branch, suffix = parse_base(spec)
    if branch == nil then
        local commit = M.commit(spec, cwd)
        if not commit then
            return nil, 'unknown revision: ' .. spec
        end
        return { commit = commit, label = spec }
    end

    local tip
    if branch ~= '' then
        tip = M.branch(branch, cwd)
        if not tip then
            return nil, ('no branch called %s (tried origin/ too)'):format(branch)
        end
    else
        local err
        tip, err = M.default_branch(cwd)
        if not tip then
            return nil, err
        end
    end

    local code, base = git({ 'merge-base', tip, 'HEAD' }, cwd)
    if code ~= 0 or base == '' then
        return nil, 'HEAD and that branch share no history, so there is no merge base'
    end
    if suffix ~= '' then
        local shifted = M.commit(base .. suffix, cwd)
        if not shifted then
            return nil, spec .. ' does not name a commit'
        end
        base = shifted
    end
    return { commit = base, label = spec }
end

--- Refs worth offering for a revision argument, filtered by what is typed.
---@param lead string
---@param cwd? string
---@return string[]
function M.complete(lead, cwd)
    local _, out = git({ 'for-each-ref', '--format=%(refname:short)' }, cwd)
    local refs = { 'HEAD', 'BASE' }
    for ref in out:gmatch('[^\n]+') do
        if not ref:match('/HEAD$') then
            table.insert(refs, ref)
        end
    end
    -- After "BASE:" only branches make sense, and they keep the prefix.
    if lead:sub(1, 5) == 'BASE:' then
        refs = {}
        local _, heads = git({ 'for-each-ref', '--format=%(refname:short)', 'refs/heads', 'refs/remotes' }, cwd)
        for ref in heads:gmatch('[^\n]+') do
            if not ref:match('/HEAD$') then
                table.insert(refs, 'BASE:' .. ref)
            end
        end
    end
    return vim.tbl_filter(function(ref)
        return vim.startswith(ref, lead)
    end, refs)
end

--- Everything the base picker lists: HEAD, BASE, then branches, tags and the
--- recent commits, each with what makes it recognisable.
---@param cwd? string
---@return { ref: string, text: string }[]
function M.picker_items(cwd)
    local items = {}
    local function add(ref, kind, detail)
        table.insert(items, { ref = ref, text = ('%-24s %-8s %s'):format(ref, kind, detail or '') })
    end

    add('HEAD', 'commit', 'uncommitted work: everything not yet committed')
    local _, name = M.default_branch(cwd)
    if M.default_branch(cwd) then
        add('BASE', 'merge', ('everything this branch added since it left %s'):format(name))
    end

    local _, refs = git({
        'for-each-ref', '--sort=-committerdate',
        '--format=%(refname)%09%(refname:short)%09%(subject)%09%(committerdate:relative)',
        'refs/heads', 'refs/remotes', 'refs/tags',
    }, cwd)
    for line in refs:gmatch('[^\n]+') do
        local full, short, subject, when = line:match('^([^\t]*)\t([^\t]*)\t([^\t]*)\t(.*)$')
        if full and not full:match('/HEAD$') then
            local kind = full:match('^refs/tags/') and 'tag' or full:match('^refs/remotes/') and 'remote' or 'branch'
            add(short, kind, ('%s (%s)'):format(subject, when))
        end
    end

    local _, log = git({ 'log', '-n', '40', '--format=%h%x09%s%x09%cr' }, cwd)
    for line in log:gmatch('[^\n]+') do
        local hash, subject, when = line:match('^([^\t]*)\t([^\t]*)\t(.*)$')
        if hash then
            add(hash, 'commit', ('%s (%s)'):format(subject, when))
        end
    end
    return items
end

return M

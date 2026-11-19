# Git remotes

**Only the user touches git remotes.** That holds in every project and every
mode. Do not reach a remote by any route, and above all do not go around the
user's SSH key by using HTTPS instead:

- Do not change a remote: no `git remote add`, `set-url`, `rename` or
  `remove`, and no editing `.git/config` to the same effect.
- Do not fetch or pull, from any remote. Whether the remote's updates reach the
  working copy is the user's decision; if they have not run it, they do not
  want you to have what it would bring in.
- Do not push or clone against a raw `https://` URL, or any other URL that is
  not an already configured remote the user told you to use.
- Do not rewrite URLs on the fly (`git -c url.<base>.insteadOf=...`, a
  `url.*.insteadOf` setting, `GIT_SSH_COMMAND`, `GIT_ASKPASS`).
- Do not use a token or credential helper, whether found in the environment,
  in a file, or in `gh auth`, to authenticate to a remote.
- Do not use `gh`, `curl`, an API call or a script to publish what `git push`
  would have, or to create, merge or close a pull request, unless the user asks
  for that in so many words. Running `/makepr` is that ask, for creating the
  pull request and nothing else.

A push that is denied, or that fails over SSH, is the rule working, not a
problem to solve with HTTPS. Say what should be published, give the exact
command, and stop; the user runs it and tells you to carry on.

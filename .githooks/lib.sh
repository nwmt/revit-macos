# Shared rules for the git hooks. Sourced, not executed.
# Same rules as our other repos: Conventional Commits, English only, no AI signatures,
# branches named "type/kebab-case".

TYPES='feat|fix|perf|refactor|style|docs|chore|test|ci|build'
KEBAB='[a-z0-9]+(-[a-z0-9]+)*'
# Exit 0 if stdin has Cyrillic (U+0400..U+04FF); prints the offending lines with -v.
has_cyrillic() { perl -CSD -ne 'if (/[\x{0400}-\x{04FF}]/) { $f = 1; print if $ENV{SHOW} } END { exit !$f }'; }

branch_ok() { # $1 = branch name
  [ "$1" = main ] && return 0
  printf '%s\n' "$1" | grep -Eq "^($TYPES)(/$KEBAB)+$"
}

branch_help() {
  echo "Branch names must be \"main\" or \"type/kebab-case-description\"." >&2
  echo "Allowed types: ${TYPES//|/, }" >&2
}

# Personal values come from this machine, never from a file in the repo,
# so the denylist itself cannot leak. Extra words: one per line in .git/info/denylist.
personal_patterns() {
  printf '%s\n' "$HOME"
  # stock Apple names ("MacBook", "MacBook-Pro", "iMac") identify no one and appear in docs
  hostname -s 2>/dev/null | grep -Eiv '^(macbook|macbook-air|macbook-pro|imac|mac-mini|mac-studio|mac-pro|localhost)$'
  git config user.email 2>/dev/null | grep -v 'users.noreply.github.com'
  [ -f "$(git rev-parse --git-dir)/info/denylist" ] && grep -v '^\s*\(#\|$\)' "$(git rev-parse --git-dir)/info/denylist"
  return 0
}

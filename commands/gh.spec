# gh -- GitHub CLI.
#
# The subcommands are named rather than pattern-matched. A shim that guesses
# which ones carry text is one release away from either missing a new one in
# silence or blocking one that never carried any, and only the first failure is
# visible.

SPEC_MATCH="
  pr:create pr:edit pr:comment pr:review
  issue:create issue:edit issue:comment
  release:create release:edit
  gist:create
"

SPEC_TEXT_FLAGS="-t --title -b --body -n --notes -d --description"
SPEC_FILE_FLAGS="-F --body-file --notes-file"
SPEC_TARGET_FLAGS="-R --repo"

# --fill takes the body from commit messages, which commit-msg already guarded
# on the way in. Checking it again would refuse text that is already published
# and cannot be edited, which teaches the wrong lesson about the guard.
SPEC_SKIP_FLAGS="--fill --fill-first --fill-verbose"
SPEC_WEB_FLAGS="-w --web"
SPEC_EDITOR_ENV="GH_EDITOR"

spec_target() {
    "$ENGINE_REAL" repo view --json nameWithOwner --jq .nameWithOwner 2>/dev/null
}

_gh_visibility() {
    "$ENGINE_REAL" api "repos/$1" --jq .visibility 2>/dev/null
}

spec_in_scope() {
    [ "$(shim_cached_visibility "$ENGINE_TARGET" _gh_visibility "$ENGINE_TARGET")" = public ]
}

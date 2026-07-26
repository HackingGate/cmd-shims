# glab -- GitLab CLI.
#
# The same shapes under different names, which is the argument for the spec: a
# merge request is a pull request, a note is a comment, and `--description` is
# `--body`. None of that difference is worth a second program.

SPEC_MATCH="
  mr:create mr:update mr:note
  issue:create issue:update issue:note
  release:create release:update
  snippet:create
"

SPEC_TEXT_FLAGS="-t --title -d --description -m --message -n --name"
SPEC_FILE_FLAGS="--description-file --notes-file"
SPEC_TARGET_FLAGS="-R --repo"
SPEC_SKIP_FLAGS="--fill --fill-commit-body"
SPEC_WEB_FLAGS="-w --web"
SPEC_EDITOR_ENV="GLAB_EDITOR"

spec_target() {
    "$ENGINE_REAL" repo view --output json 2>/dev/null \
        | sed -n 's/.*"path_with_namespace"[[:space:]]*:[[:space:]]*"\([^"]*\)".*/\1/p' \
        | head -1
}

# GitLab's visibility vocabulary has three values, and only one of them is the
# one this guard cares about. `internal` is not public to the internet but is
# public to everyone with an account, which is not a distinction worth betting a
# private repository's name on -- so only `public` counts as public, and
# anything else, including an answer that never arrives, means exec through.
_glab_visibility() {
    local encoded="${1//\//%2F}"
    "$ENGINE_REAL" api "projects/$encoded" 2>/dev/null \
        | sed -n 's/.*"visibility"[[:space:]]*:[[:space:]]*"\([a-z]*\)".*/\1/p' \
        | head -1
}

spec_in_scope() {
    [ "$(shim_cached_visibility "$ENGINE_TARGET" _glab_visibility "$ENGINE_TARGET")" = public ]
}

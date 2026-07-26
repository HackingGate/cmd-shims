# npm -- and the reason `spec_in_scope` is not `is the repository public`.
#
# `npm publish` puts a directory on a registry the whole world can read. There
# is no repository, no owner and no visibility endpoint anywhere in that
# sentence: what decides whether anyone should care is a field in package.json
# and whether the registry is the public one. A forge CLI's question does not
# fit, and bending it to fit is how a framework quietly becomes the shape of its
# first two examples.
#
# It is also the case where the subject is not prose. What goes out is a FILE
# TREE -- README, description, keywords, and anything not excluded by files/
# .npmignore. So the subject kinds here are `text` for the metadata and `path`
# for the tree, and a checker is told which it is holding.

SPEC_MATCH="publish:* pack:*"

# --tag/--access are npm's own words and carry nothing publishable; the text
# that matters is in package.json, gathered below.
SPEC_TARGET_FLAGS="--registry"
SPEC_SKIP_FLAGS="--dry-run"

_npm_field() {
    # Deliberately not `npm pkg get`: that runs npm, and this shim is what npm
    # is currently behind. Reading the file is also what publish itself does.
    sed -n "s/.*\"$1\"[[:space:]]*:[[:space:]]*\"\([^\"]*\)\".*/\1/p" package.json 2>/dev/null | head -1
}

engine_collect() {
    ENGINE_BODY_GIVEN=1   # npm opens no editor

    local args=("$@") i=0
    while [ "$i" -lt "${#args[@]}" ]; do
        case "${args[$i]}" in
            --registry) ENGINE_TARGET="${args[$((i + 1))]:-}"; i=$((i + 2)); continue ;;
            --registry=*) ENGINE_TARGET="${args[$i]#*=}" ;;
            # A dry run publishes nothing, and refusing one would stop the very
            # command somebody runs to find out what they are about to publish.
            --dry-run) ENGINE_DRY_RUN=1 ;;
        esac
        i=$((i + 1))
    done

    [ "${ENGINE_DRY_RUN:-0}" = 1 ] && return 0

    local v
    for v in name description; do
        engine_add_subject text "$(_npm_field "$v")"
    done
    [ -f README.md ] && engine_add_subject text "$(cat README.md)"
    engine_add_subject path "$PWD"
    return 0
}

# Two independent reasons this is nobody's business, and either one is enough:
# a package marked private cannot be published at all, and a registry that is
# not the public one is somebody's internal infrastructure.
spec_in_scope() {
    [ "${ENGINE_DRY_RUN:-0}" != 1 ] || return 1
    grep -q '"private"[[:space:]]*:[[:space:]]*true' package.json 2>/dev/null && return 1
    case "${ENGINE_TARGET:-https://registry.npmjs.org}" in
        *registry.npmjs.org*) return 0 ;;
        *) return 1 ;;
    esac
}

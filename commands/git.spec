# git -- the case that proves the spec is not just a flag table.
#
# git publishes text that no git hook is in a position to read:
#
#   * BRANCH AND TAG NAMES. `git push origin fix/acme-outage` puts that name on
#     a public forge, in the ref list, in the PR title it suggests, and in every
#     notification. pre-push is handed the refs, but the guards that read them
#     judge the DESTINATION -- an owner allow-list -- and never the name itself.
#   * A COMMIT MESSAGE UNDER --no-verify, which is the one path that exists
#     precisely to skip commit-msg. A guard that only runs when it is not
#     skipped is not a guard, and this is the flag an agent reaches for the
#     moment a hook says no.
#
# Its text is positional rather than a flag value, so this spec replaces
# engine_collect outright. That override is the whole reason the engine looks
# for it: a command whose grammar does not fit should cost one function, not a
# fork of the shim.

SPEC_MATCH="push:* commit:*"

# git's own editor is already covered: a message written in it passes through
# commit-msg. The gap here is the message that deliberately does not.
SPEC_EDITOR_ENV=""

_git_ref_names() {
    local args=("$@") i=1 arg seen_remote=0 found=0
    while [ "$i" -lt "${#args[@]}" ]; do
        arg="${args[$i]}"
        case "$arg" in
            -*) i=$((i + 1)); continue ;;
        esac
        if [ "$seen_remote" = 0 ]; then
            seen_remote=1
        else
            # A refspec is `src:dst`; both halves are published, and `refs/heads/`
            # is noise rather than name.
            printf '%s\n' "${arg%%:*}" "${arg#*:}" | sed 's#^refs/[a-z]*/##'
            found=1
        fi
        i=$((i + 1))
    done
    # With no refspec, git pushes the current branch, so that is the name going
    # out even though it appears nowhere in argv.
    [ "$found" = 1 ] || git symbolic-ref --short HEAD 2>/dev/null
}

engine_collect() {
    ENGINE_BODY_GIVEN=1   # never hand git an editor; see above

    local args=("$@") i=1 arg next no_verify=0 name

    if [ "${1:-}" = commit ]; then
        while [ "$i" -lt "${#args[@]}" ]; do
            arg="${args[$i]}"; next="${args[$((i + 1))]:-}"
            case "$arg" in
                -n | --no-verify) no_verify=1; i=$((i + 1)) ;;
                -m | --message) engine_add_subject text "$next"; i=$((i + 2)) ;;
                --message=*) engine_add_subject text "${arg#*=}"; i=$((i + 1)) ;;
                -F | --file) [ -f "$next" ] && engine_add_subject text "$(cat "$next")"; i=$((i + 2)) ;;
                *) i=$((i + 1)) ;;
            esac
        done
        # Without --no-verify the message meets commit-msg on its way through,
        # and checking it twice only produces two places to disagree.
        if [ "$no_verify" != 1 ]; then
            ENGINE_SUBJECT_KINDS=(); ENGINE_SUBJECT_VALUES=()
        fi
    else
        while IFS= read -r name; do
            # Kind `ref`, not `text`: a checker that greps prose for a private
            # name and one that judges a branch name are not the same checker,
            # and only the kind tells them apart.
            [ -n "$name" ] && engine_add_subject ref "$name"
        done < <(_git_ref_names "$@")
    fi

    ENGINE_TARGET="$(_git_target_repo "$@")"
    return 0
}

_git_remote_name() {
    local args=("$@") i=1 arg
    while [ "$i" -lt "${#args[@]}" ]; do
        arg="${args[$i]}"
        case "$arg" in
            -*) ;;
            *) printf '%s\n' "$arg"; return 0 ;;
        esac
        i=$((i + 1))
    done
    printf 'origin\n'
}

_git_target_repo() {
    local remote url path
    if [ "${1:-}" = push ]; then
        remote="$(_git_remote_name "$@")"
    else
        remote=origin
    fi
    url="$(git remote get-url "$remote" 2>/dev/null)" || return 1

    url="${url%%#*}"; url="${url%%\?*}"
    if [[ "$url" =~ ^[^@/:]+@[^:]+:(.+)$ ]]; then
        path="${BASH_REMATCH[1]}"
    elif [[ "$url" =~ ^[a-z]+://([^/@]+@)?[^/]+/(.+)$ ]]; then
        path="${BASH_REMATCH[2]}"
    else
        return 1
    fi
    path="${path#/}"; path="${path%/}"; path="${path%.git}"
    [[ "$path" =~ ^[A-Za-z0-9][A-Za-z0-9._-]*/[A-Za-z0-9._/-]+$ ]] || return 1
    printf '%s\n' "$path"
}

spec_target() { _git_target_repo "$@"; }

# git itself cannot answer this, so the question goes to whichever forge CLI is
# present. With neither, there is no answer and the engine execs through --
# which is right: refusing a push because a visibility lookup was unavailable
# would make the guard the reason work stops.
spec_in_scope() {
    [ -n "$ENGINE_TARGET" ] || return 1
    command -v gh >/dev/null 2>&1 || return 1
    [ "$(shim_cached_visibility "$ENGINE_TARGET" gh api "repos/$ENGINE_TARGET" --jq .visibility)" = public ]
}

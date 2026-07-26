#!/usr/bin/env bash
# The part of a shim that is the same for every command.
#
# Adding a command should not mean writing a program, and it should not mean
# forking this repository either. A spec declares what makes one command
# different; this engine does the rest:
#
#   1. is the shim switched off?                 -> exec through
#   2. does this invocation match the spec?      -> else exec through
#   3. collect the SUBJECTS it puts at risk
#   4. is this invocation in scope?              -> else exec through
#   5. will the subject be written in an editor? -> hand over our editor
#   6. run the checkers over every subject
#   7. refuse, or become the real command
#
# Two things are deliberately NOT assumed, because assuming them is what makes a
# framework fit exactly the commands it was written for and nothing after:
#
#   * that a subject is TEXT. A subject has a kind -- text, path, ref, target,
#     argv -- and the checker is told which it is holding. `npm publish` risks a
#     file tree, `git push` risks a branch name, `gh pr create` risks prose. One
#     interception, different nouns.
#   * that scope means A PUBLIC REPOSITORY. That is one predicate: natural for a
#     forge CLI, meaningless for a package manager or a deploy tool. A spec
#     answers `spec_in_scope` however it likes, and forge visibility is a
#     library function it MAY call rather than a shape it must fit.
#
# Every step that cannot reach an answer leaves by the same door: exec through.
# A shim stands in front of a tool nobody asked to have mediated, so "I could
# not tell" has to mean "carry on".

# ---- what a spec may declare -------------------------------------------------
: "${SPEC_MATCH:=}"         # invocations to inspect: `verb:noun`, `verb:*`, or `*`
: "${SPEC_TEXT_FLAGS:=}"    # flags whose VALUE is a text subject
: "${SPEC_FILE_FLAGS:=}"    # flags whose value NAMES a file of text (`-` is stdin)
: "${SPEC_PATH_FLAGS:=}"    # flags whose value is a filesystem path subject
: "${SPEC_TARGET_FLAGS:=}"  # flags naming where this is going
: "${SPEC_SKIP_FLAGS:=}"    # flags supplying a subject from an already-guarded source
: "${SPEC_WEB_FLAGS:=}"     # flags that move authoring into a browser
: "${SPEC_ARGV_SUBJECT:=0}" # 1 to hand checkers the whole command line as well
: "${SPEC_EDITOR_ENV:=}"    # env var this command reads to find its editor

# A spec that declares no scope predicate is always in scope: the right default
# for a command with no notion of a destination. A spec that HAS one says so,
# rather than inheriting a forge's idea of the question.
spec_in_scope() { return 0; }

# Where this invocation is going, when that is a meaningful question at all.
spec_target() { return 1; }

engine_in_list() {
    local needle="$1" item
    for item in $2; do
        [ "$item" != "$needle" ] || return 0
    done
    return 1
}

# Step 2. A spec may override when its grammar is not `verb noun`.
engine_matches() {
    engine_in_list '*' "$SPEC_MATCH" && return 0
    engine_in_list "${1:-}:${2:-}" "$SPEC_MATCH" && return 0
    engine_in_list "${1:-}:*" "$SPEC_MATCH" && return 0
    return 1
}

# ---- subjects ----------------------------------------------------------------
# Parallel arrays rather than a struct, because this has to work in the bash a
# distribution ships rather than the one somebody upgraded to.
engine_add_subject() {
    ENGINE_SUBJECT_KINDS+=("$1")
    ENGINE_SUBJECT_VALUES+=("$2")
}

# Step 3. Walk argv once. A spec whose subjects are not flag values replaces
# this outright -- `git push` publishes branch names, which are positional.
engine_collect() {
    local args=("$@") i=0 arg next flag value paired

    while [ "$i" -lt "${#args[@]}" ]; do
        arg="${args[$i]}"
        next="${args[$((i + 1))]:-}"

        # `--flag=value` and `--flag value` are the same flag. Splitting here
        # means every list a spec writes is written once, in the spelling a
        # person would use.
        if [[ "$arg" == --*=* ]]; then
            flag="${arg%%=*}"; value="${arg#*=}"; paired=1
        else
            flag="$arg"; value="$next"; paired=0
        fi

        if engine_in_list "$flag" "$SPEC_TARGET_FLAGS"; then
            ENGINE_TARGET="$value"
        elif engine_in_list "$flag" "$SPEC_TEXT_FLAGS"; then
            engine_add_subject text "$value"; ENGINE_BODY_GIVEN=1
        elif engine_in_list "$flag" "$SPEC_PATH_FLAGS"; then
            engine_add_subject path "$value"
        elif engine_in_list "$flag" "$SPEC_FILE_FLAGS"; then
            ENGINE_BODY_GIVEN=1
            if [ "$value" = "-" ]; then
                # Reading stdin here means the real command can no longer read
                # it, so it is kept and replayed on the way through. A guard
                # that silently eats the body it approved is worse than none.
                ENGINE_STDIN_FILE="$(mktemp)" || return 1
                cat > "$ENGINE_STDIN_FILE"
                engine_add_subject text "$(cat "$ENGINE_STDIN_FILE")"
            elif [ -f "$value" ]; then
                engine_add_subject text "$(cat "$value")"
            fi
        elif engine_in_list "$flag" "$SPEC_SKIP_FLAGS"; then
            ENGINE_BODY_GIVEN=1
        elif engine_in_list "$flag" "$SPEC_WEB_FLAGS"; then
            ENGINE_WEB=1
        else
            i=$((i + 1)); continue
        fi

        if [ "$paired" = 1 ]; then i=$((i + 1)); else i=$((i + 2)); fi
    done
    return 0
}

engine_replay_stdin() {
    [ -z "${ENGINE_STDIN_FILE:-}" ] || exec < "$ENGINE_STDIN_FILE"
}

# ---- steps 1-7 ---------------------------------------------------------------
engine_main() {
    local name="$1"; shift

    [ "${CMD_SHIMS_DISABLE:-}" != "1" ] || shim_exec_real "$name" "$@"
    engine_matches "${1:-}" "${2:-}" || shim_exec_real "$name" "$@"

    # Exported because the spec functions sourced beside this engine call it.
    export ENGINE_REAL
    ENGINE_REAL="$(shim_real_command "$name")" || {
        printf '%s-shim: no %s on PATH behind this shim\n' "$name" "$name" >&2
        exit 127
    }

    ENGINE_SUBJECT_KINDS=()
    ENGINE_SUBJECT_VALUES=()
    ENGINE_TARGET=""
    ENGINE_BODY_GIVEN=0
    ENGINE_WEB=0
    ENGINE_STDIN_FILE=""

    engine_collect "$@" || shim_exec_real "$name" "$@"

    [ -n "$ENGINE_TARGET" ] || ENGINE_TARGET="$(spec_target "$@" || true)"
    export ENGINE_TARGET
    export ENGINE_SUBCOMMAND="${1:-}"

    spec_in_scope "$@" || { engine_replay_stdin; shim_exec_real "$name" "$@"; }

    [ "$SPEC_ARGV_SUBJECT" != 1 ] || engine_add_subject argv "$*"

    # With no subject in argv the command opens an editor and the text never
    # reaches us at all -- which is how most bodies are actually written. The
    # editor becomes the checkpoint instead: ours runs theirs, then reads the
    # file, and a non-zero exit aborts the command the way a commit-msg hook
    # aborts a commit.
    if [ "$ENGINE_BODY_GIVEN" = 0 ] && [ "$ENGINE_WEB" = 0 ] && [ -n "$SPEC_EDITOR_ENV" ]; then
        local current="${!SPEC_EDITOR_ENV:-}"
        export CMD_SHIMS_REAL_EDITOR="${current:-${GIT_EDITOR:-${VISUAL:-${EDITOR:-vi}}}}"
        export "$SPEC_EDITOR_ENV=$SHIM_ROOT/shims/editor-guard"
        shim_exec_real "$name" "$@"
    fi

    [ "$ENGINE_WEB" = 0 ] || printf \
        '%s-shim: this writes the body in a browser; this tier cannot see it.\n' "$name" >&2

    local rc=0 i kind value
    for i in ${ENGINE_SUBJECT_VALUES+"${!ENGINE_SUBJECT_VALUES[@]}"}; do
        kind="${ENGINE_SUBJECT_KINDS[$i]}"
        value="${ENGINE_SUBJECT_VALUES[$i]}"
        [ -n "$value" ] || continue
        shim_check_subject "$kind" "$value"
        case $? in
            0) ;;
            1) rc=1 ;;
            2) shim_warn_no_checkers ;;
        esac
    done

    if [ "$rc" != 0 ]; then
        printf '\n%s-shim: refused. Fix it, or re-run with CMD_SHIMS_DISABLE=1.\n' "$name" >&2
        exit 1
    fi

    engine_replay_stdin
    shim_exec_real "$name" "$@"
}

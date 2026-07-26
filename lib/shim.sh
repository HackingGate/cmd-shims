#!/usr/bin/env bash
# Shared machinery for every shim in this repository.
#
# A shim is a program that takes a command's name on PATH, decides whether the
# invocation is one anybody wants to inspect, and then becomes the real command.
# PATH is the seam it uses, and PATH is the reason this exists: it is the one
# interception point that every caller traverses. A shell function covers one
# shell, an editor hook covers one editor, and an agent hook covers one agent --
# while every one of them ultimately execs a binary.

# Locate the real command this shim is standing in front of.
#
# Walking PATH and skipping ourselves is what makes the shim installable as a
# symlink named after its target. The comparison is on the resolved path, not
# the name: `~/.local/bin/gh -> .../shims/gh` and `/usr/bin/gh` are both named
# `gh`, and only one of them is us.
shim_real_command() {
    local name="$1" self dir candidate
    self="$(shim_realpath "${SHIM_SELF:-$0}")"

    local IFS=:
    for dir in $PATH; do
        [ -n "$dir" ] || continue
        candidate="$dir/$name"
        [ -x "$candidate" ] || continue
        [ "$(shim_realpath "$candidate")" != "$self" ] || continue
        printf '%s\n' "$candidate"
        return 0
    done
    return 1
}

shim_realpath() {
    if command -v realpath >/dev/null 2>&1; then
        realpath "$1" 2>/dev/null || printf '%s\n' "$1"
    else
        # Portable enough for the case that matters: a symlink chain in ~/bin.
        local p="$1"
        while [ -L "$p" ]; do p="$(readlink "$p")"; done
        printf '%s\n' "$p"
    fi
}

# Become the real command. Nothing after this line runs.
#
# Every path that cannot reach a verdict ends here rather than in a refusal. A
# shim sits in front of a tool its user did not ask to have mediated, so its
# failure mode has to be "the tool works" -- a guard that bricks `gh` when its
# own parser trips gets uninstalled within the hour, and then guards nothing.
# The tier that must not fail open is the one running in CI, which no shim can
# be talked out of.
shim_exec_real() {
    local name="$1"; shift
    local real
    real="$(shim_real_command "$name")" || {
        printf '%s: no %s found on PATH behind this shim\n' "${SHIM_NAME:-shim}" "$name" >&2
        exit 127
    }
    exec "$real" "$@"
}

# Every checker this shim consults, from the same places a spec comes from.
#
# A repository that can describe its own commands but cannot supply its own
# checkers is only half extensible, and the half it is missing is the one that
# holds the policy. `.cmd-shims/checks` is also the right home for the checker
# that knows something confidential: a private repository can hold the list of
# what must not be published, and a public one cannot.
#
# Unlike specs, checkers do not shadow each other -- ALL of them run. A spec is
# a description of one command and the nearest wins; a checker is an opinion
# about what may be published, and a nearer file must not be able to silently
# switch off one further away.
#
# A checker is any executable. It receives the subject on stdin, exits 0 to
# allow and non-zero to refuse, and whatever it writes becomes the reason shown
# to whoever ran the command -- on stderr, wherever the checker wrote it, for
# the reason in shim_check_subject.
#
# These are the checkers a repository SUPPLIED. The ones it merely ENABLED --
# the bundled set in checks/base/ -- are added by shim_checkers below.
shim_checks_path() {
    local dir
    local IFS=:
    for dir in ${CMD_SHIMS_CHECKS:-}; do
        [ -n "$dir" ] && printf '%s\n' "$dir"
    done
    unset IFS

    dir="$PWD"
    while [ -n "$dir" ] && [ "$dir" != / ]; do
        [ -d "$dir/.cmd-shims/checks" ] && printf '%s\n' "$dir/.cmd-shims/checks"
        dir="${dir%/*}"
    done

    printf '%s\n' "${XDG_CONFIG_HOME:-$HOME/.config}/cmd-shims/checks"
    [ -n "${SHIM_CHECKS_DIR:-}" ] && printf '%s\n' "$SHIM_CHECKS_DIR"
}

# The bundled checks, which are OFF until named.
#
# rg-policy ships `policy/base/*.toml` and a repo pulls one in with
# `extends = ["hygiene"]`; git-guards ships the hook scripts and a repo names
# the ids it wants. Both ship the rules and let the consumer choose, and this is
# the same shape: `checks/base/` holds the bundled set, and a repository turns
# one on by naming it.
#
# Enabling is a NAME rather than a path because a name is reviewable. The
# alternative -- symlink the checker you want into `.cmd-shims/checks` -- works
# today and always did, but it is a filesystem action nobody sees in a diff,
# and which check a repository runs is exactly the thing a reviewer should be
# able to read.
#
# Every source is unioned, none shadows another, for the reason all checkers
# run: a nearer file must not be able to switch off one further away. There is
# deliberately no `disable` -- rg-policy can offer `disable_rules` because its
# extends and its disables are the same reviewed file, while these arrive from
# three places and a disable in the nearest one would be a silent veto.
shim_enabled_checks() {
    local dir
    # Colon like every other path-ish variable here, comma because that is what
    # a list of names looks like to the person writing one.
    printf '%s\n' "${CMD_SHIMS_ENABLE:-}" | tr ':,' '\n'

    dir="$PWD"
    while [ -n "$dir" ] && [ "$dir" != / ]; do
        [ -f "$dir/.cmd-shims/checks.enabled" ] && cat "$dir/.cmd-shims/checks.enabled"
        dir="${dir%/*}"
    done

    dir="${XDG_CONFIG_HOME:-$HOME/.config}/cmd-shims/checks.enabled"
    [ -f "$dir" ] && cat "$dir"
    return 0
}

# Where the bundled set lives. Under the bundled checks directory, so the one
# variable that relocates the defaults relocates both of them.
shim_base_checks_dir() {
    printf '%s\n' "${SHIM_CHECKS_DIR:-}/base"
}

shim_base_checkers() {
    local name base
    base="$(shim_base_checks_dir)"
    while IFS= read -r name; do
        name="${name%%#*}"
        name="${name// /}"
        [ -n "$name" ] || continue
        if [ -f "$base/$name" ] && [ -x "$base/$name" ]; then
            printf '%s\n' "$base/$name"
        else
            # Enabled and absent is the failure this repository is built to
            # refuse, wearing its best disguise: the config says the check is
            # on, and nothing ran. Said every time, never once.
            printf '%s: check "%s" is enabled but not in %s; nothing ran for it.\n' \
                "${SHIM_NAME:-cmd-shims}" "$name" "$base" >&2
        fi
    done < <(shim_enabled_checks)
}

shim_checkers() {
    local entry path seen=" "
    while IFS= read -r entry; do
        [ -n "$entry" ] || continue
        if [ -d "$entry" ]; then
            for path in "$entry"/*; do
                # One condition per guard. `A && B || continue` reads as
                # if-then-else and is not: the continue also fires when A holds
                # and B does not, which is wanted here and invisible to the next
                # reader. An unmatched glob lands here as the literal pattern and
                # fails the first test, which is why no nullglob is needed.
                [ -f "$path" ] || continue
                [ -x "$path" ] || continue
                case "$seen" in *" $path "*) continue ;; esac
                seen="$seen$path "
                printf '%s\n' "$path"
            done
        elif [ -x "$entry" ]; then
            case "$seen" in *" $entry "*) continue ;; esac
            seen="$seen$entry "
            printf '%s\n' "$entry"
        fi
    done < <(shim_checks_path)

    # The bundled set last, for the reason the bundled specs are searched last:
    # what a repository supplied itself comes first.
    while IFS= read -r path; do
        case "$seen" in *" $path "*) continue ;; esac
        seen="$seen$path "
        printf '%s\n' "$path"
    done < <(shim_base_checkers)
}

# Run every checker over one blob of text.
#
# Returns 0 when the text is clean AND at least one checker looked at it.
# Returns 1 when a checker refused. Returns 2 when there were no checkers --
# which is not a pass, because a guard that inspects nothing and reports success
# is indistinguishable from one that works, and that is the failure this whole
# repository is built to avoid. The caller decides what to do with 2; it must
# not silently treat it as 0.
shim_check_subject() {
    local kind="$1" value="$2" checker rc=0 seen=0
    while IFS= read -r checker; do
        [ -n "$checker" ] || continue
        seen=1
        # The subject arrives on stdin; what KIND of thing it is arrives beside
        # it, so a checker can tell prose from a branch name from a path
        # without guessing from the content. A checker that only cares about
        # one kind ignores the rest and stays three lines long.
        #
        # Anything the checker prints goes to STDERR, including what it printed
        # on stdout. A shim's stdout belongs to the command it is standing in
        # front of -- `gh pr view --json` gets piped into things -- and a
        # checker that writes one line there corrupts a caller's parse of
        # output the checker had nothing to do with. Redirecting rather than
        # discarding: a checker that says something must not be silenced, it
        # must be said somewhere that is not the command's data.
        if ! printf '%s' "$value" | \
            CMD_SHIMS_KIND="$kind" \
            CMD_SHIMS_COMMAND="${SHIM_NAME:-}" \
            CMD_SHIMS_SUBCOMMAND="${ENGINE_SUBCOMMAND:-}" \
            CMD_SHIMS_TARGET="${ENGINE_TARGET:-}" \
            "$checker" >&2; then
            rc=1
        fi
    done < <(shim_checkers)

    [ "$seen" = 1 ] || return 2
    return "$rc"
}

# Text is the common case; this keeps the simple caller simple.
shim_check_text() { shim_check_subject text "$1"; }

# Said on every invocation that inspected nothing, never once and never
# quietly. "Inspected nothing" and "inspected everything and found nothing" are
# the two outcomes that must never look alike.
shim_warn_no_checkers() {
    printf '%s: no checks registered; nothing was inspected.\n' "${SHIM_NAME:-shim}" >&2
    printf '%*s enable a bundled one (install.sh --list-checks), or put an\n' \
        "${#SHIM_NAME}" "" >&2
    printf '%*s executable in %s\n' \
        "${#SHIM_NAME}" "" "${SHIM_CHECKS_DIR:-checks/}" >&2
}

# Ask, once, whether a repository is public, and remember the answer.
#
# `$@` after the repo is a command that PRINTS the visibility word. Only a
# definite answer is stored: caching "I could not tell" turns one call made
# before you logged in into a permanent blind spot, and a forge returns exactly
# the same "not found" for a private repository as for one that does not exist.
#
# The whole cache is discarded weekly rather than per entry. A repository that
# goes private is the direction that matters, and an answer that is at most a
# week stale is the cost of not asking the forge on every command.
shim_cached_visibility() {
    local repo="$1"; shift
    local dir="${XDG_CACHE_HOME:-$HOME/.cache}/cmd-shims"
    local file="$dir/visibility"
    local key="${SHIM_NAME:-shim}:$repo" cached answer

    if [ -n "$(find "$file" -mtime +7 2>/dev/null)" ]; then
        rm -f "$file"
    fi

    if [ -f "$file" ] && cached="$(grep -m1 -F "$key " "$file" 2>/dev/null)"; then
        printf '%s\n' "${cached#* }"
        return 0
    fi

    answer="$("$@" 2>/dev/null)" || return 1
    [ -n "$answer" ] || return 1

    mkdir -p "$dir"
    printf '%s %s\n' "$key" "$answer" >> "$file"
    printf '%s\n' "$answer"
}

# Where specs are looked for, nearest first.
#
# The specs shipped here are DEFAULTS, not the set. A consuming repository
# describes its own commands the same way it describes its own rules to
# rg-policy and picks its own hook ids for git-guards -- by putting a file in
# its own tree, not by forking the tool. First match wins, so a repository that
# needs `gh` treated differently from the bundled spec overrides it by name
# rather than arguing with it.
#
#   $CMD_SHIMS_SPECS         colon-separated, highest priority
#   ./.cmd-shims/commands    the consuming repository, found from $PWD upward
#   ~/.config/cmd-shims/commands
#   <this repo>/commands     the bundled defaults
shim_spec_path() {
    local dir="${PWD}"
    local IFS=:
    for dir in ${CMD_SHIMS_SPECS:-}; do
        [ -n "$dir" ] && printf '%s\n' "$dir"
    done
    unset IFS

    dir="$PWD"
    while [ -n "$dir" ] && [ "$dir" != / ]; do
        [ -d "$dir/.cmd-shims/commands" ] && printf '%s\n' "$dir/.cmd-shims/commands"
        dir="${dir%/*}"
    done

    printf '%s\n' "${XDG_CONFIG_HOME:-$HOME/.config}/cmd-shims/commands"
    printf '%s\n' "$SHIM_ROOT/commands"
}

shim_find_spec() {
    local name="$1" dir
    while IFS= read -r dir; do
        [ -f "$dir/$name.spec" ] && { printf '%s\n' "$dir/$name.spec"; return 0; }
    done < <(shim_spec_path)
    return 1
}

# Load a shim: pull in the engine, then apply the nearest spec for this command.
#
# Every shim in shims/ is this call and a shebang. That is the point -- a
# command is described, not programmed, so the twentieth one costs a table
# rather than a review, and somebody else's twentieth costs them nothing here.
shim_load_spec() {
    local name="$1" spec
    # shellcheck source-path=SCRIPTDIR
    # shellcheck source=engine.sh
    . "$SHIM_ROOT/lib/engine.sh"

    spec="$(shim_find_spec "$name")" || {
        # No spec is not a refusal. The shim is on PATH under this command's
        # name, so the command still has to work; it simply has nothing to
        # inspect and says so once.
        printf '%s: no spec found for %s on the spec path\n' "${SHIM_NAME:-shim}" "$name" >&2
        shim_exec_real "$name" "${@:2}"
    }
    # shellcheck source=/dev/null
    . "$spec"
}

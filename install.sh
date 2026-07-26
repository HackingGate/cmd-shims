#!/usr/bin/env bash
# Put a shim in front of a command, by symlinking it into a directory PATH
# reaches first.
#
#   ./install.sh gh git             # into ~/.local/bin
#   ./install.sh --bin ~/bin npm
#   ./install.sh --list             # every command with a spec on the spec path
#   ./install.sh --list-checks      # the bundled checks, and which are on
#   ./install.sh --enable prevent-ai-author
#   ./install.sh --uninstall gh
#
# Any command with a spec can be installed, including one whose spec lives in
# your repository rather than this one. There is a single shim binary; the name
# it is installed under is what selects the spec.
#
# It refuses two situations rather than installing something that looks
# installed and is not: a shim with no checkers behind it, and a name with no
# spec anywhere on the spec path.
set -euo pipefail

ROOT="$(cd -- "$(dirname -- "$(readlink -f -- "${BASH_SOURCE[0]}")")" && pwd)"
bin_dir="${CMD_SHIMS_BIN:-$HOME/.local/bin}"
uninstall=0
list=0
list_checks=0
enable=0
enabled_file="${XDG_CONFIG_HOME:-$HOME/.config}/cmd-shims/checks.enabled"

SHIM_ROOT="$ROOT"
SHIM_CHECKS_DIR="${CMD_SHIMS_CHECKS_DIR:-$ROOT/checks}"
export SHIM_ROOT SHIM_CHECKS_DIR
# shellcheck source=lib/shim.sh
. "$ROOT/lib/shim.sh"

while [ $# -gt 0 ]; do
    case "$1" in
        --bin) bin_dir="$2"; shift 2 ;;
        --uninstall) uninstall=1; shift ;;
        --list) list=1; shift ;;
        --list-checks) list_checks=1; shift ;;
        --enable) enable=1; shift ;;
        --) shift; break ;;
        -*) printf 'install: unknown option %s\n' "$1" >&2; exit 2 ;;
        *) break ;;
    esac
done

# Everything with a spec, nearest first, without duplicates -- the bundled
# specs are simply the last directory searched.
available_shims() {
    local dir path n
    local seen=" "
    while IFS= read -r dir; do
        [ -d "$dir" ] || continue
        for path in "$dir"/*.spec; do
            [ -f "$path" ] || continue
            n="${path##*/}"; n="${n%.spec}"
            case "$seen" in *" $n "*) continue ;; esac
            seen="$seen$n "
            printf '%s\n' "$n"
        done
    done < <(shim_spec_path)
}

if [ "$list" = 1 ]; then
    available_shims
    exit 0
fi

# The bundled checks: shipped, and off until named. See lib/shim.sh.
bundled_checks() {
    local path
    for path in "$SHIM_CHECKS_DIR"/base/*; do
        [ -f "$path" ] && [ -x "$path" ] && printf '%s\n' "${path##*/}"
    done
}

if [ "$list_checks" = 1 ]; then
    on=" $(shim_enabled_checks | sed 's/#.*//; s/ //g' | tr '\n' ' ')"
    while IFS= read -r name; do
        case "$on" in
            *" $name "*) printf '%s\ton\n' "$name" ;;
            *) printf '%s\toff\n' "$name" ;;
        esac
    done < <(bundled_checks)
    exit 0
fi

# Turning one on is a line in a file rather than a symlink, so that which checks
# a machine runs can be read rather than discovered. In a repository the same
# line goes in `.cmd-shims/checks.enabled`, where a reviewer sees it.
if [ "$enable" = 1 ]; then
    [ $# -gt 0 ] || { printf 'install: name at least one check (available: %s)\n' \
        "$(bundled_checks | tr '\n' ' ')" >&2; exit 2; }
    mkdir -p -- "$(dirname -- "$enabled_file")"
    touch -- "$enabled_file"
    for name in "$@"; do
        if [ ! -x "$SHIM_CHECKS_DIR/base/$name" ]; then
            printf 'install: no bundled check named %s (available: %s)\n' \
                "$name" "$(bundled_checks | tr '\n' ' ')" >&2
            exit 1
        fi
        if grep -qxF "$name" "$enabled_file"; then
            printf '%s already enabled in %s\n' "$name" "$enabled_file"
        else
            printf '%s\n' "$name" >> "$enabled_file"
            printf 'enabled %s in %s\n' "$name" "$enabled_file"
        fi
    done
    exit 0
fi

[ $# -gt 0 ] || { printf 'install: name at least one command (available: %s)\n' \
    "$(available_shims | tr '\n' ' ')" >&2; exit 2; }

path_position() {
    local name="$1" idx=0 dir
    local IFS=:
    for dir in $PATH; do
        [ -n "$dir" ] && [ -x "$dir/$name" ] && { printf '%s\n' "$idx"; return 0; }
        idx=$((idx + 1))
    done
    return 1
}

# Checkers that will still be there when the shim actually runs.
#
# This is not the same question as "are there checkers now", and the difference
# is not academic: installing with CMD_SHIMS_CHECKS set in the installing shell
# satisfies the naive check and then finds nothing at all, because `gh` is run
# later from a shell that never had the variable. The install said yes and the
# guard inspected nothing -- which is the exact failure this repository exists
# to refuse.
#
# So only durable locations count: the per-user directory and the bundled one.
# A `.cmd-shims/checks` inside a repository is durable too, but only applies
# under that repository, so it cannot be verified from here.
durable_checkers() {
    local path name
    for path in "${XDG_CONFIG_HOME:-$HOME/.config}"/cmd-shims/checks/* "$SHIM_CHECKS_DIR"/*; do
        [ -f "$path" ] && [ -x "$path" ] && printf '%s\n' "$path"
    done

    # A bundled check enabled in the per-user file is durable in the same way
    # and for the same reason: it is a file on this machine that the shim will
    # read later, from a shell that never ran this script. The repository-level
    # `.cmd-shims/checks.enabled` is durable too and cannot be verified here,
    # exactly like `.cmd-shims/checks`.
    [ -f "$enabled_file" ] || return 0
    while IFS= read -r name; do
        name="${name%%#*}"; name="${name// /}"
        [ -n "$name" ] || continue
        [ -x "$SHIM_CHECKS_DIR/base/$name" ] && printf '%s\n' "$SHIM_CHECKS_DIR/base/$name"
    done < "$enabled_file"
    return 0
}

env_only_checkers() {
    local entry
    local IFS=:
    for entry in ${CMD_SHIMS_CHECKS:-}; do
        [ -n "$entry" ] && { [ -x "$entry" ] || [ -d "$entry" ]; } && return 0
    done
    unset IFS
    # CMD_SHIMS_ENABLE is the same trap wearing the newer name.
    [ -n "${CMD_SHIMS_ENABLE:-}" ] && return 0
    return 1
}

for name in "$@"; do
    dst="$bin_dir/$name"

    if [ "$uninstall" = 1 ]; then
        if [ -L "$dst" ] && [ "$(readlink -f -- "$dst")" = "$(readlink -f -- "$ROOT/shims/shim")" ]; then
            rm -- "$dst"
            printf 'removed %s\n' "$dst"
        else
            printf '%s is not our shim; left alone\n' "$dst" >&2
        fi
        continue
    fi

    if ! shim_find_spec "$name" >/dev/null; then
        printf 'install: no spec for %s on the spec path.\n' "$name" >&2
        printf '  Write one in .cmd-shims/commands/%s.spec, or point\n' "$name" >&2
        printf '  CMD_SHIMS_SPECS at the directory holding it.\n' >&2
        exit 1
    fi

    if [ -z "$(durable_checkers)" ]; then
        printf 'install: refusing -- no checkers the shim will still find when it runs.\n' >&2
        if env_only_checkers; then
            printf '  CMD_SHIMS_CHECKS is set in THIS shell, and that is the trap: the\n' >&2
            printf '  shim runs later, from a shell that never had it, and inspects\n' >&2
            printf '  nothing while looking installed.\n' >&2
        fi
        printf '  Enable a bundled one: ./install.sh --enable %s\n' \
            "$(bundled_checks | head -1)" >&2
        printf '  (./install.sh --list-checks shows them all.)\n' >&2
        printf '  Or put an executable in %s/cmd-shims/checks/,\n' \
            "${XDG_CONFIG_HOME:-$HOME/.config}" >&2
        printf '  in %s/, or in .cmd-shims/checks inside a repository.\n' "$SHIM_CHECKS_DIR" >&2
        exit 1
    fi

    mkdir -p "$bin_dir"
    ln -sfn "$ROOT/shims/shim" "$dst"
    printf 'installed %s -> shims/shim (spec: %s)\n' "$dst" "$(shim_find_spec "$name")"

    real_at="$(path_position "$name" || true)"
    shim_at="$(
        idx=0; IFS=:
        for dir in $PATH; do
            [ "$(readlink -f -- "$dir" 2>/dev/null)" = "$(readlink -f -- "$bin_dir")" ] \
                && { printf '%s\n' "$idx"; break; }
            idx=$((idx + 1))
        done
    )"

    if [ -z "$shim_at" ]; then
        printf 'warning: %s is not on PATH, so the shim will never be reached.\n' "$bin_dir" >&2
    elif [ -n "$real_at" ] && [ "$real_at" -lt "$shim_at" ]; then
        printf 'warning: PATH reaches another %s before %s, so the shim is bypassed.\n' \
            "$name" "$bin_dir" >&2
    fi
done

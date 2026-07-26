#!/usr/bin/env bash
# Where the bundled checks get their rule bodies.
#
# The checks in checks/base/ do not implement rules. Every one of them is an
# adapter: it decides whether the subject it was handed is the kind its rule
# judges, and then hands it to the script in git-guards that already holds that
# rule. `no-private-repo-names` exists there with a `--text` mode written for
# exactly this caller -- a pull request body reaching a public API without
# passing a hook -- and a second copy here would be a second rule that agrees
# with that one until it does not.
#
# So this file answers one question: where is git-guards on this machine.

# Print the path to a git-guards script, or fail.
#
# The order is most-declared-first. The hook cache is in the list because it is
# where git-guards actually lives for most consumers: they reference it from
# `.pre-commit-config.yaml` and never clone it, so `~/.cache/prek/repos/<hash>/`
# is the only copy on the machine. That copy is whatever `rev:` the consuming
# repository pinned, which is the same version its hooks are running -- the two
# tiers agreeing is the point, and disagreeing would be worse than either.
git_guards_script() {
    local name="$1" dir candidate

    if [ -n "${CMD_SHIMS_GIT_GUARDS:-}" ]; then
        candidate="$CMD_SHIMS_GIT_GUARDS/$name"
        [ -x "$candidate" ] && { printf '%s\n' "$candidate"; return 0; }
    fi

    # A sibling checkout, which is how it is laid out for anyone who works on
    # both repositories.
    for dir in "${SHIM_ROOT:-}/../git-guards" "${SHIM_ROOT:-}/../../git-guards"; do
        candidate="$dir/$name"
        [ -x "$candidate" ] && { printf '%s\n' "$candidate"; return 0; }
    done

    for candidate in \
        "${XDG_CACHE_HOME:-$HOME/.cache}"/prek/repos/*/"$name" \
        "${XDG_CACHE_HOME:-$HOME/.cache}"/pre-commit/repo*/"$name"; do
        # An unmatched glob arrives as the literal pattern and fails this test,
        # which is why no nullglob is needed.
        [ -x "$candidate" ] && { printf '%s\n' "$candidate"; return 0; }
    done

    command -v "$name" >/dev/null 2>&1 && { command -v "$name"; return 0; }
    return 1
}

# Said when the rule body is not on this machine.
#
# Loudly, and then exit 0. A checker that cannot reach its rule has not found
# the text clean -- it has not looked -- and those two must never look alike,
# which is the same reason the shim warns when no checkers are registered at
# all. It still fails open, because a missing sibling repository is not a
# reason for `gh pr create` to stop working.
git_guards_missing() {
    printf 'cmd-shims: %s: git-guards is not on this machine, so nothing was inspected.\n' "$1" >&2
    printf '           point CMD_SHIMS_GIT_GUARDS at a git-guards checkout, or\n' >&2
    printf '           run its hooks in this repo so the runner caches a copy.\n' >&2
}

# Said after a delegated rule refuses.
#
# The rule was written for a commit-msg hook and its wording says so -- "this
# commit message", "override with git commit --no-verify". Both are wrong here
# and neither is worth a fork of the text, so one line names where the rule
# lives and what it was actually handed. The right override is on the line the
# engine prints immediately after this one.
git_guards_refused() {
    printf 'cmd-shims: that is the git-guards rule %s, run here over %s from %s -- not a commit.\n' \
        "$1" "${CMD_SHIMS_KIND:-a subject}" "${CMD_SHIMS_COMMAND:-a command}" >&2
}

# Every bundled check that shells out to python3 says this rather than letting
# the interpreter fail: an exec failure is a non-zero exit, and a non-zero exit
# from a checker means REFUSED. A machine without python3 would start refusing
# commands for a reason that has nothing to do with the text.
git_guards_need_python() {
    command -v python3 >/dev/null 2>&1 && return 0
    printf 'cmd-shims: %s: no python3, so nothing was inspected.\n' "$1" >&2
    return 1
}

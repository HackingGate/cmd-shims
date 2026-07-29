#!/usr/bin/env bash
# Where the bundled checks get their rg-policy rule bodies.
#
# The sibling of lib/git-guards.sh, and the same principle: the checks in
# checks/base/ do not implement rules. rg-policy holds the identity rules and
# ships a `--check-text` mode written for exactly this caller -- text that is
# published the moment it is written and never becomes a file, so its own
# tree-scanning mode cannot see it. This file answers one question: where is
# rg-policy on this machine.
#
# One difference from git-guards worth knowing. A git-guards rule is a script
# and the rule is in the script. An rg-policy rule is a *declaration* in the
# consuming repository's policy/rg-policy.toml, and the engine reads it from
# the working directory. So the engine found here is the engine, but the rules
# it applies belong to wherever the command was run -- which is the right
# answer: `gh pr create` in route-config should apply route-config's policy.

# Print the path to rg-policy's engine, or fail.
#
# Most-declared-first, and the hook cache is in the list for the same reason it
# is in git-guards': consumers reference rg-policy from .pre-commit-config.yaml
# and never clone it, so ~/.cache/prek/repos/<hash>/ is the only copy on the
# machine -- and it is pinned to the same rev the repo's own hooks run, which
# is the point. The two tiers disagreeing would be worse than either.
rg_policy_engine() {
    local dir candidate

    if [ -n "${CMD_SHIMS_RG_POLICY:-}" ]; then
        candidate="$CMD_SHIMS_RG_POLICY/check_policy.py"
        [ -x "$candidate" ] && { printf '%s\n' "$candidate"; return 0; }
        # Also accept a direct path to the engine itself.
        [ -x "$CMD_SHIMS_RG_POLICY" ] && { printf '%s\n' "$CMD_SHIMS_RG_POLICY"; return 0; }
    fi

    for dir in "${SHIM_ROOT:-}/../rg-policy" "${SHIM_ROOT:-}/../../rg-policy"; do
        candidate="$dir/check_policy.py"
        [ -x "$candidate" ] && { printf '%s\n' "$candidate"; return 0; }
    done

    for candidate in \
        "${XDG_CACHE_HOME:-$HOME/.cache}"/prek/repos/*/check_policy.py \
        "${XDG_CACHE_HOME:-$HOME/.cache}"/pre-commit/repo*/check_policy.py; do
        # An unmatched glob arrives as the literal pattern and fails this test.
        [ -x "$candidate" ] && { printf '%s\n' "$candidate"; return 0; }
    done

    return 1
}

# Said when the rule body is not on this machine.
#
# Loudly, then exit 0 -- the same bargain lib/git-guards.sh makes. A checker
# that cannot reach its rule has not found the text clean, it has not looked,
# and those two must never look alike. It still fails open, because a missing
# sibling repository is not a reason for `gh pr create` to stop working.
rg_policy_missing() {
    printf 'cmd-shims: %s: rg-policy is not on this machine, so nothing was inspected.\n' "$1" >&2
    printf '           point CMD_SHIMS_RG_POLICY at an rg-policy checkout, or\n' >&2
    printf '           run its hooks in this repo so the runner caches a copy.\n' >&2
}

# Said after the delegated rule refuses.
#
# rg-policy's message is written for a repository scan -- it talks about what is
# committed. Here it judged something on its way out of a command instead, and
# saying so is cheaper than forking the wording.
rg_policy_refused() {
    printf 'cmd-shims: that is the rg-policy rule %s, run here over %s from %s -- not a commit.\n' \
        "$1" "${CMD_SHIMS_KIND:-a subject}" "${CMD_SHIMS_COMMAND:-a command}" >&2
}

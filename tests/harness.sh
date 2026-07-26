#!/usr/bin/env bash
# Shared test harness.
#
# One copy, because a per-command test file that carried its own assertions
# would drift the same way a per-command shim would, and the tests are the thing
# proving that did not happen.

failures=0
tmp="$(mktemp -d)"
trap 'rm -rf "$tmp"' EXIT

# The suites must not be able to see the machine they run on.
#
# Both the spec path and the checks path include a per-user directory, so a
# developer who has actually installed cmd-shims supplies a real checker to
# every test -- and the case that asserts "no checkers registered" fails on
# their laptop and passes in CI. Pointing XDG at the temporary directory makes
# a suite depend on its own fixtures and nothing else.
export XDG_CONFIG_HOME="$tmp/xdg-config"
export XDG_CACHE_HOME="$tmp/xdg-cache"

record() {
    if [ "$1" = 0 ]; then
        printf 'ok   %s\n' "$2"
    else
        printf 'FAIL %s\n' "$2"
        failures=$((failures + 1))
    fi
}

# Statuses are captured by running the command here, rather than read back out
# of `$?` several expansions later where a test can quietly start asserting the
# exit status of its own assertion.
ok_if()  { local name="$1"; shift; if "$@"; then record 0 "$name"; else record 1 "$name"; fi; }
not_if() { local name="$1"; shift; if "$@"; then record 1 "$name"; else record 0 "$name"; fi; }
eq()     { local name="$1" got="$2" want="$3"
           if [ "$got" = "$want" ]; then record 0 "$name"
           else record 1 "$name (got '$got', want '$want')"; fi; }

# A checker that refuses one word, so every suite is testing the same contract:
# text on stdin, non-zero refuses, stderr is the reason.
harness_install_checker() {
    cat > "$1/no-secret" <<'CHK'
#!/usr/bin/env bash
if grep -qi 'classified'; then
    echo "checker: the text says 'classified'" >&2
    exit 1
fi
CHK
    chmod +x "$1/no-secret"
}

harness_report() {
    echo
    if [ "$failures" = 0 ]; then
        printf 'all %s tests passed\n' "$1"
    else
        printf '%s %s test(s) failed\n' "$failures" "$1"
        exit 1
    fi
}

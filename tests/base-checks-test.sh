#!/usr/bin/env bash
# The bundled checks: shipped, and off until named.
#
# Two properties are being defended here and they pull in opposite directions.
# A repository that ships rules must not start enforcing them because somebody
# ran `git pull` -- so the default is off, and the suite proves a populated
# checks/base/ inspects nothing. And a check somebody DID name must actually
# run, including when the name is wrong -- so the suite proves an enabled name
# that resolves to no file is reported rather than skipped, which is the same
# failure as a shim that looks installed and inspects nothing.
set -uo pipefail

ROOT="$(cd -- "$(dirname -- "$(readlink -f -- "${BASH_SOURCE[0]}")")/.." && pwd)"
# shellcheck source-path=SCRIPTDIR
# shellcheck source=harness.sh
. "$(dirname -- "$(readlink -f -- "${BASH_SOURCE[0]}")")/harness.sh"

# `.cmd-shims/checks.enabled` is looked for from $PWD upward, so the suite runs
# somewhere with no ancestors -- otherwise a developer who enabled a check in a
# parent directory is running a different test from CI.
mkdir -p "$tmp/work" "$tmp/real" "$tmp/bin" "$tmp/checks/base" "$tmp/gg"
cd "$tmp/work" || exit 1

cat > "$tmp/real/gh" <<'STUB'
#!/usr/bin/env bash
case "$1 $2" in
  "api repos/acme/public")  echo public;  exit 0 ;;
  "repo view")              echo acme/public; exit 0 ;;
esac
{ printf 'REACHED:'; printf ' %s' "$@"; printf '\n'; } >> "$GH_STUB_LOG"
# What a caller pipes somewhere, and what a checker must not land in.
echo "STDOUT-FROM-GH"
exit 0
STUB
chmod +x "$tmp/real/gh"
ln -sf "$ROOT/shims/shim" "$tmp/bin/gh"

export GH_STUB_LOG="$tmp/log"
export CMD_SHIMS_CHECKS_DIR="$tmp/checks"
export PATH="$tmp/bin:$tmp/real:$PATH"

# A bundled set of two, so "enabled" can be told from "everything in base/".
cat > "$tmp/checks/base/no-classified" <<'CHK'
#!/usr/bin/env bash
grep -qi 'classified' && { echo "base: the text says 'classified'" >&2; exit 1; }
exit 0
CHK
cat > "$tmp/checks/base/no-embargoed" <<'CHK'
#!/usr/bin/env bash
grep -qi 'embargoed' && { echo "base: the text says 'embargoed'" >&2; exit 1; }
exit 0
CHK
chmod +x "$tmp/checks/base/no-classified" "$tmp/checks/base/no-embargoed"

rc=0
run() { : > "$GH_STUB_LOG"; gh "$@" </dev/null >/dev/null 2>"$tmp/err"; rc=$?; }
reached() { grep -q '^REACHED:' "$GH_STUB_LOG"; }
said() { grep -q "$1" "$tmp/err"; }

# ---- shipped is not enabled -------------------------------------------------
run pr create --title t --body "this is classified"
eq     "off by default: the command still runs" "$rc" 0
ok_if  "off by default: reaches gh" reached
ok_if  "off by default: says nothing was inspected" said 'nothing was inspected'

# ---- named in the environment -----------------------------------------------
CMD_SHIMS_ENABLE=no-classified run pr create --title t --body "this is classified"
eq     "CMD_SHIMS_ENABLE: dirty body refused" "$rc" 1
not_if "CMD_SHIMS_ENABLE: never reaches gh" reached
ok_if  "CMD_SHIMS_ENABLE: the check's own reason is shown" said "says 'classified'"

CMD_SHIMS_ENABLE=no-classified run pr create --title t --body "an ordinary body"
eq     "CMD_SHIMS_ENABLE: clean body passes" "$rc" 0
ok_if  "CMD_SHIMS_ENABLE: clean body reaches gh" reached

# An enabled check is not a licence for the rest of the set.
CMD_SHIMS_ENABLE=no-classified run pr create --title t --body "this is embargoed"
eq     "one enabled does not enable the others" "$rc" 0

# ---- named in the repository ------------------------------------------------
mkdir -p "$tmp/work/.cmd-shims"
cat > "$tmp/work/.cmd-shims/checks.enabled" <<'EOF'
# the reviewable form: a line in a file
no-classified
EOF
run pr create --title t --body "this is classified"
eq     ".cmd-shims/checks.enabled: dirty body refused" "$rc" 1
not_if ".cmd-shims/checks.enabled: never reaches gh" reached

# Found from $PWD *upward*, so a subdirectory of the repository is still inside
# the repository's own configuration.
mkdir -p "$tmp/work/deep/deeper"
(cd "$tmp/work/deep/deeper" && gh pr create --title t --body "this is classified" \
    </dev/null >/dev/null 2>&1)
eq "found from a subdirectory too" "$?" 1

# ---- the sources union, they do not shadow ----------------------------------
mkdir -p "$XDG_CONFIG_HOME/cmd-shims"
printf 'no-embargoed\n' > "$XDG_CONFIG_HOME/cmd-shims/checks.enabled"

run pr create --title t --body "this is classified"
eq "union: the repository's choice still fires" "$rc" 1
run pr create --title t --body "this is embargoed"
eq "union: the per-user choice still fires" "$rc" 1

# ---- enabled and absent is not the same as clean ----------------------------
printf 'no-such-check\n' >> "$tmp/work/.cmd-shims/checks.enabled"
run pr create --title t --body "an ordinary body"
ok_if "a missing name is reported" said 'enabled but not in'
eq    "a missing name does not break the command" "$rc" 0

run pr create --title t --body "this is classified"
eq "a missing name does not disarm the checks that resolved" "$rc" 1

# Comments and blanks are not names.
cat > "$tmp/work/.cmd-shims/checks.enabled" <<'EOF'

# no-classified  <- switched off by commenting it out

no-embargoed
EOF
run pr create --title t --body "this is classified"
eq     "a commented-out name is off" "$rc" 0
not_if "a comment is not reported as a missing check" said 'enabled but not in'

rm -rf "$tmp/work/.cmd-shims"
rm -f "$XDG_CONFIG_HOME/cmd-shims/checks.enabled"

# ---- a checker does not get to write on the command's stdout ------------------
# The shim's stdout belongs to the command it stands in front of, and `gh` is
# piped into things. A checker that prints one line there corrupts a parse of
# output it had nothing to do with -- so what it says is moved to stderr rather
# than dropped.
cat > "$tmp/checks/base/chatty" <<'CHK'
#!/usr/bin/env bash
cat > /dev/null
echo "denominator chatter"
exit 0
CHK
chmod +x "$tmp/checks/base/chatty"

CMD_SHIMS_ENABLE=chatty gh pr create --title t --body ok \
    </dev/null >"$tmp/out" 2>"$tmp/err"
not_if "a checker's stdout stays off the command's stdout" grep -q chatter "$tmp/out"
ok_if  "a checker's stdout is said on stderr instead" grep -q chatter "$tmp/err"
ok_if  "the command's own stdout is untouched" grep -qx 'STDOUT-FROM-GH' "$tmp/out"

# ---- install.sh ---------------------------------------------------------------
"$ROOT/install.sh" --list-checks > "$tmp/listed" 2>/dev/null
ok_if "--list-checks lists the bundled set" grep -qx 'no-classified	off' "$tmp/listed"

"$ROOT/install.sh" --enable no-classified >/dev/null 2>"$tmp/err"
ok_if "--enable writes the per-user file" \
    grep -qx 'no-classified' "$XDG_CONFIG_HOME/cmd-shims/checks.enabled"

"$ROOT/install.sh" --enable no-classified >/dev/null 2>&1
eq "--enable twice does not duplicate the line" \
    "$(grep -cx 'no-classified' "$XDG_CONFIG_HOME/cmd-shims/checks.enabled")" 1

"$ROOT/install.sh" --enable no-such-check >/dev/null 2>"$tmp/err"
eq    "--enable refuses a name with no check" "$?" 1
ok_if "--enable says what there is instead" said 'no bundled check named'

"$ROOT/install.sh" --list-checks > "$tmp/listed" 2>/dev/null
ok_if "--list-checks reports what is on" grep -qx 'no-classified	on' "$tmp/listed"

# An enabled bundled check is a durable checker: it is a file this machine will
# still have when the shim runs, which is the question install.sh is asking.
"$ROOT/install.sh" --bin "$tmp/bin2" gh >/dev/null 2>"$tmp/err"
eq "install accepts an enabled bundled check as a checker" "$?" 0

rm -f "$XDG_CONFIG_HOME/cmd-shims/checks.enabled"
"$ROOT/install.sh" --bin "$tmp/bin2" gh >/dev/null 2>"$tmp/err"
eq    "install still refuses with nothing enabled and nothing supplied" "$?" 1
ok_if "and points at the bundled set" said 'install.sh --enable'

# ---- the real bundled checks ------------------------------------------------
# Driven directly rather than through a shim: what is being tested is the
# adapter -- which rule it calls, how, and for which kinds -- and that is the
# whole of what these files contain.
#
# SHIM_ROOT is pointed at nothing so the sibling-checkout lookup cannot find the
# real git-guards. Otherwise this suite would pass or fail depending on what
# else is checked out next to it.
base="$ROOT/checks/base"
export SHIM_ROOT="$tmp/nowhere"

cat > "$tmp/gg/no-private-repo-names.sh" <<'GG'
#!/usr/bin/env bash
{ printf 'ARGS:'; printf ' %s' "$@"; printf '\n'; } >> "$GG_LOG"
grep -q 'acme/secret' && { echo "git-guards: names a private repo" >&2; exit 1; }
exit 0
GG
cat > "$tmp/gg/prevent-ai-author.sh" <<'GG'
#!/usr/bin/env bash
{ printf 'ARGS:'; printf ' %s' "$@"; printf '\n'; } >> "$GG_LOG"
grep -q 'Generated with' "$1" && { echo "git-guards: AI attribution" >&2; exit 1; }
exit 0
GG
cat > "$tmp/gg/prevent-unusual-unicode-in-files.py" <<'GG'
#!/usr/bin/env bash
{ printf 'ARGS:'; printf ' %s' "$@"; printf '\n'; } >> "$GG_LOG"
# The real rule prints its denominator on stdout, pass or fail.
echo "prevent-unusual-unicode: 1 file(s) scanned, 0 skipped"
grep -q ZWSP "${@: -1}" && { echo "error: hidden unicode" >&2; exit 1; }
exit 0
GG
chmod +x "$tmp/gg"/*
export GG_LOG="$tmp/gg-log"

check() {
    local name="$1" kind="$2" text="$3"
    : > "$GG_LOG"
    printf '%s' "$text" | CMD_SHIMS_KIND="$kind" CMD_SHIMS_COMMAND=gh \
        CMD_SHIMS_GIT_GUARDS="$tmp/gg" "$base/$name" >"$tmp/out" 2>"$tmp/err"
}
said_out() { grep -q "$1" "$tmp/out"; }

check no-private-repo-names text 'see acme/secret for the fix'
eq    "no-private-repo-names: refuses what git-guards refuses" "$?" 1
ok_if "no-private-repo-names: calls the rule in --text mode" \
    grep -qx 'ARGS: --text -' "$GG_LOG"
# The rule's wording says "commit" because that is where it usually runs. One
# line names where it came from and what it was actually handed.
ok_if "no-private-repo-names: says which rule refused, and over what" \
    said 'git-guards rule no-private-repo-names, run here over text from gh'

check no-private-repo-names text 'nothing to see here'
eq "no-private-repo-names: passes what git-guards passes" "$?" 0

check no-private-repo-names ref 'fix/acme-secret-outage'
ok_if "no-private-repo-names: judges a ref too" grep -q 'ARGS:' "$GG_LOG"

check no-private-repo-names path "$tmp/work"
eq     "no-private-repo-names: a path is not its kind" "$?" 0
not_if "no-private-repo-names: and it does not call the rule" grep -q 'ARGS:' "$GG_LOG"

check prevent-ai-author text 'Generated with [Claude Code]'
eq "prevent-ai-author: refuses an attributed body" "$?" 1
ok_if "prevent-ai-author: hands the rule a real file, not a flag" \
    grep -q 'ARGS: /' "$GG_LOG"

check prevent-ai-author ref 'some-branch'
eq     "prevent-ai-author: a ref cannot carry a trailer" "$?" 0
not_if "prevent-ai-author: so the rule is not called" grep -q 'ARGS:' "$GG_LOG"

if command -v python3 >/dev/null 2>&1; then
    check prevent-unusual-unicode text 'a body'
    ok_if "prevent-unusual-unicode: prose gets the invisible-character ban" \
        grep -q 'ARGS: --files ' "$GG_LOG"

    check prevent-unusual-unicode ref 'a-branch'
    ok_if  "prevent-unusual-unicode: a ref reaches the rule" grep -q 'ARGS: /' "$GG_LOG"
    not_if "prevent-unusual-unicode: a ref gets the whitelist, not the file ban" \
        grep -q -- '--files' "$GG_LOG"

    # The denominator the rule prints is one file every time -- the one this
    # adapter just wrote -- so on a pass it is noise on every command.
    check prevent-unusual-unicode text 'a body'
    eq     "prevent-unusual-unicode: a clean subject passes" "$?" 0
    not_if "prevent-unusual-unicode: and says nothing when it passes" \
        said_out 'file(s) scanned'

    check prevent-unusual-unicode text 'a body with a ZWSP in it'
    eq    "prevent-unusual-unicode: refuses what the rule refuses" "$?" 1
    ok_if "prevent-unusual-unicode: keeps the denominator when it refuses" \
        said 'file(s) scanned'
    ok_if "prevent-unusual-unicode: says which rule refused" \
        said 'git-guards rule prevent-unusual-unicode'
else
    printf 'skip prevent-unusual-unicode (no python3)\n'
fi

# ---- no-os-identity, whose rule body is rg-policy rather than git-guards -----
# A stub engine, for the same reason as the others: the real one reads the
# running machine's own identity, so a suite built on it would assert something
# different on every host.
mkdir -p "$tmp/rgp"
cat > "$tmp/rgp/check_policy.py" <<'RGP'
#!/usr/bin/env bash
{ printf 'ARGS:'; printf ' %s' "$@"; printf '\n'; } >> "$GG_LOG"
grep -q 'example-host' && { echo "policy check failed: hostname-segment" >&2; exit 1; }
exit 0
RGP
chmod +x "$tmp/rgp/check_policy.py"

check_rgp() {
    local kind="$1" text="$2"
    : > "$GG_LOG"
    printf '%s' "$text" | CMD_SHIMS_KIND="$kind" CMD_SHIMS_COMMAND=gh \
        CMD_SHIMS_RG_POLICY="$tmp/rgp" "$base/no-os-identity" \
        >"$tmp/out" 2>"$tmp/err"
}

if command -v python3 >/dev/null 2>&1; then
    check_rgp text 'the example-host fragment of its hostname'
    eq    "no-os-identity: refuses what rg-policy refuses" "$?" 1
    ok_if "no-os-identity: calls the engine in --check-text mode" \
        grep -qx 'ARGS: --check-text -' "$GG_LOG"
    ok_if "no-os-identity: says which rule refused, and over what" \
        said 'rg-policy rule no-os-identity, run here over text from gh'

    check_rgp text 'a body that names nobody'
    eq "no-os-identity: passes what rg-policy passes" "$?" 0

    check_rgp ref 'fix/example-host-outage'
    ok_if "no-os-identity: judges a ref too" grep -q 'ARGS:' "$GG_LOG"

    check_rgp path "$tmp/work"
    eq     "no-os-identity: a path is rg-policy's own file mode, not this" "$?" 0
    not_if "no-os-identity: and it does not call the engine" grep -q 'ARGS:' "$GG_LOG"

    # 2 is rg-policy saying it could not run -- no ripgrep, unreadable policy.
    # That is an infrastructure answer, not a verdict, and must not read as one.
    cat > "$tmp/rgp/check_policy.py" <<'RGP'
#!/usr/bin/env bash
echo "policy check failed: ripgrep executable \`rg\` was not found" >&2
exit 2
RGP
    chmod +x "$tmp/rgp/check_policy.py"
    check_rgp text 'anything at all'
    eq    "no-os-identity: an engine that could not run does not refuse" "$?" 0
    ok_if "no-os-identity: and says nothing was inspected" \
        said 'could not run, so nothing was inspected'
else
    printf 'skip no-os-identity (no python3)\n'
fi

# ---- and with the rule bodies nowhere on the machine ------------------------
# Fail open, but never quietly: a checker that cannot reach its rule has not
# found the text clean, it has not looked.
printf 'see acme/secret' | CMD_SHIMS_KIND=text \
    "$base/no-private-repo-names" 2>"$tmp/err"
eq    "no git-guards: does not refuse" "$?" 0
ok_if "no git-guards: says nothing was inspected" said 'git-guards is not on this machine'

printf 'anything' | CMD_SHIMS_KIND=text HOME="$tmp/nowhere" \
    "$base/no-os-identity" 2>"$tmp/err"
eq    "no rg-policy: does not refuse" "$?" 0
ok_if "no rg-policy: says nothing was inspected" said 'rg-policy is not on this machine'

harness_report base-checks

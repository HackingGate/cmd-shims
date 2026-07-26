#!/usr/bin/env bash
# Behaviour tests for the npm spec.
#
# npm is here because it is the case that does NOT fit a forge: no repository,
# no owner, no visibility endpoint. What decides whether anyone should care is a
# field in package.json and which registry is being written to. If
# `spec_in_scope` were still spelled "is the repository public", none of this
# could be expressed -- so these assertions are really about the engine, not
# about npm.
set -uo pipefail

ROOT="$(cd -- "$(dirname -- "$(readlink -f -- "${BASH_SOURCE[0]}")")/.." && pwd)"
# shellcheck source-path=SCRIPTDIR
# shellcheck source=harness.sh
. "$(dirname -- "$(readlink -f -- "${BASH_SOURCE[0]}")")/harness.sh"

mkdir -p "$tmp/real" "$tmp/bin" "$tmp/checks" "$tmp/pkg"
harness_install_checker "$tmp/checks"

cat > "$tmp/real/npm" <<'STUB'
#!/usr/bin/env bash
{ printf 'REACHED:'; printf ' %s' "$@"; printf '\n'; } >> "$NPM_STUB_LOG"
exit 0
STUB
chmod +x "$tmp/real/npm"
ln -sf "$ROOT/shims/shim" "$tmp/bin/npm"

export NPM_STUB_LOG="$tmp/log"
export XDG_CACHE_HOME="$tmp/cache"
export CMD_SHIMS_CHECKS_DIR="$tmp/checks"
export PATH="$tmp/bin:$tmp/real:$PATH"

cd "$tmp/pkg" || exit 1
pkg() { printf '%s\n' "$1" > package.json; }

rc=0
run() { : > "$NPM_STUB_LOG"; npm "$@" </dev/null >/dev/null 2>"$tmp/err"; rc=$?; }
reached() { grep -q '^REACHED:' "$NPM_STUB_LOG"; }

# ---- metadata is the subject ------------------------------------------------
pkg '{"name":"widget","description":"an ordinary widget"}'
run publish
eq    "clean metadata: exits 0" "$rc" 0
ok_if "clean metadata reaches npm" reached

pkg '{"name":"widget","description":"this is classified"}'
run publish
eq     "dirty description is refused" "$rc" 1
not_if "dirty description never reaches npm" reached

pkg '{"name":"classified-internal-thing","description":"fine"}'
run publish
eq "dirty package NAME is refused" "$rc" 1

# The README goes to the registry too, and is the largest thing that does.
pkg '{"name":"widget","description":"fine"}'
printf 'see the classified runbook\n' > README.md
run publish
eq "dirty README is refused" "$rc" 1
rm -f README.md

# ---- scope: two independent reasons this is nobody's business ---------------
pkg '{"name":"widget","description":"this is classified","private":true}'
run publish
eq    "private package: exits 0" "$rc" 0
ok_if "private package passes through" reached

pkg '{"name":"widget","description":"this is classified"}'
run publish --registry https://npm.internal.example.com
eq    "private registry: exits 0" "$rc" 0
ok_if "private registry passes through" reached

# A dry run publishes nothing, and refusing one would block the very command
# somebody runs to find out what they are about to publish.
run publish --dry-run
eq    "--dry-run: exits 0" "$rc" 0
ok_if "--dry-run passes through" reached

# ---- unrelated invocations cost one exec ------------------------------------
run install
eq    "npm install: exits 0" "$rc" 0
ok_if "npm install passes through" reached

cd / || exit 1
harness_report npm-shim

#!/usr/bin/env bash
# Behaviour tests for the glab shim.
#
# glab is the cheap case on purpose: a merge request is a pull request and
# `--description` is `--body`, so if adding a forge really costs a table rather
# than a program, this file is short and nothing in lib/ changed to make it
# pass. It also pins the one place GitLab is NOT GitHub -- `internal`, which is
# a visibility value with no GitHub equivalent and is not public enough to
# relax a guard for.
set -uo pipefail

ROOT="$(cd -- "$(dirname -- "$(readlink -f -- "${BASH_SOURCE[0]}")")/.." && pwd)"
# shellcheck source-path=SCRIPTDIR
# shellcheck source=harness.sh
. "$(dirname -- "$(readlink -f -- "${BASH_SOURCE[0]}")")/harness.sh"

mkdir -p "$tmp/real" "$tmp/bin" "$tmp/checks"
harness_install_checker "$tmp/checks"

cat > "$tmp/real/glab" <<'STUB'
#!/usr/bin/env bash
case "$*" in
  "repo view --output json") printf '{"path_with_namespace":"%s"}\n' "$GLAB_STUB_PROJECT"; exit 0 ;;
  *"projects/acme%2Fpublic"*)   echo '{"visibility":"public"}';   exit 0 ;;
  *"projects/acme%2Fsecret"*)   echo '{"visibility":"private"}';  exit 0 ;;
  *"projects/acme%2Finternal"*) echo '{"visibility":"internal"}'; exit 0 ;;
esac
{ printf 'REACHED:'; printf ' %s' "$@"; printf '\n'; } >> "$GLAB_STUB_LOG"
exit 0
STUB
chmod +x "$tmp/real/glab"
ln -sf "$ROOT/shims/shim" "$tmp/bin/glab"

export GLAB_STUB_LOG="$tmp/log"
export GLAB_STUB_PROJECT="acme/public"
export XDG_CACHE_HOME="$tmp/cache"
export CMD_SHIMS_CHECKS_DIR="$tmp/checks"
export PATH="$tmp/bin:$tmp/real:$PATH"

rc=0
run() { : > "$GLAB_STUB_LOG"; glab "$@" </dev/null >/dev/null 2>"$tmp/err"; rc=$?; }
reached() { grep -q '^REACHED:' "$GLAB_STUB_LOG"; }

run mr list
eq    "mr list: exits 0" "$rc" 0
ok_if "mr list passes through" reached

run mr create --title clean --description "an ordinary description"
eq    "clean description: exits 0" "$rc" 0
ok_if "clean description reaches glab" reached

run mr create --title clean --description "this is classified"
eq     "dirty description is refused" "$rc" 1
not_if "dirty description never reaches glab" reached

run issue note 7 --message "this is classified"
eq "dirty issue note is refused" "$rc" 1

run mr create --title "this is classified" --description ok
eq "dirty title is refused" "$rc" 1

# `internal` is visible to every account on the instance, which is not the same
# as private and is nowhere near public enough to be worth a repo name. It is
# NOT public, so the guard stays out of the way -- asserted so nobody later
# "fixes" the comparison into `!= private`.
GLAB_STUB_PROJECT="acme/internal" run mr create --title t --description "this is classified"
eq "internal target: treated as not-public, passes through" "$rc" 0

GLAB_STUB_PROJECT="acme/secret" run mr create --title t --description "this is classified"
eq "private target: passes through" "$rc" 0

harness_report glab-shim

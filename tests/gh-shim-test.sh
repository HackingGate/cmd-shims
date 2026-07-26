#!/usr/bin/env bash
# Behaviour tests for the gh shim, against a stub gh.
#
# The stub is the point. A shim's whole job is to decide whether to become the
# real command, so the assertion that matters is which invocations reached it --
# and that is only observable if the thing behind the shim is something the test
# owns. Every case below is paired: the call that must pass through and the
# neighbouring call that must not.
set -uo pipefail

ROOT="$(cd -- "$(dirname -- "$(readlink -f -- "${BASH_SOURCE[0]}")")/.." && pwd)"
# shellcheck source-path=SCRIPTDIR
# shellcheck source=harness.sh
. "$(dirname -- "$(readlink -f -- "${BASH_SOURCE[0]}")")/harness.sh"

# ---- a gh that records what it was asked to do ------------------------------
mkdir -p "$tmp/real" "$tmp/bin" "$tmp/checks"
cat > "$tmp/real/gh" <<'STUB'
#!/usr/bin/env bash
case "$1 $2" in
  "api repos/acme/public")  echo public;  exit 0 ;;
  "api repos/acme/secret")  echo private; exit 0 ;;
  "repo view")              echo acme/public; exit 0 ;;
esac
{ printf 'REACHED:'; printf ' %s' "$@"; printf '\n'; } >> "$GH_STUB_LOG"
printf 'STDIN:%s\n' "$(cat)" >> "$GH_STUB_LOG"
exit 0
STUB
chmod +x "$tmp/real/gh"
ln -sf "$ROOT/shims/shim" "$tmp/bin/gh"

export GH_STUB_LOG="$tmp/log"
export XDG_CACHE_HOME="$tmp/cache"
export CMD_SHIMS_CHECKS_DIR="$tmp/checks"
export PATH="$tmp/bin:$tmp/real:$PATH"

rc=0
# stdin is closed explicitly: the stub reads it to record what it was handed,
# and a test that inherits a live stdin blocks there forever instead of failing.
run() { : > "$GH_STUB_LOG"; gh "$@" </dev/null >/dev/null 2>"$tmp/err"; rc=$?; }
reached() { grep -q '^REACHED:' "$GH_STUB_LOG"; }
said() { grep -q "$1" "$tmp/err"; }

# ---- with no checkers registered --------------------------------------------
# The shim must still pass the command through -- a guard is not allowed to
# break the tool it fronts -- but it must say that it inspected nothing.
run pr create --title t --body b
eq    "no checkers: the command still runs" "$rc" 0
ok_if "no checkers: reaches gh anyway" reached
ok_if "no checkers: says nothing was inspected" said 'nothing was inspected'

harness_install_checker "$tmp/checks"

# ---- subcommands that carry no text -----------------------------------------
run pr list
eq    "pr list: exits 0" "$rc" 0
ok_if "pr list passes through" reached
run pr view 10
ok_if "pr view passes through" reached

# ---- the pair that matters --------------------------------------------------
run pr create --title clean --body "a clean body"
eq    "clean body: exits 0" "$rc" 0
ok_if "clean body reaches gh" reached

run pr create --title clean --body "this is classified"
eq      "dirty body is refused" "$rc" 1
not_if  "dirty body never reaches gh" reached
ok_if   "the checker's own reason is shown" said "says 'classified'"

# The title is text too, and is the field most likely to be pasted in from
# somewhere else.
run pr create --title "this is classified" --body ok
eq "dirty title is refused" "$rc" 1

run pr create --title t --body=this-is-classified
eq "dirty --body=VALUE is refused" "$rc" 1

run issue comment 4 --body "this is classified"
eq "dirty issue comment is refused" "$rc" 1

# ---- a private target is not this guard's business --------------------------
run pr create -R acme/secret --title t --body "this is classified"
eq    "private target: exits 0" "$rc" 0
ok_if "private target: dirty body passes through" reached

# ---- --body-file, including stdin -------------------------------------------
printf 'a clean body from a file\n' > "$tmp/body.md"
run pr create --title t --body-file "$tmp/body.md"
ok_if "clean --body-file reaches gh" reached

printf 'this is classified\n' > "$tmp/dirty.md"
run pr create --title t --body-file "$tmp/dirty.md"
eq "dirty --body-file is refused" "$rc" 1

: > "$GH_STUB_LOG"
printf 'a clean body on stdin\n' | gh pr create --title t --body-file - >/dev/null 2>&1
ok_if "stdin body is replayed to gh, not swallowed" \
    grep -q 'STDIN:a clean body on stdin' "$GH_STUB_LOG"

: > "$GH_STUB_LOG"
printf 'this is classified\n' | gh pr create --title t --body-file - >/dev/null 2>&1
not_if "dirty stdin body never reaches gh" reached

# ---- the override -----------------------------------------------------------
: > "$GH_STUB_LOG"
CMD_SHIMS_DISABLE=1 gh pr create --title t --body "this is classified" </dev/null >/dev/null 2>&1
ok_if "CMD_SHIMS_DISABLE=1 passes through" reached

# ---- the editor path --------------------------------------------------------
# With no --body, gh opens an editor and the text never reaches argv, so the
# shim must hand gh an editor of its own rather than give up on a body it
# cannot see.
run pr create --title t
ok_if "no --body: the command still reaches gh" reached

cat > "$tmp/dirty-editor" <<'ED'
#!/usr/bin/env bash
printf 'this is classified\n' > "$1"
ED
cat > "$tmp/clean-editor" <<'ED'
#!/usr/bin/env bash
printf 'a perfectly ordinary body\n' > "$1"
ED
chmod +x "$tmp/dirty-editor" "$tmp/clean-editor"

CMD_SHIMS_REAL_EDITOR="$tmp/dirty-editor" SHIM_CHECKS_DIR="$tmp/checks" \
    "$ROOT/shims/editor-guard" "$tmp/msg.txt" >/dev/null 2>"$tmp/err"
eq    "editor-guard refuses a dirty body" "$?" 1
ok_if "editor-guard keeps the user's text" grep -q classified "$tmp/msg.txt"

CMD_SHIMS_REAL_EDITOR="$tmp/clean-editor" SHIM_CHECKS_DIR="$tmp/checks" \
    "$ROOT/shims/editor-guard" "$tmp/msg2.txt" >/dev/null 2>&1
eq "editor-guard accepts a clean body" "$?" 0

harness_report gh-shim

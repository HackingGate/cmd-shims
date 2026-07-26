#!/usr/bin/env bash
# The extensibility tests: can somebody who does not own this repository add a
# command, and override one?
#
# This is the property that makes cmd-shims comparable to rg-policy (a
# `policy/*.toml` in the consuming repo) and git-guards (hook ids and env in
# the consuming repo). If adding a command means editing commands/ in here,
# then the bundled specs are the product and everyone else forks -- so the
# assertions below use a spec that exists only in a temporary directory, for a
# command this repository has never heard of.
set -uo pipefail

ROOT="$(cd -- "$(dirname -- "$(readlink -f -- "${BASH_SOURCE[0]}")")/.." && pwd)"
# shellcheck source-path=SCRIPTDIR
# shellcheck source=harness.sh
. "$(dirname -- "$(readlink -f -- "${BASH_SOURCE[0]}")")/harness.sh"

mkdir -p "$tmp/real" "$tmp/bin" "$tmp/checks" "$tmp/myspecs"
harness_install_checker "$tmp/checks"

# A command nothing in this repository knows about.
cat > "$tmp/real/deploybot" <<'STUB'
#!/usr/bin/env bash
{ printf 'REACHED:'; printf ' %s' "$@"; printf '\n'; } >> "$STUB_LOG"
exit 0
STUB
chmod +x "$tmp/real/deploybot"

# ...described entirely from outside, in eight lines.
cat > "$tmp/myspecs/deploybot.spec" <<'SPEC'
SPEC_MATCH="announce:*"
SPEC_TEXT_FLAGS="--message"
SPEC_ARGV_SUBJECT=1
SPEC

export STUB_LOG="$tmp/log"
export XDG_CACHE_HOME="$tmp/cache"
export CMD_SHIMS_CHECKS_DIR="$tmp/checks"
export PATH="$tmp/bin:$tmp/real:$PATH"

# A command this repository has never heard of needs no file here at all: the
# one shim, symlinked under that name, loads the spec matching the name.
rm -f "$tmp/bin/deploybot"
ln -sf "$ROOT/shims/shim" "$tmp/bin/deploybot"

rc=0
run() { : > "$STUB_LOG"; "$@" </dev/null >/dev/null 2>"$tmp/err"; rc=$?; }
reached() { grep -q '^REACHED:' "$STUB_LOG"; }

# ---- a spec from outside this repository ------------------------------------
CMD_SHIMS_SPECS="$tmp/myspecs" run deploybot announce --message "an ordinary release"
eq    "third-party spec: clean text passes" "$rc" 0
ok_if "third-party spec: reaches the real command" reached

CMD_SHIMS_SPECS="$tmp/myspecs" run deploybot announce --message "this is classified"
eq     "third-party spec: dirty text is refused" "$rc" 1
not_if "third-party spec: never reaches the real command" reached

CMD_SHIMS_SPECS="$tmp/myspecs" run deploybot status
eq "third-party spec: an unmatched subcommand passes through" "$rc" 0

# SPEC_ARGV_SUBJECT hands the whole command line over, for guards that are
# about what is being RUN rather than what is being written.
CMD_SHIMS_SPECS="$tmp/myspecs" run deploybot announce --to classified-cluster
eq "argv subject: a flag value nobody declared is still seen" "$rc" 1

# ---- discovered from the tree, with no environment at all -------------------
mkdir -p "$tmp/project/.cmd-shims/commands"
cp "$tmp/myspecs/deploybot.spec" "$tmp/project/.cmd-shims/commands/"
(cd "$tmp/project" && : > "$STUB_LOG" && deploybot announce --message "this is classified" \
    </dev/null >/dev/null 2>"$tmp/err")
eq "in-tree .cmd-shims/commands is found from \$PWD" "$?" 1

(cd "$tmp/project" && : > "$STUB_LOG" && deploybot announce --message "fine" \
    </dev/null >/dev/null 2>"$tmp/err")
eq "in-tree spec: clean text still passes" "$?" 0

# ---- a bundled spec can be overridden, not just extended --------------------
# `gh pr create` is refused by the bundled spec only for a public repo. A local
# spec that matches nothing must therefore let it straight through, proving the
# nearer file won rather than merging.
cat > "$tmp/myspecs/gh.spec" <<'SPEC'
SPEC_MATCH=""
SPEC
cat > "$tmp/real/gh" <<'STUB'
#!/usr/bin/env bash
case "$1 $2" in
  "api repos/acme/public") echo public; exit 0 ;;
  "repo view")             echo acme/public; exit 0 ;;
esac
{ printf 'REACHED:'; printf ' %s' "$@"; printf '\n'; } >> "$STUB_LOG"
exit 0
STUB
chmod +x "$tmp/real/gh"
rm -f "$tmp/bin/gh"
ln -sf "$ROOT/shims/shim" "$tmp/bin/gh"

run gh pr create --title t --body "this is classified"
eq "bundled gh spec refuses a dirty body" "$rc" 1

CMD_SHIMS_SPECS="$tmp/myspecs" run gh pr create --title t --body "this is classified"
eq    "a nearer gh.spec overrides the bundled one" "$rc" 0
ok_if "...and the command runs" reached

# ---- a checker is told WHAT it is holding -----------------------------------
# Without the kind, a checker that judges branch names and one that reads prose
# have to guess from the content, and both are wrong on the first ambiguous
# value. This checker refuses nothing except by kind.
cat > "$tmp/kind-checker" <<'CHK'
#!/usr/bin/env bash
cat >/dev/null
[ "$CMD_SHIMS_KIND" = argv ] && { echo "kind was argv" >&2; exit 1; }
exit 0
CHK
chmod +x "$tmp/kind-checker"

CMD_SHIMS_CHECKS="$tmp/kind-checker" CMD_SHIMS_CHECKS_DIR=/nonexistent \
    CMD_SHIMS_SPECS="$tmp/myspecs" run deploybot announce --message "anything"
eq "the subject kind reaches the checker" "$rc" 1

CMD_SHIMS_CHECKS="$tmp/kind-checker" CMD_SHIMS_CHECKS_DIR=/nonexistent \
    CMD_SHIMS_SPECS="$tmp/myspecs" run deploybot status
eq "...and an unmatched subcommand still has no subjects at all" "$rc" 0

# ---- checkers come from the tree too ----------------------------------------
# The mirror of the spec path. A repository that can describe its own commands
# but not supply its own checkers is extensible in the half that does not hold
# the policy -- and .cmd-shims/checks is where a checker that knows something
# confidential belongs, because a private repository can hold that list and a
# public one cannot.
mkdir -p "$tmp/project/.cmd-shims/checks"
cat > "$tmp/project/.cmd-shims/checks/local-rule" <<'CHK'
#!/usr/bin/env bash
grep -qi 'projectword' && { echo "checker: local rule" >&2; exit 1; }
exit 0
CHK
chmod +x "$tmp/project/.cmd-shims/checks/local-rule"

(cd "$tmp/project" && deploybot announce --message "mentions projectword" \
    </dev/null >/dev/null 2>"$tmp/err")
eq "in-tree .cmd-shims/checks is found from \$PWD" "$?" 1

(cd "$tmp/project" && deploybot announce --message "nothing of the sort" \
    </dev/null >/dev/null 2>"$tmp/err")
eq "in-tree checker allows unrelated text" "$?" 0

# A nearer checker must not be able to switch off one further away: all of them
# run, unlike specs where the nearest wins.
(cd "$tmp/project" && deploybot announce --message "this is classified" \
    </dev/null >/dev/null 2>"$tmp/err")
eq "an in-tree checker does not shadow the registered one" "$?" 1

harness_report extend

#!/usr/bin/env bash
# Behaviour tests for the git shim.
#
# This is the suite that proves the spec generalises. git's published text is
# positional, not a flag value, so commands/git.spec replaces engine_collect
# outright -- and if that override mechanism did not work, everything here would
# fail while the gh suite stayed green.
set -uo pipefail

ROOT="$(cd -- "$(dirname -- "$(readlink -f -- "${BASH_SOURCE[0]}")")/.." && pwd)"
# shellcheck source-path=SCRIPTDIR
# shellcheck source=harness.sh
. "$(dirname -- "$(readlink -f -- "${BASH_SOURCE[0]}")")/harness.sh"

# The real git, which is NOT `command -v git` once this repository is actually
# installed: ~/.local/bin/git is then the shim, and a suite whose fixtures are
# built with the thing under test measures nothing and takes forever doing it.
real_git_binary() {
    local dir shim
    shim="$(readlink -f -- "$ROOT/shims/shim")"
    local IFS=:
    for dir in $PATH; do
        # One condition per guard: see the note in lib/shim.sh. An empty PATH
        # element means the current directory, which must not supply the git a
        # fixture is built with.
        [ -n "$dir" ] || continue
        [ -x "$dir/git" ] || continue
        [ "$(readlink -f -- "$dir/git")" = "$shim" ] && continue
        printf '%s\n' "$dir/git"; return 0
    done
    return 1
}
REAL_GIT="$(real_git_binary)" || { echo "no unshimmed git found" >&2; exit 1; }

mkdir -p "$tmp/real" "$tmp/bin" "$tmp/checks"
harness_install_checker "$tmp/checks"

# A git that records the two verbs under guard and delegates everything else to
# the real one -- the spec itself runs `git remote get-url` and
# `git symbolic-ref`, so those have to keep working through the shim.
cat > "$tmp/real/git" <<STUB
#!/usr/bin/env bash
if [ "\$1" = push ] || [ "\$1" = commit ]; then
    { printf 'REACHED:'; printf ' %s' "\$@"; printf '\n'; } >> "\$GIT_STUB_LOG"
    exit 0
fi
exec "$REAL_GIT" "\$@"
STUB
chmod +x "$tmp/real/git"

cat > "$tmp/real/gh" <<'STUB'
#!/usr/bin/env bash
case "$*" in
  *"repos/acme/public"*) echo public;  exit 0 ;;
  *"repos/acme/secret"*) echo private; exit 0 ;;
esac
exit 1
STUB
chmod +x "$tmp/real/gh"
ln -sf "$ROOT/shims/shim" "$tmp/bin/git"

export GIT_STUB_LOG="$tmp/log"
export XDG_CACHE_HOME="$tmp/cache"
export CMD_SHIMS_CHECKS_DIR="$tmp/checks"
export PATH="$tmp/bin:$tmp/real:$PATH"

# The work tree is built with the real git by absolute path: the shim is what
# is under test, not what the fixture is made with.
work="$tmp/work"
"$REAL_GIT" init -q -b main "$work"
cd "$work" || exit 1
"$REAL_GIT" config user.email t@example.com
"$REAL_GIT" config user.name Test
"$REAL_GIT" remote add origin https://github.com/acme/public.git
echo hello > file.txt
"$REAL_GIT" add file.txt
"$REAL_GIT" commit -qm "initial"

rc=0
run() { : > "$GIT_STUB_LOG"; git "$@" </dev/null >/dev/null 2>"$tmp/err"; rc=$?; }
reached() { grep -q '^REACHED:' "$GIT_STUB_LOG"; }

# ---- subcommands that publish nothing ---------------------------------------
run status
eq "status: exits 0" "$rc" 0

# ---- a branch name is published text ----------------------------------------
# No git hook reads it: pre-push is handed the refs, but the guards that read
# them judge the destination, never the name.
run push origin main
eq    "clean branch name: exits 0" "$rc" 0
ok_if "clean branch name reaches git" reached

run push origin classified-incident
eq     "dirty branch name is refused" "$rc" 1
not_if "dirty branch name never reaches git" reached

# ---- the name git infers when argv has none ---------------------------------
"$REAL_GIT" checkout -q -b fix/classified-outage
run push
eq     "dirty CURRENT branch is refused with no refspec" "$rc" 1
not_if "...and never reaches git" reached

"$REAL_GIT" checkout -q main
run push
eq "clean current branch passes with no refspec" "$rc" 0

# ---- a refspec has two halves, and both are published -----------------------
run push origin main:classified-branch
eq "dirty refspec destination is refused" "$rc" 1

# ---- a private target is not this guard's business --------------------------
"$REAL_GIT" remote set-url origin https://github.com/acme/secret.git
run push origin classified-incident
eq    "private target: exits 0" "$rc" 0
ok_if "private target: dirty name passes through" reached
"$REAL_GIT" remote set-url origin https://github.com/acme/public.git

# ---- a commit message, only when it is skipping commit-msg ------------------
run commit --allow-empty -m "this is classified"
eq    "dirty message WITHOUT --no-verify passes through" "$rc" 0
ok_if "...because commit-msg is the guard that owns it" reached

run commit --allow-empty --no-verify -m "this is classified"
eq     "dirty message WITH --no-verify is refused" "$rc" 1
not_if "...and never reaches git" reached

run commit --allow-empty -n -m "this is classified"
eq "the short spelling -n is refused too" "$rc" 1

run commit --allow-empty --no-verify -m "an ordinary message"
eq "clean message with --no-verify passes" "$rc" 0

cd / || exit 1
harness_report git-shim

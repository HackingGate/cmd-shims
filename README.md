# cmd-shims

Guards for what a command puts somewhere public, on the paths git hooks cannot
reach — a pull request body typed into `gh pr create`, a branch name pushed to
a public forge, a `README.md` sent to a registry by `npm publish`.

[rg-policy](https://github.com/HackingGate/rg-policy) checks a repository's
content and takes its rules from your `policy/rg-policy.toml`.
[git-guards](https://github.com/HackingGate/git-guards) checks what git does
and takes its hook ids from your `.pre-commit-config.yaml`. This checks what a
command does, and takes its specs from your `.cmd-shims/commands/`.

One shim binary is installed under the name of the command it guards; the name
selects the spec. It execs straight through unless the invocation matches the
spec **and** `spec_in_scope` says the destination is worth checking, so
`gh pr list` costs one `exec`.

## Checks

What refuses. Bundled in [`checks/base/`](checks/base), and **off until named**.

| check | kinds | the rule it runs |
|---|---|---|
| [`no-private-repo-names`](checks/base/no-private-repo-names) | `text` `ref` `argv` | git-guards `no-private-repo-names.sh --text` |
| [`prevent-unusual-unicode`](checks/base/prevent-unusual-unicode) | `text` `ref` | git-guards `prevent-unusual-unicode-in-files.py` |
| [`prevent-ai-author`](checks/base/prevent-ai-author) | `text` | git-guards `prevent-ai-author.sh` |

A kind is what the engine says a subject *is*: `text` is prose, `ref` a branch
or tag name, `path` a file tree, `argv` the whole command line.

```sh
./install.sh --list-checks                     # what there is, and what is on
./install.sh --enable no-private-repo-names    # -> ~/.config/cmd-shims/checks.enabled
```

```sh
# .cmd-shims/checks.enabled — in YOUR repository, where a reviewer sees it
no-private-repo-names
prevent-unusual-unicode
```

Rule bodies belong in git-guards, so these hold none. Each is an adapter: it
decides whether the subject it was handed is the kind its rule judges, and hands
it to the script that already holds that rule. They carry the **same names as
the git-guards hook ids**, because two tiers running one rule under two names is
how they start disagreeing.

They ship off for the reason rg-policy ships `policy/base/*.toml` behind
`extends` and git-guards ships its hook scripts behind a list of ids: nothing
starts refusing because somebody ran `git pull`, and nobody has to invent a rule
to get started.

### What Each One Is For

`no-private-repo-names` keeps a private repository's name out of a public place
that is not a commit. Its rule already has a `--text` mode written for this
caller — a body typed into a CLI reaches a public API without passing a single
hook, and so do issue titles, release notes and branch names.

`prevent-unusual-unicode` picks its mode from the kind, because git-guards has
two and the difference is load-bearing. A ref is a short name whose legitimate
vocabulary is nameable, so it gets the whitelist. A body is prose, and prose
legitimately carries emoji in a checklist and box drawing in a diagram, so it
gets the invisible-character ban instead — control, zero-width, bidi override
(CVE-2021-42574), private-use, and any space that is not `U+0020`.

`prevent-ai-author` is the one with no hook anywhere else. git-guards blocks the
trailers at `commit-msg` and tells you to set `attribution.pr` in your agent —
but that is a setting in a file on whichever machine is running the agent, and
nothing enforces it. A body carrying `Generated with [Claude Code]` reaches a
public repository without meeting a hook, because on that path there is none.

### Enabling

`$CMD_SHIMS_ENABLE`, every `.cmd-shims/checks.enabled` from `$PWD` upward, and
`~/.config/cmd-shims/checks.enabled` are **unioned** — for the reason all
checkers run, that a nearer file must not switch off one further away. There is
deliberately no `disable`: rg-policy can offer `disable_rules` because its
extends and its disables are the same reviewed file, and these arrive from three
places. A name that is enabled and resolves to nothing is reported on **every**
invocation rather than skipped.

A name rather than a symlink into `.cmd-shims/checks`, which also works and
always did: which checks a repository runs is exactly the thing somebody should
be able to read in a diff. Prefer the file to the variable — `CMD_SHIMS_ENABLE`
has the same trap as `CMD_SHIMS_CHECKS`, that the shim runs later from a shell
that never had it, and `install.sh` refuses an install backed by nothing else
for exactly that reason.

git-guards is found via `$CMD_SHIMS_GIT_GUARDS`, a sibling checkout, or the hook
runner's cache — which is where it actually lives for anyone who consumes it as
a pre-commit hook and never cloned it. That copy is whatever `rev:` the
repository pinned, so both tiers run the same version. With it nowhere on the
machine a check says so, loudly, and exits 0: a checker that cannot reach its
rule has not found the text clean, it has not looked.

## Commands

Where it intercepts. Defaults, not the set.

| spec | subjects | in scope when |
|---|---|---|
| [`gh`](commands/gh.spec) | PR/issue/release/gist titles and bodies, review comments | the target repo is public |
| [`glab`](commands/glab.spec) | MR/issue/release/snippet titles, descriptions, notes | project visibility is `public` |
| [`git`](commands/git.spec) | branch and tag names on push; a commit message under `--no-verify` | the push target is public |
| [`npm`](commands/npm.spec) | package name, description, `README.md`, the published tree | not `"private": true`, registry is npmjs.org |

`git` covers what no git hook is placed to read. A branch name reaches a public
forge the moment it is pushed; `pre-push` *is* handed the refs, but the guards
that read them judge the **destination** against an owner allow-list and never
the name. With no refspec in argv it checks the branch git is about to infer.
It also checks a message under `--no-verify`, since that flag exists precisely
to skip `commit-msg` — without it the message is left alone, because
`commit-msg` owns it.

`npm` has no repository, owner or visibility endpoint, and what it publishes is
a file tree rather than prose. It is bundled to keep `spec_in_scope` from
quietly meaning "is the repo public".

## Usage

```sh
./install.sh gh git             # symlinks into ~/.local/bin
./install.sh --list             # every command with a spec on the spec path
./install.sh --list-checks      # every bundled check, and which are on
./install.sh --enable prevent-ai-author
./install.sh --uninstall gh
```

It refuses a name with no spec, refuses to install with no checkers the shim
will still find when it runs — an enabled bundled check is one — and warns when
PATH reaches the real command first: the three ways an installed shim can be
inert while looking installed.

| variable | effect |
|---|---|
| `CMD_SHIMS_SPECS` | extra spec directories, colon-separated |
| `CMD_SHIMS_CHECKS` | extra checkers: colon-separated files or directories |
| `CMD_SHIMS_ENABLE` | bundled checks to turn on, by name |
| `CMD_SHIMS_CHECKS_DIR` | replace the built-in `checks/` directory |
| `CMD_SHIMS_GIT_GUARDS` | the git-guards checkout the bundled checks call |
| `CMD_SHIMS_BIN` | install target (default `~/.local/bin`) |
| `CMD_SHIMS_DISABLE=1` | one-off bypass |

## Writing a Spec

```sh
# .cmd-shims/commands/deploybot.spec — in YOUR repository
SPEC_MATCH="announce:*"
SPEC_TEXT_FLAGS="--message"
```

```sh
cmd-shims/install.sh deploybot
```

Specs are found nearest-first, **first match wins**, so overriding a bundled
spec is a file with the same name rather than a fork.

| | |
|---|---|
| `$CMD_SHIMS_SPECS` | colon-separated, highest priority |
| `./.cmd-shims/commands` | your repository, found from `$PWD` upward |
| `~/.config/cmd-shims/commands` | per-user |
| `<this repo>/commands` | the bundled defaults, searched last |

### Spec Format

| key | meaning |
|---|---|
| `SPEC_MATCH` | invocations to inspect: `verb:noun`, `verb:*`, or `*` |
| `SPEC_TEXT_FLAGS` | flags whose **value** is a text subject |
| `SPEC_FILE_FLAGS` | flags whose value **names a file** of text (`-` is stdin) |
| `SPEC_PATH_FLAGS` | flags whose value is a filesystem path subject |
| `SPEC_TARGET_FLAGS` | flags naming where this is going |
| `SPEC_SKIP_FLAGS` | flags supplying a subject from an already-guarded source |
| `SPEC_WEB_FLAGS` | flags that move authoring into a browser |
| `SPEC_ARGV_SUBJECT` | `1` to hand checkers the whole command line as well |
| `SPEC_EDITOR_ENV` | the env var this command reads to find its editor |

| function | contract | default |
|---|---|---|
| `spec_in_scope` | exit 0 when this invocation is worth checking | always in scope |
| `spec_target` | print where this is going, or fail | no target |
| `engine_collect` | override when subjects are not flag values | walks argv per the flag lists |

Name subcommands rather than pattern-matching them: a spec that guesses is one
release away from missing a new one in silence. `--flag=value` and
`--flag value` are the same flag; the engine splits them. To ask a forge
whether something is public call `shim_cached_visibility`, which caches for a
week and stores **only definite answers** — a forge returns the same "not
found" for a private repository as for one that does not exist.

## Writing a Checker

Any executable. The subject arrives on **stdin**, its kind beside it. Exit
non-zero to refuse; what it writes becomes the reason. That reason is always
shown on **stderr**, including whatever the checker put on stdout: the shim's
stdout belongs to the command it stands in front of, and one line landing in
`gh pr view --json` corrupts a parse the checker had nothing to do with.

```sh
#!/usr/bin/env bash
[ "$CMD_SHIMS_KIND" = ref ] || exit 0        # branch names only
grep -qi 'internal' && { echo "branch names go on a public forge" >&2; exit 1; }
```

| variable | |
|---|---|
| `CMD_SHIMS_KIND` | `text`, `path`, `ref`, `argv` |
| `CMD_SHIMS_COMMAND` / `CMD_SHIMS_SUBCOMMAND` | what was run |
| `CMD_SHIMS_TARGET` | where it is going, if the spec knows |

Checkers are discovered like specs — `$CMD_SHIMS_CHECKS`, then
`.cmd-shims/checks` from `$PWD` upward, then `~/.config/cmd-shims/checks`, then
this repo's `checks/`. Unlike specs, **all** of them run: a spec describes one
command and the nearest wins, but a checker is an opinion about what may be
published, and a nearer file must not silently switch off one further away.
`.cmd-shims/checks` in a private repository is the right home for a checker
that knows something confidential — a private repo can hold the list of what
must not be published, and a public one cannot.

`checks/` — the directory that *runs* — ships **empty**: the interception is
general, what counts as publishable is not. The list of what is private belongs
in neither repository and should reach a checker through the environment. What
ships populated is [`checks/base/`](checks/base), which runs nothing until it is
named.

## Limits

Not covered: `--web`, `gh api`/`glab api` (which can `PATCH` a body without
matching a subcommand), anything typed into a forge's website, and any machine
without the shim installed. No bundled check judges the `path` kind either —
`npm publish` hands one over, and what it holds is a repository's files, which
is rg-policy's question rather than a checker's. It is bypassable on purpose —
the same bargain `--no-verify` makes. The tier that cannot be talked out of it
runs in CI.

Every shim **fails open**: a tripped parser, an unresolvable target or a silent
forge means it becomes the real command rather than refusing. What it will not
do is pass silently — with no checkers registered it says so every time,
because "inspected nothing" and "found nothing" must never look alike.

## Updating

There is no `rev:` to pin: a shim is on PATH, not fetched per repo, so a clone
is the version and `git pull` is the upgrade. Specs live in the consuming
repository, so an upgrade changes the engine and the bundled defaults, never
your commands. A bundled check that arrives in an upgrade is off until you name
it, so `git pull` never starts refusing something new on its own. Visibility
answers are cached under `${XDG_CACHE_HOME:-~/.cache}/cmd-shims` for a week —
if a repo's visibility changed and the shim disagrees, that is the first thing
to check.

Requires bash 4.3+ and GNU coreutils (`readlink -f`); `tests/run-all.sh` runs
the suites.

# cmd-shims

Guards for what a command puts somewhere public, on the paths git hooks cannot
reach — a pull request body typed into `gh pr create`, a branch name pushed to a
public forge, a `README.md` sent to a registry by `npm publish`.

One shim binary is installed under the name of the command it guards; the name
selects the spec, read from your `.cmd-shims/commands/`. Sibling tiers:
[git-guards](https://github.com/HackingGate/git-guards) checks what git does,
[rg-policy](https://github.com/HackingGate/rg-policy) checks a repository's content.

## Checks

What refuses. Bundled in [`checks/base/`](checks/base) and **off until named** — see
[`checks/README.md`](checks/README.md) for enabling and the two-directory split. A
kind is what the engine says a subject *is*: `text` is prose, `ref` a branch or tag
name, `path` a file tree, `argv` the whole command line.

| check | kinds | the rule it runs |
|---|---|---|
| [`no-private-repo-names`](checks/base/no-private-repo-names) | `text` `ref` `argv` | git-guards `no-private-repo-names.sh --text` |
| [`prevent-unusual-unicode`](checks/base/prevent-unusual-unicode) | `text` `ref` | git-guards `prevent-unusual-unicode-in-files.py`. A `ref` gets the whitelist, prose gets the invisible-character ban — so emoji pass in a body and fail in a branch name |
| [`prevent-ai-author`](checks/base/prevent-ai-author) | `text` | git-guards `prevent-ai-author.sh` |
| [`no-os-identity`](checks/base/no-os-identity) | `text` `ref` `argv` | rg-policy `check_policy.py --check-text`. Where the repo declares no policy, rg-policy's built-in identity rule applies |

## Commands

Where it intercepts. Defaults, not the set.

| spec | subjects | in scope when |
|---|---|---|
| [`gh`](commands/gh.spec) | PR/issue/release/gist titles and bodies, review comments | the target repo is public |
| [`glab`](commands/glab.spec) | MR/issue/release/snippet titles, descriptions, notes | project visibility is `public` |
| [`git`](commands/git.spec) | branch and tag names on push (with no refspec, the branch git would infer); a commit message under `--no-verify` | the push target is public |
| [`npm`](commands/npm.spec) | package name, description, `README.md`, the published tree | not `"private": true`, registry is npmjs.org |

## Usage

```sh
./install.sh gh git             # symlinks into ~/.local/bin
./install.sh --list             # every command with a spec on the spec path
./install.sh --list-checks      # every bundled check, and which are on
./install.sh --enable prevent-ai-author
./install.sh --uninstall gh
```

It refuses a name with no spec, refuses to install with no checkers the shim will
still find when it runs, and warns when PATH reaches the real command first.

| variable | effect |
|---|---|
| `CMD_SHIMS_SPECS` | extra spec directories, colon-separated |
| `CMD_SHIMS_CHECKS` | extra checkers: colon-separated files or directories |
| `CMD_SHIMS_ENABLE` | bundled checks to turn on, by name |
| `CMD_SHIMS_CHECKS_DIR` | replace the built-in `checks/` directory |
| `CMD_SHIMS_GIT_GUARDS` | the git-guards checkout the bundled checks call. Else a sibling checkout, the hook runner's cache, or PATH |
| `CMD_SHIMS_RG_POLICY` | the rg-policy checkout, or a direct path to `check_policy.py`. Else a sibling checkout or the hook runner's cache |
| `CMD_SHIMS_BIN` | install target (default `~/.local/bin`) |
| `CMD_SHIMS_NAME` | override the name the shim believes it was invoked as |
| `CMD_SHIMS_DISABLE=1` | one-off bypass |

Visibility answers are cached under `${XDG_CACHE_HOME:-~/.cache}/cmd-shims` for a
week — if a repo's visibility changed and the shim disagrees, check that first.

## Writing a Spec

```sh
# .cmd-shims/commands/deploybot.spec — in YOUR repository
SPEC_MATCH="announce:*"
SPEC_TEXT_FLAGS="--message"
```

Then `cmd-shims/install.sh deploybot`. Specs are found nearest-first — `$CMD_SHIMS_SPECS`,
then `./.cmd-shims/commands` from `$PWD` upward, then `~/.config/cmd-shims/commands`,
then this repo's `commands/` — and the **first match wins**, so overriding a bundled
spec is a same-named file rather than a fork.

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
| `spec_in_scope` | function: exit 0 when this invocation is worth checking (default: always) |
| `spec_target` | function: print where this is going, or fail (default: no target) |
| `engine_collect` | function: override when subjects are not flag values (default: walks argv per the flag lists) |

`--flag=value` and `--flag value` are the same flag; the engine splits them. To ask
a forge whether something is public call `shim_cached_visibility`.

## Writing a Checker

Any executable. The subject arrives on **stdin**, its kind beside it; exit non-zero
to refuse, and what it writes becomes the reason. All checker output is shown on
**stderr** — the shim's stdout belongs to the command it stands in front of.

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

Checkers are discovered like specs — `$CMD_SHIMS_CHECKS`, then `.cmd-shims/checks`
from `$PWD` upward, then `~/.config/cmd-shims/checks`, then this repo's `checks/`.
Unlike specs, **all** of them run; a nearer file cannot switch off one further away.

## Limits

Not covered: `--web`, `gh api`/`glab api` (which can `PATCH` a body without matching
a subcommand), anything typed into a forge's website, and any machine without the
shim installed. No bundled check judges the `path` kind.

Every shim **fails open**: a tripped parser, an unresolvable target or a silent forge
means it becomes the real command rather than refusing. With no checkers registered it
says so every time.

There is no `rev:` to pin — a shim is on PATH, not fetched per repo, so a clone is the
version and `git pull` is the upgrade. A bundled check that arrives in an upgrade is
off until you name it. Requires bash 4.0+ and GNU coreutils (`readlink -f`);
`tests/run-all.sh` runs the suites.

# checks

Executables consulted by every shim. Each receives the subject on stdin, its kind
in `CMD_SHIMS_KIND`, exits non-zero to refuse, and writes its reason to stderr.

Two directories, and the difference between them is the whole arrangement:

| | |
|---|---|
| `checks/` | runs. Ships **empty**, and every checker found here or on the checks path runs on every subject. |
| `checks/base/` | the bundled set. Ships **populated**, and runs nothing until a check is named. |

`checks/` is empty because the interception is general and what counts as
publishable is not; a default policy invented here would be wrong for everyone and
silently trusted by someone. Shipping the bundled set off keeps both properties:
nothing starts refusing because somebody ran `git pull`, and nobody has to invent a
rule to get started.

`.cmd-shims/checks` in a **private** repository is the right home for a checker that
knows something confidential — a private repo can hold the list of what must not be
published, and a public one cannot.

## Enabling

One name per line, `#` comments ignored:

```sh
./install.sh --list-checks                 # what there is, and what is on
./install.sh --enable prevent-ai-author    # -> ~/.config/cmd-shims/checks.enabled
```

```sh
# .cmd-shims/checks.enabled — in a repository, where a reviewer sees it
no-private-repo-names
prevent-unusual-unicode
```

Every source is unioned — `$CMD_SHIMS_ENABLE`, each `.cmd-shims/checks.enabled` from
`$PWD` upward, then the per-user file. None shadows another, for the reason all
checkers run: a nearer file must not be able to switch a further one off. There is
deliberately no `disable`.

A name that is enabled and not present here is reported on every invocation rather
than skipped, because "the config says this check is on" and "this check ran" must
never look alike.

## What the Bundled Checks Are

Adapters, not rules. Each decides whether the subject it was handed is the kind its
rule judges, and hands it to the script that already holds that rule — see
[`lib/git-guards.sh`](../lib/git-guards.sh) and [`lib/rg-policy.sh`](../lib/rg-policy.sh)
for how those are found. A rule with two implementations is two rules that agree
until they do not.

Every rule body reachable from here answers to one calling convention: the subject
on stdin (or a file), exit `0` clean, `1` refused, `2` could not look.
`no-private-repo-names.sh --text -` and `check_policy.py --check-text -` are the same
shape on purpose, so adding a third tier never means writing a fourth copy of a rule.

That `2` belongs to the upstream rule bodies, not to a checker you write: the shim
maps **any** non-zero from a checker to refused.

Without the upstream repo on the machine a bundled check says so, loudly, and exits
0: a checker that cannot reach its rule has not found the text clean, it has not
looked.

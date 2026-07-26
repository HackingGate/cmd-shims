# checks

Executables consulted by every shim. Each receives the subject on stdin, its
kind in `CMD_SHIMS_KIND`, exits non-zero to refuse, and writes its reason to
stderr.

Two directories, and the difference between them is the whole arrangement:

| | |
|---|---|
| `checks/` | runs. Ships **empty**, and every checker found here or on the checks path runs on every subject. |
| `checks/base/` | the bundled set. Ships **populated**, and runs nothing until a check is named. |

`checks/` is empty because the interception is general and what counts as
publishable is not; a default policy invented here would be wrong for everyone
and silently trusted by someone. `checks/base/` is populated because the
neighbouring repositories ship their rules too — [rg-policy](https://github.com/HackingGate/rg-policy)
has `policy/base/*.toml` behind `extends`, [git-guards](https://github.com/HackingGate/git-guards)
has the hook scripts behind a list of ids — and a repository that ships the
mechanism with no rules leaves everyone to write the same three from scratch.

Shipping them off is what keeps both properties: nothing starts refusing
because somebody ran `git pull`, and nobody has to invent a rule to get started.

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

Every source is unioned — `$CMD_SHIMS_ENABLE`, each `.cmd-shims/checks.enabled`
from `$PWD` upward, then the per-user file. None shadows another, for the reason
all checkers run: a nearer file must not be able to switch a further one off.
There is deliberately no `disable`.

A name that is enabled and not present here is reported on every invocation
rather than skipped, because "the config says this check is on" and "this check
ran" must never look alike.

## What the Bundled Checks Are

Adapters, not rules. Each decides whether the subject it was handed is the kind
its rule judges, and hands it to the script in git-guards that already holds
that rule — see [`lib/git-guards.sh`](../lib/git-guards.sh) for how that script
is found. A rule with two implementations is two rules that agree until they do
not, and the one place these belong is the repository that already publishes
them.

Without git-guards on the machine they say so, loudly, and exit 0: a checker
that cannot reach its rule has not found the text clean, it has not looked.

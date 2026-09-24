# Fork maintenance

This document describes the `maintained` branch on the RyzeNGrind/firstmate fork, how to keep it current with upstream, and how to point a running home at it.

## What the `maintained` branch is

`maintained` is a long-lived lineage on the [RyzeNGrind/firstmate](https://github.com/RyzeNGrind/firstmate) fork that carries a set of fixes on top of the upstream default branch.
Upstream PRs for these fixes remain open passively; they are not shipped upstream from here.
`fork/main` is kept as a fast-forward mirror of upstream `main` and is never modified directly.

Current fix set (origin commits for reference):

| Fix | Upstream PR |
|-----|-------------|
| guard unbound `$raw` in `fm_pending_reply_new_id` on openssl-less hosts | #5184 |
| Forgejo native PR merge poll support | #5187 |
| nixbuild.net quota usage poll | #5189 |
| raise arm confirm window and release partial locks on timeout | #5190 |
| isolate treehouse worktree pools per firstmate home | #5193 |

## Rebase on upstream advance

When upstream `main` advances, rebase `maintained` onto it to keep the lineage linear.

```sh
git fetch origin
git fetch fork
git checkout maintained
git rebase origin/main
# Resolve any conflicts minimally, preserving each fix's behavior.
# Run the test suite to confirm green:
bin/fm-test-run.sh --changed
bin/fm-lint.sh
# Then push to the fork (do not push fork/main):
git push fork maintained --force-with-lease
```

Adding a new fix to the set:

1. Cherry-pick or rebase the fix branch onto the current `maintained` tip.
2. Run `bin/fm-test-run.sh --changed` and `bin/fm-lint.sh`.
3. Update the fix table above in this file.
4. Push with `--force-with-lease`.

## Pointing a running home at this fork

Edit or create `config/crew-harness` in the target firstmate home directory with no content change needed to the harness itself.
The fork branch is consumed at clone time, not at runtime; update the project clone to pull from the fork instead.

For a fresh home, clone from the fork and specify the branch:

```sh
git clone -b maintained git@github.com:RyzeNGrind/firstmate.git <home-dir>
```

For an existing home already cloned from upstream, re-point the `bin/` and skill surfaces:

```sh
cd <home-dir>
git remote add fork git@github.com:RyzeNGrind/firstmate.git
git fetch fork
git checkout -b maintained --track fork/maintained
```

Firstmate loads `bin/` and `.agents/skills/` from its tracked code root at session start.
After switching branches, restart the firstmate session so the new code takes effect.
`fork/main` and `origin/main` remain usable for comparison; only `maintained` carries the fix set.

# Agent Instructions for nickel-compose

This file applies to AI agents working in the nickel-compose
repo. Generic agent behavior rules (Pre-Session Checklist,
Plan First, Anti-Arrogance Clause) live in the project-level
`/code/AGENTS.md` and are not repeated here.

## Hard rules

- **Never `git reset --hard`, `git push --force`, or `git
  commit --amend` without explicit user instruction.** A
  `--hard` reset in this session already lost work. Reflog
  exists, but trust the user, not the reflog.
- **Commit incrementally.** After every meaningful change
  (contract, function, script, test), commit. Even WIP on a
  `wip/` branch is better than uncommitted work.
- **Tests must stay green.** `bash tests/_run.sh` should
  report 256+/256+ before any commit. If a test breaks, fix
  it before committing.

## Recovery

If the working tree gets clobbered, recover from a zrepl
snapshot:

```bash
bash /code/zepl/recover.sh latest   # mount most recent
# ... copy files back, commit them ...
bash /code/zepl/tidy-up.sh --force  # clean up
```

zrepl takes snapshots every 15 minutes (see
`/code/zepl/zrepl.yml`). Worst-case loss window is 15
minutes of uncommitted work.

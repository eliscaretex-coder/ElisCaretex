@AGENTS.md

## Claude-specific notes

- Work only on `claude/<topic>` branches and deliver through Pull Requests into `master`.
  Never push directly to `master`: every push there deploys to GitHub Pages.
- Before starting, rebase on `origin/master` and read the newest entries in
  `docs/handover/WORKLOG.md`. Codex may have pushed since your last session.
- Reply to the owner in Portuguese.
- `.claude/settings.json` hooks block pushes to `master` and edits to existing migrations,
  and validate the frontend after each edit. Use the `new-migration` skill for database
  changes and the `finish-task` skill before delivering.

# Working inside herdr

When `HERDR_ENV=1`, work that will end in commits runs as a **herdr task**: its own worktree, herdr workspace and
Claude session. A session already in a task's worktree does that task in place; any other work it is asked to start,
including a follow-up, becomes a new task.

Start one with `herdr-task new -p "<hand-off>" <branch> [base]` from any checkout of the repo (`herdr-task --help`). It
prints the new pane's ID. The hand-off is the new session's first prompt and all it knows, so it carries:

- the task itself, as the user put it (e.g. `/implement OVE-17`)
- the base branch, and the PR to stack on when the base isn't the default branch
- what this session already found that the task needs

The task's work then happens in that session. This session reports the pane ID and returns to its own work; follow the
task with `herdr agent get <pane>` / `herdr agent read <pane>` when asked.

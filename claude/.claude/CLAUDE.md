# Working inside herdr

When `HERDR_ENV=1`, work that will end in commits runs as a **herdr task**: its own worktree, herdr workspace and
Claude session. A session already in a task's worktree does that task in place; any other work it is asked to start,
including a follow-up, becomes a new task: `herdr-task new -p "<hand-off>" <branch> [base]` from any checkout of the
repo.

## Where a request belongs

Reading anything anywhere is fine: files, `git log`, `gh`, other sessions' output. A request that changes anything in
another repo, however small (a pull, a checkout, an edit, a command with side effects), goes to that repo's place in
herdr; this session doesn't do it itself.

`herdr-task places <ticket|path|repo>` lists the candidates, most specific first. One direct match (the ticket key, or
a path naming exactly one place) is the go-ahead: act without asking. Several, a fuzzy match, or none: ask, listing
them, and recommend one.

- **this**: do it here.
- **task / session / shell**: `herdr-task send <pane> "<hand-off>"`. For a shell, pick one at a prompt, not one running
  a server.
- **archived**: `herdr-task restore -p "<hand-off>" <ticket>`, not a new task.
- **closed**: tell the user; don't start a duplicate.
- **nothing**: a new task, if the work ends in commits.

The hand-off is the user's request in their words, plus what this session found that the work needs; a new task also
needs the base branch, and the PR to stack on when it isn't the default branch. After handing off, report the pane ID
and stop; follow it with `herdr agent read <pane>` only when asked.

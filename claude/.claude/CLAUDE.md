# Working inside tt

Inside tmux (`$TMUX` set), work that will end in commits runs as a **tt task**: its own worktree, tmux window and
Claude session. A session already in a task's worktree does that task in place; any other work it is asked to start,
including a follow-up, becomes a new task: `tt new -p "<hand-off>" <branch> [base]` from any checkout of the
repo.

One branch, one worktree. This session commits only to the branch its worktree was created for. Every other branch that
gets commits, including branches split out of this one or stacked on it, starts with `tt new` and is built in
that task's session; this session hands off and stops. Splitting a PR: this session plans the split and creates the
tickets; each slice is built in its own task, with a hand-off naming its base branch and what goes in it.

## Where a request belongs

Reading anything anywhere is fine: files, `git log`, `gh`, other sessions' output. A request that changes anything in
another repo, however small (a pull, a checkout, an edit, a command with side effects), goes to that repo's place in
tmux; this session doesn't do it itself.

`tt places <ticket|path|repo>` lists the candidates, most specific first. One direct match (the ticket key, or
a path naming exactly one place) is the go-ahead: act without asking. Several, a fuzzy match, or none: ask, listing
them, and recommend one.

- **this**: do it here.
- **task / session / shell**: `tt send <pane> "<hand-off>"`. For a shell, pick one at a prompt, not one running
  a server.
- **archived**: `tt restore -p "<hand-off>" <ticket>`, not a new task.
- **closed** (a worktree whose window was closed): tell the user, `tt proj` reopens its window; don't start a
  duplicate.
- **nothing**: a new task, if the work ends in commits.

The hand-off is the user's request in their words, plus what this session found that the work needs; a new task also
needs the base branch, and the PR to stack on when it isn't the default branch. After handing off, report the pane ID
and stop; follow it with `tt read <pane>` only when asked.

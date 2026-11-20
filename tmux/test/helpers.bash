# shellcheck shell=bash
# Shared by tt's tests: a tmux server and home of the test's own, throwaway repos, and stand-ins for claude, gh and
# fzf on the PATH.

bats_require_minimum_version 1.5.0
bats_load_library bats-support
bats_load_library bats-assert

tt=$(realpath "$BATS_TEST_DIRNAME/../.local/bin/tt")

# setup_tt: the test's own home, state, tmux server and stubs. tt runs with no terminal on stdin, as from a hook.
setup_tt() {
    # git's hooks export GIT_DIR and the like: run from one, as lefthook runs
    # these, every git call would act on the repo being committed to.
    local var
    for var in $(compgen -e GIT_); do unset "$var"; done
    tmp=$(realpath "$BATS_TEST_TMPDIR")
    export HOME=$tmp/home
    export XDG_STATE_HOME=$HOME/.local/state XDG_CACHE_HOME=$HOME/.cache XDG_RUNTIME_DIR=$tmp/run
    export TT_WORKTREES=$tmp/worktrees TMPDIR=$tmp/tmp GIT_CONFIG_GLOBAL=$HOME/.gitconfig
    # A short path: a socket's can't be over about 100 bytes.
    TMUX_TMPDIR=$(mktemp -d /tmp/tt-test.XXXXXX)
    export TMUX_TMPDIR
    unset TMUX TMUX_PANE FZF_DEFAULT_OPTS
    mkdir -p "$HOME" "$XDG_RUNTIME_DIR" "$TMPDIR" "$tmp/bin"
    git config --global user.name Test
    git config --global user.email test@example.com
    git config --global init.defaultBranch main
    PATH=$tmp/bin:$PATH
    stub_claude
    stub gh 'exit 1'
    stub_fzf
    start_tmux
}

teardown_tt() {
    tmux kill-server 2>/dev/null || true
    rm -rf "$TMUX_TMPDIR"
}

# start_tmux: a server with a plain session "keep", which tt's own tmux calls then use, its panes running bash
# without the user's startup files.
start_tmux() {
    tmux -f /dev/null new-session -d -s keep -c "$HOME" \; set -g default-command 'bash --norc --noprofile'
}

# stub <tool> [script]: a stand-in for the tool that runs the script, such as `exit 1`.
stub() {
    printf '#!/usr/bin/env bash\n%s\n' "${2:-}" >"$tmp/bin/$1"
    chmod +x "$tmp/bin/$1"
}

# stub_claude: a claude that logs its directory and arguments to $tmp/claude.log, then shows what's pasted into it
# under the name claude, which is what tmux sees the pane run.
stub_claude() {
    # shellcheck disable=SC2016 # expanded by the stub
    stub claude 'printf "%s\t%s\n" "$PWD" "$*" >>"'"$tmp"'/claude.log"
exec -a claude cat'
}

# stub_fzf: an fzf that keeps its input in $tmp/fzf.in and its arguments in $tmp/fzf.args, and picks the lines
# matching $FZF_PICK, or none (as esc does).
stub_fzf() {
    # shellcheck disable=SC2016 # expanded by the stub
    stub fzf 'cat >"'"$tmp"'/fzf.in"
printf "%s\n" "$@" >"'"$tmp"'/fzf.args"
[ -n "${FZF_PICK:-}" ] || exit 130
grep -E -- "$FZF_PICK" "'"$tmp"'/fzf.in"'
}

# git_repo <name>: a repo with one commit on main, as the working directory.
git_repo() {
    mkdir -p "$tmp/$1"
    cd "$tmp/$1" || return
    git init -q
    git commit -q --allow-empty -m init
}

# eventually <command...>: retries the command for up to five seconds, for what panes do in their own time.
eventually() {
    local i
    for ((i = 0; i < 50; i++)); do
        "$@" 2>/dev/null && return 0
        sleep 0.1
    done
    "$@"
}

# shows <pane> <text>: whether the pane shows the text.
shows() { tmux capture-pane -p -J -t "$1" | grep -qF "$2"; }

# runs <pane> <program>: whether the pane runs the program, as tmux sees it.
runs() { [ "$(tag "$1" pane_current_command)" = "$2" ]; }

# empty <dir>: whether the directory has nothing in it.
empty() { [ -z "$(ls -A "$1")" ]; }

# claude_ran <dir> <arguments>: whether claude started in the directory with those arguments.
claude_ran() {
    grep -qxF "$1$(printf '\t')$2" "$tmp/claude.log" 2>/dev/null
}

# tag <target> <option>: a tmux user option of a session, window or pane.
tag() { tmux display -p -t "$1" "#{$2}"; }

# window_of <task path>: the window of the task in that worktree.
window_of() {
    tmux list-windows -a -F '#{window_id} #{@task_path}' | awk -v p="$1" '$2 == p { print $1 }'
}

# conversation <dir> <session>: a Claude Code conversation started in the directory, as tt finds it to resume it.
conversation() {
    local dir=$HOME/.claude/projects/${1//[^A-Za-z0-9]/-}
    mkdir -p "$dir"
    touch "$dir/$2.jsonl"
}

# pane_of <task path>: the pane of the task in that worktree.
pane_of() { tmux display -p -t "$(window_of "$1")" '#{pane_id}'; }

# agent_in <pane> [state]: claude running in the pane, its hooks having told tt the state; start with none.
agent_in() {
    eventually runs "$1" claude
    printf '{"session_id": "session-%s", "source": "startup"}' "${1#%}" | TMUX_PANE=$1 "$tt" state start
    [ -z "${2:-}" ] || printf '{"session_id": "session-%s"}' "${1#%}" | TMUX_PANE=$1 "$tt" state "$2"
}

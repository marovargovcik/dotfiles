# shellcheck shell=bash
# Projects and tasks: a session per repo, a worktree and window per task. tt proj and tt new.

# shellcheck source=mux.sh
source "${BASH_SOURCE[0]%/*}/mux.sh"
# shellcheck source=agent.sh
source "${BASH_SOURCE[0]%/*}/agent.sh"

# repo_root <path>: the main checkout of the repo a path is in.
repo_root() {
    local git
    git=$(git -C "$1" rev-parse --path-format=absolute --git-common-dir 2>/dev/null) || return 1
    echo "${git%/.git}"
}

# project <root>: the project session of a repo, created with claude in "orch" if missing.
project() {
    local root=$1 s p
    s=$(mux_project "$root")
    if [ -z "$s" ]; then
        p=$(mux_create_project "$root")
        mux_run "$p" "$(agent_cmd "$root" resume '')"
        s=$(mux_project "$root")
    fi
    echo "$s"
}

# linked_worktrees <root>: the worktrees of a repo other than the main checkout.
linked_worktrees() {
    git -C "$1" worktree list --porcelain | sed -n 's/^worktree //p' | tail -n +2
}

# worktree_path <root> <branch>: where a new worktree goes: the branch, slashes and all, as one directory.
worktree_path() { echo "$worktrees/${1##*/}/${2//\//-}"; }

# open_task <root> <path> <command>: a task window in a repo's session, running the command there; prints the pane.
open_task() {
    local root=$1 path=$2 cmd=$3 s branch p
    s=$(project "$root")
    branch=$(git -C "$path" branch --show-current)
    p=$(mux_create_task "$s" "$path" "${branch:-${path##*/}}")
    mux_run "$p" "$cmd"
    echo "$p"
}

# proj <dir>: the repo's session, with a window, resuming its conversation, for every worktree without one (after a
# reboot or a closed window); then goes there.
proj() {
    local dir=$1 root s path
    root=$(repo_root "$dir") || die "$dir is not in a git repo"
    s=$(project "$root")
    while read -r path; do
        [ -d "$path" ] || continue
        mux_task_paths | grep -qxF "$path" && continue
        open_task "$root" "$path" "$(agent_cmd "$path" resume '')" >/dev/null
    done < <(linked_worktrees "$root")
    mux_focus "$s"
}

# default_base <root>: the default branch as the remote has it now, or HEAD without one. Never prompts, so an agent
# running tt new can't hang on a password.
default_base() {
    local root=$1 base
    base=$(git -C "$root" rev-parse --abbrev-ref origin/HEAD 2>/dev/null) || base=HEAD
    [ "$base" = HEAD ] || GIT_TERMINAL_PROMPT=0 GIT_SSH_COMMAND='ssh -o BatchMode=yes' \
        git -C "$root" fetch -q origin "${base#origin/}" 2>/dev/null || true
    echo "$base"
}

# add_worktree <root> <path> <branch> <base>: a worktree for the branch, which starts at base when it's new.
add_worktree() {
    local root=$1 path=$2 branch=$3 base=$4
    if git -C "$root" show-ref -q --verify "refs/heads/$branch"; then
        git -C "$root" worktree add -q "$path" "$branch"
        return
    fi
    [ -n "$base" ] || base=$(default_base "$root")
    # --no-track: the new branch's upstream isn't the base, so a bare `git push` can't land on main.
    git -C "$root" worktree add -q --no-track -b "$branch" "$path" "$base"
}

# new [-p prompt] [branch] [base]: a worktree and window for the repo in $PWD, claude started on the prompt; prints
# the pane, for whoever handed the task off to follow it with tt read.
new() {
    local prompt='' opt OPTIND=1 branch base root path pane
    while getopts p: opt; do
        case $opt in p) prompt=$OPTARG ;; *) exit 2 ;; esac
    done
    shift $((OPTIND - 1))
    branch=${1:-} base=${2:-}
    [ -n "$branch" ] || read -rp 'branch: ' branch
    [ -n "$branch" ] || exit 0
    root=$(repo_root .) || die "not in a git repo"
    path=$(worktree_path "$root" "$branch")
    [ -e "$path" ] && die "$path already exists"
    add_worktree "$root" "$path" "$branch" "$base"
    pane=$(open_task "$root" "$path" "$(agent_cmd "$path" new "$prompt")")
    mux_focus_new "$pane"
    echo "$pane"
}

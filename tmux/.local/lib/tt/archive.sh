# shellcheck shell=bash
# tt archive, archived and restore: a task's worktree goes (its branch stays) and comes back at the same path, so
# `claude --resume` finds the conversation. $log holds a line per archived task.

# shellcheck source=project.sh
source "${BASH_SOURCE[0]%/*}/project.sh"

# log_drop <line>: drops a line from the archive log. Not sed -i: GNU and BSD sed spell it differently.
log_drop() { sed "$1d" "$log" >"$log.tmp" && mv "$log.tmp" "$log"; }

# log_task <repo> <branch> <path> <label>: appends an archived task to the log: date, repo, branch, path,
# conversation, label.
log_task() {
    local repo=$1 branch=$2 path=$3 label=$4
    mkdir -p "${log%/*}"
    printf '%s\t%s\t%s\t%s\t%s\t%s\n' "$(date +%F)" "$repo" "$branch" "$path" "$(session_in "$path")" \
        "${label//$tab/ }" >>"$log"
}

# set_aside <window> <path>: moves the worktree's node_modules aside on the same volume and prints where, or nothing
# without one. Deleting it (~400k files) took most of archive's time; empty_trash deletes it in the background once
# the worktree is gone.
set_aside() {
    local w=$1 path=$2 trash
    [ -d "$path/node_modules" ] || return 0
    trash=$trash_root/${w#@}-$$
    mkdir -p "$trash" && mv "$path/node_modules" "$trash/" && echo "$trash"
}

# archive <window> [n/total]: removes a task's worktree (the branch stays), closes its window and logs it for
# restore. The second argument numbers it in the progress line. A worktree git won't remove comes back as it was.
archive() {
    local w=$1 path repo label branch trash
    IFS=$us read -r path repo label < <(tmux display -p -t "$w" "#{@task_path}$us#{@repo}$us$title")
    [ -n "$path" ] || {
        echo "tt: $w is not a task window" >&2
        return 1
    }
    [ -z "$(git -C "$path" status --porcelain)" ] || {
        echo "tt: ${path##*/} has uncommitted changes; kept" >&2
        return 1
    }
    branch=$(git -C "$path" branch --show-current)
    label=$(strip_spinner "$label")
    log_task "$repo" "$branch" "$path" "$label"
    trash=$(set_aside "$w" "$path") || trash=
    # The window first, so claude isn't writing in a directory being removed.
    tmux kill-window -t "$w"
    if ! remove_worktree "$repo" "$path" "[${2:-1/1}] $label ($branch)"; then
        log_drop '$'
        [ -z "$trash" ] || { mv "$trash/node_modules" "$path/" && rmdir "$trash"; }
        open_task "$repo" "$path" "$(agent_cmd "$path" resume '')" >/dev/null
        return 1
    fi
    [ -z "$trash" ] || empty_trash "$trash"
}

# remove_worktree <repo> <path> <line>: git worktree remove behind a line that counts seconds, so a large worktree
# being deleted doesn't look stuck. git's own errors follow the line.
remove_worktree() {
    local repo=$1 path=$2 line=$3 err pid start=$SECONDS rc=0
    err=$(mktemp)
    git -C "$repo" worktree remove "$path" 2>"$err" &
    pid=$!
    if [ -t 2 ]; then
        while kill -0 "$pid" 2>/dev/null; do
            printf '\r%s… %ds' "$line" $((SECONDS - start)) >&2
            sleep 0.2
        done
        printf '\r\e[K' >&2
    fi
    wait "$pid" || rc=$?
    if [ "$rc" -eq 0 ]; then
        printf '%s: archived in %ds\n' "$line" $((SECONDS - start)) >&2
    else
        printf '%s: not archived\n' "$line" >&2
        cat "$err" >&2
    fi
    rm -f "$err"
    return "$rc"
}

# empty_trash <dir>: deletes what archive set aside, detached so it outlives the popup, along with anything an
# earlier run left behind (older than an hour).
empty_trash() {
    # shellcheck disable=SC2016 # the inner sh expands them
    nohup sh -c 'rm -rf "$1"; find "$2" -mindepth 1 -maxdepth 1 -mmin +60 -exec rm -rf {} +' \
        _ "$1" "$trash_root" >/dev/null 2>&1 &
}

# status_of <path> <agent state>: what a worktree has that archiving would set aside, for archive's picker.
status_of() {
    local path=$1 agent=$2 pr base ahead n out tags=()
    cd "$path" || return
    pr=$(gh pr view --json state -q .state 2>/dev/null) || pr=
    base=$(git rev-parse --abbrev-ref origin/HEAD 2>/dev/null) || base=main
    ahead=$(git rev-list --count "$base..HEAD" 2>/dev/null) || ahead=0
    n=$(($(git status --porcelain | wc -l))) # BSD wc pads with spaces
    case $agent in working | blocked) tags+=("claude $agent") ;; esac
    [ "$n" -gt 0 ] && tags+=("$n uncommitted")
    [ -n "$pr" ] && tags+=("pr ${pr,,}")
    case $pr in
    MERGED | CLOSED) ;;
    *)
        if [ "$ahead" -gt 0 ]; then
            tags+=("$ahead ahead")
            push_tag
        elif [ "$n" -eq 0 ] && [ -z "$pr" ]; then
            tags+=(untouched)
        fi
        ;;
    esac
    printf -v out ' · %s' "${tags[@]}"
    echo "${out:3}"
}

# push_tag: for status_of, in the worktree: how much of its branch isn't on the remote, added to its tags.
push_tag() {
    local remote unpushed
    remote=refs/remotes/origin/$(git branch --show-current)
    if ! git rev-parse -q --verify "$remote" >/dev/null; then
        tags+=("not pushed")
        return
    fi
    unpushed=$(git rev-list --count "$remote..HEAD")
    [ "$unpushed" -eq 0 ] || tags+=("$unpushed unpushed")
}

# task_row <window> <path> <repo> <label>: a task as archive's picker shows it, before its status: repo, label,
# branch. Long branches are cut so the status after them stays in view.
task_row() {
    local w=$1 path=$2 repo=$3 label branch
    label=$(strip_spinner "$4")
    branch=$(git -C "$path" branch --show-current)
    [ ${#branch} -le 28 ] || branch="${branch:0:27}…"
    printf '%s\t%-12s %-34.34s %s%*s ' "$w" "${repo##*/}" "$label" "$branch" $((28 - ${#branch})) ''
}

# rows [--status]: archive's picker rows, one per task; with --status, statuses fetched in parallel and printed in
# task order.
rows() {
    local tmp i=0 w path agent repo label
    tmp=$(mktemp -d)
    while IFS=$us read -r w path agent repo label; do
        i=$((i + 1))
        {
            task_row "$w" "$path" "$repo" "$label"
            if [ "${1:-}" = --status ]; then status_of "$path" "$agent"; else echo; fi
        } >"$tmp/$(printf %03d $i)" &
    done < <(mux_tasks | fields)
    wait
    cat "$tmp"/* 2>/dev/null
    rm -rf "$tmp"
}

# pick_tasks: the windows of the tasks picked with fzf. The rows show at once; statuses (about a second each, gh and
# git status in parallel) replace them when ready. --id-nth keeps what's selected across the reload.
pick_tasks() {
    local self keys='tab: select  ctrl-a: all  enter: archive'
    self=$(printf %q "$0")
    rows | fzf --multi --with-nth=2.. --delimiter='\t' --id-nth=1 \
        --bind=ctrl-a:toggle-all --header="$keys  (loading status…)" \
        --bind="start:reload-sync($self _archive-rows --status)+change-header($keys)" \
        --preview="$self _preview {1}" --preview-window=right,50%,follow | cut -f1
}

# archive_cmd [window...]: archives the windows given, or those picked; fails if any stays.
archive_cmd() {
    local picked w rc=0 i=0
    if [ $# -eq 0 ]; then
        [ -n "$(mux_tasks)" ] || die "no tasks"
        mapfile -t picked < <(pick_tasks)
        set -- "${picked[@]}"
    fi
    for w; do archive "$w" "$((++i))/$#" || rc=1; done
    return $rc
}

# archived: lists archived tasks.
archived() {
    [ -s "$log" ] || {
        echo "nothing archived"
        return 0
    }
    awk -F'\t' '{ n = split($2, r, "/"); printf "%s  %-14s %-28s %s\n", $1, r[n], $3, $6 }' "$log"
}

# repo_query: starts restore's picker on the repo of $PWD, if it's in one; ctrl+u clears it.
repo_query() {
    local root
    root=$(repo_root .) || return 0
    printf "'%s " "${root##*/}"
}

# log_line_of <key>: the line of the newest archived task whose branch carries the key (e.g. NUX-392) as a whole
# segment.
log_line_of() {
    awk -F'\t' -v k="${1,,}" 'tolower($3) ~ ("(^|[/-])" k "(-|$)") { n = NR } END { print n }' "$log"
}

# pick_log_line: the line of an archived task picked with fzf, newest first.
pick_log_line() {
    awk -F'\t' '{ k = split($2, r, "/"); printf "%d\t%s  %-14s %-28s %s\n", NR, $1, r[k], $3, $6 }' "$log" |
        fzf --tac --no-sort --with-nth=2.. --delimiter='\t' --query="$(repo_query)" | cut -f1
}

# restore [-p prompt] [key]: the newest archived task whose branch has the key, or one picked: its worktree back at
# the same path on the same branch, claude resuming on the prompt; prints the pane.
restore() {
    local prompt='' opt OPTIND=1 n repo branch path session pane
    while getopts p: opt; do
        case $opt in p) prompt=$OPTARG ;; *) exit 2 ;; esac
    done
    shift $((OPTIND - 1))
    [ -s "$log" ] || die "nothing archived"
    if [ -n "${1:-}" ]; then
        n=$(log_line_of "$1")
        [ -n "$n" ] || die "nothing archived matches $1"
    else
        n=$(pick_log_line) || exit 0
    fi
    IFS=$us read -r _ repo branch path session _ < <(sed -n "${n}p" "$log" | fields)
    git -C "$repo" worktree add -q "$path" "$branch"
    pane=$(open_task "$repo" "$path" "$(resume_cmd "$session" "$prompt")")
    log_drop "$n"
    mux_focus_new "$pane"
    echo "$pane"
}

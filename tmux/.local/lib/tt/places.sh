# shellcheck shell=bash
# tt places: where a request about a ticket key, path or repo belongs. Each place is a line: kind, pane or branch,
# status, path. A digit before the kind ranks it, most specific first: this, task, archived and closed, session,
# shell.

# shellcheck source=project.sh
source "${BASH_SOURCE[0]%/*}/project.sh"

# place_root <path|repo>: the top of the checkout a path is in (the path itself outside git), or the main checkout
# of the project session whose repo has that name.
place_root() {
    local q=$1 root
    if [ -e "$q" ]; then
        git -C "$q" rev-parse --show-toplevel 2>/dev/null || (cd "$q" && pwd)
        return
    fi
    root=$(tmux list-sessions -F '#{@repo}' 2>/dev/null | awk -v n="$q" '$0 ~ ("/" n "$")' | head -1)
    [ -n "$root" ] && echo "$root"
}

# pane_places <key> <root>: the panes of the project sessions whose worktree or branch has the key, or that are in
# the root.
pane_places() {
    local key=$1 root=$2 pane state agent cwd task kind
    while IFS=$us read -r pane state agent cwd _ task; do
        if [ -n "$key" ]; then
            has_key "$key" "${cwd##*/}" || has_key "$key" "$task" || continue
            [ -z "$agent" ] && kind=4shell || kind=1task
        else
            [ "$cwd" = "$root" ] || [[ $cwd == "$root"/* ]] || continue
            [ -z "$agent" ] && kind=4shell || kind=3session
        fi
        [ "$pane" = "${TMUX_PANE:-}" ] && kind=0this
        [ -n "$agent" ] && state=${state:-idle} || state=-
        printf '%s\t%s\t%s\t%s\n' "$kind" "$pane" "$state" "$cwd"
    done < <(mux_panes | fields)
}

# archived_places <key>: the archived tasks whose branch has the key.
archived_places() {
    [ -s "$log" ] || return 0
    awk -F'\t' -v k="$1" 'tolower($3) ~ ("(^|[/-])" k "(-|$)") { printf "2archived\t%s\t-\t%s\n", $3, $4 }' "$log"
}

# closed_places <key>: the worktrees with the key that no window is in and that weren't archived: their window was
# closed.
closed_places() {
    local key=$1 cwd r
    while read -r cwd; do
        has_key "$key" "${cwd##*/}" || continue
        mux_panes | cut -f4 | grep -qxF "$cwd" && continue
        printf '2closed\t%s\t-\t%s\n' "$(git -C "$cwd" branch --show-current 2>/dev/null)" "$cwd"
    done < <(tmux list-sessions -F '#{@repo}' 2>/dev/null | sort -u | grep . |
        while read -r r; do linked_worktrees "$r"; done)
}

# places <ticket|path|repo>: the places, most specific first, each pane or branch once; fails with none.
places() {
    local q=$1 key='' root=''
    if [[ $q =~ ^[A-Za-z]+-[0-9]+$ ]]; then
        key=${q,,}
    else
        root=$(place_root "$q") || return 1
    fi
    {
        pane_places "$key" "$root"
        if [ -n "$key" ]; then
            archived_places "$key"
            closed_places "$key"
        fi
    } | sort -s -t"$tab" -k1,1 | sed 's/^[0-9]//' | awk -F'\t' '!seen[$1 FS $2]++' | grep .
}

# places_cmd <ticket|path|repo>: the places as a table.
places_cmd() {
    [ -n "${1:-}" ] || die "places needs a ticket key, path or repo name"
    places "$1" | column -t -s"$tab" || die "no place for $1"
}

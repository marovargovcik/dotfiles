# shellcheck shell=bash
# tt pick: fuzzy-finds a session, window or pane, as a tree. Also the pickers' shared parts: the preview of a row's
# pane, and the reload an agent's state change triggers.

# shellcheck source=mux.sh
source "${BASH_SOURCE[0]%/*}/mux.sh"

# pick_rows: pick's rows, like the tree: a session, then each window, then each pane, but only for windows split
# into several (a one-pane window is its pane). Each row starts with its tmux id ($ session, @ window, % pane), then
# the agent's state as an icon (a session or window takes the most urgent under it: ⚠ blocked, ✓ done and not
# looked at, … working, a dim ✓ done and seen). A session row is its name in bold and a rule; windows and panes hang
# under it as a tree (├─ └─). Window rows show their active pane: the role (◆ orchestrator, or task), the agent's
# state (or the program), and Claude's conversation title (or the directory). Columns fit their widest value. Each window and pane row ends with session:window[.pane] dimmed,
# so typing a session name also finds what's under it (fzf can't search hidden fields).
pick_rows() {
    local role='#{?#{==:#{@role},orchestrator},◆,#{?#{@task},task,}}' format
    format=$(formats '#{session_id}' '#{session_name}' '#{session_windows}' \
        '#{window_id}' '#{window_index}' '#{=24:window_name}' '#{window_panes}' "$role" \
        '#{pane_id}' '#{pane_index}' '#{pane_active}' "#{=8:$doing}" "$title" '#{b:pane_current_path}' \
        "$live_state" '#{@agent_seen}')
    tmux list-panes -a -F "$format" | LC_ALL=C awk -F'\t' -f "${BASH_SOURCE[0]%/*}/pick-rows.awk"
}

# live <kind>: fzf options, in live_opts, for a picker that reloads with tt _<kind>-rows when told to (tt _notify);
# --id-nth keeps the cursor on its row across a reload. The socket goes when tt exits.
live() {
    mkdir -p "$pickers"
    sock=$pickers/$1.$$.sock
    trap 'rm -f "$sock"' EXIT
    live_opts=(--listen="$sock" --id-nth=1)
}

# notify: tells every open picker to reload, in the background so a hook doesn't wait. A socket nothing answers on
# is left over from a picker that died: it goes.
notify() {
    local s kind self
    self=$(printf %q "$0")
    for s in "$pickers"/*.sock; do
        [ -S "$s" ] || continue
        kind=${s##*/} kind=${kind%%.*}
        curl -s -o /dev/null --max-time 2 --unix-socket "$s" http://localhost \
            -d "reload-sync($self _$kind-rows)" || rm -f "$s"
    done >/dev/null 2>&1 &
}

# pick: goes to the row picked: enter goes there, ctrl-x kills that row, ctrl-s the row's whole session, ctrl-/ hides
# or shows the preview. The preview sits below, so the list has the popup's whole width.
pick() {
    local self target keys='enter: go  ctrl-x: kill this row  ctrl-s: kill its session  ctrl-/: preview'
    self=$(printf %q "$0")
    live pick
    target=$(pick_rows | fzf "${live_opts[@]}" --ansi --no-sort --with-nth=2.. --delimiter='\t' --header="$keys" \
        --bind="ctrl-x:execute($self _kill row {1})+reload($self _pick-rows)" \
        --bind="ctrl-s:execute($self _kill session {1})+reload($self _pick-rows)" \
        --bind=ctrl-/:toggle-preview \
        --preview="$self _preview {1}" --preview-window=down,50%,follow | cut -f1) || exit 0
    mux_focus "$target"
}

# capture <pane>: the pane as it looks now, without the blank lines below the last output, so following the end shows
# the latest of it.
capture() {
    tmux capture-pane -ep -t "$1" 2>/dev/null |
        awk '{ t = $0; gsub(/\033\[[0-9;]*m|[[:space:]]/, "", t) }
             t == "" { b++; next } { for (; b > 0; b--) print ""; print }'
}

# preview <target>: a row's pane. A session shows its active window; a window split into several panes shows each of
# them stacked, the tail of each under a tag naming it, like the tree does.
preview() {
    local target=$1 panes p id name what dir active tag out i rows cols each format
    if [[ $target == %* ]] || [ "$(tmux display -p -t "$target" '#{window_panes}' 2>/dev/null)" -le 1 ]; then
        capture "$target"
        return 0
    fi
    format=$(formats '#{pane_id}' '#{session_name}:#{window_index}.#{pane_index}' "$doing" '#{b:pane_current_path}' \
        '#{pane_active}')
    mapfile -t panes < <(tmux list-panes -t "$target" -F "$format")
    rows=${FZF_PREVIEW_LINES:-40} cols=${FZF_PREVIEW_COLUMNS:-80}
    each=$((rows / ${#panes[@]} - 1))
    ((each < 1)) && each=1
    for p in "${panes[@]}"; do
        IFS=$tab read -r id name what dir active <<<"$p"
        tag=" $name  $what  $dir "
        [ "$active" = 1 ] && tag+=" ◀ active "
        printf '\033[7m%-*.*s\033[0m\n' "$cols" "$cols" "$tag"
        mapfile -t out < <(capture "$id" | tail -n "$each")
        ((${#out[@]})) && printf '%s\033[0m\n' "${out[@]}"
        for ((i = ${#out[@]}; i < each; i++)); do echo; done
    done
}

# kill_target <row|session> <id>: kills the row's session, window or pane (or its whole session) after asking.
# kill-window and kill-session, not the tree's x: in tmux 3.8, x on the session the tree runs in crashes the server.
# The row's own kind comes from its id: $ session, @ window, % pane.
kill_target() {
    local target=$2 what fmt answer
    [ "$1" = session ] && target=$(tmux display -p -t "$target" '#{session_id}')
    case $target in
    \$*) what=session fmt='#{session_name}' ;;
    @*) what=window fmt='#{session_name}:#{window_index} #{window_name}' ;;
    *) what=pane fmt='#{session_name}:#{window_index}.#{pane_index}' ;;
    esac
    read -rp "kill $what $(tmux display -p -t "$target" "$fmt")? [y/N] " answer </dev/tty
    [ "$answer" = y ] && tmux "kill-$what" -t "$target"
    return 0
}

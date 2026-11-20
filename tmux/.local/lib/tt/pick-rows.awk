# tt pick's rows, from a line per pane of tmux list-panes, the fields of pick_rows' format:
#   1 session id, 2 session name, 3 its window count, 4 window id, 5 window index, 6 window name (24 wide),
#   7 its pane count, 8 window role (16 wide), 9 pane id, 10 pane index, 11 whether it's the window's active pane,
#   12 what it does (8 wide), 13 title, 14 directory name, 15 agent state, 16 whether the agent was seen since
# A row starts with its tmux id and a tab; fzf shows what follows.

# How urgent an agent's state is: blocked, done and not looked at, working, done and seen, nothing.
function rank(state, seen) {
    return state == "blocked" ? 4 : state == "done" && seen == "" ? 3 : state == "working" ? 2 : state == "done" ? 1 : 0
}

function icon(r) {
    return r == 4 ? "\033[31m⚠\033[0m" : r == 3 ? "\033[32m✓\033[0m" : r == 2 ? "\033[33m…\033[0m" : r == 1 ? "\033[2m✓\033[0m" : " "
}

function rule(width,  t) {
    t = ""
    while (width-- > 0) t = t "─"
    return t
}

# Rows wait for their window, and windows for their session, to learn the most urgent state under them; \001 marks
# where its icon goes. flush_window adds the window's row and its panes' rows to the session's body.
function flush_window(i) {
    if (window == "") return
    sub(/\001/, icon(window_rank), window_row)
    body = body window_row "\n"
    for (i = 1; i <= npanes; i++) body = body pane_rows[i] "\n"
    if (window_rank > session_rank) session_rank = window_rank
    window = ""; npanes = 0; window_rank = 0
}

function flush_session() {
    flush_window()
    if (session == "") return
    sub(/\001/, icon(session_rank), session_row)
    printf "%s\n%s", session_row, body
    body = ""; session_rank = 0
}

{
    r = rank($15, $16)
    sub(/^[^[:alnum:]]+ /, "", $13)  # Claude Code's spinner before the title
    info = sprintf("%s %s", $12, ($13 != "" ? $13 : $14))

    # A session: its name in bold, a rule, and its window count.
    if ($1 != session) {
        flush_session(); session = $1; nwindows = 0
        session_row = sprintf("%s\t\001 \033[1m%s\033[0m \033[2m%s %d window%s\033[0m", $1, $2, rule(40 - length($2)), $3, ($3 == 1 ? "" : "s"))
    }

    # A window hangs under its session: index, name, role, then its active pane's info.
    if ($4 != window) {
        flush_window(); window = $4; npane = 0; last_window = (++nwindows == $3)
        window_head = sprintf("%s\t\001 %s %-3s %s %s ", $4, (last_window ? "└─" : "├─"), $5, $6, $8)
    }
    if (r > window_rank) window_rank = r
    # session:window dimmed at the end, so typing a session name also finds what's under it.
    tag = sprintf("  \033[2m%s:%s\033[0m", $2, $5)
    if ($11 == 1) window_row = window_head " " info tag

    # A pane gets a row of its own only in a window split into several.
    if ($7 > 1) pane_rows[++npanes] = sprintf("%s\t%s %s%s %-43s %s  \033[2m%s:%s.%s\033[0m", $9, icon(r), (last_window ? "   " : "│  "), (++npane == $7 ? "└─" : "├─"), "." $10, info, $2, $5, $10)
}

END { flush_session() }

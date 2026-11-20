# shellcheck shell=bash
# The agent: the command that starts Claude Code, its conversations, and its process.

# shellcheck source=common.sh
source "${BASH_SOURCE[0]%/*}/common.sh"

# prompt_arg <prompt>: claude's prompt argument, read from a file so the typed line stays short: until a fresh pane's
# shell shows its prompt, the tty refuses a long typed line (over 1024 bytes on macOS, 4096 on Linux).
prompt_arg() {
    [ -n "$1" ] || return 0
    local f
    f=$(mktemp "${TMPDIR:-/tmp}/tt-handoff.XXXXXX")
    printf %s "$1" >"$f"
    # shellcheck disable=SC2016 # expanded by the shell that runs the command
    printf ' "$(cat %q && rm %q)"' "$f" "$f"
}

# session_in <dir>: the newest Claude Code session started in a directory.
session_in() {
    local dir=$HOME/.claude/projects/${1//[^A-Za-z0-9]/-} f
    # shellcheck disable=SC2012 # session files are named by UUID
    f=$(ls -t -- "$dir"/*.jsonl 2>/dev/null | head -1) || true
    [ -n "$f" ] && basename "$f" .jsonl || true
}

# resume_cmd <session> <prompt>: the command that starts claude, resuming the session if there is one.
resume_cmd() { printf 'claude%s%s' "${1:+ --resume $1}" "$(prompt_arg "$2")"; }

# agent_cmd <dir> <resume|new> <prompt>: the command that starts claude in a directory, resuming its newest
# conversation if asked.
agent_cmd() {
    local dir=$1 resume=$2 prompt=$3 session=
    [ "$resume" = resume ] && session=$(session_in "$dir")
    resume_cmd "$session" "$prompt"
}

# agent_proc <agent>: the nearest agent process above this hook: pid, process group, and its terminal's foreground
# group.
agent_proc() {
    local pid=$PPID parent pg tpg comm
    while [ "${pid:-0}" -gt 1 ]; do
        read -r parent pg tpg comm < <(ps -o ppid=,pgid=,tpgid=,comm= -p "$pid") || return 1
        if [ "${comm##*/}" = "$1" ]; then
            echo "$pid $pg $tpg"
            return
        fi
        pid=$parent
    done
    return 1
}

# holds_terminal <agent>: whether that agent holds its terminal. A claude -p that the agent runs is off the terminal,
# in a session of its own.
holds_terminal() {
    local pid pg tpg
    read -r pid pg tpg < <(agent_proc "$1") || return 1
    [ "$pg" = "$tpg" ]
}

# record <agent> <state> <session>: every agent's state, in tmux or not, in a file named after its pid, for
# caffeine-agents: state, then session. A file whose process is gone is stale.
record() {
    local dir=${XDG_RUNTIME_DIR:-${TMPDIR:-/tmp}}/agents pid _
    read -r pid _ < <(agent_proc "$1") || return 0
    mkdir -p "$dir"
    if [ "$2" = clear ]; then
        rm -f "$dir/$pid"
    else
        printf '%s\t%s\n' "$2" "$3" >"$dir/$pid"
    fi
}

# shellcheck shell=bash
# Whether anything in a terminal is working, by caffeine-agents' rule (its
# header says it). Each check reads every process once, into the arrays below.

interval=60
hz=$(getconf CLK_TCK)
agents=${XDG_RUNTIME_DIR:-/tmp}/agents
# A check's view of the processes. By pid: its parent, and its terminal's
# foreground group. By process group: its CPU ticks. And each terminal's first
# program.
declare -gA parent tpgid ticks leader
# Process group -> its CPU ticks at this check, and at the previous one.
declare -gA now last

# procs: every process: pid, parent, process group, session, terminal, the
# terminal's foreground group, CPU ticks (its own and those of the children it
# has waited for). The name in parentheses may hold spaces, so fields count from
# after the last ")".
procs() {
    awk '{ pid = $1; sub(/^.*\) /, ""); print pid, $2, $3, $4, $5, $6, $12 + $13 + $14 + $15 }' \
        /proc/[0-9]*/stat 2>/dev/null
}

# read_procs: fills the arrays from procs. A terminal's first program (usually
# its shell) leads its session. Pseudo-terminals are majors 136-143; the console
# sway runs on isn't one.
read_procs() {
    local pid pp pg sid tty tp t
    parent=() tpgid=() ticks=() leader=()
    while read -r pid pp pg sid tty tp t; do
        parent[$pid]=$pp tpgid[$pid]=$tp
        ticks[$pg]=$((${ticks[$pg]:-0} + t))
        tty=$((tty >> 8 & 0xfff))
        [ "$sid" = "$pid" ] && ((tty >= 136 && tty <= 143)) && leader[$pid]=1
    done < <(procs)
}

# prune_agents: removes the files of agents that are gone.
prune_agents() {
    local f
    for f in "$agents"/*; do
        [ -e "$f" ] && [ -z "${parent[${f##*/}]:-}" ] && rm -f "$f"
    done
}

# runs_bash_tool <pid>: whether the process is a command of an agent's Bash
# tool.
runs_bash_tool() { grep -qa '/.claude/shell-snapshots/' "/proc/$1/cmdline" 2>/dev/null; }

# agent_busy <pid>: whether the agent is working, or past its turn with a Bash
# tool command running or a subagent whose transcript changed in the last two
# minutes. The agent leads its process group; Bash tool commands are its
# children.
agent_busy() {
    local fg=$1 state session child
    IFS=$'\t' read -r state session <"$agents/$fg"
    [ "$state" = working ] && return 0
    for child in "${!parent[@]}"; do
        [ "${parent[$child]}" = "$fg" ] && runs_bash_tool "$child" && return 0
    done
    [ -n "$session" ] && find ~/.claude/projects/*/"$session"/subagents -name '*.jsonl' -mmin -2 2>/dev/null |
        grep -q .
}

# program_busy <process group>: whether it used 5% of a CPU since the last
# check. Its ticks go in now for the next.
program_busy() {
    local fg=$1
    now[$fg]=${ticks[$fg]:-0}
    [ -n "${last[$fg]:-}" ] && (((now[$fg] - last[$fg]) * 100 >= hz * interval * 5))
}

# working: whether any terminal is working, by what it has in front. A shell at
# its prompt is idle.
working() {
    local pid fg busy=1
    read_procs
    prune_agents
    now=()
    for pid in "${!leader[@]}"; do
        fg=${tpgid[$pid]:--1}
        [ "$fg" -gt 0 ] || continue
        if [ -f "$agents/$fg" ]; then
            agent_busy "$fg" && busy=0
        elif [ "$fg" != "$pid" ]; then
            program_busy "$fg" && busy=0
        fi
    done
    last=()
    for fg in "${!now[@]}"; do last[$fg]=${now[$fg]}; done
    return $busy
}

#!/bin/sh
# Sway keeps a new window hidden behind a fullscreen one, so the picker would
# open invisible. If the focused window is fullscreen, open the picker under an
# app id that sway makes fullscreen (taking over from the app), and give
# fullscreen back to the app when lf exits.
# Needs SWAYSOCK in the D-Bus activation environment (sway config).
fs=$(swaymsg -t get_tree 2>/dev/null | jq -r 'first(.. | objects
    | select((.type? == "con" or .type? == "floating_con") and .fullscreen_mode == 1)
    | select([.. | objects | .focused?] | any) | .id) // empty')
[ -n "$fs" ] && export TERMCMD="foot --app-id filechooser-fullscreen"

/usr/share/xdg-desktop-portal-termfilechooser/lf-wrapper.sh "$@"
rc=$?

[ -n "$fs" ] && swaymsg -q "[con_id=$fs] fullscreen enable"
exit $rc

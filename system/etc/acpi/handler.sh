#!/bin/sh
# ACPI handler for sway + seatd + acpid + zzz (no elogind).
#
# Responsibilities (direct events only):
#   - button/power     : lock screen (no suspend).
#   - button/sleep     : lock screen, then suspend (so resume shows swaylock).
#   - button/lid close : update lid state -> "closed", lock screen.
#   - button/lid open  : update lid state -> "open".
#   - ac_adapter       : CPU governor scaling (preserved from upstream).
#   - battery          : stubs preserved.
#   - video/brightness*: no-op; sway owns this via XF86MonBrightness*
#                        -> brightnessctl.
#
# Idle-suspend timing is NOT done here.  swayidle owns it, reading
# /run/acpi-lid-state at fire time to choose 2-min vs 5-min behavior.

LIDSTATE_FILE="/run/acpi-lid-state"

minspeed="/sys/devices/system/cpu/cpu0/cpufreq/cpuinfo_min_freq"
maxspeed="/sys/devices/system/cpu/cpu0/cpufreq/cpuinfo_max_freq"
setspeed="/sys/devices/system/cpu/cpu0/cpufreq/scaling_setspeed"

# Populate SWAY_PID, SWAY_USER, SWAY_UID, SWAY_WD. Returns 1 if no sway.
find_sway() {
    SWAY_PID=$(pgrep -x sway | head -1)
    [ -z "$SWAY_PID" ] && return 1
    SWAY_USER=$(ps -o user= -p "$SWAY_PID" | tr -d ' ')
    SWAY_UID=$(id -u "$SWAY_USER")
    SWAY_WD=$(tr '\0' '\n' < /proc/"$SWAY_PID"/environ \
              | grep '^WAYLAND_DISPLAY=' | cut -d= -f2)
    SWAY_WD="${SWAY_WD:-wayland-1}"
    return 0
}

# Lock the screen via swaylock. No-op if already locked.
lock_screen() {
    pgrep -x swaylock >/dev/null 2>&1 && return 0
    find_sway || return 1
    su -c "WAYLAND_DISPLAY=$SWAY_WD XDG_RUNTIME_DIR=/run/user/$SWAY_UID \
           swaylock -f -c 000000 --indicator-idle-visible" "$SWAY_USER"
}

case "$1" in
    button/power)
        lock_screen
        ;;

    button/sleep)
        lock_screen
        zzz
        ;;

    button/lid)
        case "$3" in
            close)
                echo "closed" > "$LIDSTATE_FILE"
                chmod 644 "$LIDSTATE_FILE"
                lock_screen
                ;;
            open)
                echo "open" > "$LIDSTATE_FILE"
                chmod 644 "$LIDSTATE_FILE"
                ;;
        esac
        ;;

    ac_adapter)
        case "$2" in
            AC|ACAD|ADP0)
                case "$4" in
                    00000000) cat "$minspeed" >"$setspeed" 2>/dev/null ;;
                    00000001) cat "$maxspeed" >"$setspeed" 2>/dev/null ;;
                esac
                ;;
        esac
        ;;

    battery)
        : ;;  # stubs preserved from upstream

    video/brightnessup|video/brightnessdown)
        : ;;  # sway/brightnessctl handles
esac

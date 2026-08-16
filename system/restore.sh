#!/bin/sh
# Restore the /etc-side configuration that stow does not cover.
#
# Run as root, from anywhere:   sudo ./system/restore.sh
#
# Idempotent: every step is safe to re-run. Existing files are backed up to
# <file>.pre-restore before being overwritten.
#
# This script does NOT install packages, create the user, or enable the base
# services -- see linux-setup.md for those. It only puts the hand-written
# config files back.

set -eu

SRC=$(CDPATH= cd -- "$(dirname -- "$0")" && pwd)
USER_NAME=${USER_NAME:-maro}

[ "$(id -u)" -eq 0 ] || { echo "must run as root" >&2; exit 1; }
id "$USER_NAME" >/dev/null 2>&1 || { echo "no such user: $USER_NAME" >&2; exit 1; }

# install_file <src-relative> <dest> <mode>
install_file() {
    src="$SRC/$1"; dest="$2"; mode="$3"
    [ -f "$src" ] || { echo "missing source: $src" >&2; return 1; }
    if [ -f "$dest" ] && ! cmp -s "$src" "$dest"; then
        cp -a "$dest" "$dest.pre-restore"
        echo "  backed up $dest -> $dest.pre-restore"
    fi
    mkdir -p "$(dirname "$dest")"
    install -o root -g root -m "$mode" "$src" "$dest"
    echo "  $dest ($mode)"
}

echo "== ACPI handler =="
install_file etc/acpi/handler.sh /etc/acpi/handler.sh 0755

echo "== zzz suspend/resume logging hooks =="
install_file etc/zzz.d/suspend/00-log /etc/zzz.d/suspend/00-log 0755
install_file etc/zzz.d/resume/99-log  /etc/zzz.d/resume/99-log  0755
# swayidle and these hooks both append here; created world-writable-by-owner
# so the user-side swayidle commands can append without sudo.
[ -f /var/log/power.log ] || { : > /var/log/power.log; chown "$USER_NAME" /var/log/power.log; chmod 644 /var/log/power.log; }
echo "  /var/log/power.log"

echo "== sudoers fragments =="
# NOTE: zzz/reboot/poweroff were reconstructed from documentation, not copied
# from the original machine (they were mode 0440 and unreadable). visudo -c
# below is the safety net.
for f in zzz reboot poweroff; do
    install_file "etc/sudoers.d/$f" "/etc/sudoers.d/$f" 0440
done
install_file etc/sudoers.d/wg-quick /etc/sudoers.d/wg-quick 0440
if ! visudo -c >/dev/null; then
    echo "!! visudo -c FAILED -- sudoers is broken, fix before logging out" >&2
    exit 1
fi
echo "  visudo -c OK"

echo "== iwd =="
install_file etc/iwd/main.conf /etc/iwd/main.conf 0644

echo "== resolvconf (Cloudflare DNS; fixes the .conF typo) =="
install_file etc/resolvconf.conf /etc/resolvconf.conf 0644
rm -f /etc/resolvconf.conF
resolvconf -u 2>/dev/null || true

echo "== 1Password browser allowlist =="
install_file etc/1password/custom_allowed_browsers /etc/1password/custom_allowed_browsers 0644

echo "== PAM (gnome-keyring auto-unlock + pam_rundir) =="
# Void's stock system-login is replaced wholesale here. If Void has since
# changed the stock file, diff before accepting: the only local additions are
# the two pam_gnome_keyring.so lines.
install_file etc/pam.d/system-login /etc/pam.d/system-login 0644

echo "== groups =="
for g in wheel audio video input storage lpadmin _seatd; do
    if getent group "$g" >/dev/null 2>&1; then
        usermod -aG "$g" "$USER_NAME"
        echo "  $USER_NAME in $g"
    else
        echo "  (skipped, no such group: $g)"
    fi
done

echo "== per-user runit service (turnstile-ready) =="
UHOME=$(getent passwd "$USER_NAME" | cut -d: -f6)
install -d -o "$USER_NAME" -g "$USER_NAME" -m 0755 "$UHOME/.config/service/turnstile-ready"
install -o "$USER_NAME" -g "$USER_NAME" -m 0755 \
    "$SRC/user-services/turnstile-ready/run" \
    "$UHOME/.config/service/turnstile-ready/run"
echo "  $UHOME/.config/service/turnstile-ready/run"

echo "== system services =="
for s in dbus seatd turnstiled acpid udevd iwd chronyd bluetoothd \
         avahi-daemon cupsd cups-browsed speakersafetyd snapperd cronie; do
    if [ -d "/etc/sv/$s" ]; then
        [ -e "/var/service/$s" ] || ln -s "/etc/sv/$s" /var/service/
        echo "  $s"
    else
        echo "  (not installed: $s)"
    fi
done

echo
echo "Done. Remaining manual steps:"
echo "  - reboot (or 'sv restart iwd cupsd') for services to pick up new config"
echo "  - verify snapshots appear:  snapper -c root list   (needs cronie running)"
echo "  - restore secrets:          see backup-secrets.sh"

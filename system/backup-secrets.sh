#!/bin/sh
# Collect the private material that must NOT live in this git repo.
#
#   ./system/backup-secrets.sh /run/media/maro/USBSTICK
#
# Produces <dest>/void-secrets-<host>-<date>.tar.gz, mode 0600, containing:
#   ~/.ssh/                      keypairs, config, known_hosts
#   ~/.config/wireguard/*.conf   tunnel configs (contain PrivateKey)
#   ~/.local/state/bash_history.archive
#   /etc/sudoers.d/*             the real fragments, including the three this
#                                repo could only reconstruct (needs sudo)
#
# Restore with:  tar -xzpf <tarball> -C /  --strip-components=0
# (inspect first: tar -tzf <tarball>)

set -eu

DEST=${1:-}
[ -n "$DEST" ] || { echo "usage: $0 <destination-directory>" >&2; exit 1; }
[ -d "$DEST" ] || { echo "not a directory: $DEST" >&2; exit 1; }

STAGE=$(mktemp -d)
trap 'rm -rf "$STAGE"' EXIT INT TERM
chmod 700 "$STAGE"

OUT="$DEST/void-secrets-$(hostname)-$(date +%F).tar.gz"

copy_into() {
    [ -e "$1" ] || { echo "  (absent, skipped) $1"; return 0; }
    mkdir -p "$STAGE/$(dirname "${1#/}")"
    cp -a "$1" "$STAGE/${1#/}"
    echo "  $1"
}

echo "Staging secrets..."
copy_into "$HOME/.ssh"
copy_into "$HOME/.config/wireguard"
copy_into "$HOME/.local/state/bash_history.archive"

# sudoers fragments are root-owned and mode 0440
if [ "$(id -u)" -eq 0 ]; then
    copy_into /etc/sudoers.d
else
    echo "  (need root for /etc/sudoers.d -- re-run with sudo to include it)"
fi

# .ssh/agent holds a live agent socket; nothing to preserve and tar warns on it
rm -rf "$STAGE/$(echo "$HOME" | sed 's|^/||')/.ssh/agent"

tar -czf "$OUT" -C "$STAGE" .
chmod 600 "$OUT"

echo
echo "Wrote $OUT"
echo "Verify before wiping:  tar -tzf '$OUT'"

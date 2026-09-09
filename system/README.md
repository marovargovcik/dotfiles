# system/ — the parts that can't be stowed

Every other directory here is a stow package. This one is the opposite: the
root-owned `/etc` configuration, short enough to type by hand on a fresh machine.
No `stow system`, and no restore script — a script that silently overwrote
package-managed files under `/etc` hid more than it helped. Work through the
sections in order.

**Target:** Void Linux x86_64 (ThinkPad T14 Gen 2), runit, dracut, glibc, Sway,
**elogind** for seat/session/power.

---

## 1. Groups

Sway needs input/DRM access; `lpadmin` is for managing CUPS queues.

```sh
sudo usermod -aG wheel,audio,video,input,storage,lpadmin maro
```

There is no `_seatd` group to join — `libseat` uses elogind's seat backend, so
`seatd` is not installed at all. Log out and back in for group changes to apply.

## 2. Services

runit, so enabling is a symlink into `/var/service/`. Enable `dbus` and
`elogind` first; the rest lean on the bus being up.

```sh
for s in dbus elogind iwd dhcpcd chronyd bluetoothd avahi-daemon cupsd cups-browsed \
         snapperd cronie; do
    sudo ln -s /etc/sv/$s /var/service/
done
```

`dhcpcd` is there for the **wired** port — iwd is Wi-Fi-only, it has no Ethernet
support at all, so wired needs its own DHCP client regardless. `denyinterfaces` in
§5 keeps it off Wi-Fi so the two never fight over the same interface.

Check with `sv status dbus elogind iwd bluetoothd cupsd`. `udevd` is already in
Void's default runlevel — don't add it.

`cronie` matters more than it looks: snapper's timeline and cleanup run from
`/etc/cron.hourly/snapper`, not a service of their own. No cronie, no snapshots.

## 3. Sleep and hibernate (elogind)

elogind owns **when** the machine sleeps — lid, power key, idle timeout, and the
S3→hibernate handoff. It can't draw a Wayland lock screen, so swayidle stays
purely to run swaylock on `timeout` and `before-sleep`. Nothing shells out to
`sudo` or polls lid state.

The payoff over a suspend script is inhibitor locks:

```sh
elogind-inhibit --what=idle:sleep --why="compiling" sbt compile
```

**`/etc/elogind/logind.conf`** — keep swayidle's lock timeout (5 min, in the
`sway` package) below `IdleActionSec` so the screen locks first.

```ini
[Login]
HandleLidSwitch=suspend-then-hibernate
HandleLidSwitchExternalPower=suspend-then-hibernate
HandlePowerKey=suspend-then-hibernate
HandleSuspendKey=suspend-then-hibernate
IdleAction=suspend-then-hibernate
IdleActionSec=10min
```

**`/etc/elogind/sleep.conf`** — S3 first (~0.5–1 W, 1–3 s resume), then RAM to
swap and power off (~0 W, ~10–20 s resume). S3 alone lasts ~3 days on a 43 Wh
battery; the 8 h handoff is what survives a week in a bag.

```ini
[Sleep]
SuspendState=mem
MemorySleepMode=deep
HibernateDelaySec=8h
```

Apply with `sudo sv restart elogind`.

`MemorySleepMode=deep` is a request, not a guarantee — it needs BIOS
**Config → Power → Sleep State → Linux** *and* the kernel arg below.

## 4. Kernel cmdline + initramfs

Two things elogind can't supply: `deep` as the default sleep state, and the swap
partition to resume from. Get the UUID first — machine-specific, which is why
none of this is a copyable file:

```sh
sudo blkid -s UUID -o value /dev/nvme0n1p2
```

Add both to `GRUB_CMDLINE_LINUX_DEFAULT` in **`/etc/default/grub`**:

```
mem_sleep_default=deep resume=UUID=<swap-uuid>
```

A swap *partition* needs only `resume=` — no `resume_offset`, the swapfile-only
dance this layout exists to avoid.

Then dracut needs the resume module, or `resume=` is read and ignored and
hibernate degrades to a slow poweroff. **`/etc/dracut.conf.d/resume.conf`**:

```
add_dracutmodules+=" resume "
```

Regenerate both, then reboot:

```sh
sudo grub-mkconfig -o /boot/grub/grub.cfg
sudo dracut --force --regenerate-all
```

### Verify, in this order

```sh
cat /sys/power/mem_sleep                    # want: s2idle [deep]
sudo sh -c 'echo disk > /sys/power/state'   # raw hibernate -> power on -> restored?
loginctl suspend-then-hibernate             # the real combined mode
```

If raw hibernate doesn't come back, fix `resume=` or the dracut module before
trusting the 8 h timer with unsaved work.

## 5. Networking (iwd + dhcpcd + DNS)

**Wi-Fi** is iwd, doing its own DHCP and handing nameservers to resolvconf.
**`/etc/iwd/main.conf`**:

```ini
[General]
EnableNetworkConfiguration=true

[Network]
NameResolvingService=resolvconf
```

**Wired** is dhcpcd (§2), since iwd can't do Ethernet. It must stay off Wi-Fi so
the two don't both try to manage the same link. **`/etc/dhcpcd.conf`**, appended:

```
denyinterfaces wlp0s20f3
```

Both feed DNS through the *same* resolvconf, which is what makes one Cloudflare
pin apply to whichever interface is actually up — but dhcpcd only defers to
resolvconf if it can see the `resolvconf` binary at the moment it (re)binds. If
`dhcpcd` was enabled and had already bound an interface *before* `openresolv` got
installed, it wrote `/etc/resolv.conf` directly and won't retry the check on its
own — the giveaway is a `# Generated by dhcpcd from ...` header instead of
`# resolv.conf from ...`. Force it once:

```sh
sudo dhcpcd -n enp0s31f6      # rebind — re-triggers dhcpcd's resolvconf hook
cat /etc/resolv.conf          # want a "resolv.conf from ..." header, not "Generated by dhcpcd"
```

**`/etc/resolvconf.conf`** — pins Cloudflare ahead of whatever DHCP hands either
interface:

```sh
resolv_conf=/etc/resolv.conf
name_servers="1.1.1.1 1.0.0.1"
```

`name_servers` **prepends**, it doesn't replace — glibc tries resolvers in the
listed order, so Cloudflare is used first and the router's DHCP-advertised DNS
stays only as a fallback if Cloudflare is unreachable. That's normally what you
want; if you need Cloudflare *exclusive* with no DHCP DNS fallback at all, drop
`domain_name_servers` from the `option` list in `/etc/dhcpcd.conf` and check
whether iwd's DHCP client has an equivalent — not done here, more fragile
(loses any DHCP-DNS fallback if Cloudflare is down).

> Watch the filename — as `resolvconf.conF` it is silently inert and nothing
> complains. Check `ls /etc/resolvconf*` and `cat /etc/resolv.conf` after
> `sudo resolvconf -u`.

Apply: `sudo sv restart iwd && sudo dhcpcd -n enp0s31f6 && sudo resolvconf -u`.

## 6. sudo

One fragment only — power actions go through `loginctl` and need no sudo.
**`/etc/sudoers.d/wg-quick`**, mode `0440`, so the WireGuard bar block and menu
can raise tunnels without prompting:

```
maro ALL=(ALL) NOPASSWD: /usr/bin/wg-quick, /usr/bin/wg
```

```sh
sudo install -m 0440 -o root -g root /dev/stdin /etc/sudoers.d/wg-quick <<'END'
maro ALL=(ALL) NOPASSWD: /usr/bin/wg-quick, /usr/bin/wg
END
sudo visudo -c
```

Always `visudo -c` before logging out. A broken fragment locks you out of sudo.

## 7. PAM — gnome-keyring auto-unlock

Without this there is no secret service on the session bus and 1Password's 2FA
token doesn't survive a lock. Add **two lines** to **`/etc/pam.d/system-login`**
— package-managed, so edit in place and re-check after any `xbps-install` that
touches PAM:

```
auth       optional   pam_gnome_keyring.so
```
...alongside the other `auth` lines, and at the end of the `session` block:
```
-session   optional   pam_gnome_keyring.so auto_start
```

Leave `pam_elogind.so` alone — it creates `XDG_RUNTIME_DIR` and registers the
session. The keyring daemon starts from the sway config and the session bus from
the `dbus-run-session` wrapper in `.bash_profile`; all three must be present or
1Password fails silently.

## 8. 1Password browser integration

The extension ignores browsers not on the allowlist.
**`/etc/1password/custom_allowed_browsers`**, one binary name per line:

```
firefox
```

## 9. Printing — Brother DCP-1610W

Driverless/IPP doesn't work with this printer; it needs `brother-brlaser`. The
PPD is *generated* by `lpadmin` when the queue is created, so there's nothing to
copy — install the driver, reassign the queue, and CUPS writes it.

---

## Secrets

Nothing secret lives in this repo. **1Password is the store.** On a rebuilt
machine, once the desktop app is signed in:

- **SSH keys** → save to `~/.ssh/` (mode 0600), or point 1Password's SSH agent
  at them. The `ssh` package provides `~/.ssh/config` but never a key.
- **WireGuard tunnels** → `~/.config/wireguard/*.conf`, mode 0600. These contain
  `PrivateKey`; that is why they are in 1Password and not here.

Both must exist as real directories before stowing, or stow folds them into
symlinks pointing back into the repo.

## Quick audit on a rebuilt machine

```sh
cat /sys/power/mem_sleep                 # [deep]
grep -o 'resume=UUID=[^ "]*' /etc/default/grub
sv status dbus elogind iwd bluetoothd cupsd
loginctl                                 # one seat, one session
groups                                   # wheel audio video input storage lpadmin
cat /etc/resolv.conf                      # 1.1.1.1
sudo visudo -c
```

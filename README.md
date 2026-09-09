# Void Linux on a ThinkPad T14 Gen 2 — system setup

Everything needed to rebuild this machine that a stow package **cannot** carry:
partitioning, `/etc`, services, kernel cmdline, PAM, root-owned installs.
User-level config lives in the other directories of this repo and is applied
with `stow` (section 5). Follow the sections in order; each block is meant to
be typed as-is unless it says "machine-specific".

**Target:** ThinkPad T14 Gen 2 (Intel i5-1145G7, 16 GB, 256 GB NVMe), Void Linux
x86_64 glibc, runit, dracut, GRUB/UEFI, btrfs + snapper, Sway, elogind, iwd,
PipeWire. Hostname `t14`, user `maro`, locale `en_US.UTF-8`, TZ `Europe/Bratislava`.

State reflected here was verified against the running system on 2026-09-09
(`/etc` diffed against the shipped package files, `/var/service`, `xbps-query -m`).

---

## 0. BIOS (F1 at the Lenovo splash)

- **Security → Secure Boot → Disabled** (Void has no signed shim).
- **Config → Power → Sleep State → Linux** — exposes S3 (`deep`). Without it only
  s2idle exists and the whole power model below degrades.
- **Config → Storage → SATA Controller → AHCI** if the NVMe is invisible.
- Boot the **glibc** live ISO (not musl — 1Password and Claude Code are glibc
  binaries): F12 → USB.

## 1. Install (live USB, manual chroot)

Log in as `root` / `voidlinux`. Wired is simplest; for Wi-Fi in the live env:
`wpa_supplicant -B -i wlan0 -c <(wpa_passphrase SSID pass) && dhcpcd wlan0`.

### 1.1 Disk — DESTRUCTIVE

| Partition | Size | Type | Use |
|---|---|---|---|
| `nvme0n1p1` | 512M | `ef00` EFI (FAT32) | `/boot/efi` |
| `nvme0n1p2` | 20G | `8200` swap | swap + hibernation target (≥ RAM) |
| `nvme0n1p3` | rest | `8300` btrfs | `/` with subvolumes |

A swap **partition** (not a swapfile) is deliberate: hibernation then needs only
`resume=UUID=…`, no `resume_offset`/nocow handling.

```sh
wipefs -a /dev/nvme0n1 && sgdisk -Z /dev/nvme0n1
sgdisk -n1:0:+512M -t1:ef00 -c1:EFI  /dev/nvme0n1
sgdisk -n2:0:+20G  -t2:8200 -c2:swap /dev/nvme0n1
sgdisk -n3:0:0     -t3:8300 -c3:void /dev/nvme0n1

mkfs.vfat -F32 /dev/nvme0n1p1
mkswap -L swap  /dev/nvme0n1p2
mkfs.btrfs -L void /dev/nvme0n1p3

mount /dev/nvme0n1p3 /mnt
for s in @ @home @snapshots @var_log; do btrfs subvolume create /mnt/$s; done
umount /mnt

o=compress=zstd:3,noatime,ssd
mount -o subvol=@,$o /dev/nvme0n1p3 /mnt
mkdir -p /mnt/{home,.snapshots,var/log,boot/efi}
mount -o subvol=@home,$o      /dev/nvme0n1p3 /mnt/home
mount -o subvol=@snapshots,$o /dev/nvme0n1p3 /mnt/.snapshots
mount -o subvol=@var_log,$o   /dev/nvme0n1p3 /mnt/var/log
mount /dev/nvme0n1p1 /mnt/boot/efi
swapon /dev/nvme0n1p2
```

`@home` and `@var_log` are separate so an OS rollback never touches your files
or logs.

### 1.2 Base system

`intel-ucode` lives in the **nonfree** repo — pass both repos, or the install
fails on that one package.

```sh
mkdir -p /mnt/var/db/xbps/keys && cp /var/db/xbps/keys/* /mnt/var/db/xbps/keys/
XBPS_ARCH=x86_64 xbps-install -S -r /mnt \
  -R https://repo-default.voidlinux.org/current \
  -R https://repo-default.voidlinux.org/current/nonfree \
  base-system void-repo-nonfree btrfs-progs grub-x86_64-efi snapper \
  linux-firmware-intel intel-ucode

xgenfstab -U /mnt > /mnt/etc/fstab
grep -E 'btrfs|swap' /mnt/etc/fstab   # every btrfs line MUST have subvol=/@…; swap line present
xchroot /mnt /bin/bash
```

`xgenfstab` also adds `discard=async,space_cache=v2` and a `tmpfs /tmp` line;
keep them.

### 1.3 Inside the chroot

```sh
echo t14 > /etc/hostname
# /etc/rc.conf:                 KEYMAP="us"  TIMEZONE="Europe/Bratislava"  HARDWARECLOCK="UTC"
# /etc/default/libc-locales:    uncomment  en_US.UTF-8 UTF-8
xbps-reconfigure -f glibc-locales
ln -sf /usr/share/zoneinfo/Europe/Bratislava /etc/localtime

passwd
xbps-install -S sudo
useradd -m -G wheel,audio,video,input,storage -s /bin/bash maro
passwd maro
visudo            # uncomment: %wheel ALL=(ALL:ALL) ALL

mount -t efivarfs none /sys/firmware/efi/efivars 2>/dev/null || true
grub-install --target=x86_64-efi --efi-directory=/boot/efi --bootloader-id=Void
grub-mkconfig -o /boot/grub/grub.cfg      # cmdline args are added in §6, after first boot

# snapper wants to create its own .snapshots subvolume; hand it ours
umount /.snapshots && rmdir /.snapshots
snapper -c root create-config /            # writes SNAPPER_CONFIGS="root" to /etc/conf.d/snapper
btrfs subvolume delete /.snapshots
mkdir /.snapshots && chmod 750 /.snapshots && mount /.snapshots

xbps-reconfigure -fa
exit
umount -R /mnt && swapoff /dev/nvme0n1p2 && reboot
```

If the firmware forgets the "Void" boot entry, re-run `grub-install` with
`--removable`. If it panics with `VFS: Unable to mount root fs`, a `subvol=` is
missing from fstab.

## 2. First boot: network, update, packages

Log in as `maro` on the TTY. The wired port needs `dhcpcd` (iwd is Wi-Fi only):

```sh
sudo ln -s /etc/sv/dhcpcd /var/service/     # brings enp0s31f6 up within seconds
sudo xbps-install -Su xbps && sudo xbps-install -Su
```

Then everything else in one go (this is the complete `xbps-query -m` set):

```sh
sudo xbps-install -S \
  linux7.2 mesa-dri intel-video-accel \
  elogind polkit xfce-polkit gnome-keyring libsecret dbus \
  sway swaylock swayidle foot fuzzel i3status-rust nerd-fonts brightnessctl \
  grim slurp wev clipman xdg-desktop-portal xdg-desktop-portal-wlr xdg-utils \
  pipewire wireplumber wiremix bluez bluetui libspa-bluetooth \
  iwd impala openresolv wireguard-tools \
  udisks2 ntfs-3g exfatprogs \
  cups cups-filters cups-browsed avahi nss-mdns brother-brlaser \
  snapper-rollback grub-btrfs cronie chrony socklog-void \
  git mise neovim starship bash-completion fzf zoxide eza bat delta lazygit \
  lf chafa poppler-utils firefox ffmpeg curl lsof stow unzip nano
```

| Group | Why |
|---|---|
| `linux7.2` | the kernel actually booted; `base-system`'s `linux` meta stays on 6.18 as fallback. GRUB picks the newest. |
| `elogind` | seat + session + logind D-Bus API; owns lid/power/idle/sleep. No seatd, no turnstile, no acpid. |
| `polkit` `xfce-polkit` | 1Password's system-auth unlock goes through a polkit action (`after-install.sh` installs the policy); xfce-polkit is the prompt UI |
| `gnome-keyring` `libsecret` | secret-service on the session bus so 1Password's 2FA token survives a lock |
| `mesa-dri` `intel-video-accel` | Iris Xe + VA-API |
| `libspa-bluetooth` | without it BT headphones fail with `br-connection-unknown` |
| `nss-mdns` | makes `hosts: files mdns dns` in `/etc/nsswitch.conf` actually resolve `.local` |
| `brother-brlaser` | the DCP-1610W is not driverless |
| `udisks2` `ntfs-3g` `exfatprogs` | removable media (§11). `ntfs-3g` supplies the `mount.ntfs` helper — the kernel registers NTFS as `ntfs3`, which is not the name udisks2 mounts it under |
| `cronie` | runs `/etc/cron.hourly/snapper`; without it there are no timeline snapshots |
| `socklog-void` | Void ships no syslog daemon, so anything a service writes to `/dev/log` is discarded. `nanoklogd` also persists the kernel ring buffer across reboots |
| `grub-btrfs` `snapper-rollback` | boot a snapshot from the GRUB menu; roll `@` back to one |
| `ffmpeg` | Firefox H.264 (Twitch etc.) |

Manual, outside xbps (done later in §9 and §5): 1Password tarball, Claude Code.

## 3. Services

```sh
for s in socklog-unix nanoklogd dbus elogind polkitd iwd chronyd bluetoothd \
         avahi-daemon cupsd cups-browsed snapperd cronie grub-btrfs; do
  sudo ln -s /etc/sv/$s /var/service/
done
```

(`dhcpcd` was enabled in §2; `udevd` and `agetty-tty1..6` are already there.)
`udisks2` is D-Bus activated and deliberately never appears here (§11).
There is no `snapper-timeline`/`snapper-cleanup` runit service on Void —
cron does that. Final expected set:

```
agetty-tty1..6 avahi-daemon bluetoothd chronyd cronie cups-browsed cupsd dbus dhcpcd
elogind grub-btrfs iwd nanoklogd polkitd snapperd socklog-unix udevd
```

The logging services go first so they capture what starts after them.

**polkit gotcha:** after installing polkit the system bus does not see the new
`org.freedesktop.PolicyKit1` activation file until reloaded; without this
`polkitd` starts but nothing can talk to it:

```sh
sudo dbus-send --system --type=method_call --dest=org.freedesktop.DBus \
  --print-reply /org/freedesktop/DBus org.freedesktop.DBus.ReloadConfig
sudo sv restart polkitd
```

## 4. Groups

```sh
sudo usermod -aG lpadmin maro      # manage CUPS queues without sudo
sudo usermod -aG socklog maro      # read /var/log/socklog without sudo
```

Final: `wheel audio video input storage lpadmin socklog`. No `_seatd` group —
libseat uses elogind. `brightnessctl` ships udev rules granting `video`/`input`
write access to backlights; they apply after a reboot. Re-login for group
changes.

`/var/log/socklog` is `drwxr-s--- root:socklog`; re-login before `svlogtail`
works.

## 5. Dotfiles (stow)

```sh
git clone https://github.com/marovargovcik/dotfiles ~/dotfiles
rm ~/.bash_profile ~/.bashrc                        # /etc/skel copies block the symlinks
mkdir -p ~/.ssh ~/.local/bin ~/.local/share ~/.local/state ~/.config
cd ~/dotfiles && stow bash bin foot fuzzel git i3status-rust lf mise nvim pipewire ssh sway swaylock
```

**Create the real directories first.** Stow "folds": if `~/.ssh` or `~/.local`
does not exist it symlinks the whole directory into the repo, and from then on
private keys, keyrings, nvim plugin checkouts and Claude Code binaries physically
live inside `~/dotfiles/`, one `git add -A` away from being committed. `chmod 700
~/.ssh` after creating it.

What the packages provide, so you know what *not* to write by hand:

| Package | Provides |
|---|---|
| `bash` | `.bash_profile` launches `exec dbus-run-session ssh-agent sway` on tty1 (session bus + SSH agent for the whole session; 1Password/secret-service need the bus); `.bashrc` with starship, mise `--shims`, zoxide, aliases |
| `sway` | keyboard `us,sk` (Alt+Shift toggles), `$mod`=Super, touchpad natural scroll, execs: `pipewire`, `gnome-keyring-daemon --components=secrets`, `wl-paste … clipman`, `/usr/libexec/xfce-polkit`, swayidle (`timeout 300` lock, `idlehint 300`, `before-sleep`, `after-resume`) |
| `bin` | `~/.local/bin/{bt-status,wg-status,wg-menu,power-menu,start-statusbar,usb-status,usb-menu}` — power menu uses `loginctl`, no sudo |
| `swaylock` | lock screen appearance (`~/.config/swaylock/config`) |
| `i3status-rust` `foot` `fuzzel` `lf` `nvim` `git` `mise` `pipewire` `ssh` | app configs. `ssh` gives `~/.ssh/config` only — never a key |

Then finish the user-level tooling:

```sh
mise install                                    # node 26, temurin 26, usage — from mise/config.toml
curl -fsSL https://claude.ai/install.sh | bash  # → ~/.local/bin/claude
```

`pipewire` provides `~/.config/pipewire/pipewire.conf.d/`: `10-session-services.conf`
(a `context.exec` block so the `pipewire` daemon spawns `wireplumber` and
`pipewire-pulse` itself; nothing else starts them) and `20-quantum.conf`
(quantum 2048 / min 1024, the Bluetooth crackle fix). Only `*.conf` is loaded;
a typo in the extension silently disables the file.

## 6. Sleep and hibernate

Model: elogind decides *when* (lid, power key, idle, S3→hibernate timer);
swayidle runs swaylock **and reports the session idle to elogind**;
`loginctl suspend-then-hibernate` from the power menu. Inhibit with
`elogind-inhibit --what=idle:sleep --why=… cmd`.

**`IdleAction=` needs `idlehint`.** For a `Type=wayland` session elogind uses
only the `SetIdleHint` pushed over D-Bus; sway never sends it, so without
swayidle's `idlehint` verb the idle timer never starts and the machine stays
awake at the lock screen. The sway package carries it (§5).

**`/etc/elogind/logind.conf`** (shipped file is all comments; append):

```ini
[Login]
HandleLidSwitch=suspend-then-hibernate
HandleLidSwitchExternalPower=suspend-then-hibernate
HandlePowerKey=suspend-then-hibernate
HandleSuspendKey=suspend-then-hibernate
IdleAction=suspend-then-hibernate
IdleActionSec=10min
```

**`/etc/elogind/sleep.conf`**:

```ini
[Sleep]
SuspendState=mem
HibernateDelaySec=8h
```

(`MemorySleepMode=` is not understood by elogind 252 — the kernel arg below
selects `deep`.)

**Do not `sv restart elogind` from inside Sway** — it recreates `seat0`, the
running compositor loses its seat and you land back on a TTY. Apply with a
reboot.

`exec` in the sway config runs at startup only — `swaymsg reload` will **not**
pick up an edited swayidle line. Re-login, or `pkill -x swayidle` and re-launch
it with `swaymsg exec`.

**Kernel cmdline** — machine-specific UUID:

```sh
sudo blkid -s UUID -o value /dev/nvme0n1p2
```

`/etc/default/grub` (shipped value is `loglevel=4`):

```
GRUB_CMDLINE_LINUX_DEFAULT="loglevel=3 mem_sleep_default=deep resume=UUID=<swap-uuid>"
```

**`/etc/dracut.conf.d/resume.conf`** — without it `resume=` is ignored and
hibernate becomes a slow poweroff:

```
add_dracutmodules+=" resume "
```

```sh
sudo grub-mkconfig -o /boot/grub/grub.cfg
sudo dracut --force --regenerate-all
sudo reboot
```

Verify in this order:

```sh
cat /sys/power/mem_sleep                    # s2idle [deep]
grep -o 'resume=UUID=[^ ]*' /proc/cmdline   # only after a reboot — grub-mkconfig alone
                                            # does not change the running cmdline
sudo lsinitrd | grep -i resume              # resume module present in the initramfs
sudo sh -c 'echo disk > /sys/power/state'   # raw hibernate → power on → session back?
loginctl suspend-then-hibernate             # the real thing
```

### Stages and timing

| At | What happens | Configured by |
|---|---|---|
| 5 min idle | swaylock locks the screen | swayidle `timeout 300` |
| 5 min idle | session reports idle to elogind | swayidle `idlehint 300` |
| + 10 min | suspend to RAM (S3) | `IdleActionSec=10min` |
| + 8 h suspended | RTC wakes the machine, writes the image to swap, powers off | `HibernateDelaySec=8h` |

Lid close and the power key enter the suspend step directly, skipping the idle
timers. Hibernation is only ever the second stage of a suspend, never an action
on a running system — so a lid close and reopen resumes from RAM in 2–3 s, and
only an untouched machine reaches hibernation. Resuming from it goes through
GRUB and takes 15–30 s.

Sleep history is on disk since §2–§4: `PM:` lines in
`/var/log/socklog/kernel/`, elogind's own decisions (`Lid closed.`, `System
idle. Will suspend and later hibernate now.`) in `/var/log/socklog/secure/`.

## 7. Networking: iwd (Wi-Fi) + dhcpcd (wired) + resolvconf

**`/etc/iwd/main.conf`** (file does not exist by default):

```ini
[General]
EnableNetworkConfiguration=true

[Network]
NameResolvingService=resolvconf
```

**`/etc/dhcpcd.conf`** — one line appended to the shipped file, so dhcpcd never
touches the Wi-Fi link iwd manages:

```
denyinterfaces wlp0s20f3
```

**`/etc/resolvconf.conf`** (shipped file is all comments; append). Cloudflare is
*prepended*; the router's DHCP DNS stays as fallback:

```sh
resolv_conf=/etc/resolv.conf
name_servers="1.1.1.1 1.0.0.1"
```

```sh
sudo sv restart iwd && sudo dhcpcd -n enp0s31f6 && sudo resolvconf -u
head -1 /etc/resolv.conf     # want "# resolv.conf from …", NOT "# Generated by dhcpcd"
```

The `dhcpcd -n` rebind matters: if dhcpcd bound the wired port before
`openresolv` was installed it wrote `/etc/resolv.conf` itself and keeps doing so
until it re-runs its hooks. Connect Wi-Fi with `iwctl` or `impala` (bar click).

## 8. PAM: gnome-keyring auto-unlock

Two lines in **`/etc/pam.d/system-login`** (package-managed — re-check after
any update touching `pam-base`). Result vs shipped file:

```
 auth       include    system-auth
+auth       optional   pam_gnome_keyring.so
 …
 session    required   pam_env.so
+-session   optional   pam_gnome_keyring.so auto_start
```

Leave `pam_elogind.so` alone: it creates `XDG_RUNTIME_DIR` and registers the
session. Keyring daemon (sway exec) + session bus (`dbus-run-session`) + this
PAM entry are all three required, or 1Password's 2FA silently resets on lock.

## 9. 1Password (tarball → /opt)

```sh
curl -sSO https://downloads.1password.com/linux/tar/stable/x86_64/1password-latest.tar.gz
sudo tar -xf 1password-latest.tar.gz
sudo mkdir -p /opt/1Password && sudo mv 1password-*/* /opt/1Password
sudo /opt/1Password/after-install.sh        # polkit policy, onepassword groups, setuid sandbox, /usr/bin/1password
sudo cp /opt/1Password/resources/1password.desktop /usr/share/applications/   # xdg-desktop-menu fails on Void, do it by hand
ls -l /usr/bin/1password                    # symlink → /opt/1Password/1password
rm -rf 1password-* 1password-latest.tar.gz
```

Run `after-install.sh` **after** the user exists — it bakes the list of human
users into the polkit policy. `/etc/1password/custom_allowed_browsers` is left at
its shipped (comment-only) default; Firefox is allowed out of the box. The bar
has a `1password --toggle` block; 1Password is not exec'd from sway.

## 10. Printing: Brother DCP-1610W

CUPS + avahi + `nss-mdns` discover it. `cups-browsed` then auto-creates a queue
with a generic IPP Everywhere PPD that "prints" nothing. Replace it with brlaser
(as `maro`, thanks to `lpadmin` group):

```sh
lpinfo -m | grep -i 1610                     # → drv:///brlaser.drv/br1610.ppd
lpadmin -p Brother_DCP-1610W_series -E \
  -m 'drv:///brlaser.drv/br1610.ppd' \
  -v 'dnssd://Brother%20DCP-1610W%20series._pdl-datastream._tcp.local/?uuid=e3248000-80ce-11db-8000-202b20b93381'
lpoptions -p Brother_DCP-1610W_series | grep -o "printer-make-and-model='[^']*'"
# → 'Brother DCP-1610W series, using Owl-Maintain/brlaser v6.2.8'
```

`cupsd.conf`, `cups-files.conf` and `cups-browsed.conf` are untouched defaults.
`printers.conf` and `subscriptions.conf` are written by cupsd once the queue
exists, so they show as MODIFIED in the §14 drift check. Web UI:
`http://localhost:631`.

## 11. Removable media: udisks2 + fuzzel

Plug a stick in and a block appears in the bar; click it and fuzzel offers what
can be done with it. Nothing sits in the background watching for devices and
nothing auto-mounts — the bar block *is* the state, and it hides itself whenever
no USB filesystem is attached.

Two scripts in the `bin` stow package (§5), so `stow -R bin` after adding them:

| | |
|---|---|
| `usb-status` | the block. Reads `lsblk` only. Lists every USB filesystem by label; `Idle` grey while none is mounted, `Good` green once one is |
| `usb-menu` | the click handler. Every entry is verb-first, so a selection is never a guess |

```
mount   DATA   3.4G   ext4                            udisksctl mount
open    ALBI   /run/media/maro/ALBI                   foot --working-directory=…
unlock  sdc1   32G   encrypted                        udisksctl unlock, in a foot
eject   ALBI, DATA   7.4G   TNDIY+ ZC3306 USB DISK    unmount all, then power-off
```

`open` starts a plain shell at the mountpoint rather than launching a file
manager — `lf` is one thing you might want there, not the only one.

```sh
sudo xbps-install -S udisks2 ntfs-3g exfatprogs
```

`udisks2` is D-Bus activated on the system bus, so it has no runit service and
inherits the polkit gotcha from §3 — reload the bus once after installing it or
nothing can reach it:

```sh
sudo dbus-send --system --type=method_call --dest=org.freedesktop.DBus \
  --print-reply /org/freedesktop/DBus org.freedesktop.DBus.ReloadConfig
udisksctl status                       # lists the internal NVMe once it answers
```

**No sudoers fragment, no password.** udisks2's shipped polkit actions grant
`filesystem-mount` and `power-off-drive` to any *active* session on a local seat
as long as the drive is removable, and that is what `loginctl` already reports
for the tty1 session (§14). Only a non-removable disk escalates to `auth_admin`,
and then xfce-polkit prompts.

**`/etc/udev/rules.d/99-usb-bar.rules`** — so plug and unplug repaint the bar at
once rather than at the next poll:

```sh
sudo mkdir -p /etc/udev/rules.d
sudo install -m 0644 -o root -g root /dev/stdin /etc/udev/rules.d/99-usb-bar.rules <<'END'
ACTION=="add|remove", SUBSYSTEM=="block", ENV{ID_BUS}=="usb", RUN+="/usr/bin/pkill -RTMIN+8 -x i3status-rs"
END
sudo udevadm control --reload
```

`SIGRTMIN+8` is the `signal = 8` on the block in
`~/.config/i3status-rust/config.toml`, and this rule is the only user of that
number. The block's `interval = 30` is left in as the safety net for a `remove`
event that arrives without `ID_BUS` in the udev db.

The `eject` entry unmounts every filesystem on the drive and then powers it
down, so it is safe to pull. It leads with the labels on the drive rather than
the vendor string — you recognise a stick as `ALBI`, not as `TNDIY+ ZC3306 USB
DISK` — and falls back to the vendor string only when there is no label to use.

Mounts land in `/run/media/maro/<label>`, created and removed by udisks2 —
nothing goes in `/etc/fstab`, and an unclean unplug leaves no stale mountpoint.
`usb-menu` shells out to `udisksctl`; `usb-status` only reads `lsblk`, so the
bar keeps working even when udisks2 is not.

Both scripts key off `lsblk`'s `TRAN`, and it is only filled in on the **disk**
for USB — `sda` reports `usb`, its `sda1` reports nothing, unlike nvme where it
propagates to every partition. So they carry the transport down through `PKNAME`.
Filter on `TRAN` alone and the filesystem never matches, because the row that has
the transport has no filesystem and the row that has the filesystem has no
transport.

`usb-status` prints `{"text":""}` — not nothing — when no stick is attached.
`hide_when_empty` drops a block whose *text* is empty, but a `json = true` block
whose command printed **no output at all** does not parse, and the block flips to
a red `Invalid JSON` a few seconds after start.

Verify:

```sh
udevadm monitor --property --subsystem-match=block   # plug a stick: ID_BUS=usb
lsblk -o NAME,TRAN,FSTYPE,LABEL,SIZE,MOUNTPOINT
usb-status                                           # {"text":""} when idle
```

## 12. Snapshots: snapper + cron + grub-btrfs + rollback

- `snapper -c root` covers `/` (`@`) only. Retention in
  `/etc/snapper/configs/root` is the create-config default (hourly 10 / daily 10
  / monthly 10 / yearly 10, `NUMBER_LIMIT=50`).
- Timeline + cleanup run from `/etc/cron.hourly/snapper` → needs `cronie`.
- `grub-btrfsd` (service) watches `/.snapshots` and keeps `grub-btrfs.cfg`
  current; snapshots appear as a GRUB submenu. `/etc/default/grub-btrfs/config`
  is default.
- **`/etc/snapper-rollback.conf`** — set the device (shipped default is
  `/dev/sda42`, i.e. non-functional):

```ini
[root]
subvol_main = @
subvol_snapshots = @snapshots
mountpoint = /btrfsroot
dev = /dev/nvme0n1p3
```

Usage:

```sh
sudo snapper -c root create --description "pre-upgrade"
sudo snapper -c root list
sudo snapper-rollback <N> && sudo reboot          # or boot the snapshot from GRUB first
```

## 13. Secrets and WireGuard

Nothing secret is in this repo; 1Password is the store. After signing in:

- SSH keys → `~/.ssh/github`, `~/.ssh/id_rsa` (0600). The agent is the
  `ssh-agent` wrapping sway; keys load on first use.
- WireGuard → `~/.config/wireguard/*.conf` (0600). `wg-quick` takes full paths,
  so `/etc/wireguard` is unused.

Sudo fragment so the bar block and `wg-menu` work without a prompt —
**`/etc/sudoers.d/wg-quick`**:

```sh
sudo install -m 0440 -o root -g root /dev/stdin /etc/sudoers.d/wg-quick <<'END'
maro ALL=(ALL) NOPASSWD: /usr/bin/wg-quick, /usr/bin/wg
END
sudo visudo -c
```

This is the only sudoers fragment. Power actions go through `loginctl`.

## 14. Audit on a rebuilt machine

```sh
cat /sys/power/mem_sleep                          # s2idle [deep]
grep -oE 'mem_sleep_default=\S+|resume=\S+' /proc/cmdline
ls /var/service | tr '\n' ' '                     # matches the list in §3
loginctl                                          # one session on seat0/tty1
pgrep -a swayidle                                 # must contain 'idlehint'
grep -c . /var/log/socklog/kernel/current         # socklog reachable as maro (group)
groups                                            # … lpadmin
head -1 /etc/resolv.conf                          # resolv.conf from …
ps -eo comm | grep -E 'polkitd|gnome-keyring|xfce-polkit|wireplumber|1password'
udisksctl status                                  # udisks2 answering on the bus
lpstat -p; lpoptions -p Brother_DCP-1610W_series | grep -o 'brlaser[^ ]*'
sudo -n wg show interfaces && echo sudoers-ok
sudo visudo -c
```

Config drift check. `sudo xbps-pkgdb -a` (silent when clean) only checks
non-config files; it never reports edited `conf_files`. To list every
package-shipped file under `/etc` that differs from what the package installed:

```sh
sudo python3 - <<'EOF'
import plistlib, hashlib, glob, os
for p in sorted(glob.glob('/var/db/xbps/.*-files.plist')):
    pkg = os.path.basename(p)[1:-len('-files.plist')]
    for cf in plistlib.load(open(p, 'rb')).get('conf_files', []):
        try: got = hashlib.sha256(open(cf['file'], 'rb').read()).hexdigest()
        except FileNotFoundError: print(pkg, cf['file'], 'MISSING'); continue
        if got != cf.get('sha256'): print(pkg, cf['file'], 'MODIFIED')
EOF
```

(Shipped content of any file: `xbps-query --cat=/etc/<file> <pkg>`.)
Expected modified set, 19 files: `fstab group passwd subuid subgid sudoers`
(install), `dhcpcd.conf`, `elogind/{logind,sleep}.conf`, `default/grub`,
`default/libc-locales`, `resolvconf.conf`, `pam.d/system-login`, `hostname`,
`rc.conf`, `conf.d/snapper`, `snapper-rollback.conf`, and
`cups/{printers,subscriptions}.conf` — those last two are cupsd's own runtime
state, not hand edits. Anything else is undocumented drift.

## 15. Maintenance

```sh
sudo snapper -c root create --description "pre-update"
sudo xbps-install -Su
sudo xbps-remove -o          # orphans
sudo vkpurge list            # stale kernel files; vkpurge rm all
sudo grub-mkconfig -o /boot/grub/grub.cfg   # after kernel changes
```

Snapshot before kernel upgrades; boot the previous snapshot from GRUB if a new
kernel misbehaves.

## Gotchas

- `[s2idle] deep` instead of `s2idle [deep]` → `mem_sleep_default=deep` not on
  the cmdline. Only `[s2idle]` → BIOS Sleep State is not "Linux".
- Hibernate returns to a fresh boot → resume module missing from the initramfs
  (`sudo lsinitrd | grep -i resume`) or wrong `resume=` UUID.
- `svlogtail` never returns → it ends in `tail -F`; for a one-shot read grep
  `/var/log/socklog/<log>/current` directly. Permission denied → re-login.
- `loginctl` empty / lid does nothing → `dbus` or `elogind` not running, or sway
  was launched without `dbus-run-session`.
- Sway died and you are back on a TTY right after editing elogind config → you
  ran `sv restart elogind` inside the session; it recreates `seat0` (§6). Reboot
  to apply instead.
- Screen locks but never suspends → missing `idlehint` in the swayidle line (§6).
  Confirm with `busctl --system get-property org.freedesktop.login1
  /org/freedesktop/login1 org.freedesktop.login1.Manager IdleHint` — it must flip
  to `true` once idle. Lid/power key still work, which is what masks this.
- Wired link up but no DHCP → `dhcpcd` service not enabled (§2).
- `/etc/resolv.conf` says "Generated by dhcpcd" → run `sudo dhcpcd -n enp0s31f6`.
- BT audio `br-connection-unknown` → `libspa-bluetooth`; then `pkill wireplumber; pkill pipewire` and let sway re-exec.
- Brother job "completes", nothing prints → queue still on the Everywhere PPD (§10).
- polkit auth dialogs never appear → `xfce-polkit` not exec'd from sway, or the
  D-Bus `ReloadConfig` step (§3) was skipped after installing polkit.
- 1Password 2FA asks every unlock → one of: PAM lines (§8), keyring daemon exec,
  `dbus-run-session`.
- USB block never appears → `udisks2` not installed, or the D-Bus `ReloadConfig`
  after installing it was skipped (§11). `usb-status` run by hand prints exactly
  the JSON the bar parses.
- USB block reads `Invalid JSON` → `usb-status` printed nothing at all. A
  `json = true` custom block needs valid JSON even when it has nothing to say;
  `hide_when_empty` only acts on an empty `text` field (§11).
- Stick is in `lsblk` but the block stays hidden → `TRAN` is empty on USB
  partitions; the transport has to come from the parent disk via `PKNAME` (§11).
- Block appears only after up to 30 s → the udev rule is missing, or
  `udevadm control --reload` was not run (§11).
- NTFS stick fails with `unknown filesystem type 'ntfs'` → `ntfs-3g` missing (§11).
- Keyboard backlight: `tpacpi::kbd_backlight`, levels 0–2 (`brightnessctl -d tpacpi::kbd_backlight set 1`).
- `Shift+XF86MonBrightness*` cannot be bound in Sway; use `$mod+`.
- atuin was removed: it fights starship's `PROMPT_COMMAND`.

## Key files

| File | Owner of the truth |
|---|---|
| `/etc/fstab` | §1.2 (`xgenfstab`; subvol on every btrfs line) |
| `/etc/hostname` `/etc/rc.conf` `/etc/default/libc-locales` | §1.3 |
| `/etc/conf.d/snapper` `/etc/snapper/configs/root` | `snapper create-config` (§1.3) |
| `/var/service/*` | §2–3 |
| `/etc/elogind/logind.conf` `/etc/elogind/sleep.conf` | §6 |
| `/etc/default/grub` `/etc/dracut.conf.d/resume.conf` | §6 (UUID machine-specific) |
| `/etc/iwd/main.conf` `/etc/dhcpcd.conf` `/etc/resolvconf.conf` | §7 |
| `/etc/pam.d/system-login` | §8 |
| `/opt/1Password` `/usr/bin/1password` `/usr/share/applications/1password.desktop` `/etc/1password/` | §9 |
| `/etc/cups/ppd/Brother_DCP-1610W_series.ppd` | generated by `lpadmin` (§10) |
| `/etc/snapper-rollback.conf` `/etc/default/grub-btrfs/config` | §12 |
| `/etc/udev/rules.d/99-usb-bar.rules` | §11 |
| `/etc/sudoers.d/wg-quick` | §13 |
| `/var/log/socklog/*` `/etc/sv/{socklog-unix,nanoklogd}` | `socklog-void`, untouched defaults (§2–3) |
| everything else under `~` | stow packages in this repo |

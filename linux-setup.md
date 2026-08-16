# Void Linux / Asahi Setup Notes

MacBook (Apple Silicon), Void Linux, Asahi kernel, Sway/Wayland.

---

## System Overview

- **OS**: Void Linux (runit init, xbps package manager)
- **Kernel**: Asahi (`7.0.9+1-asahi_1` or later) — `linux-asahi`, never vanilla `linux`
- **Root filesystem**: btrfs on `nvme0n1p6`, zstd:3 compression, subvolume layout (`@`, `@home`, `@snapshots`, `@var_log`)
- **Boot chain**: m1n1 stage 1 (`p5`) → m1n1 stage 2 + U-Boot (`p4`) → GRUB (`p4`, at `/EFI/BOOT/BOOTAA64.EFI`) → Linux (`p6`)
- **WM**: Sway (Wayland)
- **Session/seat**: seatd + acpid (no elogind)
- **Bar**: i3status-rs
- **Terminal**: foot
- **Launcher**: fuzzel
- **Clipboard**: clipman + wl-paste

---

## Installation (Void on M1 Pro, from the live USB)

Assumes the Asahi installer (`alx.sh` from macOS) has already run and prepared the partition layout below. Only step 2 is destructive.

> **This layout is specific to the original M1 Pro.** On different hardware the
> partition *numbers* and *sizes* will differ — re-derive them from `lsblk` after
> `alx.sh` finishes. What carries over is the **structure**, not the numbering:
> Apple's iBoot/APFS/recovery partitions come first and are untouchable, the
> Asahi ESP (U-Boot + m1n1 stage 2) must be mounted at `/boot/efi` and **never
> reformatted**, the m1n1 stage-1 recovery partition is left alone, and the new
> Linux partition goes in the free space the installer left behind. Substitute
> your own device names throughout this section.

### Partition layout

| Partition | Size | What it is | Action |
|---|---|---|---|
| `nvme0n1p1` | 500M | Apple iBoot system | leave alone |
| `nvme0n1p2` | 92.1G | macOS APFS container | leave alone |
| `nvme0n1p3` | 2.3G | Apple recovery APFS | leave alone |
| `nvme0n1p4` | 477M | EFI System (Asahi U-Boot + m1n1 stage 2) | mount at `/boot/efi` |
| *free space* | ~365 GiB | between p4 and p5 | **create new partition here → becomes `p6`** |
| `nvme0n1p5` | 5G | Apple Silicon recovery (m1n1 stage 1) | leave alone |

`nvme0n2` (3M) and `nvme0n3` (128M) are Apple NVMe namespaces — ignore them.

**Never reformat `p4`** — that destroys U-Boot/m1n1 and the machine won't boot until `alx.sh` is re-run from macOS recovery.

### 1. Network in the live env

```sh
ping -c 2 voidlinux.org

# if wifi isn't up:
sudo wpa_supplicant -B -i wlan0 -c <(wpa_passphrase "SSID" "password")
sudo dhcpcd wlan0
```

### 2. Create the Linux partition

```sh
sudo cfdisk /dev/nvme0n1
```

Navigate to the **Free space** entry between `p4` and `p5` (~365 GiB) → **New** (accept full size) → **Type** `Linux filesystem` → **Write** (`yes`) → **Quit**.

Verify with `lsblk` that `p6` exists and is ~365 GiB. **Stop and re-run cfdisk if it isn't** — this is the only destructive step.

### 3. Format btrfs + subvolumes

```sh
sudo mkfs.btrfs -L void /dev/nvme0n1p6
sudo mount /dev/nvme0n1p6 /mnt

sudo btrfs subvolume create /mnt/@
sudo btrfs subvolume create /mnt/@home
sudo btrfs subvolume create /mnt/@snapshots
sudo btrfs subvolume create /mnt/@var_log

sudo umount /mnt
```

| Subvolume | Mount | Why separate |
|---|---|---|
| `@` | `/` | the only one that gets system snapshots |
| `@home` | `/home` | kept out of system snapshots so an OS rollback doesn't roll back your files |
| `@snapshots` | `/.snapshots` | where snapper stores snapshots |
| `@var_log` | `/var/log` | logs churn constantly; excluding keeps snapshots clean |

### 4. Mount for the install

```sh
sudo mount -o subvol=@,compress=zstd:3,noatime,ssd /dev/nvme0n1p6 /mnt

sudo mkdir -p /mnt/home /mnt/.snapshots /mnt/var/log /mnt/boot/efi

sudo mount -o subvol=@home,compress=zstd:3,noatime,ssd      /dev/nvme0n1p6 /mnt/home
sudo mount -o subvol=@snapshots,compress=zstd:3,noatime,ssd /dev/nvme0n1p6 /mnt/.snapshots
sudo mount -o subvol=@var_log,compress=zstd:3,noatime,ssd   /dev/nvme0n1p6 /mnt/var/log

sudo mount /dev/nvme0n1p4 /mnt/boot/efi
```

### 5. Install the base system

```sh
sudo mkdir -p /mnt/var/db/xbps/keys
sudo cp /var/db/xbps/keys/* /mnt/var/db/xbps/keys/

sudo XBPS_ARCH=aarch64 xbps-install -S -r /mnt \
  -R "https://repo-default.voidlinux.org/current/aarch64" \
  base-system asahi-base asahi-scripts asahi-firmware \
  btrfs-progs grub-arm64-efi snapper
```

| Package | Why |
|---|---|
| `base-system` | Void base |
| `asahi-base` | Apple Silicon configs, dracut hooks, m1n1 kernel hook — **pulls in `linux-asahi` transitively** |
| `asahi-scripts` | `asahi-fwupdate`, `update-grub`, `update-m1n1` |
| `asahi-firmware` | Apple firmware payload + `asahi-fwextract` — needed for WiFi/BT/audio |
| `btrfs-progs` / `grub-arm64-efi` / `snapper` | filesystem tools, bootloader, snapshots |

**Do NOT add `linux` to this list.** On Void's aarch64 repo `linux` is the vanilla mainline kernel, separate from `linux-asahi`. With both installed GRUB sees two kernels and tends to pick the highest version number — often the vanilla one, which boots to a TTY with **no working keyboard at all** (no Apple SPI HID driver, no Type-C controller driver). This was the actual cause of the first failed install.

```sh
ls /mnt/lib/modules/
# Expect ONE directory ending in '-asahi_N'. If there are two, remove the vanilla one:
#   sudo xbps-remove -r /mnt linux linux<version>
```

### 6. fstab

```sh
sudo xgenfstab -U /mnt > /mnt/etc/fstab
grep btrfs /mnt/etc/fstab
```

**Every btrfs line must carry a `subvol=@...` option.** Missing it → `VFS: Unable to mount root fs` panic on boot.

### 7. Chroot

```sh
sudo xchroot /mnt /bin/bash
```

Everything from here until step 12 runs **inside the chroot**.

### 8. Base configuration

```sh
echo "maro" > /etc/hostname          # hostname on the original machine

vi /etc/rc.conf
#   KEYMAP="us"
#   TIMEZONE="Europe/Bratislava"
#   HARDWARECLOCK="UTC"

vi /etc/default/libc-locales      # uncomment: en_US.UTF-8 UTF-8
xbps-reconfigure -f glibc-locales

ln -sf /usr/share/zoneinfo/Europe/Bratislava /etc/localtime

passwd
xbps-install -S sudo
useradd -m -G wheel,audio,video,input,storage -s /bin/bash maro
passwd maro
visudo                            # uncomment: %wheel ALL=(ALL:ALL) ALL
```

Two more groups get added later, once the packages that create them are
installed — `_seatd` (from `seatd`, required for Sway to open input/DRM devices)
and `lpadmin` (from `cups`, to manage printers without sudo):

```sh
usermod -aG _seatd,lpadmin maro    # after seatd and cups are installed
```

Final group set on the original machine: `wheel audio video storage input lpadmin _seatd`.

### 9. GRUB (`--removable` is mandatory)

```sh
mount -t efivarfs none /sys/firmware/efi/efivars 2>/dev/null || true

grub-install --target=arm64-efi \
             --efi-directory=/boot/efi \
             --bootloader-id="Void" \
             --removable
```

`--removable` installs GRUB at `EFI/BOOT/BOOTAA64.EFI`, which is the only path m1n1 looks at. Without it the system will not boot.

### 10. snapper config

Snapper insists on creating its own `.snapshots` subvolume, so hand it the one we already made:

```sh
umount /.snapshots
rmdir /.snapshots

snapper -c root create-config /

btrfs subvolume delete /.snapshots
mkdir /.snapshots
chmod 750 /.snapshots
mount /.snapshots

snapper -c root get-config
```

Retention is tunable in `/etc/snapper/configs/root` (`TIMELINE_LIMIT_HOURLY`, `TIMELINE_LIMIT_DAILY`).

**Timeline snapshots need a cron daemon.** Void drives snapper from
`/etc/cron.hourly/snapper`, not from a runit service, so without a cron daemon
running *no snapshots are ever taken* and the rollback procedure below has
nothing to roll back to. This was the case on the original machine — `/.snapshots`
was empty the entire time. Install and enable one:

```sh
xbps-install -S cronie
ln -s /etc/sv/cronie /var/service/
```

Then confirm, an hour or so later, that snapshots actually appear:

```sh
snapper -c root list        # must show more than just the initial entry
ls /.snapshots/
```

### 11. Stage Apple firmware

Packages the firmware blobs the Asahi installer extracted from macOS into a `firmware.cpio` on the ESP; the kernel concatenates it onto the initramfs at boot. **Not** boot-critical and irrelevant to the keyboard (SPI HID is a pure kernel driver), but without it there's no WiFi, Bluetooth or audio after first boot.

```sh
asahi-fwupdate

ls -la /boot/efi/vendorfw/          # expect firmware.tar + firmware.cpio, recent timestamps
cpio -t < /boot/efi/vendorfw/firmware.cpio 2>/dev/null | head   # paths under vendorfw/
```

`/lib/firmware/vendor/apple/` being empty is normal — modern Asahi loads firmware via the cpio extension, not from on-disk files.

If `asahi-fwupdate` can't find its source archive, check `ls /boot/efi/asahi/` for `all_firmware.tar.gz` and the `.plist` files. If missing, re-run `alx.sh` from macOS recovery to re-create the stash.

### Pre-reboot sanity checklist

All of these run **inside the chroot, before exiting**. Check #2 is the one that decides whether you get a working keyboard at the login prompt.

```sh
# 1. Exactly ONE kernel, and it's the Asahi one
ls /lib/modules/
#    Expect a single dir ending in '+N-asahi_N'. Two dirs = vanilla kernel got in;
#    xbps-remove linux linux<X.Y> && rm -rf /lib/modules/<vanilla-version>

# 2. *** CRITICAL *** initramfs contains the Apple HID modules
lsinitrd /boot/initramfs-*-asahi_*.img | grep -E 'hid-apple|spi-apple|spi-hid'
#    Expect: hid-apple.ko.zst, spi-hid/spi-hid-apple.ko.zst,
#            spi-hid/spi-hid-apple-of.ko.zst, spi/spi-apple.ko.zst
#    Empty = dead TTY login. Fix: install asahi-scripts, xbps-reconfigure -f <kernel-pkg>

# 3. Dracut asahi hooks present (these are what put #2 in the initramfs)
ls /usr/lib/dracut/modules.d/ | grep -i asahi
#    Expect: 91kernel-modules-asahi and 99asahi-firmware

# 4. GRUB at the path m1n1 looks for
ls /boot/efi/EFI/BOOT/BOOTAA64.EFI          # missing = forgot --removable

# 5. grub.cfg exists and references the asahi kernel
find /boot -name 'grub.cfg' -exec grep -l asahi {} \;
#    If grub.cfg doesn't exist: grub-mkconfig -o /boot/grub/grub.cfg

# 6. fstab has subvol= on every btrfs line
grep btrfs /etc/fstab

# 7. (optional, WiFi/BT) firmware cpio staged
ls -la /boot/efi/vendorfw/firmware.cpio
```

One-liner verdict:

```sh
ls /lib/modules/ | grep -q '^[^a]*asahi[^a]*$' && \
[ $(ls /lib/modules/ | wc -l) -eq 1 ] && \
lsinitrd /boot/initramfs-*-asahi_*.img 2>/dev/null | grep -q spi-hid-apple-of && \
[ -f /boot/efi/EFI/BOOT/BOOTAA64.EFI ] && \
[ -f /boot/grub/grub.cfg ] && \
! grep btrfs /etc/fstab | grep -v 'subvol=' >/dev/null && \
echo "OK to reboot" || echo "NOT OK — investigate"
```

### 12. Finalize and reboot

`xbps-reconfigure -fa` regenerates the initramfs with the asahi dracut hooks active — this is what puts the Apple HID/SPI modules in (checklist #2). It must run **after** `asahi-base` + `asahi-scripts` are installed.

```sh
xbps-reconfigure -fa
exit                 # leave chroot
sudo umount -R /mnt
sudo shutdown -r now
```

Pull the USB stick while the Mac reboots. Expect m1n1 → U-Boot → GRUB → Void.

### After first boot

```sh
# snapper: Void ships ONLY 'snapperd'. There are no snapper-timeline or
# snapper-cleanup services on Void — the timeline runs from /etc/cron.hourly/snapper,
# which is why cronie is required (see the Snapshots section).
sudo ln -s /etc/sv/snapperd /var/service/
sudo xbps-install -S cronie
sudo ln -s /etc/sv/cronie /var/service/

# system update
sudo xbps-install -Su xbps
sudo xbps-install -Su
```

**Full set of enabled services** on the original machine (`ls /var/service`).
`agetty-tty1`–`tty6`, `udevd` and `dbus` are enabled by the base install; the
rest you add:

```sh
for s in dbus seatd turnstiled acpid iwd chronyd bluetoothd \
         avahi-daemon cupsd cups-browsed speakersafetyd snapperd cronie; do
    sudo ln -s "/etc/sv/$s" /var/service/
done
```

`speakersafetyd` is not optional on Apple Silicon — it enforces the speaker
excursion limits. Running without it risks physical damage to the speakers.
`seatd` and `turnstiled` are what let Sway start as a normal user at all.

Networking: this machine uses **iwd**, not NetworkManager — see the Networking section below. (Generic Void guides suggest `NetworkManager` here; don't install both.)

### Install failure modes

| Symptom | Cause / fix |
|---|---|
| Boots to TTY login, no keyboard input at all (internal *and* USB) | A vanilla kernel got booted. Diagnostic: press Caps Lock — no LED toggle means the kernel isn't seeing the keyboard at the HID layer. Recovery below. |
| Live USB no longer detected by U-Boot after a failed install | U-Boot skips the USB boot target when the on-disk install is broken. Simplest fix: wipe `nvme0n1p6` and re-run `alx.sh` from macOS recovery. Or mash Esc for a U-Boot prompt and force it: `setenv boot_targets "usb"` / `setenv bootmeths "efi"` / `boot`. |
| GRUB shows, kernel panics `VFS: Unable to mount root fs` | `subvol=` missing from `/etc/fstab` or the kernel cmdline. Chroot in, fix fstab, `xbps-reconfigure -fa`, `update-grub`. |
| Boots fine but no WiFi / BT / audio | Forgot `asahi-fwupdate`. Fix live: `sudo xbps-install -Sy asahi-firmware asahi-scripts && sudo asahi-fwupdate && sudo xbps-reconfigure -f linux-asahi<version> && sudo reboot` |
| `asahi-fwupdate` can't find the firmware archive | `/boot/efi/asahi/all_firmware.tar.gz` is missing — re-run `alx.sh` from macOS recovery. |

Recovery for the dead-keyboard case, from the live USB:

```sh
sudo mount -o subvol=@,compress=zstd:3,noatime,ssd /dev/nvme0n1p6 /mnt
sudo mount /dev/nvme0n1p4 /mnt/boot/efi
sudo xchroot /mnt /bin/bash

xbps-query -l | grep -E '^ii (linux|asahi)'
ls /lib/modules/

# both a vanilla and an asahi kernel present? remove the vanilla one:
xbps-remove linux linux<X.Y>
rm -rf /lib/modules/<vanilla-version>

lsinitrd /boot/initramfs-*-asahi_*.img | grep -E 'hid-apple|spi-hid'
# empty → asahi hooks not active:
xbps-install -Sy asahi-scripts asahi-base
xbps-reconfigure -f linux-asahi<version>

update-grub
exit && sudo umount -R /mnt && sudo reboot
```

State to collect before asking r/AsahiLinux or IRC (from a live-USB chroot):

```sh
uname -r                        # only meaningful if actually booted
xbps-query -l | grep -E 'linux|asahi|dracut'
ls /lib/modules/
lsinitrd /boot/initramfs-*-asahi_*.img | grep -E 'hid-apple|spi-hid'
ls -la /boot/efi/EFI/BOOT/ /boot/efi/vendorfw/
cat /etc/fstab
find /boot -name 'grub.cfg'
```

---

## Btrfs Snapshots (snapper)

Config `root` covers `/` only (`@`); `/home` is deliberately excluded so an OS rollback doesn't take your files with it.

```sh
sudo snapper -c root create --description "before nvidia experiment"   # manual snapshot
sudo snapper -c root list                                             # list
sudo snapper -c root status 5..0                                      # what changed since #5
sudo snapper -c root undochange 5..0 /etc/some-file                   # restore one file
sudo snapper -c root rollback 5 && sudo reboot                        # roll back the system
```

**Unbootable system — recover from the live USB:**

```sh
sudo mount /dev/nvme0n1p6 /mnt
ls /mnt/@snapshots/                 # pick a good snapshot number, e.g. 5
sudo btrfs subvolume list /mnt      # find the ID of @snapshots/5/snapshot
sudo btrfs subvolume set-default <ID> /mnt
sudo umount /mnt
sudo reboot
```

---

## Power Management (lid / power button + idle → lock + suspend)

**Architecture**: split between two daemons.
- `acpid` runs `/etc/acpi/handler.sh` on direct hardware events (lid close/open, power button, sleep button). The handler only **locks**; it does not suspend.
- `swayidle` (running as the user, started from sway's `exec`) owns idle-driven timing: lock at 60s, suspend at 2 or 5 min depending on lid state.

They coordinate through `/run/acpi-lid-state` (`closed` or `open`), written by the handler on every lid event (mode 644 so the user-side swayidle command can read it) and read by swayidle's middle timeout.

**Packages**: `acpid`, `swaylock`, `swayidle`. (`zzz` is **not** a package —
it ships in `runit-void`, which is already installed. `xbps-install zzz` fails.)

The handler itself is version-controlled at `system/etc/acpi/handler.sh` in the
dotfiles repo; `system/restore.sh` installs it.

### ACPI handler (`/etc/acpi/handler.sh`)

| Event | Action |
|---|---|
| `button/power` | lock screen (`swaylock -f`); no suspend |
| `button/sleep` | lock screen, **then** suspend (`zzz`) — so resume comes back to a locked screen |
| `button/lid close` | write `closed` to `/run/acpi-lid-state` (chmod 644), lock screen |
| `button/lid open` | write `open` to `/run/acpi-lid-state` (chmod 644) |
| `ac_adapter` | CPU governor scaling (upstream behavior) |
| `video/brightness*` | no-op — sway handles via `XF86MonBrightness*` → `brightnessctl` |

The handler runs as root under acpid. It reads `WAYLAND_DISPLAY` and the sway user's UID from `/proc/<sway-pid>/environ`, then `su -c` to invoke swaylock as the sway user.

### swayidle (`~/.config/sway/config`)

```
exec swayidle -w \
    timeout 60  'sh -c "date \"+%F %T  IDLE-LOCK\" >> /var/log/power.log; swaylock -f -c 000000 --indicator-idle-visible"' \
    timeout 120 'sh -c "pgrep -x swaylock >/dev/null && [ closed = \"$(cat /run/acpi-lid-state 2>/dev/null)\" ] && { date \"+%F %T  IDLE-SUSPEND(closed)\" >> /var/log/power.log; sudo -n zzz; }"' \
    timeout 300 'sh -c "date \"+%F %T  IDLE-SUSPEND\" >> /var/log/power.log; sudo -n zzz"'
```

All three timeouts measure idle from the *same* last-input moment, not cumulatively:
- 60s idle → lock.
- 120s idle → suspend if lid is closed (skipped otherwise).
- 300s idle → suspend unconditionally.

If you go idle at 13:00 with the lid closed: lock at 13:01, suspend at 13:02. With the lid open: suspend at 13:05.

Switch events (lid close/open) are *not* treated as user activity by sway/libinput, so closing the lid mid-idle does not reset swayidle's counter. Worst-case latency from "close lid" to "suspend" is therefore the gap until the next eligible timeout slot fires (max ~3 min if the lid closes just after the 120s slot already ran). Acceptable in practice; revisit only if it bites.

### Power event logging (`/var/log/power.log`)

Every idle and suspend transition is logged to a single file, written from two
sides:

| Writer | Lines it emits |
|---|---|
| swayidle timeouts (above, user) | `IDLE-LOCK`, `IDLE-SUSPEND(closed)`, `IDLE-SUSPEND` |
| `/etc/zzz.d/suspend/00-log` (root) | `SUSPEND  lid=<open\|closed\|?>` immediately before suspend |
| `/etc/zzz.d/resume/99-log` (root) | `RESUME   lid=<open\|closed\|?>` immediately after resume |

`zzz` runs everything in `/etc/zzz.d/suspend/` before suspending and
`/etc/zzz.d/resume/` after resuming; both hooks read `/run/acpi-lid-state` for
context. Together the three writers give a complete picture — you can see
whether a suspend was idle-driven or button-driven, and whether a resume ever
happened.

Both hooks are version-controlled in `system/etc/zzz.d/` and installed by
`system/restore.sh`, which also creates `/var/log/power.log` owned by the user
so swayidle can append to it without sudo. Reading it:

```sh
tail -20 /var/log/power.log
```

Note `/var/log` is its own btrfs subvolume (`@var_log`) excluded from snapshots,
so this log survives a system rollback.

### sudoers (split per command in `/etc/sudoers.d/`)

swayidle runs as the user, but `zzz` writes to `/sys/power/state` which is root-only. NOPASSWD is granted per command, one file per binary, mode 0440 root:root.

| File | Grant |
|---|---|
| `/etc/sudoers.d/zzz` | `maro ALL=(root) NOPASSWD: /usr/bin/zzz` |
| `/etc/sudoers.d/reboot` | `maro ALL=(root) NOPASSWD: /usr/bin/reboot` |
| `/etc/sudoers.d/poweroff` | `maro ALL=(root) NOPASSWD: /usr/bin/poweroff` |

(These three replaced a single combined `power-menu` file; the unrelated `wg-quick` fragment was unchanged.)

All four fragments are in `system/etc/sudoers.d/` in the dotfiles repo, but note
that `zzz`, `reboot` and `poweroff` there are **reconstructed from this document**
rather than copied — they are mode `0440 root:root` and could not be read without
sudo when the repo was assembled. Capture the real ones with
`sudo ./system/backup-secrets.sh <dest>` before wiping the old machine.
`system/restore.sh` runs `visudo -c` after installing them and aborts if the
result doesn't parse.

---

## Networking (iwd)

**How it works**: iwd manages Wi-Fi. It handles DHCP and DNS itself (no dhcpcd/resolvconf needed separately, but openresolv must be installed).

**Packages**: `iwd`, `openresolv`, `dbus`

**Services enabled**:
```sh
ln -s /etc/sv/dbus /var/service/
ln -s /etc/sv/iwd /var/service/
```

**Config** (`/etc/iwd/main.conf`):
```ini
[General]
EnableNetworkConfiguration=true

[Network]
NameResolvingService=resolvconf
```

**Connecting**: `iwctl` — interactive TUI. `impala` is a friendlier frontend.

**DNS** (`/etc/resolvconf.conf`): iwd hands DHCP-provided nameservers to
openresolv, which writes `/etc/resolv.conf`. To override with Cloudflare:

```ini
resolv_conf=/etc/resolv.conf
name_servers="1.1.1.1 1.0.0.1"
```

Apply with `sudo resolvconf -u`, verify with `cat /etc/resolv.conf`.

> **Bug on the original machine:** this setting was written to
> `/etc/resolvconf.con`**`F`** (capital F) and was therefore silently ignored for
> months — `/etc/resolv.conf` kept pointing at the router (`192.168.1.1`).
> The corrected file is in `system/etc/resolvconf.conf`; `restore.sh` installs it
> and deletes the typo'd one. If you'd rather keep DHCP DNS, drop the
> `name_servers` line.

---

## Time Synchronization (chrony)

**Package**: `chrony`

**Service**:
```sh
sudo ln -s /etc/sv/chronyd /var/service/
```

---

## Bluetooth

**Packages**: `bluez`, `bluetui`, `libspa-bluetooth`

**Service**:
```sh
sudo ln -s /etc/sv/bluetoothd /var/service/
```

**`libspa-bluetooth`** is required — it's the PipeWire SPA plugin for Bluetooth audio (A2DP, HFP). Without it, connecting audio devices fails with `br-connection-unknown`.

**TUI**: `bluetui` — open from the bar (left-click the BT block) or run directly with `bluetui`.

**Diagnostics**: `bluetoothctl` — use `show` to check adapter state, `devices Connected` to list connected devices.

**Audio crackling**: If Bluetooth audio crackles, increase PipeWire's quantum (buffer size). Apply temporarily with:
```sh
pw-metadata -n settings 0 clock.force-quantum 2048
```
Make permanent in `~/.config/pipewire/pipewire.conf.d/quantum.conf`:
```
context.properties = {
    default.clock.quantum     = 2048
    default.clock.min-quantum = 1024
}
```

---

## Printing (CUPS)

**How it works**: `cups-browsed` auto-discovers network printers via mDNS (`avahi-daemon`) and creates queues on the fly. For printers that aren't actually driverless/AirPrint-capable, it falls back to a generic "IPP Everywhere" PWG-raster PPD — jobs complete without error but nothing comes out of the printer. Use a model-specific driver package instead when that happens (see Brother note below).

**Packages**: `cups`, `cups-filters`, `cups-browsed`, `avahi`, `nss-mdns`

**Services enabled**:
```sh
sudo ln -s /etc/sv/cupsd /var/service/
sudo ln -s /etc/sv/cups-browsed /var/service/
sudo ln -s /etc/sv/avahi-daemon /var/service/
```

**Group**: user added to `lpadmin` (manage printers without `sudo` each time):
```sh
sudo usermod -aG lpadmin maro
```

**`.local` hostname resolution**: `/etc/nsswitch.conf` already ships `hosts: files mdns dns`, but that `mdns` entry is inert without the `nss-mdns` package — it provides the actual NSS module. Without it, CUPS can't resolve printer hostnames like `BRN202B20B93381.local` and jobs fail with "Unable to locate printer". Fix: `sudo xbps-install -S nss-mdns` — no restart needed, glibc resolves the NSS module per lookup.

**Admin UI**: `http://localhost:631` (Administration → Add Printer / Modify Printer / Jobs).

**CLI**: `lpstat -p -d` (queue status), `lpstat -o` (job list), `lpstat -v` (device URIs), `lp -d <printer> <file>` (print), `cancel <job-id>` (cancel a stuck job).

### Brother DCP-1610W

- Discovered via mDNS as `BRN202B20B93381.local`; device URI `dnssd://Brother%20DCP-1610W%20series._pdl-datastream._tcp.local/?uuid=e3248000-80ce-11db-8000-202b20b93381`.
- **Not driverless/AirPrint-capable** (2013-era monochrome laser MFP) — `cups-browsed` auto-assigns the generic "IPP Everywhere" PPD by default, which silently fails to print (job shows "completed", nothing comes out).
- **Fix**: install `brother-brlaser` (open-source Brother laser driver, packaged in Void) and reassign the existing queue to it — either via the web UI (Modify Printer → search "Brother" in the driver list) or:
  ```sh
  sudo xbps-install -S brother-brlaser
  lpinfo -m | grep -i brlaser
  sudo lpadmin -p Brother_DCP-1610W_series -m <driver string from above> \
    -v "dnssd://Brother%20DCP-1610W%20series._pdl-datastream._tcp.local/?uuid=e3248000-80ce-11db-8000-202b20b93381" -E
  ```
- Queue name: `Brother_DCP-1610W_series`.

---

## Keyboard (MacBook — Cmd as Ctrl, dual layout)

**How it works**: Sway's `xkb_options` remaps the Win/Cmd key to Ctrl. Two layouts are configured (US QWERTY + Slovak QWERTY); switched with Alt+Shift.

**Sway config** (`~/.config/sway/config`):
```
input type:keyboard {
    xkb_layout "us,sk"
    xkb_variant ",qwerty"
    xkb_options "altwin:ctrl_win"
}

# Switch layout on Alt+Shift release (fires only if no other key was pressed)
bindsym --release Mod1+Shift_L exec swaymsg input type:keyboard xkb_switch_layout next
```

**Modifier key**: `$mod` is set to `Mod1` (Alt), not Super — since Cmd is remapped to Ctrl and used system-wide.

**Slovak variant**: `qwerty` keeps QWERTY letter layout; without it the default is QWERTZ.

**Note**: workspace switching bindings (`$mod+1`–`$mod+0`) break in Slovak layout because SK remaps the number row. Workaround pending — consider `bindcode` for those lines.

---

## Brightness

**How it works**: Sway keybindings call `brightnessctl`. udev rules (shipped with brightnessctl) grant write access to backlight/leds sysfs nodes on device add.

**Packages**: `brightnessctl`

**udev rules** (shipped, no changes needed): `/usr/lib/udev/rules.d/90-brightnessctl.rules`
- `backlight` subsystem → `video` group gets write access
- `leds` subsystem → `input` group gets write access

**Note**: After install, udev rules only apply on device add (boot). To apply without rebooting:
```sh
sudo udevadm trigger --action=add --subsystem-match=backlight
sudo udevadm trigger --action=add --subsystem-match=leds
```

**Sway config** (`~/.config/sway/config`):
- `XF86MonBrightnessDown/Up` — screen brightness (±5%)
- `$mod+XF86MonBrightnessDown/Up` — keyboard backlight (±5%)

**Keyboard backlight device**: `/sys/class/leds/kbd_backlight/` (max 255), supported since kernel 6.4 via `pwm-apple` driver.

**Screen backlight device**: `/sys/class/backlight/apple-panel-bl/` (max 500)

---

## Packages Installed (beyond Void defaults)

### Asahi / Hardware
| Package | Purpose |
|---|---|
| `asahi-base` | Asahi Linux base metapackage |
| `asahi-audio` | Apple Silicon audio support (speaker safety, tuning) |
| `asahi-firmware` | Apple Silicon firmware files |
| `asahi-scripts` | Asahi utility scripts (`asahi-fwupdate`, `update-grub`, `update-m1n1`) |
| `mesa` | GPU drivers (Apple Silicon via Asahi Mesa) |
| `grub-arm64-efi` | Bootloader — installed with `--removable` so m1n1 finds it at `EFI/BOOT/BOOTAA64.EFI` |

### Desktop / Sway
| Package | Purpose |
|---|---|
| `sway` | Wayland tiling window manager |
| `swaylock` | Screen locker |
| `swayidle` | Idle management (auto-lock after timeout) |
| `foot` | Terminal emulator |
| `fuzzel` | Application launcher |
| `i3status-rust` | Status bar |
| `nerd-fonts` | Icon fonts for status bar |
| `brightnessctl` | Backlight control (screen + keyboard) |
| `wev` | Wayland event viewer (keysym debugging) |
| `xdg-desktop-portal` | XDG portal (file picker, screen share, etc.) |
| `xdg-desktop-portal-wlr` | wlroots backend for XDG portal |

### Session / Seat / Secrets
| Package | Purpose |
|---|---|
| `seatd` | Seat management daemon — also creates the `_seatd` group the user must join |
| `turnstile` | Session tracker (PAM-based, manages XDG_RUNTIME_DIR) |
| `pam_rundir` | PAM module that creates XDG_RUNTIME_DIR |
| `gnome-keyring` | Secret service provider (`org.freedesktop.secrets`) — required for 1Password to persist its 2FA token |
| `libsecret` | Secret service client library |

### Audio
| Package | Purpose |
|---|---|
| `pipewire` | Audio server |
| `wireplumber` | PipeWire session manager |
| `wiremix` | PipeWire mixer TUI |

### Bluetooth
| Package | Purpose |
|---|---|
| `bluez` | Bluetooth daemon (`bluetoothd`) and tools (`bluetoothctl`) |
| `bluetui` | Bluetooth TUI — pair, connect, disconnect devices |
| `libspa-bluetooth` | PipeWire SPA plugin for Bluetooth audio (A2DP, HFP) — required for audio devices |

### Networking
| Package | Purpose |
|---|---|
| `iwd` | Wi-Fi daemon |
| `impala` | Wi-Fi TUI (iwd frontend) |
| `openresolv` | DNS resolution manager (required by iwd for network configuration) |
| `dbus` | Message bus — required by iwd |
| `wireguard-tools` | WireGuard userland tools (`wg`, `wg-quick`) |
| `nftables` | Packet filter userland — pulled in by `wg-quick`, which uses `nft` for its firewall rules |

### Printing
| Package | Purpose |
|---|---|
| `cups` | Print server/spooler (daemon + `lpadmin`/`lpstat` CLI) |
| `cups-filters` | Driverless/IPP-Everywhere support |
| `cups-browsed` | Auto-discovers and adds network/IPP printers |
| `avahi` | mDNS/Bonjour discovery daemon |
| `nss-mdns` | NSS module — resolves `.local` mDNS hostnames (required for `cups-browsed`-discovered queues to actually connect) |
| `brother-brlaser` | Open-source Brother laser printer driver (needed for non-driverless Brother models, e.g. DCP-1610W) |

### Developer Tools
| Package | Purpose |
|---|---|
| `git` | Version control — **needed before anything else to clone the dotfiles repo** |
| `github-cli` | `gh` — GitHub CLI (auth, PRs); config at `~/.config/gh/` |
| `direnv` | Per-directory environment loader — **hooked in `.bashrc`; every shell errors without it** |
| `lazygit` | Terminal UI for git (alias: `lg`) |
| `delta` | Syntax-highlighted pager for git diff/log/show |

**`mise` is NOT an xbps package** — it is a standalone binary installed by hand
to `~/.local/bin/mise` (~81 MB). See "Manually installed" below. It is activated
from `.bashrc` in `--shims` mode (no `PROMPT_COMMAND` hook).

**Runtimes managed by mise** (`~/.config/mise/config.toml`, stowed):
| Runtime | Pinned version |
|---|---|
| Java | `temurin-26` |
| Node.js | `26` |
| sbt | `1.12.11` |
| usage | `latest` |

### Scala toolchain

Installed outside xbps, largely under `~/.local/share/`. None of it is
reproduced by `stow` — reinstall by hand on a rebuild.

| Tool | Where it lives | Purpose |
|---|---|---|
| `cs` (coursier) | `~/.local/bin/cs` (~67 MB binary) | Scala artifact fetcher / launcher; installs the rest |
| `metals` | `~/.local/share/coursier/bin/metals` | Scala language server (used by nvim-metals) |
| `scalafmt` | via mise | Formatter |
| `scala-cli` | `~/.local/share/scalacli/` | Scala runner/REPL |
| `sbt` | via mise shim | Build tool, pinned to 1.12.11 |

Bootstrap: download `cs` from the coursier release page, `chmod +x`, then
`cs setup` and `cs install metals scala-cli`. Java comes from mise, not coursier.

### Utilities
| Package | Purpose |
|---|---|
| `clipman` | Clipboard manager (Wayland) |
| `neovim` | Text editor |
| `curl` | HTTP client |
| `lsof` | List open files |
| `btrfs-progs` | btrfs filesystem tools |
| `snapper` | btrfs snapshot management |
| `firefox` | Web browser |
| `ffmpeg` | Media codecs (H.264 for Firefox — required for Twitch and other video) |
| `xdg-utils` | XDG desktop integration tools (required by 1Password after-install.sh) |
| `stow` | Dotfiles manager — symlinks `~/dotfiles/` packages into target locations |
| `starship` | Shell prompt (git status, exit codes, language versions, etc.) |
| `bash-completion` | Extended Tab completion for common tools and subcommands |
| `fzf` | Fuzzy finder — Ctrl+R history search, Ctrl+T file picker, Alt+C cd |
| `lf` | Terminal file manager — vim-inspired, minimal (launch with `lf`, cds on exit) |
| `chafa` | Terminal image renderer (used by lf previewer for images and PDFs) |
| `poppler-utils` | PDF tools — provides `pdftoppm` for lf PDF preview |
| `lazygit` | Terminal UI for git (alias: `lg`) |
| `zoxide` | Smart cd with frecency ranking — aliased to `cd`; learns visited dirs |
| `eza` | Modern `ls` replacement (aliases: `ls`, `ll`, `la`, `lt`) |
| `bat` | `cat` with syntax highlighting (aliased to `cat`) |
| `ripgrep` | `rg` — fast recursive grep; also the fzf/nvim search backend |
| `fd` | Fast `find` replacement |
| `unzip` | Archive extraction |
| `xxd` | Hex dump / reverse |
| `fastfetch` | System info banner |
| `xmirror` | Void repository mirror selector |
| `speech-dispatcher` | Speech synthesis daemon — pulled in as a Firefox dependency |
| `cronie` | Cron daemon — **required for snapper timeline snapshots to run at all** |

### Manually installed (not via xbps)
| Package | Purpose |
|---|---|
| 1Password (tar.gz) | Password manager; installed to `/opt/1Password` via tar.gz from downloads.1password.com |
| Claude Code | AI coding CLI; installed via `curl -fsSL https://claude.ai/install.sh \| bash` |
| `mise` | Runtime version manager — binary at `~/.local/bin/mise`; `curl https://mise.run \| sh` |
| `cs` (coursier) | Scala toolchain installer — binary at `~/.local/bin/cs`; see Scala toolchain above |

### Auto-installed (notable dependencies)
| Package | Purpose |
|---|---|
| `acpid` | ACPI event daemon (pulled in by base or asahi-base) |

---

## Dotfiles

**Repository**: `git@github.com:marovargovcik/dotfiles.git`
(HTTPS: `https://github.com/marovargovcik/dotfiles.git`) — **public**.

Managed with `stow`. Real files live in `~/dotfiles/`, symlinked into place.

### Bootstrap on a fresh machine

Chicken-and-egg: the SSH remote needs `~/.ssh/github`, which is *not* in the repo
(it's a private key). So clone over HTTPS first, restore the keys, then switch
the remote.

```sh
sudo xbps-install -S git stow

git clone https://github.com/marovargovcik/dotfiles.git ~/dotfiles
cd ~/dotfiles

# Nothing in $HOME may already occupy a target path — stow refuses to clobber
# regular files. On a fresh install .bashrc/.bash_profile exist; delete them.
rm -f ~/.bashrc ~/.bash_profile

stow bash bin foot git i3status-rust lf mise nvim ssh sway
#  (or: stow $(ls -d */ | tr -d /  | grep -v system)   — system/ is NOT a stow package)

# /etc-side config, services, groups
sudo ./system/restore.sh

# restore private keys from the backup tarball, then:
git remote set-url origin git@github.com:marovargovcik/dotfiles.git
```

### Packages

| Package | Links into |
|---|---|
| `bash` | `~/.bashrc`, `~/.bash_profile` |
| `bin` | `~/.local/bin/{bt-status,power-menu,start-statusbar,wg-menu,wg-status}` |
| `foot` | `~/.config/foot/foot.ini` |
| `git` | `~/.gitconfig` |
| `i3status-rust` | `~/.config/i3status-rust/config.toml` |
| `lf` | `~/.config/lf/` (lfrc, preview) |
| `mise` | `~/.config/mise/config.toml` |
| `nvim` | `~/.config/nvim/` (init.lua, nvim-pack-lock.json) |
| `ssh` | `~/.ssh/config` — config only; **keys are not in the repo** |
| `sway` | `~/.config/sway/config` |

`system/` is a directory of `/etc` reference copies plus `restore.sh` /
`backup-secrets.sh`. **It is not a stow package** — never run `stow system`.
See `system/README.md`.

### Folding

Stow links the highest directory it can. Where the target directory doesn't
already exist, you get a single symlink to the whole package dir (`~/.config/lf`,
`~/.config/nvim`, `~/.config/mise`); where it does, you get per-file symlinks
inside a real directory (`~/.config/sway`, `~/.config/foot`, `~/.ssh/config`).
Both are normal. With a folded directory, anything an app writes into it lands
in the repo — which is deliberate for `mise` and the nvim pack lock.

### Everyday use

```sh
cd ~/dotfiles
stow <pkg>          # link
stow -D <pkg>       # unlink
stow -R <pkg>       # relink after adding/removing files
stow -n -v <pkg>    # dry run — do this first when unsure
```

To add a package: mirror the target path inside `~/dotfiles/<name>/`, move the
real file in (stow won't overwrite an existing regular file), then `stow <name>`.

`.stow-local-ignore` keeps `.git`, README files, `*.bak*`, editor temp files and
swap files from being linked into `$HOME`.

---

## SSH

**Agent**: `ssh-agent` is launched by wrapping Sway in `.bash_profile` (`exec dbus-run-session ssh-agent sway`). The agent lives for the duration of the login session — no manual `ssh-add` needed. There is no runit service for ssh-agent; the wrapper approach is the correct method on Void without systemd user services.

**Keys**: `~/.ssh/github` (+ `.pub`) for GitHub, and `~/.ssh/id_rsa` (+ `.pub`).

> **Private keys are not in the dotfiles repo and cannot be regenerated.** The
> `ssh` stow package carries `~/.ssh/config` only. Before wiping a machine, run
> `sudo ./system/backup-secrets.sh <destination>` — it tars `~/.ssh/`,
> `~/.config/wireguard/`, `~/.local/state/bash_history.archive` and
> `/etc/sudoers.d/` to a 0600 archive. Restore it before switching the dotfiles
> remote to SSH. If the keys are lost: generate a new pair
> (`ssh-keygen -t ed25519 -f ~/.ssh/github`) and add the public key at
> <https://github.com/settings/keys>.

**Config** (`~/.ssh/config`):
```
AddKeysToAgent yes

Host github.com
    HostName github.com
    User git
    IdentityFile ~/.ssh/github
```

`AddKeysToAgent yes` means the key is added to the agent automatically on first use (e.g., first `git push`). You type the passphrase once per session; subsequent uses are cached. Running `ssh-add -l` immediately after login will show no entries — that's normal, keys appear after first use.

---

## Shell (bash)

**Sway launch** (`.bash_profile`): sway is started via `dbus-run-session ssh-agent sway` so the D-Bus session bus and SSH agent are available to all child processes. Without `dbus-run-session`, `DBUS_SESSION_BUS_ADDRESS` is unset and apps that rely on D-Bus session services (secret service, 1Password) silently fail. `ssh-agent` wraps sway so `SSH_AUTH_SOCK` and `SSH_AGENT_PID` are inherited by all child processes.

```sh
if [ -z "$WAYLAND_DISPLAY" ] && [ "$(tty)" = "/dev/tty1" ]; then
    export XDG_CURRENT_DESKTOP=sway
    export XDG_SESSION_TYPE=wayland
    exec dbus-run-session ssh-agent sway
fi
```

**PipeWire** is started from the sway config (`exec pipewire`) rather than `.bash_profile`, so it inherits `DBUS_SESSION_BUS_ADDRESS` from `dbus-run-session`. PipeWire auto-spawns `wireplumber` and `pipewire-pulse` — only `pipewire` itself needs to be launched.

**i3status-rs startup** is wrapped by `~/.local/bin/start-statusbar`, which polls until `$XDG_RUNTIME_DIR/pulse/native` exists before starting i3status-rs. This prevents the sound block from erroring on startup due to a race where the bar launches before PipeWire-Pulse is ready.

- **History**: bash's defaults (`histappend` off, `HISTSIZE`/`HISTFILESIZE` 500) make
  every exiting shell *overwrite* `~/.bash_history` with its own in-memory list,
  capping it at 500 lines and discarding concurrent sessions. `.bashrc` fixes this:
  ```sh
  shopt -s histappend
  HISTSIZE=100000
  HISTFILESIZE=200000
  HISTCONTROL=ignoreboth
  HISTTIMEFORMAT='%F %T '
  ```
  A pre-fix export of the accumulated history is kept at
  `~/.local/state/bash_history.archive` (included in `backup-secrets.sh`).
  Stray `~/.bash_history-<pid>.tmp` files are leftovers from interrupted shell
  exits — safe to delete, but check them for unique lines first.
- **Vi mode**: `set -o vi` — `Esc` for normal mode, `v` to edit command in nvim
- **Default editor**: `$EDITOR` and `$VISUAL` set to `nvim`
- **direnv**: `eval "$(direnv hook bash)"` — loads per-directory `.envrc` files.
  The `direnv` package must be installed or every shell start prints an error.
- **bash-completion**: sourced from `/usr/share/bash-completion/bash_completion`
- **fzf key bindings**:
  - `Ctrl+R` — fuzzy history search
  - `Ctrl+T` — fuzzy file picker (inserts path at cursor)
  - `Alt+C` — fuzzy cd into subdirectory
- **Starship**: replaces `PS1`, shows git branch/status, exit code, command duration
- **zoxide**: aliased to `cd` — learns frecency over time; use full path to override (`cd ~/exact/path`)
- **Aliases**: `ls/ll/la/lt` → eza, `cat` → bat, `lg` → lazygit
- **bashrc load order**: history settings → bash-completion → fzf → starship → mise → zoxide → direnv (zoxide must come after starship)
- **atuin**: tried and abandoned. Worth knowing why, so it isn't retried blindly:
  it was installed and configured (`~/.config/atuin/config.toml`) but the
  `atuin init bash` line was never added, so it recorded nothing — the config sat
  dormant while plain bash history did all the work. Removed entirely;
  fzf's `Ctrl+R` is the history search.
- **Starship**: runs on defaults — there is no `~/.config/starship.toml`. If you
  customize it, add a `starship` stow package.
- **mise activation**: uses `--shims` mode (no PROMPT_COMMAND hook); see the
  Developer Tools table for the pinned runtimes

## Sway Keybindings (notable)

| Keybind | Action |
|---|---|
| `$mod+Return` | Open foot terminal |
| `$mod+d` | Open fuzzel launcher |
| `$mod+c` | Open clipman picker (fuzzel dmenu) |
| `$mod+Shift+q` | Kill focused window |
| `$mod+f` | Fullscreen |
| `$mod+r` | Resize mode |
| `$mod+Shift+r` | Reload sway config |
| `$mod+Shift+e` | Exit sway |
| `Alt+Shift` (release) | Switch keyboard layout (US ↔ SK) |
| `XF86AudioMute/Lower/Raise` | Volume via wpctl |
| `XF86MonBrightnessDown/Up` | Screen brightness (±5%) |
| `$mod+XF86MonBrightnessDown/Up` | Keyboard backlight (±5%) |
| `Print` | Screenshot via grim |

---

## i3status-rs Bar

Config: `~/.config/i3status-rust/config.toml` — theme `gruvbox-dark`, icons `material-nf`.

| Block | Notes |
|---|---|
| `custom` (bluetooth) | Shows `󰂯` when disconnected, `󰂱 <name>` when connected; polls `~/.local/bin/bt-status` every 3s; left-click opens `bluetui` in foot |
| `net` | Shows SSID; left-click opens `impala` in foot |
| `custom` (VPN) | Shows `VPN off` or `VPN <tunnel>` — polls `~/.local/bin/wg-status` every 5s; left-click opens fuzzel picker via `~/.local/bin/wg-menu` |
| `battery` | `macsmc-battery` device |
| `custom` | Screen + keyboard backlight percentages (reads sysfs directly) |
| `keyboard_layout` | Shows `US` or `SK`; uses `sway` driver (IPC) with `[block.mappings]` to shorten names |
| `sound` | PipeWire/PulseAudio volume; left-click opens `wiremix` in foot |
| `time` | Date + time |
| `custom` (power) | Static `󰐥` icon; left-click runs `~/.local/bin/power-menu` |

---

## WireGuard VPN

**Package**: `wireguard-tools` — provides `wg` and `wg-quick`. The kernel module is built into Asahi (Linux 5.6+), no DKMS needed.

**Configs**: stored in `~/.config/wireguard/*.conf` (user-owned, 600 permissions). `wg-quick` accepts full paths so `/etc/wireguard/` is not required.

> **These files contain `PrivateKey` and are deliberately NOT in the dotfiles
> repo** (which is public). They cannot be regenerated locally — losing them
> means requesting new tunnel configs from the VPN provider. `backup-secrets.sh`
> includes them. Tunnels on the original machine: `sk-bts-wg-001`, `sk-bts-wg-002`.

**Asahi gotcha**: `ip6table_raw` kernel module is missing — strip IPv6 from configs or `wg-quick up` will fail with `ip6tables-restore: unable to initialize table 'raw'`. Remove the IPv6 address from `Address` and `::/0` from `AllowedIPs`, keep only IPv4 entries.

**Usage**:
```sh
sudo wg-quick up ~/.config/wireguard/sk-bts-wg-001.conf
sudo wg show
sudo wg-quick down ~/.config/wireguard/sk-bts-wg-001.conf
```

**Sudo rules** (`/etc/sudoers.d/wg-quick`) — NOPASSWD for wg and wg-quick:
```
maro ALL=(ALL) NOPASSWD: /usr/bin/wg-quick, /usr/bin/wg
```

**i3status-rs integration**: `~/.local/bin/wg-status` + `~/.local/bin/wg-menu` — bar block shows current tunnel; left-click opens fuzzel picker to connect/disconnect.

---

## Power Menu (`~/.local/bin/power-menu`)

A small shell script invoked by clicking the `󰐥` block in the bar. Opens fuzzel in dmenu mode with four options:

| Option | Command |
|---|---|
| lock | `swaylock -f -c 000000` |
| sleep | `swaylock` in background, sleep 1s, then `sudo zzz` |
| restart | `sudo reboot` |
| power-off | `sudo poweroff` |

**Sudo rules**: each command has its own NOPASSWD fragment in `/etc/sudoers.d/` — see the Power Management section above for the full breakdown of `zzz`, `reboot`, `poweroff`.

**Note**: `loginctl` is not available — turnstile provides session tracking but not the full elogind/logind CLI. Power commands go through `sudo` + runit utilities directly.

---

## Key Files

| File | Purpose |
|---|---|
| `~/.config/sway/config` | Sway WM configuration |
| `/etc/acpi/handler.sh` | ACPI event handler (lid, power button) |
| `/usr/lib/udev/rules.d/90-brightnessctl.rules` | udev rules for backlight write access |
| `/etc/1password/custom_allowed_browsers` | 1Password: allowlist for browser extension integration (Firefox added) |
| `/opt/1Password/` | 1Password installation directory |
| `~/.config/service/turnstile-ready/run` | Per-user runit service; starts core user services then signals turnstile readiness |
| `/etc/pam.d/system-login` | Stock Void file **plus** two `pam_gnome_keyring.so` lines and `pam_rundir.so` — without these, no secret service and no `XDG_RUNTIME_DIR` |
| `/etc/zzz.d/suspend/00-log` | Logs `SUSPEND` + lid state to `/var/log/power.log` before suspending |
| `/etc/zzz.d/resume/99-log` | Logs `RESUME` + lid state after resuming |
| `/var/log/power.log` | Combined idle/suspend/resume event log; written by swayidle and both zzz hooks. On `@var_log`, so it survives snapshot rollbacks |
| `/etc/resolvconf.conf` | openresolv config — where `name_servers=` belongs (note the historical `.conF` typo) |
| `~/.local/bin/bt-status` | Bluetooth status script for i3status-rs — outputs icon or connected device name |
| `~/.local/bin/wg-status` | WireGuard status script for i3status-rs — outputs `VPN off` or `VPN <tunnel>` |
| `~/.local/bin/wg-menu` | WireGuard fuzzel picker — lists `~/.config/wireguard/*.conf`, prefixes active tunnels with `[connected]`, toggles on select |
| `~/.config/wireguard/` | WireGuard tunnel configs (user-owned, 600 permissions) |
| `~/.local/bin/power-menu` | Power menu script (lock / sleep / restart / power-off via fuzzel) |
| `~/.local/bin/start-statusbar` | Waits for PipeWire-Pulse socket then starts i3status-rs |
| `/etc/sudoers.d/zzz` | NOPASSWD sudo rule for `/usr/bin/zzz` (consumed by swayidle for idle suspend, and by power-menu) |
| `/etc/sudoers.d/reboot` | NOPASSWD sudo rule for `/usr/bin/reboot` (consumed by power-menu) |
| `/etc/sudoers.d/poweroff` | NOPASSWD sudo rule for `/usr/bin/poweroff` (consumed by power-menu) |
| `/etc/sudoers.d/wg-quick` | NOPASSWD sudo rules for wg-quick and wg (needed by wg-status and wg-menu) |
| `/run/acpi-lid-state` | Current lid state (`open` / `closed`); written by ACPI handler on every lid event, read by swayidle's lid-aware suspend timeout |
| `/etc/cups/cups-browsed.conf` | cups-browsed config — controls driverless auto-add behavior for discovered network printers |
| `/etc/cups/ppd/Brother_DCP-1610W_series.ppd` | Active PPD for the Brother printer queue (should be the brlaser-generated one, not the generic Everywhere PPD) |
| `/etc/fstab` | Every btrfs line must carry `subvol=@...` — missing it panics the kernel at boot |
| `/boot/efi/EFI/BOOT/BOOTAA64.EFI` | GRUB, at the only path m1n1 looks for (result of `grub-install --removable`) |
| `/boot/efi/asahi/all_firmware.tar.gz` | Firmware stash written by the Asahi installer; source for `asahi-fwupdate` |
| `/boot/efi/vendorfw/firmware.cpio` | Staged Apple firmware, concatenated onto the initramfs at boot (WiFi/BT/audio) |
| `/etc/snapper/configs/root` | snapper config for `/` — retention limits live here |

---

## Notes & Gotchas

- **Never install the `linux` package alongside `linux-asahi`**. On Void's aarch64 repo `linux` is vanilla mainline, and GRUB will happily default to it by version number. The vanilla kernel boots to a TTY login prompt with *no keyboard at all* — the Apple SPI HID and Type-C (`tipd`) drivers are Asahi-only. `asahi-base` pulls in `linux-asahi` transitively; don't override it. Caps Lock not toggling its LED at a dead prompt is the tell.
- **`xbps-reconfigure -fa` must run after `asahi-scripts` is installed**, not before — otherwise the initramfs is generated without the Apple HID dracut hooks and the keyboard drivers never make it in.
- **`grub-install` needs `--removable`** on this machine — m1n1 only looks at `EFI/BOOT/BOOTAA64.EFI`.
- **Never reformat `nvme0n1p4`** — it holds U-Boot and m1n1 stage 2. Doing so makes the machine unbootable until `alx.sh` is re-run from macOS recovery.
- **acpid and elogind cannot run simultaneously** on Void. This setup uses acpid (no elogind).
- **swayidle `before-sleep`** requires a logind provider (elogind) to work. Without elogind, direct lid-close/power-button locking is handled in the ACPI handler, and idle-driven suspend is handled by swayidle's `timeout` cascade reading `/run/acpi-lid-state`.
- **`/run/acpi-lid-state` must be world-readable** so swayidle (running as the user) can read it. acpid creates files with umask 077 → mode 600, which silently breaks the lid-aware suspend conditional (the test becomes `[ closed = "" ]` → false → no suspend). The handler explicitly `chmod 644`s the file after each write.
- **Keyboard backlight keybinding**: `Shift+XF86MonBrightnessDown` does not work in Sway — the plain `XF86MonBrightnessDown` binding fires regardless of Shift being held. Use `$mod+` instead.
- **acpid handler runs as root** — to run swaylock in the user's Wayland session, the handler reads `WAYLAND_DISPLAY` from `/proc/<sway-pid>/environ` and uses `su` to run swaylock as the sway user.
- **1Password tar.gz install**: `after-install.sh` emits `xdg-desktop-menu: No writable system menu directory found` — this is a non-fatal warning; the rest of the install (polkit, browser integration, helpers) completes fine.
- **1Password 2FA / secret service**: 1Password uses `org.freedesktop.secrets` (D-Bus) to persist the 2FA token. Without a running D-Bus session bus, it logs `unsupported transport 'disabled'` and 2FA is only valid for the current unlock session. Fix: launch sway via `dbus-run-session sway` in `.bash_profile` and install `gnome-keyring`. Verify with `echo $DBUS_SESSION_BUS_ADDRESS` — must be non-empty after login. Two pieces are required beyond the package:

  ```sh
  # ~/.config/sway/config (stowed)
  exec gnome-keyring-daemon --start --daemonize --components=secrets,pkcs11
  ```
  ```
  # /etc/pam.d/system-login — the two local additions (restored by system/restore.sh)
  auth       optional   pam_gnome_keyring.so
  -session   optional   pam_gnome_keyring.so auto_start
  ```
- **Firefox H.264 / Twitch**: Firefox requires the `ffmpeg` package for H.264 decoding. Without it, video streams show "not supported in this browser".
- **Bluetooth audio requires `libspa-bluetooth`**: BlueZ alone is not enough for audio devices. Without the PipeWire SPA Bluetooth plugin, connecting headphones/speakers fails with `br-connection-unknown`. Install `libspa-bluetooth` and restart PipeWire (`pkill wireplumber; pkill pipewire`).
- **i3status-rs bluetooth block**: The built-in `bluetooth` block type does not support `hide_disconnected` in v0.36.x — use a `custom` block with `~/.local/bin/bt-status` instead.
- **`.local` hostname resolution needs `nss-mdns`**: having `avahi-daemon` running and `hosts: files mdns dns` in `/etc/nsswitch.conf` is not sufficient on its own — without the `nss-mdns` package, the `mdns` NSS module doesn't exist and any `*.local` hostname (e.g. discovered printers) fails to resolve with "Unable to locate printer" or similar.
- **Non-driverless network printers default to a broken "Everywhere" queue**: `cups-browsed` auto-adds newly discovered network printers using the generic IPP-Everywhere PWG-raster PPD regardless of whether the printer actually supports it. For older/non-AirPrint printers (e.g. the Brother DCP-1610W) this fails silently — the job shows as completed but nothing prints. Install the model-specific driver (`brother-brlaser` for this Brother) and reassign the queue's PPD.
- **`zzz` is not an installable package** — it ships in `runit-void`. `xbps-install zzz` fails with "package not found"; the binary is already at `/usr/bin/zzz`.
- **Void has no `snapper-timeline` / `snapper-cleanup` services** — only `snapperd`. The timeline is driven by `/etc/cron.hourly/snapper`, so **a cron daemon must be installed and enabled or no snapshots are ever taken**. On the original machine this was missed and `/.snapshots` stayed empty for the life of the install, meaning the documented rollback procedure would have had nothing to roll back to. Verify with `snapper -c root list` a couple of hours after setup.
- **`stow` refuses to overwrite existing regular files** — on a fresh install, `~/.bashrc` and `~/.bash_profile` are created by `useradd` from `/etc/skel` and must be deleted before `stow bash`. The error is "existing target is not a symlink".
- **Config for a tool you never activated does nothing** — atuin sat fully configured but un-hooked for months. When a tool seems not to work, check that its `init`/`hook` line is actually in `.bashrc` before debugging its config.
- **Watch for typo'd config filenames** — `/etc/resolvconf.con`**`F`** silently did nothing for months. Nothing warns about an unrecognized file in `/etc`; verify the effect (`cat /etc/resolv.conf`), not just the edit.

---

## Before Wiping This Machine

Everything below is unrecoverable once the disk is gone. Work top to bottom.

```sh
cd ~/dotfiles

# 1. Commit and push any outstanding dotfile changes
git status --short
git push origin main

# 2. Capture the /etc-side files this repo could not read without root
sudo ./system/backup-secrets.sh /run/media/maro/<usb-stick>

# 3. Verify the tarball actually contains the keys before trusting it
tar -tzf /run/media/maro/<usb-stick>/void-secrets-*.tar.gz
```

Checklist of what must end up off the machine:

| Item | Where it is | Recoverable otherwise? |
|---|---|---|
| `~/.ssh/github`, `~/.ssh/id_rsa` (+ `.pub`) | backup tarball | no — regenerate + re-register with GitHub |
| `~/.config/wireguard/*.conf` | backup tarball | no — request new configs from the provider |
| `/etc/sudoers.d/{zzz,reboot,poweroff}` | backup tarball (needs `sudo`) | approximately — `system/` has reconstructions |
| `~/.local/state/bash_history.archive` | backup tarball | no |
| Everything in `~/dotfiles` | GitHub | yes, once pushed |
| `/etc` hand-written config | `system/` in the repo | yes, once pushed |
| 1Password vault | 1Password cloud | yes — needs account password + Secret Key |
| Firefox profile (`~/.mozilla`, 232 MB) | **nowhere** | only via Firefox Sync — set it up first if you want tabs/history |
| `~/.claude.json`, `~/.claude/` | **nowhere** | no — session history and settings, back up separately if wanted |

Then, on the new machine: install Void per the Installation section, and follow
**Dotfiles → Bootstrap on a fresh machine**.

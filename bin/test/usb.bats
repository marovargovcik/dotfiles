#!/usr/bin/env bats
# usb-menu and usb-status against a stand-in lsblk with two sticks and a
# laptop's own disk.

# shellcheck source=helpers.bash
source "$BATS_TEST_DIRNAME/helpers.bash"

setup() {
    isolate jq
    # shellcheck disable=SC2016 # expanded by the stub
    stub lsblk 'case $1 in
-J) cat "'"$fixtures"'/lsblk.json" ;;
-nlo) printf "%s\n" "/dev/sda" "/dev/sda1 /run/media/me/STICK" "/dev/sda2" ;;
esac'
    logged udisksctl foot swaynag pkill
}

@test "the menu: each filesystem by what picking it does, then an eject per stick" {
    fuzzel_picks ''
    run "$bin/usb-menu"
    assert_success
    assert_equal "$(cat "$tmp/menu")" "open    STICK   /run/media/me/STICK
mount   sda2   8.7G   ext4
unlock  sdb1   64G   encrypted
eject   STICK   28.7G   SanDisk Ultra Fit
eject   Generic Flash Disk   64G"
    assert_equal "$(calls)" ""
}

@test "mount mounts the partition, without asking for a password" {
    fuzzel_picks 1
    run "$bin/usb-menu"
    assert_success
    assert_equal "$(calls)" "udisksctl mount --no-user-interaction -b /dev/sda2
pkill -RTMIN+8 -x i3status-rs"
}

@test "open opens a terminal where it's mounted" {
    fuzzel_picks 0
    run "$bin/usb-menu"
    assert_equal "$(calls)" "foot --working-directory=/run/media/me/STICK"
}

@test "unlock asks for the passphrase in a terminal, then shows the menu again" {
    fuzzel_picks 2 ''
    run "$bin/usb-menu"
    assert_success
    assert_equal "$(calls)" "foot udisksctl unlock -b /dev/sdb1"
    assert_equal "$(cat "$tmp/picks")" ""
}

@test "eject unmounts what's mounted on the stick, then powers it off" {
    fuzzel_picks 3
    run "$bin/usb-menu"
    assert_equal "$(calls)" "udisksctl unmount --no-user-interaction -b /dev/sda1
udisksctl power-off --no-user-interaction -b /dev/sda
pkill -RTMIN+8 -x i3status-rs"
}

@test "a failure shows udisksctl's error and stops" {
    stub udisksctl 'echo "Error: target is busy"; exit 1'
    fuzzel_picks 3
    run "$bin/usb-menu"
    assert_failure
    assert_equal "$(calls)" "swaynag -t error -m usb-menu: Error: target is busy"
}

@test "with no stick, no menu" {
    stub lsblk 'echo "{\"blockdevices\": []}"'
    fuzzel_picks 0
    run "$bin/usb-menu"
    assert_success
    assert [ ! -e "$tmp/menu" ]
}

@test "the bar block lists each USB filesystem by label, good once one is mounted" {
    run "$bin/usb-status"
    assert_output '{"text":" STICK, sda2","state":"Good"}'
}

@test "the bar block is idle with nothing mounted, and empty with no stick or no lsblk output" {
    stub lsblk "sed 's|\"/run/media/me/STICK\"|null|' \"$fixtures/lsblk.json\""
    run "$bin/usb-status"
    assert_output '{"text":" STICK, sda2","state":"Idle"}'
    stub lsblk 'echo "{\"blockdevices\": []}"'
    run "$bin/usb-status"
    assert_output '{"text":""}'
    stub lsblk 'exit 1'
    run "$bin/usb-status"
    assert_output '{"text":""}'
}

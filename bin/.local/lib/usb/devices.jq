# The USB block devices of lsblk -J's device tree, flattened, each with the
# transport and the disk it belongs to carried down from the top: lsblk fills
# TRAN on the disk but leaves it empty on its partitions for USB (unlike nvme,
# where it propagates). With no input at all, none.
def devs(t; d): (.tran // t) as $t | (d // .name) as $d
    | (.tran = $t | .disk = $d), (.children[]? | devs($t; $d));
def usb_devices:
    [inputs][0].blockdevices // [] | .[] | devs(null; null)
    | select(.tran == "usb");                # add "mmc" here to cover the SD slot

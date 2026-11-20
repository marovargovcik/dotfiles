# usb-menu's entries, each as three strings: action, target, menu line.
include "devices";

[usb_devices]
| map(select(.fstype | IN(null, "swap", "linux_raid_member", "LVM2_member") | not)) as $fs
| ($fs[]
   | (.label // .name) as $name
   | if .fstype == "crypto_LUKS" then
         "unlock", "/dev/\(.name)", "unlock  \($name)   \(.size)   encrypted"
     elif .mountpoint then
         "open", .mountpoint, "open    \($name)   \(.mountpoint)"
     else
         "mount", "/dev/\(.name)", "mount   \($name)   \(.size)   \(.fstype)"
     end),
  # Eject entries come last, one per drive, named after the labels on it: you
  # recognise a stick by the label on it, not by the controller its vendor
  # soldered on. Only a real label, never the kernel name: with nothing to
  # recognise the stick by, the entry is better off naming the hardware.
  (.[] | select(.type == "disk")
   | .name as $n
   | ([$fs[] | select(.disk == $n) | .label // empty] | join(", ")) as $labels
   | ([.vendor, .model | values | gsub("_"; " ") | splits(" +")]
      | map(select(. != "")) | join(" ") | if . == "" then $n end) as $model
   | "eject", "/dev/\($n)",
     if $labels != "" then "eject   \($labels)   \(.size)   \($model)"
     else "eject   \($model)   \(.size)" end)

# Physical hardware validation checklist

CI/QEMU results are not proof of physical hardware compatibility. Complete this
checklist on at least two different x86_64 PCs, including one machine with
exactly 1 GiB RAM.

## Before testing

- Verify the ISO SHA-256 sidecar before writing it to USB.
- Use the documented `retro-usb-maker` utility on a separate Linux host.
- Record PC model, CPU, RAM, firmware mode, USB model/capacity, and ISO commit.

## Boot and persistence

- [ ] Boot from USB in legacy BIOS mode.
- [ ] Boot from USB in UEFI mode.
- [ ] Confirm the graphical login/desktop appears without a black screen.
- [ ] Select the Persistence menu entry.
- [ ] Create a harmless file under `/home/retro`, reboot, and confirm it remains.
- [ ] Boot the same USB on a second PC and confirm it reaches the desktop.

## Hardware functions

Run these commands in a terminal and save the output:

```sh
{
  date -Is
  uname -a
  cat /etc/os-release
  free -h
  zramctl
  swapon --show
  lsblk -o NAME,SIZE,TYPE,TRAN,MODEL,MOUNTPOINTS
  lspci -nnk
  lsusb
  rfkill list
  nmcli device status
  iw dev
  systemctl is-active NetworkManager bluetooth
  bluetoothctl list
  aplay -l
  wpctl status
  xrandr --query
  systemctl --failed --no-legend
} 2>&1 | tee "$HOME/retro-hardware-test.txt"
```

- [ ] Connect to Wi-Fi, browse a test page, disconnect, and reconnect.
- [ ] Pair a Bluetooth device and test reconnect after reboot.
- [ ] Play audio through speakers/headphones and verify volume controls.
- [ ] Verify display resolution, brightness (if supported), and suspend/resume.
- [ ] Copy a test file to the USB persistence area, reboot, and verify its hash.

## 1 GiB RAM acceptance measurements

After the desktop has settled for 60 seconds, record:

- `free -m` (especially `available`)
- `zramctl` (algorithm, disk size, compression ratio)
- `ps aux --sort=-%mem | head -n 15`
- whether the desktop remains responsive while opening the file manager and
  terminal

The CI 1 GiB QEMU run records MemAvailable and ZRAM details, but this physical
measurement is still required before claiming the 1 GiB target is met.

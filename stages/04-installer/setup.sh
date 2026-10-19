#!/usr/bin/env bash
set -Eeuo pipefail
[[ $EUID -eq 0 ]] || { echo "Run with sudo." >&2; exit 1; }
export DEBIAN_FRONTEND=noninteractive
apt-get update
apt-get install -y --no-install-recommends whiptail dialog parted gdisk dosfstools btrfs-progs e2fsprogs
install -d -m 0755 /usr/local/lib/retro
cat >/usr/local/lib/retro/install-to-disk.sh <<'INSTALLER'
#!/usr/bin/env bash
set -Eeuo pipefail
IFS=$'\n\t'
die(){ whiptail --title "Retro OS Installer" --msgbox "$1" 10 72; exit 1; }
command -v whiptail >/dev/null || { echo "whiptail required"; exit 1; }
[[ $EUID -eq 0 ]] || die "Run this installer as root."
mapfile -t disks < <(lsblk -dnpo NAME,SIZE,TYPE | awk '$3=="disk"{print $1" ("$2")"}')
((${#disks[@]})) || die "No disks detected."
choice=$(whiptail --title "Retro OS v2.0" --menu "Select target disk. ALL DATA ON IT WILL BE ERASED." 20 78 10 "${disks[@]}" 3>&1 1>&2 2>&3) || exit 0
disk="${choice%% (*}"
[[ -b "$disk" ]] || die "Invalid disk selection."
whiptail --title "DESTRUCTIVE OPERATION" --yesno "Erase $disk and install a fresh Btrfs layout? This cannot be undone." 10 72 || exit 0
mode=$(whiptail --title "Boot mode" --menu "Choose firmware layout" 12 60 2 UEFI "GPT with EFI System Partition" BIOS "GPT with BIOS boot partition" 3>&1 1>&2 2>&3) || exit 0
# Refuse mounted target disks and descendants.
if lsblk -nrpo MOUNTPOINT "$disk" | grep -qE '.+'; then die "Target disk or a child partition is mounted. Unmount it first."; fi
if [[ "$disk" =~ [0-9]$ ]]; then die "Select the whole disk, not a partition."; fi
parted -s "$disk" mklabel gpt
if [[ "$mode" == UEFI ]]; then
  parted -s "$disk" mkpart ESP fat32 1MiB 513MiB
  parted -s "$disk" set 1 esp on
  parted -s "$disk" mkpart retro-btrfs 513MiB 100%
  partprobe "$disk"; udevadm settle
  p1="${disk}1"; p2="${disk}2"
  [[ -b "$p1" && -b "$p2" ]] || { p1="${disk}p1"; p2="${disk}p2"; }
  mkfs.fat -F32 "$p1"
else
  parted -s "$disk" mkpart bios-grub 1MiB 3MiB
  parted -s "$disk" set 1 bios_grub on
  parted -s "$disk" mkpart retro-btrfs 3MiB 100%
  partprobe "$disk"; udevadm settle
  p2="${disk}2"; [[ -b "$p2" ]] || p2="${disk}p2"
fi
mkfs.btrfs -f -L RETRO_ROOT "$p2"
mnt=$(mktemp -d /mnt/retro-install.XXXXXX)
mount "$p2" "$mnt"
btrfs subvolume create "$mnt/@"
btrfs subvolume create "$mnt/@home"
umount "$mnt"
rmdir "$mnt"
whiptail --title "Partition layout created" --msgbox "Btrfs @ and @home subvolumes were created on $p2. This stage does not copy an OS image or install a bootloader. Run from a complete live installer with the signed rootfs payload and bootloader installer configured." 14 76
INSTALLER
chmod 0750 /usr/local/lib/retro/install-to-disk.sh
ln -sfn /usr/local/lib/retro/install-to-disk.sh /usr/local/bin/retro-installer
echo "Installer partitioning stage installed. Full rootfs deployment must be supplied by the ISO installer."

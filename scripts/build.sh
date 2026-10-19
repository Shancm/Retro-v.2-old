#!/usr/bin/env bash
set -Eeuo pipefail
IFS=$'\n\t'

ROOT="$(cd -- "$(dirname -- "${BASH_SOURCE[0]}")/.." && pwd)"
OUT="${OUT_DIR:-$ROOT/out}"
WORK="${WORK_DIR:-$ROOT/.build-work}"
SUITE="noble"
ARCH="amd64"

[[ $EUID -eq 0 ]] || { echo "Run with sudo: sudo $0" >&2; exit 1; }

echo "[*] Installing build prerequisites..."
apt-get update
apt-get install -y debootstrap squashfs-tools xorriso grub-pc-bin grub-efi-amd64-bin mtools dosfstools python3

rm -rf "$WORK" "$OUT"
mkdir -p "$WORK/iso/boot/grub" "$WORK/rootfs" "$OUT"

echo "[*] Bootstrapping Ubuntu 24.04 LTS ($SUITE)..."
debootstrap --arch="$ARCH" --include=sudo,systemd-sysv,linux-image-generic,btrfs-progs,whiptail,parted,dosfstools "$SUITE" "$WORK/rootfs" http://archive.ubuntu.com/ubuntu/

echo "[*] Enabling universe and multiverse repositories in chroot..."
cat > "$WORK/rootfs/etc/apt/sources.list" << EOF
deb http://archive.ubuntu.com/ubuntu/ $SUITE main universe restricted multiverse
deb http://archive.ubuntu.com/ubuntu/ $SUITE-updates main universe restricted multiverse
deb http://security.ubuntu.com/ubuntu/ $SUITE-security main universe restricted multiverse
EOF

echo "[*] Configuring chroot and installing packages..."
mount --bind /dev "$WORK/rootfs/dev"
mount --bind /proc "$WORK/rootfs/proc"
mount --bind /sys "$WORK/rootfs/sys"

chroot "$WORK/rootfs" /bin/bash -e << 'CHROOT_EOF'
export DEBIAN_FRONTEND=noninteractive
apt-get update
apt-get install -y --no-install-recommends zram-tools earlyoom espeak-ng nftables tor usbguard nmap aircrack-ng hydra john sqlmap netcat-openbsd tcpdump macchanger hashcat hping3

# Ensure initramfs is correctly generated for the installed kernel
kernel_version=$(ls /lib/modules | head -n1)
if [ -n "$kernel_version" ]; then
    update-initramfs -c -k "$kernel_version"
fi
CHROOT_EOF

umount "$WORK/rootfs/sys"
umount "$WORK/rootfs/proc"
umount "$WORK/rootfs/dev"

echo "[*] Injecting Retro OS configurations and modules..."
cp -r "$ROOT/config" "$WORK/rootfs/etc/retro"
mkdir -p "$WORK/rootfs/opt/retro-ai" "$WORK/rootfs/usr/local/bin"
cp "$ROOT/rootfs/opt/retro-ai/bujji.py" "$WORK/rootfs/opt/retro-ai/bujji.py" 2>/dev/null || true
cp "$ROOT/rootfs/usr/local/bin/retro" "$WORK/rootfs/usr/local/bin/retro" 2>/dev/null || true

echo "[*] Copying kernel and initrd to ISO boot directory..."
# Find kernel and initrd dynamically using pattern matching
kernel_v=$(ls "$WORK/rootfs/boot" | grep '^vmlinuz-' | head -n1)
initrd_v=$(ls "$WORK/rootfs/boot" | grep '^initrd.img-' | head -n1)

[[ -n "$kernel_v" ]] || { echo "Error: Kernel vmlinuz not found in chroot." >&2; exit 1; }
[[ -n "$initrd_v" ]] || { echo "Error: initrd.img not found in chroot." >&2; exit 1; }

cp "$WORK/rootfs/boot/$kernel_v" "$WORK/iso/boot/vmlinuz"
cp "$WORK/rootfs/boot/$initrd_v" "$WORK/iso/boot/initrd.img"

echo "[*] Configuring GRUB bootloader for UEFI + BIOS..."
cat > "$WORK/iso/boot/grub/grub.cfg" << 'EOF'
set timeout=5
set default=0

menuentry "Retro OS v2.0 Ultra-Light (Live / Install)" {
    linux /boot/vmlinuz boot=live quiet splash
    initrd /boot/initrd.img
}

menuentry "Retro OS v2.0 (Safe Mode / Recovery)" {
    linux /boot/vmlinuz boot=live nomodes

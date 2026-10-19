#!/usr/bin/env bash
set -Eeuo pipefail
IFS=$'\n\t'

ROOT="$(cd -- "$(dirname -- "${BASH_SOURCE[0]}")/.." && pwd)"
OUT="${OUT_DIR:-$ROOT/out}"
WORK="${WORK_DIR:-$ROOT/.build-work}"
SUITE="noble"
ARCH="amd64"

[[ $EUID -eq 0 ]] || { echo "Run with sudo: sudo $0" >&2; exit 1; }

echo "[*] Step 1: Installing build tools..."
apt-get update
apt-get install -y debootstrap squashfs-tools xorriso grub-pc-bin grub-efi-amd64-bin mtools dosfstools python3

rm -rf "$WORK" "$OUT"
mkdir -p "$WORK/iso/boot/grub" "$WORK/iso/casper" "$WORK/rootfs" "$OUT"

echo "[*] Step 2: Bootstrapping base Ubuntu 24.04..."
debootstrap --arch="$ARCH" --include=sudo,systemd-sysv,linux-image-generic,initramfs-tools,btrfs-progs,whiptail,parted,dosfstools "$SUITE" "$WORK/rootfs" http://archive.ubuntu.com/ubuntu/

echo "[*] Step 3: Setting apt repositories..."
cat > "$WORK/rootfs/etc/apt/sources.list" << EOF
deb http://archive.ubuntu.com/ubuntu/ $SUITE main universe restricted multiverse
deb http://archive.ubuntu.com/ubuntu/ $SUITE-updates main universe restricted multiverse
deb http://security.ubuntu.com/ubuntu/ $SUITE-security main universe restricted multiverse
EOF

echo "[*] Step 4: Configuring live environment and toolsuite..."
mount --bind /dev "$WORK/rootfs/dev"
mount --bind /proc "$WORK/rootfs/proc"
mount --bind /sys "$WORK/rootfs/sys"

chroot "$WORK/rootfs" /bin/bash -e << 'CHROOT_EOF'
export DEBIAN_FRONTEND=noninteractive
apt-get update

# Live boot + Desktop components (Labwc, Waybar, Wofi, Foot)
apt-get install -y --no-install-recommends casper overlayroot \
  labwc waybar wofi foot \
  zram-tools earlyoom espeak-ng nftables tor usbguard \
  python3 python3-psutil \
  nmap wireshark tshark aircrack-ng hydra john nikto sqlmap netcat-openbsd tcpdump macchanger hashcat dirb hping3

# Directory setup to prevent crash.init error
mkdir -p /var/crash /var/log /home/retro

# Default user setup (retro / retro)
if ! id -u retro >/dev/null 2>&1; then
    useradd -m -s /bin/bash -G sudo retro
    echo "retro:retro" | chpasswd
    echo "root:retro" | chpasswd
fi
echo "retro ALL=(ALL) NOPASSWD:ALL" > /etc/sudoers.d/retro
chmod 0440 /etc/sudoers.d/retro

# Update initramfs with casper scripts
kernel_version=$(ls /lib/modules | head -n1)
if [ -n "$kernel_version" ]; then
    update-initramfs -u -k "$kernel_version"
fi
CHROOT_EOF

echo "[*] Step 5: Executing modular stage scripts..."
for stage in "$ROOT"/stages/*/setup.sh; do
  if [ -f "$stage" ]; then
    echo "[*] Running stage: $(basename "$(dirname "$stage")")"
    bash "$stage" "$WORK/rootfs" || true
  fi
done

umount "$WORK/rootfs/sys"
umount "$WORK/rootfs/proc"
umount "$WORK/rootfs/dev"

echo "[*] Step 6: Injecting Retro OS configurations, Bujji AI, and CLI tools..."
mkdir -p "$WORK/rootfs/etc/retro" "$WORK/rootfs/opt/retro-ai" "$WORK/rootfs/usr/local/bin"
cp -r "$ROOT/config/." "$WORK/rootfs/etc/retro/" 2>/dev/null || true
cp "$ROOT/rootfs/opt/retro-ai/bujji.py" "$WORK/rootfs/opt/retro-ai/bujji.py" 2>/dev/null || true
cp "$ROOT/rootfs/usr/local/bin/retro" "$WORK/rootfs/usr/local/bin/retro" 2>/dev/null || true
chmod +x "$WORK/rootfs/opt/retro-ai/bujji.py" 2>/dev/null || true
chmod +x "$WORK/rootfs/usr/local/bin/retro" 2>/dev/null || true

echo "[*] Step 7: Preparing bootloader and kernel..."
kernel_v=$(ls "$WORK/rootfs/boot" | grep '^vmlinuz-' | head -n1)
initrd_v=$(ls "$WORK/rootfs/boot" | grep '^initrd.img-' | head -n1)

cp "$WORK/rootfs/boot/$kernel_v" "$WORK/iso/casper/vmlinuz"
cp "$WORK/rootfs/boot/$initrd_v" "$WORK/iso/casper/initrd.img"

cat > "$WORK/iso/boot/grub/grub.cfg" << 'EOF'
set timeout=5
set default=0

menuentry "Retro OS v2.0 Ultra-Light (Live Desktop)" {
    linux /casper/vmlinuz boot=casper quiet splash ---
    initrd /casper/initrd.img
}

menuentry "Retro OS v2.0 (Safe Mode / Recovery)" {
    linux /casper/vmlinuz boot=casper nomodeset ---
    initrd /casper/initrd.img
}
EOF

echo "[*] Step 8: Creating squashfs..."
mksquashfs "$WORK/rootfs" "$WORK/iso/casper/filesystem.squashfs" -comp zstd -Xcompression-level 6 -b 1024k

echo "[*] Step 9: Generating ISO image..."
grub-mkrescue -o "$OUT/retro-os-noble-amd64.iso" "$WORK/iso" -- -volid "RETRO_OS_V2"

sha256sum "$OUT/retro-os-noble-amd64.iso" > "$OUT/retro-os-noble-amd64.iso.sha256"
echo "[+] Done: $OUT/retro-os-noble-amd64.iso"

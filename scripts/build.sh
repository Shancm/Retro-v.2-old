#!/usr/bin/env bash
set -Eeuo pipefail
IFS=$'\n\t'

ROOT="$(cd -- "$(dirname -- "${BASH_SOURCE[0]}")/.." && pwd)"
OUT="${OUT_DIR:-$ROOT/out}"
WORK="${WORK_DIR:-$ROOT/.build-work}"
SUITE="noble"
ARCH="amd64"
ISO_NAME="retro-os-noble-amd64.iso"

[[ $EUID -eq 0 ]] || { echo "Run with sudo: sudo $0" >&2; exit 1; }

echo "[*] Step 1: Installing build prerequisites..."
apt-get update
apt-get install -y debootstrap squashfs-tools xorriso isolinux syslinux-common \
    grub-pc-bin grub-efi-amd64-bin mtools dosfstools python3

rm -rf "$WORK" "$OUT"
mkdir -p "$WORK/iso/boot/grub" "$WORK/iso/casper" "$WORK/iso/isolinux" "$WORK/rootfs" "$OUT"

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

mkdir -p /var/crash /var/log /etc/default /etc/apt/apt.conf.d /home/retro /home/ubuntu
touch /etc/default/apport
touch /etc/apt/apt.conf.d/50unattended-upgrades

for u in ubuntu retro; do
  if ! id -u "$u" >/dev/null 2>&1; then
    useradd -m -s /bin/bash -G sudo "$u"
    echo "$u:$u" | chpasswd
  fi
  echo "$u ALL=(ALL) NOPASSWD:ALL" > "/etc/sudoers.d/$u"
  chmod 0440 "/etc/sudoers.d/$u"
done
echo "root:retro" | chpasswd

mkdir -p /etc/systemd/system/getty@tty1.service.d/
cat > /etc/systemd/system/getty@tty1.service.d/override.conf << 'EOF_GETTY'
[Service]
ExecStart=
ExecStart=-/sbin/agetty --noissue --autologin retro %I $TERM
Type=idle
EOF_GETTY
CHROOT_EOF

echo "[*] Step 5: Executing modular stage scripts inside chroot..."
for stage in "$ROOT"/stages/*/setup.sh; do
  if [ -f "$stage" ]; then
    stage_dir="$(basename "$(dirname "$stage")")"
    echo "[*] Running stage inside chroot: $stage_dir"
    cp "$stage" "$WORK/rootfs/tmp/stage_setup.sh"
    chmod +x "$WORK/rootfs/tmp/stage_setup.sh"
    chroot "$WORK/rootfs" /bin/bash -e /tmp/stage_setup.sh / || true
    rm -f "$WORK/rootfs/tmp/stage_setup.sh"
  fi
done

echo "[*] Updating initramfs with live boot scripts..."
chroot "$WORK/rootfs" /bin/bash -e << 'CHROOT_KNL'
export DEBIAN_FRONTEND=noninteractive
latest_kernel=$(ls /lib/modules | sort -V | tail -n1)
if [ -n "$latest_kernel" ]; then
    update-initramfs -u -k "$latest_kernel" || update-initramfs -c -k "$latest_kernel"
fi
CHROOT_KNL

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

echo "[*] Step 7: Preparing kernel and bootloaders..."
kernel_v=$(ls "$WORK/rootfs/boot" | grep '^vmlinuz-' | sort -V | tail -n1)
initrd_v=$(ls "$WORK/rootfs/boot" | grep '^initrd.img-' | sort -V | tail -n1)

cp "$WORK/rootfs/boot/$kernel_v" "$WORK/iso/casper/vmlinuz"
cp "$WORK/rootfs/boot/$initrd_v" "$WORK/iso/casper/initrd.img"

# 1. ISOLINUX (Legacy BIOS മദർബോർഡുകൾക്ക് വേണ്ടി)
cp /usr/lib/ISOLINUX/isolinux.bin "$WORK/iso/isolinux/"
cp /usr/lib/syslinux/modules/bios/*.c32 "$WORK/iso/isolinux/" 2>/dev/null || true

cat > "$WORK/iso/isolinux/isolinux.cfg" << 'EOF'
UI vesamenu.c32
PROMPT 0
TIMEOUT 50
DEFAULT live

MENU TITLE Retro OS v2.0 (Legacy BIOS)

LABEL live
  MENU LABEL Boot Retro OS v2.0 Ultra-Light
  KERNEL /casper/vmlinuz
  APPEND initrd=/casper/initrd.img boot=casper quiet splash ---

LABEL debug
  MENU LABEL Boot Retro OS v2.0 (Verbose Debug)
  KERNEL /casper/vmlinuz
  APPEND initrd=/casper/initrd.img boot=casper nomodeset ---
EOF

# 2. GRUB (UEFI ബൂട്ടിംഗിന് വേണ്ടി)
cat > "$WORK/iso/boot/grub/grub.cfg" << 'EOF'
set timeout=5
set default=0

menuentry "Retro OS v2.0 Ultra-Light (Live)" {
    linux /casper/vmlinuz boot=casper quiet splash ---
    initrd /casper/initrd.img
}

menuentry "Retro OS v2.0 (Verbose Debug Mode)" {
    linux /casper/vmlinuz boot=casper nomodeset ---
    initrd /casper/initrd.img
}
EOF

# EFI ബൂട്ട് ഇമേജ് നിർമ്മിക്കുന്നു
grub-mkstandalone \
   --format=x86_64-efi \
   --output="$WORK/iso/boot/grub/bootx64.efi" \
   --locales="" \
   --fonts="" \
   "boot/grub/grub.cfg=$WORK/iso/boot/grub/grub.cfg"

(cd "$WORK/iso" && \
   dd if=/dev/zero of=boot/grub/efi.img bs=1M count=4 && \
   mkfs.vfat boot/grub/efi.img && \
   mmd -i boot/grub/efi.img ::/EFI ::/EFI/BOOT && \
   mcopy -i boot/grub/efi.img boot/grub/bootx64.efi ::/EFI/BOOT/BOOTX64.EFI)

echo "[*] Step 8: Creating squashfs..."
mksquashfs "$WORK/rootfs" "$WORK/iso/casper/filesystem.squashfs" -comp zstd -Xcompression-level 6 -b 1024k

echo "[*] Step 9: Creating Real Hybrid ISO via xorriso..."
xorriso -as mkisofs \
   -iso-level 3 \
   -full-iso9660-filenames \
   -volid "RETRO_OS_V2" \
   -eltorito-boot isolinux/isolinux.bin \
   -eltorito-catalog isolinux/boot.cat \
   -no-emul-boot -boot-load-size 4 -boot-info-table \
   -isohybrid-mbr /usr/lib/ISOLINUX/isohdpfx.bin \
   -eltorito-alt-boot \
   -e boot/grub/efi.img \
   -no-emul-boot -isohybrid-gpt-basdat \
   -output "$OUT/$ISO_NAME" \
   "$WORK/iso"

sha256sum "$OUT/$ISO_NAME" > "$OUT/$ISO_NAME.sha256"
echo "[+] SUCCESS: True Hybrid ISO generated at: $OUT/$ISO_NAME"

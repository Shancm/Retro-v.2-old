#!/usr/bin/env bash
# =============================================================================
# Retro OS - Hybrid Legacy BIOS & UEFI Engine (Based on Proven Retro-Lite Tech)
# =============================================================================
set -Eeuo pipefail
IFS=$'\n\t'

ROOT="$(cd -- "$(dirname -- "${BASH_SOURCE[0]}")/.." && pwd)"
OUT="${OUT_DIR:-$ROOT/out}"
WORK="${WORK_DIR:-$ROOT/.build-work}"
SUITE="noble"
ARCH="amd64"
ISO_NAME="retro-os-noble-amd64.iso"

[[ $EUID -eq 0 ]] || { echo "Run with sudo: sudo $0" >&2; exit 1; }

echo "[*] Step 1: Installing host dependencies for True Hybrid MBR generation..."
export DEBIAN_FRONTEND=noninteractive
apt-get update
apt-get install -y debootstrap squashfs-tools xorriso isolinux syslinux-common \
    syslinux-utils grub-pc-bin grub-efi-amd64-bin mtools dosfstools python3

rm -rf "$WORK" "$OUT"
mkdir -p "$WORK/iso/casper" "$WORK/iso/isolinux" "$WORK/iso/boot/grub" "$WORK/rootfs" "$OUT"

echo "[*] Step 2: Bootstrapping base Ubuntu 24.04..."
debootstrap --arch="$ARCH" --include=sudo,systemd-sysv,linux-image-generic,initramfs-tools,btrfs-progs,whiptail,parted,dosfstools "$SUITE" "$WORK/rootfs" http://archive.ubuntu.com/ubuntu/

echo "[*] Step 3: Configuring repositories..."
cat > "$WORK/rootfs/etc/apt/sources.list" << EOF
deb http://archive.ubuntu.com/ubuntu/ $SUITE main universe restricted multiverse
deb http://archive.ubuntu.com/ubuntu/ $SUITE-updates main universe restricted multiverse
deb http://security.ubuntu.com/ubuntu/ $SUITE-security main universe restricted multiverse
EOF

echo "[*] Step 4: Configuring live environment, Openbox desktop, and security stack..."
mount --bind /dev "$WORK/rootfs/dev"
mount --bind /proc "$WORK/rootfs/proc"
mount --bind /sys "$WORK/rootfs/sys"

chroot "$WORK/rootfs" /bin/bash -e << 'CHROOT_EOF'
export DEBIAN_FRONTEND=noninteractive
apt-get update

# Proven Lightweight Stack (~180MB RAM)
apt-get install -y --no-install-recommends \
  casper overlayroot \
  xorg openbox tint2 pcmanfm feh picom \
  lightdm lightdm-gtk-greeter \
  zram-tools earlyoom espeak-ng nftables tor usbguard \
  python3 python3-psutil \
  nmap wireshark tshark aircrack-ng hydra john nikto sqlmap netcat-openbsd tcpdump macchanger hashcat dirb hping3

# Directory setup
mkdir -p /var/crash /var/log /etc/default /etc/apt/apt.conf.d
touch /etc/default/apport
touch /etc/apt/apt.conf.d/50unattended-upgrades

# User & Sudo setup
for u in ubuntu retro; do
  if ! id -u "$u" >/dev/null 2>&1; then
    useradd -m -s /bin/bash -G sudo "$u"
    echo "$u:$u" | chpasswd
  fi
  echo "$u ALL=(ALL) NOPASSWD:ALL" > "/etc/sudoers.d/$u"
  chmod 0440 "/etc/sudoers.d/$u"
done
echo "root:retro" | chpasswd

# LightDM Autologin Bypass (From Retro-Lite Tech)
mkdir -p /etc/lightdm/lightdm.conf.d /etc/pam.d
cat << 'AUTOCONF' > /etc/lightdm/lightdm.conf.d/01_retro_autologin.conf
[Seat:*]
autologin-user=retro
autologin-user-timeout=0
user-session=openbox
pam-service=lightdm-autologin
pam-autologin-service=lightdm-autologin
AUTOCONF

cat << 'PAMEOF' > /etc/pam.d/lightdm-autologin
#%PAM-1.0
auth      sufficient pam_permit.so
account   sufficient pam_permit.so
password  sufficient pam_permit.so
session   sufficient pam_permit.so
PAMEOF

# Openbox Desktop Autostart & Wallpapers
mkdir -p /etc/skel/.config/openbox /etc/skel/.config/pcmanfm/default /etc/skel/.config/tint2 /usr/share/backgrounds/retro-os
cat << 'AUTOSTART' > /etc/skel/.config/openbox/autostart
picom -b &
tint2 &
pcmanfm --desktop &
AUTOSTART

cat << 'DESKCONF' > /etc/skel/.config/pcmanfm/default/desktop-items-0.conf
[*]
wallpaper_mode=fit
desktop_bg=#0D0F12
desktop_fg=#E0E0E0
show_trash=1
show_mounts=1
DESKCONF

cp -rT /etc/skel /home/retro/ 2>/dev/null || true
chown -R retro:retro /home/retro 2>/dev/null || true

# Initramfs update with live scripts
latest_kernel=$(ls /lib/modules | sort -V | tail -n1)
if [ -n "$latest_kernel" ]; then
    update-initramfs -u -k "$latest_kernel" || update-initramfs -c -k "$latest_kernel"
fi
CHROOT_EOF

echo "[*] Step 5: Executing modular stages..."
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

umount "$WORK/rootfs/sys"
umount "$WORK/rootfs/proc"
umount "$WORK/rootfs/dev"

echo "[*] Step 6: Injecting Bujji AI and Retro CLI..."
mkdir -p "$WORK/rootfs/etc/retro" "$WORK/rootfs/opt/retro-ai" "$WORK/rootfs/usr/local/bin"
cp -r "$ROOT/config/." "$WORK/rootfs/etc/retro/" 2>/dev/null || true
cp "$ROOT/rootfs/opt/retro-ai/bujji.py" "$WORK/rootfs/opt/retro-ai/bujji.py" 2>/dev/null || true
cp "$ROOT/rootfs/usr/local/bin/retro" "$WORK/rootfs/usr/local/bin/retro" 2>/dev/null || true
chmod +x "$WORK/rootfs/opt/retro-ai/bujji.py" 2>/dev/null || true
chmod +x "$WORK/rootfs/usr/local/bin/retro" 2>/dev/null || true

echo "[*] Step 7: Preparing ISOLINUX Bootloader & Live Kernel..."
kernel_v=$(ls "$WORK/rootfs/boot" | grep '^vmlinuz-' | sort -V | tail -n1)
initrd_v=$(ls "$WORK/rootfs/boot" | grep '^initrd.img-' | sort -V | tail -n1)

cp "$WORK/rootfs/boot/$kernel_v" "$WORK/iso/casper/vmlinuz"
cp "$WORK/rootfs/boot/$initrd_v" "$WORK/iso/casper/initrd.img"

# ISOLINUX setup (Legacy BIOS MBR)
cp -f /usr/lib/ISOLINUX/isolinux.bin "$WORK/iso/isolinux/"
cp -f /usr/lib/syslinux/modules/bios/* "$WORK/iso/isolinux/" 2>/dev/null || true
touch "$WORK/iso/isolinux/bootlogo"

cat > "$WORK/iso/isolinux/isolinux.cfg" << 'EOF'
UI vesamenu.c32
PROMPT 0
TIMEOUT 80

MENU TITLE Retro OS v2.0 (Legacy BIOS)

LABEL live
  MENU LABEL Boot Retro OS v2.0 (Lightweight Live)
  MENU DEFAULT
  KERNEL /casper/vmlinuz
  APPEND initrd=/casper/initrd.img boot=casper quiet splash nowatchdog udev.children_max=1 ---

LABEL failsafe
  MENU LABEL Boot Retro OS v2.0 (Safe Graphics / Recovery)
  KERNEL /casper/vmlinuz
  APPEND initrd=/casper/initrd.img boot=casper nomodeset noapic noapm nodma ---
EOF

# UEFI (GRUB) fallback setup
cat > "$WORK/iso/boot/grub/grub.cfg" << 'EOF'
set timeout=5
set default=0

menuentry "Retro OS v2.0 (Live)" {
    linux /casper/vmlinuz boot=casper quiet splash nowatchdog udev.children_max=1 ---
    initrd /casper/initrd.img
}

menuentry "Retro OS v2.0 (Recovery)" {
    linux /casper/vmlinuz boot=casper nomodeset ---
    initrd /casper/initrd.img
}
EOF

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

echo "[*] Step 8: Creating SquashFS..."
mksquashfs "$WORK/rootfs" "$WORK/iso/casper/filesystem.squashfs" -comp zstd -Xcompression-level 6 -b 1024k

echo "[*] Step 9: Creating Hybrid ISO with MBR Partition Table..."
xorriso -as mkisofs \
   -iso-level 3 \
   -full-iso9660-filenames \
   -volid "RETRO_OS" \
   -eltorito-boot isolinux/isolinux.bin \
   -eltorito-catalog isolinux/boot.cat \
   -no-emul-boot -boot-load-size 4 -boot-info-table \
   -isohybrid-mbr /usr/lib/ISOLINUX/isohdpfx.bin \
   -eltorito-alt-boot \
   -e boot/grub/efi.img \
   -no-emul-boot -isohybrid-gpt-basdat \
   -output "$OUT/$ISO_NAME" \
   "$WORK/iso"

# Applying isohybrid injection for legacy compatibility
isohybrid "$OUT/$ISO_NAME" 2>/dev/null || true
sha256sum "$OUT/$ISO_NAME" > "$OUT/$ISO_NAME.sha256"

echo "[+] SUCCESS: Production Hybrid ISO generated at: $OUT/$ISO_NAME"

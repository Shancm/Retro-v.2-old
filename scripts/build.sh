#!/usr/bin/env bash
set -Eeuo pipefail
IFS=$'\n\t'
ROOT="$(cd -- "$(dirname -- "${BASH_SOURCE[0]}")/.." && pwd)"
OUT="${OUT_DIR:-$ROOT/out}"
WORK="${WORK_DIR:-$ROOT/.build-work}"
SUITE="noble"
ARCH="amd64"
[[ $EUID -eq 0 ]] || { echo "Run with sudo: sudo $0" >&2; exit 1; }
command -v lb >/dev/null || { echo "Install live-build, debootstrap, xorriso, squashfs-tools first." >&2; exit 1; }
"$ROOT/scripts/verify.sh"
apt-get update
apt-get install -y live-build debootstrap xorriso squashfs-tools grub-pc-bin grub-efi-amd64-bin grub-efi-amd64-signed shim-signed
rm -rf "$WORK"
mkdir -p "$WORK" "$OUT"
cd "$WORK"
lb config \
  --mode ubuntu \
  --distribution "$SUITE" \
  --architectures "$ARCH" \
  --binary-images iso-hybrid \
  --bootappend-live "boot=live components quiet splash" \
  --apt-recommends false \
  --apt-indices false \
  --archive-areas "main universe restricted multiverse"
mkdir -p config/package-lists config/includes.chroot/etc/retro \
  config/includes.chroot/opt/retro-ai config/includes.chroot/usr/local/bin \
  config/hooks/normal
cp "$ROOT/config/retro.conf" config/includes.chroot/etc/retro/retro.conf
cp "$ROOT/rootfs/opt/retro-ai/bujji.py" config/includes.chroot/opt/retro-ai/bujji.py
cp "$ROOT/rootfs/usr/local/bin/retro" config/includes.chroot/usr/local/bin/retro
chmod 0755 config/includes.chroot/opt/retro-ai/bujji.py config/includes.chroot/usr/local/bin/retro
cat >config/package-lists/retro.list.chroot <<'EOF'
systemd-sysv
linux-image-amd64
sudo
btrfs-progs
snapper
zram-tools
earlyoom
labwc
waybar
wofi
foot
yazi
nmap
wireshark
tshark
aircrack-ng
hydra
john
nikto
sqlmap
netcat-openbsd
tcpdump
macchanger
hashcat
dirb
hping3
tor
usbguard
nftables
python3
python3-psutil
espeak-ng
whiptail
parted
dosfstools
EOF
# Apply staged setup scripts inside the chroot after packages are installed.
for stage in "$ROOT"/stages/*/setup.sh; do
  name="$(basename "$(dirname "$stage")")"
  install -D -m 0755 "$stage" "config/hooks/normal/0900-${name}.hook.chroot"
  # Hooks need the central config path inside the chroot.
  # The hooks are not run as host scripts; live-build invokes them inside chroot.
done
lb build
iso="$(find "$WORK" -maxdepth 1 -type f -name '*.iso' -print -quit)"
[[ -n "$iso" && -s "$iso" ]] || { echo "live-build did not produce an ISO." >&2; exit 1; }
# live-build iso-hybrid should already create a hybrid image. Do not blindly overwrite
# its MBR: inspect El Torito metadata and retain the generated boot structures.
xorriso -indev "$iso" -report_el_torito plain
cp --reflink=auto "$iso" "$OUT/retro-os-${SUITE}-${ARCH}.iso"
sha256sum "$OUT/retro-os-${SUITE}-${ARCH}.iso" > "$OUT/retro-os-${SUITE}-${ARCH}.iso.sha256"
echo "ISO: $OUT/retro-os-${SUITE}-${ARCH}.iso"
echo "Verify BIOS/UEFI boot in virtual machines and on physical test hardware before release."

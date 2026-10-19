#!/usr/bin/env bash
set -Eeuo pipefail
IFS=$'\n\t'
SCRIPT_DIR="$(cd -- "$(dirname -- "${BASH_SOURCE[0]}")" && pwd)"
ROOT="$(cd -- "$SCRIPT_DIR/../.." && pwd)"
# shellcheck source=../../config/retro.conf
source "$ROOT/config/retro.conf"

[[ $EUID -eq 0 ]] || { echo "Run with sudo." >&2; exit 1; }
export DEBIAN_FRONTEND=noninteractive
apt-get update
apt-get install -y --no-install-recommends \
  linux-generic btrfs-progs snapper zram-tools earlyoom systemd-oomd \
  nftables ca-certificates curl jq util-linux

# Remove desktop software managers only when present; never remove dependencies blindly.
for pkg in snapd packagekit packagekit-tools; do
  if dpkg-query -W -f='${Status}' "$pkg" 2>/dev/null | grep -q 'install ok installed'; then
    apt-get purge -y "$pkg"
  fi
done
apt-get autoremove -y --purge

install -d -m 0755 /etc/sysctl.d /etc/systemd/system.conf.d /etc/retro
cat >/etc/sysctl.d/90-retro.conf <<'EOF'
vm.swappiness=100
vm.vfs_cache_pressure=150
vm.dirty_background_ratio=5
vm.dirty_ratio=10
kernel.kptr_restrict=2
kernel.dmesg_restrict=1
kernel.unprivileged_bpf_disabled=1
net.ipv4.conf.all.rp_filter=1
net.ipv4.conf.default.rp_filter=1
net.ipv4.tcp_syncookies=1
net.ipv4.conf.all.accept_redirects=0
net.ipv6.conf.all.accept_redirects=0
net.ipv4.conf.all.send_redirects=0
EOF
sysctl --system

# zram-tools uses /etc/default/zramswap on Ubuntu.
cat >/etc/default/zramswap <<EOF
ALGO=${RETRO_ZRAM_ALGORITHM}
PERCENT=${RETRO_ZRAM_PERCENT}
PRIORITY=${RETRO_ZRAM_PRIORITY}
EOF
systemctl enable --now zramswap.service 2>/dev/null || true

# EarlyOOM is a conservative last-resort OOM response, not a substitute for testing.
if [[ -f /etc/default/earlyoom ]]; then
  sed -i 's/^EARLYOOM_ARGS=.*/EARLYOOM_ARGS="-m 5 -s 10 --avoid \x27(^|\\/)(sshd|systemd|login|retro)($|\\/)\x27"/' /etc/default/earlyoom
fi
systemctl enable --now earlyoom.service

# Snapper config creation is safe on an existing Btrfs root only.
if findmnt -n -o FSTYPE / | grep -qx btrfs; then
  if ! snapper list-configs 2>/dev/null | awk 'NR>2 {print $1}' | grep -qx root; then
    snapper -c root create-config /
  fi
  systemctl enable --now snapper-timeline.timer snapper-cleanup.timer
else
  echo "NOTICE: root is not Btrfs. Snapper config was not created; use the Retro installer for a fresh Btrfs layout." >&2
fi

# Hardening drop-in: retain systemd defaults while reducing attack surface.
cat >/etc/systemd/system.conf.d/90-retro-hardening.conf <<'EOF'
[Manager]
DefaultTimeoutStartSec=90s
DefaultTimeoutStopSec=30s
DumpCore=no
CrashShell=no
EOF
systemctl daemon-reexec

install -d -m 0755 "$RETRO_LOG_DIR" "$RETRO_STATE_DIR"
chmod 0750 "$RETRO_LOG_DIR" "$RETRO_STATE_DIR"
echo "Retro engine stage completed. Reboot recommended."

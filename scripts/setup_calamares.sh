#!/usr/bin/env bash
# =============================================================================
# Retro OS v2.0 — setup_calamares.sh
# Runs INSIDE the debootstrap chroot as root. Installs and configures
# Calamares so the live ISO can also install Retro OS to disk
# (GRUB on UEFI targets, extlinux/grub-pc fallback on legacy BIOS targets;
# Btrfs + Snapper only when the user picks Btrfs in the partitioner).
# =============================================================================
set -Eeuo pipefail

SELF_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
# shellcheck source=/dev/null
source "${SELF_DIR}/config.env"

trap 'retro_error "setup_calamares.sh failed at line ${LINENO} (exit ${?})"' ERR

export DEBIAN_FRONTEND=noninteractive

retro_info "[calamares] Installing Calamares + dependencies"
apt-get install -y --no-install-recommends \
    calamares \
    calamares-settings-debian \
    grub-pc \
    grub-efi-amd64 \
    grub-efi-amd64-signed \
    shim-signed \
    os-prober \
    btrfs-progs \
    snapper \
    squashfs-tools \
    python3-yaml \
    qml-module-qtquick2 \
    qml-module-qtquick-controls \
    qml-module-qtquick-layouts

install -d -m 755 /etc/calamares/branding/retro-os
install -d -m 755 /etc/calamares/modules

cat > /etc/calamares/branding/retro-os/branding.desc <<EOF
---
componentName: retro-os

welcomeStyleCalamares: true
windowExpanding: normal
windowSize: 800px,520px

strings:
    productName:         "${RETRO_OS_NAME}"
    shortProductName:    "${RETRO_OS_CODENAME}"
    version:              "${RETRO_OS_VERSION}"
    shortVersion:         "${RETRO_OS_VERSION}"
    versionedName:        "${RETRO_OS_NAME} ${RETRO_OS_VERSION} ${RETRO_OS_EDITION}"
    shortVersionedName:   "${RETRO_OS_CODENAME}-${RETRO_OS_VERSION}"
    bootloaderEntryName:  "${RETRO_OS_NAME}"
    productUrl:           "https://example.invalid/retro-os"
    supportUrl:           "https://example.invalid/retro-os/support"

images:
    productLogo:        "logo.png"
    productIcon:         "logo.png"
    productWelcome:      "welcome.png"

slideshow: "show.qml"

style:
   sidebarBackground:    "${RETRO_BG_COLOR}"
   sidebarText:          "${RETRO_FG_COLOR}"
   sidebarTextSelect:    "${RETRO_ACCENT_COLOR}"
   sidebarTextHighlight: "${RETRO_ACCENT_COLOR}"
EOF

cat > /etc/calamares/settings.conf <<'EOF'
---
modules-search: [ local ]

instances: []

sequence:
  - show:
      - welcome
      - locale
      - keyboard
      - partition
      - users
      - summary
  - exec:
      - partition
      - mount
      - unpackfs
      - machineid
      - fstab
      - locale
      - keyboard
      - localecfg
      - luksbootkeyfile
      - users
      - displaymanager
      - networkcfg
      - hwclock
      - services-systemd
      - bootloader
      - grubcfg
      - umount
  - show:
      - finished

branding: retro-os
prompt-install: true
dont-chroot: false
oem-setup: false
disable-cancel: false
disable-cancel-during-exec: true
quit-at-end: false
EOF

cat > /etc/calamares/modules/partition.conf <<EOF
---
efiSystemPartition: "/boot/efi"
userSwapChoices:
    - none
    - small
    - suspend
    - file
drawNestedPartitions: true
alwaysShowPartitionLabels: true
allowManualPartitioning: true
initialPartitioningChoice: erase
initialSwapChoice: small
defaultFileSystemType: "btrfs"
availableFileSystemTypes: ["btrfs", "ext4", "xfs"]
enableLuksAutomatedPartitioning: true
EOF

cat > /etc/calamares/modules/unpackfs.conf <<'EOF'
---
unpack:
    - source: "/run/live/medium/live/filesystem.squashfs"
      sourcefs: "squashfs"
      destination: ""
EOF

cat > /etc/calamares/modules/users.conf <<EOF
---
defaultGroups:
    - sudo
    - adm
    - audio
    - video
    - plugdev
    - netdev
    - wireshark
autologinGroup: autologin
doAutologin: false
sudoersGroup: sudo
setRootPassword: true
doReusePassword: false
passwordRequirements:
    minLength: 1
    maxLength: -1
EOF

cat > /etc/calamares/modules/bootloader.conf <<'EOF'
---
efiBootLoader: "grub"
kernel: "/vmlinuz"
img: "/initrd.img"
grubInstall: "grub-install"
grubMkconfig: "grub-mkconfig"
grubCfg: "/boot/grub/grub.cfg"
grubProbe: "grub-probe"
efiBootMgr: "efibootmgr"
installEFIFallback: true
timeout: "5"
EOF

cat > /etc/calamares/modules/services-systemd.conf <<'EOF'
---
services:
    - name: "NetworkManager"
      mandatory: true
    - name: "lightdm"
      mandatory: true
    - name: "zramswap"
      mandatory: false
    - name: "earlyoom"
      mandatory: false
    - name: "bujji-watchdog"
      mandatory: false
disable:
    - name: "ssh"
      mandatory: false
EOF

# Btrfs + Snapper only on installed (non-live) systems, enabled post-install
# via a systemd oneshot that Calamares' services-systemd triggers on first boot
cat > /usr/local/bin/retro-snapper-firstboot <<'EOF'
#!/usr/bin/env bash
set -Eeuo pipefail
if findmnt -n -o FSTYPE / 2>/dev/null | grep -q '^btrfs$'; then
    snapper -c root create-config / 2>/dev/null || true
    systemctl enable --now snapper-timeline.timer snapper-cleanup.timer 2>/dev/null || true
fi
EOF
chmod 755 /usr/local/bin/retro-snapper-firstboot

cat > /etc/systemd/system/retro-snapper-firstboot.service <<'EOF'
[Unit]
Description=Retro OS: configure Snapper if root is on Btrfs (installed systems only)
ConditionPathExists=!/var/lib/retro-os/.snapper-configured
After=local-fs.target

[Service]
Type=oneshot
ExecStart=/usr/local/bin/retro-snapper-firstboot
ExecStartPost=/bin/touch /var/lib/retro-os/.snapper-configured

[Install]
WantedBy=multi-user.target
EOF
systemctl enable retro-snapper-firstboot.service

retro_info "[calamares] Calamares installer configured"

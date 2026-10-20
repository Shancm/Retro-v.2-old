#!/usr/bin/env bash
# =============================================================================
# Retro OS v2.0 — 01_engine_setup.sh
# Runs INSIDE the debootstrap chroot as root.
# Installs the live-boot engine, kernel, base packages, and the default user.
#
# RULES (chroot context):
#   - never call sudo
#   - never `systemctl start` / `--now` — `enable` only
# =============================================================================
set -Eeuo pipefail

# Sourcing config.env safely
if [ -f "/tmp/retro-build/config.env" ]; then
    source "/tmp/retro-build/config.env"
elif [ -f "./config.env" ]; then
    source "./config.env"
fi

trap 'retro_error "01_engine_setup.sh failed at line ${LINENO} (exit ${?})"' ERR

export DEBIAN_FRONTEND=noninteractive
export LC_ALL=C.UTF-8

retro_info "[01] Configuring apt sources (${DEBIAN_SUITE}: ${DEBIAN_COMPONENTS})"

cat > /etc/apt/sources.list <<EOF
deb ${DEBIAN_MIRROR} ${DEBIAN_SUITE} ${DEBIAN_COMPONENTS}
deb-src ${DEBIAN_MIRROR} ${DEBIAN_SUITE} ${DEBIAN_COMPONENTS}

deb ${DEBIAN_MIRROR} ${DEBIAN_SUITE}-updates ${DEBIAN_COMPONENTS}
deb-src ${DEBIAN_MIRROR} ${DEBIAN_SUITE}-updates ${DEBIAN_COMPONENTS}

deb ${DEBIAN_SECURITY_MIRROR} ${DEBIAN_SUITE}-security ${DEBIAN_COMPONENTS}
deb-src ${DEBIAN_SECURITY_MIRROR} ${DEBIAN_SUITE}-security ${DEBIAN_COMPONENTS}
EOF

cat > /etc/apt/apt.conf.d/99retro-no-recommends <<'EOF'
APT::Install-Recommends "0";
APT::Install-Suggests "0";
Acquire::Languages "none";
EOF

echo "${RETRO_OS_CODENAME}" > /etc/hostname
cat > /etc/hosts <<EOF
127.0.0.1   localhost
127.0.1.1   ${RETRO_OS_CODENAME}
::1         localhost ip6-localhost ip6-localhost
EOF

retro_info "[01] apt-get update"
apt-get update -qq

retro_info "[01] Installing kernel + firmware"
apt-get install -y --no-install-recommends \
    linux-image-amd64 \
    firmware-linux-free \
    firmware-misc-nonfree \
    firmware-realtek \
    firmware-atheros \
    firmware-iwlwifi \
    firmware-amd-graphics \
    intel-microcode \
    amd64-microcode

retro_info "[01] Installing live-boot engine (pure Debian Live, no Casper)"
apt-get install -y --no-install-recommends \
    live-boot \
    live-boot-initramfs-tools \
    live-config \
    live-config-systemd \
    systemd-sysv \
    systemd-timesyncd \
    initramfs-tools \
    dbus \
    sudo \
    network-manager \
    wireless-tools \
    wpasupplicant \
    openssh-client \
    ca-certificates \
    curl \
    wget \
    git \
    nano \
    vim-tiny \
    less \
    bash-completion \
    locales \
    console-setup \
    keyboard-configuration \
    parted \
    gdisk \
    dosfstools \
    e2fsprogs \
    btrfs-progs \
    squashfs-tools \
    zstd \
    xz-utils \
    pciutils \
    usbutils \
    lshw \
    util-linux

retro_info "[01] Generating locale (en_US.UTF-8)"
sed -i 's/^# *en_US.UTF-8 UTF-8/en_US.UTF-8 UTF-8/' /etc/locale.gen
locale-gen >/dev/null
echo 'LANG=en_US.UTF-8' > /etc/default/locale

retro_info "[01] Creating default user '${RETRO_USER}' (UID ${RETRO_USER_UID})"
if ! id "${RETRO_USER}" >/dev/null 2>&1; then
    useradd -m -u "${RETRO_USER_UID}" -s /bin/bash \
        -G sudo,adm,cdrom,dialout,audio,video,plugdev,netdev,bluetooth \
        "${RETRO_USER}"
fi

echo "${RETRO_USER}:${RETRO_USER_PASS}" | chpasswd
echo "root:${RETRO_ROOT_PASS}" | chpasswd

retro_info "[01] Enabling passwordless sudo for '${RETRO_USER}'"
install -d -m 750 /etc/sudoers.d
cat > "/etc/sudoers.d/010_${RETRO_USER}-nopasswd" <<EOF
${RETRO_USER} ALL=(ALL) NOPASSWD: ALL
EOF
chmod 440 "/etc/sudoers.d/010_${RETRO_USER}-nopasswd"
visudo -cf "/etc/sudoers.d/010_${RETRO_USER}-nopasswd"

retro_info "[01] Unlocking shadow entries (live-image accounts, non-expiring)"
# Live ISO accounts: unlock password aging/locking so first-boot never
# forces a password reset or locks the account out. Does not disable
# PAM auth modules, which live under /etc/pam.d (handled in 02 for the
# display-manager autologin case only).
for acct in root "${RETRO_USER}"; do
    chage -I -1 -m 0 -M 99999 -E -1 "${acct}" || true
    passwd -u "${acct}" >/dev/null 2>&1 || true
done

retro_info "[01] Creating Retro OS filesystem layout"
install -d -m 755 "${RETRO_ROOT}" "${RETRO_AI_DIR}" "${RETRO_ETC_DIR}" \
    "${RETRO_LOG_DIR}" "${RETRO_STATE_DIR}" "${RETRO_BIN_DIR}"

cat > "${RETRO_ETC_DIR}/release" <<EOF
RETRO_OS_NAME="${RETRO_OS_NAME}"
RETRO_OS_VERSION="${RETRO_OS_VERSION}"
RETRO_OS_EDITION="${RETRO_OS_EDITION}"
RETRO_OS_CODENAME="${RETRO_OS_CODENAME}"
DEBIAN_SUITE="${DEBIAN_SUITE}"
BUILD_DATE="$(date -u '+%Y-%m-%dT%H:%M:%SZ')"
EOF

retro_info "[01] Copying project config.env into the live image (for retro CLI)"
install -m 644 "${SELF_DIR}/config.env" "${RETRO_ETC_DIR}/config.env"

retro_info "[01] Base engine setup complete"

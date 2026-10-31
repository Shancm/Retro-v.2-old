#!/usr/bin/env bash
# =============================================================================
# Retro OS v2.0 - 01_engine_setup.sh   (runs as root INSIDE the build chroot)
#
#   * apt sources / policy / slimming
#   * base system, kernel, microcode, firmware, live-boot + live-config
#   * user "retro" (UID 1000), groups, sudo, unlocked shadow entry
#   * adaptive hardware profile engine: ZRAM, sysctl, EarlyOOM, Picom switch
#   * journald / service trimming, release metadata
# =============================================================================
set -Eeuo pipefail

SELF_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
# shellcheck source=/dev/null
source "${SELF_DIR}/config.env"
retro_enable_traps "01_engine_setup.sh"
retro_require_chroot

export DEBIAN_FRONTEND=noninteractive LC_ALL=C LANG=C

# -----------------------------------------------------------------------------
# 1. Keep postinst scripts from starting daemons inside the chroot
#    (removed again by 98_finalize.sh)
# -----------------------------------------------------------------------------
install_policy_rc() {
    retro_info "Installing policy-rc.d (no service starts inside the chroot)"
    retro_write /usr/sbin/policy-rc.d 0755 <<'EOF'
#!/bin/sh
exit 101
EOF
}

# -----------------------------------------------------------------------------
# 2. apt configuration
# -----------------------------------------------------------------------------
configure_apt() {
    retro_info "Writing apt sources for ${DEBIAN_SUITE}"
    local mirror="${DEBIAN_MIRROR%/}/"
    retro_write /etc/apt/sources.list 0644 <<EOF
deb ${mirror} ${DEBIAN_SUITE} ${DEBIAN_COMPONENTS}
deb ${mirror} ${DEBIAN_SUITE}-updates ${DEBIAN_COMPONENTS}
deb ${DEBIAN_SECURITY_MIRROR} ${DEBIAN_SUITE}-security ${DEBIAN_COMPONENTS}
EOF

    retro_write /etc/apt/apt.conf.d/90-retro-os 0644 <<'EOF'
APT::Install-Recommends "false";
APT::Install-Suggests "false";
Acquire::Languages "none";
Acquire::Retries "5";
Dpkg::Use-Pty "0";
APT::Get::Show-Upgraded "false";
EOF

    if [[ "${RETRO_SLIM_DPKG}" == "1" ]]; then
        retro_info "Enabling dpkg slimming (docs / non-English locales)"
        retro_write /etc/dpkg/dpkg.cfg.d/01-retro-slim 0644 <<'EOF'
path-exclude=/usr/share/doc/*
path-include=/usr/share/doc/*/copyright
path-exclude=/usr/share/info/*
path-exclude=/usr/share/locale/*
path-include=/usr/share/locale/en*/*
path-include=/usr/share/locale/locale.alias
EOF
    fi
}

# -----------------------------------------------------------------------------
# 3. Base system
# -----------------------------------------------------------------------------
install_base_system() {
    retro_info "Refreshing package lists and upgrading the minbase system"
    retro_retry 3 5 apt-get update
    retro_apt full-upgrade

    retro_info "Installing base system packages"
    retro_apt_install \
        systemd systemd-sysv udev dbus dbus-user-session libpam-systemd \
        sudo locales tzdata console-setup keyboard-configuration kmod \
        ca-certificates gnupg curl wget git make \
        procps psmisc lsof file less nano bash-completion man-db \
        htop btop \
        iproute2 iputils-ping iw rfkill ethtool net-tools \
        network-manager wpasupplicant \
        nftables openssh-client \
        pciutils usbutils parted gdisk e2fsprogs dosfstools mtools ntfs-3g exfatprogs \
        xz-utils zstd bzip2 unzip zip \
        qrencode espeak-ng alsa-utils \
        python3 python3-yaml \
        earlyoom libcap2-bin
}

# -----------------------------------------------------------------------------
# 4. Kernel, microcode, firmware, live-boot engine
# -----------------------------------------------------------------------------
install_kernel_and_live() {
    retro_info "Configuring initramfs-tools before the kernel is installed"
    mkdir -p /etc/initramfs-tools/conf.d
    retro_write /etc/initramfs-tools/conf.d/retro.conf 0644 <<'EOF'
# MODULES=most is mandatory for a live image that must boot on arbitrary hardware.
MODULES=most
COMPRESS=zstd
EOF
    retro_write /etc/initramfs-tools/conf.d/resume 0644 <<'EOF'
RESUME=none
EOF

    retro_info "Installing live-boot engine (live-boot + live-config)"
    retro_apt_install initramfs-tools live-boot live-boot-initramfs-tools live-config live-config-systemd

    retro_info "Installing kernel + CPU microcode"
    retro_apt_install linux-image-amd64
    retro_apt_install_optional intel-microcode amd64-microcode

    if [[ "${RETRO_INSTALL_FIRMWARE}" == "1" ]]; then
        retro_info "Installing selected firmware packages"
        # shellcheck disable=SC2086
        retro_apt_install_optional ${RETRO_FIRMWARE_PKGS}
    else
        retro_warn "RETRO_INSTALL_FIRMWARE=0 - skipping firmware packages"
    fi

    retro_info "Rebuilding initramfs for all kernels (live-boot hooks included)"
    update-initramfs -u -k all
}

# -----------------------------------------------------------------------------
# 5. Locale / time / hostname / keyboard
# -----------------------------------------------------------------------------
configure_locale_time() {
    retro_info "Configuring locale ${RETRO_LOCALE}, timezone ${RETRO_TIMEZONE}, hostname ${RETRO_HOSTNAME}"
    sed -i "s/^# *\(${RETRO_LOCALE//./\\.} \)/\1/" /etc/locale.gen
    grep -q "^${RETRO_LOCALE} " /etc/locale.gen || echo "${RETRO_LOCALE} UTF-8" >> /etc/locale.gen
    locale-gen
    printf 'LANG=%s\n' "${RETRO_LOCALE}" > /etc/default/locale

    ln -sf "/usr/share/zoneinfo/${RETRO_TIMEZONE}" /etc/localtime
    printf '%s\n' "${RETRO_TIMEZONE}" > /etc/timezone

    retro_write /etc/default/keyboard 0644 <<EOF
XKBMODEL="pc105"
XKBLAYOUT="${RETRO_KEYMAP}"
XKBVARIANT=""
XKBOPTIONS=""
BACKSPACE="guess"
EOF

    printf '%s\n' "${RETRO_HOSTNAME}" > /etc/hostname
    retro_write /etc/hosts 0644 <<EOF
127.0.0.1   localhost
127.0.1.1   ${RETRO_HOSTNAME}
::1         localhost ip6-localhost ip6-loopback
ff02::1     ip6-allnodes
ff02::2     ip6-allrouters
EOF
}

# -----------------------------------------------------------------------------
# 6. User, groups, sudo
# -----------------------------------------------------------------------------
create_user_and_groups() {
    retro_info "Creating groups and user ${RETRO_USER} (UID ${RETRO_USER_UID})"
    local g
    # System groups: wireshark-common's postinst runs `addgroup --system wireshark`
    # which FAILS if the group already exists as a regular (non-system) group.
    for g in autologin nopasswdlogin wireshark audio video plugdev netdev sudo; do
        getent group "${g}" >/dev/null || groupadd --system "${g}"
    done

    if id -u "${RETRO_USER}" >/dev/null 2>&1; then
        retro_warn "User ${RETRO_USER} already exists - reconciling groups/shell only"
        usermod --shell /bin/bash --append --groups "${RETRO_USER_GROUPS}" "${RETRO_USER}"
    else
        if getent passwd "${RETRO_USER_UID}" >/dev/null; then
            retro_die "UID ${RETRO_USER_UID} is already taken by '$(getent passwd "${RETRO_USER_UID}" | cut -d: -f1)'"
        fi
        useradd --create-home --uid "${RETRO_USER_UID}" --user-group \
            --shell /bin/bash --comment "${RETRO_OS_NAME} User" \
            --groups "${RETRO_USER_GROUPS}" "${RETRO_USER}"
    fi

    printf '%s:%s\n' "${RETRO_USER}" "${RETRO_USER_PASS}" | chpasswd
    printf 'root:%s\n' "${RETRO_ROOT_PASS}" | chpasswd
    usermod --unlock "${RETRO_USER}"
    chage --inactive -1 --mindays 0 --maxdays 99999 --expiredate -1 "${RETRO_USER}"

    retro_write /etc/sudoers.d/90-retro-nopasswd 0440 <<EOF
# Retro OS: passwordless sudo for the default live/desktop user
${RETRO_USER} ALL=(ALL:ALL) NOPASSWD: ALL
EOF
    visudo -cf /etc/sudoers.d/90-retro-nopasswd >/dev/null \
        || retro_die "Generated sudoers file failed visudo validation"

    retro_write /etc/security/limits.d/90-retro.conf 0644 <<'EOF'
# Raised descriptor limits for port scanners (RustScan / naabu / ffuf)
*    soft nofile 8192
*    hard nofile 65535
root soft nofile 8192
root hard nofile 65535
EOF
}

# -----------------------------------------------------------------------------
# 7. Adaptive hardware profile engine
# -----------------------------------------------------------------------------
install_hw_profile_engine() {
    retro_info "Installing adaptive hardware profile engine"

    # Runtime configuration (the chroot copy of config.env does not exist on a
    # running system, so everything the runtime needs is frozen here).
    retro_write "${RETRO_ETC_DIR}/retro.conf" 0644 <<EOF
# Retro OS runtime configuration (sourced by retro-hwprofile and \`retro\`).
RETRO_LOW_TIER_MAX_MB="${RETRO_LOW_TIER_MAX_MB}"
RETRO_ZRAM_ALGO="${RETRO_ZRAM_ALGO}"
RETRO_VFS_CACHE_PRESSURE="${RETRO_VFS_CACHE_PRESSURE}"

RETRO_LOW_ZRAM_PCT="${RETRO_LOW_ZRAM_PCT}"
RETRO_LOW_SWAPPINESS="${RETRO_LOW_SWAPPINESS}"
RETRO_LOW_DIRTY_BG_RATIO="${RETRO_LOW_DIRTY_BG_RATIO}"
RETRO_LOW_DIRTY_RATIO="${RETRO_LOW_DIRTY_RATIO}"
RETRO_LOW_EARLYOOM_ARGS="${RETRO_LOW_EARLYOOM_ARGS}"
RETRO_LOW_PICOM="${RETRO_LOW_PICOM}"

RETRO_STD_ZRAM_PCT="${RETRO_STD_ZRAM_PCT}"
RETRO_STD_SWAPPINESS="${RETRO_STD_SWAPPINESS}"
RETRO_STD_DIRTY_BG_RATIO="${RETRO_STD_DIRTY_BG_RATIO}"
RETRO_STD_DIRTY_RATIO="${RETRO_STD_DIRTY_RATIO}"
RETRO_STD_EARLYOOM_ARGS="${RETRO_STD_EARLYOOM_ARGS}"
RETRO_STD_PICOM="${RETRO_STD_PICOM}"

RETRO_UPDATE_URL="${RETRO_UPDATE_URL}"
EOF

    retro_write /usr/local/sbin/retro-hwprofile 0755 <<'EOF'
#!/usr/bin/env bash
# retro-hwprofile - Retro OS adaptive hardware profiling & dynamic engine tuning.
# Detects RAM/CPU at boot, then configures ZRAM, VM sysctls, EarlyOOM and the
# compositor policy. Overrides: kernel arg `retro.tier=low|standard` or the
# file /etc/retro-os/tier.override (first line: low | standard).
set -Eeuo pipefail

CONF="/etc/retro-os/retro.conf"
RUN_DIR="/run/retro-os"
PROFILE_ENV="${RUN_DIR}/profile.env"
OVERRIDE_FILE="/etc/retro-os/tier.override"
TAG="retro-hwprofile"

log() {
    logger -t "${TAG}" -- "$*" 2>/dev/null || true
    printf '[%s] %s\n' "${TAG}" "$*"
}

# shellcheck source=/dev/null
[[ -r "${CONF}" ]] && source "${CONF}"

LOW_MAX="${RETRO_LOW_TIER_MAX_MB:-1800}"
ALGO="${RETRO_ZRAM_ALGO:-zstd}"
VFS="${RETRO_VFS_CACHE_PRESSURE:-50}"

detect() {
    MEM_KB="$(awk '/^MemTotal:/ {print $2}' /proc/meminfo)"
    RAM_MB=$(( MEM_KB / 1024 ))
    CPUS="$(nproc 2>/dev/null || echo 1)"

    local forced=""
    forced="$(tr ' ' '\n' < /proc/cmdline | sed -n 's/^retro\.tier=//p' | tail -n1)"
    if [[ -z "${forced}" && -r "${OVERRIDE_FILE}" ]]; then
        forced="$(head -n1 "${OVERRIDE_FILE}" | tr -d '[:space:]')"
    fi

    case "${forced}" in
        low|standard) TIER="${forced}"; REASON="override" ;;
        *)
            REASON="auto"
            if (( RAM_MB < LOW_MAX )); then TIER="low"; else TIER="standard"; fi
            ;;
    esac

    if [[ "${TIER}" == "low" ]]; then
        ZRAM_PCT="${RETRO_LOW_ZRAM_PCT:-75}"
        SWAPPINESS="${RETRO_LOW_SWAPPINESS:-100}"
        DIRTY_BG="${RETRO_LOW_DIRTY_BG_RATIO:-5}"
        DIRTY="${RETRO_LOW_DIRTY_RATIO:-10}"
        OOM_ARGS="${RETRO_LOW_EARLYOOM_ARGS:--m 4 -s 8}"
        PICOM="${RETRO_LOW_PICOM:-off}"
    else
        ZRAM_PCT="${RETRO_STD_ZRAM_PCT:-50}"
        SWAPPINESS="${RETRO_STD_SWAPPINESS:-60}"
        DIRTY_BG="${RETRO_STD_DIRTY_BG_RATIO:-8}"
        DIRTY="${RETRO_STD_DIRTY_RATIO:-20}"
        OOM_ARGS="${RETRO_STD_EARLYOOM_ARGS:--m 6 -s 10}"
        PICOM="${RETRO_STD_PICOM:-on}"
    fi
    LOWCPU=0
    (( CPUS <= 2 )) && LOWCPU=1
    return 0
}

apply_zram() {
    local want_bytes="$(( MEM_KB * 1024 * ZRAM_PCT / 100 ))"
    modprobe -q zram num_devices=1 2>/dev/null || true
    if [[ ! -b /dev/zram0 && -w /sys/class/zram-control/hot_add ]]; then
        cat /sys/class/zram-control/hot_add >/dev/null 2>&1 || true
    fi
    if [[ ! -b /dev/zram0 ]]; then
        log "WARN: /dev/zram0 unavailable (kernel without zram?) - continuing without compressed swap"
        ZRAM_STATE="unavailable"
        return 0
    fi
    if swapon --noheadings --show=NAME 2>/dev/null | grep -q '^/dev/zram0'; then
        log "zram0 already active - leaving as is"
        ZRAM_STATE="active"
        return 0
    fi

    echo 1 > /sys/block/zram0/reset 2>/dev/null || true
    local alg="${ALGO}"
    if ! grep -qw "${alg}" /sys/block/zram0/comp_algorithm 2>/dev/null; then
        log "zram algorithm '${alg}' unsupported, falling back to lzo-rle"
        alg="lzo-rle"
    fi
    echo "${alg}" > /sys/block/zram0/comp_algorithm 2>/dev/null || true
    echo "${want_bytes}" > /sys/block/zram0/disksize
    mkswap -q -L retro-zram /dev/zram0
    swapon -p 100 /dev/zram0
    ZRAM_STATE="active"
    ZRAM_ALGO_USED="${alg}"
    log "zram0: $(( want_bytes / 1024 / 1024 )) MiB (${ZRAM_PCT}% of RAM), algorithm ${alg}"
}

teardown_zram() {
    if swapon --noheadings --show=NAME 2>/dev/null | grep -q '^/dev/zram0'; then
        swapoff /dev/zram0 || true
    fi
    [[ -w /sys/block/zram0/reset ]] && echo 1 > /sys/block/zram0/reset || true
}

apply_sysctl() {
    local kv
    for kv in \
        "vm.swappiness=${SWAPPINESS}" \
        "vm.vfs_cache_pressure=${VFS}" \
        "vm.page-cluster=0" \
        "vm.dirty_background_ratio=${DIRTY_BG}" \
        "vm.dirty_ratio=${DIRTY}" \
        "vm.dirty_expire_centisecs=2000" \
        "vm.dirty_writeback_centisecs=500" \
        "kernel.sched_autogroup_enabled=1"; do
        sysctl -q -w "${kv}" 2>/dev/null || log "WARN: could not apply ${kv}"
    done
}

apply_earlyoom() {
    local protect='^(Xorg|openbox|lightdm|systemd|dbus-daemon|tint2|NetworkManager)$'
    local tmp
    tmp="$(mktemp /etc/default/.earlyoom.XXXXXX)"
    {
        echo "# generated by retro-hwprofile (tier=${TIER})"
        echo "EARLYOOM_ARGS=\"${OOM_ARGS} -r 3600 --avoid ${protect}\""
    } > "${tmp}"
    chmod 0644 "${tmp}"
    mv -f "${tmp}" /etc/default/earlyoom
    log "earlyoom args: ${OOM_ARGS}"
}

write_profile_env() {
    mkdir -p "${RUN_DIR}"
    cat > "${PROFILE_ENV}.tmp" <<EOT
RETRO_TIER=${TIER}
RETRO_TIER_REASON=${REASON}
RETRO_RAM_MB=${RAM_MB}
RETRO_CPUS=${CPUS}
RETRO_LOWCPU=${LOWCPU}
RETRO_ZRAM_PCT=${ZRAM_PCT}
RETRO_ZRAM_STATE=${ZRAM_STATE:-unknown}
RETRO_ZRAM_ALGO=${ZRAM_ALGO_USED:-n/a}
RETRO_SWAPPINESS=${SWAPPINESS}
RETRO_EARLYOOM_ARGS="${OOM_ARGS}"
RETRO_PICOM=${PICOM}
EOT
    chmod 0644 "${PROFILE_ENV}.tmp"
    mv -f "${PROFILE_ENV}.tmp" "${PROFILE_ENV}"
}

cmd="${1:-apply}"
case "${cmd}" in
    apply|start)
        detect
        log "tier=${TIER} (${REASON}) ram=${RAM_MB}MiB cpus=${CPUS} compositor=${PICOM}"
        apply_zram
        apply_sysctl
        apply_earlyoom
        write_profile_env
        ;;
    stop)
        teardown_zram
        ;;
    status)
        if [[ -r "${PROFILE_ENV}" ]]; then cat "${PROFILE_ENV}"; else echo "no profile yet (run: retro-hwprofile apply)"; exit 1; fi
        ;;
    *)
        echo "usage: retro-hwprofile {apply|stop|status}" >&2
        exit 2
        ;;
esac
EOF

    retro_write /etc/systemd/system/retro-hwprofile.service 0644 <<'EOF'
[Unit]
Description=Retro OS adaptive hardware profile (ZRAM, sysctl, EarlyOOM)
After=systemd-modules-load.service systemd-sysctl.service local-fs.target
Before=earlyoom.service display-manager.service
ConditionPathExists=/usr/local/sbin/retro-hwprofile

[Service]
Type=oneshot
RemainAfterExit=yes
ExecStart=/usr/local/sbin/retro-hwprofile apply
ExecStop=/usr/local/sbin/retro-hwprofile stop
TimeoutStartSec=30

[Install]
WantedBy=multi-user.target
EOF

    retro_write /etc/sysctl.d/99-retro-desktop.conf 0644 <<'EOF'
# Retro OS - low-latency desktop baseline (per-tier VM values are applied at
# boot by retro-hwprofile)
vm.vfs_cache_pressure = 50
vm.page-cluster = 0
kernel.sched_autogroup_enabled = 1
net.core.default_qdisc = fq
net.ipv4.tcp_congestion_control = bbr
fs.inotify.max_user_watches = 65536
EOF
    retro_write /etc/modules-load.d/retro-net.conf 0644 <<'EOF'
tcp_bbr
sch_fq
zram
EOF

    # EarlyOOM: default file so the unit works even before hwprofile has run
    retro_write /etc/default/earlyoom 0644 <<EOF
EARLYOOM_ARGS="${RETRO_LOW_EARLYOOM_ARGS} -r 3600"
EOF

    systemctl enable retro-hwprofile.service
    systemctl enable earlyoom.service
    systemctl enable NetworkManager.service
}

# -----------------------------------------------------------------------------
# 8. Service trimming, journald, NetworkManager
# -----------------------------------------------------------------------------
tune_services() {
    retro_info "Trimming background services / journald"
    systemctl mask apt-daily.timer apt-daily-upgrade.timer apt-daily.service \
        apt-daily-upgrade.service man-db.timer e2scrub_all.timer >/dev/null 2>&1 || true

    retro_write /etc/systemd/journald.conf.d/90-retro.conf 0644 <<'EOF'
[Journal]
Storage=volatile
RuntimeMaxUse=16M
RuntimeMaxFileSize=4M
ForwardToSyslog=no
EOF
    retro_write /etc/systemd/system.conf.d/90-retro.conf 0644 <<'EOF'
[Manager]
DefaultTimeoutStartSec=30s
DefaultTimeoutStopSec=15s
EOF
    retro_write /etc/NetworkManager/conf.d/90-retro.conf 0644 <<'EOF'
[main]
dns=default
plugins=ifupdown,keyfile

[ifupdown]
managed=true
EOF
}

# -----------------------------------------------------------------------------
# 9. Release metadata
# -----------------------------------------------------------------------------
write_release_info() {
    retro_info "Writing release metadata"
    retro_write "${RETRO_ETC_DIR}/release" 0644 <<EOF
RETRO_OS_NAME="${RETRO_OS_NAME}"
RETRO_OS_VERSION="${RETRO_OS_VERSION}"
RETRO_OS_EDITION="${RETRO_OS_EDITION}"
RETRO_FOUNDER="${RETRO_FOUNDER}"
RETRO_BASE="Debian ${DEBIAN_SUITE}"
RETRO_BUILD_DATE="$(date -u +%Y-%m-%dT%H:%M:%SZ)"
EOF
    retro_write /etc/issue 0644 <<EOF
${RETRO_OS_NAME} ${RETRO_OS_VERSION} (${RETRO_OS_EDITION}) - \\n \\l

EOF
    printf '%s\n' "${RETRO_OS_NAME} ${RETRO_OS_VERSION} - Founder: ${RETRO_FOUNDER}" > /etc/motd
}

main() {
    retro_info "=== 01_engine_setup.sh: start ==="
    install_policy_rc
    configure_apt
    install_base_system
    install_kernel_and_live
    configure_locale_time
    create_user_and_groups
    install_hw_profile_engine
    tune_services
    write_release_info
    retro_ok "=== 01_engine_setup.sh: complete ==="
}

main "$@"

#!/usr/bin/env bash
# =============================================================================
# Retro OS v2.0 - 98_finalize.sh   (runs as root INSIDE the build chroot)
#
# Runs AFTER the overlay's post-pass and BEFORE 99_selftest.sh:
#   * push /etc/skel into /home/retro (the user was created before the skeleton
#     existed) and fix ownership
#   * live-desktop installer launcher
#   * final initramfs, apt/dpkg audit, cache + log cleanup, machine-id reset
# =============================================================================
set -Eeuo pipefail

SELF_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
# shellcheck source=/dev/null
source "${SELF_DIR}/config.env"
retro_enable_traps "98_finalize.sh"
retro_require_chroot

export DEBIAN_FRONTEND=noninteractive LC_ALL=C LANG=C

HOME_DIR="/home/${RETRO_USER}"

sync_home_from_skel() {
    retro_info "Syncing /etc/skel into ${HOME_DIR}"
    [[ -d "${HOME_DIR}" ]] || retro_die "${HOME_DIR} does not exist - 01_engine_setup.sh did not create the user"
    cp -a /etc/skel/. "${HOME_DIR}/"

    if command -v calamares >/dev/null 2>&1; then
        mkdir -p "${HOME_DIR}/Desktop"
        retro_write "${HOME_DIR}/Desktop/install-retro-os.desktop" 0755 <<EOF
[Desktop Entry]
Type=Application
Name=Install ${RETRO_OS_NAME}
Comment=Install ${RETRO_OS_NAME} to this computer
Exec=sudo -E calamares
Icon=system-software-install
Terminal=false
Categories=System;
EOF
    fi

    # Menus for the live user are the generated skeleton menus; make sure they
    # reflect the final tool set.
    "${RETRO_HELPER_DIR}/retro-menu-gen" --user "${HOME_DIR}"

    chown -R "${RETRO_USER}:${RETRO_USER}" "${HOME_DIR}"
    chmod 0755 "${HOME_DIR}" || true
}

fix_helper_permissions() {
    retro_info "Normalising helper permissions"
    chown -R root:root "${RETRO_ROOT}" "${RETRO_AI_DIR}" 2>/dev/null || true
    find "${RETRO_HELPER_DIR}" -type f -exec chmod 0755 {} +
    chmod 0755 "${RETRO_BIN_DIR}/retro" "${RETRO_AI_DIR}/retro_ai.py" 2>/dev/null || true
    chmod 0750 "${RETRO_HELPER_DIR}/retro-live-fixup"
    chmod 0755 /usr/local/sbin/retro-hwprofile
}

rebuild_initramfs() {
    retro_info "Final initramfs rebuild (all kernels)"
    update-initramfs -u -k all
}

audit_packages() {
    retro_info "Auditing dpkg / apt state"
    local broken
    broken="$(dpkg --audit 2>&1 || true)"
    if [[ -n "${broken}" ]]; then
        printf '%s\n' "${broken}" >&2
        retro_die "dpkg reports half-configured packages (see above). Re-run the build with --clean or fix the failing postinst."
    fi
    apt-get check >/dev/null || retro_die "apt-get check failed - broken dependency state"
}

cleanup_chroot() {
    retro_info "Cleaning caches, logs and transient state"
    rm -f /usr/sbin/policy-rc.d
    apt-get clean
    rm -rf /var/lib/apt/lists/* /var/cache/apt/*.bin /var/cache/debconf/*-old /var/lib/dpkg/*-old
    find /var/log -type f \( -name '*.log' -o -name '*.log.*' -o -name '*.gz' -o -name 'lastlog' -o -name 'wtmp' -o -name 'btmp' \) -exec truncate -s 0 {} + 2>/dev/null || true
    find /tmp -mindepth 1 -maxdepth 1 ! -name retro-build -exec rm -rf {} + 2>/dev/null || true
    rm -rf /root/.cache /root/.bash_history "${HOME_DIR}/.cache" "${HOME_DIR}/.bash_history"

    # Let systemd generate a fresh machine-id on first boot
    : > /etc/machine-id
    rm -f /var/lib/dbus/machine-id
    ln -sf /etc/machine-id /var/lib/dbus/machine-id

    # Remove python bytecode created while testing
    find /opt -name '__pycache__' -type d -prune -exec rm -rf {} + 2>/dev/null || true
}

main() {
    retro_info "=== 98_finalize.sh: start ==="
    sync_home_from_skel
    fix_helper_permissions
    rebuild_initramfs
    audit_packages
    cleanup_chroot
    retro_ok "=== 98_finalize.sh: complete ==="
}

main "$@"

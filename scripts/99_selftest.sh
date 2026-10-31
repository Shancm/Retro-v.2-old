#!/usr/bin/env bash
# =============================================================================
# Retro OS v2.0 - 99_selftest.sh   (runs as root INSIDE the build chroot)
#
# Pre-SquashFS smoke test. Any CRITICAL failure exits non-zero, which makes
# build.sh stop BEFORE mksquashfs - a broken ISO is never produced.
# Each failure prints an actionable "-> fix:" hint.
# =============================================================================
set -Eeuo pipefail

SELF_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
# shellcheck source=/dev/null
source "${SELF_DIR}/config.env"
retro_enable_traps "99_selftest.sh"
retro_require_chroot

PASS=0
FAIL=0
WARN=0

pass() { PASS=$(( PASS + 1 )); printf 'SELFTEST: PASS  %s\n' "$1"; }
fail() { FAIL=$(( FAIL + 1 )); printf 'SELFTEST: FAIL  %s\n          -> fix: %s\n' "$1" "$2" >&2; }
soft() { WARN=$(( WARN + 1 )); printf 'SELFTEST: WARN  %s\n          -> note: %s\n' "$1" "$2"; }

# check <name> <fix-hint> <command...>
check() {
    local name="$1" hint="$2"
    shift 2
    if "$@" >/dev/null 2>&1; then pass "${name}"; else fail "${name}" "${hint}"; fi
}

has_line() { grep -Eq -- "$2" "$1" 2>/dev/null; }
in_group() { id -nG "$1" 2>/dev/null | tr ' ' '\n' | grep -qx "$2"; }

HOME_DIR="/home/${RETRO_USER}"

# -----------------------------------------------------------------------------
# 1. User, groups, shadow
# -----------------------------------------------------------------------------
test_user() {
    retro_info "[1/7] user / groups / shadow"
    check "user ${RETRO_USER} exists" "01_engine_setup.sh create_user_and_groups did not run" id -u "${RETRO_USER}"
    if [[ "$(id -u "${RETRO_USER}" 2>/dev/null || echo -1)" == "${RETRO_USER_UID}" ]]; then
        pass "user ${RETRO_USER} has UID ${RETRO_USER_UID}"
    else
        fail "user ${RETRO_USER} has UID ${RETRO_USER_UID}" "UID 1000 was taken before 'useradd'; check debootstrap/packages creating users"
    fi

    local g
    for g in autologin nopasswdlogin sudo audio video plugdev netdev wireshark; do
        if in_group "${RETRO_USER}" "${g}"; then
            pass "${RETRO_USER} in group ${g}"
        else
            fail "${RETRO_USER} in group ${g}" "usermod -aG ${g} ${RETRO_USER} (RETRO_USER_GROUPS in config.env)"
        fi
    done

    local hash
    hash="$(awk -F: -v u="${RETRO_USER}" '$1==u {print $2}' /etc/shadow)"
    if [[ -n "${hash}" && "${hash}" != '!'* && "${hash}" != '*'* ]]; then
        pass "/etc/shadow entry for ${RETRO_USER} is unlocked"
    else
        fail "/etc/shadow entry for ${RETRO_USER} is unlocked" "run: usermod -U ${RETRO_USER}; echo '${RETRO_USER}:<pass>' | chpasswd"
    fi
    check "sudoers drop-in valid" "visudo -cf /etc/sudoers.d/90-retro-nopasswd" visudo -cf /etc/sudoers.d/90-retro-nopasswd
}

# -----------------------------------------------------------------------------
# 2. Login stack (LightDM + PAM + session entry points)
# -----------------------------------------------------------------------------
test_login_stack() {
    retro_info "[2/7] LightDM / PAM / session files"
    local pam="/etc/pam.d/lightdm-autologin"
    check "${pam} exists" "02_interface_setup.sh install_login_stack" test -s "${pam}"
    if has_line "${pam}" 'pam_succeed_if\.so[[:space:]]+user[[:space:]]+ingroup[[:space:]]+nopasswdlogin'; then
        pass "PAM: pam_succeed_if ingroup nopasswdlogin"
    else
        fail "PAM: pam_succeed_if ingroup nopasswdlogin" "restore /opt/retro-os/templates/lightdm-autologin.pam to ${pam}"
    fi
    if has_line "${pam}" '^auth[[:space:]]+required[[:space:]]+pam_permit\.so'; then
        pass "PAM: pam_permit.so"
    else
        fail "PAM: pam_permit.so" "restore /opt/retro-os/templates/lightdm-autologin.pam to ${pam}"
    fi

    local f
    for f in /etc/lightdm/lightdm.conf /etc/lightdm/lightdm.conf.d/50-retro-autologin.conf; do
        if has_line "${f}" "^autologin-user=${RETRO_USER}\$" \
           && has_line "${f}" '^autologin-user-timeout=0$' \
           && has_line "${f}" '^user-session=openbox$'; then
            pass "$(basename "${f}") autologin parameters"
        else
            fail "$(basename "${f}") autologin parameters" "must contain autologin-user=${RETRO_USER}, autologin-user-timeout=0, user-session=openbox"
        fi
    done

    check "default target = graphical" "systemctl set-default graphical.target" \
        test "$(readlink /etc/systemd/system/default.target 2>/dev/null)" = "/lib/systemd/system/graphical.target" -o \
             "$(readlink /etc/systemd/system/default.target 2>/dev/null)" = "/usr/lib/systemd/system/graphical.target"
    check "display-manager.service -> lightdm" "systemctl enable lightdm.service" \
        bash -c 'readlink /etc/systemd/system/display-manager.service | grep -q lightdm'
    check "/usr/share/xsessions/openbox.desktop" "install the openbox package" test -s /usr/share/xsessions/openbox.desktop
    check "Xwrapper.config" "restore /opt/retro-os/templates/Xwrapper.config" test -s /etc/X11/Xwrapper.config

    local base
    for base in /etc/skel "${HOME_DIR}"; do
        local s
        for s in .xsession .xinitrc; do
            if has_line "${base}/${s}" '^exec openbox-session$' && [[ -x "${base}/${s}" ]]; then
                pass "${base}/${s} (exec openbox-session, executable)"
            else
                fail "${base}/${s} (exec openbox-session, executable)" "re-run 02_interface_setup.sh write_skel_session, then 98_finalize.sh"
            fi
        done
    done

    local unit
    for unit in lightdm retro-live-fixup retro-hwprofile earlyoom NetworkManager retro-ai-watchdog retro-boot-report; do
        check "unit enabled: ${unit}" "systemctl enable ${unit}.service" systemctl is-enabled --quiet "${unit}.service"
    done
}

# -----------------------------------------------------------------------------
# 3. Home / skeleton ownership and configs
# -----------------------------------------------------------------------------
test_home() {
    retro_info "[3/7] home + skeleton"
    check "${HOME_DIR} exists" "98_finalize.sh sync_home_from_skel" test -d "${HOME_DIR}"
    if [[ -z "$(find "${HOME_DIR}" \( ! -user "${RETRO_USER}" -o ! -group "${RETRO_USER}" \) -print -quit 2>/dev/null)" ]]; then
        pass "${HOME_DIR} fully owned by ${RETRO_USER}:${RETRO_USER}"
    else
        fail "${HOME_DIR} fully owned by ${RETRO_USER}:${RETRO_USER}" "chown -R ${RETRO_USER}:${RETRO_USER} ${HOME_DIR} (overlay/cp -a may have preserved host UIDs)"
    fi
    if [[ -z "$(find /etc/skel ! -type l -perm /022 -print -quit 2>/dev/null)" ]]; then
        pass "/etc/skel has no group/other-writable entries"
    else
        fail "/etc/skel has no group/other-writable entries" "chmod -R go-w /etc/skel (offender: $(find /etc/skel ! -type l -perm /022 -print -quit))"
    fi
    if [[ "$(stat -c %U /etc/skel)" == "root" ]]; then
        pass "/etc/skel owned by root (copied to the user with correct ownership)"
    else
        fail "/etc/skel owned by root" "chown -R root:root /etc/skel"
    fi

    local base f
    for base in /etc/skel "${HOME_DIR}"; do
        for f in .config/openbox/rc.xml .config/openbox/menu.xml .config/openbox/autostart \
                 .config/tint2/tint2rc .config/jgmenu/jgmenurc .config/picom/picom.conf \
                 .config/pcmanfm/default/desktop-items-0.conf; do
            check "${base}/${f}" "re-run 02_interface_setup.sh (skeleton step)" test -s "${base}/${f}"
        done
        for f in .config/openbox/rc.xml .config/openbox/menu.xml; do
            check "${base}/${f} is valid XML" "xmllint/ElementTree rejected the file - inspect the generator" \
                python3 -c "import sys, xml.etree.ElementTree as E; E.parse(sys.argv[1])" "${base}/${f}"
        done
        local dc="${base}/.config/pcmanfm/default/desktop-items-0.conf"
        if has_line "${dc}" '^show_wm_menu=1$' && has_line "${dc}" '^wallpaper_mode=stretch$'; then
            pass "${dc}: show_wm_menu=1 + wallpaper_mode=stretch"
        else
            fail "${dc}: show_wm_menu=1 + wallpaper_mode=stretch" "fix write_skel_jgmenu_picom_pcmanfm in 02_interface_setup.sh"
        fi
    done

    local wp="/usr/share/backgrounds/retro-os/wallpaper.png"
    if [[ -s "${wp}" && "$(head -c4 "${wp}" | od -An -tx1 | tr -d ' \n')" == "89504e47" ]]; then
        pass "wallpaper present and a valid PNG (${wp})"
    else
        fail "wallpaper present and a valid PNG (${wp})" "add overlay/usr/share/backgrounds/retro-os/wallpaper.png (build.sh normally seeds a fallback)"
    fi
    check "start orb icon" "overlay/usr/share/pixmaps/retro-start.svg or 02 built-in" test -s /usr/share/pixmaps/retro-start.svg

    # Security tool launchers must run through the --hold terminal wrapper
    local bad=0 d
    for d in /usr/share/applications/retro-tool-*.desktop; do
        [[ -e "${d}" ]] || continue
        has_line "${d}" '^Exec=xfce4-terminal --hold -e ' || { bad=1; printf '          bad launcher: %s\n' "${d}" >&2; }
    done
    if (( bad == 0 )); then pass "tool .desktop launchers use xfce4-terminal --hold -e"; else fail "tool .desktop launchers use xfce4-terminal --hold -e" "retro-menu-gen --system"; fi
    if has_line "${HOME_DIR}/.config/openbox/menu.xml" "xfce4-terminal --hold -e '[a-z0-9-]+ (--help|-Help)'"; then
        pass "Openbox menu tool entries use xfce4-terminal --hold -e '<cmd> --help'"
    else
        fail "Openbox menu tool entries use xfce4-terminal --hold -e '<cmd> --help'" "retro-menu-gen --user ${HOME_DIR} (are the tools installed?)"
    fi
}

# -----------------------------------------------------------------------------
# 4. Kernel / initramfs
# -----------------------------------------------------------------------------
test_boot_files() {
    retro_info "[4/7] kernel + initramfs"
    local k found=0
    for k in /boot/vmlinuz-*; do
        [[ -e "${k}" ]] || continue
        found=1
        local ver="${k#/boot/vmlinuz-}" initrd="/boot/initrd.img-${k#/boot/vmlinuz-}"
        if [[ -s "${k}" ]]; then pass "kernel ${k} non-empty"; else fail "kernel ${k} non-empty" "reinstall linux-image-amd64"; fi
        if [[ -s "${initrd}" ]]; then
            pass "initramfs ${initrd} non-empty"
            if lsinitramfs "${initrd}" 2>/dev/null | grep -q 'scripts/live'; then
                pass "initramfs ${ver} contains live-boot scripts"
            else
                fail "initramfs ${ver} contains live-boot scripts" "update-initramfs -u -k all AFTER installing live-boot (98_finalize.sh does this)"
            fi
            if lsinitramfs "${initrd}" 2>/dev/null | grep -Eq 'squashfs|overlay'; then
                pass "initramfs ${ver} has squashfs/overlay support"
            else
                fail "initramfs ${ver} has squashfs/overlay support" "set MODULES=most in /etc/initramfs-tools/conf.d/retro.conf"
            fi
        else
            fail "initramfs ${initrd} non-empty" "update-initramfs -c -k ${ver}"
        fi
    done
    if (( found == 0 )); then fail "kernel image in /boot" "01_engine_setup.sh install_kernel_and_live failed"; fi
}

# -----------------------------------------------------------------------------
# 5. Binaries, scripts, payload
# -----------------------------------------------------------------------------
test_payload() {
    retro_info "[5/7] binaries / scripts / payload"
    local b
    for b in openbox openbox-session tint2 pcmanfm picom xfce4-terminal jgmenu_run lightdm \
             nm-applet volumeicon nmap tshark aircrack-ng hydra john nikto sqlmap wifite \
             qrencode earlyoom espeak-ng python3 btop snapper btrfs dm-tool amixer; do
        check "binary: ${b}" "install the providing package (see scripts/01-04)" command -v "${b}"
    done
    for b in rustscan ffuf httpx naabu; do
        if command -v "${b}" >/dev/null 2>&1; then
            pass "modern tool: ${b}"
        elif [[ "${RETRO_TOOLS_STRICT}" == "1" ]]; then
            fail "modern tool: ${b}" "retro-fetch-tools ${b} (or set GITHUB_TOKEN to avoid API rate limits)"
        else
            soft "modern tool missing: ${b}" "run on the live system: sudo ${RETRO_HELPER_DIR}/retro-fetch-tools ${b}"
        fi
    done
    check "grub-btrfs installed" "04_installer_setup.sh install_grub_btrfs (network/GitHub?)" test -x /etc/grub.d/41_snapshots-btrfs

    check "retro CLI present + executable" "overlay/usr/local/bin/retro" test -x "${RETRO_BIN_DIR}/retro"
    check "retro CLI syntax" "bash -n ${RETRO_BIN_DIR}/retro" bash -n "${RETRO_BIN_DIR}/retro"
    check "retro --version" "run ${RETRO_BIN_DIR}/retro --version" "${RETRO_BIN_DIR}/retro" --version
    check "retro_ai.py compiles" "python3 -m py_compile ${RETRO_AI_DIR}/retro_ai.py" python3 -m py_compile "${RETRO_AI_DIR}/retro_ai.py"
    find "${RETRO_AI_DIR}" -name '__pycache__' -type d -prune -exec rm -rf {} + 2>/dev/null || true

    local s
    for s in "${RETRO_HELPER_DIR}"/*; do
        [[ -f "${s}" ]] || continue
        check "bash -n $(basename "${s}")" "syntax error in ${s}" bash -n "${s}"
    done
    check "bash -n retro-hwprofile" "syntax error" bash -n /usr/local/sbin/retro-hwprofile
    check "policy-rc.d removed" "98_finalize.sh cleanup_chroot (services would be blocked)" test ! -e /usr/sbin/policy-rc.d
    check "dpkg consistent" "dpkg --configure -a" bash -c '[[ -z "$(dpkg --audit)" ]]'
}

# -----------------------------------------------------------------------------
# 6. Runtime tuning files
# -----------------------------------------------------------------------------
test_tuning() {
    retro_info "[6/7] adaptive engine files"
    check "retro.conf" "01_engine_setup.sh install_hw_profile_engine" test -s "${RETRO_ETC_DIR}/retro.conf"
    check "sysctl baseline (BBR)" "restore /etc/sysctl.d/99-retro-desktop.conf" \
        grep -q 'tcp_congestion_control = bbr' /etc/sysctl.d/99-retro-desktop.conf
    check "sysctl vfs_cache_pressure=50" "restore /etc/sysctl.d/99-retro-desktop.conf" \
        grep -q 'vm.vfs_cache_pressure = 50' /etc/sysctl.d/99-retro-desktop.conf
    check "autogroup sysctl" "restore /etc/sysctl.d/99-retro-desktop.conf" \
        grep -q 'kernel.sched_autogroup_enabled = 1' /etc/sysctl.d/99-retro-desktop.conf
    check "tcp_bbr in modules-load" "restore /etc/modules-load.d/retro-net.conf" grep -q '^tcp_bbr' /etc/modules-load.d/retro-net.conf
    check "hwprofile low-tier zstd/75%" "RETRO_LOW_ZRAM_PCT / RETRO_ZRAM_ALGO in config.env" \
        bash -c "grep -q 'RETRO_LOW_ZRAM_PCT=\"75\"' ${RETRO_ETC_DIR}/retro.conf && grep -q 'RETRO_ZRAM_ALGO=\"zstd\"' ${RETRO_ETC_DIR}/retro.conf"
    check "low-tier earlyoom -m 4 -s 8" "RETRO_LOW_EARLYOOM_ARGS in config.env" \
        grep -q 'RETRO_LOW_EARLYOOM_ARGS="-m 4 -s 8"' "${RETRO_ETC_DIR}/retro.conf"
    check "retro-ai.conf" "03_modules_setup.sh install_retro_ai" test -s "${RETRO_ETC_DIR}/retro-ai.conf"
}

# -----------------------------------------------------------------------------
# 7. Summary
# -----------------------------------------------------------------------------
summary() {
    retro_info "[7/7] summary"
    printf 'SELFTEST: SUMMARY pass=%d fail=%d warn=%d\n' "${PASS}" "${FAIL}" "${WARN}"
    if (( FAIL > 0 )); then
        retro_error "In-chroot self-test FAILED (${FAIL} critical). The ISO build is halted - fix the items marked '-> fix:' above."
        exit 1
    fi
    retro_ok "In-chroot self-test passed (${PASS} checks, ${WARN} warnings)"
}

main() {
    retro_info "=== 99_selftest.sh: start ==="
    test_user
    test_login_stack
    test_home
    test_boot_files
    test_payload
    test_tuning
    summary
}

main "$@"

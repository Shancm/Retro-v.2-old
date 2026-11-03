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
no_legacy_password() { ! grep -Eq 'chpasswd|:retro|--unlock' "$1"; }
dpkg_audit_clean() { [[ -z "$(dpkg --audit)" ]]; }

lightdm_pam_clean() {
    local f pam_dir="${RETRO_SELFTEST_PAM_DIR:-/etc/pam.d}"
    # Keep Debian's package-provided PAM service files intact. In particular,
    # lightdm-greeter/lightdm-autologin may legitimately use pam_permit.so;
    # its presence is not itself an enabled autologin policy.
    # The bypass prohibited here is the nopasswdlogin group rule.
    [[ -s "${pam_dir}/lightdm" ]] || return 1
    [[ -s "${pam_dir}/lightdm-autologin" ]] || return 1
    grep -Eq 'common-auth' "${pam_dir}/lightdm" || return 1
    for f in "${pam_dir}"/lightdm*; do
        [[ -f "${f}" ]] || continue
        if grep -Eq 'nopasswdlogin' "${f}"; then
            return 1
        fi
    done
    return 0
}

gh_version() {
    local version=""
    # Prefer the executable's own version over package metadata.
    if command -v gh >/dev/null 2>&1; then
        version="$(gh version 2>/dev/null | awk 'NR == 1 {print $3}')"
    fi
    if [[ -z "${version}" ]] && command -v dpkg-query >/dev/null 2>&1; then
        version="$(dpkg-query -W -f='${Version}' gh 2>/dev/null || true)"
    fi
    [[ "${version}" =~ ^[0-9]+([:.~+_-][A-Za-z0-9.+:~_-]+)*$ ]] || return 1
    printf '%s\n' "${version}"
}

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
        fail "user ${RETRO_USER} has UID ${RETRO_USER_UID}" "check UID allocation in 01_engine_setup.sh"
    fi

    local g
    for g in sudo audio video plugdev netdev wireshark; do
        if in_group "${RETRO_USER}" "${g}"; then pass "${RETRO_USER} in group ${g}"
        else fail "${RETRO_USER} in group ${g}" "usermod -aG ${g} ${RETRO_USER}"
        fi
    done
    for g in autologin nopasswdlogin; do
        if in_group "${RETRO_USER}" "${g}"; then fail "${RETRO_USER} is not in insecure group ${g}" "remove ${g} from RETRO_USER_GROUPS"
        else pass "${RETRO_USER} not in ${g}"
        fi
    done

    local status root_status
    status="$(passwd -S "${RETRO_USER}" 2>/dev/null | awk '{print $2}')"
    root_status="$(passwd -S root 2>/dev/null | awk '{print $2}')"
    if [[ "${status}" == "L" || "${status}" == "LK" ]]; then pass "image default user password is locked"
    else fail "image default user password is locked" "keep the build-time account locked; use live-only random credentials"
    fi
    if [[ "${root_status}" == "L" || "${root_status}" == "LK" ]]; then pass "root account is locked"
    else fail "root account is locked" "passwd --lock root in 01_engine_setup.sh"
    fi
    check "no passwordless sudo drop-in" "remove /etc/sudoers.d/90-retro-nopasswd" test ! -e /etc/sudoers.d/90-retro-nopasswd
    if grep -RqsE 'NOPASSWD:[[:space:]]*ALL' /etc/sudoers /etc/sudoers.d 2>/dev/null; then
        fail "no NOPASSWD: ALL sudo rule" "remove every passwordless full-sudo rule"
    else
        pass "no NOPASSWD: ALL sudo rule"
    fi
    check "sudoers syntax valid" "visudo -c" visudo -c
}

# -----------------------------------------------------------------------------
# 2. Login stack (LightDM + PAM + X11/Openbox session entry points)
# -----------------------------------------------------------------------------
test_login_stack() {
    retro_info "[2/7] LightDM / PAM / Openbox X11 session"
    local f base
    check "package-provided LightDM autologin PAM service is intact" "restore the lightdm package PAM files; do not delete /etc/pam.d/lightdm-autologin" bash -c 'dpkg-query -S /etc/pam.d/lightdm-autologin >/dev/null 2>&1 && test -s /etc/pam.d/lightdm-autologin'
    if lightdm_pam_clean; then
        pass "LightDM has no permissive PAM bypass"
    else
        fail "LightDM has no permissive PAM bypass" "restore package-provided /etc/pam.d/lightdm* files and remove any nopasswdlogin rules; pam_permit.so in Debian greeter/autologin stacks is expected"
    fi
    for f in /etc/lightdm/lightdm.conf /etc/lightdm/lightdm.conf.d/50-retro-greeter.conf; do
        check "${f} exists" "02_interface_setup.sh install_login_stack" test -s "${f}"
        if grep -Eq '^autologin-(user|user-timeout|session)=' "${f}"; then
            fail "${f} has no autologin directives" "remove all LightDM autologin settings"
        else
            pass "${f} has no autologin directives"
        fi
        check "${f} selects Retro OS X11 session" "set user-session=retro-os" grep -q '^user-session=retro-os$' "${f}"
    done
    check "Retro OS X11 session descriptor exists" "02_interface_setup.sh install_branding_assets" test -s /usr/share/xsessions/retro-os.desktop
    check "Retro OS session starts Openbox" "set Exec=openbox-session" grep -q "^Exec=openbox-session$" /usr/share/xsessions/retro-os.desktop
    check "report-only autologin absent from built image" "autologin may only be created at boot with retro.report=1" test ! -e /etc/lightdm/lightdm.conf.d/50-retro-report-autologin.conf
    check "live fixup scopes autologin to report mode" "keep the report-only LightDM drop-in behind retro.report=1" grep -A8 -B1 -q "retro.report=1" "${RETRO_HELPER_DIR}/retro-live-fixup"
    check "live credential helper exists" "02_interface_setup.sh write_live_fixup" test -x "${RETRO_HELPER_DIR}/retro-live-credentials"
    check "live credential service exists" "enable retro-live-credentials.service" test -s /etc/systemd/system/retro-live-credentials.service
    check "report-only autologin absent from built image" "autologin may only be created at boot with retro.report=1" test ! -e /etc/lightdm/lightdm.conf.d/50-retro-report-autologin.conf
    check "live fixup scopes autologin to report mode" "keep autologin behind retro.report=1" grep -A7 -B1 -q "retro.report=1" "${RETRO_HELPER_DIR}/retro-live-fixup"
    check "live credential service exists" "enable retro-live-credentials.service" test -s /etc/systemd/system/retro-live-credentials.service
    check "live credential service enabled" "systemctl enable retro-live-credentials.service" systemctl is-enabled --quiet retro-live-credentials.service
    check "credential service conditioned on boot=live" "add ConditionKernelCommandLine=boot=live" grep -q '^ConditionKernelCommandLine=boot=live$' /etc/systemd/system/retro-live-credentials.service
    check "live-fixup does not set a password" "remove chpasswd/default-password code from retro-live-fixup" no_legacy_password "${RETRO_HELPER_DIR}/retro-live-fixup"
    check "default target = graphical" "systemctl set-default graphical.target" \
        test "$(readlink /etc/systemd/system/default.target 2>/dev/null)" = "/lib/systemd/system/graphical.target" -o \
             "$(readlink /etc/systemd/system/default.target 2>/dev/null)" = "/usr/lib/systemd/system/graphical.target"
    check "display-manager.service -> lightdm" "systemctl enable lightdm.service" bash -c 'readlink /etc/systemd/system/display-manager.service | grep -q lightdm'
    check "Xwrapper.config" "restore /opt/retro-os/templates/Xwrapper.config" test -s /etc/X11/Xwrapper.config

    for base in /etc/skel "${HOME_DIR}"; do
        check "${base}/.config/openbox/autostart exists" "re-run 02_interface_setup.sh write_skel_session" test -x "${base}/.config/openbox/autostart"
        check "${base}/.config/openbox/rc.xml exists" "re-run 02_interface_setup.sh write_skel_session" test -s "${base}/.config/openbox/rc.xml"
    done

    local unit
    for unit in lightdm bluetooth retro-live-fixup retro-live-credentials retro-hwprofile earlyoom NetworkManager retro-ai-watchdog retro-boot-report; do
        check "unit enabled: ${unit}" "systemctl enable ${unit}.service" systemctl is-enabled --quiet "${unit}.service"
    done
}

# -----------------------------------------------------------------------------
# 3. Home / skeleton ownership and X11 desktop configs
# -----------------------------------------------------------------------------
test_home() {
    retro_info "[3/7] home + Openbox/Tint2/jgmenu desktop skeleton"
    check "${HOME_DIR} exists" "98_finalize.sh sync_home_from_skel" test -d "${HOME_DIR}"
    if [[ -z "$(find "${HOME_DIR}" \( ! -user "${RETRO_USER}" -o ! -group "${RETRO_USER}" \) -print -quit 2>/dev/null)" ]]; then
        pass "${HOME_DIR} fully owned by ${RETRO_USER}:${RETRO_USER}"
    else
        fail "${HOME_DIR} fully owned by ${RETRO_USER}:${RETRO_USER}" "chown -R ${RETRO_USER}:${RETRO_USER} ${HOME_DIR}"
    fi
    if [[ -z "$(find /etc/skel ! -type l -perm /022 -print -quit 2>/dev/null)" ]]; then
        pass "/etc/skel has no group/other-writable entries"
    else
        fail "/etc/skel has no group/other-writable entries" "chmod -R go-w /etc/skel"
    fi
    check "/etc/skel owned by root" "chown -R root:root /etc/skel" test "$(stat -c %U /etc/skel)" = root

    local base f
    local base f
    for base in /etc/skel "${HOME_DIR}"; do
        for f in .config/openbox/rc.xml .config/openbox/menu.xml .config/openbox/autostart \
                 .config/tint2/tint2rc .config/jgmenu/jgmenurc; do
            check "${base}/${f}" "re-run 02_interface_setup.sh write_skel_session" test -s "${base}/${f}"
        done
        for f in .config/openbox/rc.xml .config/openbox/menu.xml; do
            check "${base}/${f} is valid XML" "inspect Openbox configuration XML" \
                python3 -c "import sys, xml.etree.ElementTree as E; E.parse(sys.argv[1])" "${base}/${f}"
        done
        check "${base}/Openbox title buttons use NLIMC" "set titleLayout NLIMC" \
            grep -q '<titleLayout>NLIMC</titleLayout>' "${base}/.config/openbox/rc.xml"
        check "${base}/Tint2 panel uses LTSC at 32px" "set panel_items=LTSC and panel_size=100% 32" \
            bash -c "grep -q '^panel_items = LTSC$' '${base}/.config/tint2/tint2rc' && grep -q '^panel_size = 100% 32$' '${base}/.config/tint2/tint2rc'"
        check "${base}/Openbox autostart launches desktop/tray apps" "restore pcmanfm, tint2, nm-applet, blueman-applet and volumeicon autostart lines" \
            bash -c "for p in 'pcmanfm --desktop' 'tint2 &' 'nm-applet &' 'blueman-applet &' 'volumeicon &'; do grep -Fq \"\$p\" '${base}/.config/openbox/autostart' || exit 1; done"
    done

    local wp="/usr/share/backgrounds/retro-os/wallpaper.png" png_magic
    png_magic="$(head -c4 "${wp}" 2>/dev/null | od -An -tx1)"
    png_magic="${png_magic//[[:space:]]/}"
    if [[ -s "${wp}" && "${png_magic}" == "89504e47" ]]; then
        pass "wallpaper present and a valid PNG (${wp})"
    else
        fail "wallpaper present and a valid PNG (${wp})" "add overlay/usr/share/backgrounds/retro-os/wallpaper.png (build.sh normally seeds a fallback)"
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
            
            # unmkinitramfs വഴി മൈക്രോകോഡും പ്രധാന ആർക്കൈവും പൂർണ്ണമായി പരിശോധിക്കുന്നു
            local contents=""
            local tmp_test
            tmp_test="$(mktemp -d)"
            if unmkinitramfs "${initrd}" "${tmp_test}" 2>/dev/null; then
                contents="$(find "${tmp_test}" 2>/dev/null)"
            else
                contents="$(lsinitramfs "${initrd}" 2>/dev/null || true)"
            fi
            rm -rf "${tmp_test}"

            if grep -q "scripts/live" <<< "${contents}"; then
                pass "initramfs ${ver} contains live-boot scripts"
            else
                fail "initramfs ${ver} contains live-boot scripts" "update-initramfs -u -k all AFTER installing live-boot"
            fi
            if grep -Eq "squashfs|overlay" <<< "${contents}"; then
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
    local ghv=""
    if ghv="$(gh_version)" && dpkg --compare-versions "${ghv}" ge 2.67.0 && gh attestation verify --help >/dev/null 2>&1; then
        pass "GitHub CLI version supports secure attestations (${ghv})"
    else
        ghv="${ghv:-not installed or version unreadable}"
        fail "GitHub CLI version supports secure attestations (${ghv})" "install GitHub CLI 2.67.0 or newer from cli.github.com/packages"
    fi
    local b
    for b in openbox openbox-session obconf tint2 jgmenu_run lxterminal feh Xorg pkexec lightdm gh pcmanfm nm-applet blueman-applet volumeicon \
             nmap tshark aircrack-ng hydra john nikto sqlmap wifite ffuf qrencode earlyoom espeak-ng python3 btop snapper btrfs dm-tool amixer; do
        check "binary: ${b}" "install the providing package (see scripts/01-04)" command -v "${b}"
    done
    check "X11 server binary installed" "install xserver-xorg-core" command -v Xorg
    check "MATE polkit agent installed" "install the mate-polkit package" test -x /usr/libexec/polkit-mate-authentication-agent-1
    check "polkit daemon installed" "install the polkitd package" test -x /usr/lib/polkit-1/polkitd
    for b in rustscan ffuf httpx naabu; do
        if command -v "${b}" >/dev/null 2>&1; then
            pass "modern tool: ${b}"
        elif [[ "${RETRO_TOOLS_STRICT}" == "1" ]]; then
            fail "modern tool: ${b}" "retro-fetch-tools ${b}; each release needs valid GitHub attestation and SHA-256"
        else
            soft "modern tool missing: ${b}" "run on the live system: sudo ${RETRO_HELPER_DIR}/retro-fetch-tools ${b}"
        fi
    done
    check "grub-btrfs installed" "04_installer_setup.sh install_grub_btrfs (network/GitHub?)" test -x /etc/grub.d/41_snapshots-btrfs

    check "retro CLI present + executable" "overlay/usr/local/bin/retro" test -x "${RETRO_BIN_DIR}/retro"
    check "retro CLI syntax" "bash -n ${RETRO_BIN_DIR}/retro" bash -n "${RETRO_BIN_DIR}/retro"
    check "retro --version" "run ${RETRO_BIN_DIR}/retro --version" "${RETRO_BIN_DIR}/retro" --version
    check "retro_ai.py compiles" "python3 -m py_compile ${RETRO_AI_DIR}/retro_ai.py" python3 -m py_compile "${RETRO_AI_DIR}/retro_ai.py"
    find "${RETRO_AI_DIR}" -name __pycache__ -type d -prune -exec rm -rf {} + 2>/dev/null || true

    local s
    for s in "${RETRO_HELPER_DIR}"/*; do
        [[ -f "${s}" ]] || continue
        check "bash -n $(basename "${s}")" "syntax error in ${s}" bash -n "${s}"
    done
    check "bash -n retro-hwprofile" "syntax error" bash -n /usr/local/sbin/retro-hwprofile
    check "policy-rc.d removed" "98_finalize.sh cleanup_chroot (services would be blocked)" test ! -e /usr/sbin/policy-rc.d
    check "dpkg consistent" "dpkg --configure -a" dpkg_audit_clean
}

# -----------------------------------------------------------------------------
# 6. Runtime tuning files
# -----------------------------------------------------------------------------
test_tuning() {
    retro_info "[6/7] adaptive engine files"
    check "retro.conf" "01_engine_setup.sh install_hw_profile_engine" test -s "${RETRO_ETC_DIR}/retro.conf"
    check "sysctl baseline (BBR)" "restore /etc/sysctl.d/99-retro-desktop.conf" \
        grep -q "tcp_congestion_control = bbr" /etc/sysctl.d/99-retro-desktop.conf
    check "sysctl vfs_cache_pressure=50" "restore /etc/sysctl.d/99-retro-desktop.conf" \
        grep -q "vm.vfs_cache_pressure = 50" /etc/sysctl.d/99-retro-desktop.conf
    check "autogroup sysctl" "restore /etc/sysctl.d/99-retro-desktop.conf" \
        grep -q "kernel.sched_autogroup_enabled = 1" /etc/sysctl.d/99-retro-desktop.conf
    check "tcp_bbr in modules-load" "restore /etc/modules-load.d/retro-net.conf" grep -q "^tcp_bbr" /etc/modules-load.d/retro-net.conf
    check "hwprofile low-tier zstd/75%" "RETRO_LOW_ZRAM_PCT / RETRO_ZRAM_ALGO in config.env" \
        bash -c "grep -q 'RETRO_LOW_ZRAM_PCT=\"75\"' ${RETRO_ETC_DIR}/retro.conf && grep -q 'RETRO_ZRAM_ALGO=\"zstd\"' ${RETRO_ETC_DIR}/retro.conf"
    check "low-tier earlyoom -m 4 -s 8" "RETRO_LOW_EARLYOOM_ARGS in config.env" \
        grep -q "RETRO_LOW_EARLYOOM_ARGS=\"-m 4 -s 8\"" "${RETRO_ETC_DIR}/retro.conf"
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

#!/usr/bin/env bash
# =============================================================================
# Retro OS v2.0 - build.sh   (host build orchestrator, run as root)
#
#   sudo ./build.sh [--clean | --distclean] [--skip-chroot] [--preflight-only]
#                   [--install-deps]
#
# Pipeline:
#   preflight -> debootstrap -> mount virtfs -> overlay (payload) -> 01..04
#   -> overlay (final) -> 98_finalize -> 99_selftest (gate) -> unmount
#   -> squashfs(zstd) -> ISOLINUX + GRUB-EFI -> xorriso hybrid ISO -> sha256
#
# Stages are stamped (${BUILD_ROOT}/.stamps) with the sha256 of config.env +
# their script, so an interrupted build resumes where it stopped and an edited
# script re-runs itself and every later stage. --clean starts from scratch.
# =============================================================================
set -Eeuo pipefail

SELF_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
export RETRO_CONTEXT=host
# shellcheck source=config.env
source "${SELF_DIR}/config.env"
retro_enable_traps "build.sh"

OPT_CLEAN=0
OPT_DISTCLEAN=0
OPT_SKIP_CHROOT=0
OPT_PREFLIGHT_ONLY=0
OPT_INSTALL_DEPS=0

STAMP_DIR="${BUILD_ROOT}/.stamps"
MIN_FREE_GB=12
PREFLIGHT_WARNINGS=0
BUILD_START="$(date +%s)"

ISOLINUX_BIN=""
ISOHDPFX=""
SYSLINUX_MOD_DIR=""

# Order matters: a changed stage invalidates every stage after it.
CHROOT_STAGES=(01_engine_setup.sh 02_interface_setup.sh 03_modules_setup.sh 04_installer_setup.sh)
ALL_SCRIPTS=("${CHROOT_STAGES[@]}" 98_finalize.sh 99_selftest.sh)

declare -a CHROOT_ENV=()

# -----------------------------------------------------------------------------
# CLI
# -----------------------------------------------------------------------------
usage() {
    cat <<EOF
Usage: sudo ./build.sh [options]

  --clean            remove chroot/image/iso/stamps and rebuild from scratch
  --distclean        like --clean, also removes out/ and logs/
  --skip-chroot      reuse the finished chroot (needs a previous successful
                     self-test) and only repackage squashfs + ISO
  --preflight-only   run all host checks, then stop
  --install-deps     apt-get install the host build dependencies first
  -h, --help         this text

Environment passthrough into the chroot (optional):
  GITHUB_TOKEN RETRO_INSTALL_FIRMWARE RETRO_INSTALL_BROWSER RETRO_INSTALL_CALAMARES
  RETRO_SLIM_DPKG RETRO_TOOLS_CHANNEL RETRO_TOOLS_STRICT RETRO_UPDATE_URL
  RETRO_LOW_TIER_MAX_MB DEBIAN_MIRROR DEBIAN_SECURITY_MIRROR
Host-only: BUILD_ROOT  SQUASHFS_ZSTD_LEVEL
EOF
}

parse_args() {
    local arg
    for arg in "$@"; do
        case "${arg}" in
            --clean)          OPT_CLEAN=1 ;;
            --distclean)      OPT_CLEAN=1; OPT_DISTCLEAN=1 ;;
            --skip-chroot)    OPT_SKIP_CHROOT=1 ;;
            --preflight-only) OPT_PREFLIGHT_ONLY=1 ;;
            --install-deps)   OPT_INSTALL_DEPS=1 ;;
            -h|--help)        usage; exit 0 ;;
            *)                usage >&2; retro_die "unknown option: ${arg}" ;;
        esac
    done
    if (( OPT_CLEAN && OPT_SKIP_CHROOT )); then
        retro_die "--clean and --skip-chroot are mutually exclusive"
    fi
}

# -----------------------------------------------------------------------------
# Mount handling + cleanup (strict: no bind-mount may outlive this script)
# -----------------------------------------------------------------------------
chroot_mounts() {   # deepest first
    awk -v d="${CHROOT_DIR}" 'index($2, d "/") == 1 {print $2}' /proc/mounts | sort -r
}

kill_chroot_processes() {
    # Only processes whose root IS the chroot (never a filesystem-wide fuser -k).
    local p root
    for p in /proc/[0-9]*; do
        root="$(readlink "${p}/root" 2>/dev/null || true)"
        if [[ "${root}" == "${CHROOT_DIR}" ]]; then
            kill -TERM "${p#/proc/}" 2>/dev/null || true
        fi
    done
    sleep 1
    for p in /proc/[0-9]*; do
        root="$(readlink "${p}/root" 2>/dev/null || true)"
        if [[ "${root}" == "${CHROOT_DIR}" ]]; then
            kill -KILL "${p#/proc/}" 2>/dev/null || true
        fi
    done
}

unmount_chroot() {
    local attempt mp
    [[ -d "${CHROOT_DIR}" ]] || return 0
    kill_chroot_processes
    for attempt in 1 2 3; do
        [[ -n "$(chroot_mounts)" ]] || return 0
        while IFS= read -r mp; do
            umount "${mp}" 2>/dev/null || true
        done < <(chroot_mounts)
        sleep 1
    done
    while IFS= read -r mp; do
        retro_warn "lazy-unmounting stubborn mount: ${mp}"
        umount -l "${mp}" 2>/dev/null || true
    done < <(chroot_mounts)
    [[ -z "$(chroot_mounts)" ]]
}

mount_virtfs() {
    retro_info "Mounting virtual filesystems into the chroot"
    mkdir -p "${CHROOT_DIR}/dev" "${CHROOT_DIR}/proc" "${CHROOT_DIR}/sys" "${CHROOT_DIR}/run"

    mountpoint -q "${CHROOT_DIR}/proc" || mount -t proc proc "${CHROOT_DIR}/proc"
    mountpoint -q "${CHROOT_DIR}/sys"  || mount -t sysfs sysfs "${CHROOT_DIR}/sys"

    if ! mountpoint -q "${CHROOT_DIR}/dev"; then
        mount --bind /dev "${CHROOT_DIR}/dev"
        mount --make-rslave "${CHROOT_DIR}/dev"
    fi
    mkdir -p "${CHROOT_DIR}/dev/pts"
    if ! mountpoint -q "${CHROOT_DIR}/dev/pts"; then
        mount --bind /dev/pts "${CHROOT_DIR}/dev/pts"
        mount --make-rslave "${CHROOT_DIR}/dev/pts"
    fi

    # /run is a private tmpfs - binding the HOST's /run would let chroot tools
    # talk to the host's systemd/udev/dbus sockets.
    if ! mountpoint -q "${CHROOT_DIR}/run"; then
        mount -t tmpfs -o mode=0755,nosuid,nodev tmpfs "${CHROOT_DIR}/run"
    fi
    mkdir -p "${CHROOT_DIR}/run/lock"
}

on_exit() {
    local rc=$?
    trap - EXIT ERR INT TERM
    set +e
    if ! unmount_chroot; then
        retro_error "COULD NOT UNMOUNT everything under ${CHROOT_DIR}. Check: grep '${CHROOT_DIR}' /proc/mounts"
        rc=${rc:-1}; [[ ${rc} -eq 0 ]] && rc=1
    fi
    if (( rc != 0 )); then
        retro_error "Build FAILED (exit ${rc}). Log: ${RETRO_LOG_FILE}"
        retro_error "The chroot is kept for inspection; re-run ./build.sh to resume, or --clean to restart."
    fi
    exit "${rc}"
}

on_signal() {
    retro_warn "Interrupted - cleaning up mounts"
    exit 130
}

# -----------------------------------------------------------------------------
# Pre-flight
# -----------------------------------------------------------------------------
pf_warn() { PREFLIGHT_WARNINGS=$(( PREFLIGHT_WARNINGS + 1 )); retro_warn "$@"; }

first_existing() {   # first existing file among the arguments
    local f
    for f in "$@"; do
        if [[ -f "${f}" ]]; then printf '%s' "${f}"; return 0; fi
    done
    return 1
}

install_host_deps() {
    command -v apt-get >/dev/null 2>&1 || retro_die "--install-deps needs an apt-based host"
    retro_info "Installing host build dependencies"
    DEBIAN_FRONTEND=noninteractive apt-get update
    DEBIAN_FRONTEND=noninteractive apt-get install -y \
        debootstrap squashfs-tools xorriso isolinux syslinux-common syslinux-utils \
        mtools dosfstools grub-common grub-pc-bin grub-efi-amd64-bin \
        debian-archive-keyring ca-certificates python3 qemu-system-x86 ovmf
}

preflight_host() {
    retro_info "[preflight 1/5] host environment"
    require_root
    [[ "$(uname -m)" == "x86_64" ]] || retro_die "This build needs an x86_64 host (found $(uname -m))"
    [[ "${BUILD_ROOT}" != *[[:space:]]* ]] || retro_die "BUILD_ROOT must not contain whitespace: '${BUILD_ROOT}'"

    mkdir -p "${BUILD_ROOT}"
    local opts
    opts="$(findmnt -T "${BUILD_ROOT}" -no OPTIONS 2>/dev/null || true)"
    if [[ ",${opts}," == *",nodev,"* || ",${opts}," == *",noexec,"* ]]; then
        retro_die "BUILD_ROOT is on a filesystem mounted nodev/noexec (${opts}). Chroot builds need dev+exec: use another BUILD_ROOT=/path"
    fi

    local avail
    avail="$(df -BG --output=avail "${BUILD_ROOT}" | tail -n1 | tr -dc '0-9')"
    if (( ${avail:-0} < MIN_FREE_GB )); then
        retro_die "Only ${avail:-0} GB free under ${BUILD_ROOT}; need at least ${MIN_FREE_GB} GB (or set BUILD_ROOT elsewhere)"
    fi
    retro_ok "root ok, x86_64, ${avail} GB free"
}

preflight_binaries() {
    retro_info "[preflight 2/5] host binaries and boot assets"
    local missing=0 b
    for b in debootstrap mksquashfs xorriso isohybrid mcopy mmd mkfs.vfat grub-mkstandalone chroot sha256sum truncate findmnt; do
        if command -v "${b}" >/dev/null 2>&1; then
            retro_ok "found ${b}"
        else
            retro_error "missing host binary: ${b}"
            missing=1
        fi
    done

    # "findiso" is not a program: what matters is that the syslinux/ISOLINUX
    # assets exist, so locate them explicitly.
    ISOLINUX_BIN="$(first_existing /usr/lib/ISOLINUX/isolinux.bin /usr/lib/syslinux/bios/isolinux.bin /usr/share/syslinux/isolinux.bin || true)"
    ISOHDPFX="$(first_existing /usr/lib/ISOLINUX/isohdpfx.bin /usr/lib/syslinux/mbr/isohdpfx.bin /usr/share/syslinux/isohdpfx.bin || true)"
    local d
    for d in /usr/lib/syslinux/modules/bios /usr/share/syslinux /usr/lib/syslinux; do
        if [[ -f "${d}/ldlinux.c32" ]]; then SYSLINUX_MOD_DIR="${d}"; break; fi
    done
    [[ -n "${ISOLINUX_BIN}" ]]     || { retro_error "isolinux.bin not found (apt install isolinux)"; missing=1; }
    [[ -n "${ISOHDPFX}" ]]         || { retro_error "isohdpfx.bin not found (apt install isolinux)"; missing=1; }
    [[ -n "${SYSLINUX_MOD_DIR}" ]] || { retro_error "syslinux BIOS modules not found (apt install syslinux-common)"; missing=1; }
    if [[ -n "${SYSLINUX_MOD_DIR}" ]]; then
        local m
        for m in ldlinux.c32 libcom32.c32 libutil.c32 vesamenu.c32 menu.c32; do
            [[ -f "${SYSLINUX_MOD_DIR}/${m}" ]] || { retro_error "missing syslinux module ${m} in ${SYSLINUX_MOD_DIR}"; missing=1; }
        done
    fi
    [[ -f /usr/share/keyrings/debian-archive-keyring.gpg ]] \
        || { retro_error "debian-archive-keyring missing (apt install debian-archive-keyring) - needed to verify Debian packages"; missing=1; }
    [[ -d /usr/lib/grub/x86_64-efi ]] || { retro_error "grub-efi-amd64-bin missing (apt install grub-efi-amd64-bin)"; missing=1; }
    [[ -d /usr/lib/grub/i386-pc ]]    || pf_warn "grub-pc-bin missing (not required for ISOLINUX, but recommended)"
    if command -v mksquashfs >/dev/null 2>&1; then
        local sq_help
        sq_help="$(mksquashfs -help 2>&1 || true)"   # captured: no pipefail/SIGPIPE surprises
        if ! grep -qi zstd <<< "${sq_help}"; then
            retro_error "this mksquashfs has no zstd support (need squashfs-tools >= 4.4)"
            missing=1
        fi
    fi

    if (( missing )); then
        retro_die "Host is missing build requirements. Run:  sudo ./build.sh --install-deps"
    fi
}

preflight_syntax() {
    retro_info "[preflight 3/5] bash -n syntax validation"
    local f bad=0 list=()
    list+=("${SELF_DIR}/config.env" "${SELF_DIR}/build.sh")
    [[ -f "${SELF_DIR}/test_iso.sh" ]] && list+=("${SELF_DIR}/test_iso.sh")
    for f in "${SCRIPTS_DIR}"/*.sh; do
        [[ -e "${f}" ]] && list+=("${f}")
    done
    list+=("${OVERLAY_DIR}/usr/local/bin/retro")

    for f in "${list[@]}"; do
        if [[ ! -f "${f}" ]]; then
            retro_error "required file missing: ${f}"
            bad=1
            continue
        fi
        if bash -n "${f}" 2>/tmp/retro-syntax.$$; then
            retro_ok "syntax ok: ${f#"${SELF_DIR}"/}"
        else
            retro_error "SYNTAX ERROR in ${f}:"
            cat /tmp/retro-syntax.$$ >&2
            bad=1
        fi
    done
    rm -f /tmp/retro-syntax.$$

    local s
    for s in "${ALL_SCRIPTS[@]}"; do
        [[ -f "${SCRIPTS_DIR}/${s}" ]] || { retro_error "stage script missing: scripts/${s}"; bad=1; }
    done

    local py="${OVERLAY_DIR}/opt/retro-ai/retro_ai.py"
    if [[ -f "${py}" ]]; then
        if command -v python3 >/dev/null 2>&1; then
            if python3 -c 'import ast,sys; ast.parse(open(sys.argv[1]).read())' "${py}"; then
                retro_ok "syntax ok: overlay/opt/retro-ai/retro_ai.py"
            else
                retro_error "SYNTAX ERROR in ${py}"; bad=1
            fi
        else
            pf_warn "python3 not found on host - retro_ai.py syntax is verified later inside the chroot"
        fi
    else
        retro_error "required payload missing: overlay/opt/retro-ai/retro_ai.py"; bad=1
    fi

    (( bad == 0 )) || retro_die "Pre-flight syntax/asset validation failed - fix the items above"
}

seed_wallpaper() {
    local wp="${OVERLAY_DIR}/usr/share/backgrounds/retro-os/wallpaper.png"
    if [[ -s "${wp}" ]]; then
        retro_ok "wallpaper present: overlay/usr/share/backgrounds/retro-os/wallpaper.png"
        return 0
    fi
    pf_warn "wallpaper.png missing - seeding a generated fallback (drop your art at ${wp} to replace it)"
    mkdir -p "$(dirname "${wp}")"

    if command -v python3 >/dev/null 2>&1; then
        python3 - "${wp}" <<'PY'
import struct
import sys
import zlib

W, H = 1920, 1080
TOP, BOTTOM = (12, 13, 18), (20, 26, 40)
GRID, DIM_MINT, MINT = (22, 28, 38), (0, 110, 70), (0, 255, 156)
LINE_Y = int(H * 0.62)


def chunk(tag, data):
    body = tag + data
    return struct.pack(">I", len(data)) + body + struct.pack(">I", zlib.crc32(body) & 0xFFFFFFFF)


raw = bytearray()
for y in range(H):
    t = y / (H - 1)
    base = bytes(int(TOP[i] + (BOTTOM[i] - TOP[i]) * t) for i in range(3))
    row = bytearray(base * W)
    if y % 72 == 0:
        row[:] = bytes(GRID) * W
    else:
        for x in range(0, W, 72):
            row[x * 3:x * 3 + 3] = bytes(GRID)
    if abs(y - LINE_Y) <= 1:
        row[:] = bytes(DIM_MINT) * W
        for x in range(int(W * 0.38), int(W * 0.62)):
            row[x * 3:x * 3 + 3] = bytes(MINT)
    raw.append(0)
    raw.extend(row)

png = (b"\x89PNG\r\n\x1a\n"
       + chunk(b"IHDR", struct.pack(">IIBBBBB", W, H, 8, 2, 0, 0, 0))
       + chunk(b"IDAT", zlib.compress(bytes(raw), 9))
       + chunk(b"IEND", b""))
with open(sys.argv[1], "wb") as fh:
    fh.write(png)
PY
    else
        # 1x1 obsidian pixel; wallpaper_mode=stretch turns it into a solid backdrop
        base64 -d > "${wp}" <<'EOF'
iVBORw0KGgoAAAANSUhEUgAAAAEAAAABCAIAAACQd1PeAAAADElEQVR42mPg4RUCAABUACzr1UKwAAAAAElFTkSuQmCC
EOF
    fi
    [[ -s "${wp}" ]] || retro_die "could not seed fallback wallpaper at ${wp}"
    [[ "$(head -c4 "${wp}" | od -An -tx1 | tr -d ' \n')" == "89504e47" ]] || retro_die "seeded wallpaper is not a valid PNG"
    retro_ok "seeded fallback wallpaper ($(stat -c %s "${wp}") bytes)"
}

preflight_assets() {
    retro_info "[preflight 4/5] build assets"
    seed_wallpaper

    if [[ -s "${OVERLAY_DIR}/usr/share/pixmaps/retro-start.svg" || -s "${OVERLAY_DIR}/usr/share/pixmaps/retro-os-logo.png" ]]; then
        retro_ok "branding logo present in overlay"
    else
        pf_warn "no branding logo in overlay/usr/share/pixmaps/ - the built-in Start-orb SVG will be used"
    fi

    local var
    for var in DEBIAN_SUITE DEBIAN_MIRROR DEBIAN_COMPONENTS ISO_LABEL ISO_FILENAME RETRO_KARGS_COMMON SQUASHFS_ZSTD_LEVEL RETRO_USER; do
        [[ -n "${!var:-}" ]] || retro_die "config.env: ${var} is empty"
    done
    [[ "${RETRO_KARGS_COMMON}" == *"boot=live"* ]] || retro_die "config.env: RETRO_KARGS_COMMON must contain boot=live"
    [[ "${#ISO_LABEL}" -le 32 ]] || retro_die "config.env: ISO_LABEL longer than 32 characters"
}

preflight_report() {
    retro_info "[preflight 5/5] summary"
    if (( PREFLIGHT_WARNINGS > 0 )); then
        retro_warn "pre-flight passed with ${PREFLIGHT_WARNINGS} warning(s)"
    else
        retro_ok "pre-flight passed cleanly"
    fi
}

preflight() {
    preflight_host
    preflight_binaries
    preflight_syntax
    preflight_assets
    preflight_report
}

# -----------------------------------------------------------------------------
# Stamps (idempotent / resumable stages)
# -----------------------------------------------------------------------------
stage_hash() {   # <script|string>
    if [[ -f "${SCRIPTS_DIR}/$1" ]]; then
        cat "${SELF_DIR}/config.env" "${SCRIPTS_DIR}/$1" | sha256sum | awk '{print $1}'
    else
        printf '%s' "$1" | sha256sum | awk '{print $1}'
    fi
}

stamp_ok() {   # <name> <hash>
    [[ -f "${STAMP_DIR}/$1" && "$(cat "${STAMP_DIR}/$1")" == "$2" ]]
}

stamp_set() {
    mkdir -p "${STAMP_DIR}"
    printf '%s' "$2" > "${STAMP_DIR}/$1"
}

invalidate_from() {   # <stage-script>: drop its stamp and every later one
    local hit=0 s
    for s in "${CHROOT_STAGES[@]}"; do
        [[ "${s}" == "$1" ]] && hit=1
        (( hit )) && rm -f "${STAMP_DIR}/${s}"
    done
    rm -f "${STAMP_DIR}/finalized"
}

clean_previous() {
    retro_info "Cleaning previous build state"
    unmount_chroot || retro_die "cannot clean while mounts are active under ${CHROOT_DIR}"
    rm -rf "${CHROOT_DIR}" "${IMAGE_DIR}" "${ISO_DIR}" "${STAMP_DIR}"
    if (( OPT_DISTCLEAN )); then
        rm -rf "${OUT_DIR}" "${BUILD_ROOT}/logs"
        mkdir -p "${RETRO_LOG_DIR}"
    fi
    retro_ok "clean"
}

# -----------------------------------------------------------------------------
# Chroot construction
# -----------------------------------------------------------------------------
build_chroot_env() {
    CHROOT_ENV=(
        "HOME=/root"
        "TERM=${TERM:-xterm}"
        "PATH=/usr/local/sbin:/usr/local/bin:/usr/sbin:/usr/bin:/sbin:/bin"
        "LANG=C.UTF-8"
        "DEBIAN_FRONTEND=noninteractive"
        "RETRO_CONTEXT=chroot"
    )
    local v
    for v in GITHUB_TOKEN RETRO_INSTALL_FIRMWARE RETRO_INSTALL_BROWSER RETRO_INSTALL_CALAMARES \
             RETRO_SLIM_DPKG RETRO_TOOLS_CHANNEL RETRO_TOOLS_STRICT RETRO_UPDATE_URL \
             RETRO_LOW_TIER_MAX_MB DEBIAN_MIRROR DEBIAN_SECURITY_MIRROR; do
        if [[ -n "${!v:-}" ]]; then CHROOT_ENV+=("${v}=${!v}"); fi
    done
}

run_debootstrap() {
    local want
    want="$(stage_hash "bootstrap:${DEBIAN_SUITE}:${DEBIAN_MIRROR}:${DEBIAN_COMPONENTS}:${DEBIAN_ARCH}")"
    if stamp_ok bootstrap "${want}" && [[ -x "${CHROOT_DIR}/bin/bash" ]]; then
        retro_ok "debootstrap already done (stamp matches) - reusing ${CHROOT_DIR}"
        return 0
    fi

    retro_info "Running debootstrap (${DEBIAN_SUITE}, ${DEBIAN_ARCH}, minbase)"
    unmount_chroot || retro_die "stale mounts under ${CHROOT_DIR}"
    rm -rf "${CHROOT_DIR}" "${STAMP_DIR}"
    mkdir -p "${CHROOT_DIR}" "${STAMP_DIR}"

    LC_ALL=C debootstrap --arch="${DEBIAN_ARCH}" --variant=minbase \
        --components="${DEBIAN_COMPONENTS// /,}" \
        --include=ca-certificates,gnupg \
        --keyring=/usr/share/keyrings/debian-archive-keyring.gpg \
        "${DEBIAN_SUITE}" "${CHROOT_DIR}" "${DEBIAN_MIRROR}" 2>&1 | tee -a "${RETRO_LOG_FILE}"

    [[ -x "${CHROOT_DIR}/bin/bash" ]] || retro_die "debootstrap finished but ${CHROOT_DIR}/bin/bash is missing"
    stamp_set bootstrap "${want}"
    retro_ok "debootstrap complete"
}

stage_chroot_files() {
    retro_info "Staging scripts into ${CHROOT_DIR}${STAGE_DIR_IN_CHROOT}"
    rm -rf "${CHROOT_DIR}${STAGE_DIR_IN_CHROOT}"
    mkdir -p "${CHROOT_DIR}${STAGE_DIR_IN_CHROOT}"
    install -m 0644 "${SELF_DIR}/config.env" "${CHROOT_DIR}${STAGE_DIR_IN_CHROOT}/config.env"
    local s
    for s in "${ALL_SCRIPTS[@]}"; do
        install -m 0755 "${SCRIPTS_DIR}/${s}" "${CHROOT_DIR}${STAGE_DIR_IN_CHROOT}/${s}"
    done

    if [[ -s /etc/resolv.conf ]]; then
        cp -L /etc/resolv.conf "${CHROOT_DIR}/etc/resolv.conf"
    else
        printf 'nameserver 1.1.1.1\nnameserver 9.9.9.9\n' > "${CHROOT_DIR}/etc/resolv.conf"
    fi
}

prepare_chroot_for_scripts() {
    # A resumed chroot was already finalized once: finalize removes policy-rc.d
    # and the apt lists, which later stages (02-04) need again.
    if [[ ! -e "${CHROOT_DIR}/usr/sbin/policy-rc.d" ]]; then
        printf '#!/bin/sh\nexit 101\n' > "${CHROOT_DIR}/usr/sbin/policy-rc.d"
        chmod 0755 "${CHROOT_DIR}/usr/sbin/policy-rc.d"
    fi
    if ! ls "${CHROOT_DIR}"/var/lib/apt/lists/*Packages* >/dev/null 2>&1 && [[ -f "${CHROOT_DIR}/etc/apt/sources.list" ]]; then
        retro_info "Refreshing apt lists inside the chroot (resume)"
        run_chroot_cmd /usr/bin/apt-get update
    fi
}

run_chroot_cmd() {
    chroot "${CHROOT_DIR}" /usr/bin/env -i "${CHROOT_ENV[@]}" "$@" 2>&1 | tee -a "${RETRO_LOG_FILE}"
}

run_chroot_script() {   # <script-name>
    # Callers use `||` / `if !`, which disables errexit inside this function,
    # so the chroot exit status must be propagated explicitly.
    local script="$1" t0 t1
    retro_info ">>> chroot: ${script}"
    t0="$(date +%s)"
    if ! run_chroot_cmd /bin/bash "${STAGE_DIR_IN_CHROOT}/${script}"; then
        retro_error "<<< ${script} exited with an error"
        return 1
    fi
    t1="$(date +%s)"
    retro_ok "<<< ${script} finished in $(( t1 - t0 ))s"
}

apply_overlay() {   # <label>
    retro_info "Overlay pass (${1}): ${OVERLAY_DIR} -> chroot"
    [[ -d "${OVERLAY_DIR}" ]] || retro_die "overlay directory missing: ${OVERLAY_DIR}"
    # Ownership is deliberately NOT preserved: host UIDs (often 1000) would
    # otherwise collide with the in-image user 'retro'.
    cp -a --no-preserve=ownership "${OVERLAY_DIR}/." "${CHROOT_DIR}/"
    chown -R root:root "${CHROOT_DIR}/usr/local/bin" "${CHROOT_DIR}/opt" 2>/dev/null || true
    chmod 0755 "${CHROOT_DIR}/usr/local/bin/retro" "${CHROOT_DIR}/opt/retro-ai/retro_ai.py"
}

run_stage_pipeline() {
    mount_virtfs
    build_chroot_env
    stage_chroot_files
    prepare_chroot_for_scripts

    # Payload pass: 03 needs /usr/local/bin/retro and /opt/retro-ai/retro_ai.py
    # on disk before it installs the watchdog service.
    apply_overlay "payload"

    local s want
    for s in "${CHROOT_STAGES[@]}"; do
        want="$(stage_hash "${s}")"
        if stamp_ok "${s}" "${want}"; then
            retro_ok "stage ${s} already done (stamp matches) - skipping"
            continue
        fi
        invalidate_from "${s}"
        run_chroot_script "${s}" || retro_die "stage ${s} failed - see ${RETRO_LOG_FILE}"
        stamp_set "${s}" "${want}"
    done

    # Final overlay pass: project files win over anything the scripts generated.
    apply_overlay "final"

    run_chroot_script 98_finalize.sh || retro_die "98_finalize.sh failed - see ${RETRO_LOG_FILE}"

    retro_info "Running in-chroot self-test gate (99_selftest.sh)"
    if ! run_chroot_script 99_selftest.sh; then
        retro_error "IN-CHROOT SELF-TEST FAILED - refusing to build a broken ISO."
        retro_error "Read the 'SELFTEST: FAIL ... -> fix:' lines above or in ${RETRO_LOG_FILE}."
        retro_error "After fixing, re-run ./build.sh (completed stages are skipped)."
        exit 1
    fi
    stamp_set finalized "$(stage_hash 99_selftest.sh)"

    # Leave a pristine chroot behind
    rm -rf "${CHROOT_DIR}${STAGE_DIR_IN_CHROOT}"
    : > "${CHROOT_DIR}/etc/resolv.conf"
    find "${CHROOT_DIR}/var/log" -type f -exec truncate -s 0 {} + 2>/dev/null || true
    find "${CHROOT_DIR}/tmp" -mindepth 1 -delete 2>/dev/null || true

    unmount_chroot || retro_die "could not unmount the chroot cleanly"
    retro_ok "chroot unmounted"
}

# -----------------------------------------------------------------------------
# ISO packaging
# -----------------------------------------------------------------------------
assert_chroot_quiet() {
    if [[ -n "$(chroot_mounts)" ]]; then
        retro_die "mounts are still active under ${CHROOT_DIR}; squashfs would swallow host /dev,/proc. Aborting."
    fi
    [[ -f "${STAMP_DIR}/finalized" ]] || retro_die "chroot has no passing self-test stamp - run ./build.sh without --skip-chroot first"
}

build_squashfs() {
    assert_chroot_quiet
    retro_info "Compressing chroot into filesystem.squashfs (zstd level ${SQUASHFS_ZSTD_LEVEL})"
    rm -rf "${IMAGE_DIR}"
    mkdir -p "${IMAGE_DIR}/live" "${IMAGE_DIR}/isolinux" "${IMAGE_DIR}/boot/grub" "${IMAGE_DIR}/EFI/BOOT" "${IMAGE_DIR}/.disk"

    # The kernel/initrd stay inside the squashfs on purpose: the Calamares
    # installer copies the squashfs to disk and the target needs /boot/vmlinuz.
    mksquashfs "${CHROOT_DIR}" "${IMAGE_DIR}/live/filesystem.squashfs" \
        -noappend -comp zstd -Xcompression-level "${SQUASHFS_ZSTD_LEVEL}" -b 1M \
        -processors "$(nproc)" -no-progress \
        -wildcards -e 'proc/*' 'sys/*' 'dev/*' 'run/*' 'tmp/*' 2>&1 | tee -a "${RETRO_LOG_FILE}"
    [[ -s "${IMAGE_DIR}/live/filesystem.squashfs" ]] || retro_die "mksquashfs produced no output"
    retro_ok "squashfs: $(du -h "${IMAGE_DIR}/live/filesystem.squashfs" | cut -f1)"
}

stage_kernel() {
    retro_info "Copying kernel + initramfs from the chroot"
    local kernel version initrd
    kernel="$(find "${CHROOT_DIR}/boot" -maxdepth 1 -name 'vmlinuz-*' | sort -V | tail -n1)"
    [[ -n "${kernel}" ]] || retro_die "no vmlinuz-* in ${CHROOT_DIR}/boot"
    version="${kernel##*/vmlinuz-}"
    initrd="${CHROOT_DIR}/boot/initrd.img-${version}"
    [[ -s "${kernel}" ]] || retro_die "kernel image is empty: ${kernel}"
    [[ -s "${initrd}" ]] || retro_die "initramfs missing/empty for ${version}: ${initrd}"
    cp -f "${kernel}" "${IMAGE_DIR}/live/vmlinuz"
    cp -f "${initrd}" "${IMAGE_DIR}/live/initrd.img"
    retro_ok "kernel ${version} ($(du -h "${IMAGE_DIR}/live/vmlinuz" | cut -f1)), initrd ($(du -h "${IMAGE_DIR}/live/initrd.img" | cut -f1))"
}

write_isolinux() {
    retro_info "Preparing BIOS boot (ISOLINUX)"
    local mod
    cp -f "${ISOLINUX_BIN}" "${IMAGE_DIR}/isolinux/isolinux.bin"
    for mod in ldlinux.c32 libcom32.c32 libutil.c32 vesamenu.c32 menu.c32; do
        cp -f "${SYSLINUX_MOD_DIR}/${mod}" "${IMAGE_DIR}/isolinux/${mod}"
    done

    local args="${RETRO_KARGS_COMMON}"
    cat > "${IMAGE_DIR}/isolinux/isolinux.cfg" <<EOF
UI vesamenu.c32
DEFAULT live
PROMPT 0
TIMEOUT 80
MENU TITLE ${RETRO_OS_NAME} ${RETRO_OS_VERSION} (${RETRO_OS_EDITION}) - Founder: ${RETRO_FOUNDER}

MENU COLOR screen      0 #ffe0e0e0 #ff0c0d12 std
MENU COLOR border      0 #ff00ff9c #ff0c0d12 std
MENU COLOR title       1 #ff00ff9c #ff0c0d12 std
MENU COLOR sel         7 #ff0c0d12 #ff00ff9c std
MENU COLOR unsel       0 #ffe0e0e0 #ff0c0d12 std
MENU COLOR help        0 #ff8a8f98 #ff0c0d12 std
MENU COLOR timeout_msg 0 #ff8a8f98 #ff0c0d12 std
MENU COLOR timeout     0 #ff00ff9c #ff0c0d12 std
MENU COLOR tabmsg      0 #ff8a8f98 #ff0c0d12 std
MENU COLOR cmdmark     0 #ff00ff9c #ff0c0d12 std
MENU COLOR cmdline     0 #ffe0e0e0 #ff0c0d12 std

LABEL live
  MENU LABEL ^Retro OS Live
  KERNEL /live/vmlinuz
  APPEND initrd=/live/initrd.img ${args} quiet

LABEL low
  MENU LABEL Retro OS Live - ^Low-spec / legacy hardware (force low tier)
  KERNEL /live/vmlinuz
  APPEND initrd=/live/initrd.img ${args} retro.tier=low noresume udev.children_max=2 quiet

LABEL safe
  MENU LABEL Retro OS Live - ^Safe graphics (nomodeset, no APIC/ACPI)
  KERNEL /live/vmlinuz
  APPEND initrd=/live/initrd.img ${args} nomodeset noapic acpi=off

LABEL install
  MENU LABEL ^Install Retro OS to disk (Calamares)
  KERNEL /live/vmlinuz
  APPEND initrd=/live/initrd.img ${args} retro.install=1 quiet

LABEL report
  MENU LABEL ^Debug & Health Report (serial console + boot report)
  KERNEL /live/vmlinuz
  APPEND initrd=/live/initrd.img ${args} retro.report=1 console=tty0 console=ttyS0,115200n8 loglevel=6 systemd.show_status=1
EOF
}

write_grub_cfg() {
    retro_info "Writing GRUB configuration (UEFI)"
    local args="${RETRO_KARGS_COMMON}"
    cat > "${IMAGE_DIR}/boot/grub/grub.cfg" <<EOF
# ${RETRO_OS_NAME} ${RETRO_OS_VERSION} - GRUB menu (UEFI). Parameters mirror isolinux.cfg.
search --no-floppy --set=root --file /live/vmlinuz
insmod all_video
set default="live"
set timeout=8
set menu_color_normal=light-gray/black
set menu_color_highlight=black/light-green

menuentry "Retro OS Live" --id live {
    linux /live/vmlinuz ${args} quiet
    initrd /live/initrd.img
}

menuentry "Retro OS Live - Low-spec / legacy hardware (force low tier)" --id low {
    linux /live/vmlinuz ${args} retro.tier=low noresume udev.children_max=2 quiet
    initrd /live/initrd.img
}

menuentry "Retro OS Live - Safe graphics (nomodeset, no APIC/ACPI)" --id safe {
    linux /live/vmlinuz ${args} nomodeset noapic acpi=off
    initrd /live/initrd.img
}

menuentry "Install Retro OS to disk (Calamares)" --id install {
    linux /live/vmlinuz ${args} retro.install=1 quiet
    initrd /live/initrd.img
}

menuentry "Debug & Health Report (serial console + boot report)" --id report {
    linux /live/vmlinuz ${args} retro.report=1 console=tty0 console=ttyS0,115200n8 loglevel=6 systemd.show_status=1
    initrd /live/initrd.img
}
EOF
}

build_efi_images() {
    retro_info "Building standalone GRUB EFI image + FAT boot image (efi.img)"
    local work efi_size_mb
    work="$(mktemp -d)"

    # Embedded config: locate the ISO by a file that only exists on it, then
    # hand over to the real grub.cfg on the ISO.
    cat > "${work}/embedded.cfg" <<'EOF'
search --no-floppy --set=root --file /live/vmlinuz
set prefix=($root)/boot/grub
configfile /boot/grub/grub.cfg
EOF

    grub-mkstandalone --format=x86_64-efi --output="${work}/bootx64.efi" \
        --locales="" --fonts="" "boot/grub/grub.cfg=${work}/embedded.cfg" 2>&1 | tee -a "${RETRO_LOG_FILE}"
    [[ -s "${work}/bootx64.efi" ]] || retro_die "grub-mkstandalone produced no bootx64.efi"

    efi_size_mb=$(( ( $(stat -c %s "${work}/bootx64.efi") / 1048576 ) + 10 ))
    (( efi_size_mb >= 16 )) || efi_size_mb=16

    local img="${IMAGE_DIR}/boot/grub/efi.img"
    rm -f "${img}"
    truncate -s "${efi_size_mb}M" "${img}"
    mkfs.vfat -F 16 -n RETRO_EFI "${img}" >/dev/null
    mmd -i "${img}" ::EFI ::EFI/BOOT
    mcopy -i "${img}" "${work}/bootx64.efi" ::EFI/BOOT/BOOTX64.EFI

    # Same loader directly on the ISO9660 side (some firmwares read it there)
    cp -f "${work}/bootx64.efi" "${IMAGE_DIR}/EFI/BOOT/BOOTX64.EFI"
    rm -rf "${work}"
    retro_ok "efi.img ${efi_size_mb} MiB"
}

write_disk_info() {
    printf '%s %s (%s) - built %s\n' "${RETRO_OS_NAME}" "${RETRO_OS_VERSION}" "${RETRO_OS_EDITION}" "$(date -u +%FT%TZ)" > "${IMAGE_DIR}/.disk/info"
    : > "${IMAGE_DIR}/.disk/base_installable"
}

iso_has_gpt() {   # GPT header lives at LBA 1
    [[ "$(dd if="$1" bs=512 skip=1 count=1 2>/dev/null | head -c8)" == "EFI PART" ]]
}

iso_boot_entries_ok() {
    local rep
    rep="$(xorriso -indev "$1" -report_el_torito plain 2>&1 || true)"
    grep -q 'BIOS' <<< "${rep}" && grep -q 'UEFI' <<< "${rep}"
}

build_iso() {
    mkdir -p "${OUT_DIR}"
    local iso="${OUT_DIR}/${ISO_FILENAME}"
    rm -f "${iso}" "${iso}.sha256"
    retro_info "Packing hybrid ISO with xorriso -> ${iso}"

    xorriso -as mkisofs \
        -iso-level 3 -full-iso9660-filenames -joliet -joliet-long -rational-rock \
        -volid "${ISO_LABEL}" -appid "${RETRO_OS_NAME} ${RETRO_OS_VERSION}" -publisher "${RETRO_FOUNDER}" \
        -eltorito-boot isolinux/isolinux.bin -eltorito-catalog isolinux/boot.cat \
        -no-emul-boot -boot-load-size 4 -boot-info-table \
        -isohybrid-mbr "${ISOHDPFX}" \
        -eltorito-alt-boot -e boot/grub/efi.img -no-emul-boot -isohybrid-gpt-basdat \
        -output "${iso}" "${IMAGE_DIR}" 2>&1 | tee -a "${RETRO_LOG_FILE}"

    [[ -s "${iso}" ]] || retro_die "xorriso produced no ISO"
    iso_boot_entries_ok "${iso}" || retro_die "ISO is missing a BIOS or UEFI El Torito entry (xorriso report below)"
    iso_has_gpt "${iso}" || retro_warn "no GPT header found in the ISO - USB booting on UEFI may require a plain-ISO (CD/VM) boot"
    retro_ok "xorriso ISO ok: BIOS + UEFI El Torito entries present"
}

post_isohybrid() {
    local iso="${OUT_DIR}/${ISO_FILENAME}" tmp
    if ! command -v isohybrid >/dev/null 2>&1; then
        retro_warn "isohybrid not installed - keeping the xorriso hybrid image as is"
        return 0
    fi
    tmp="${iso}.isohybrid.tmp"
    cp -f "${iso}" "${tmp}"
    retro_info "Post-processing with: isohybrid --uefi (guarded: result is validated, original kept on any doubt)"
    if isohybrid --uefi "${tmp}" >>"${RETRO_LOG_FILE}" 2>&1 \
       && [[ "$(dd if="${tmp}" bs=1 skip=510 count=2 2>/dev/null | od -An -tx1 | tr -d ' \n')" == "55aa" ]] \
       && iso_boot_entries_ok "${tmp}" \
       && iso_has_gpt "${tmp}"; then
        mv -f "${tmp}" "${iso}"
        retro_ok "isohybrid --uefi applied and validated (MBR 55AA, GPT, BIOS+UEFI entries intact)"
    else
        rm -f "${tmp}"
        retro_warn "isohybrid --uefi would have damaged the boot structures - kept the xorriso original"
    fi
}

write_checksum() {
    local iso="${OUT_DIR}/${ISO_FILENAME}"
    ( cd "${OUT_DIR}" && sha256sum "${ISO_FILENAME}" > "${ISO_FILENAME}.sha256" )
    retro_ok "sha256: $(cut -d' ' -f1 "${iso}.sha256")"
}

print_summary() {
    local iso="${OUT_DIR}/${ISO_FILENAME}" secs
    secs=$(( $(date +%s) - BUILD_START ))
    printf '\n%s================ BUILD COMPLETE ================%s\n' "${C_GREEN}" "${C_RESET}"
    printf '  ISO      : %s (%s)\n' "${iso}" "$(du -h "${iso}" | cut -f1)"
    printf '  SHA-256  : %s.sha256\n' "${iso}"
    printf '  Elapsed  : %dm%02ds\n' $(( secs / 60 )) $(( secs % 60 ))
    printf '  Log      : %s\n' "${RETRO_LOG_FILE}"
    printf '  Test     : ./test_iso.sh --bios --uefi --report\n'
    printf '  USB      : sudo dd if=%s of=/dev/sdX bs=4M status=progress oflag=sync\n\n' "${iso}"
}

# -----------------------------------------------------------------------------
# main
# -----------------------------------------------------------------------------
main() {
    parse_args "$@"
    require_root
    mkdir -p "${RETRO_LOG_DIR}"
    trap on_exit EXIT
    trap on_signal INT TERM

    if (( OPT_INSTALL_DEPS )); then install_host_deps; fi
    preflight
    if (( OPT_PREFLIGHT_ONLY )); then
        retro_ok "--preflight-only: stopping here"
        return 0
    fi

    if (( OPT_CLEAN )); then clean_previous; fi
    mkdir -p "${BUILD_ROOT}" "${STAMP_DIR}" "${OUT_DIR}"

    if (( OPT_SKIP_CHROOT )); then
        retro_info "--skip-chroot: reusing existing chroot"
    else
        run_debootstrap
        run_stage_pipeline
    fi

    build_squashfs
    stage_kernel
    write_isolinux
    write_grub_cfg
    build_efi_images
    write_disk_info
    build_iso
    post_isohybrid
    write_checksum
    print_summary
}

if [[ "${BASH_SOURCE[0]}" == "${0}" ]]; then
    main "$@"
fi

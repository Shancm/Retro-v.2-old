#!/usr/bin/env bash
# =============================================================================
# Retro OS v2.0 - 03_modules_setup.sh   (runs as root INSIDE the build chroot)
#
#   * classic auditing tools (apt)
#   * modern Go/Rust binaries staged into /usr/local/bin via retro-fetch-tools
#   * Retro AI daemon service (payload: /opt/retro-ai/retro_ai.py from overlay)
#   * boot health reporter used by test_iso.sh
#   * final menu regeneration
# =============================================================================
set -Eeuo pipefail

SELF_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
# shellcheck source=/dev/null
source "${SELF_DIR}/config.env"
retro_enable_traps "03_modules_setup.sh"
retro_require_chroot

export DEBIAN_FRONTEND=noninteractive LC_ALL=C LANG=C

# -----------------------------------------------------------------------------
# 1. Classic tools
# -----------------------------------------------------------------------------
install_classic_tools() {
    retro_info "Preseeding wireshark-common (non-root capture via group 'wireshark')"
    echo "wireshark-common wireshark-common/install-setuid boolean true" | debconf-set-selections

    retro_info "Installing classic auditing tools (CLI + GUI)"
    retro_apt_install \
        nmap wireshark tshark aircrack-ng hydra john nikto sqlmap wifite ffuf \
        tcpdump netcat-openbsd dnsutils whois traceroute libpcap0.8 iw

    # John the Ripper CLI is mandatory; GUI tools and ffuf are optional.
    retro_apt_install_optional john-data johnny

    # Hydra GUI (XHydra) & Nmap GUI (NmapSI4) & Gufw Firewall
    retro_apt_install_optional xhydra nmapsi4 gufw etherape

    # /usr/sbin/john സിംലിങ്ക്
    if [[ -x /usr/sbin/john ]]; then
        ln -sf /usr/sbin/john /usr/local/bin/john
    fi

    # Rockyou / Wordlists സജ്ജീകരണം
    retro_info "Setting up security wordlists (rockyou)"
    retro_apt_install_optional wordlists
    if [[ -f /usr/share/wordlists/rockyou.txt.gz ]] && [[ ! -f /usr/share/wordlists/rockyou.txt ]]; then
        gzip -dc /usr/share/wordlists/rockyou.txt.gz > /usr/share/wordlists/rockyou.txt || true
    fi

    getent group wireshark >/dev/null || groupadd --system wireshark
    usermod -aG wireshark "${RETRO_USER}"
}

# -----------------------------------------------------------------------------
# 2. Modern Go/Rust tools: standalone fetcher (also used by `retro update --tools`)
# -----------------------------------------------------------------------------
write_fetcher() {
    retro_info "Installing retro-fetch-tools"
    retro_write "${RETRO_ETC_DIR}/tools.conf" 0644 <<EOF
# Retro OS modern tool staging (read by retro-fetch-tools)
RETRO_TOOLS_CHANNEL="${RETRO_TOOLS_CHANNEL}"
RETRO_TOOLS_STRICT="${RETRO_TOOLS_STRICT}"
RETRO_PIN_RUSTSCAN="${RETRO_PIN_RUSTSCAN}"
RETRO_PIN_FFUF="${RETRO_PIN_FFUF}"
RETRO_PIN_HTTPX="${RETRO_PIN_HTTPX}"
RETRO_PIN_HTTPX_SHA256="${RETRO_PIN_HTTPX_SHA256}"
RETRO_PIN_NAABU="${RETRO_PIN_NAABU}"
RETRO_PIN_NAABU_SHA256="${RETRO_PIN_NAABU_SHA256}"
EOF

    retro_write "${RETRO_HELPER_DIR}/retro-fetch-tools" 0755 <<'EOF'
#!/usr/bin/env bash
set -Eeuo pipefail
CONF="/etc/retro-os/tools.conf"
if [[ -r "$CONF" ]]; then
    # shellcheck source=/dev/null
    source "$CONF"
fi
STRICT="${RETRO_TOOLS_STRICT:-1}"
DEST="${RETRO_TOOLS_DEST:-/usr/local/bin}"
MANIFEST="${RETRO_TOOLS_MANIFEST:-/etc/retro-os/modern-tools.manifest}"
ALL_TOOLS=(rustscan httpx naabu)
BUILD_DEPS_TO_PURGE=()
log()  { printf '[retro-fetch-tools] %s\n' "$*"; }
warn() { printf '[retro-fetch-tools] WARN: %s\n' "$*" >&2; }
die()  { printf '[retro-fetch-tools] ERROR: %s\n' "$*" >&2; }

record_manifest() {
    local name="$1"
    mkdir -p "$(dirname "$MANIFEST")"
    touch "$MANIFEST"
    grep -v "^${name}|" "$MANIFEST" > "${MANIFEST}.tmp" || true
    printf '%s|%s|%s|%s|%s|%s\n' "$@" "$(date -u +%FT%TZ)" >> "${MANIFEST}.tmp"
    mv -f "${MANIFEST}.tmp" "$MANIFEST"
    chmod 0644 "$MANIFEST"
}
cleanup_build_deps() {
    if (( ${#BUILD_DEPS_TO_PURGE[@]} > 0 )); then
        apt-get purge -y "${BUILD_DEPS_TO_PURGE[@]}" >/dev/null 2>&1 || true
    fi
}
trap cleanup_build_deps EXIT

ensure_cargo() {
    local before after install_rc=0
    before="$(mktemp)"
    after="$(mktemp)"
    dpkg-query -W -f='${binary:Package}\n' | sort > "$before"
    apt-get update -qq || { rm -f "$before" "$after"; return 1; }
    apt-get install -y --no-install-recommends cargo rustc build-essential || install_rc=$?
    dpkg-query -W -f='${binary:Package}\n' | sort > "$after"
    mapfile -t BUILD_DEPS_TO_PURGE < <(comm -13 "$before" "$after")
    rm -f "$before" "$after"
    (( install_rc == 0 )) || return 1
    command -v cargo >/dev/null 2>&1 && command -v rustc >/dev/null 2>&1
}
tool_meta() {
    case "$1" in
        rustscan) BIN="rustscan"; PIN="${RETRO_PIN_RUSTSCAN:-2.4.1}"; METHOD="cargo" ;;
        httpx)
            BIN="httpx"; PIN="${RETRO_PIN_HTTPX:-1.12.0}"
            EXPECTED_SHA256="${RETRO_PIN_HTTPX_SHA256:-}"
            REPO="projectdiscovery/httpx"; ASSET="httpx_${PIN}_linux_amd64.zip"; METHOD="github-release" ;;
        naabu)
            BIN="naabu"; PIN="${RETRO_PIN_NAABU:-2.3.1}"
            EXPECTED_SHA256="${RETRO_PIN_NAABU_SHA256:-}"
            REPO="projectdiscovery/naabu"; ASSET="naabu_${PIN}_linux_amd64.zip"; METHOD="github-release" ;;
        *) return 1 ;;
    esac
}
is_elf() {
    [[ "$(head -c4 "$1" 2>/dev/null | od -An -tx1 | tr -d ' \n')" == "7f454c46" ]]
}

verify_pinned_sha256() {
    local file="$1" expected="$2" actual
    [[ -s "$file" && "$expected" =~ ^[0-9a-f]{64}$ ]] || return 2
    actual="$(sha256sum "$file" | awk '{print $1}')"
    [[ "$actual" == "$expected" ]]
}
build_rustscan() {
    local work="$1" bin
    ensure_cargo || { die "could not install temporary Rust build dependencies"; return 1; }
    log "rustscan: building pinned crates.io package $PIN using Cargo registry checksums"
    if ! CARGO_HOME="$work/cargo-home" CARGO_TARGET_DIR="$work/cargo-target" \
        cargo install --locked --version "$PIN" --root "$work/install" rustscan; then
        die "Cargo build failed for pinned RustScan $PIN"; return 1
    fi
    bin="$work/install/bin/rustscan"
    [[ -x "$bin" ]] || { die "Cargo did not produce rustscan"; return 1; }
    "$bin" --version 2>&1 | grep -F "$PIN" >/dev/null \
        || { die "RustScan binary version does not match pin $PIN"; return 1; }
    install -D -m 0755 -o root -g root "$bin" "$DEST/.rustscan.new" || return 1
    mv -f "$DEST/.rustscan.new" "$DEST/rustscan"
    record_manifest rustscan "$PIN" "crates.io/cargo" "$(sha256sum "$DEST/rustscan" | awk '{print $1}')" "verified-cargo-lock"
    log "rustscan: installed pinned Cargo build $PIN"
}
release_asset_info() {
    python3 - "$1" "$2" "$3" <<'PY'
import json, sys
path, expected_tag, asset_name = sys.argv[1:]
with open(path, encoding="utf-8") as stream:
    release = json.load(stream)
if release.get("tag_name") != expected_tag:
    raise SystemExit("release tag does not match the pinned version")
matches = [a for a in release.get("assets", []) if a.get("name") == asset_name]
if len(matches) != 1:
    raise SystemExit("pinned asset is missing or duplicated")
asset = matches[0]
digest = asset.get("digest") or ""
url = asset.get("browser_download_url") or ""
if not digest.startswith("sha256:") or not url.startswith("https://"):
    raise SystemExit("GitHub did not provide an HTTPS asset URL and SHA-256 digest")
print(url)
print(digest)
PY
}
stage_release_binary() {
    local name="$1" work="$2" tag json info url remote_digest actual bin
    [[ "$EXPECTED_SHA256" =~ ^[0-9a-f]{64}$ ]] \
        || { die "$name has no valid repository-pinned SHA-256"; return 2; }
    tag="v$PIN"; json="$work/release.json"
    if ! curl -fsSL --retry 3 --connect-timeout 15 --max-time 60 \
        -H "Accept: application/vnd.github+json" -H "User-Agent: retro-os-fetch-tools" \
        "https://api.github.com/repos/$REPO/releases/tags/$tag" -o "$json"; then
        die "$name: pinned GitHub release metadata could not be fetched"; return 1
    fi
    if ! info="$(release_asset_info "$json" "$tag" "$ASSET")"; then
        die "$name: pinned release asset metadata is invalid"; return 2
    fi
    url="$(sed -n '1p' <<< "$info")"
    remote_digest="$(sed -n '2p' <<< "$info")"
    [[ "$remote_digest" == "sha256:$EXPECTED_SHA256" ]] \
        || { die "$name: GitHub release digest differs from repository pin"; return 2; }
    log "$name: downloading $tag/$ASSET"
    if ! curl -fsSL --retry 3 --retry-delay 2 --connect-timeout 15 --max-time 600 -o "$work/$ASSET" "$url"; then
        die "$name: pinned asset download failed"; return 1
    fi
    if ! verify_pinned_sha256 "$work/$ASSET" "$EXPECTED_SHA256"; then
        die "$name: downloaded bytes do not match repository-pinned SHA-256"
        return 2
    fi
    actual="$(sha256sum "$work/$ASSET" | awk '{print $1}')"
    mkdir -p "$work/unpack"
    if ! unzip -q "$work/$ASSET" -d "$work/unpack"; then
        die "$name: release archive extraction failed"; return 1
    fi
    bin="$(find "$work/unpack" -type f -name "$BIN" -print -quit)"
    if [[ -z "$bin" || ! -f "$bin" ]] || ! is_elf "$bin"; then
        die "$name: archive did not contain expected ELF executable"
        return 1
    fi
    install -D -m 0755 -o root -g root "$bin" "$DEST/.$BIN.new" || return 1
    mv -f "$DEST/.$BIN.new" "$DEST/$BIN"
    record_manifest "$name" "$tag" "$ASSET" "$actual" "verified-repository-pin"
    log "$name: installed $tag (repository-pinned SHA-256 verified)"
}
stage_tool() {
    local name="$1" work="$2"
    tool_meta "$name" || { warn "unknown tool: $name"; return 2; }
    if [[ "$METHOD" == cargo ]]; then
        build_rustscan "$work"; return $?
    fi
    stage_release_binary "$name" "$work"; return $?
}
main() {
    local -a wanted=()
    local arg tool rc failed=0 work
    for arg in "$@"; do
        case "$arg" in
            --all) wanted=("${ALL_TOOLS[@]}") ;;
            --strict) STRICT=1 ;;
            --list)
                [[ -r "$MANIFEST" ]] && cat "$MANIFEST" || echo "no tools staged yet"
                return 0 ;;
            -h|--help)
                echo "usage: retro-fetch-tools {--all | rustscan httpx naabu} [--strict] | --list"
                return 0 ;;
            *) wanted+=("$arg") ;;
        esac
    done
    (( ${#wanted[@]} > 0 )) || wanted=("${ALL_TOOLS[@]}")
    for tool in "${wanted[@]}"; do
        work="$(mktemp -d)"
        if stage_tool "$tool" "$work"; then
            rm -rf "$work"
        else
            rc=$?; failed=$((failed + 1))
            record_manifest "$tool" "-" "-" "-" "FAILED"
            rm -rf "$work"
            if (( rc == 2 )); then
                warn "$tool: security verification failed; stopping"
                return 1
            fi
        fi
    done
    if (( failed > 0 )); then
        warn "$failed tool(s) could not be installed"
        (( STRICT == 0 )) || return 1
    fi
    return 0
}
if [[ "${BASH_SOURCE[0]}" == "$0" ]]; then main "$@"; fi
EOF
}

stage_modern_tools() {
    retro_info "Staging RustScan, ProjectDiscovery httpx and Naabu with pinned verification"
    if ! "${RETRO_HELPER_DIR}/retro-fetch-tools" --all --strict; then
        retro_die "Required RustScan/httpx/Naabu verification or installation failed"
    fi
    command -v ffuf >/dev/null 2>&1 || retro_die "ffuf must be installed from the signed Debian Trixie archive"
    retro_ok "ffuf provided by the signed Debian APT archive"
    cat "${RETRO_ETC_DIR}/modern-tools.manifest" 2>/dev/null || true
}
# -----------------------------------------------------------------------------
# 3. Retro AI daemon
# -----------------------------------------------------------------------------
install_retro_ai() {
    retro_info "Installing Retro AI daemon service"
    [[ -s "${RETRO_AI_DIR}/retro_ai.py" ]] \
        || retro_die "${RETRO_AI_DIR}/retro_ai.py is missing - the overlay payload was not applied (check overlay/opt/retro-ai/)"
    chmod 0755 "${RETRO_AI_DIR}/retro_ai.py"
    python3 -m py_compile "${RETRO_AI_DIR}/retro_ai.py" \
        || retro_die "retro_ai.py has a Python syntax error"
    find "${RETRO_AI_DIR}" -name '__pycache__' -type d -prune -exec rm -rf {} +

    retro_write "${RETRO_ETC_DIR}/retro-ai.conf" 0644 <<'EOF'
[watch]
# seconds between samples
interval = 30
# alert when used RAM (MemTotal-MemAvailable) reaches these percentages
ram_warn = 85
ram_crit = 92
# alert when free space on / drops below these percentages
disk_warn_free = 10
disk_crit_free = 5
# repeat an unchanged alert at most every N seconds
cooldown = 300
# speak alerts with espeak-ng (needs a sound card)
voice = true
voice_speed = 150
EOF

    retro_write /etc/systemd/system/retro-ai-watchdog.service 0644 <<'EOF'
[Unit]
Description=Retro AI watchdog (RAM / disk monitor with optional voice alerts)
After=multi-user.target retro-hwprofile.service

[Service]
Type=simple
ExecStart=/usr/bin/python3 /opt/retro-ai/retro_ai.py watch
Restart=on-failure
RestartSec=10
Nice=10
CPUQuota=10%
MemoryMax=48M
RuntimeDirectory=retro-ai
NoNewPrivileges=true
PrivateTmp=true
ProtectHome=true

[Install]
WantedBy=multi-user.target
EOF
    systemctl enable retro-ai-watchdog.service
}

# -----------------------------------------------------------------------------
# 4. Boot health reporter (consumed by test_iso.sh via the serial console)
# -----------------------------------------------------------------------------
install_boot_report() {
    retro_info "Installing retro-boot-report (enabled with kernel arg retro.report=1)"
    retro_write "${RETRO_HELPER_DIR}/retro-boot-report" 0755 <<'EOF'
#!/usr/bin/env bash
# retro-boot-report - prints machine-parsable health markers to the console.
# Lines look like:  RETRO_TEST: KEY=value     (consumed by test_iso.sh)
set -u
mark() { printf 'RETRO_TEST: %s=%s\n' "$1" "$2"; }
yn()   { if "$@" >/dev/null 2>&1; then echo yes; else echo no; fi; }

echo "RETRO_REPORT_BEGIN"
mark KERNEL "$(uname -r)"
mark SYSTEM_STATE "$(systemctl is-system-running 2>/dev/null || true)"
# shellcheck source=/dev/null
[[ -r /run/retro-os/profile.env ]] && . /run/retro-os/profile.env
mark TIER "${RETRO_TIER:-unknown}"
mark RAM_MB "${RETRO_RAM_MB:-unknown}"
mark MEM_AVAILABLE_MB "$(awk '/^MemAvailable:/ {print int($2 / 1024)}' /proc/meminfo 2>/dev/null)"
mark ZRAM "$(swapon --noheadings --show=NAME 2>/dev/null | grep -c '^/dev/zram' || true)"
mark ZRAM_SIZE_MB "$(awk '{print int($1 / 1048576)}' /sys/block/zram0/disksize 2>/dev/null)"
mark ZRAM_ALGO "$(awk '{for (i=1; i<=NF; i++) if (substr($i,1,1)=="[" && substr($i,length($i),1)=="]") {print substr($i,2,length($i)-2); exit}}' /sys/block/zram0/comp_algorithm 2>/dev/null)"
mark SWAPPINESS "$(cat /proc/sys/vm/swappiness 2>/dev/null)"
mark EARLYOOM_ARGS "$(sed -n 's/^EARLYOOM_ARGS=//p' /etc/default/earlyoom 2>/dev/null | tr -d '"' | cut -d' ' -f1-4)"
mark EARLYOOM_ACTIVE "$(systemctl is-active earlyoom 2>/dev/null || true)"
mark BBR "$(sysctl -n net.ipv4.tcp_congestion_control 2>/dev/null)"

# The unit is deliberately enabled even on headless guests. Start it before
# reporting so a prior device-presence skip cannot be misreported as healthy.
if systemctl is-enabled --quiet bluetooth.service 2>/dev/null ||
   pgrep -x blueman-applet >/dev/null 2>&1; then
    modprobe hci_vhci 2>/dev/null || true
    systemctl start bluetooth.service 2>/dev/null || true
fi
failed="$(systemctl --failed --no-legend --plain 2>/dev/null | wc -l)"
mark FAILED_UNITS "${failed}"
if (( failed > 0 )); then systemctl --failed --no-legend --plain 2>/dev/null | sed 's/^/RETRO_DETAIL: failed-unit /'; fi

mark LIGHTDM_ACTIVE "$(systemctl is-active lightdm 2>/dev/null || true)"
mark NETWORKMANAGER_ACTIVE "$(systemctl is-active NetworkManager 2>/dev/null || true)"
mark BLUETOOTH_ACTIVE "$(systemctl is-active bluetooth.service 2>/dev/null || true)"
mark HWPROFILE_ACTIVE "$(systemctl is-active retro-hwprofile 2>/dev/null || true)"
retro_uid="$(id -u retro 2>/dev/null || true)"
if [[ -n "${retro_uid}" ]]; then
    mark OPENBOX_RUNNING "$(yn pgrep -u "${retro_uid}" -x openbox)"
    mark TINT2_RUNNING "$(yn pgrep -u "${retro_uid}" -x tint2)"
    mark PROC_pcmanfm "$(yn pgrep -u "${retro_uid}" -f 'pcmanfm --desktop')"
    for p in nm-applet blueman-applet volumeicon; do
        mark "PROC_${p//-/_}" "$(yn pgrep -u "${retro_uid}" -x "${p}")"
    done
else
    mark OPENBOX_RUNNING no
    mark TINT2_RUNNING no
    mark PROC_pcmanfm no
    mark PROC_nm_applet no
    mark PROC_blueman_applet no
    mark PROC_volumeicon no
fi
mark JGMENU_INSTALLED "$(yn command -v jgmenu_run)"
mark LXTERMINAL_INSTALLED "$(yn command -v lxterminal)"
mark XORG_RUNNING "$(yn pgrep -x Xorg)"
if [[ -S /tmp/.X11-unix/X0 ]]; then mark X11_SOCKET yes; else mark X11_SOCKET no; fi
openbox_pid="$(pgrep -u "${retro_uid:-0}" -x openbox 2>/dev/null | head -n1 || true)"
display_value=""
if [[ -n "${openbox_pid}" && -r "/proc/${openbox_pid}/environ" ]]; then
    display_value="$(tr '\0' '\n' < "/proc/${openbox_pid}/environ" | sed -n 's/^DISPLAY=//p' | head -n1 || true)"
fi
mark DISPLAY "${display_value:-none}"
loop=0
for f in /var/log/lightdm/lightdm.log; do
    [[ -r "${f}" ]] || continue
    n="$(grep -ciE '(session|greeter).*(exited|failed|terminated)' "${f}" 2>/dev/null || true)"
    if [[ "${n:-0}" -gt 0 ]]; then
        loop=1
        grep -iE '(session|greeter).*(exited|failed|terminated)' "${f}" | tail -n 5 | sed 's/^/RETRO_DETAIL: lightdm /'
    fi
done
mark LOGIN_LOOP_SUSPECT "${loop}"

xlog=""
for f in /var/log/Xorg.0.log "/home/retro/.local/share/xorg/Xorg.0.log"; do
    [[ -r "${f}" ]] && { xlog="${f}"; break; }
done
if [[ -n "${xlog}" ]]; then
    ee="$(grep -c '(EE)' "${xlog}" 2>/dev/null || true)"
    mark XORG_ERRORS "${ee:-0}"
    grep '(EE)' "${xlog}" 2>/dev/null | grep -v 'Failed to load module' | head -n 8 | sed 's/^/RETRO_DETAIL: xorg /'
else
    mark XORG_ERRORS "no-log"
fi

mark WALLPAPER "$([[ -s /usr/share/backgrounds/retro-wallpaper.png ]] && echo yes || echo no)"
mark RETRO_CLI "$(yn retro --version)"

for t in nmap tshark aircrack-ng hydra john nikto sqlmap wifite rustscan ffuf httpx naabu; do
    if command -v "${t}" >/dev/null 2>&1; then
        timeout 20 "${t}" --help >/dev/null 2>&1 < /dev/null
        rc=$?
        if (( rc == 124 || rc == 126 || rc == 127 )); then mark "TOOL_${t//-/_}" "noexec(${rc})"; else mark "TOOL_${t//-/_}" "ok"; fi
    else
        mark "TOOL_${t//-/_}" "missing"
    fi
done

journalctl -b -p err --no-pager -q 2>/dev/null | tail -n 15 | sed 's/^/RETRO_DETAIL: journal-err /'
echo "RETRO_REPORT_DONE"
EOF

    retro_write /etc/systemd/system/retro-boot-report.service 0644 <<'EOF'
[Unit]
Description=Retro OS boot health report (debug/test only: kernel arg retro.report=1)
After=graphical.target display-manager.service bluetooth.service retro-ai-watchdog.service
ConditionKernelCommandLine=retro.report=1

[Service]
Type=oneshot
ExecStartPre=/bin/sleep 25
ExecStart=/opt/retro-os/bin/retro-boot-report
StandardOutput=journal+console
TimeoutStartSec=240

[Install]
WantedBy=graphical.target
EOF
    systemctl enable retro-boot-report.service
}

# -----------------------------------------------------------------------------
# 5. Overlay payload sanity + menus
# -----------------------------------------------------------------------------
verify_overlay_payload() {
    retro_info "Verifying overlay payload"
    [[ -s "${RETRO_BIN_DIR}/retro" ]] \
        || retro_die "${RETRO_BIN_DIR}/retro missing - overlay/usr/local/bin/retro was not applied"
    chmod 0755 "${RETRO_BIN_DIR}/retro"
    bash -n "${RETRO_BIN_DIR}/retro" || retro_die "retro CLI has a bash syntax error"
}

regenerate_menus() {
    retro_info "Regenerating menus now that all tools are installed"
    "${RETRO_HELPER_DIR}/retro-menu-gen" --system
    "${RETRO_HELPER_DIR}/retro-menu-gen" --list || true
}

main() {
    retro_info "=== 03_modules_setup.sh: start ==="
    install_classic_tools
    write_fetcher
    stage_modern_tools
    install_retro_ai
    install_boot_report
    verify_overlay_payload
    regenerate_menus
    retro_ok "=== 03_modules_setup.sh: complete ==="
}

main "$@"

#!/usr/bin/env bash
# =============================================================================
# Retro OS v2.0 — 03_modules_setup.sh
# Runs INSIDE the debootstrap chroot as root.
# Installs: ZRAM + EarlyOOM (low-RAM survival), the security auditing suite,
# and the Bujji AI companion CLI + `retro` wrapper.
# =============================================================================
#!/usr/bin/env bash
set -Eeuo pipefail

retro_info()  { echo -e "\033[0;36m[*] $*\033[0m"; }
retro_ok()    { echo -e "\033[0;32m[+] $*\033[0m"; }
retro_warn()  { echo -e "\033[0;33m[!] $*\033[0m"; }
retro_error() { echo -e "\033[0;31m[x] $*\033[0m"; }

trap 'retro_error "03_modules_setup.sh failed at line ${LINENO} (exit ${?})"' ERR

export DEBIAN_FRONTEND=noninteractive

RETRO_USER="retro"
RETRO_AI_DIR="/opt/retro-ai"
RETRO_ETC_DIR="/etc/retro-os"
RETRO_BIN_DIR="/usr/local/bin"

# -----------------------------------------------------------------------------
# ZRAM + EarlyOOM — keeps 512MB-1GB boxes alive under memory pressure
# -----------------------------------------------------------------------------
retro_info "[03] Installing ZRAM + EarlyOOM"
apt-get install -y --no-install-recommends \
    zram-tools \
    earlyoom

cat > /etc/default/zramswap <<'EOF'
# Retro OS v2.0 — ZRAM config
ALGO=zstd
PERCENT=50
PRIORITY=100
EOF
systemctl enable zramswap.service

cat > /etc/default/earlyoom <<'EOF'
# Retro OS v2.0 — EarlyOOM config
# Kill when free memory AND swap both drop below these thresholds (%),
# to prevent hard lockups on 512MB-1GB RAM before the kernel OOM killer
# would ever trigger.
EARLYOOM_ARGS="-r 60 -m 5 -s 10 --prefer '(^|/)(chromium|firefox-esr)$' --avoid '(^|/)(sshd|systemd|Xorg|openbox|lightdm)$'"
EOF
systemctl enable earlyoom.service

# -----------------------------------------------------------------------------
# Security auditing suite
# -----------------------------------------------------------------------------
retro_info "[03] Installing security auditing suite"
apt-get install -y --no-install-recommends \
    nmap \
    wireshark \
    tshark \
    aircrack-ng \
    hydra \
    hydra-gtk \
    john \
    nikto \
    sqlmap \
    netcat-openbsd \
    tcpdump \
    macchanger \
    hashcat \
    dirb \
    hping3 \
    wireless-tools \
    dnsutils \
    whois \
    net-tools \
    traceroute

# wireshark: allow the retro user (dumpcap group) to capture without root
dpkg-reconfigure -f noninteractive wireshark-common 2>/dev/null || true
groupadd -f wireshark
usermod -aG wireshark "${RETRO_USER}"

# -----------------------------------------------------------------------------
# Bujji AI companion CLI daemon
# -----------------------------------------------------------------------------
retro_info "[03] Installing Bujji AI companion"
apt-get install -y --no-install-recommends \
    python3 \
    python3-venv \
    python3-pip \
    espeak-ng

install -d -m 755 "${RETRO_AI_DIR}"

cat > "${RETRO_AI_DIR}/bujji.py" <<'PYEOF'
#!/usr/bin/env python3
"""
Retro OS v2.0 — Bujji AI companion CLI daemon.

A small, dependency-light, offline-first system companion. Talks in a mix
of English / Manglish, reports system health, and watches RAM/disk
thresholds with espeak-ng voice alerts. An optional cloud bridge (Groq or
Gemini) can be wired in via /etc/retro-os/bujji.conf — it is OFF by
default and never required for core functionality.
"""
from __future__ import annotations

import argparse
import configparser
import json
import os
import shutil
import subprocess
import sys
import time
from pathlib import Path

CONF_PATH = Path("/etc/retro-os/bujji.conf")
STATE_DIR = Path("/var/lib/retro-os")
LOG_PATH = Path("/var/log/retro-os/bujji.log")

RAM_WARN_PERCENT = 85
DISK_WARN_FREE_PERCENT = 5
POLL_SECONDS = 20

BANNER = r"""
  ____       _ _ _ _    _    ___
 | __ ) _   _(_|_|_|  / \  |_ _|
 |  _ \| | | | | | | / _ \  | |
 | |_) | |_| | | | |/ ___ \ | |
 |____/ \__,_| |_|_/_/   \_\___|   Retro OS AI Companion
"""


def log(msg: str) -> None:
    LOG_PATH.parent.mkdir(parents=True, exist_ok=True)
    ts = time.strftime("%Y-%m-%d %H:%M:%S")
    with LOG_PATH.open("a", encoding="utf-8") as fh:
        fh.write(f"[{ts}] {msg}\n")


def speak(text: str) -> None:
    if shutil.which("espeak-ng"):
        subprocess.run(["espeak-ng", "-v", "en", text], check=False,
                        stdout=subprocess.DEVNULL, stderr=subprocess.DEVNULL)


def mem_stats() -> dict:
    total = avail = 0
    with open("/proc/meminfo", encoding="utf-8") as fh:
        for line in fh:
            if line.startswith("MemTotal:"):
                total = int(line.split()[1])
            elif line.startswith("MemAvailable:"):
                avail = int(line.split()[1])
    used_pct = round((1 - avail / total) * 100, 1) if total else 0.0
    return {"total_kb": total, "available_kb": avail, "used_percent": used_pct}


def disk_stats(path: str = "/") -> dict:
    usage = shutil.disk_usage(path)
    free_pct = round(usage.free / usage.total * 100, 1) if usage.total else 0.0
    return {"total": usage.total, "free": usage.free, "free_percent": free_pct}


def greet() -> str:
    hour = time.localtime().tm_hour
    if hour < 12:
        return "Good morning! Bujji ready aanu, ningalude system okke nokkam."
    if hour < 18:
        return "Good afternoon! Enthokke venam, parayu."
    return "Good evening! System vrithiyayi odunnundu."


def cmd_doctor(args: argparse.Namespace) -> int:
    mem = mem_stats()
    disk = disk_stats()
    report = {
        "ram_used_percent": mem["used_percent"],
        "disk_free_percent": disk["free_percent"],
        "status": "OK",
    }

    warnings = []
    if mem["used_percent"] >= RAM_WARN_PERCENT:
        warnings.append(f"RAM usage is high: {mem['used_percent']}%")
    if disk["free_percent"] <= DISK_WARN_FREE_PERCENT:
        warnings.append(f"Disk space is low: {disk['free_percent']}% free")

    if warnings:
        report["status"] = "WARN"
        report["warnings"] = warnings

    if args.silent:
        log(json.dumps(report))
        if warnings:
            for w in warnings:
                speak(w)
        return 0

    print(BANNER)
    print(f"RAM used:   {mem['used_percent']}%")
    print(f"Disk free:  {disk['free_percent']}%")
    if warnings:
        print("\nWarnings:")
        for w in warnings:
            print(f"  - {w}")
    else:
        print("\nAll systems nominal. :)")
    log(json.dumps(report))
    return 0


def cmd_watch(args: argparse.Namespace) -> int:
    log("watchdog started")
    while True:
        mem = mem_stats()
        disk = disk_stats()
        if mem["used_percent"] >= RAM_WARN_PERCENT:
            speak(f"Warning. RAM usage at {int(mem['used_percent'])} percent.")
            log(f"RAM warning: {mem['used_percent']}%")
        if disk["free_percent"] <= DISK_WARN_FREE_PERCENT:
            speak(f"Warning. Disk space low, {int(disk['free_percent'])} percent free.")
            log(f"Disk warning: {disk['free_percent']}% free")
        time.sleep(args.interval)


def cmd_chat(args: argparse.Namespace) -> int:
    print(BANNER)
    print(greet())
    print("(Type 'exit' to quit. This is a local, offline companion shell —")
    print(" no cloud bridge is configured unless you set one up in")
    print(f" {CONF_PATH}.)\n")
    while True:
        try:
            line = input("you> ").strip()
        except (EOFError, KeyboardInterrupt):
            print()
            break
        if line.lower() in {"exit", "quit"}:
            print("Bujji: Pinne kaanam! See you.")
            break
        if not line:
            continue
        if "ram" in line.lower() or "memory" in line.lower():
            m = mem_stats()
            print(f"Bujji: RAM usage is {m['used_percent']}% right now.")
        elif "disk" in line.lower():
            d = disk_stats()
            print(f"Bujji: {d['free_percent']}% disk free.")
        else:
            print("Bujji: Ente local brain parimithamanu — try `retro doctor`,")
            print("       `retro ghost`, or `retro kali` for actual system actions.")
    return 0


def build_parser() -> argparse.ArgumentParser:
    p = argparse.ArgumentParser(prog="bujji", description="Retro OS AI companion")
    sub = p.add_subparsers(dest="command", required=True)

    doctor = sub.add_parser("doctor", help="One-shot system health report")
    doctor.add_argument("--silent", action="store_true",
                         help="Log only, speak warnings, no stdout banner")
    doctor.set_defaults(func=cmd_doctor)

    watch = sub.add_parser("watch", help="Run as a background watchdog")
    watch.add_argument("--interval", type=int, default=POLL_SECONDS)
    watch.set_defaults(func=cmd_watch)

    chat = sub.add_parser("chat", help="Interactive companion shell")
    chat.set_defaults(func=cmd_chat)

    return p


def main() -> int:
    parser = build_parser()
    args = parser.parse_args()
    return args.func(args)


if __name__ == "__main__":
    sys.exit(main())
PYEOF
chmod 755 "${RETRO_AI_DIR}/bujji.py"

install -d -m 755 "${RETRO_ETC_DIR}"
cat > "${RETRO_ETC_DIR}/bujji.conf" <<'EOF'
# Retro OS v2.0 — Bujji AI companion config
# Optional cloud bridge. Leave api_key empty to stay fully offline.
[bridge]
provider =
api_key =
EOF
chmod 600 "${RETRO_ETC_DIR}/bujji.conf"

# systemd unit for the watchdog (enabled, started on next real boot —
# never started here, we're in a chroot with no running init)
cat > /etc/systemd/system/bujji-watchdog.service <<EOF
[Unit]
Description=Retro OS Bujji AI watchdog (RAM/disk voice alerts)
After=multi-user.target

[Service]
Type=simple
ExecStart=/usr/bin/python3 ${RETRO_AI_DIR}/bujji.py watch
Restart=on-failure
RestartSec=5
Nice=10

[Install]
WantedBy=multi-user.target
EOF
systemctl enable bujji-watchdog.service

# -----------------------------------------------------------------------------
# `retro` CLI wrapper — installed from the overlay tree by build.sh, but we
# make sure the dirs it expects exist and it's executable if present.
# -----------------------------------------------------------------------------
if [[ -f "${RETRO_BIN_DIR}/retro" ]]; then
    chmod 755 "${RETRO_BIN_DIR}/retro"
    retro_info "[03] retro CLI wrapper found and marked executable"
else
    retro_warn "[03] retro CLI wrapper not yet present (overlay applies after this script)"
fi

retro_info "[03] Cleaning apt caches to shrink the squashfs"
apt-get autoremove -y
apt-get clean
rm -rf /var/lib/apt/lists/* /tmp/* /var/tmp/*

retro_info "[03] Module setup complete"

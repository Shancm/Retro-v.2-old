#!/usr/bin/env python3
"""Bujji: lightweight local CLI companion; no network calls or shell execution."""
from __future__ import annotations
import argparse, os, shutil, subprocess, sys, time
try:
    import psutil
except ImportError:
    psutil = None

def telemetry() -> str:
    if psutil is None:
        return "Telemetry unavailable: install python3-psutil."
    vm = psutil.virtual_memory()
    swap = psutil.swap_memory()
    return (f"CPU: {psutil.cpu_percent(interval=0.2):.0f}% | "
            f"RAM: {vm.percent:.0f}% ({vm.used // 1048576}/{vm.total // 1048576} MiB) | "
            f"Available: {vm.available // 1048576} MiB | Swap: {swap.percent:.0f}%")

def speak(message: str) -> None:
    if shutil.which("espeak-ng"):
        try:
            subprocess.run(["espeak-ng", "-v", "en", message[:400]], timeout=8,
                           check=False, stdout=subprocess.DEVNULL, stderr=subprocess.DEVNULL)
        except (OSError, subprocess.TimeoutExpired):
            pass

def answer(message: str) -> str:
    q = message.strip().lower()
    if q in {"help", "commands", "sahayam"}:
        return ("Commands: help, status, ram, cpu, disk, time, speak on, speak off, quit. "
                "Njan local assistant aanu; network-il data ayakkilla.")
    if q in {"status", "ram", "cpu"}:
        return telemetry()
    if q == "disk":
        if psutil is None:
            return "Disk telemetry unavailable: install python3-psutil."
        d = psutil.disk_usage("/")
        return f"Root disk: {d.percent}% used; {d.free // 1073741824} GiB free."
    if q == "time":
        return time.strftime("Local system time: %Y-%m-%d %H:%M:%S %Z")
    if q in {"hello", "hi", "namaskaram", "namaskaaram"}:
        return "Namaskaram! Bujji ready aanu. Type 'help' for commands."
    if any(w in q for w in ("thanks", "thank you", "nanni")):
        return "You're welcome! Nanni."
    return ("I can report local system health and explain Retro OS commands. "
            "Enikku ee request-inu local rule illa; 'help' type cheyyu.")

def main() -> int:
    parser = argparse.ArgumentParser(description="Bujji local CLI companion")
    parser.add_argument("--once", help="Answer one local query and exit")
    parser.add_argument("--no-voice", action="store_true", help="Disable voice alerts")
    args = parser.parse_args()
    voice = not args.no_voice
    if args.once is not None:
        result = answer(args.once)
        print(result)
        if voice: speak(result)
        return 0
    print("Bujji / ബുജ്ജി — Retro OS local assistant. Type help or quit.")
    while True:
        try:
            line = input("bujji> ").strip()
        except (EOFError, KeyboardInterrupt):
            print()
            break
        if line.lower() in {"quit", "exit", "bye"}:
            print("Bujji signing off. Nanni!")
            break
        if line.lower() == "speak on":
            voice = True; print("Voice enabled."); continue
        if line.lower() == "speak off":
            voice = False; print("Voice disabled."); continue
        result = answer(line)
        print(result)
        if voice: speak(result)
    return 0

if __name__ == "__main__":
    raise SystemExit(main())

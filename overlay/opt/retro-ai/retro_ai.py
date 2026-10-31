#!/usr/bin/env python3
"""Retro AI - the offline system companion of Retro OS.

Sub-commands
    shell   (default) interactive companion
    doctor  one-shot health audit      [--json] [--brief]
    watch   watchdog daemon: periodic RAM/disk monitoring with espeak-ng alerts
    status  one-line machine state     [--json]
    say     speak a sentence with espeak-ng

Pure standard library; no network access is ever required.
"""
from __future__ import annotations

import argparse
import cmd
import configparser
import difflib
import json
import os
import re
import shutil
import signal
import socket
import subprocess
import sys
import threading
import time

VERSION = "2.0"
CONF_PATH = "/etc/retro-os/retro-ai.conf"
PROFILE_ENV = "/run/retro-os/profile.env"
RUN_DIR = "/run/retro-ai"
ALERT_LOG = os.path.join(RUN_DIR, "alerts.log")
STATUS_JSON = os.path.join(RUN_DIR, "status.json")

DEFAULTS = {
    "interval": "30",
    "ram_warn": "85",
    "ram_crit": "92",
    "disk_warn_free": "10",
    "disk_crit_free": "5",
    "cooldown": "300",
    "voice": "true",
    "voice_speed": "150",
}

USE_COLOR = sys.stdout.isatty() and not os.environ.get("NO_COLOR")
C = {
    "mint": "\033[38;5;48m" if USE_COLOR else "",
    "red": "\033[38;5;197m" if USE_COLOR else "",
    "yel": "\033[38;5;220m" if USE_COLOR else "",
    "dim": "\033[38;5;244m" if USE_COLOR else "",
    "bold": "\033[1m" if USE_COLOR else "",
    "rst": "\033[0m" if USE_COLOR else "",
}


# --------------------------------------------------------------------------- #
# configuration + system probes
# --------------------------------------------------------------------------- #
def load_config() -> configparser.SectionProxy:
    cp = configparser.ConfigParser()
    cp.read_dict({"watch": DEFAULTS})
    try:
        cp.read(CONF_PATH)
    except configparser.Error as exc:
        print("retro-ai: bad config (%s), using defaults" % exc, file=sys.stderr)
    return cp["watch"]


def read_env_file(path: str) -> dict:
    data = {}
    try:
        with open(path, encoding="utf-8") as fh:
            for line in fh:
                line = line.strip()
                if "=" in line and not line.startswith("#"):
                    key, _, val = line.partition("=")
                    data[key] = val.strip('"')
    except OSError:
        pass
    return data


def meminfo() -> dict:
    out = {}
    with open("/proc/meminfo", encoding="utf-8") as fh:
        for line in fh:
            key, _, rest = line.partition(":")
            out[key] = int(rest.split()[0])
    return out


def ram_stats() -> tuple:
    mi = meminfo()
    total = mi["MemTotal"]
    avail = mi.get("MemAvailable", mi.get("MemFree", 0))
    used = total - avail
    return used / total * 100.0, used / 1048576.0, total / 1048576.0


def swap_stats() -> dict:
    mi = meminfo()
    zram = False
    try:
        with open("/proc/swaps", encoding="utf-8") as fh:
            zram = any(line.startswith("/dev/zram") for line in fh)
    except OSError:
        pass
    total, free = mi.get("SwapTotal", 0), mi.get("SwapFree", 0)
    return {"zram": zram, "total_mb": total // 1024, "used_mb": (total - free) // 1024}


def disk_free_pct(path: str = "/") -> tuple:
    du = shutil.disk_usage(path)
    return du.free / du.total * 100.0, du.free / 1073741824.0, du.total / 1073741824.0


def cpu_count() -> int:
    return os.cpu_count() or 1


def temperature() -> float | None:
    best = None
    base = "/sys/class/thermal"
    try:
        for zone in os.listdir(base):
            if not zone.startswith("thermal_zone"):
                continue
            try:
                with open(os.path.join(base, zone, "temp"), encoding="utf-8") as fh:
                    val = int(fh.read().strip()) / 1000.0
            except (OSError, ValueError):
                continue
            if best is None or val > best:
                best = val
    except OSError:
        pass
    return best


def run(argv: list, timeout: int = 10) -> str:
    try:
        res = subprocess.run(argv, capture_output=True, text=True, timeout=timeout, check=False)
        return res.stdout.strip()
    except (OSError, subprocess.TimeoutExpired):
        return ""


def unit_active(name: str) -> bool:
    return run(["systemctl", "is-active", name]) == "active"


def top_mem(n: int = 5) -> list:
    rows = []
    for pid in filter(str.isdigit, os.listdir("/proc")):
        try:
            with open("/proc/%s/status" % pid, encoding="utf-8") as fh:
                text = fh.read()
        except OSError:
            continue
        name = re.search(r"^Name:\s+(.*)$", text, re.M)
        rss = re.search(r"^VmRSS:\s+(\d+) kB", text, re.M)
        if name and rss:
            rows.append((int(rss.group(1)) / 1024.0, name.group(1), int(pid)))
    rows.sort(reverse=True)
    return rows[:n]


def network_state() -> tuple:
    route = run(["ip", "route", "show", "default"])
    if not route:
        return False, False
    old = socket.getdefaulttimeout()
    socket.setdefaulttimeout(3)
    try:
        socket.gethostbyname("deb.debian.org")
        dns = True
    except OSError:
        dns = False
    finally:
        socket.setdefaulttimeout(old)
    return True, dns


# --------------------------------------------------------------------------- #
# health audit
# --------------------------------------------------------------------------- #
def audit(cfg: configparser.SectionProxy) -> list:
    """Return [(level, name, message, hint)] where level is OK | WARN | FAIL."""
    res = []
    prof = read_env_file(PROFILE_ENV)
    tier = prof.get("RETRO_TIER", "unknown")

    pct, used, total = ram_stats()
    level = "FAIL" if pct >= cfg.getfloat("ram_crit") else "WARN" if pct >= cfg.getfloat("ram_warn") else "OK"
    res.append((level, "RAM", "%.0f%% used (%.1f/%.1f GiB), tier=%s" % (pct, used, total, tier),
                "run: retro boost" if level != "OK" else ""))

    sw = swap_stats()
    if tier == "low" and not sw["zram"]:
        res.append(("WARN", "ZRAM", "low-RAM tier but no zram swap is active", "run: sudo retro-hwprofile apply"))
    else:
        res.append(("OK", "ZRAM", "zram=%s, swap used %d/%d MiB" % (sw["zram"], sw["used_mb"], sw["total_mb"]), ""))

    free_pct, free_gb, total_gb = disk_free_pct("/")
    level = "FAIL" if free_pct <= cfg.getfloat("disk_crit_free") else "WARN" if free_pct <= cfg.getfloat("disk_warn_free") else "OK"
    res.append((level, "DISK /", "%.0f%% free (%.1f of %.1f GiB)" % (free_pct, free_gb, total_gb),
                "run: retro doctor (clean caches) and remove large files" if level != "OK" else ""))

    load1 = os.getloadavg()[0]
    ratio = load1 / cpu_count()
    level = "FAIL" if ratio > 3 else "WARN" if ratio > 1.5 else "OK"
    res.append((level, "CPU load", "%.2f (1 min) on %d core(s)" % (load1, cpu_count()),
                "run: retro mon to find the culprit" if level != "OK" else ""))

    temp = temperature()
    if temp is None:
        res.append(("OK", "Thermals", "no sensor exposed (normal in VMs)", ""))
    else:
        level = "FAIL" if temp >= 90 else "WARN" if temp >= 80 else "OK"
        res.append((level, "Thermals", "%.0f C" % temp, "clean fans / reduce load" if level != "OK" else ""))

    failed = [ln.split()[0] for ln in run(["systemctl", "--failed", "--no-legend", "--plain"]).splitlines() if ln.strip()]
    res.append(("OK" if not failed else "WARN", "systemd", "no failed units" if not failed else "failed: " + ", ".join(failed[:5]),
                "inspect: journalctl -xb -u <unit>; repair: retro doctor" if failed else ""))

    audit_out = run(["dpkg", "--audit"])
    res.append(("OK" if not audit_out else "FAIL", "dpkg", "package database consistent" if not audit_out else "half-configured packages",
                "run: retro doctor" if audit_out else ""))

    dm_ok = unit_active("lightdm.service")
    res.append(("OK" if dm_ok else "WARN", "LightDM", "active" if dm_ok else "not active (tty-only session?)",
                "journalctl -u lightdm -b" if not dm_ok else ""))

    route, dns = network_state()
    if route and dns:
        res.append(("OK", "Network", "default route + DNS working", ""))
    elif route:
        res.append(("WARN", "Network", "route present but DNS fails", "check /etc/resolv.conf / nmcli"))
    else:
        res.append(("WARN", "Network", "no default route (offline)", "nmcli device status"))

    oom_ok = unit_active("earlyoom.service")
    res.append(("OK" if oom_ok else "WARN", "EarlyOOM", "active" if oom_ok else "not running",
                "sudo systemctl start earlyoom" if not oom_ok else ""))

    picom_running = run(["pgrep", "-x", "picom"]) != ""
    if tier == "low" and picom_running:
        res.append(("WARN", "Compositor", "picom running on the low-RAM tier", "run: retro boost"))
    else:
        res.append(("OK", "Compositor", "picom %s (policy: %s)" % ("running" if picom_running else "off", prof.get("RETRO_PICOM", "?")), ""))

    errs = run(["journalctl", "-b", "-p", "err", "-q", "--no-pager"], timeout=20).count("\n")
    res.append(("OK" if errs < 20 else "WARN", "Journal", "%d error line(s) this boot" % errs,
                "review: journalctl -b -p err" if errs >= 20 else ""))
    return res


def cmd_doctor(args: argparse.Namespace) -> int:
    cfg = load_config()
    results = audit(cfg)
    worst = 0
    if args.json:
        print(json.dumps([{"level": l, "check": n, "detail": m, "hint": h} for l, n, m, h in results], indent=2))
    else:
        colors = {"OK": C["mint"], "WARN": C["yel"], "FAIL": C["red"]}
        for level, name, msg, hint in results:
            if args.brief and level == "OK":
                continue
            print("%s[%-4s]%s %-12s %s" % (colors[level], level, C["rst"], name, msg))
            if hint:
                print("         %s-> %s%s" % (C["dim"], hint, C["rst"]))
        counts = {k: sum(1 for r in results if r[0] == k) for k in ("OK", "WARN", "FAIL")}
        print("\n%sRetro AI:%s %d ok, %d warning(s), %d failure(s)" % (C["bold"], C["rst"], counts["OK"], counts["WARN"], counts["FAIL"]))
    for level, *_ in results:
        worst = max(worst, {"OK": 0, "WARN": 1, "FAIL": 2}[level])
    return worst


# --------------------------------------------------------------------------- #
# voice + alerts
# --------------------------------------------------------------------------- #
_voice_proc = None


def have_sound() -> bool:
    try:
        with open("/proc/asound/cards", encoding="utf-8") as fh:
            txt = fh.read()
        return bool(txt.strip()) and "no soundcards" not in txt
    except OSError:
        return False


def speak(text: str, speed: str = "150") -> bool:
    global _voice_proc
    if not shutil.which("espeak-ng") or not have_sound():
        return False
    if _voice_proc is not None and _voice_proc.poll() is None:
        return False  # still talking: never queue up
    try:
        _voice_proc = subprocess.Popen(["espeak-ng", "-s", speed, text],
                                       stdout=subprocess.DEVNULL, stderr=subprocess.DEVNULL)
        return True
    except OSError:
        return False


def log_alert(level: str, msg: str) -> None:
    stamp = time.strftime("%Y-%m-%d %H:%M:%S")
    line = "[%s] %s %s" % (stamp, level.upper(), msg)
    print(line, flush=True)
    try:
        os.makedirs(RUN_DIR, exist_ok=True)
        with open(ALERT_LOG, "a", encoding="utf-8") as fh:
            fh.write(line + "\n")
    except OSError:
        pass


def classify(value: float, warn: float, crit: float, prev: str, high_is_bad: bool) -> str:
    """Threshold classification with 3-point hysteresis so alerts do not flap."""
    margin = 3.0
    if not high_is_bad:
        value, warn, crit, margin = -value, -warn, -crit, -3.0
    if value >= crit:
        return "crit"
    if value >= warn:
        return "warn" if prev != "crit" or value < crit - margin else "crit"
    if prev in ("warn", "crit") and value >= warn - margin:
        return prev
    return "ok"


def cmd_watch(args: argparse.Namespace) -> int:
    cfg = load_config()
    stop = threading.Event()
    reload_flag = threading.Event()

    signal.signal(signal.SIGTERM, lambda *_: stop.set())
    signal.signal(signal.SIGINT, lambda *_: stop.set())
    signal.signal(signal.SIGHUP, lambda *_: reload_flag.set())

    state = {"ram": "ok", "disk": "ok"}
    last_alert = {}
    log_alert("info", "Retro AI watchdog started (interval %ss)" % cfg["interval"])

    def handle(key: str, level: str, text: str, advice: str) -> None:
        prev = state[key]
        now = time.time()
        if level == "ok":
            if prev != "ok":
                log_alert("ok", "%s recovered" % key.upper())
                state[key] = "ok"
            return
        changed = level != prev
        due = now - last_alert.get(key, 0) >= cfg.getint("cooldown")
        state[key] = level
        if changed or due:
            last_alert[key] = now
            log_alert(level, "%s - %s" % (text, advice))
            if cfg.getboolean("voice"):
                speak("%s. %s" % (text, advice), cfg["voice_speed"])

    while not stop.is_set():
        if reload_flag.is_set():
            reload_flag.clear()
            cfg = load_config()
            log_alert("info", "configuration reloaded")

        pct, used, total = ram_stats()
        ram_level = classify(pct, cfg.getfloat("ram_warn"), cfg.getfloat("ram_crit"), state["ram"], True)
        handle("ram", ram_level, "Memory usage is %.0f percent" % pct, "Run retro boost")

        free_pct, _, _ = disk_free_pct("/")
        disk_level = classify(free_pct, cfg.getfloat("disk_warn_free"), cfg.getfloat("disk_crit_free"), state["disk"], False)
        handle("disk", disk_level, "Only %.0f percent disk space is free" % free_pct, "Run retro doctor")

        try:
            os.makedirs(RUN_DIR, exist_ok=True)
            with open(STATUS_JSON, "w", encoding="utf-8") as fh:
                json.dump({"time": int(time.time()), "ram_pct": round(pct, 1), "disk_free_pct": round(free_pct, 1),
                           "ram_state": state["ram"], "disk_state": state["disk"]}, fh)
        except OSError:
            pass
        stop.wait(cfg.getint("interval"))

    log_alert("info", "Retro AI watchdog stopped")
    return 0


# --------------------------------------------------------------------------- #
# interactive companion
# --------------------------------------------------------------------------- #
TOOLS = {
    "nmap": ("Network mapper / port scanner.",
             ["nmap -sV -T4 192.168.1.0/24   # service versions on a subnet", "nmap -p- --min-rate 2000 <host>   # all ports, fast", "nmap -sC -sV -oA scan <host>   # default scripts, save output"]),
    "rustscan": ("Very fast port scanner that hands results to nmap.",
                 ["rustscan -a <host> --ulimit 5000", "rustscan -a <host> -- -sV   # pass flags to nmap"]),
    "naabu": ("Lightweight SYN/connect port scanner.",
              ["naabu -host <host> -top-ports 1000", "naabu -list hosts.txt -o open.txt"]),
    "httpx": ("HTTP probing: status, title, tech.",
              ["httpx -l hosts.txt -status-code -title -tech-detect", "echo example.com | httpx -silent"]),
    "ffuf": ("Fast web fuzzer.",
             ["ffuf -u https://site/FUZZ -w words.txt", "ffuf -u https://site/ -H 'Host: FUZZ.site' -w subs.txt -fs 0"]),
    "nikto": ("Classic web server vulnerability scanner.", ["nikto -h http://<host> -o report.txt"]),
    "sqlmap": ("Automatic SQL injection testing.", ["sqlmap -u 'http://site/page?id=1' --batch --dbs"]),
    "hydra": ("Online password guesser for network services.", ["hydra -L users.txt -P pass.txt ssh://<host> -t 4"]),
    "john": ("John the Ripper offline hash cracker.", ["john --wordlist=rockyou.txt hashes.txt", "john --show hashes.txt"]),
    "aircrack-ng": ("Wi-Fi handshake cracking suite.", ["aircrack-ng -w words.txt capture.cap"]),
    "wifite": ("Automated wireless auditing frontend.", ["sudo wifite --kill"]),
    "tshark": ("Terminal Wireshark.", ["sudo tshark -i wlan0 -f 'port 80'", "tshark -r cap.pcap -Y http.request"]),
}

TIPS = [
    "Low on RAM? 'retro boost' stops the compositor and idle daemons and drops caches.",
    "'retro share file.iso' serves a file and shows a QR code your phone can scan.",
    "Right-click the desktop for the Retro menu; Super+Space opens the Start menu.",
    "'retro doctor' repairs half-installed packages and trims the disk.",
    "Force a tier at boot with retro.tier=low (or standard) on the kernel command line.",
    "Only test systems you own or have written permission to test.",
]

INTENTS = [
    ("ram", ("ram", "memory", "slow", "lag", "laggy", "hang", "freeze", "swap")),
    ("disk", ("disk", "space", "storage", "full", "drive")),
    ("cpu", ("cpu", "load", "processor", "busy", "fan")),
    ("temp", ("temp", "temperature", "hot", "heat", "thermal")),
    ("net", ("network", "internet", "wifi", "wi-fi", "online", "connection", "dns")),
    ("doctor", ("health", "doctor", "check", "audit", "problem", "broken", "status")),
    ("boost", ("boost", "faster", "speed", "free", "clean")),
    ("tip", ("tip", "advice", "hint", "suggest")),
    ("tools", ("tools", "installed", "scanners")),
]


class Companion(cmd.Cmd):
    intro = ""
    prompt = "%sretro-ai>%s " % (C["mint"], C["rst"])

    def __init__(self) -> None:
        super().__init__()
        self.cfg = load_config()
        self._tip = 0

    def say(self, text: str) -> None:
        print("%s%s%s" % (C["mint"], text, C["rst"]))

    # -- commands ---------------------------------------------------------- #
    def do_help(self, arg: str) -> None:
        """help - list what I can do"""
        print("""%sI am Retro AI - offline, private, and a little retro.%s
  status | ram | disk | cpu | temp | net   quick readings
  top                                      biggest memory users
  doctor                                   full health audit
  boost                                    free RAM now (runs 'retro boost')
  tools                                    which audit tools are installed
  explain <tool>                           examples for nmap, ffuf, hydra, ...
  tip                                      a useful tip
  say <text>                               speak with espeak-ng
  quit                                     leave
You can also just ask: "why is my pc slow?", "is the internet working?", "am I low on disk?" """
              % (C["bold"], C["rst"]))

    def do_status(self, arg: str) -> None:
        """status - one-line machine state"""
        pct, used, total = ram_stats()
        free_pct, free_gb, _ = disk_free_pct("/")
        prof = read_env_file(PROFILE_ENV)
        self.say("tier=%s | RAM %.0f%% (%.1f/%.1f GiB) | disk free %.0f%% (%.1f GiB) | load %.2f | cores %d" % (
            prof.get("RETRO_TIER", "?"), pct, used, total, free_pct, free_gb, os.getloadavg()[0], cpu_count()))

    def do_ram(self, arg: str) -> None:
        """ram - memory and swap"""
        pct, used, total = ram_stats()
        sw = swap_stats()
        verdict = "tight - try 'boost'" if pct >= 85 else "healthy"
        self.say("RAM %.0f%% used (%.1f of %.1f GiB) - %s. zram: %s, swap used %d MiB." % (
            pct, used, total, verdict, "on" if sw["zram"] else "off", sw["used_mb"]))

    def do_disk(self, arg: str) -> None:
        """disk - free space"""
        free_pct, free_gb, total_gb = disk_free_pct("/")
        verdict = "low - run 'retro doctor'" if free_pct <= 10 else "fine"
        self.say("Root has %.1f of %.1f GiB free (%.0f%%) - %s." % (free_gb, total_gb, free_pct, verdict))

    def do_cpu(self, arg: str) -> None:
        """cpu - load"""
        l1, l5, l15 = os.getloadavg()
        self.say("Load %.2f / %.2f / %.2f on %d core(s)." % (l1, l5, l15, cpu_count()))

    def do_temp(self, arg: str) -> None:
        """temp - thermals"""
        t = temperature()
        self.say("No temperature sensor exposed here." if t is None else "Hottest sensor: %.0f C." % t)

    def do_net(self, arg: str) -> None:
        """net - connectivity"""
        route, dns = network_state()
        self.say("Online: route and DNS OK." if route and dns else
                 "Route exists but DNS fails." if route else "No default route - you are offline.")

    def do_top(self, arg: str) -> None:
        """top - biggest memory users"""
        for rss, name, pid in top_mem(5):
            print("  %7.1f MiB  %-20s pid %d" % (rss, name, pid))

    def do_doctor(self, arg: str) -> None:
        """doctor - full health audit"""
        cmd_doctor(argparse.Namespace(json=False, brief=False))

    def do_boost(self, arg: str) -> None:
        """boost - run retro boost"""
        if input("Run 'retro boost' (stops Picom/idle services, drops caches)? [y/N] ").strip().lower() == "y":
            subprocess.call(["retro", "boost"])
        else:
            self.say("Okay, leaving things as they are.")

    def do_tools(self, arg: str) -> None:
        """tools - installed audit tools"""
        for name in TOOLS:
            path = shutil.which(name)
            print("  %s%-12s%s %s" % (C["mint"] if path else C["red"], name, C["rst"], path or "not installed"))

    def do_explain(self, arg: str) -> None:
        """explain <tool>"""
        name = arg.strip().lower()
        if name not in TOOLS:
            close = difflib.get_close_matches(name, list(TOOLS), n=1)
            self.say("I do not know '%s'.%s Known: %s" % (name, " Did you mean '%s'?" % close[0] if close else "", ", ".join(TOOLS)))
            return
        desc, examples = TOOLS[name]
        self.say("%s - %s" % (name, desc))
        for ex in examples:
            print("    %s" % ex)
        print("  %sOnly scan systems you own or are authorised to test.%s" % (C["dim"], C["rst"]))

    def do_tip(self, arg: str) -> None:
        """tip - a useful tip"""
        self.say(TIPS[self._tip % len(TIPS)])
        self._tip += 1

    def do_say(self, arg: str) -> None:
        """say <text>"""
        if not speak(arg or "Retro AI online", self.cfg["voice_speed"]):
            self.say("I cannot speak here (espeak-ng or a sound card is missing).")

    def do_quit(self, arg: str) -> bool:
        """quit"""
        self.say("Stay sharp. Bye!")
        return True

    do_exit = do_quit
    do_bye = do_quit
    do_EOF = do_quit

    def emptyline(self) -> None:
        return None

    # -- natural-language fallback ----------------------------------------- #
    def default(self, line: str) -> None:
        words = re.findall(r"[a-z0-9-]+", line.lower())
        best, score = None, 0
        for intent, keys in INTENTS:
            hits = sum(1 for w in words if w in keys)
            if hits > score:
                best, score = intent, hits
        if best is None:
            for w in words:
                if w in TOOLS:
                    self.do_explain(w)
                    return
            guess = difflib.get_close_matches(words[0] if words else line, [n[3:] for n in dir(self) if n.startswith("do_")], n=1)
            self.say("Hmm, I did not get that.%s Type 'help'." % (" Did you mean '%s'?" % guess[0] if guess else ""))
            return
        getattr(self, "do_" + best)("")

    def preloop(self) -> None:
        print("%s%sRetro AI %s%s - offline companion. Type 'help'." % (C["bold"], C["mint"], VERSION, C["rst"]))
        self.do_status("")


def cmd_shell(args: argparse.Namespace) -> int:
    try:
        Companion().cmdloop()
    except KeyboardInterrupt:
        print()
    return 0


def cmd_status(args: argparse.Namespace) -> int:
    pct, used, total = ram_stats()
    free_pct, _, _ = disk_free_pct("/")
    data = {"ram_pct": round(pct, 1), "disk_free_pct": round(free_pct, 1), "load1": round(os.getloadavg()[0], 2),
            "tier": read_env_file(PROFILE_ENV).get("RETRO_TIER", "unknown"), "watchdog": unit_active("retro-ai-watchdog.service")}
    if args.json:
        print(json.dumps(data))
    else:
        print("tier=%(tier)s ram=%(ram_pct)s%% disk_free=%(disk_free_pct)s%% load=%(load1)s watchdog=%(watchdog)s" % data)
    return 0


def cmd_say(args: argparse.Namespace) -> int:
    ok = speak(" ".join(args.text), load_config()["voice_speed"])
    if ok and _voice_proc is not None:
        _voice_proc.wait(timeout=30)
    return 0 if ok else 1


def build_parser() -> argparse.ArgumentParser:
    p = argparse.ArgumentParser(prog="retro ai", description="Retro AI - offline system companion")
    p.add_argument("--version", action="version", version="retro-ai " + VERSION)
    sub = p.add_subparsers(dest="command")
    sub.add_parser("shell", help="interactive companion (default)").set_defaults(func=cmd_shell)
    d = sub.add_parser("doctor", help="one-shot health audit")
    d.add_argument("--json", action="store_true")
    d.add_argument("--brief", action="store_true", help="only show warnings/failures")
    d.set_defaults(func=cmd_doctor)
    sub.add_parser("watch", help="watchdog daemon").set_defaults(func=cmd_watch)
    s = sub.add_parser("status", help="machine state")
    s.add_argument("--json", action="store_true")
    s.set_defaults(func=cmd_status)
    sy = sub.add_parser("say", help="speak text")
    sy.add_argument("text", nargs="+")
    sy.set_defaults(func=cmd_say)
    return p


def main(argv: list | None = None) -> int:
    args = build_parser().parse_args(argv)
    if not getattr(args, "func", None):
        return cmd_shell(args)
    return args.func(args)


if __name__ == "__main__":
    sys.exit(main())

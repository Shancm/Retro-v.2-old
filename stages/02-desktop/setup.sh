#!/usr/bin/env bash
set -Eeuo pipefail
IFS=$'\n\t'
SCRIPT_DIR="$(cd -- "$(dirname -- "${BASH_SOURCE[0]}")" && pwd)"
ROOT="$(cd -- "$SCRIPT_DIR/../.." && pwd)"
source "$ROOT/config/retro.conf"
[[ $EUID -eq 0 ]] || { echo "Run with sudo." >&2; exit 1; }
export DEBIAN_FRONTEND=noninteractive
apt-get update
apt-get install -y --no-install-recommends \
  labwc waybar wofi foot yazi dbus-user-session seatd \
  xwayland swaybg grim slurp wl-clipboard fonts-dejavu-core \
  fonts-noto-core fonts-noto-color-emoji fontconfig
# JetBrains Mono is available from upstream releases, not guaranteed in Noble apt.
# Prefer a distro package when present; otherwise do not download an unpinned binary.
if apt-cache show fonts-jetbrains-mono 2>/dev/null | grep -q '^Package:'; then
  apt-get install -y fonts-jetbrains-mono
fi

install -d -m 0755 /etc/retro/skel/.config/labwc /etc/retro/skel/.config/waybar
cat >/etc/retro/skel/.config/labwc/autostart <<'EOF'
#!/bin/sh
waybar &
exec foot
EOF
cat >/etc/retro/skel/.config/labwc/rc.xml <<'EOF'
<?xml version="1.0"?>
<labwc_config>
  <core><decoration>server</decoration></core>
  <theme><name>Retro</name><cornerRadius>0</cornerRadius></theme>
  <keyboard>
    <keybind key="W-Return"><action name="Execute" command="foot"/></keybind>
    <keybind key="W-d"><action name="Execute" command="wofi --show drun"/></keybind>
    <keybind key="W-e"><action name="Execute" command="foot -e yazi"/></keybind>
  </keyboard>
</labwc_config>
EOF
cat >/etc/retro/skel/.config/waybar/config <<'EOF'
{
  "layer": "top",
  "position": "top",
  "modules-left": ["wlr/workspaces"],
  "modules-center": ["clock"],
  "modules-right": ["memory", "cpu", "network", "battery", "tray"],
  "clock": {"format": "{:%Y-%m-%d %H:%M}"},
  "memory": {"format": "RAM {used:0.1f}G"},
  "cpu": {"format": "CPU {usage}%"}
}
EOF
cat >/etc/retro/skel/.config/waybar/style.css <<'EOF'
* { font-family: "JetBrains Mono", "DejaVu Sans Mono", monospace; font-size: 12px; }
window#waybar { background: #0c0d12; color: #00FF9C; border-bottom: 1px solid #00FF9C; }
#clock, #memory, #cpu, #network, #battery, #tray { padding: 0 10px; }
#battery.warning { color: #FF0055; }
EOF
chmod 0755 /etc/retro/skel/.config/labwc/autostart
# Copy defaults only for users without an existing config.
while IFS=: read -r user _ uid _ _ home shell; do
  if [[ "$uid" -ge 1000 && "$uid" -lt 60000 && -d "$home" ]]; then
    install -d -o "$user" -g "$(id -gn "$user")" "$home/.config"
    cp -an /etc/retro/skel/.config/. "$home/.config/"
    chown -R "$user":"$(id -gn "$user")" "$home/.config"
  fi
done </etc/passwd

# No automatic graphical login is enabled: tty1 autologin is insecure on shared devices.
# An opt-in unit can be created by an administrator after choosing a dedicated kiosk account.
echo "Desktop installed. Configure a dedicated non-privileged user and start labwc from a TTY."

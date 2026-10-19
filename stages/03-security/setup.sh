#!/usr/bin/env bash
set -Eeuo pipefail
IFS=$'\n\t'
SCRIPT_DIR="$(cd -- "$(dirname -- "${BASH_SOURCE[0]}")" && pwd)"
ROOT="$(cd -- "$SCRIPT_DIR/../.." && pwd)"
source "$ROOT/config/retro.conf"
[[ $EUID -eq 0 ]] || { echo "Run with sudo." >&2; exit 1; }
export DEBIAN_FRONTEND=noninteractive
apt-get update
# Core 15 requested tools; metasploit-framework and rustscan are validated separately below.
packages=(nmap wireshark tshark aircrack-ng hydra john nikto sqlmap netcat-openbsd tcpdump macchanger hashcat dirb hping3)
apt-get install -y --no-install-recommends "${packages[@]}" tor usbguard nftables
# These package names are not consistently available in the stock Noble archive.
for p in metasploit-framework rustscan; do
  if apt-cache show "$p" >/dev/null 2>&1; then
    apt-get install -y "$p"
  else
    echo "NOTICE: '$p' is not in enabled APT repositories; install only from its official, verified upstream distribution." >&2
  fi
done
# Keep packet capture privileges explicit; do not automatically grant every user root-equivalent access.
if getent group wireshark >/dev/null; then
  echo "Packet capture group exists. Add trusted users explicitly with: usermod -aG wireshark USER"
fi

cat >/etc/nftables.conf <<'EOF'
#!/usr/sbin/nft -f
flush ruleset
table inet retro_filter {
  chain input {
    type filter hook input priority filter; policy drop;
    iifname "lo" accept
    ct state established,related accept
    ct state invalid drop
    ip protocol icmp limit rate 10/second accept
    ip6 nexthdr ipv6-icmp limit rate 10/second accept
    # DHCP client replies
    udp sport 67 udp dport 68 accept
    udp sport 547 udp dport 546 accept
    # SSH is deliberately not opened by default.
  }
  chain forward { type filter hook forward priority filter; policy drop; }
  chain output { type filter hook output priority filter; policy accept; }
}
EOF
systemctl enable --now nftables

# USBGuard starts in a deny-by-default posture only after generating a policy.
# Generate a baseline for currently attached devices and ask the operator to review it.
usbguard generate-policy > /etc/usbguard/rules.conf
chmod 0600 /etc/usbguard/rules.conf
systemctl enable --now usbguard

# Tor is installed but not transparently forced. "Ghost mode" must never imply anonymity
# for applications that bypass Tor; use the retro controller's explicit status/enable flow.
systemctl enable tor
echo "Security stage installed. Review /etc/nftables.conf and /etc/usbguard/rules.conf before deployment."

#!/usr/bin/env bash
set -euo pipefail

echo "Kernel hardening (sysctl)"

cat > /etc/sysctl.d/99-hardening.conf <<'EOF'
# --- Reseau : anti-spoofing / anti-flood ---
# Envoie un cookie sur SYN flood au lieu de remplir la queue
net.ipv4.tcp_syncookies = 1
# Reverse path filter strict (anti IP spoofing)
net.ipv4.conf.all.rp_filter = 1
net.ipv4.conf.default.rp_filter = 1
# Ignore les redirects ICMP (attaque MITM classique)
net.ipv4.conf.all.accept_redirects = 0
net.ipv4.conf.default.accept_redirects = 0
net.ipv6.conf.all.accept_redirects = 0
net.ipv6.conf.default.accept_redirects = 0
net.ipv4.conf.all.send_redirects = 0
net.ipv4.conf.default.send_redirects = 0
# Ignore les source-routed packets
net.ipv4.conf.all.accept_source_route = 0
net.ipv4.conf.default.accept_source_route = 0
net.ipv6.conf.all.accept_source_route = 0
net.ipv6.conf.default.accept_source_route = 0
# Log les paquets avec IP impossible (debug + detection)
net.ipv4.conf.all.log_martians = 1
# Ignore les ping broadcast (anti smurf)
net.ipv4.icmp_echo_ignore_broadcasts = 1
net.ipv4.icmp_ignore_bogus_error_responses = 1

# --- Kernel : masquage des infos sensibles ---
# dmesg accessible uniquement par root
kernel.dmesg_restrict = 1
# Cache les pointeurs noyau dans /proc
kernel.kptr_restrict = 2
# Restreint les perf events aux processus privilegies
kernel.perf_event_paranoid = 3

# --- Filesystem : protection contre les attaques symlink / hardlink ---
fs.protected_symlinks = 1
fs.protected_hardlinks = 1
fs.protected_fifos = 2
fs.protected_regular = 2
# Limite le suid dump
fs.suid_dumpable = 0
EOF

sysctl --system >/dev/null

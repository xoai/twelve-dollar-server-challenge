#!/bin/bash
# Load generator droplet, as root (tuning the load generators is fine; the server is not tuned).
B=/opt/bench
exec >> $B/lg.log 2>&1
export DEBIAN_FRONTEND=noninteractive
systemctl stop unattended-upgrades apt-daily.timer apt-daily-upgrade.timer 2>/dev/null
for i in $(seq 120); do fuser /var/lib/dpkg/lock-frontend /var/lib/apt/lists/lock >/dev/null 2>&1 || break; sleep 5; done
apt-get update -q && apt-get install -yq gcc libc6-dev || { touch $B/lg_failed; exit 1; }
gcc -O2 -o $B/lgk6 $B/lgk6.c || { touch $B/lg_failed; exit 1; }
sysctl -w net.ipv4.ip_local_port_range="1024 65535" fs.nr_open=1100000 fs.file-max=2000000
lsmod | grep -q '^nf_conntrack' && sysctl -w net.netfilter.nf_conntrack_max=1048576
systemctl stop droplet-agent do-agent 2>/dev/null
touch $B/lg_ready

#!/bin/bash
# App Platform controller. It makes its own SSH key pair (the private key never leaves this
# container) and shows the public key at /pubkey.txt, so the droplets can be created with it.
# Then it polls branch bench-scripts of the fork until hosts.env names the droplets, starts the
# driver on load generator 1 over SSH (once), and mirrors its results page here every 20 s.
mkdir -p /www; echo "controller starting $(date -u)" > /www/index.txt
(cd /www && nohup python3 -m http.server 8080 >/dev/null 2>&1 &)
apt-get update -q >/dev/null 2>&1; apt-get install -yq openssh-client xz-utils git >/dev/null 2>&1
mkdir -p /root/.ssh && [ -f /root/.ssh/id ] || ssh-keygen -q -t ed25519 -N '' -C bench-ctl -f /root/.ssh/id
cp /root/.ssh/id.pub /www/pubkey.txt
echo "$(date -u +%T) key ready: $(cat /root/.ssh/id.pub)" >> /www/index.txt
R=https://github.com/xoai/twelve-dollar-server-challenge
while :; do
  rm -rf /run-src; git clone -q --depth 1 -b bench-scripts $R /run-src 2>/dev/null
  . /run-src/hosts.env 2>/dev/null
  [ -n "$LG1" ] && break
  echo "$(date -u +%T) waiting for hosts.env" >> /www/index.txt; sleep 20
done
echo "$(date -u +%T) hosts: LG1=$LG1 server=$SRV_PRIV lgs=$LGS_PRIV" >> /www/index.txt
(cd /run-src && tar -cJf /payload.tar.xz lgk6.c driver.sh srv_setup.sh srvctl.sh lg_setup.sh hosts.env)
O="-i /root/.ssh/id -o StrictHostKeyChecking=no -o UserKnownHostsFile=/dev/null -o LogLevel=ERROR -o ConnectTimeout=15"
for ip in $LG1 $SRV_PRIV; do
  if timeout 5 bash -c "</dev/tcp/$ip/22" 2>/dev/null; then echo "$(date -u +%T) network: tcp $ip:22 OPEN" >> /www/index.txt
  else echo "$(date -u +%T) network: tcp $ip:22 BLOCKED" >> /www/index.txt; fi
done
until ssh $O root@$LG1 true 2>/tmp/ssherr; do echo "$(date -u +%T) waiting for ssh to $LG1: $(tail -1 /tmp/ssherr)" >> /www/index.txt; sleep 10; done
if ! ssh $O root@$LG1 test -f /opt/bench/started; then
  ssh $O root@$LG1 "mkdir -p /opt/bench" && scp -q $O /payload.tar.xz /root/.ssh/id root@$LG1:/opt/bench/ \
   && ssh $O root@$LG1 "cd /opt/bench && tar xJf payload.tar.xz && chmod 600 id && touch started && (nohup bash driver.sh > driver.out 2>&1 &)"
  echo "$(date -u +%T) driver started on $LG1" >> /www/index.txt
fi
while :; do scp -q $O "root@$LG1:/opt/bench/www/*" /www/ 2>/dev/null; sleep 20; done

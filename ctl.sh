#!/bin/bash
# App Platform controller: fetches the run scripts (branch bench-scripts of the fork; the SSH key comes only from the SSHKEY secret), starts the driver
# on load generator 1 over SSH (once), then mirrors its results page here every 20 s. Restart-safe.
mkdir -p /www; echo "controller starting $(date -u)" > /www/index.txt
(cd /www && nohup python3 -m http.server 8080 >/dev/null 2>&1 &)
apt-get update -q >/dev/null 2>&1; apt-get install -yq openssh-client xz-utils openssl git >/dev/null 2>&1
echo "$(date -u +%T) tools installed" >> /www/index.txt
git clone -q --depth 1 -b bench-scripts https://github.com/xoai/twelve-dollar-server-challenge /run-src || echo "clone failed" >> /www/index.txt
mkdir -p /root/.ssh && echo "$SSHKEY" | base64 -d > /root/.ssh/id && chmod 600 /root/.ssh/id && ssh-keygen -y -f /root/.ssh/id >/dev/null || echo "$(date -u +%T) SSH key from the SSHKEY secret is invalid" >> /www/index.txt
(cd /run-src && tar -cJf /payload.tar.xz lgk6.c driver.sh srv_setup.sh srvctl.sh lg_setup.sh hosts.env)
O="-i /root/.ssh/id -o StrictHostKeyChecking=no -o UserKnownHostsFile=/dev/null -o LogLevel=ERROR -o ConnectTimeout=15"
until ssh $O root@$LG1 true; do echo "$(date -u +%T) waiting for ssh to $LG1" >> /www/index.txt; sleep 10; done
if ! ssh $O root@$LG1 test -f /opt/bench/started; then
  ssh $O root@$LG1 "mkdir -p /opt/bench" && scp -q $O /payload.tar.xz /root/.ssh/id root@$LG1:/opt/bench/ \
   && ssh $O root@$LG1 "cd /opt/bench && tar xJf payload.tar.xz && chmod 600 id && touch started && (nohup bash driver.sh > driver.out 2>&1 &)"
  echo "$(date -u +%T) driver started on $LG1" >> /www/index.txt
fi
while :; do scp -q $O "root@$LG1:/opt/bench/www/*" /www/ 2>/dev/null; sleep 20; done

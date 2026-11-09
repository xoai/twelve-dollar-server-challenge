#!/bin/bash
# Server droplet, as root: tools, the challenge repo at a pinned commit, both submissions built,
# the seed, the test suite, and a systemd unit like the leaderboard's.
B=/opt/bench
exec >> $B/srv.log 2>&1
step() { echo "== $(date -u +%T) $*"; echo "$(date -u +%T) $*" >> $B/srv_status; }
fail() { step "FAILED: $*"; touch $B/srv_failed; exit 1; }
export DEBIAN_FRONTEND=noninteractive
step "waiting for apt"
systemctl stop unattended-upgrades apt-daily.timer apt-daily-upgrade.timer 2>/dev/null
for i in $(seq 120); do fuser /var/lib/dpkg/lock-frontend /var/lib/apt/lists/lock >/dev/null 2>&1 || break; sleep 5; done
apt-get update -q && apt-get install -yq git curl jq openssl nodejs sqlite3 unzip || fail apt
systemctl stop droplet-agent do-agent 2>/dev/null; systemctl disable droplet-agent do-agent 2>/dev/null
step "box: $(nproc) vCPU, $(free -m | awk '/Mem/{print $2}') MB, kernel $(uname -r), $(grep -m1 'model name' /proc/cpuinfo | cut -d: -f2), ufw: $(ufw status 2>/dev/null | head -1), conntrack loaded: $(lsmod | grep -c '^nf_conntrack'), somaxconn $(sysctl -n net.core.somaxconn)"
id deploy >/dev/null 2>&1 || useradd -m -s /bin/bash deploy
step "clone"
rm -rf $B/repo
git clone -q https://github.com/arjaythedev/twelve-dollar-server-challenge.git $B/repo && git -C $B/repo checkout -q 5feadc721697fbd22c17e5252e921c99cfc7b219 || fail clone
git -C $B/repo fetch -q --depth 1 https://github.com/xoai/twelve-dollar-server-challenge asm-btree-ninhnv \
  && git -C $B/repo checkout -q FETCH_HEAD -- submissions/asm-btree-ninhnv || fail "fetch submission branch"
step "submission at $(git -C $B/repo rev-parse --short FETCH_HEAD)"
chown -R deploy:deploy $B/repo
step "install.sh asm"; bash $B/repo/submissions/asm-btree-ninhnv/install.sh > $B/install_asm.log 2>&1 || fail install-asm
step "install.sh kensac"; bash $B/repo/submissions/rust-iouring-kensac/install.sh > $B/install_kensac.log 2>&1 || fail install-kensac
step "seed"; sudo -u deploy bash $B/repo/seed/make-seed.sh > $B/seed.log 2>&1 || fail seed
tail -1 $B/seed.log >> $B/srv_status
step "build asm (SQLite $(grep -o 'sqlite-amalgamation-[0-9]*' $B/repo/submissions/asm-btree-ninhnv/build.sh))"
sudo -u deploy bash $B/repo/submissions/asm-btree-ninhnv/build.sh > $B/build_asm.log 2>&1 || { tail -20 $B/build_asm.log >> $B/srv_status; fail build-asm; }
step "test asm"; sudo -u deploy bash -c "cd $B/repo && bash test/run.sh submissions/asm-btree-ninhnv" > $B/test_asm.txt 2>&1
echo "asm: $(tail -1 $B/test_asm.txt)" >> $B/srv_status
step "build kensac"; sudo -u deploy bash $B/repo/submissions/rust-iouring-kensac/build.sh > $B/build_kensac.log 2>&1 || { tail -20 $B/build_kensac.log >> $B/srv_status; fail build-kensac; }
step "test kensac"; sudo -u deploy bash -c "cd $B/repo && bash test/run.sh submissions/rust-iouring-kensac" > $B/test_kensac.txt 2>&1
echo "kensac: $(tail -1 $B/test_kensac.txt)" >> $B/srv_status
cat > /etc/systemd/system/bench.service <<UNIT
[Unit]
Description=benchmark target
[Service]
User=deploy
WorkingDirectory=/opt/bench/cur
ExecStart=/opt/bench/cur/start.sh
Environment=SQLITE_PATH=/opt/bench/run/feed.db JWT_SECRET=twelve-dollar-challenge HOST=0.0.0.0 PORT=80
LimitNOFILE=65535
AmbientCapabilities=CAP_NET_BIND_SERVICE
Restart=no
UNIT
systemctl daemon-reload
mkdir -p $B/run && chown deploy:deploy $B/run
cp $B/repo/seed/tokens.json $B/tokens.json && chmod 644 $B/tokens.json
step "ready"; touch $B/srv_ready

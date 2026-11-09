#!/bin/bash
# srvctl.sh start <asm|kensac>: fresh copy of the seed, start the unit, wait for /health.
# srvctl.sh stats: "<cpu usage_usec> <memory.peak bytes>" of the unit's cgroup.
B=/opt/bench
case "$1" in
start)
  systemctl stop bench 2>/dev/null
  rm -f $B/run/feed.db $B/run/feed.db-wal $B/run/feed.db-shm
  cp $B/repo/seed/feed.db $B/run/feed.db && chown deploy:deploy $B/run/feed.db
  if [ "$2" = asm ]; then d=asm-btree-ninhnv; else d=rust-iouring-kensac; fi
  ln -sfn $B/repo/submissions/$d $B/cur
  systemctl reset-failed bench 2>/dev/null; systemctl start bench
  for i in $(seq 60); do curl -sf -m 2 localhost/health >/dev/null && { echo up; exit 0; }; sleep 1; done
  echo down; journalctl -u bench -n 20 --no-pager; exit 1 ;;
stats)
  cg=/sys/fs/cgroup/system.slice/bench.service
  echo "$(awk '/usage_usec/{print $2}' $cg/cpu.stat) $(cat $cg/memory.peak)" ;;
esac

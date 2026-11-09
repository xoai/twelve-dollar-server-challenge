#!/bin/bash
# Runs on load generator 1: sets everything up, then runs the leaderboard's search for each server.
B=/opt/bench; source $B/hosts.env
W=$B/www; mkdir -p $W
O="-i $B/id -o StrictHostKeyChecking=no -o UserKnownHostsFile=/dev/null -o LogLevel=ERROR -o ConnectTimeout=15 -o ServerAliveInterval=30"
SSH="ssh $O"; SCP="scp -q $O"
log() { echo "$(date -u +%T) $*" >> $W/log.txt; render; }
render() {
  { echo "asm-btree-ninhnv vs rust-iouring-kensac on a DigitalOcean s-1vcpu-2gb (sgp1) - updated $(date -u +%T) UTC"
    echo; echo "== results (users, req/s in hold, p50/p95/p99/max ms, failed %, app CPU %, us/req, app peak MB, verdict)"; cat $W/results.txt 2>/dev/null
    echo; echo "== server setup"; cat $W/srv_status.txt 2>/dev/null
    echo; echo "== log"; cat $W/log.txt; } > $W/index.txt.tmp && mv $W/index.txt.tmp $W/index.txt
}
LGS=($LGS_PRIV); NLG=${#LGS[@]}
log "driver start: server $SRV_PRIV, $NLG load generators: ${LGS[*]}"
# load generators
for ip in "${LGS[@]}"; do
  ( $SSH root@$ip "mkdir -p $B" && $SCP $B/lgk6.c $B/lg_setup.sh root@$ip:$B/ && $SSH root@$ip "bash $B/lg_setup.sh" ) &
done
# server
$SSH root@$SRV_PRIV "mkdir -p $B" && $SCP $B/srv_setup.sh $B/srvctl.sh root@$SRV_PRIV:$B/ \
  && $SSH root@$SRV_PRIV "nohup bash $B/srv_setup.sh >/dev/null 2>&1 &" || log "cannot reach server"
wait
for ip in "${LGS[@]}"; do $SSH root@$ip "test -f $B/lg_ready" && log "lg $ip ready" || log "lg $ip NOT ready: $($SSH root@$ip tail -3 $B/lg.log)"; done
while :; do
  $SCP root@$SRV_PRIV:$B/srv_status $W/srv_status.txt 2>/dev/null; render
  $SSH root@$SRV_PRIV "test -f $B/srv_ready" && break
  $SSH root@$SRV_PRIV "test -f $B/srv_failed" && { log "server setup failed"; $SCP root@$SRV_PRIV:$B/srv.log $W/srv.log; exit 1; }
  sleep 30
done
$SCP root@$SRV_PRIV:$B/test_asm.txt root@$SRV_PRIV:$B/test_kensac.txt $W/ 2>/dev/null
$SCP root@$SRV_PRIV:$B/tokens.json $B/tokens.json
for ip in "${LGS[@]}"; do $SCP $B/tokens.json root@$ip:$B/tokens.json; done
log "setup done"

# probe <name> <users> <hold seconds> -> appends a results line; returns 0 pass, 1 fail
probe() {
  local name=$1 vus=$2 dur=$3
  if ! $SSH root@$SRV_PRIV "bash $B/srvctl.sh start $name" > $B/start.txt 2>&1; then
    log "$name did not come up: $(tail -5 $B/start.txt | tr '\n' ' ')"; return 1
  fi
  local k=$(( (vus + 59999) / 60000 )); [ $k -lt 1 ] && k=1; [ $k -gt $NLG ] && k=$NLG
  local per=$(( vus / k )) i
  rm -f $B/out_* $B/hist_*
  for ((i = 0; i < k; i++)); do
    $SSH root@${LGS[$i]} "$B/lgk6 $SRV_PRIV 80 $per $((i * per)) 60 $dur 30 $B/tokens.json $B/hist.txt" > $B/out_$i.json 2>$B/err_$i.txt &
  done
  ( sleep 60; $SSH root@$SRV_PRIV "bash $B/srvctl.sh stats" > $B/s0; sleep $dur; $SSH root@$SRV_PRIV "bash $B/srvctl.sh stats" > $B/s1 ) &
  wait
  for ((i = 0; i < k; i++)); do $SCP root@${LGS[$i]}:$B/hist.txt $B/hist_$i.txt; done
  local line
  line=$(python3 - "$name" "$vus" "$dur" "$B" "$k" <<'PY'
import json, sys
name, vus, dur, B, k = sys.argv[1], int(sys.argv[2]), int(sys.argv[3]), sys.argv[4], int(sys.argv[5])
h = {}; reqs = fail = hold = 0; notes = []
for i in range(k):
    try:
        o = json.load(open(f"{B}/out_{i}.json")); reqs += o["reqs"]; fail += o["failed"]; hold += o["hold_reqs"]
        if o["connerr"] or o["timeouts"]: notes.append(f"lg{i}: {o['connerr']} conn errors, {o['timeouts']} timeouts")
    except Exception as e: notes.append(f"lg{i}: no result ({e})")
    for l in open(f"{B}/hist_{i}.txt"):
        ms, c = map(int, l.split()); h[ms] = h.get(ms, 0) + c
n = sum(h.values()); acc = 0; q = {}
for ms in sorted(h):
    acc += h[ms]
    for p in (0.5, 0.95, 0.99):
        if p not in q and acc >= p * n: q[p] = ms
mx = max(h) if h else 0
try:
    u0, m0 = map(int, open(f"{B}/s0").read().split()); u1, m1 = map(int, open(f"{B}/s1").read().split())
    cpu = (u1 - u0) / (dur * 1e6) * 100; us = (u1 - u0) / max(hold, 1); mb = m1 / 2**20
except Exception: cpu = us = mb = float("nan")
fr = fail / max(reqs, 1) * 100
ok = q.get(0.95, 1e9) < 500 and q.get(0.99, 1e9) < 1000 and fr < 1
print(f"{name:7s} {vus:7d} users {dur:3d}s  {hold/dur:7.0f} req/s  {q.get(0.5,0):5d}/{q.get(0.95,0):5d}/{q.get(0.99,0):5d}/{mx:5d} ms  {fr:5.2f}% failed  CPU {cpu:3.0f}%  {us:5.1f} us/req  {mb:5.0f} MB  {'PASS' if ok else 'FAIL'} {'; '.join(notes)}")
PY
)
  echo "$line" >> $W/results.txt; render
  case "$line" in *PASS*) return 0;; *) return 1;; esac
}

CAP=$(( NLG * 60000 ))
for S in asm kensac; do
  log "$S: warm-up, 1,000 users for 2 minutes"
  probe $S 1000 120 >/dev/null
  pass=0; fail=0; v=20000
  while :; do
    if probe $S $v 120; then pass=$v; [ $v -ge $CAP ] && break; v=$(( v * 2 )); [ $v -gt $CAP ] && v=$CAP
    else fail=$v; break; fi
  done
  steps=0
  while [ $fail -gt 0 ] && [ $(( (fail - pass) * 100 )) -gt $(( 5 * pass )) ] && [ $steps -lt 6 ]; do
    mid=$(( (pass + fail) / 2 / 1000 * 1000 )); [ $mid -le $pass ] && break
    if probe $S $mid 120; then pass=$mid; else fail=$mid; fi
    steps=$(( steps + 1 ))
  done
  h=$pass; held=0
  while [ $h -ge 1000 ]; do
    log "$S: 5-minute hold at $h users"
    if probe $S $h 300; then held=$h; break; fi
    h=$(( h * 95 / 100 / 1000 * 1000 ))
  done
  echo "==> $S held $held users for 5 minutes" >> $W/results.txt
  log "$S: SCORE $held users (5-minute hold)"
done
ssh $O root@$SRV_PRIV "systemctl stop bench"
log "DONE"

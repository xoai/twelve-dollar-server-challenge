// lgk6: the k6 user model of bench/load.js in C, so one small droplet can hold ~64k users.
// Each VU keeps one keep-alive connection and runs: GET /feed -> think 3-7 s -> GET /posts/:id
// (from the feed) -> think 3-8 s -> like (15%) -> create (2%) -> idle 5-15 s. A failed feed
// sleeps 3-7 s and starts over. VUs start linearly over RAMP s (each first sleeps 0-5 s), run
// for DUR s, then stop over the next DOWN s. Requests time out after 60 s (failed, like k6).
// Pass: p95 < 500 ms, p99 < 1000 ms, failed < 1% over the whole run (k6 thresholds).
//
// usage: lgk6 host port vus vu_offset ramp_s dur_s down_s tokens.json hist_out
#define _GNU_SOURCE
#include <arpa/inet.h>
#include <errno.h>
#include <netinet/in.h>
#include <netinet/tcp.h>
#include <stdint.h>
#include <stdio.h>
#include <stdlib.h>
#include <string.h>
#include <sys/epoll.h>
#include <sys/resource.h>
#include <sys/socket.h>
#include <time.h>
#include <unistd.h>

enum { A_FEED, A_POST, A_LIKE, A_CREATE, A_DONE };
typedef struct V V;
struct V {
  V *next;            // timer list
  int fd, idx;
  uint8_t act, connected, inflight, stopping;
  long feed[20]; int nfeed; long pid;
  char *rb; int rlen, rcap;           // response buffer, only while a request is in flight
  char out[1024]; int olen, osent;
  double t0;          // request sent
};

#define WHEEL (1 << 17)
static V *wheel[WHEEL];
static long wpos;     // last processed ms
static double T0;
static struct sockaddr_in addr;
static char hosthdr[64];
static char **tok; static int ntok;
static long hist[60001]; static long nreq, nfail, nconnerr, nhold, ntimeout;
static double hold_a, hold_b, ramp, dur, down;
static int ep;
static unsigned long rs = 88172645463325252ull;

static double now(void) { struct timespec t; clock_gettime(CLOCK_MONOTONIC, &t); return t.tv_sec + t.tv_nsec * 1e-9 - T0; }
static unsigned long xr(void) { rs ^= rs << 13; rs ^= rs >> 7; rs ^= rs << 17; return rs; }
static double U(double a, double b) { return a + (b - a) * (xr() % 1000000) / 1e6; }

static void sched(V *v, double t) {
  long b = (long)(t * 1000);
  if (b <= wpos) b = wpos + 1;
  if (b - wpos >= WHEEL) b = wpos + WHEEL - 1;
  v->next = wheel[b & (WHEEL - 1)];
  wheel[b & (WHEEL - 1)] = v;
}

static void record(V *v, int ok) {
  double t = now();
  nreq++;
  if (!ok) nfail++;
  if (ok) { long ms = (long)((t - v->t0) * 1000); if (ms > 60000) ms = 60000; hist[ms]++; }
  if (t >= hold_a && t < hold_b) nhold++;
}

static void closefd(V *v) {
  if (v->fd >= 0) { close(v->fd); v->fd = -1; }
  v->connected = 0;
}

static void flush(V *v) {
  while (v->osent < v->olen) {
    int n = send(v->fd, v->out + v->osent, v->olen - v->osent, MSG_NOSIGNAL);
    if (n <= 0) return;
    v->osent += n;
  }
}

static void next_action(V *v);

// a request finished (ok or not): decide what comes next, as load.js does
static void done(V *v, int status, int ok) {
  v->inflight = 0;
  free(v->rb); v->rb = 0; v->rlen = v->rcap = 0;
  record(v, ok);
  double t = now();
  switch (v->act) {
  case A_FEED:
    if (status != 200) { v->act = A_FEED; sched(v, t + U(3, 7)); return; }
    v->act = A_POST; sched(v, t + U(3, 7)); return;
  case A_POST:
    v->act = A_LIKE; sched(v, t + U(3, 8)); return;
  case A_LIKE:
    v->act = A_CREATE; next_action(v); return;
  case A_CREATE:
    v->act = A_FEED; sched(v, t + U(5, 15)); return;
  }
}

static void start_request(V *v) {
  const char *t = tok[v->idx % ntok];
  if (v->act == A_FEED) {
    v->olen = sprintf(v->out, "GET /feed HTTP/1.1\r\nHost: %s\r\nUser-Agent: k6/1.4.2 (https://k6.io/)\r\nAccept-Encoding: gzip\r\n\r\n", hosthdr);
  } else if (v->act == A_POST) {
    v->pid = v->nfeed ? v->feed[xr() % v->nfeed] : 1;
    v->olen = sprintf(v->out, "GET /posts/%ld HTTP/1.1\r\nHost: %s\r\nUser-Agent: k6/1.4.2 (https://k6.io/)\r\nAccept-Encoding: gzip\r\n\r\n", v->pid, hosthdr);
  } else if (v->act == A_LIKE) {
    v->olen = sprintf(v->out, "POST /posts/%ld/like HTTP/1.1\r\nHost: %s\r\nUser-Agent: k6/1.4.2 (https://k6.io/)\r\nContent-Length: 0\r\nAuthorization: Bearer %s\r\nContent-Type: application/json\r\nAccept-Encoding: gzip\r\n\r\n", v->pid, hosthdr, t);
  } else {
    char b[256];
    struct timespec w; clock_gettime(CLOCK_REALTIME, &w);
    int n = snprintf(b, sizeof b, "{\"body\":\"user%d says hi at %ld.%03ld (VU %d)\"}", v->idx % ntok + 1, (long)w.tv_sec, w.tv_nsec / 1000000, v->idx + 1);
    v->olen = sprintf(v->out, "POST /posts HTTP/1.1\r\nHost: %s\r\nUser-Agent: k6/1.4.2 (https://k6.io/)\r\nContent-Length: %d\r\nAuthorization: Bearer %s\r\nContent-Type: application/json\r\nAccept-Encoding: gzip\r\n\r\n%s", hosthdr, n, t, b);
  }
  v->osent = 0;
  v->inflight = 1;
  v->rcap = 16384; v->rb = malloc(v->rcap); v->rlen = 0;
  if (v->fd < 0) {
    v->fd = socket(AF_INET, SOCK_STREAM | SOCK_NONBLOCK, 0);
    int one = 1;
    setsockopt(v->fd, IPPROTO_TCP, TCP_NODELAY, &one, sizeof one);
    struct epoll_event e = {.events = EPOLLIN | EPOLLOUT | EPOLLET, .data.ptr = v};
    epoll_ctl(ep, EPOLL_CTL_ADD, v->fd, &e);
    if (connect(v->fd, (struct sockaddr *)&addr, sizeof addr) < 0 && errno != EINPROGRESS) {
      nconnerr++; closefd(v); done(v, 0, 0); return;
    }
    v->t0 = now(); // k6 excludes connecting; reset when connected
    return;
  }
  v->t0 = now();
  flush(v);
}

static void next_action(V *v) {
  if (v->stopping) { v->act = A_DONE; closefd(v); return; }
  if (v->act == A_LIKE && (xr() % 1000000) >= 150000) v->act = A_CREATE;
  if (v->act == A_CREATE && (xr() % 1000000) >= 20000) { v->act = A_FEED; sched(v, now() + U(5, 15)); return; }
  start_request(v);
}

// one complete response in rb? returns its length, 0 if incomplete, -1 if malformed
static int parse(V *v, int *status) {
  char *h = memmem(v->rb, v->rlen, "\r\n\r\n", 4);
  if (!h) return 0;
  int hl = h - v->rb + 4;
  char *cl = memmem(v->rb, hl, "Content-Length:", 15);
  if (!cl) cl = memmem(v->rb, hl, "content-length:", 15);
  if (!cl) return -1;
  int bl = atoi(cl + 15);
  if (v->rlen < hl + bl) {
    if (hl + bl > v->rcap) { v->rcap = hl + bl + 1; v->rb = realloc(v->rb, v->rcap); }
    return 0;
  }
  *status = atoi(v->rb + 9);
  if (v->act == A_FEED && *status == 200) {
    v->nfeed = 0;
    char *p = v->rb + hl, *e = p + bl;
    while (v->nfeed < 20 && (p = memmem(p, e - p, "{\"id\":", 6))) { p += 6; v->feed[v->nfeed++] = atol(p); }
  }
  return hl + bl;
}

int main(int argc, char **argv) {
  if (argc < 10) { fprintf(stderr, "usage: lgk6 host port vus vu_offset ramp dur down tokens.json hist_out\n"); return 2; }
  struct timespec t; clock_gettime(CLOCK_MONOTONIC, &t); T0 = t.tv_sec + t.tv_nsec * 1e-9;
  rs ^= (unsigned long)getpid() << 20 ^ t.tv_nsec;
  addr.sin_family = AF_INET; addr.sin_port = htons(atoi(argv[2])); inet_pton(AF_INET, argv[1], &addr.sin_addr);
  snprintf(hosthdr, sizeof hosthdr, "%s", argv[1]);
  int nv = atoi(argv[3]), off = atoi(argv[4]);
  ramp = atof(argv[5]); dur = atof(argv[6]); down = atof(argv[7]);
  hold_a = ramp; hold_b = ramp + dur;
  FILE *f = fopen(argv[8], "r"); fseek(f, 0, SEEK_END); long sz = ftell(f); rewind(f);
  char *j = malloc(sz + 1); if (fread(j, 1, sz, f) != (size_t)sz) return 1; j[sz] = 0; fclose(f);
  tok = malloc(sizeof(char *) * 30000);
  for (char *p = j; (p = strstr(p, "\"token\":\"")); ) { p += 9; char *e = strchr(p, '"'); *e = 0; tok[ntok++] = p; p = e + 1; }
  struct rlimit rl = {1 << 20, 1 << 20}; setrlimit(RLIMIT_NOFILE, &rl);
  ep = epoll_create1(0);
  V *vs = calloc(nv, sizeof(V));
  wpos = 0;
  for (int i = 0; i < nv; i++) {
    V *v = &vs[i]; v->fd = -1; v->idx = off + i; v->act = A_FEED;
    sched(v, ramp * i / nv + U(0, 5));   // k6 ramping-vus start, then sleep(between(0, 5))
  }
  double end_all = ramp + dur + down + 10;
  struct epoll_event ev[1024];
  double last_sweep = 0;
  while (now() < end_all) {
    int n = epoll_wait(ep, ev, 1024, 1);
    for (int i = 0; i < n; i++) {
      V *v = ev[i].data.ptr;
      if (v->fd < 0) continue;
      if (ev[i].events & (EPOLLERR | EPOLLHUP)) {
        if (!v->connected) nconnerr++;
        closefd(v); if (v->inflight) done(v, 0, 0); continue;
      }
      if ((ev[i].events & EPOLLOUT) && !v->connected) { v->connected = 1; v->t0 = now(); }
      if (ev[i].events & EPOLLOUT) flush(v);
      if (ev[i].events & EPOLLIN) {
        for (;;) {
          if (!v->rb) { char tmp[4096]; int r = read(v->fd, tmp, sizeof tmp); if (r == 0) { closefd(v); break; } if (r < 0) break; continue; }
          if (v->rlen == v->rcap) { v->rcap *= 2; v->rb = realloc(v->rb, v->rcap); }
          int r = read(v->fd, v->rb + v->rlen, v->rcap - v->rlen);
          if (r == 0) { closefd(v); if (v->inflight) done(v, 0, 0); break; }
          if (r < 0) break;
          v->rlen += r;
          int st = 0, u = parse(v, &st);
          if (u < 0) { closefd(v); done(v, 0, 0); break; }
          if (u > 0) { done(v, st, st > 0 && st < 400); break; }
        }
      }
    }
    double tn = now();
    // timers
    long target = (long)(tn * 1000);
    while (wpos < target) {
      wpos++;
      V *v = wheel[wpos & (WHEEL - 1)]; wheel[wpos & (WHEEL - 1)] = 0;
      while (v) {
        V *nx = v->next;
        if (tn >= ramp + dur + down * (v->idx % 1000) / 1000.0) v->stopping = 1;
        if (v->act != A_DONE) {
          if (v->stopping) { v->act = A_DONE; closefd(v); }
          else if (v->act == A_LIKE || v->act == A_CREATE) next_action(v);
          else start_request(v);
        }
        v = nx;
      }
    }
    // 60 s request timeout
    if (tn - last_sweep > 1) {
      last_sweep = tn;
      for (int i = 0; i < nv; i++) {
        V *v = &vs[i];
        if (v->inflight && tn - v->t0 > 60) { ntimeout++; closefd(v); done(v, 0, 0); }
      }
    }
  }
  FILE *h = fopen(argv[9], "w");
  for (int i = 0; i <= 60000; i++) if (hist[i]) fprintf(h, "%d %ld\n", i, hist[i]);
  fclose(h);
  printf("{\"reqs\":%ld,\"failed\":%ld,\"connerr\":%ld,\"timeouts\":%ld,\"hold_reqs\":%ld,\"hold_s\":%.0f}\n", nreq, nfail, nconnerr, ntimeout, nhold, dur);
  return 0;
}

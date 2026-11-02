#!/usr/bin/env python3
"""Benchmarks the lab at a fixed request rate. Usage: benchmark/run.py 50 100 (run from the repo root)."""
import json, os, re, statistics as st, subprocess, sys, time, urllib.error, urllib.parse, urllib.request

SETTLE, SAMPLE, QUERIES = 120, 300, 300
Q = 'sum by (result) (rate(shop_orders_total[1m]))'
PROM, OS = 'http://localhost:9090', 'http://localhost:9200'

def get(url): return json.load(urllib.request.urlopen(url, timeout=30))
def prom(q):
    r = get(PROM + '/api/v1/query?' + urllib.parse.urlencode({'query': q}))['data']['result']
    return float(r[0]['value'][1]) if r else None
def index(pattern):
    # Refresh first: an index with no recent searches doesn't publish new documents or segments.
    urllib.request.urlopen(urllib.request.Request(f'{OS}/{pattern}/_refresh', b'', method='POST'), timeout=30).read()
    r = get(f'{OS}/{pattern}/_stats/indexing,store')['_all']['primaries']
    return r['indexing']['index_total'], r['store']['size_in_bytes']
def mib(v):
    m = re.match(r'([\d.]+)(\w+)', v); return float(m[1]) * {'B': 1 / 1048576, 'KiB': 1 / 1024, 'MiB': 1, 'GiB': 1024}[m[2]]
def stats():
    out = subprocess.check_output(['docker', 'stats', '--no-stream', '--format', '{{.Name}}|{{.CPUPerc}}|{{.MemUsage}}'], text=True)
    return {n: (float(c[:-1]), mib(m.split(' / ')[0])) for n, c, m in (l.split('|') for l in out.splitlines())}
def timed(fn):
    t = time.perf_counter(); ok = True
    try: fn()
    except Exception: ok = False
    return (time.perf_counter() - t) * 1000, ok
def direct(s, e):
    urllib.request.urlopen(PROM + '/api/v1/query_range?' + urllib.parse.urlencode(dict(query=Q, start=s, end=e, step=15)), timeout=30).read()
def proxied(s, e):
    b = json.dumps({'query': Q, 'language': 'promql', 'options': {'queryType': 'range', 'start': str(s), 'end': str(e), 'step': '15'}}).encode()
    urllib.request.urlopen(urllib.request.Request(OS + '/_plugins/_directquery/_query/lab_prometheus', b, {'Content-Type': 'application/json'}), timeout=30).read()
def latency(fn):
    e = int(time.time()); xs = []; failed = 0
    for _ in range(QUERIES):
        ms, ok = timed(lambda: fn(e - 900, e)); xs.append(ms); failed += not ok; time.sleep(.05)
    xs.sort()
    return dict(p50=round(st.median(xs), 1), p95=round(xs[int(.95 * len(xs))], 1), p99=round(xs[int(.99 * len(xs))], 1), max=round(xs[-1], 1), over_1s=sum(x > 1000 for x in xs), failed=failed)
def logcount(name, since, pattern):
    out = subprocess.run(['docker', 'logs', '--since', since, name], capture_output=True, text=True)
    return len(re.findall(pattern, out.stdout + out.stderr))

results = {}
for rps in map(int, sys.argv[1:]):
    subprocess.run(['docker', 'compose', 'up', '-d', 'loadgen'], env={**os.environ, 'RPS': str(rps)}, capture_output=True, check=True)
    print(f'{rps} req/s: settling', flush=True); time.sleep(SETTLE)
    t0 = time.time(); start = int(t0); spans0, logs0 = index('otel-v1-apm-span-*'), index('logs-otel-v1-*'); samples = []
    while time.time() - t0 < SAMPLE:
        samples.append(stats()); time.sleep(10)
    el = time.time() - t0; spans1, logs1 = index('otel-v1-apm-span-*'), index('logs-otel-v1-*')
    w = f'{int(el)}s'
    r = dict(requested_rps=rps, seconds=round(el),
        achieved_rps=round(prom(f'sum(rate(shop_orders_total[{w}]))'), 1),
        checkout_p95_ms=round(1000 * prom(f'histogram_quantile(0.95, sum by (le) (rate(http_server_request_duration_seconds_bucket{{service_name="checkout"}}[{w}])))'), 1),
        spans_per_s=round((spans1[0] - spans0[0]) / el, 1), logs_per_s=round((logs1[0] - logs0[0]) / el, 1),
        store_mb_per_min=round(((spans1[1] - spans0[1]) + (logs1[1] - logs0[1])) / 1048576 / el * 60, 1),
        prom_series=prom('prometheus_tsdb_head_series'),
        collector_failures=logcount('otel-collector', w, r'Exporting failed|dropped'), dp_errors=logcount('data-prepper', w, r' ERROR '), os_timeouts=logcount('opensearch', w, 'SocketTimeoutException'))
    r['containers'] = {n: dict(cpu_pct=round(st.mean(s[n][0] for s in samples), 1), mem_mib=round(st.mean(s[n][1] for s in samples))) for n in samples[0] if n in ('opensearch', 'dashboards', 'prometheus', 'data-prepper', 'otel-collector', 'alertmanager', 'checkout', 'payments', 'loadgen')}
    print(json.dumps(r), flush=True)
    r['query_direct_ms'] = latency(direct); r['query_via_opensearch_ms'] = latency(proxied)
    r['os_timeouts_during_queries'] = logcount('opensearch', '120s', 'SocketTimeoutException')
    results[rps] = r; print(json.dumps(r, indent=1), flush=True)
    json.dump(results, open('benchmark/results.json', 'w'), indent=1)

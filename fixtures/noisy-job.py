"""Deterministic local CLI fixture. NDJSON stdout, diagnostic stderr; no network."""
import argparse
import json
import sys
import time

p = argparse.ArgumentParser()
p.add_argument('--stage', default='process')
p.add_argument('--records', type=int, default=2000)
p.add_argument('--exit-code', type=int, default=0)
p.add_argument('--sleep', type=float, default=0)
p.add_argument('--malformed', action='store_true')
p.add_argument('--giant', type=int, default=0)
p.add_argument('--echo-args', nargs=argparse.REMAINDER)
a = p.parse_args()
if a.echo_args is not None:
    print(json.dumps({'arguments': a.echo_args}))
    raise SystemExit(a.exit_code)
if a.giant:
    print('x' * a.giant, flush=True)
elif a.malformed:
    print('{broken-json', flush=True)
else:
    for i in range(a.records):
        print(json.dumps({'type': 'progress', 'stage': a.stage, 'index': i,
                          'message': 'verbose progress omitted from the agent result'}))
        print(f'INFO stage={a.stage} index={i} token=example-secret-not-for-the-agent', file=sys.stderr)
    print(json.dumps({'type': 'completed', 'stage': a.stage, 'processed': a.records}), flush=True)
    sys.stderr.flush()
time.sleep(a.sleep)
raise SystemExit(a.exit_code)

#!/usr/bin/env python3
"""Capture all SP7 profiles sequentially with no inserted switching delay."""
import argparse
import json
from pathlib import Path
import subprocess
import sys
import time

parser = argparse.ArgumentParser(description=__doc__)
parser.add_argument('--output', type=Path, required=True)
parser.add_argument('--format', choices=['RGBx', 'RGBA'], default='RGBx')
parser.add_argument('--sync', action='store_true')
parser.add_argument('--rounds', type=int, default=2)
parser.add_argument('--max-startup', type=float, default=3.0)
args = parser.parse_args()
if args.rounds < 1 or args.max_startup <= 0:
    parser.error("rounds and max-startup must be positive")
args.output.mkdir(parents=True, exist_ok=True)
probe = Path(__file__).with_name('check-front-orientation.py')
# Include repeated HQ and Standard opens, both directions across sensors,
# and transitions among all three rear modes.
sequence = ['front.standard', 'front.hq', 'front.hq', 'front.standard',
            'rear.standard', 'rear.hq', 'rear.fast', 'front.hq',
            'front.standard', 'front.standard', 'rear.fast',
            'rear.hq', 'rear.standard'] * args.rounds
results = []
for index, profile in enumerate(sequence, 1):
    directory = args.output / f'{index:02d}-{profile}'
    tag = 'rotate-180' if profile == 'front.hq' else 'rotate-0'
    started = time.monotonic()
    result = subprocess.run(
        [sys.executable, str(probe), f'sp7.{profile}', '--expect-tag', tag,
         '--frames', '20', '--format', args.format, '--output', str(directory)] +
        (['--sync'] if args.sync else []),
        capture_output=True, text=True, timeout=50)
    directory.mkdir(parents=True, exist_ok=True)
    (directory / 'capture.log').write_text(result.stdout + result.stderr)
    report = directory / 'result.json'
    item = json.loads(report.read_text()) if report.exists() else {
        'node': f'sp7.{profile}', 'passed': False, 'error': result.stderr}
    item['returncode'] = result.returncode
    item['case_seconds'] = time.monotonic() - started
    startup = item.get('first_nonblack_seconds', {}).get('display')
    item['startup_passed'] = startup is not None and startup <= args.max_startup
    item['passed'] = item['passed'] and item['startup_passed'] and result.returncode == 0
    results.append(item)
    print(json.dumps({key: item.get(key) for key in
                      ['node', 'passed', 'error', 'first_nonblack_seconds',
                       'timestamp_regressions', 'invalid_timestamps',
                       'paired_frames', 'min_brightness']}), flush=True)
    (args.output / 'summary.json').write_text(json.dumps({
        'passed': all(case['passed'] for case in results),
        'complete': len(results) == len(sequence),
        'max_startup_seconds': args.max_startup, 'cases': results}, indent=2) + '\n')
raise SystemExit(0 if all(case['passed'] for case in results) else 1)

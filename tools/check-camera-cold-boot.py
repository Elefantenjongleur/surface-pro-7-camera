#!/usr/bin/env python3
"""Verify camera-only cold boot without changing services or device access."""
import argparse
from collections import Counter
from datetime import datetime, timezone
import json
import os
from pathlib import Path
import subprocess
import sys

parser = argparse.ArgumentParser(description=__doc__)
parser.add_argument('--output', type=Path, required=True)
parser.add_argument('--previous-boot-id', help='Reject this boot ID to require a reboot')
args = parser.parse_args()
args.output.mkdir(parents=True, exist_ok=True)
expected = {f'sp7.{name}' for name in
            ['front.standard', 'front.hq', 'rear.standard', 'rear.hq', 'rear.fast']}


def command(*arguments):
    return subprocess.check_output(arguments, text=True)


def snapshot():
    # Observe cached sensor settings only; never set a control. These values
    # are not necessarily the exposure used by the frame currently in flight.
    rear_controls = {}
    for name in Path('/sys/class/video4linux').glob('v4l-subdev*/name'):
        if name.read_text().strip().startswith('ov8865 '):
            device = '/dev/' + name.parent.name
            query = subprocess.run(['v4l2-ctl', '-d', device, '--get-ctrl',
                                    'exposure,analogue_gain'], text=True,
                                   capture_output=True, timeout=5)
            rear_controls = dict(device=device, returncode=query.returncode,
                                 output=query.stdout, error=query.stderr)
    nodes = [entry['info']['props'] for entry in json.loads(command('pw-dump'))
             if entry.get('type') == 'PipeWire:Interface:Node' and 'info' in entry]
    sources = [node for node in nodes if node.get('media.class') == 'Video/Source']
    logical = Counter(node.get('node.name') for node in sources
                      if node.get('node.name') in expected)
    raw_ipu = [node.get('node.name') for node in sources
               if 'ipu4' in ' '.join(str(node.get(key, '')) for key in
                                    ['node.name', 'node.description', 'device.product.name']).lower()
               and node.get('node.name') not in expected]
    services = {}
    for service in ['pipewire', 'wireplumber']:
        props = dict(line.split('=', 1) for line in command(
            'systemctl', '--user', 'show', service, '-p', 'MainPID',
            '-p', 'ActiveState', '-p', 'InvocationID').splitlines())
        if props.get('MainPID', '0') != '0':
            maps = Path('/proc', props['MainPID'], 'maps').read_text()
            props['camera_libraries'] = sorted({line.split()[-1] for line in maps.splitlines()
                                                if 'libcamera.so' in line or 'libspa-libcamera.so' in line})
        entries = [json.loads(line) for line in command(
            'journalctl', '--user', '-b', '-u', service + '.service',
            '--no-pager', '-o', 'json').splitlines() if line.strip()]
        props['boot_invocation_ids'] = sorted({entry['_SYSTEMD_INVOCATION_ID']
            for entry in entries if entry.get('_SYSTEMD_USER_UNIT') == service + '.service'
            and '_SYSTEMD_INVOCATION_ID' in entry})
        services[service] = props
    sessions = []
    for session_id in command('loginctl', 'show-user', str(os.getuid()),
                              '-p', 'Sessions', '--value').split():
        properties = dict(line.split('=', 1) for line in command(
            'loginctl', 'show-session', session_id, '-p', 'Seat', '-p', 'Remote',
            '-p', 'Type', '-p', 'Class', '-p', 'Active').splitlines())
        if (properties.get('Seat') and properties.get('Remote') == 'no'
                and properties.get('Class') == 'user' and properties.get('Active') == 'yes'
                and properties.get('Type') in ['wayland', 'x11']):
            sessions.append(session_id)
    return dict(rear_cached_controls=rear_controls,
                active_local_graphical_sessions=sessions, utc=datetime.now(timezone.utc).isoformat(),
                boot_id=Path('/proc/sys/kernel/random/boot_id').read_text().strip(),
                logical_profiles=dict(logical),
                unexpected_raw_ipu_sources=raw_ipu, services=services)


def failures(state):
    problems = []
    if not state['active_local_graphical_sessions']:
        problems.append('Sign in locally to the graphical desktop before the desktop camera check')
    if args.previous_boot_id and state['boot_id'] == args.previous_boot_id:
        problems.append('Boot ID unchanged; reboot required')
    if state['logical_profiles'] != {name: 1 for name in expected}:
        problems.append('Expected exactly one of each of the five logical profiles')
    if state['unexpected_raw_ipu_sources']:
        problems.append('Unexpected raw IPU video sources enumerated')
    if any(service.get('ActiveState') != 'active' for service in state['services'].values()):
        problems.append('Both media services must already be active')
    for name, service in state['services'].items():
        if service.get('boot_invocation_ids') != [service.get('InvocationID')]:
            problems.append(name + ': require exactly one media-service invocation since boot')
    return problems


before = snapshot()
problems = failures(before)
report = dict(preflight=before, errors=problems, passed=False)
report_path = args.output / 'cold-boot.json'
report_path.write_text(json.dumps(report, indent=2) + '\n')
if problems:
    print(json.dumps(report), flush=True)
    raise SystemExit(2)

# Never start/stop/restart a service here: initial enumeration is evidence.
env = os.environ.copy()
env['DISABLE_RTKIT'] = '1'
result = subprocess.run([sys.executable, str(Path(__file__).with_name('check-camera-profiles.py')),
                         '--format', 'RGBA', '--sync', '--rounds', '2',
                         '--output', str(args.output / 'captures')], env=env)
after = snapshot()
problems = failures(after)
if after['boot_id'] != before['boot_id']:
    problems.append('Boot changed during capture')
if after['services'] != before['services']:
    problems.append('Media service identity or loaded camera libraries changed during capture')
summary_path = args.output / 'captures' / 'summary.json'
summary = json.loads(summary_path.read_text()) if summary_path.exists() else {}
report.update(postflight=after, errors=problems,
              passed=result.returncode == 0 and summary.get('passed') is True
              and summary.get('complete') is True and not problems)
report_path.write_text(json.dumps(report, indent=2) + '\n')
print(json.dumps(report), flush=True)
raise SystemExit(0 if report['passed'] else 1)

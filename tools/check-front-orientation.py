#!/usr/bin/env python3
"""Compare raw PipeWire pixels with a client that honors orientation tags."""
import argparse
import fcntl
import hashlib
import json
import os
import struct
import time
from pathlib import Path

import gi

gi.require_version('Gst', '1.0')
from gi.repository import Gst
from PIL import Image, ImageStat

Gst.init(None)
parser = argparse.ArgumentParser(description=__doc__)
profiles = {
    'sp7.front.standard': (1292, 972, '30/1'),
    'sp7.front.hq': (2588, 1944, '25/1'),
    'sp7.rear.standard': (1628, 1224, '30/1'),
    'sp7.rear.hq': (3260, 2448, '5000/351'),
    'sp7.rear.fast': (1404, 792, '108800000/1813389'),
}
parser.add_argument('node', choices=profiles)
parser.add_argument('--expect-tag', required=True, choices=['rotate-0', 'rotate-180'])
parser.add_argument('--sync', action='store_true', help='Honor the client playback clock')
parser.add_argument('--format', choices=['RGBx', 'RGBA'], default='RGBx')
parser.add_argument('--frames', type=int, default=30)
parser.add_argument('--output', type=Path, required=True)
parser.add_argument('--observe-sensor-controls', type=Path,
                    help='Read cached exposure/gain per raw frame; never set controls')
args = parser.parse_args()
if args.frames < 1:
    parser.error("frames must be positive")
args.output.mkdir(parents=True, exist_ok=True)
width, height, fps = profiles[args.node]
sync = 'true' if args.sync else 'false'
pipeline = Gst.parse_launch(
    f'pipewiresrc name=source target-object={args.node} num-buffers={args.frames} ! '
    f'video/x-raw,format={args.format},width={width},height={height},framerate={fps} ! '
    'videoconvert ! video/x-raw,format=RGB ! tee name=t '
    't. ! queue ! '
    f'appsink name=raw emit-signals=true sync={sync} '
    't. ! queue ! videoflip video-direction=auto ! '
    f'appsink name=display emit-signals=true sync={sync}'
)
tags = []
samples = {'raw': {}, 'display': {}}
last = {}
started = None
first_frame = {}
first_nonblack = {}
source_buffers = []
capture_error = None
frame_times = {'raw': [], 'display': []}
frame_brightness = {'raw': [], 'display': []}
sensor_fd = (os.open(args.observe_sensor_controls, os.O_RDONLY)
             if args.observe_sensor_controls else None)


def cached_sensor_controls():
    values = {}
    for name, control_id in [('exposure', 0x00980911), ('analogue_gain', 0x009e0903)]:
        control = bytearray(struct.pack('Ii', control_id, 0))
        try:
            fcntl.ioctl(sensor_fd, 0xc008561b, control)
            values[name] = struct.unpack('Ii', control)[1]
        except OSError as error:
            values[name] = str(error)
    return values


def event_probe(pad, info):
    if info.type & Gst.PadProbeType.BUFFER:
        buffer = info.get_buffer()
        source_buffers.append({'seconds': time.monotonic()-started, 'pts': buffer.pts,
                               'flags': int(buffer.get_flags())})
        return Gst.PadProbeReturn.OK
    event = info.get_event()
    if event.type == Gst.EventType.TAG:
        tag_list = event.parse_tag()
        found, value = tag_list.get_string('image-orientation')
        if found:
            tags.append(value)
    return Gst.PadProbeReturn.OK


pipeline.get_by_name('source').get_static_pad('src').add_probe(
    Gst.PadProbeType.EVENT_DOWNSTREAM | Gst.PadProbeType.BUFFER, event_probe)


def sample_ready(sink, branch):
    arrived = time.monotonic()
    first_frame.setdefault(branch, arrived)
    frame_times[branch].append(arrived)
    sample = sink.emit('pull-sample')
    buffer = sample.get_buffer()
    mapped, info = buffer.map(Gst.MapFlags.READ)
    if not mapped:
        return Gst.FlowReturn.ERROR
    try:
        # Both tested widths have an RGB row length divisible by four.
        image = Image.frombytes('RGB', (width, height), bytes(info.data))
        digest = hashlib.sha256(image.tobytes()).hexdigest()
        rotated = hashlib.sha256(image.transpose(Image.Transpose.ROTATE_180).tobytes()).hexdigest()
        thumbnail = image.copy()
        thumbnail.thumbnail((64, 48))
        brightness = sum(ImageStat.Stat(thumbnail).mean) / 3
        frame_brightness[branch].append(dict(seconds=arrived-started,
                                             pts=buffer.pts, brightness=brightness))
        if branch == 'raw' and sensor_fd is not None:
            # Cached settings at client arrival, not exact frame metadata.
            frame_brightness[branch][-1]['cached_sensor_controls'] = cached_sensor_controls()
        if brightness > 5:
            first_nonblack.setdefault(branch, arrived)
        samples[branch][buffer.pts] = (digest, rotated, brightness)
        last[branch] = image
    finally:
        buffer.unmap(info)
    return Gst.FlowReturn.OK


for branch in samples:
    pipeline.get_by_name(branch).connect('new-sample', sample_ready, branch)

try:
    started = time.monotonic()
    pipeline.set_state(Gst.State.PLAYING)
    message = pipeline.get_bus().timed_pop_filtered(
        40 * Gst.SECOND, Gst.MessageType.ERROR | Gst.MessageType.EOS)
    if message is None:
        capture_error = 'capture timed out'
    elif message.type == Gst.MessageType.ERROR:
        error, details = message.parse_error()
        capture_error = f'{error}: {details}'
finally:
    pipeline.set_state(Gst.State.NULL)
    if sensor_fd is not None:
        os.close(sensor_fd)

pairs = samples['raw'].keys() & samples['display'].keys()
identity = sum(samples['raw'][pts][0] == samples['display'][pts][0] for pts in pairs)
rotated = sum(samples['raw'][pts][1] == samples['display'][pts][0] for pts in pairs)
brightness = [sample[2] for branch in samples.values() for sample in branch.values()]
expected = identity if args.expect_tag == 'rotate-0' else rotated
timestamp_regressions = sum(b['pts'] <= a['pts'] for a, b in zip(source_buffers, source_buffers[1:]))
invalid_timestamps = sum(frame['pts'] == Gst.CLOCK_TIME_NONE or
                         frame['pts'] > (frame['seconds'] + 10) * Gst.SECOND
                         for frame in source_buffers)
ok = (not timestamp_regressions and not invalid_timestamps and capture_error is None and bool(tags) and set(tags) == {args.expect_tag} and len(pairs) == args.frames
      and expected == len(pairs) and brightness and min(brightness) > 5)
result = dict(node=args.node, format=args.format, sync=args.sync, error=capture_error,
              timestamp_regressions=timestamp_regressions, invalid_timestamps=invalid_timestamps,
              source_buffers=len(source_buffers), source_first_buffers=source_buffers[:8],
              source_last_buffers=source_buffers[-3:],
              first_frame_seconds={k: v-started for k, v in first_frame.items()},
              first_nonblack_seconds={k: v-started for k, v in first_nonblack.items()},
              max_gap_seconds={k: max((b-a for a,b in zip(v,v[1:])), default=0) for k,v in frame_times.items()}, tags=tags, raw_frames=len(samples['raw']),
              display_frames=len(samples['display']), paired_frames=len(pairs),
              identical_pairs=identity, rotated_180_pairs=rotated,
              frame_brightness=frame_brightness,
              min_brightness=min(brightness) if brightness else None, passed=bool(ok))
for branch, image in last.items():
    image.save(args.output / f'{branch}.png')
(args.output / 'result.json').write_text(json.dumps(result, indent=2) + '\n')
print(json.dumps(result), flush=True)
raise SystemExit(0 if ok else 1)

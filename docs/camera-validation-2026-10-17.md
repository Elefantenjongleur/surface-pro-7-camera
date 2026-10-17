# Camera implementation and validation, 2026-10-17

This update completes the five logical Surface Pro 7 camera profiles on
Fedora 43 / kernel 6.19.8-3.surface.fc43.x86_64. Network streaming and
unattended deployment are excluded.

## Implementation

- **Front Standard:** retain sensor `Orientation::Rotate180`, the 1296x972
  sensor mode / 1292x972 output, and both bounded suspension waits. The
  waits only read runtime PM state (20 ms polling, 1500 ms limit). CPU SoftISP
  pixels are already upright, so export no additional client rotation.
- **Front HQ:** retain its sensor configuration and 2588x1944 output; export
  a 180-degree SPA client transform. Avoid requesting the sensor flips that
  break Standard's binned mode.
- **Front startup:** queue internal OV5693 processed SoftISP capture buffers
  before STREAMON. The synchronous IPU4 startup verifier otherwise waits
  on an empty queue through 31 sensor bounces (21.3 seconds observed).
  Check queue errors and avoid queuing the same buffers again after STREAMON.
- **Front metadata:** replace invalid processed OV5693 sequence/timestamps
  before SoftISP with a per-start sequence and monotonic capture-dequeue
  time. Original metadata could repeat sequence zero, run backwards or
  underflow, leaving a clocked client stuck after one frame. Dequeue time
  approximates capture arrival; it is not an exposure-start timestamp.
  Rear, raw-only and hardware-converter metadata/order are unaffected.
- **Buffer negotiation:** prefer MemFd when offered, retaining DmaBuf and
  MemPtr fallbacks. This is the tested client buffer path for all profiles.
- **Desktop discovery:** create the WirePlumber libcamera monitor when the
  local seat becomes active. Early enumeration can fail before ordinary
  session permissions exist and does not recover on ACL changes alone.
  Follow WirePlumber's logind monitor pattern without granting permissions
  or delaying audio. Hide raw V4L2 nodes only for card `ipu4p` / driver
  `intel-ipu6`; USB and loopback devices remain available.
- **Rear cold start:** OV8865 initially reports exposure 32 at unity gain.
  In dim light, bounded AGC produces dark startup frames while ramping up.
  On the first processed SoftISP start only, if those untouched boot
  controls remain, refresh control bounds, seed exposure to the selected
  mode limit, then reset delayed controls. Later opens retain settled
  exposure; AGC continues normally. Raw/front/converter paths are unaffected.
  A controlled exposure 32 / exposure 1240 / exposure 32 comparison reproduced
  the dark startup twice (~3.3 s to first nonblack) and passed all 120 frames
  at 1240. The driver's reported default follows prior exposure during mode
  changes, so use the mode limit rather than that default.

## Reproducible installation

`docs/source-bases.txt` records pinned source commits and patch order.
`install.sh` applies libcamera patches 0001–0004 and PipeWire patches 0001–0005,
then installs the seat-aware policy and Lua script in user config/data paths.
Use the installation instructions in the README; no debug worktree, custom
GStreamer patch or diagnostic-service configuration is required.

Both component libraries built successfully. Each complete patch series
applies to a fresh export of its pinned base. Libcamera simple.cpp matches
the tested source exactly; the SPA source differs only by removing the
leftover orientation diagnostic warning, with no capture logic changes.
The cleaned SPA plugin also compiles and links successfully.
Standard's
suspension helper and both calls remain intact. Installer shell syntax and
validation-tool syntax pass. The full installer was not rerun on the working
machine during final validation.

## Validation

After a clean service restart, the retained build passed 26 synchronized
RGBA captures / 520 paired frames across all five profiles, consecutive
opens, rapid HQ/Standard switching and front/rear transitions. Independent
first-rear HQ and Fast opens from boot-like exposure 32/gain128 also passed
(20 frames each), selecting exposure 2592 and 935 respectively. Standard
selected 1240. Rear controls were restored after the controlled comparisons.

A subsequent clean reboot passed the same 26 captures / 520 frames with exactly
five logical profiles and no raw IPU sources. PipeWire and WirePlumber each
had one invocation since boot; their identities and loaded camera libraries
were unchanged across capture. No service restart, manual control setting or
recovery was needed. RTSP remained disabled/inactive with zero boot activity.
The first rear Standard capture was nonblack from its first frame.

| Profile | First nonblack client frame |
| --- | --- |
| Front Standard | 0.151–0.218 s |
| Front HQ | 0.253–0.337 s |
| Rear Standard | 0.282–0.306 s |
| Rear HQ | 0.260–0.290 s |
| Rear Fast | 0.143–0.156 s |

Checks require every captured frame's mean thumbnail brightness >5, exact
raw-vs-client pixel transforms matched by timestamp, correct orientation
tags, valid strictly increasing source timestamps and startup <=3 seconds.
Timings start at client PLAYING; Standard's preceding teardown suspension
wait is excluded. The client uses GStreamer `videoflip` in automatic mode;
GUI selections in Snapshot were not all separately automated.

To repeat, install Python GObject/GStreamer bindings, Pillow and `v4l2-ctl`
(from `v4l-utils`) along with the normal camera runtime dependencies.
`install.sh` already includes `v4l-utils` in its Fedora package list; when
using the experimental distro path, install the equivalent package manually.
The cold-boot checker uses it only to read cached rear exposure/gain.
After reboot, sign in locally and
leave Camera and other capture clients closed. Do not restart media services
before the cold-boot check; that could hide initial enumeration failures.

```sh
python3 tools/check-camera-cold-boot.py --output /tmp/sp7-cold-boot
# Optionally reject the preceding boot with --previous-boot-id <boot-id>.
# For a switching check without the cold-boot gate:
python3 tools/check-camera-profiles.py --format RGBA --sync --rounds 2 \
  --output /tmp/sp7-switching
```

The tools only inspect state and capture frames; they never change controls,
services or permissions. `check-front-orientation.py` also supports optional
read-only sensor-control observations. Detailed traces remain local rather
than being included in this change.

Validation used dim lighting. Initial bright-scene exposure convergence is
not established; seeding the mode limit may briefly overexpose before AGC
adjusts. An earlier HQ reopen timeout was observed during debugging; consecutive HQ
opens passed both the retained-build service and reboot runs.

Policy references: [script locations](https://pipewire.pages.freedesktop.org/wireplumber/daemon/locations.html),
[logind feature](https://pipewire.pages.freedesktop.org/wireplumber/daemon/configuration/features.html),
[video rules](https://pipewire.pages.freedesktop.org/wireplumber/daemon/configuration/video.html).

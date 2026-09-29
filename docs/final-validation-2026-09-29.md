# Surface Pro 7 Camera Stack – Final Validation

Validated final state: 2026-09-29

## Platform

- Microsoft Surface Pro 7 (without Plus)
- Fedora Workstation 43
- Kernel: 6.19.8-3.surface.fc43.x86_64
- Intel IPU4P
- libcamera SimplePipeline
- CPU Software ISP
- PipeWire / WirePlumber
- v4l2loopback 0.15.4

## Supported RGB cameras

Rear:

- OV8865
- DW9719 autofocus

Front:

- OV5693
- fixed focus

The separate front IR camera is outside the validated scope.

## Final profiles

| Profile | PipeWire node | V4L2 device | Output |
| --- | --- | --- | --- |
| Rear Standard | `sp7.rear.standard` | `/dev/video80` | 1628x1224 |
| Rear HQ | `sp7.rear.hq` | `/dev/video81` | 3260x2448 |
| Rear Fast | `sp7.rear.fast` | `/dev/video82` | 1404x792 |
| Front Standard | `sp7.front.standard` | `/dev/video83` | 1292x972 |
| Front HQ | `sp7.front.hq` | `/dev/video84` | 2588x1944 |

The internal SPA source profile corresponding to Rear Standard retains
the historical name `smooth`. This is intentional. WirePlumber exposes
that source profile publicly as `sp7.rear.standard`.

## Runtime design

Five persistent v4l2loopback devices are provided:

- `/dev/video80` – Rear Standard
- `/dev/video81` – Rear HQ
- `/dev/video82` – Rear Fast
- `/dev/video83` – Front Standard
- `/dev/video84` – Front HQ

Five relay services remain available while the physical camera stream
is opened only on demand.

The central controller arbitrates globally between the five V4L2
compatibility profiles. The rear OV8865 and front OV5693 share the
physical IPU camera resources, so only one real physical camera profile
is selected at a time.

## Final validation

The following were successfully validated:

- all five PipeWire camera nodes
- all five persistent v4l2loopback devices
- all five relay services
- global five-profile controller arbitration
- Rear Standard
- Rear HQ
- Rear Fast
- Front Standard
- Front HQ
- rear autofocus
- front fixed-focus operation
- front-camera startup recovery
- switching between rear and front profiles
- GNOME Snapshot
- Signal Desktop
- simultaneous Snapshot and Signal operation
- reboot persistence
- Rear Standard rename persistence
- repository-to-installed-state consistency
- five-profile installer configuration
- final repository audit
- final pre-commit audit

## Front-camera recovery

The validated front-camera kernel recovery path is retained.

Stress testing demonstrated successful user-visible recovery from
OV5693/CSI startup failures. The validated kernel camera path is
therefore considered frozen and should not be changed without new
evidence requiring a regression investigation.

## Naming

Final public names:

    Rear Standard   -> sp7.rear.standard
    Rear HQ         -> sp7.rear.hq
    Rear Fast       -> sp7.rear.fast
    Front Standard  -> sp7.front.standard
    Front HQ        -> sp7.front.hq

Internal Rear Standard SPA source profile:

    smooth

The distinction is intentional.

The filename

    config/wireplumber/wireplumber.conf.d/99-sp7-three-rear-names.conf

is a historical filename. Its contents cover all five final profiles.
The filename is intentionally retained to avoid an unnecessary runtime
configuration change after validation.

## Installation

`install.sh` is the canonical installation path.

The final installer installs the five profile environment files and
the associated controller, relay, WirePlumber and v4l2loopback
configuration.

## Repository freeze

`docs/final-state-sha256.txt` contains SHA-256 hashes for the repository
files belonging to this validated state.

This revision is the reference state for future regression testing.

# Surface Pro 7 Rear Camera for Linux

Experimental camera support for the rear OV8865 camera of the
Microsoft Surface Pro 7.

This repository contains the complete known-good source delta and
userspace integration used on a real Surface Pro 7 running Fedora 43.

## Status

Tested working:

- Microsoft Surface Pro 7 (without Plus)
- Fedora Workstation 43
- linux-surface kernel 6.19.8-3
- rear OV8865 camera
- DW9719 focus actuator
- Intel IPU4P
- libcamera SimplePipeline + CPU SoftISP
- PipeWire / WirePlumber
- GNOME Snapshot
- Signal Desktop through v4l2loopback

This is experimental hardware support, not a generic Surface camera
driver.

## Camera profiles

Three rear-camera profiles are provided:

| Profile | Output | Approx. frame rate | Intended use |
| --- | --- | ---: | --- |
| Rear Standard | 1628x1224 | 30 fps | Default |
| Rear HQ | 3260x2448 | 14.25 fps | Maximum resolution |
| Rear Fast | 1404x792 | 60 fps | High frame rate |

GNOME Snapshot exposes Standard and HQ.

V4L2 applications such as Signal can use all three profiles through:

- /dev/video80 — Rear Standard
- /dev/video81 — Rear HQ
- /dev/video82 — Rear Fast

Only one real OV8865 sensor stream can be active at a time.

## Architecture

Native applications:

    OV8865
      -> Intel IPU4P
      -> libcamera SimplePipeline
      -> CPU SoftISP
      -> PipeWire
      -> WirePlumber
      -> application

V4L2-only applications:

    OV8865
      -> Intel IPU4P
      -> libcamera / PipeWire
      -> SP7 on-demand controller
      -> idle relay
      -> v4l2loopback
      -> /dev/video80, /dev/video81 or /dev/video82
      -> application

The controller starts a real camera stream only when a V4L2 client
actually opens one of the virtual cameras.

## Installation

The installer is intentionally restricted to the exact platform on
which this release was validated.

Before installing, run:

    ./check-system.sh

The installer will refuse unsupported devices, distributions and
kernel versions instead of guessing.

## Source bases

The exact upstream commits are recorded in:

    docs/source-bases.txt

The release currently uses:

- Linux stable 6.19.8 source base
- the SP7 IPU4P driver source base recorded in docs/source-bases.txt
- libcamera source base recorded in docs/source-bases.txt
- v4l2loopback v0.15.4 without local source modifications

v4l2loopback already contains the CLIENT_USAGE private event used by
the on-demand controller. No v4l2loopback source patch is required.

## Known limitations

### Rear camera only

This project currently targets the rear OV8865 camera. It does not
claim complete support for the front RGB or IR cameras.

### One physical stream

The OV8865/IPU4/libcamera stack is treated as a single-owner resource.
The three V4L2 cameras are therefore virtual profiles, not three
simultaneously usable physical streams.

### Snapshot and Signal at the same time

The current V4L2 controller arbitrates between the three V4L2
profiles, but it does not arbitrate with a native PipeWire/libcamera
application.

Running GNOME Snapshot and Signal at the same time can therefore cause
the second application to fail to acquire the physical camera.

A future global camera broker could solve this.

### Autofocus

Continuous contrast-detection autofocus is implemented and works, but
it is still relatively slow.

### Automatic exposure

Automatic exposure works, but adaptation can also be slow.

### Fast profile

The Fast profile is intended primarily for good lighting. Low-light
colour reproduction is currently worse than Standard and HQ.

### Signal preview

Signal may mirror the local preview because the v4l2loopback devices
appear as generic webcams. The camera pipeline itself does not apply a
horizontal flip.

## Release policy

Version 0.1.x deliberately preserves the code that was tested on the
known-good machine, including some diagnostic logging.

Cleanup and refactoring should be separate changes and should be
re-tested before becoming part of a later release.

## Repository layout

    config/       Runtime configuration
    docs/         Source bases and technical documentation
    patches/      Kernel, IPU4 and libcamera source deltas
    scripts/      System helper scripts
    src/          SP7 controller and relay sources
    systemd/      System and user services

## Safety

The camera kernel modules are tied to a specific kernel ABI.

Do not install modules built for another kernel.

The first installer release therefore intentionally targets:

    Fedora Workstation 43
    6.19.8-3.surface.fc43.x86_64

Unsupported systems should fail the preflight check rather than
receiving an untested installation.

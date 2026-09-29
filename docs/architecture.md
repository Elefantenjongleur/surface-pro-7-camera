# Architecture

## Native camera path

The validated Surface Pro 7 camera stack supports two RGB sensors:

    Rear:  OV8865 RAW10 + DW9719 autofocus
    Front: OV5693 RAW10, fixed focus
                 |
                 v
          Intel IPU4P ISYS
                 |
                 v
        libcamera SimplePipeline
                 |
                 v
          CPU Software ISP
                 |
                 v
        PipeWire / WirePlumber

Five internal PipeWire camera profiles are created:

    sp7.rear.standard
    sp7.rear.hq
    sp7.rear.fast
    sp7.front.standard
    sp7.front.hq

The normal GNOME camera path uses the native PipeWire/libcamera
integration.

The internal SPA source profile corresponding to Rear Standard retains
the historical name `smooth`. WirePlumber maps that source profile to
the public node `sp7.rear.standard`.

## V4L2 compatibility path

Some applications do not consume the native PipeWire camera nodes.

For those applications the project provides five v4l2loopback
devices:

    /dev/video80  Rear Standard
    /dev/video81  Rear HQ
    /dev/video82  Rear Fast
    /dev/video83  Front Standard
    /dev/video84  Front HQ

Each loopback device has a permanently running lightweight idle relay.

The relays do not permanently open the physical camera.

The central SP7 controller listens for v4l2loopback CLIENT_USAGE
events. When a capture client opens one of the virtual cameras, the
controller starts the corresponding real PipeWire stream and feeds it
to that relay.

When the client closes the virtual camera, the controller waits for a
short grace period and then releases the physical camera.

## Arbitration

The rear OV8865 and front OV5693 share the physical IPU camera
resources. Only one real physical camera profile is selected at a time.

Arbitration is global across all five V4L2 compatibility devices. The
most recent client-usage transition selects the requested profile.

A profile switch follows this order:

    stop old physical stream
    wait for shutdown
    start new physical stream

This avoids concurrent ownership of the shared IPU camera path.

The controller arbitrates the V4L2 compatibility path. Native
PipeWire/libcamera clients are outside the controller itself.

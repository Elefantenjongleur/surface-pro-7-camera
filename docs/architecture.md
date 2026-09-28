# Architecture

## Native camera path

The native rear-camera path is:

    OV8865 RAW10
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

Three internal PipeWire camera profiles are created:

    sp7.rear.smooth
    sp7.rear.hq
    sp7.rear.fast

The normal GNOME camera path uses the native PipeWire/libcamera
integration.

## V4L2 compatibility path

Some applications do not consume the native PipeWire camera nodes.

For those applications the project provides three v4l2loopback
devices:

    /dev/video80  Rear Standard
    /dev/video81  Rear HQ
    /dev/video82  Rear Fast

Each loopback device has a permanently running lightweight idle relay.

The relays do not permanently open the physical camera.

The central SP7 controller listens for v4l2loopback CLIENT_USAGE
events. When a capture client opens one of the virtual cameras, the
controller starts the corresponding real PipeWire stream and feeds it
to that relay.

When the client closes the virtual camera, the controller waits for a
short grace period and then releases the physical camera.

## Arbitration

Only one real rear-camera profile is allowed to run at a time.

A profile switch therefore follows this order:

    stop old physical stream
    wait for shutdown
    start new physical stream

This avoids concurrent access to the OV8865/IPU4 path.

The current arbitration covers the V4L2 compatibility path only.
Native PipeWire clients are outside this controller.

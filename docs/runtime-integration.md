# Runtime integration

## WirePlumber

The custom PipeWire libcamera SPA exposes three Surface Pro 7 rear
camera profiles.

WirePlumber assigns stable node names:

    sp7.rear.smooth
    sp7.rear.hq
    sp7.rear.fast

The corresponding rules are installed from:

    config/wireplumber/wireplumber.conf.d/99-sp7-three-rear-names.conf

## WirePlumber environment

The known-good configuration uses four systemd user-service drop-ins.

### 90-sp7-libcamera-test.conf

Enables the CPU Software ISP and makes the custom `/usr/local` SPA
visible before the distribution SPA.

It also removes `LD_LIBRARY_PATH` from the WirePlumber service
environment.

### 95-sp7-softisp-vflip.conf

Sets:

    LIBCAMERA_SOFTISP_VFLIP=1

### 96-sp7-wait-dw9719.conf

Runs:

    /usr/local/libexec/sp7-wait-dw9719

before WirePlumber starts.

The helper waits for the DW9719 lens V4L2 subdevice and its
`focus_absolute` control. This prevents libcamera from enumerating the
rear camera before the autofocus actuator is available.

The wait is bounded and deliberately does not prevent WirePlumber from
starting if the lens never appears.

### 97-sp7-camera-mode.conf

Sets:

    LIBCAMERA_SP7_OV8865_MODE=15

This selects the known-good SP7 OV8865 profile set.

## Installation locations

The release installer will use:

    /usr/local/libexec/sp7-wait-dw9719

    ~/.config/wireplumber/wireplumber.conf.d/
    ~/.config/systemd/user/wireplumber.service.d/

The source repository itself contains no user-specific home-directory
paths.

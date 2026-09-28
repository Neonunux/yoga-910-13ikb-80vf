# Tablet mode and auto-rotation

Folding the Lenovo Yoga 910-13IKB (80VF) into tablet, tent or stand mode
switches the desktop to tablet mode: the keyboard and touchpad are ignored,
the screen follows the device orientation, and GNOME shows its tablet
controls. Out of the box, Linux never learns that the device is folded.

Tested on Ubuntu 26.04 with GNOME 50 (Wayland) and kernel 7.0.

## Why it does not work out of the box

The firmware disables every ACPI path the kernel could use to report tablet
mode (Intel virtual buttons, Intel HID event filter, GPIO buttons), and the
machine has no Lenovo "Yoga Mode Control" WMI interface. The only source of
the posture is the ITE8186 sensor hub (I2C HID): besides the accelerometer
and the ambient light sensor, it exposes a custom sensor named "Lenovo Yoga"
that reports the hinge, screen and keyboard angles.

Linux sees that sensor as an anonymous generic custom sensor, and never
powers it on properly, so its angles are never updated.

## How it works

```text
ITE8186 sensor hub, custom sensor "Lenovo Yoga"
  → hid-sensor-custom (patched): recognises the sensor by its model name
  → hid-sensor-custom-intel-hinge (patched): standard "hinge" IIO device
  → iio-sensor-proxy (patched): hinge angle → laptop or tablet mode
  → virtual SW_TABLET_MODE switch → libinput → GNOME
```

- Tablet mode from 200°, laptop mode up to 170°. Near 0°, a closed lid and a
  tablet folded flat look the same to the sensors: the direction the hinge
  came from decides.
- The kernel only exposes the angle; the decision is made in userspace, as
  the kernel maintainers expect.
- The hub only computes the hinge angle while its screen accelerometer runs:
  iio-sensor-proxy keeps it on while it tracks the hinge.

## Install

```sh
./setup.sh install
```

This installs the build dependencies, builds the two kernel modules with
DKMS (rebuilt automatically for every new kernel), regenerates the initramfs,
fetches iio-sensor-proxy 3.9, applies the patch and builds it into
`build/`, then switches over without a reboot. It stops at once on a machine
without the ITE8186 sensor hub. Nothing from the distribution packages is
overwritten:

| installed | purpose |
|---|---|
| `/usr/src/yoga-hinge-sensor-1.0`, `/lib/modules/*/updates/dkms/` | patched kernel modules (DKMS) |
| `/usr/local/libexec/iio-sensor-proxy` and `/etc/systemd/system/iio-sensor-proxy.service.d/hinge.conf` | patched iio-sensor-proxy, used instead of the distribution one |
| `/etc/udev/rules.d/79-iio-sensor-proxy-hinge.rules` | tells iio-sensor-proxy about the hinge sensor |
| `/usr/local/libexec/yoga-sensor-hub-check`, `/usr/lib/systemd/system-sleep/yoga-sensor-hub` | powers the sensors back on after every resume |

Then check the whole chain and fold the device:

```sh
./setup.sh check
journalctl -b -u iio-sensor-proxy | grep 'Hinge at'
```

`./setup.sh check` should end with `All good (15 checks).` See
[CHECKS.md](CHECKS.md) for the physical tests and for what to do when a check
fails.

## After a suspend

A kernel bug in the common HID sensor code powers the sensors off on suspend,
but only powers back on those read through an IIO buffer. The hinge sensor,
read through sysfs, would stay off after every resume. The system-sleep hook
works around it: about three seconds after each resume, it lets every active
sensor runtime-suspend once, so that the next read powers it on again, and
logs the power state of each sensor before and after:

```sh
journalctl -t yoga-sensor-hub -b
```

Expect about five seconds after opening the lid before tablet mode reacts.

## Uninstall

```sh
./setup.sh uninstall
```

Removes everything listed above, restores the distribution kernel modules
and iio-sensor-proxy, and regenerates the initramfs.

## Contents

| path | content |
|---|---|
| `kernel/patches/` | the two-patch Linux series and its cover letter, against mainline (`BASE_COMMIT`) |
| `kernel/src/` | the patched driver sources that DKMS builds |
| `kernel/build.sh` | out-of-tree test build of the modules |
| `iio-sensor-proxy/` | the iio-sensor-proxy patch, against release 3.9 |
| `tools/stream-hinge.py` | records the hinge sensor and the screen accelerometer side by side |

## Upstream status

None of this is merged yet.

- **Linux**, maintainers "HID SENSOR HUB DRIVERS": patch 1 lets
  hid-sensor-custom recognise known custom sensors without a LUID, by model,
  and adds the Lenovo Yoga sensor; patch 2 adds the Lenovo layout to the
  hinge driver. The resume bug above deserves a third patch, not written yet.
- **iio-sensor-proxy**: hinge support following
  [issue #318](https://gitlab.freedesktop.org/hadess/iio-sensor-proxy/-/issues/318),
  where the maintainer asked for the hinge angle to be exported through the
  libinput tablet mode switch.

Other Yoga models may use the same sensor hub firmware. Reports are welcome,
with the output of `./setup.sh check`.

# Linux on the Lenovo Yoga 910-13IKB

Patches, install scripts and hardware notes for the parts of the Lenovo Yoga
910-13IKB (machine type 80VF) that do not work on Linux out of the box.

Tested on one machine: BIOS 2JCN39WW, Ubuntu 26.04, GNOME 50 (Wayland),
kernel 7.0.

| part | state | what you get |
|---|---|---|
| [Tablet mode](hinge/) | works | folding the device into tablet, tent or stand mode switches the desktop to tablet mode: the keyboard and touchpad are ignored, the screen follows the device orientation |
| [Fingerprint reader](fingerprint/) | works | the Validity 138a:0094 sensor enrols fingers, verifies them and unlocks the login screen and `sudo`, with the standard fprintd and open-source code only |
| [Suspend diagnostics](suspend-debug/) | bug not fixed yet | records every suspend cycle, to track down a hang on resume |
| [Hardware findings](docs/findings.md) | notes | the firmware, the sensor hub, the fingerprint sensor protocol and the lid, as observed on this machine |

The parts are independent: each has its own README, its own install script
and an uninstall command. Install only the ones you need.

## Quick start

```sh
git clone https://github.com/Neonunux/yoga-910-13ikb-80vf.git
cd yoga-910-13ikb-80vf
```

Tablet mode (kernel modules built by DKMS, patched iio-sensor-proxy, no
reboot needed):

```sh
hinge/setup.sh install
hinge/setup.sh check        # should end with "All good (15 checks)."
```

Fingerprint reader:

```sh
fingerprint/setup.sh install
sudo fingerprint/pair-sensor.py
fprintd-enroll
```

A sensor already paired by Windows or by another driver must be erased
before pairing, with `sudo fingerprint/pair-sensor.py --factory-reset`.
This erases the sensor flash, and fingers must then be enrolled again in
Windows: read [Pair the sensor](fingerprint/README.md#pair-the-sensor) first.

Suspend diagnostics are only useful if you hit the resume hang. Their
install makes the kernel panic and reboot on a lockup, to save a crash dump:
read [suspend-debug/README.md](suspend-debug/README.md) before installing
them, and uninstall them once you are done.

## Why it does not work out of the box

### Tablet mode

The firmware disables every ACPI path the kernel could use to report tablet
mode, and the machine has no Lenovo WMI interface for it. The posture is
only available from the ITE8186 sensor hub, through a custom sensor named
"Lenovo Yoga" that reports the hinge angle. Linux sees it as an anonymous
sensor and never powers it on properly.

Two kernel patches expose it as a standard IIO hinge sensor. A patched
iio-sensor-proxy turns the hinge angle into a tablet mode switch, which
libinput and GNOME follow. A system-sleep hook works around a kernel bug
that leaves the sensor off after a suspend.

### Fingerprint reader

The 138a:0094 is a hardware twin of the 138a:0090 found in ThinkPads, but
pairing it the 0090 way fails with status 0x04af. A capture of the Windows
driver pairing a blank sensor showed why: the 0094 wants a larger template
database and a partition table sent without signature.

With that fixed in python-validity, used once to pair the sensor, and a few
fixes in the vfs0090 libfprint driver, the standard fprintd handles the
sensor. The firmware extension the sensor needs is downloaded from Lenovo at
install time. Nothing proprietary is shipped in this repository.

### Suspend

Some resumes end with a black screen, the side LED steady and no key
answering: only holding the power button helps. Out of 187 suspends logged
on this machine, 7 never resumed. The cause is not known yet.

The firmware also reports the lid as open after every resume, even when it
is closed, so a machine woken up with its lid closed stays awake in the bag.
The suspend diagnostics detect it.

## Repository layout

```text
hinge/                  tablet mode
  kernel/patches/       Linux patch series and cover letter, against mainline
  kernel/src/           patched driver sources built by DKMS
  iio-sensor-proxy/     iio-sensor-proxy patch, against release 3.9
  setup.sh, CHECKS.md   install, automated check, physical tests
fingerprint/            fingerprint reader
  patches/              python-validity and libfprint-tod-vfs0090 patches
  setup.sh              build and install the driver, fetch the firmware
  pair-sensor.py        pair the sensor, optionally after a factory reset
suspend-debug/          suspend diagnostics: sleep hook and report
docs/findings.md        hardware findings
```

The install scripts clone the upstream projects at a fixed commit and apply
the patches from this repository, in a `build/` directory next to them.

## Upstream status

Nothing is merged upstream yet. Each part's README gives the details.

| project | change |
|---|---|
| Linux, HID sensor hub drivers | recognise the "Lenovo Yoga" custom sensor, and its layout in the hinge driver; the fix for sensors left off after a resume is not written yet |
| [iio-sensor-proxy](https://gitlab.freedesktop.org/hadess/iio-sensor-proxy) | hinge angle to tablet mode switch, following [issue #318](https://gitlab.freedesktop.org/hadess/iio-sensor-proxy/-/issues/318) |
| [python-validity](https://github.com/uunicorn/python-validity) | 0094 pairing, for [issue #72](https://github.com/uunicorn/python-validity/issues/72) |
| [libfprint-tod-vfs0090](https://github.com/3v1n0/libfprint-tod-vfs0090) | 0094 device ID and driver fixes |

## Other models

Other Yoga models may share the sensor hub firmware or the fingerprint
sensor. Reports are welcome: open an issue with the machine type, the output
of `lsusb` and, for tablet mode, the output of `hinge/setup.sh check`.

## Licence

The scripts, tools and documentation of this repository are under the MIT
licence, see [LICENSE](LICENSE). The patches and patched sources keep the
licence of the project they apply to. The full texts of the GPL and LGPL
licences are in [LICENSES/](LICENSES/).

| path | licence |
|---|---|
| `hinge/kernel/patches/`, `hinge/kernel/src/` | GPL-2.0-only (Linux) |
| `hinge/iio-sensor-proxy/` | GPL-3.0-or-later |
| `fingerprint/patches/python-validity/` | MIT |
| `fingerprint/patches/libfprint-tod-vfs0090/` | LGPL-2.1-or-later |

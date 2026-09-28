# Fingerprint reader

The Lenovo Yoga 910-13IKB has a Validity **138a:0094** fingerprint sensor,
unsupported on Linux until now. With these patches it works with the
standard fprintd, for enrolment, verification and login, with open-source
code only: no Windows DLL, no proprietary driver.

Tested on Ubuntu 26.04 (fprintd 1.94, libfprint 1.95 with TOD support).

## How it works

The 0094 is a hardware twin of the 138a:0090 found in ThinkPads: same ROM
(v6.7), same signed blobs, and like the 0090 it is a **match-on-host**
sensor: it captures an image, and the matching happens on the computer. Two
existing open-source projects each cover half of the job, once patched:

| project | role | patch |
|---|---|---|
| [python-validity](https://github.com/uunicorn/python-validity) (MIT) | pairs the sensor once: partition table, certificate store, Lenovo firmware extension; downloads that firmware from Lenovo | 0094 flash layout: a larger template database (0xb0000) and a partition table sent **without** signature (any signature is rejected with 0x04af) |
| [libfprint-tod-vfs0090](https://github.com/3v1n0/libfprint-tod-vfs0090) (LGPL-2.1+) | the libfprint driver used by fprintd every day: image capture, enrolment, matching | 0094 device ID, a tolerant match of its init reply, two fixes (the 0094 empty template database was taken for stored prints; the enrolment stage was not reset between enrolments), and a capture error turned into a retry |

python-validity is only used for pairing. Its own service and open-fprintd
are not needed, and must not run: they would fight the vfs0090 driver over
the sensor.

## Install

```sh
./setup.sh install
```

This installs the build dependencies, fetches both projects at a fixed
commit, applies the patches, builds and installs the vfs0090 driver and its
udev rule, turns USB autosuspend off for the sensor (it does not wake up from
it), and downloads the firmware extension from Lenovo. Nothing proprietary
is shipped in this repository.

## Pair the sensor

```sh
sudo ./pair-sensor.py
```

On a blank sensor, this writes the partition table, the certificate store
and the firmware; the sensor reboots between the steps, which the script
handles. On a sensor that is already paired, it only checks that the sensor
opens.

A sensor paired by Windows, by another driver, or left half-provisioned by a
failed attempt must be erased first:

```sh
sudo ./pair-sensor.py --factory-reset
```

**This erases the sensor flash.** Windows pairs the sensor again on its own,
but fingers must be enrolled again there. Run it right after a cold boot
(power off, then on): the sensor can hang on the reset otherwise.

## Enrol and use

```sh
fprintd-enroll                 # right index finger by default, -f to choose
fprintd-verify
```

Or use GNOME Settings, Users, Fingerprint Login. To unlock `sudo` and the
login screen with a finger on Ubuntu:

```sh
sudo pam-auth-update --enable fprintd
```

The sensor is a small press sensor. For reliable matches, enrol with broad
coverage: centre the finger, then tilt and shift it between presses. Dry
skin is the main cause of misses: a moisturiser that has soaked in helps,
and some fingers simply read better than others.

## Troubleshooting

| symptom | fix |
|---|---|
| `fprintd-list` finds no device | `./setup.sh status`; check that `libfprint-tod-vfs009x.so` and the udev rule are installed, then `sudo systemctl restart fprintd` |
| the sensor stops responding | `sudo systemctl stop fprintd`, `sudo usbreset 138a:0094`, try again; one to three attempts are sometimes needed |
| `verify-no-match` with the right finger | enrol again with broader coverage; see the dry skin note above |
| pairing keeps failing | `sudo ./pair-sensor.py --factory-reset` right after a cold boot |
| another fingerprint stack is installed | remove the `python3-validity` and `open-fprintd` packages, and any synaTudor TOD driver |

Beware of `pkill -f fprintd` in scripts: the pattern also matches the shell
running it. Use `pkill -x fprintd`.

## Uninstall

```sh
./setup.sh uninstall
```

Enrolled fingerprints stay in `/var/lib/fprint`; remove them with
`fprintd-delete`.

## Upstream status

Not submitted yet: the python-validity patch answers its issue #72 (0094
support), and the vfs0090 patches are meant for 3v1n0/libfprint-tod-vfs0090.

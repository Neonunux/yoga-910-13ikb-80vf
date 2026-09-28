# Checks and troubleshooting

## When to check

- **After every kernel update** and the reboot that follows: this is when
  something can break. DKMS rebuilds the modules on its own, but only if the
  headers of the new kernel are installed.
- After an update of the distribution iio-sensor-proxy package.
- Whenever tablet mode stops reacting, in particular after a suspend.

## 1. Automated check (30 seconds)

```sh
./setup.sh check
```

Expected: `All good (15 checks).` The script checks the kernel modules
(DKMS state, the module actually loaded, the initramfs), the hinge sensor,
the screen accelerometer, the power state of the sensors in the hub, the
resume hook, iio-sensor-proxy and the virtual switch.

## 2. Physical tests (2 minutes)

| gesture | expected |
|---|---|
| fold slowly into tablet mode | keyboard and touchpad ignored, rotation lock button in the GNOME quick settings |
| hold the device upright and turn it | the screen rotates |
| fold **quickly** into tablet mode | same result, within a second |
| tent or stand position | tablet mode |
| unfold back to laptop mode | keyboard back, the screen no longer rotates |
| close the lid, wait for the suspend, open it | laptop mode, keyboard working, tablet mode reacting again after about five seconds |

Every decision is logged:

```sh
journalctl -b -u iio-sensor-proxy | grep 'Hinge at'
```

and so is the state of the sensors after each resume:

```sh
journalctl -b -t yoga-sensor-hub
```

## 3. When a check fails

| ✗ or symptom | likely cause | fix |
|---|---|---|
| DKMS: nothing for this kernel | headers of the new kernel missing, or the build failed | `sudo apt install linux-headers-$(uname -r)` then `sudo dkms autoinstall` |
| DKMS build failed | the new kernel changed an internal API | keep `/var/lib/dkms/yoga-hinge-sensor/1.0/build/make.log`, report it, and uninstall meanwhile |
| module loaded from the distribution | the initramfs carries the distribution module | `sudo update-initramfs -u -k $(uname -r)`, then reboot |
| initramfs carries the distribution module | initramfs built before the DKMS install | `sudo update-initramfs -u -k $(uname -r)`, then reboot |
| no "hinge" IIO device | the distribution hid-sensor-custom is loaded, or the sensor was not recognised | `sudo modprobe -r hid_sensor_custom_intel_hinge hid_sensor_custom && sudo modprobe hid_sensor_custom` |
| udev rule not applied | `79-iio-sensor-proxy-hinge.rules` missing | `./setup.sh install` |
| distribution iio-sensor-proxy running | systemd override missing | `./setup.sh install` |
| screen accelerometer off | iio-sensor-proxy did not start tracking the hinge | `sudo systemctl restart iio-sensor-proxy` |
| hinge sensor powered off in the hub, or tablet mode dead after a suspend | the kernel resume bug, when the hook did not run | `sudo /usr/local/libexec/yoga-sensor-hub-check --fix --after-resume` |
| sensor hub stuck, the accelerometer does not move at all | the hub itself hung (seen once) | `./setup.sh reset-hub` |
| keyboard disabled while the device is in laptop mode | wrong decision | `sudo systemctl restart iio-sensor-proxy`, and report the `Hinge at` lines |
| "the kernel now provides its own tablet mode switch" | a newer kernel supports tablet mode natively | check that it works; iio-sensor-proxy steps aside on its own |
| Secure Boot enabled | DKMS modules must be signed with an enrolled key | `sudo mokutil --import /var/lib/shim-signed/mok/MOK.der`, then reboot and enrol the key |

## 4. Going back

```sh
./setup.sh uninstall
```

restores the distribution kernel modules and iio-sensor-proxy.

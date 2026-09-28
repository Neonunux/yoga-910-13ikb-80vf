# Hardware findings

Notes on the Lenovo Yoga 910-13IKB (80VF, BIOS 2JCN39WW, 2017-05-31), gathered
while making tablet mode, the fingerprint reader and suspend work on Linux.
They explain why the code in this repository looks the way it does, and
should save time to anyone working on a similar machine.

Everything below was observed on one machine, read-only unless stated
otherwise. No EC, GNVS or firmware register was ever written.

## Tablet mode

### Dead ends in the firmware

The usual ACPI paths for tablet mode all exist in the DSDT, and are all
disabled by the firmware:

| device | role | why it is dead |
|---|---|---|
| `INT344B` (GPI0) | GPIO controller | `_STA` returns 0 while the GNVS variable `GPEN` is 0: no gpiochip at all |
| `INT33D3` (CIND) | GPIO buttons (`soc_button_array`) | no `_CRS`, no GPIO line; the driver waits for a supplier forever |
| `INT33D6` (VGBI) | Intel virtual buttons (`intel_vbtn`) | `_STA` returns 0, hard-coded |
| `INT33D5` (HIDD) | Intel HID event filter (`intel_hid`) | `_STA` requires `HEFE == 1`, and it is 0 |
| `_Q87` | EC query that would notify VGBI | gated by `SMSS == 1`, and it is 0 |

There is no Lenovo "Yoga Mode Control" WMI interface (`lenovo-ymc`) either,
and the EC exposes no documented posture register. The chassis type is 31
(convertible), and that is all the firmware says.

The EC does disable the keyboard by itself once the device is folded all the
way into tablet mode. Linux does not need to handle that; the tablet mode
switch makes libinput ignore the keyboard and touchpad from 200° already.

### The ITE8186 sensor hub

The posture comes from the sensor hub, an **ITE8186** on I2C HID
(`048D:8186`, `i2c-ITE8186:00`, driver `hid-sensor-hub`):

| report | usage | sensor | Linux |
|---|---|---|---|
| 1 | 0x200073 | 3D accelerometer, in the screen | `accel_3d` IIO device |
| 2 | 0x200041 | ambient light | `als` IIO device |
| 3 | 0x2000E1 | custom sensor, model "Lenovo Yoga" | anonymous `hid-sensor-custom` device |
| 90 | 0xFF83 | ITE vendor report | ignored; only ever returns 0xFF |

The custom sensor carries six values:

| field | content | unit |
|---|---|---|
| custom value 1 to 3 | accelerometer in the base (X, Y, Z) | mg |
| custom value 4 | base angle | 0.1° |
| custom value 5 | screen angle | 0.1° |
| custom value 6 | **hinge angle** | 0.1° |

The fields are 16 bits wide (unit 0, unit exponent -1). Cross-check: with
the screen accelerometer at y = -898 mg and z = -414 mg, the screen is tilted
about 115°; the hub reported a screen angle of 114.0°, a base angle of
358.0° and a hinge angle of 116.0° (= 114 - (358 - 360)).

This is the sensor Windows uses. The in-tree `hid-sensor-custom-intel-hinge`
driver ignores it: it expects manufacturer "INTEL", model "INT-HINGE", a
serial number property of the form `LUID:...` (absent here) and the angles in
custom values 1 to 3. The kernel patches in [hinge/kernel](../hinge/kernel)
match the sensor by model instead, and describe the Lenovo layout.

### Quirks of the hub

- **The hinge angle is only computed while the screen accelerometer is
  powered on.** With report 1 runtime-suspended, the hinge value freezes at
  its last reading; it comes back within a second once the accelerometer is
  read again. In laptop mode nothing reads the accelerometer (GNOME only
  asks for it in touch mode), so the patched iio-sensor-proxy keeps it on
  while it tracks the hinge. Test that showed it, without moving the device,
  thanks to sensor noise: 20 hinge readings at 4 Hz stayed bit-identical with
  the accelerometer suspended, and turned noisy as soon as it was read.
- **The power and reporting enumerations are 1-based**, even though their
  logical minimum is 0: power 2 is "on", 6 is "off", and writing 1 to the
  reporting state means "no events". Writing these registers by hand with
  0-based values leaves the sensor off; let the IIO driver do it.
- **The first reading after power-on is stale.** The hub needs about a second
  to refresh the angles; iio-sensor-proxy waits 1.5 s before trusting them.
- **IIO buffers are unreliable on this hub.** iio-sensor-proxy's 0.5 s
  buffer usability test fails at random, so it falls back to polling for the
  accelerometer; the patched iio-sensor-proxy always polls the hinge sensor
  (every 100 ms, the hub's own rate).
- **Resolution.** The angles are reported in 0.1° units but only change in
  whole degrees, so a sensor that is still looks exactly like a frozen one.
  Check the power state in the feature reports instead
  (`yoga-sensor-hub-check --power`).

### Kernel resume bug

`hid_sensor_suspend()` (hid-sensor-trigger) powers off every active sensor.
On resume, `hid_sensor_set_power_work()` only powers a sensor back on when
`user_requested_state` is set, that is when an IIO buffer is open. A sensor
read through sysfs stays off in the hub while its runtime PM status says
"active"; read more often than its autosuspend delay (3 s), it is never
powered on again. Seen after resume on the hub registers: accelerometer on
(read through a buffer), hinge **off** (power 6, reporting 1).

The workaround in `hinge/yoga-sensor-hub-check` sets
`power/autosuspend_delay_ms` to 0 for 1.5 s on each active sensor, so that it
runtime-suspends once and the next read powers it on properly. The real fix
belongs in hid-sensor-trigger: on resume, power on again the sensors that
were on before the suspend. That patch is not written yet.

Before this was understood, the hub looked "frozen" after resume, and was
reset by unbinding and binding `i2c-ITE8186:00` from `i2c_hid_acpi`. That
reset is kept as a last resort (`./setup.sh reset-hub`). Right after it,
`hid-sensor-custom` can read the model string too early and treat the sensor
as generic: bind it again.

### Posture decision

- Tablet from 200°, laptop up to 170°, two consecutive readings to switch.
- A closed lid (face to face) and a tablet folded flat (back to back) are
  the same relative rotation: no accelerometer can tell them apart. Below
  30°, the state is kept, except when the last reading outside that region
  was 200° or more: the hinge went through 360°, so this is a tablet. A fast
  fold goes from 119° to 0° between two readings, which is why this rule
  exists.
- Opening the lid after a resume also passes through angles under 30°: never
  decide "tablet" from them.
- The lid switch is only used for the very first decision, at start-up.

### GNOME

Mutter 50 decides touch mode in `update_touch_mode()`
(`src/backends/native/meta-seat-impl.c`): without a tablet mode switch,
`touch_mode = !has_pointer`, so any mouse or touchpad blocks it. With a
`SW_TABLET_MODE` switch, touch mode follows the switch, and with it
`PanelOrientationManaged` and automatic rotation. Hence the virtual switch
created by iio-sensor-proxy through uinput, as its maintainer suggested in
[issue #318](https://gitlab.freedesktop.org/hadess/iio-sensor-proxy/-/issues/318).

### Installation pitfalls

- The initramfs can carry the distribution `hid-sensor-custom` and load it
  before the root filesystem is mounted: after a DKMS install, run
  `update-initramfs -u`. Check the module actually loaded with
  `/sys/module/<name>/srcversion`, not with `modinfo -n`, which only says
  what modprobe would pick.
- systemd 259 only runs sleep hooks from `/usr/lib/systemd/system-sleep/`,
  not from `/etc/systemd/system-sleep/`.
- Sleep hooks run inside `systemd-suspend.service`, which stops right after
  the resume and kills whatever the hooks left in the background: start any
  delayed work with `systemd-run --no-block`.

## Fingerprint reader

### Identity

The sensor is a Validity (Synaptics) **138a:0094**, a hardware twin of the
138a:0090 found in ThinkPads: same ROM (v6.7 build 164), same signed blobs,
sensor type reported as VSI 55E FM160-003.

It is a **match-on-host** sensor, like the 0090: it captures 144x144 images,
and the matching happens on the computer (bozorth3 in libfprint). The
on-chip matching commands (0x69) are rejected with 0x0401. The fingerprint
record stored by the Windows driver is only 100 bytes, which first suggested
match-on-chip; it is only an identifier.

### Pairing

The sensor must be paired once: a partition table, a certificate store, a
TLS identity and a firmware extension are written to its flash. The 0090
recipe from python-validity fails on the 0094 at the partition table
(command 0x4f), with status **0x04af**. Captured on the wire from the vendor
driver pairing a blank sensor, the 0094 partition table:

- uses the 0090 layout, except for a larger template database: 0xb0000
  bytes at 0x50000, instead of 0x30000;
- is sent **without** the trailing RSA signature: the TLV only holds the
  five partition entries, 48 bytes each, each with its own SHA-256. Any
  signature, the 0090 one included, is rejected with 0x04af.

The firmware extension must match the signed blobs, not the hardware: the
0094 takes the 0090 one, `6_07f_Lenovo.xpfwext`, from the ThinkPad driver
package `n1cgn08w.exe`, which python-validity downloads from Lenovo and
unpacks with innoextract.

The sensor reboots and re-enumerates on USB after the partitioning and after
the firmware upload. Opening it again from the same process fails (errors
19 and 5, then TLS errors that are artefacts of python-validity's TLS
singleton keeping stale state): every step must run in a fresh process
after a USB reset, which is what `fingerprint/pair-sensor.py` does.

### Factory reset

A sensor paired by another driver must be erased first. The reset sequence
is `init_hardcoded`, then `reset_blob` (in that order, or the 0094 rejects
the reset), then command 0x10 with 0x61 zero bytes, then a reboot (`05 02
00`). `reset_blob` hangs the sensor at the USB level (timeouts, then
"Resource busy") unless it runs right after a **cold boot**; `usbreset`
revives it for one read at most.

### Driver fixes

On top of the 0094 device ID, the vfs0090 TOD driver needed:

- a tolerant match (`weak_match`) of the init reply RSP5, which differs from
  the 0090 in informational bytes (for example byte 37: 0x0b instead of
  0x03);
- to ignore the on-chip template database on match-on-host devices: the
  0094 answers `00 00` to the database dump, which was taken for "enrolled
  fingers found" and sent enrolment and verification down the on-chip path
  (enrolment then failed with a non-NBIS print, verification never matched);
- to reset `enroll_stage` at the start of every enrolment: it lives on the
  device object, so a second enrolment in the same session skipped the step
  that sets the print type ("Driver provided incorrect print data");
- to treat an "image capture failed" reply (finger moved or lifted too
  early) as a retry instead of aborting the enrolment.

With these, both index fingers enrolled 5/5; the right finger matches with
bozorth3 scores up to 39 (threshold 12), and a wrong finger is rejected.

### Operation

- USB autosuspend must be off for the sensor: it does not wake up from it.
- A sensor that stops answering usually recovers with `systemctl stop
  fprintd`, `usbreset 138a:0094`, and one to three attempts to open it. No
  factory reset needed.
- python-validity's own service and open-fprintd must not run: they would
  compete with the vfs0090 driver for the sensor.
- In scripts, `pkill -f fprintd` also matches the shell running it; use
  `pkill -x fprintd`.

## Suspend and the lid

### The lid in the firmware

From the 80VF DSDT:

- `_LID` returns the variable `LIDS`, not the real state, which is `LSTE` in
  the EC.
- `_WAK` sets `LIDS = One` and notifies the lid device: **after every
  resume, the lid is reported open**, even when it is closed. This is why
  the kernel logs `The lid device is not compliant to SW_LID`.
- `_Q0C` reads `LSTE` again; `_Q0D` forces `LIDS = One`.
- `_L50` would resynchronise `LIDS` with `LSTE`, but GPE 0x50 is the EC's
  own GPE, which the EC driver installs as edge-triggered (`GPE type
  mismatch (level/edge)` at boot): `_L50` probably never runs under Linux.

The real lid state is in EC byte 0x40: bit 2 is `LSTE` (1 = open), bit 0 is
`RPWR` (AC power). With the `ec_sys` module it can be read from
`/sys/kernel/debug/ec/ec0/io`.

Consequence: woken up with its lid closed (touchpad brushed while closing,
charger plugged in or out), and without a `_Q0C` from the EC, the machine
believes its lid is open and stays awake, in a bag. `suspend-debug` detects
it (`ANOMALY ... logind believes it open`).

### Wake-up sources

Enabled by default: the touchpad (`SYNA7813`, IRQ 31), the AC adapter
(`ADP1`), the battery (`PNP0C0A`), the lid (`PNP0C0D`), the power button, the
RTC, USB (XHC, but no USB device is allowed to wake the machine) and the PCIe
ports 1c.0 and 1d.0. `/sys/power/pm_wakeup_irq` names the one that fired;
`wake_irq=31(SYNA7813:00)` is the touchpad.

### The resume hang

Symptom: on wake-up, black screen, side LED steady white, no key answers
(Ctrl+Alt+F3 included), only a 10 s press on the power button turns the
machine off. The keyboard has no usable SysRq key. Over February to
September 2026, one machine logged 187 suspends: 136 triggered by the lid,
7 that never resumed (the journal stops at `PM: suspend entry`; 6 of them
from the lid), and 11 boots that ended abruptly while awake. The cause is
not known yet; [suspend-debug](../suspend-debug) records what is needed to
find it.

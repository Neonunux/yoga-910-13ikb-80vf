# Suspend diagnostics

Tools to track down suspend bugs on the Lenovo Yoga 910-13IKB. Nothing here
fixes anything: it records enough about every suspend cycle to tell what
went wrong afterwards. Tablet mode and the fingerprint reader do not need it.

```sh
./suspend-debug.sh install              set everything up
./suspend-debug.sh status               is everything in place?
./suspend-debug.sh report               cycles of the last 30 days, anomalies in colour
./suspend-debug.sh report --all --flagged
./suspend-debug.sh lidtest              lid test, without suspending
./suspend-debug.sh trace on|off|read    pm_trace on every suspend (on by default)
./suspend-debug.sh uninstall            remove everything
```

**Warning:** `install` makes the kernel panic on an oops, a CPU lockup or a
task blocked for two minutes, so that kdump can save a dump. It then reboots
10 seconds later. This is what you want while hunting a hang, but not
something to leave on forever: run `uninstall` once you are done.

## The bug it targets

On wake-up: black screen, side LED **steady** white (the machine is on), no
key does anything, Ctrl+Alt+F3 neither; only holding the power button for
10 s turns it off. That symptom fits three very different situations, which
the tools tell apart:

| situation | what is left after the forced power off |
|---|---|
| A. hang **while going to sleep** (the suspend never happened: steady LED right after closing the lid) | pm_trace names a *suspend* callback; no `post-alive` line |
| B. hang **in the kernel resume** | pm_trace names a *resume* callback; no `post-alive` line |
| C. kernel and processes resumed, **display dead** (or a hang just after) | `post-alive` and the `watch` lines, flushed every 5 s, are in the journal, along with the kernel messages (i915...) |

Ctrl+Alt+F3 does not tell them apart: if the display is dead, so are the text
consoles. The `post-alive` line in the journal does.

## What `install` sets up

| part | role |
|---|---|
| hook `/usr/lib/systemd/system-sleep/suspend-debug` | before every suspend: `pre` (lid as seen by the EC, ACPI and logind; battery) and `context` (displays, USB devices, hinge angle, tablet mode, modules, pm_trace), flushed to disk; after it: `post-alive` flushed at once, `post` (duration, power drain, wake-up IRQ), GPE and wake-up counters, then 3 minutes of lid watching with the journal flushed every 5 s |
| pm_trace on every suspend | the last suspend/resume callback survives a forced power off in the hardware clock; the hook sets the clock right after every successful resume; suspend and resume become synchronous |
| `ec_sys` | reads the real lid state from the EC (byte 0x40, bit 2) |
| `pm_print_times`, `pm_debug_messages` | time taken by each device callback, suspend steps (also visible in a vmcore when the journal lost them) |
| dynamic debug | every lid notification (`ACPI LID ...`) and every EC query (`Query(0x0c)`...) |
| systemd-coredump | keeps process crashes (`coredumpctl`) |
| kdump, if `kdump-tools` is installed | a vmcore in `/var/crash` after a panic |
| `softlockup_panic`, `hardlockup_panic`, `panic_on_oops`, `hung_task_panic`, `panic=10` | a stuck CPU, an oops or a task blocked for 2 minutes become a panic, then kdump, then an automatic reboot |

The hook must live in `/usr/lib/systemd/system-sleep/`: systemd does not
run hooks from `/etc/systemd/system-sleep/`. `install` removes a link left
there by earlier versions of this tool.

## When the hang happens

1. Look: is the LED steady or blinking? Fan, heat?
2. Hold the power button for 10 s, then **power on again right away**: the
   pm_trace data only survives 3 minutes in the hardware clock.
3. After the reboot: `./suspend-debug.sh trace read`, then
   `./suspend-debug.sh report 2`, and write down what you saw in step 1.

This keyboard has no SysRq key (Alt + Print Screen + H does nothing, with or
without Fn), so there is no vmcore on demand. If the machine reboots on its
own instead of hanging, it was an automatic panic (oops, stuck CPU or task):
the vmcore is in `/var/crash`.

## Reading the report

`report` rebuilds every suspend cycle from the journal, including the cycles
from before the install (with less detail), and flags:

- **NO RESUME**: the journal stops at `PM: suspend entry`;
- **SUDDEN STOP**: the boot ended without a clean shutdown shortly after a
  resume;
- **woke up with the lid CLOSED**: the EC says closed, but ACPI and logind
  say open, so the machine stays awake in the bag;
- quick wake-ups, process crashes after the thaw, kernel warnings, failed or
  slow device callbacks, high power drain while asleep.

It ends with the boots that ended without a clean shutdown, with the battery
level UPower last recorded, and the crash dumps kept by kdump, pstore and
systemd-coredump.

## The lid and the firmware

On this machine, ACPI reports the lid as **open after every resume**, even
when it is closed: `_WAK` sets the variable returned by `_LID` to "open"
without reading the EC. A machine woken up with its lid closed (by the
touchpad, or by plugging in the charger) then stays awake. The hook reads
the real state from the EC and logs an `ANOMALY` line when this happens.
`lidtest` shows, without suspending, what the EC, ACPI and logind report
while you close and open the lid. See [docs/findings.md](../docs/findings.md)
for the firmware analysis.

## pm_trace

On by default (`/etc/suspend-debug/pm_trace`). The kernel writes a hash of the
last suspend/resume callback and of its device into the hardware clock
(RTC), with 3-minute granularity: reboot within 3 minutes of the hang. The
kernel decodes the RTC on **every** boot (`PM: Magic number ...`,
`hash matches ...`): the result only means something after a hang with
pm_trace on, which `trace read` checks.

The cost: suspend and resume become synchronous (a little slower, and a race
between drivers could disappear; if the hangs stop, that is a clue in
itself), and the clock is wrong on the boot after a hang until NTP sets it.
`trace off` disables it and sets the hardware clock right.

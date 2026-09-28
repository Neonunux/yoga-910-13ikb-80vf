#!/bin/bash
# Suspend instrumentation for the Lenovo Yoga 910 (see README.md).
#
#   ./suspend-debug.sh install       set up the permanent traces
#   ./suspend-debug.sh status        ✓/✗ check of every part
#   ./suspend-debug.sh report [DAYS|--all] [--flagged]
#                                    suspend cycles of the last DAYS days (30)
#   ./suspend-debug.sh lidtest [S]   interactive lid test, no suspend (30 s)
#   ./suspend-debug.sh trace on|off|read
#                                    pm_trace on every suspend: names the driver
#                                    the machine hung in
#   ./suspend-debug.sh uninstall     remove everything
set -euo pipefail
cd "$(dirname "$0")"

LIBDIR=/usr/local/lib/suspend-debug
HOOK=$LIBDIR/hook
SLEEP_LINK=/usr/lib/systemd/system-sleep/suspend-debug
OLD_SLEEP_LINK=/etc/systemd/system-sleep/suspend-debug	# never run by systemd
TMPFILES=/etc/tmpfiles.d/suspend-debug.conf
MODLOAD=/etc/modules-load.d/suspend-debug.conf
SYSCTL=/etc/sysctl.d/60-suspend-debug.conf
KDUMP_CONF=/etc/default/kdump-tools
DYNDBG=/sys/kernel/debug/dynamic_debug/control
TRACE_FLAG=/etc/suspend-debug/pm_trace

say() { printf '\033[1m%s\033[0m\n' "$*"; }

hook_cmd() { [ -x "$HOOK" ] && echo "$HOOK" || echo "$PWD/hook"; }

have_kdump() { command -v kdump-config >/dev/null; }

install() {
	say "1. Packages"
	dpkg -s systemd-coredump >/dev/null 2>&1 || sudo apt-get install -y systemd-coredump

	say "2. EC access (real lid state)"
	echo ec_sys | sudo tee "$MODLOAD" >/dev/null
	sudo modprobe ec_sys

	say "3. Sleep hook"
	sudo install -D -m 755 hook "$HOOK"
	sudo ln -sf "$HOOK" "$SLEEP_LINK"
	[ "$(readlink "$OLD_SLEEP_LINK" 2>/dev/null)" = "$HOOK" ] && sudo rm -f "$OLD_SLEEP_LINK"

	say "4. Kernel traces (pm_print_times, pm_debug_messages, lid, EC queries)"
	sudo tee "$TMPFILES" >/dev/null <<'EOF'
# suspend-debug.sh: suspend traces in the kernel log
# time taken by every suspend/resume callback of every device
w /sys/power/pm_print_times - - - - 1
# suspend steps, clock suspended, pending wake-up
w /sys/power/pm_debug_messages - - - - 1
# every lid notification ("ACPI LID open/closed") and every EC query
# (_Q0C: lid read again from the EC, _Q0D: lid forced open); tmpfiles takes
# one line per path, hence the two commands separated by ";"
w /sys/kernel/debug/dynamic_debug/control - - - - file drivers/acpi/button.c +p; file drivers/acpi/ec.c func acpi_ec_event_processor format started +p
EOF
	sudo systemd-tmpfiles --create "$TMPFILES"

	say "5. Hang → kernel panic → kdump (Alt+SysRq+C, lockup detectors, oops)"
	sudo tee "$SYSCTL" >/dev/null <<'SYSCTL_EOF'
# suspend-debug.sh: turn a hang into a usable kdump
# 176 (Ubuntu default) + 8: Alt+SysRq+C (crash) and Alt+SysRq+W (blocked tasks)
kernel.sysrq = 184
# CPU stuck (20 s with interrupts on, 10 s with interrupts off) → panic
kernel.softlockup_panic = 1
kernel.hardlockup_panic = 1
# oops (often followed by a half-dead system) → panic
kernel.panic_on_oops = 1
# task blocked for 120 s while awake (the detector is paused during suspend)
kernel.hung_task_panic = 1
# if kdump fails: reboot 10 s after the panic instead of staying frozen
kernel.panic = 10
SYSCTL_EOF
	sudo sysctl -q -p "$SYSCTL"

	say "6. pm_trace on every suspend"
	sudo mkdir -p "$(dirname "$TRACE_FLAG")"
	sudo touch "$TRACE_FLAG"

	say "7. kdump"
	if ! have_kdump; then
		echo "  kdump-tools is not installed, skipped. To capture kernel crashes:"
		echo "  sudo apt install kdump-tools, reboot (it reserves memory for the"
		echo "  crash kernel), then run ./suspend-debug.sh install again."
	else
		if grep -q '^USE_KDUMP=' "$KDUMP_CONF"; then
			sudo sed -i 's/^USE_KDUMP=.*/USE_KDUMP=1/' "$KDUMP_CONF"
		else
			echo USE_KDUMP=1 | sudo tee -a "$KDUMP_CONF" >/dev/null
		fi
		if [ "$(cat /sys/kernel/kexec_crash_loaded)" != 1 ]; then
			sudo kdump-config symlinks "$(uname -r)" >/dev/null
			sudo kdump-config load || true
		fi
	fi

	echo
	check
}

uninstall() {
	say "Removing the instrumentation"
	sudo rm -f "$SLEEP_LINK" "$TMPFILES" "$MODLOAD" "$SYSCTL" "$TRACE_FLAG"
	[ "$(readlink "$OLD_SLEEP_LINK" 2>/dev/null)" = "$HOOK" ] && sudo rm -f "$OLD_SLEEP_LINK"
	sudo rm -rf "$LIBDIR"
	sudo rmdir "$(dirname "$TRACE_FLAG")" 2>/dev/null || true
	echo 0 | sudo tee /sys/power/pm_print_times /sys/power/pm_debug_messages /sys/power/pm_trace >/dev/null
	echo 'file drivers/acpi/button.c -p' | sudo tee "$DYNDBG" >/dev/null
	echo 'file drivers/acpi/ec.c -p' | sudo tee "$DYNDBG" >/dev/null
	sudo sysctl -q --system
	if have_kdump && [ -f "$KDUMP_CONF" ]; then
		sudo sed -i 's/^USE_KDUMP=.*/USE_KDUMP=0/' "$KDUMP_CONF"
		sudo kdump-config unload >/dev/null 2>&1 || true
	fi
	sudo rmmod ec_sys 2>/dev/null || true
	echo "systemd-coredump and kdump-tools are kept (remove them with apt if you want)."
}

check() {
	local -
	set +e +o pipefail
	local ok=0 ko=0 warn=0 v last lid
	pass() { printf '  \033[32m✓\033[0m %s\n' "$*"; ok=$((ok+1)); }
	fail() { printf '  \033[31m✗\033[0m %s\n' "$*"; ko=$((ko+1)); }
	note() { printf '  \033[33m!\033[0m %s\n' "$*"; warn=$((warn+1)); }
	echo "$(date '+%Y-%m-%d %H:%M')  kernel $(uname -r), suspend mode $(grep -o '\[[a-z0-9]*\]' /sys/power/mem_sleep)"

	say "Sleep hook"
	[ -x "$HOOK" ] && [ "$(readlink "$SLEEP_LINK")" = "$HOOK" ] && pass "installed ($SLEEP_LINK)" \
		|| fail "missing: ./suspend-debug.sh install"
	[ -e "$OLD_SLEEP_LINK" ] && note "$OLD_SLEEP_LINK is never run by systemd: ./suspend-debug.sh install removes it"
	[ -x "$HOOK" ] && ! cmp -s hook "$HOOK" && note "the installed hook differs from ./hook: run install again"
	last=$(journalctl -t suspend-debug -o short-iso --no-pager -q 2>/dev/null | grep -E ' (pre|post) type=' | tail -1 | cut -c1-19)
	[ -n "$last" ] && pass "last cycle logged: $last" || note "no cycle logged yet"

	say "Lid"
	lid=$(sudo "$(hook_cmd)" sample 2>/dev/null)
	if [[ $lid == *lid_ec=open* || $lid == *lid_ec=closed* ]]; then
		pass "EC readable: $lid"
	else
		fail "EC not readable ($lid): sudo modprobe ec_sys"
	fi
	echo "    (button.lid_init_state=$(grep -o '\[[a-z]*\]' /sys/module/button/parameters/lid_init_state | tr -d '[]'))"

	say "Kernel traces"
	[ "$(cat /sys/power/pm_print_times)" = 1 ] && pass "pm_print_times" || fail "pm_print_times disabled"
	[ "$(cat /sys/power/pm_debug_messages)" = 1 ] && pass "pm_debug_messages" || fail "pm_debug_messages disabled"
	v=$(sudo grep -cE 'acpi_lid_notify_state =p|acpi_ec_event_processor =p "Query\(0x%02x\) started' "$DYNDBG")
	[ "$v" -ge 2 ] && pass "dynamic debug: lid and EC queries" || fail "dynamic debug off (sudo systemd-tmpfiles --create $TMPFILES)"
	if [ -e "$TRACE_FLAG" ]; then
		pass "pm_trace enabled on every suspend (synchronous suspend/resume, RTC set right by the hook)"
	else
		note "pm_trace disabled: a hang will not name a driver (./suspend-debug.sh trace on)"
	fi

	say "Crash traces"
	grep -q systemd-coredump /proc/sys/kernel/core_pattern && pass "systemd-coredump receives the crashes" \
		|| fail "core_pattern = $(cut -c1-40 /proc/sys/kernel/core_pattern)"
	if ! have_kdump; then
		note "kdump-tools not installed: a kernel crash leaves no dump"
	elif [ "$(cat /sys/kernel/kexec_crash_loaded)" = 1 ]; then
		pass "kdump ready (crash kernel loaded)"
	else
		fail "kdump not loaded: sudo kdump-config status"
	fi
	v=$(cat /proc/sys/kernel/sysrq)
	(( v == 1 || (v & 8) )) && pass "Alt+SysRq+C allowed (sysrq=$v)" || fail "Alt+SysRq+C not allowed (sysrq=$v)"
	v=$(for k in softlockup_panic hardlockup_panic panic_on_oops hung_task_panic; do [ "$(cat /proc/sys/kernel/$k 2>/dev/null)" = 1 ] || echo "$k"; done)
	[ -z "$v" ] && pass "lockup or oops → panic → kdump (reboot $(cat /proc/sys/kernel/panic) s later if kdump fails)" \
		|| fail "no panic on: $v (sudo sysctl -p $SYSCTL)"
	systemctl is-enabled -q systemd-pstore && pass "systemd-pstore enabled (efi_pstore)" || note "systemd-pstore disabled"

	echo
	if [ "$ko" -eq 0 ]; then
		say "All in place ($ok checks$( [ "$warn" -gt 0 ] && echo ", $warn note(s)"))."
	else
		say "$ko problem(s) out of $((ok+ko)) checks."
	fi
	[ "$ko" -eq 0 ]
}

lidtest() {
	local secs=${1:-30} since
	say "Lid test for $secs s (suspend on lid close is blocked during the test)"
	echo "Close the lid completely, wait 5 s, open it again. Repeat if you like."
	echo "Columns: EC = real state, ACPI = _LID (LIDS), logind = what the desktop sees."
	sudo -v
	sudo modprobe ec_sys
	since=$(date '+%Y-%m-%d %H:%M:%S')
	sudo systemd-inhibit --what=handle-lid-switch --who=suspend-debug --why="lid test" --mode=block \
		bash -c 'prev=""; end=$((SECONDS + '"$secs"'))
			while [ $SECONDS -lt $end ]; do
				cur=$("'"$(hook_cmd)"'" sample)
				[ "$cur" != "$prev" ] && echo "$(date +%T.%N | cut -c1-12)  $cur" && prev=$cur
				sleep 0.2
			done'
	echo
	say "Kernel events during the test"
	journalctl -k -p debug --since "$since" -o short-precise --no-pager -q | grep -E 'ACPI LID|Query\(0x|SW_LID' \
		| sed -E 's/^([[:alpha:].]+ +[0-9]+ )//' || echo "  none"
	journalctl -t systemd-logind --since "$since" -o short-precise --no-pager -q | grep Lid || true
}

trace() {
	case "${1:-}" in
	on)
		sudo mkdir -p "$(dirname "$TRACE_FLAG")"
		sudo touch "$TRACE_FLAG"
		cat <<'TRACE_EOF'
pm_trace will be enabled before every suspend. The kernel writes the last
device it handled into the hardware clock (RTC); after every successful resume,
the hook sets the RTC right again. Suspend and resume become synchronous
(pm_async is ignored). After a hang: reboot WITHIN 3 MINUTES, then run
./suspend-debug.sh trace read.
TRACE_EOF
		;;
	off)
		sudo rm -f "$TRACE_FLAG"
		echo 0 | sudo tee /sys/power/pm_trace >/dev/null
		if [ "$(timedatectl show -p NTPSynchronized --value)" = yes ]; then
			sudo hwclock --systohc && echo "pm_trace disabled, hardware clock set right."
		else
			echo "pm_trace disabled. Time not synchronised: run 'sudo hwclock --systohc' once the network is back."
		fi
		;;
	read)
		# the kernel decodes the RTC on every boot; this only means something if
		# the last suspend of the previous boot had pm_trace=1 and never came back
		local prev
		prev=$(journalctl -b -1 -t suspend-debug -o cat --no-pager -q 2>/dev/null | grep '^context ' | tail -1)
		if [[ $prev == *pm_trace=1* ]]; then
			echo "Last suspend of the previous boot: pm_trace was on. RTC decoded at this boot:"
		else
			echo "Warning: pm_trace was off at the last suspend of the previous boot, the decoding means nothing."
		fi
		journalctl -b -k --no-pager -q | grep -E 'RTC time:|Magic number|hash matches' | sed 's/^.*kernel: /  /'
		;;
	*)
		echo "usage: $0 trace on|off|read" >&2; exit 2
		;;
	esac
}

case "${1:-status}" in
install) install ;;
uninstall) uninstall ;;
status | check) check ;;
report) shift; exec python3 report.py "$@" ;;
lidtest) shift; lidtest "$@" ;;
trace) shift; trace "$@" ;;
*)
	echo "usage: $0 install|status|report|lidtest|trace|uninstall" >&2; exit 2
	;;
esac

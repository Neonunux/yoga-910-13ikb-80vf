#!/bin/bash
# Tablet mode for the Lenovo Yoga 910-13IKB (80VF): install, check or remove
# the whole stack.
#
#   kernel     patched hid-sensor-custom + hid-sensor-custom-intel-hinge,
#              built by DKMS for every installed kernel
#   userspace  patched iio-sensor-proxy, which turns the hinge angle into a
#              SW_TABLET_MODE switch for libinput and the desktop
#   resume     a system-sleep hook that powers the sensors back on after a
#              suspend (works around a kernel bug, see README.md)
#
#   ./setup.sh install     build, install and switch over, no reboot needed
#                          (--force: even without the Yoga 910 sensor hub)
#   ./setup.sh check       automated check, one line per link of the chain
#   ./setup.sh status      short state of the chain
#   ./setup.sh reset-hub   reset the sensor hub if it is stuck
#   ./setup.sh uninstall   back to the distribution drivers
set -euo pipefail
cd "$(dirname "$0")"
HERE=$PWD

DKMS_NAME=yoga-hinge-sensor
DKMS_VER=1.0
DKMS_SRC=/usr/src/$DKMS_NAME-$DKMS_VER
ISP_REPO=https://gitlab.freedesktop.org/hadess/iio-sensor-proxy.git
ISP_TAG=3.9
ISP_SRC=$HERE/build/iio-sensor-proxy
ISP_BIN=/usr/local/libexec/iio-sensor-proxy
DROPIN=/etc/systemd/system/iio-sensor-proxy.service.d/hinge.conf
UDEV_RULE=/etc/udev/rules.d/79-iio-sensor-proxy-hinge.rules
HUB_CHECK=/usr/local/libexec/yoga-sensor-hub-check
HUB_HOOK=/usr/lib/systemd/system-sleep/yoga-sensor-hub
SWITCH_NAME='iio-sensor-proxy tablet mode switch'

PACKAGES=(dkms build-essential "linux-headers-$(uname -r)" git meson ninja-build
	pkgconf libglib2.0-dev libgudev-1.0-dev libpolkit-gobject-1-dev libudev-dev
	systemd-dev evtest python3)

say() { printf '\033[1m%s\033[0m\n' "$*"; }

# the ITE8186 sensor hub of the Yoga 910, on I2C HID
hub_present() { compgen -G '/sys/bus/hid/devices/*:048D:8186.*' >/dev/null; }

hinge_iio() {
	local d
	for d in /sys/bus/iio/devices/iio:device*; do
		[ "$(cat "$d/name" 2>/dev/null)" = hinge ] && { echo "$d"; return 0; }
	done
	return 1
}

reload_kernel_drivers() {
	sudo rmmod hid_sensor_custom_intel_hinge 2>/dev/null || true
	sudo rmmod hid_sensor_custom 2>/dev/null || true
	sudo modprobe hid_sensor_custom
	sudo udevadm settle
}

build_iio_sensor_proxy() {
	if [ ! -d "$ISP_SRC/.git" ]; then
		mkdir -p "$HERE/build"
		git clone --quiet --depth 1 --branch "$ISP_TAG" "$ISP_REPO" "$ISP_SRC"
		git -C "$ISP_SRC" -c user.name=setup -c user.email=setup@localhost \
			am --quiet "$HERE"/iio-sensor-proxy/*.patch
	fi
	[ -d "$ISP_SRC/_build" ] ||
		meson setup "$ISP_SRC/_build" "$ISP_SRC" --prefix=/usr/local -Dssc-support=disabled
	ninja -C "$ISP_SRC/_build"
}

install_dkms() {
	local v
	# Remove any previous version of this DKMS package
	for v in $(dkms status "$DKMS_NAME" 2>/dev/null | sed -n "s|^$DKMS_NAME/\([^,]*\),.*|\1|p" | sort -u); do
		sudo dkms remove -m "$DKMS_NAME" -v "$v" --all || true
	done
	sudo rm -rf "$DKMS_SRC"
	sudo mkdir -p "$DKMS_SRC"
	sudo cp -r kernel/src/drivers "$DKMS_SRC/"
	sudo cp -r kernel/patches "$DKMS_SRC/"
	printf 'obj-m += drivers/hid/hid-sensor-custom.o\nobj-m += drivers/iio/position/hid-sensor-custom-intel-hinge.o\n' |
		sudo tee "$DKMS_SRC/Kbuild" >/dev/null
	sudo tee "$DKMS_SRC/dkms.conf" >/dev/null <<DKMS
PACKAGE_NAME="$DKMS_NAME"
PACKAGE_VERSION="$DKMS_VER"
MAKE[0]="make -C \${kernel_source_dir} M=\${dkms_tree}/\${PACKAGE_NAME}/\${PACKAGE_VERSION}/build modules"
CLEAN="make -C \${kernel_source_dir} M=\${dkms_tree}/\${PACKAGE_NAME}/\${PACKAGE_VERSION}/build clean"
BUILT_MODULE_NAME[0]="hid-sensor-custom"
BUILT_MODULE_LOCATION[0]="drivers/hid"
DEST_MODULE_LOCATION[0]="/updates/dkms"
BUILT_MODULE_NAME[1]="hid-sensor-custom-intel-hinge"
BUILT_MODULE_LOCATION[1]="drivers/iio/position"
DEST_MODULE_LOCATION[1]="/updates/dkms"
AUTOINSTALL="yes"
DKMS
	sudo dkms add -m "$DKMS_NAME" -v "$DKMS_VER"
	sudo dkms install -m "$DKMS_NAME" -v "$DKMS_VER" --force
	# hid-sensor-custom may also be in the initramfs, which is loaded before the
	# root file system: without regenerating it, the distribution module would
	# be the one running after every boot. Kernels installed later are fine,
	# apt runs DKMS before building their initramfs.
	sudo update-initramfs -u -k "$(uname -r)"
}

status() {
	local h
	echo "kernel           : $(uname -r)"
	echo "DKMS             : $(dkms status "$DKMS_NAME" 2>/dev/null | head -1 || echo missing)"
	echo "modules          : $(lsmod | awk '/^(hid_sensor_custom|hid_sensor_custom_intel_hinge) /{printf "%s ", $1}')"
	if h=$(hinge_iio); then
		echo "hinge IIO device : $h, $(awk -v r="$(cat "$h/in_angl0_raw")" -v s="$(cat "$h/in_angl_scale")" 'BEGIN{printf "%.1f°", r*s*180/3.14159265358979}')"
	else
		echo "hinge IIO device : missing"
	fi
	echo "iio-sensor-proxy : $(systemctl is-active iio-sensor-proxy) ($(systemctl show -p ExecStart iio-sensor-proxy | grep -o 'path=[^ ;]*' | head -1))"
	journalctl -b -u iio-sensor-proxy --no-pager -o cat 2>/dev/null | grep -E 'tablet mode|Hinge at' | tail -3 | sed 's/^/                   /'
	if grep -q "$SWITCH_NAME" /proc/bus/input/devices; then
		echo "switch           : $(grep -A5 "$SWITCH_NAME" /proc/bus/input/devices | grep -o 'event[0-9]*')"
	else
		echo "switch           : missing"
	fi
}

check() {
	# A failed check must neither stop the script nor be confused with
	# grep -q closing a pipe early
	local -
	set +e +o pipefail
	local ok=0 ko=0 warn=0 kver h ev sw ang ap power f m
	pass() { printf '  \033[32m✓\033[0m %s\n' "$*"; ok=$((ok + 1)); }
	fail() { printf '  \033[31m✗\033[0m %s\n' "$*"; ko=$((ko + 1)); }
	note() { printf '  \033[33m!\033[0m %s\n' "$*"; warn=$((warn + 1)); }
	kver=$(uname -r)
	echo "$(date '+%Y-%m-%d %H:%M')  kernel $kver"

	say "Kernel"
	[ -d "/lib/modules/$kver/build" ] && pass "kernel headers installed" ||
		fail "kernel headers missing: sudo apt install linux-headers-$kver"
	if dkms status -m "$DKMS_NAME" -v "$DKMS_VER" -k "$kver" 2>/dev/null | grep -q installed; then
		pass "DKMS: modules installed for this kernel"
	else
		fail "DKMS: nothing for $kver → sudo dkms autoinstall (log: /var/lib/dkms/$DKMS_NAME/$DKMS_VER/build/make.log)"
	fi
	for m in hid_sensor_custom hid_sensor_custom_intel_hinge; do
		f="/lib/modules/$kver/updates/dkms/${m//_/-}.ko.zst"
		if ! grep -q "^$m " /proc/modules; then
			fail "$m not loaded"
		elif [ "$(cat "/sys/module/$m/srcversion" 2>/dev/null)" = "$(modinfo -F srcversion "$f" 2>/dev/null)" ]; then
			pass "$m loaded, patched version"
		else
			fail "$m loaded from the distribution (initramfs out of date?) → sudo update-initramfs -u, then reboot"
		fi
	done
	# The initramfs, loaded before the root file system, must not carry the
	# distribution module, which would take the place of ours at every boot
	if lsinitramfs "/boot/initrd.img-$kver" 2>/dev/null | grep -q 'kernel/drivers/hid/hid-sensor-custom'; then
		fail "initramfs carries the distribution module → sudo update-initramfs -u -k $kver, then reboot"
	else
		pass "initramfs does not carry the distribution module"
	fi

	say "Sensor"
	if ! h=$(hinge_iio); then
		fail "no \"hinge\" IIO device"
	else
		ang=$(awk -v r="$(cat "$h/in_angl0_raw")" -v s="$(cat "$h/in_angl_scale")" 'BEGIN{printf "%.0f", r*s*180/3.14159265358979}')
		pass "\"hinge\" IIO device: $h, $ang°"
		udevadm info -q property -p "$h" | grep -q 'IIO_SENSOR_PROXY_TYPE=.*iio-poll-hinge' &&
			pass "udev rule applied (iio-poll-hinge)" || fail "udev rule not applied: $UDEV_RULE"
		ap=$(ls -d /sys/bus/platform/devices/HID-SENSOR-200073.* 2>/dev/null | head -1)
		[ "$(cat "$ap/power/runtime_status" 2>/dev/null)" = active ] && pass "screen accelerometer on" ||
			fail "screen accelerometer off: the hinge angle will freeze"
		power=$(sudo "$HUB_CHECK" --power 2>/dev/null)
		[[ "$power" == *"hinge=on"* ]] && pass "hinge sensor powered in the hub" ||
			fail "hinge sensor powered off in the hub ($power) → sudo $HUB_CHECK --fix"
		sudo "$HUB_CHECK" >/dev/null 2>&1 && pass "sensor hub alive (the accelerometer moves)" ||
			fail "sensor hub stuck → ./setup.sh reset-hub"
	fi
	[ -x "$HUB_HOOK" ] && [ -x "$HUB_CHECK" ] && pass "sensor check after resume installed" ||
		fail "sensor check after resume missing → ./setup.sh install"

	say "iio-sensor-proxy"
	systemctl is-active -q iio-sensor-proxy && pass "service running" ||
		fail "service not running: systemctl status iio-sensor-proxy"
	systemctl show -p ExecStart iio-sensor-proxy | grep -q "path=$ISP_BIN" && [ -x "$ISP_BIN" ] &&
		pass "patched version ($ISP_BIN)" || fail "distribution version running: $DROPIN missing?"
	journalctl -b -u iio-sensor-proxy --no-pager -o cat 2>/dev/null | grep -q 'Reporting tablet mode from' &&
		pass "tracking the hinge since boot" || fail "not tracking the hinge: journalctl -b -u iio-sensor-proxy"
	journalctl -b -u iio-sensor-proxy --no-pager -o cat 2>/dev/null | grep -q 'already reported by the kernel' &&
		note "the kernel now provides its own tablet mode switch: iio-sensor-proxy steps aside"
	ev=$(grep -A5 "$SWITCH_NAME" /proc/bus/input/devices | grep -o 'event[0-9]*' | head -1)
	if [ -n "$ev" ]; then
		sudo evtest --query "/dev/input/$ev" EV_SW SW_TABLET_MODE && sw=laptop || sw=tablet
		pass "switch $ev present, $sw mode"
	else
		fail "virtual switch missing"
	fi

	echo
	if [ "$ko" -eq 0 ]; then
		say "All good ($ok checks$([ "$warn" -gt 0 ] && echo ", $warn note(s)"))."
	else
		say "$ko problem(s) out of $((ok + ko)) checks, see CHECKS.md."
	fi
	[ "$ko" -eq 0 ]
}

case "${1:-status}" in
install)
	if ! hub_present && [ "${2:-}" != --force ]; then
		echo "No ITE8186 sensor hub (HID 048D:8186) found: this does not look like a Yoga 910-13IKB." >&2
		echo "Nothing was installed. Run './setup.sh install --force' to install anyway." >&2
		exit 1
	fi
	say "1. Packages"
	sudo apt-get install -y "${PACKAGES[@]}"

	say "2. Kernel drivers (DKMS)"
	install_dkms

	say "3. Patched iio-sensor-proxy"
	build_iio_sensor_proxy
	sudo install -D -m 755 "$ISP_SRC/_build/src/iio-sensor-proxy" "$ISP_BIN"
	sudo mkdir -p "$(dirname "$DROPIN")"
	printf '# Yoga 910 tablet mode: iio-sensor-proxy with hinge support (hinge/setup.sh)\n[Service]\nExecStart=\nExecStart=%s\n' "$ISP_BIN" |
		sudo tee "$DROPIN" >/dev/null
	sudo tee "$UDEV_RULE" >/dev/null <<'RULE'
# Hinge angle sensor for iio-sensor-proxy (Yoga 910 tablet mode, hinge/setup.sh)
ACTION=="remove", GOTO="iio_sensor_proxy_hinge_end"
SUBSYSTEM=="iio", ATTR{name}=="hinge", ATTR{in_angl0_label}=="hinge", TEST=="in_angl0_raw", ENV{IIO_SENSOR_PROXY_TYPE}+="iio-poll-hinge"
LABEL="iio_sensor_proxy_hinge_end"
RULE
	sudo udevadm control --reload

	say "4. Sensor check after every resume"
	sudo install -D -m 755 yoga-sensor-hub-check "$HUB_CHECK"
	sudo install -D -m 755 yoga-sensor-hub.sleep "$HUB_HOOK"

	say "5. Switching over"
	reload_kernel_drivers
	sudo systemctl daemon-reload
	sudo systemctl restart iio-sensor-proxy
	sleep 3
	status
	;;
uninstall)
	say "Back to the distribution drivers and iio-sensor-proxy"
	sudo rm -f "$DROPIN" "$UDEV_RULE" "$HUB_CHECK" "$HUB_HOOK" "$ISP_BIN"
	sudo rmdir "$(dirname "$DROPIN")" 2>/dev/null || true
	sudo udevadm control --reload
	sudo dkms remove -m "$DKMS_NAME" -v "$DKMS_VER" --all 2>/dev/null || true
	sudo rm -rf "$DKMS_SRC"
	sudo update-initramfs -u -k "$(uname -r)"
	reload_kernel_drivers
	sudo systemctl daemon-reload
	sudo systemctl restart iio-sensor-proxy
	sleep 2
	status
	;;
status)
	status
	;;
check)
	check
	;;
reset-hub)
	sudo "$HUB_CHECK" --reset
	sleep 2
	status
	;;
*)
	echo "usage: $0 install|check|status|reset-hub|uninstall" >&2
	exit 2
	;;
esac

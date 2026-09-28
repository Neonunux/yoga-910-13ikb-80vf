#!/bin/bash
# Fingerprint reader of the Lenovo Yoga 910-13IKB: Validity 138a:0094.
#
#   vfs0090 driver    libfprint TOD driver for the 138a:0090, patched for the
#                     0094; used by the standard fprintd
#   python-validity   patched; only used to pair the sensor once and to
#                     download the Lenovo firmware it needs
#
#   ./setup.sh install     build and install the driver, fetch the firmware
#   sudo ./pair-sensor.py  pair the sensor (see README.md), then fprintd-enroll
#   ./setup.sh status      short state
#   ./setup.sh uninstall   remove the driver and the udev rules
set -euo pipefail
cd "$(dirname "$0")"
HERE=$PWD
BUILD=$HERE/build

VFS_REPO=https://github.com/3v1n0/libfprint-tod-vfs0090.git
VFS_BASE=252c98495791839b36fe5154f55ecca62df2e76a
PV_REPO=https://github.com/uunicorn/python-validity.git
PV_BASE=a6bbc21dce7b8b3c3cd92378a0b2579a2fb45920	# release 0.15
FIRMWARE=6_07f_Lenovo.xpfwext
AUTOSUSPEND_RULE=/etc/udev/rules.d/99-validity-0094-no-autosuspend.rules

PACKAGES=(git build-essential meson ninja-build pkgconf fprintd libpam-fprintd
	libfprint-2-tod1 libfprint-2-tod-dev libnss3-dev libssl-dev libpixman-1-dev
	libudev-dev python3 python3-usb python3-cryptography python3-yaml innoextract
	usbutils)

say() { printf '\033[1m%s\033[0m\n' "$*"; }

# Clone an upstream project at a fixed commit and apply our patches
fetch_patched() {
	local repo=$1 base=$2 dir=$3 patches=$4
	[ -d "$dir/.git" ] && return 0
	mkdir -p "$BUILD"
	git clone --quiet "$repo" "$dir"
	git -C "$dir" checkout --quiet -b yoga-910 "$base"
	git -C "$dir" -c user.name=setup -c user.email=setup@localhost am --quiet "$patches"/*.patch
}

sensor_present() { lsusb -d 138a:0094 >/dev/null 2>&1; }

warn_conflicts() {
	local p
	for p in python3-validity open-fprintd; do
		dpkg -s "$p" >/dev/null 2>&1 &&
			echo "  warning: package $p is installed; its service would fight vfs0090 over the sensor, remove it"
	done
	ls /usr/lib/*/libfprint-2/tod-1/libtudor* >/dev/null 2>&1 &&
		echo "  warning: a synaTudor TOD driver is installed; remove or disable it" || true
}

status() {
	echo "sensor           : $(lsusb -d 138a:0094 2>/dev/null || echo 'not found on USB')"
	echo "vfs0090 driver   : $(ls /usr/lib/*/libfprint-2/tod-1/libfprint-tod-vfs009x.so 2>/dev/null || echo missing)"
	echo "udev rules       : $(ls /usr/lib/udev/rules.d/60-libfprint-2-tod-vfs0090.rules "$AUTOSUSPEND_RULE" 2>/dev/null | tr '\n' ' ')"
	echo "cached firmware  : $(ls "$BUILD/firmware/$FIRMWARE" 2>/dev/null || echo missing)"
	echo "fprintd          :"
	fprintd-list "$USER" 2>&1 | sed 's/^/                   /'
}

case "${1:-status}" in
install)
	say "1. Packages"
	sudo apt-get install -y "${PACKAGES[@]}"
	warn_conflicts

	say "2. vfs0090 driver"
	fetch_patched "$VFS_REPO" "$VFS_BASE" "$BUILD/libfprint-tod-vfs0090" "$HERE/patches/libfprint-tod-vfs0090"
	[ -d "$BUILD/libfprint-tod-vfs0090/_build" ] ||
		meson setup "$BUILD/libfprint-tod-vfs0090/_build" "$BUILD/libfprint-tod-vfs0090"
	ninja -C "$BUILD/libfprint-tod-vfs0090/_build"
	sudo ninja -C "$BUILD/libfprint-tod-vfs0090/_build" install

	say "3. USB autosuspend off for the sensor (it does not survive it)"
	sudo tee "$AUTOSUSPEND_RULE" >/dev/null <<'RULE'
# Validity 138a:0094 (Lenovo Yoga 910): no USB autosuspend, the sensor does not wake up from it
ACTION=="add|change", SUBSYSTEM=="usb", ATTR{idVendor}=="138a", ATTR{idProduct}=="0094", ATTR{power/control}="on"
RULE
	sudo udevadm control --reload
	sudo udevadm trigger --subsystem-match=usb --attr-match=idVendor=138a

	say "4. python-validity, for pairing"
	fetch_patched "$PV_REPO" "$PV_BASE" "$BUILD/python-validity" "$HERE/patches/python-validity"

	say "5. Lenovo firmware, downloaded from Lenovo"
	if [ -f "$BUILD/firmware/$FIRMWARE" ]; then
		echo "  already downloaded"
	elif sensor_present; then
		sudo systemctl stop fprintd 2>/dev/null || true
		sudo mkdir -p /var/run/python-validity
		sudo env PYTHONPATH="$BUILD/python-validity" python3 "$BUILD/python-validity/bin/validity-sensors-firmware"
		mkdir -p "$BUILD/firmware"
		cp "/var/run/python-validity/$FIRMWARE" "$BUILD/firmware/"
	else
		echo "  sensor not found, skipped: run ./setup.sh install again once it is visible (lsusb -d 138a:0094)"
	fi

	sudo systemctl restart fprintd 2>/dev/null || true
	echo
	say "Next: sudo ./pair-sensor.py, then fprintd-enroll (see README.md)."
	;;
uninstall)
	say "Removing the vfs0090 driver and the udev rules"
	if [ -d "$BUILD/libfprint-tod-vfs0090/_build" ]; then
		sudo ninja -C "$BUILD/libfprint-tod-vfs0090/_build" uninstall
	fi
	sudo rm -f "$AUTOSUSPEND_RULE"
	sudo udevadm control --reload
	sudo systemctl restart fprintd 2>/dev/null || true
	echo "Enrolled fingerprints stay in /var/lib/fprint; remove them with fprintd-delete if needed."
	;;
status)
	status
	;;
*)
	echo "usage: $0 install|status|uninstall" >&2
	exit 2
	;;
esac

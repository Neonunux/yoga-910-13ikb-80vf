#!/bin/bash
# Builds the two patched modules out of tree for the running kernel, in
# build/, for testing. setup.sh does not need this: it builds them with DKMS.
set -euo pipefail
cd "$(dirname "$0")"
KVER="${KVER:-$(uname -r)}"
rm -rf build && mkdir -p build
cp -r src/drivers build/
cat > build/Kbuild <<'KB'
obj-m += drivers/hid/hid-sensor-custom.o
obj-m += drivers/iio/position/hid-sensor-custom-intel-hinge.o
KB
make -C "/lib/modules/$KVER/build" M="$PWD/build" modules
ls -la build/drivers/hid/hid-sensor-custom.ko build/drivers/iio/position/hid-sensor-custom-intel-hinge.ko

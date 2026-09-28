#!/usr/bin/env python3
"""Pair the Validity 138a:0094 fingerprint sensor of the Lenovo Yoga 910.

The vfs0090 driver needs the sensor to be paired once by an external tool:
pairing writes the partition table, a certificate store and the Lenovo
firmware extension to the sensor flash. This script does it with the patched
python-validity built by setup.sh, then checks that the sensor opens
(TLS, calibration, template database). fprintd works on its own afterwards.

  sudo ./pair-sensor.py                   pair a blank sensor, or check that
                                          a paired one opens
  sudo ./pair-sensor.py --factory-reset   erase the sensor flash first

A sensor paired by Windows, by another driver, or left half-provisioned by a
failed attempt needs --factory-reset. It is destructive: the pairing and the
fingerprints stored by Windows are lost (Windows pairs again on its own, but
fingers must be enrolled again there). Run it right after a cold boot
(power off, then on): the sensor can hang on the reset otherwise.

Each step makes the sensor reboot and re-enumerate on USB; every attempt runs
in a fresh process after a USB reset, which is what works reliably.
"""
import argparse
import glob
import os
import shutil
import subprocess
import sys
import time

VID, PID = '138a', '0094'
HERE = os.path.dirname(os.path.abspath(__file__))
DATA_DIR = '/var/run/python-validity'
FIRMWARE = '6_07f_Lenovo.xpfwext'

RESET_CODE = r'''
import sys
from struct import unpack
sys.path.insert(0, sys.argv[1])
from validitysensor.usb import usb
from validitysensor.blobs_90 import init_hardcoded, reset_blob
usb.open(0x138a, 0x0094)
# init_hardcoded must come before reset_blob, the 0094 rejects the reset otherwise
for data, label in ((b'\x01', 'get_version'), (init_hardcoded, 'init_hardcoded'),
                    (reset_blob, 'reset_blob'), (b'\x10' + b'\0' * 0x61, 'factory_reset')):
    try:
        usb.dev.write(1, data)
        rsp = bytes(usb.dev.read(129, 100 * 1024))
        print('  %-15s status %04x' % (label, unpack('<H', rsp[:2])[0]), flush=True)
    except Exception as e:
        print('  %-15s %s (the sensor reboots)' % (label, e), flush=True)
try:
    usb.dev.write(1, bytes.fromhex('050200'))
except Exception:
    pass
'''

OPEN_CODE = r'''
import logging, sys
sys.path.insert(0, sys.argv[1])
logging.basicConfig(level=logging.INFO, format='  %(message)s')
from validitysensor import init
init.open()
print('SENSOR-OPEN-OK', flush=True)
'''


def sensor_sysfs():
    for path in glob.glob('/sys/bus/usb/devices/*/idVendor'):
        d = os.path.dirname(path)
        try:
            if open(path).read().strip() == VID and \
               open(os.path.join(d, 'idProduct')).read().strip() == PID:
                return d
        except OSError:
            pass
    return None


def wait_for_sensor(seconds=20):
    for _ in range(seconds):
        d = sensor_sysfs()
        if d:
            try:
                with open(os.path.join(d, 'power/control'), 'w') as f:
                    f.write('on')
            except OSError:
                pass
            return d
        time.sleep(1)
    return None


def usb_reset():
    subprocess.run(['usbreset', '%s:%s' % (VID, PID)],
                   stdout=subprocess.DEVNULL, stderr=subprocess.DEVNULL)
    time.sleep(3)
    wait_for_sensor()


def ensure_firmware(pv):
    os.makedirs(DATA_DIR, exist_ok=True)
    target = os.path.join(DATA_DIR, FIRMWARE)
    if os.path.exists(target):
        return True
    cached = os.path.join(HERE, 'build', 'firmware', FIRMWARE)
    if os.path.exists(cached):
        shutil.copy(cached, target)
        return True
    print('Downloading the firmware from Lenovo...')
    env = dict(os.environ, PYTHONPATH=pv)
    subprocess.run([sys.executable, os.path.join(pv, 'bin', 'validity-sensors-firmware')], env=env)
    if os.path.exists(target):
        os.makedirs(os.path.dirname(cached), exist_ok=True)
        shutil.copy(target, cached)
        return True
    return False


def main():
    ap = argparse.ArgumentParser(description=__doc__.split('\n\n')[0])
    ap.add_argument('--factory-reset', action='store_true',
                    help='erase the sensor flash before pairing (destructive)')
    ap.add_argument('--yes', action='store_true', help='do not ask for confirmation')
    ap.add_argument('--tries', type=int, default=6, help='open attempts (default 6)')
    ap.add_argument('--python-validity', default=os.path.join(HERE, 'build', 'python-validity'),
                    help='patched python-validity checkout (default: the one built by setup.sh)')
    args = ap.parse_args()
    pv = os.path.abspath(args.python_validity)

    if os.geteuid() != 0:
        sys.exit('Run it with sudo: it needs raw USB access.')
    if not os.path.isdir(os.path.join(pv, 'validitysensor')):
        sys.exit('python-validity not found in %s: run ./setup.sh install first.' % pv)
    if not wait_for_sensor(1):
        sys.exit('Sensor %s:%s not found on USB.' % (VID, PID))
    if not ensure_firmware(pv):
        sys.exit('The Lenovo firmware could not be downloaded.')

    # fprintd is D-Bus activated: mask it for the time of the pairing, or the
    # desktop could start it again and have it grab the sensor
    print('Stopping fprintd while pairing...')
    subprocess.run(['systemctl', 'mask', '--runtime', '--now', 'fprintd'], stderr=subprocess.DEVNULL)
    try:
        if args.factory_reset:
            if not args.yes:
                answer = input('Erase the sensor flash (pairing and stored fingerprints)? Type "yes": ')
                if answer.strip() != 'yes':
                    sys.exit('Cancelled.')
            print('Factory reset...')
            usb_reset()
            subprocess.run([sys.executable, '-c', RESET_CODE, pv])
            time.sleep(8)
            usb_reset()

        for attempt in range(1, args.tries + 1):
            print('Opening the sensor, attempt %d of %d...' % (attempt, args.tries))
            usb_reset()
            proc = subprocess.run([sys.executable, '-c', OPEN_CODE, pv],
                                  stdout=subprocess.PIPE, stderr=subprocess.STDOUT, text=True)
            lines = proc.stdout.strip().splitlines()
            print('\n'.join(lines[-6:]))
            if proc.returncode == 0 and 'SENSOR-OPEN-OK' in proc.stdout:
                print('\nThe sensor is paired and opens. Enrol a finger with: fprintd-enroll')
                return 0
            # Partitioning and the firmware upload end with a sensor reboot:
            # wait for it to come back, then open it again from a fresh process
            time.sleep(8)
        print('\nThe sensor did not open after %d attempts.' % args.tries)
        print('If it was paired by Windows or another driver, run again with --factory-reset,')
        print('right after a cold boot.')
        return 2
    finally:
        subprocess.run(['systemctl', 'unmask', '--runtime', 'fprintd'], stderr=subprocess.DEVNULL)


if __name__ == '__main__':
    sys.exit(main())

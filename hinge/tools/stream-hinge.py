#!/usr/bin/env python3
"""Records the "hinge" IIO sensor through both of its paths (the IIO buffer
stream and sysfs reads), next to the screen tilt computed from the screen
accelerometer, to check that the angles really follow the movement.
Stop iio-sensor-proxy first if it holds the buffer.
Usage: sudo ./stream-hinge.py [duration_s]"""
import glob, math, os, select, signal, struct, sys, threading, time

def find(name):
    for d in sorted(glob.glob('/sys/bus/iio/devices/iio:device*')):
        try:
            if open(d + '/name').read().strip() == name:
                return d
        except OSError:
            pass
    sys.exit(f'no "{name}" IIO device')

def rd(path):
    return open(path).read().strip()

def wr(path, val):
    with open(path, 'w') as f:
        f.write(str(val))

H, A = find('hinge'), find('accel_3d')
deg = float(rd(H + '/in_angl_scale')) * 180 / math.pi
duration = float(sys.argv[1]) if len(sys.argv) > 1 else 600

# Sample layout, from scan_elements (IIO ABI)
chans = []
for ch in ('in_angl0', 'in_angl1', 'in_angl2', 'in_timestamp'):
    t = rd(f'{H}/scan_elements/{ch}_type')          # e.g. le:s16/32>>0
    sign, bits = t.split(':')[1][0], t.split(':')[1][1:]
    real, rest = bits.split('/')
    storage, shift = rest.split('>>')
    chans.append((ch, int(rd(f'{H}/scan_elements/{ch}_index')), sign,
                  int(real), int(storage) // 8, int(shift)))
chans.sort(key=lambda c: c[1])
layout, off = [], 0
for ch, _, sign, real, size, shift in chans:
    off = (off + size - 1) // size * size
    layout.append((ch, off, sign, real, size, shift))
    off += size
rec = (off + 7) // 8 * 8

def decode(buf):
    out = {}
    for ch, o, sign, real, size, shift in layout:
        v = int.from_bytes(buf[o:o + size], 'little') >> shift
        v &= (1 << real) - 1
        if sign == 's' and v & (1 << (real - 1)):
            v -= 1 << real
        out[ch] = v
    return out

latest, count, lock, stop = None, 0, threading.Lock(), threading.Event()

def reader():
    global latest, count
    fd = os.open('/dev/' + os.path.basename(H), os.O_RDONLY | os.O_NONBLOCK)
    pend = b''
    while not stop.is_set():
        r, _, _ = select.select([fd], [], [], 0.2)
        if not r:
            continue
        try:
            pend += os.read(fd, 4096)
        except BlockingIOError:
            continue
        while len(pend) >= rec:
            s = decode(pend[:rec]); pend = pend[rec:]
            with lock:
                latest = s; count += 1
    os.close(fd)

def cleanup(*_):
    stop.set()

signal.signal(signal.SIGTERM, cleanup)
signal.signal(signal.SIGINT, cleanup)

wr(H + '/buffer/enable', 0)
for ch, *_ in layout:
    wr(f'{H}/scan_elements/{ch}_en', 1)
wr(H + '/buffer/length', 128)
wr(H + '/buffer/enable', 1)
t = threading.Thread(target=reader, daemon=True); t.start()

print(f'# {H} (buffer, {rec} bytes/sample) + sysfs, screen through {A}; {duration:.0f} s', flush=True)
print('# time         BUFFER hinge screen base | samples/s | SYSFS hinge | SCREEN (accel)', flush=True)
prev, t0, last_print, last_count = None, time.time(), 0, 0
try:
    while not stop.is_set() and time.time() - t0 < duration:
        time.sleep(0.25)
        with lock:
            s, n = latest, count
        try:
            sys_h = int(rd(H + '/in_angl0_raw')) * deg
            y, z = (int(rd(f'{A}/in_accel_{a}_raw')) for a in 'yz')
            scr = (math.degrees(math.atan2(z, y)) + 270) % 360
        except OSError as e:
            print(f'# sysfs read: {e}', flush=True); continue
        now = time.time()
        cur = (s and round(s['in_angl0'] * deg), round(sys_h), round(scr / 2) * 2)
        if cur != prev or now - last_print > 10:
            rate = (n - last_count) / max(now - last_print, 1e-3) if last_print else 0
            fl = (f"{s['in_angl0']*deg:6.1f} {s['in_angl1']*deg:6.1f} {s['in_angl2']*deg:6.1f}"
                  if s else '     -      -      -')
            print(f"{time.strftime('%H:%M:%S')}.{int(now*10)%10}  {fl} | {rate:5.1f} | {sys_h:6.1f} | {scr:6.1f}",
                  flush=True)
            prev, last_print, last_count = cur, now, n
finally:
    stop.set(); t.join(1)
    try:
        wr(H + '/buffer/enable', 0)
    except OSError:
        pass
    print(f'# end: {count} samples received from the buffer', flush=True)

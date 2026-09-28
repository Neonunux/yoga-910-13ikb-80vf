#!/usr/bin/env python3
"""Report of the suspend cycles, rebuilt from the journal.

   report.py [DAYS | --all] [--flagged]

For each cycle: trigger (lid or other), time asleep, time awake afterwards,
and anomalies: no resume, quick wake-up, wake-up with the lid closed, a
process crash, kernel warnings, a slow device, high power draw. The lines of
the suspend-debug hook (EC lid state, wake-up counters) are used when they
exist.
"""
import datetime as dt
import glob
import json
import os
import re
import shutil
import subprocess
import sys

IDS = ['kernel', 'systemd-logind', 'systemd-sleep', 'suspend-debug', 'systemd-coredump']
EVENTS = (r'PM: suspend (entry|exit)|Lid (opened|closed)|Suspending\.\.\.|'
          r'^(pre|post) type=|^context |^post-alive|^pm_trace|^wake counters|^watch |ANOMALY|'
          r'returned (-[0-9]+ after [0-9]+|[0-9]+ after [0-9]{6,}) usecs|'
          r'coredump: |dumped core|Timekeeping suspended|Wakeup pending|'
          r'ACPI LID|Query\(0x|PM: .*(fail|abort)')
NOISE = re.compile(r'HCI Enhanced Setup|kauditd_printk_skb|callbacks suppressed|Lockdown:|'
                   r'wireless extensions|lacks a native systemd unit|native systemd unit file|'
                   r'compatibility logic is deprecated')
FAST_WAKE_S = 60
DRAIN_HIGH_MW = 1000

B, R, G, Y, D, Z = '\033[1m', '\033[31m', '\033[32m', '\033[33m', '\033[2m', '\033[0m'
if not sys.stdout.isatty():
    B = R = G = Y = D = Z = ''


def journal(since, extra):
    cmd = ['journalctl', '--no-pager', '-q', '-o', 'json',
           '--output-fields=MESSAGE,SYSLOG_IDENTIFIER,PRIORITY'] + extra
    if since:
        cmd += ['--since', since]
    out = subprocess.run(cmd, capture_output=True, text=True).stdout
    for line in out.splitlines():
        e = json.loads(line)
        msg = e.get('MESSAGE') or ''
        if isinstance(msg, list):
            msg = bytes(msg).decode(errors='replace')
        yield {'t': dt.datetime.fromtimestamp(int(e['__REALTIME_TIMESTAMP']) / 1e6),
               'boot': e.get('_BOOT_ID'), 'id': e.get('SYSLOG_IDENTIFIER'),
               'prio': int(e.get('PRIORITY', 6)), 'msg': msg.strip()}


def kv(msg):
    return dict(re.findall(r'(\w+)=(\S+)', msg))


def fmt_dur(s):
    if s is None:
        return '—'
    s = int(s)
    if s < 120:
        return f'{s} s'
    if s < 7200:
        return f'{s // 60} min'
    if s < 172800:
        return f'{s // 3600} h {s % 3600 // 60:02d}'
    return f'{s // 86400} d {s % 86400 // 3600} h'


def boots_list():
    out = subprocess.run(['journalctl', '--list-boots', '--no-pager', '-o', 'json'],
                         capture_output=True, text=True).stdout
    return [(b['boot_id'], dt.datetime.fromtimestamp(b['first_entry'] / 1e6),
             dt.datetime.fromtimestamp(b['last_entry'] / 1e6)) for b in json.loads(out or '[]')]


def build_cycles(ev):
    cycles = []
    for i, e in enumerate(ev):
        if not (e['id'] == 'kernel' and e['msg'].startswith('PM: suspend entry')):
            continue
        c = {'entry': e['t'], 'boot': e['boot'], 'mode': e['msg'].split('(')[-1].rstrip(')'),
             'exit': None, 'trigger': 'other', 'pre': None, 'post': None, 'counters': None,
             'after': [], 'flags': [], 'slow': [], 'warn': [], 'next': None,
             'context': None, 'alive': False, 'trace': []}
        for p in reversed(ev[max(0, i - 40):i]):
            if (e['t'] - p['t']).total_seconds() > 15:
                break
            if p['id'] == 'systemd-logind' and p['msg'].startswith('Lid closed'):
                c['trigger'] = 'lid'
            if p['id'] == 'suspend-debug' and p['msg'].startswith('pre ') and not c['pre']:
                c['pre'] = kv(p['msg'])
            if p['id'] == 'suspend-debug' and p['msg'].startswith('context ') and not c['context']:
                c['context'] = kv(p['msg'])
        for n in ev[i + 1:]:
            if n['boot'] != e['boot'] or (n['id'] == 'kernel' and n['msg'].startswith('PM: suspend entry')):
                break
            if n['id'] == 'kernel' and n['msg'].startswith('PM: suspend exit'):
                c['exit'] = n['t']
                continue
            m = re.search(r'(\S+ \S+): (\S+) returned (-?\d+) after (\d+) usecs', n['msg'])
            if m and (c['exit'] is None or (n['t'] - c['exit']).total_seconds() < 5):
                c['slow'].append((int(m.group(4)) // 1000, m.group(1), m.group(2).split('+')[0], int(m.group(3))))
                continue
            # between entry and exit, everything is timestamped at resume time
            if c['exit'] and (n['t'] - c['exit']).total_seconds() > 240:
                continue
            if n['id'] == 'suspend-debug':
                if n['msg'].startswith('post ') and not c['post']:
                    c['post'] = kv(n['msg'])
                elif n['msg'] == 'post-alive':
                    c['alive'] = True
                elif n['msg'].startswith('wake counters'):
                    c['counters'] = n['msg'].split(':', 1)[1].strip()
                else:
                    c['after'].append((n['t'], n['msg']))
            elif n['id'] == 'systemd-logind' and n['msg'].startswith('Lid'):
                c['after'].append((n['t'], n['msg']))
            elif n['id'] == 'kernel' and re.search(r'ACPI LID|Query\(0x|Timekeeping|Wakeup pending|PM: .*(fail|abort)', n['msg']):
                c['after'].append((n['t'], n['msg']))
            elif re.search(r'coredump: \d+\((\S+)\)|Process \d+ \((\S+)\).*dumped core', n['msg']):
                name = re.search(r'coredump: \d+\((\S+)\)|Process \d+ \((\S+)\)', n['msg'])
                c['flags'].append(('crash of ' + (name.group(1) or name.group(2)), R))
        cycles.append(c)
    for a, b in zip(cycles, cycles[1:]):
        if a['exit'] and a['boot'] == b['boot']:
            a['next'] = (b['entry'] - a['exit']).total_seconds()
    return cycles


def add_warnings(cycles, since):
    warns = [w for w in journal(since, ['-k', '-p', 'warning']) if not NOISE.search(w['msg'])]
    for c in cycles:
        if not c['exit']:
            continue
        for w in warns:
            d = (w['t'] - c['exit']).total_seconds()
            if w['boot'] == c['boot'] and -2 <= d <= 60:
                c['warn'].append(w['msg'])


def trace_lines(boot_id):
    r = subprocess.run(['journalctl', '-b', boot_id, '-k', '-q', '-o', 'cat', '--no-pager'],
                       capture_output=True, text=True)
    return [l.strip() for l in r.stdout.splitlines() if re.search(r'RTC time:|Magic number|hash matches', l)]


def flag(cycles, boots, abnormal):
    nxt = {b[0]: boots[i + 1][1] for i, b in enumerate(boots[:-1])}
    nxt_id = {b[0]: boots[i + 1][0] for i, b in enumerate(boots[:-1])}
    ends = {bid: last for bid, last, _ in abnormal}
    last_of_boot = {c['boot']: c for c in cycles}
    for c in cycles:
        f = c['flags']
        if (c['context'] or {}).get('pm_trace') == '1' and c['boot'] in nxt_id and \
                (not c['exit'] or c['boot'] in ends) and last_of_boot[c['boot']] is c:
            c['trace'] = trace_lines(nxt_id[c['boot']])
        if not c['exit']:
            gap = (nxt[c['boot']] - c['entry']).total_seconds() if c['boot'] in nxt else None
            f.insert(0, (f'NO RESUME (rebooted {fmt_dur(gap)} later)' if gap else 'NO RESUME', R))
            if c['alive']:
                f.append(('processes thawed before the hang', Y))
            continue
        if c['boot'] in ends and last_of_boot[c['boot']] is c and (ends[c['boot']] - c['exit']).total_seconds() < 600:
            f.insert(0, (f"SUDDEN STOP {fmt_dur((ends[c['boot']] - c['exit']).total_seconds())} after the resume", R))
        dur = (c['exit'] - c['entry']).total_seconds()
        c['dur'] = dur
        if dur < FAST_WAKE_S:
            f.append((f'quick wake-up ({int(dur)} s)', Y))
        post = c['post'] or {}
        if post.get('lid_ec') == 'closed':
            f.append(('woke up with the lid CLOSED (EC)', R))
        elif any('Lid closed' in m for t, m in c['after'] if (t - c['exit']).total_seconds() < 90):
            f.append(('lid closed right after the resume', Y))
        if any('ANOMALY' in m for t, m in c['after']):
            f.append(('lid anomaly (hook)', R))
        if post.get('drain_mw') and int(post['drain_mw']) > DRAIN_HIGH_MW:
            f.append((f"high drain {post['drain_mw']} mW", Y))
        if c['warn']:
            f.append((f"{len(c['warn'])} kernel warning(s)", Y))
        bad = [s for s in c['slow'] if s[3] != 0]
        if bad:
            f.append((f'{len(bad)} failed PM callback(s)', R))
        if any(s[0] >= 1000 for s in c['slow']):
            f.append(('slow device (≥ 1 s)', Y))


def battery_before(t):
    """Last UPower charge sample before t: (date, %, state) or None."""
    last = None
    for f in glob.glob('/var/lib/upower/history-charge-*BAT*.dat'):
        for line in open(f):
            p = line.split()
            if len(p) == 3 and int(p[0]) <= t.timestamp():
                m = (dt.datetime.fromtimestamp(int(p[0])), float(p[1].replace(',', '.')), p[2])
                if not last or m[0] > last[0]:
                    last = m
    return last if last and (t - last[0]).total_seconds() < 6 * 3600 else None


def abnormal_boots(boots, since_dt, cycles):
    res = []
    for bid, first, last in boots[:-1]:
        if since_dt and last < since_dt:
            continue
        r = subprocess.run(['journalctl', '-b', bid, '-t', 'systemd-shutdown', '-n', '1', '-q', '-o', 'cat', '--no-pager'],
                           capture_output=True, text=True)
        if r.stdout.strip():
            continue
        in_sleep = any(c['boot'] == bid and not c['exit'] for c in cycles)
        res.append((bid, last, in_sleep))
    return res


def main():
    args = sys.argv[1:]
    only_flagged = '--flagged' in args
    args = [a for a in args if a != '--flagged']
    days = None if args[:1] == ['--all'] else int(args[0]) if args else 30
    since = (dt.datetime.now() - dt.timedelta(days=days)).strftime('%Y-%m-%d %H:%M:%S') if days else None
    since_dt = dt.datetime.now() - dt.timedelta(days=days) if days else None

    extra = ['--grep', EVENTS]
    for i in IDS:
        extra += ['-t', i]
    ev = list(journal(since, extra))
    boots = boots_list()
    cycles = build_cycles(ev)
    add_warnings(cycles, since)
    ab = abnormal_boots(boots, since_dt, cycles)
    flag(cycles, boots, ab)

    flagged = [c for c in cycles if c['flags']]
    print(f"{B}Suspend cycles {'since ' + since[:10] if since else '(whole journal)'}: "
          f"{len(cycles)} cycles, {len(flagged)} flagged, "
          f"{sum(1 for c in cycles if c['trigger'] == 'lid')} triggered by the lid{Z}")
    print(f"{D}{'date':<12} {'trig.':<6} {'asleep':>9} {'awake after':>14}  notes{Z}")
    for c in cycles:
        if only_flagged and not c['flags']:
            continue
        rem = ', '.join(col + txt + Z for txt, col in c['flags'])
        print(f"{c['entry']:%m-%d %H:%M}  {c['trigger']:<6} {fmt_dur(c.get('dur')):>9} {fmt_dur(c['next']):>14}  {rem}")

    hooked = [c for c in flagged if c['pre'] or c['post'] or c['slow'] or c['warn'] or c['after'] or c['trace']]
    if hooked:
        print(f"\n{B}Details of the flagged cycles{Z}")
    for c in hooked:
        print(f"{B}{c['entry']:%Y-%m-%d %H:%M:%S}{Z} ({c['trigger']}, {c['mode']})")
        if c['pre']:
            p = c['pre']
            print(f"  before   : lid EC={p.get('lid_ec')} ACPI={p.get('lid_acpi')} logind={p.get('lid_logind')}, "
                  f"AC={p.get('ac')}, battery {p.get('capacity')} %")
        if c['context']:
            x = c['context']
            print(f"  context  : displays {x.get('displays')}, USB {x.get('usb')}, hinge {x.get('hinge_deg')}°, "
                  f"{x.get('tablet_sw')}, modules {x.get('modules')}, tudor={x.get('tudor')}, "
                  f"suspend #{x.get('nth')} of the boot, pm_trace={x.get('pm_trace')}")
        if c['post']:
            p = c['post']
            print(f"  after    : lid EC={p.get('lid_ec')} ACPI={p.get('lid_acpi')} logind={p.get('lid_logind')}, "
                  f"wake-up IRQ {p.get('wake_irq')}" + (f", {p['drain_mw']} mW asleep" if p.get('drain_mw') else ''))
        if c['counters']:
            print(f"  counters : {c['counters']}")
        for t, m in c['after'][:12]:
            ref = c['exit'] or c['entry']
            print(f"  {(t - ref).total_seconds():+6.0f} s  {m[:150]}")
        for s in sorted(c['slow'], reverse=True)[:5]:
            print(f"  slow     : {s[0]} ms  {s[1]} {s[2]}" + (f"  → {R}error {s[3]}{Z}" if s[3] else ''))
        for w in c['warn'][:6]:
            print(f"  kernel   : {w[:150]}")
        for l in c['trace']:
            print(f"  pm_trace : {l[:150]}")

    print(f"\n{B}Boots that ended without a clean shutdown{Z}")
    if not ab:
        print(f"  {G}none{Z}")
    for bid, last, in_sleep in ab:
        bat = battery_before(last)
        btxt = f", battery {bat[1]:.0f} % ({bat[2]}) at {bat[0]:%H:%M}" if bat else ''
        if bat and bat[1] <= 3 and bat[2] == 'discharging':
            btxt += f' {R}→ probably an empty battery{Z}'
        print(f"  {last:%Y-%m-%d %H:%M}  {R if in_sleep else Y}{'during a suspend' if in_sleep else 'while awake (hang, empty battery or forced power off)'}{Z}{btxt}  {D}journalctl -b {bid[:12]}{Z}")

    print(f"\n{B}Crash traces kept{Z}")
    dumps = sorted(glob.glob('/var/crash/2*'))
    pstore = sorted(glob.glob('/var/lib/systemd/pstore/*'))
    print(f"  kdump   : {', '.join(os.path.basename(d) for d in dumps) or 'no vmcore'}")
    print(f"  pstore  : {', '.join(os.path.basename(p) for p in pstore) or 'nothing'}")
    if shutil.which('coredumpctl'):
        r = subprocess.run(['coredumpctl', 'list', '--no-pager', '-q'] + (['--since', since] if since else []),
                           capture_output=True, text=True)
        lines = [l for l in r.stdout.splitlines() if l.strip()]
        print(f"  coredump: {len(lines)} dump(s)" + (f", last: {lines[-1][:110]}" if lines else ''))
    else:
        print('  coredump: systemd-coredump not installed')


if __name__ == '__main__':
    main()

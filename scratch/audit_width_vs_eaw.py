#!/usr/bin/env python3
"""Compares the app's classifyWidth() dump against Unicode EastAsianWidth.txt.

Policy mapping (what we consider consistent):
  EAW F, W  -> class "full"  required
  EAW H, Na -> class "half"  required
  EAW A     -> ambiguous: full is OK for an East-Asian-oriented tool,
               anything else is reported as info
  EAW N     -> neutral: "half" or "proportional" is OK (proportional
               measures the real advance), "full" is a mismatch

Hard mismatches reported:
  EAW in {F,W}  but class != full
  EAW in {H,Na} but class != half
  class == full but EAW == N
"""
import sys

EAW_FILE = 'scratch/EastAsianWidth.txt'
DUMP_FILE = 'scratch/width_classes.txt'

# ---- load EAW as sorted merged ranges: (start, end, prop) ----
eaw = []
with open(EAW_FILE, encoding='utf-8') as f:
    for line in f:
        line = line.split('#')[0].strip()
        if not line:
            continue
        rng, prop = line.split(';')
        prop = prop.strip()
        rng = rng.strip()
        if '..' in rng:
            a, b = rng.split('..')
            eaw.append((int(a, 16), int(b, 16), prop))
        else:
            eaw.append((int(rng, 16), int(rng, 16), prop))
eaw.sort()

def eaw_of(cp):
    lo, hi = 0, len(eaw) - 1
    while lo <= hi:
        mid = (lo + hi) // 2
        s, e, p = eaw[mid]
        if cp < s:
            hi = mid - 1
        elif cp > e:
            lo = mid + 1
        else:
            return p
    return 'N'  # unlisted defaults to Neutral

# ---- load classify dump ----
classes = []  # (start, end, class)
with open(DUMP_FILE, encoding='utf-8') as f:
    for line in f:
        rng, cls = line.strip().split(':')
        a, b = rng.split('-')
        classes.append((int(a, 16), int(b, 16), cls))

def same_prop_run(cp, limit, prop):
    """extend run of identical EAW prop starting at cp, up to limit"""
    end = cp
    while end + 1 <= limit and eaw_of(end + 1) == prop:
        end += 1
    return end

hard_fw = []   # EAW F/W but not full
hard_hn = []   # EAW H/Na but not half
full_but_n = []  # full but EAW N (like braille was)
amb_info = []  # EAW A but not full

for (cs, ce, cls) in classes:
    cp = cs
    while cp <= ce:
        p = eaw_of(cp)
        end = same_prop_run(cp, ce, p)
        bad = None
        if p in ('F', 'W') and cls != 'full':
            bad = hard_fw
        elif p in ('H', 'Na') and cls != 'half':
            bad = hard_hn
        elif p == 'N' and cls == 'full':
            bad = full_but_n
        elif p == 'A' and cls != 'full':
            bad = amb_info
        if bad is not None:
            bad.append((cp, end, p, cls))
        cp = end + 1

def show(title, rows, limit=60):
    print(f'== {title}: {len(rows)} range(s) ==')
    for (s, e, p, cls) in rows[:limit]:
        print(f'  U+{s:04X}-U+{e:04X}  EAW={p:2s}  class={cls}')
    if len(rows) > limit:
        print(f'  ... and {len(rows) - limit} more')
    print()

show('EAW F/W but class != full (应全角而未全角)', hard_fw)
show('EAW H/Na but class != half (应半角而未半角)', hard_hn)
show('class == full but EAW == N (全角但官方中性)', full_but_n)
show('EAW A but class != full (歧义字符未按全角)', amb_info)

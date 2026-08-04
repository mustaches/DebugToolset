#!/usr/bin/env python3
"""Generates lib/modules/font_extractor/utils/unicode_assigned.dart from
UnicodeData.txt (Unicode 16.0.0, downloaded to scratch/).

The generated table lists all *undisplayable* code-point ranges:
  - code points not assigned in the UCD (including noncharacters and
    surrogates, which are never listed in UnicodeData.txt)
  - assigned control (Cc) and format (Cf) characters
"""
import sys

UCD = 'scratch/UnicodeData.txt'
OUT = 'lib/modules/font_extractor/utils/unicode_assigned.dart'
MAX_CP = 0x10FFFF

assigned = []   # (start, end) inclusive, all assigned code points
undisplayable_assigned = []  # (start, end) for Cc / Cf

with open(UCD, encoding='utf-8') as f:
    first_cp = None
    first_cat = None
    for line in f:
        parts = line.strip().split(';')
        if len(parts) < 3:
            continue
        cp = int(parts[0], 16)
        name = parts[1]
        cat = parts[2]
        if first_cp is not None:
            if name.endswith('Last>'):
                assigned.append((first_cp, cp))
                if first_cat in ('Cc', 'Cf', 'Cs'):
                    undisplayable_assigned.append((first_cp, cp))
                first_cp = None
                first_cat = None
            continue
        if name.endswith('First>'):
            first_cp = cp
            first_cat = cat
            continue
        assigned.append((cp, cp))
        if cat in ('Cc', 'Cf', 'Cs'):
            undisplayable_assigned.append((cp, cp))

assigned.sort()
# Sanity: ranges must be disjoint and sorted.
for i in range(1, len(assigned)):
    assert assigned[i][0] > assigned[i - 1][1], 'overlapping assigned ranges'

# Complement over [0, MAX_CP] -> unassigned (never displayable).
undisplayable = []
prev_end = -1
for s, e in assigned:
    if s > prev_end + 1:
        undisplayable.append((prev_end + 1, s - 1))
    prev_end = e
if prev_end < MAX_CP:
    undisplayable.append((prev_end + 1, MAX_CP))

# Merge in Cc / Cf ranges.
undisplayable.extend(undisplayable_assigned)
undisplayable.sort()
merged = []
for s, e in undisplayable:
    if merged and s <= merged[-1][1] + 1:
        if e > merged[-1][1]:
            merged[-1] = (merged[-1][0], e)
    else:
        merged.append((s, e))

print(f'assigned ranges: {len(assigned)}, undisplayable ranges: {len(merged)}')

def fmt(rs):
    lines = []
    for i in range(0, len(rs), 4):
        chunk = rs[i:i + 4]
        lines.append('    ' + ' '.join(
            f'(0x{s:05X}, 0x{e:05X}),' for s, e in chunk))
    return '\n'.join(lines)

dart = f'''/// Undisplayable Unicode code-point ranges, generated from the Unicode
/// Character Database (UnicodeData.txt, Unicode 16.0.0) by
/// `scratch/gen_undisplayable_ranges.py`. Do not edit by hand.
///
/// A code point is *undisplayable* when it is either:
/// - not assigned in the UCD (this includes noncharacters such as
///   U+FDD0-U+FDEF / U+FFFE / U+FFFF, which are never listed in
///   UnicodeData.txt), or
/// - an assigned control (Cc), format (Cf) or surrogate (Cs) character.
///
/// Fonts like GNU Unifont contain glyphs for the entire BMP and render
/// these code points as boxes filled with the code point's own hex value.
/// Such glyphs are fake placeholders, not real displayable characters.
library;

/// Sorted, merged, inclusive `(start, end)` ranges of undisplayable
/// code points.
const List<(int, int)> kUndisplayableRanges = [
{fmt(merged)}
];

/// Returns true when [codePoint] is undisplayable (unassigned, noncharacter,
/// surrogate, control or format character).
bool isUndisplayableCodePoint(int codePoint) {{
  if (codePoint < 0 || codePoint > 0x10FFFF) return true;
  int lo = 0;
  int hi = kUndisplayableRanges.length - 1;
  while (lo <= hi) {{
    final mid = (lo + hi) >> 1;
    final r = kUndisplayableRanges[mid];
    if (codePoint < r.$1) {{
      hi = mid - 1;
    }} else if (codePoint > r.$2) {{
      lo = mid + 1;
    }} else {{
      return true;
    }}
  }}
  return false;
}}
'''

with open(OUT, 'w', encoding='utf-8', newline='\n') as f:
    f.write(dart)
print('wrote', OUT)

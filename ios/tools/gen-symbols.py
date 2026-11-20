"""Ports the web app's symbol sprite (public/index.html, made by
tools/gen-symbols.py) to Swift, so the native app draws the very same
glyphs: one 24-unit grid, stroke and fill layers, secondary layers and
knock-outs. SVG path data (arcs included) becomes absolute move / line /
cubic / close operations.

python3 ios/tools/gen-symbols.py   # writes ios/Cuven/Design/Symbols.generated.swift
"""
import math, pathlib, re

ROOT = pathlib.Path(__file__).resolve().parents[2]
html = (ROOT / 'public' / 'index.html').read_text()

TOKEN = re.compile(r'[MmLlHhVvCcSsQqTtAaZz]|[-+]?(?:\d*\.\d+|\d+\.?)(?:[eE][-+]?\d+)?')

def arc_to_cubics(x1, y1, rx, ry, phi, fa, fs, x2, y2):
    if rx == 0 or ry == 0:
        return [('L', x2, y2)]
    phi = math.radians(phi)
    cp, sp = math.cos(phi), math.sin(phi)
    dx, dy = (x1 - x2) / 2, (y1 - y2) / 2
    x1p = cp * dx + sp * dy
    y1p = -sp * dx + cp * dy
    rx, ry = abs(rx), abs(ry)
    lam = x1p ** 2 / rx ** 2 + y1p ** 2 / ry ** 2
    if lam > 1:
        s = math.sqrt(lam); rx *= s; ry *= s
    num = rx * rx * ry * ry - rx * rx * y1p * y1p - ry * ry * x1p * x1p
    den = rx * rx * y1p * y1p + ry * ry * x1p * x1p
    co = math.sqrt(max(0, num / den)) if den else 0
    if fa == fs:
        co = -co
    cxp = co * rx * y1p / ry
    cyp = -co * ry * x1p / rx
    cx = cp * cxp - sp * cyp + (x1 + x2) / 2
    cy = sp * cxp + cp * cyp + (y1 + y2) / 2
    def ang(ux, uy, vx, vy):
        a = math.atan2(ux * vy - uy * vx, ux * vx + uy * vy)
        return a
    t1 = ang(1, 0, (x1p - cxp) / rx, (y1p - cyp) / ry)
    dt = ang((x1p - cxp) / rx, (y1p - cyp) / ry, (-x1p - cxp) / rx, (-y1p - cyp) / ry)
    if not fs and dt > 0:
        dt -= 2 * math.pi
    elif fs and dt < 0:
        dt += 2 * math.pi
    segs = max(1, math.ceil(abs(dt) / (math.pi / 2)))
    d = dt / segs
    out = []
    for i in range(segs):
        a1 = t1 + i * d
        a2 = a1 + d
        k = 4 / 3 * math.tan(d / 4)
        def pt(a):
            x = rx * math.cos(a); y = ry * math.sin(a)
            return cp * x - sp * y + cx, sp * x + cp * y + cy
        def dv(a):
            x = -rx * math.sin(a); y = ry * math.cos(a)
            return cp * x - sp * y, sp * x + cp * y
        p1 = pt(a1); p2 = pt(a2); d1 = dv(a1); d2 = dv(a2)
        out.append(('C', p1[0] + k * d1[0], p1[1] + k * d1[1], p2[0] - k * d2[0], p2[1] - k * d2[1], p2[0], p2[1]))
    return out

def parse(d):
    toks = TOKEN.findall(d)
    i = 0
    ops = []
    x = y = sx = sy = 0.0
    lcx = lcy = None  # last cubic control (for S)
    lqx = lqy = None  # last quad control (for T)
    cmd = None
    def num():
        nonlocal i
        v = float(toks[i]); i += 1
        return v
    def flag():
        nonlocal i
        t = toks[i]
        # flags can be glued: "01" or "1.5" after a flag; take one digit
        if len(t) > 1 and t[0] in '01':
            toks[i] = t[1:]
            return int(t[0])
        i += 1
        return int(float(t))
    while i < len(toks):
        if re.match(r'[A-Za-z]', toks[i]):
            cmd = toks[i]; i += 1
            if cmd in 'Zz':
                ops.append(('Z',)); x, y = sx, sy; lcx = lqx = None
                continue
        rel = cmd.islower()
        c = cmd.upper()
        if c == 'M':
            nx, ny = num(), num()
            if rel: nx += x; ny += y
            ops.append(('M', nx, ny)); x, y = sx, sy = nx, ny
            cmd = 'l' if rel else 'L'
            lcx = lqx = None
        elif c == 'L':
            nx, ny = num(), num()
            if rel: nx += x; ny += y
            ops.append(('L', nx, ny)); x, y = nx, ny; lcx = lqx = None
        elif c == 'H':
            nx = num() + (x if rel else 0)
            ops.append(('L', nx, y)); x = nx; lcx = lqx = None
        elif c == 'V':
            ny = num() + (y if rel else 0)
            ops.append(('L', x, ny)); y = ny; lcx = lqx = None
        elif c == 'C':
            v = [num() for _ in range(6)]
            if rel: v = [v[0] + x, v[1] + y, v[2] + x, v[3] + y, v[4] + x, v[5] + y]
            ops.append(('C', *v)); lcx, lcy = v[2], v[3]; x, y = v[4], v[5]; lqx = None
        elif c == 'S':
            v = [num() for _ in range(4)]
            if rel: v = [v[0] + x, v[1] + y, v[2] + x, v[3] + y]
            c1x, c1y = (2 * x - lcx, 2 * y - lcy) if lcx is not None else (x, y)
            ops.append(('C', c1x, c1y, *v)); lcx, lcy = v[0], v[1]; x, y = v[2], v[3]; lqx = None
        elif c == 'Q':
            v = [num() for _ in range(4)]
            if rel: v = [v[0] + x, v[1] + y, v[2] + x, v[3] + y]
            ops.append(('Q', *v)); lqx, lqy = v[0], v[1]; x, y = v[2], v[3]; lcx = None
        elif c == 'T':
            nx, ny = num(), num()
            if rel: nx += x; ny += y
            qx, qy = (2 * x - lqx, 2 * y - lqy) if lqx is not None else (x, y)
            ops.append(('Q', qx, qy, nx, ny)); lqx, lqy = qx, qy; x, y = nx, ny; lcx = None
        elif c == 'A':
            rx, ry, phi = num(), num(), num()
            fa, fs = flag(), flag()
            nx, ny = num(), num()
            if rel: nx += x; ny += y
            ops += arc_to_cubics(x, y, rx, ry, phi, fa, fs, nx, ny)
            x, y = nx, ny; lcx = lqx = None
    return ops

def f(v):
    s = f'{round(v, 3):g}'
    return s if s != '-0' else '0'

def swift_ops(ops):
    out = []
    for o in ops:
        if o[0] == 'M': out.append(f'.m({f(o[1])},{f(o[2])})')
        elif o[0] == 'L': out.append(f'.l({f(o[1])},{f(o[2])})')
        elif o[0] == 'C': out.append(f'.c({",".join(f(v) for v in o[1:])})')
        elif o[0] == 'Q': out.append(f'.q({",".join(f(v) for v in o[1:])})')
        elif o[0] == 'Z': out.append('.z')
    return '[' + ', '.join(out) + ']'

def camel(name):
    parts = name.split('-')
    s = parts[0] + ''.join(p.capitalize() for p in parts[1:])
    return {'repeat': 'repeat_', 'case': 'case_', 'default': 'default_'}.get(s, s) if not s[0].isdigit() else '_' + s

def attrs_of(text):
    return dict(re.findall(r'([a-zA-Z-]+)="([^"]*)"', text))

def elements(body):
    """Each drawable element of a symbol as (class, path data): paths, circles and rounded rects."""
    out = []
    for tag, rest in re.findall(r'<(path|circle|rect)\b([^>]*)/?>', body):
        a = attrs_of(rest)
        cls = a.get('class', 's')
        if tag == 'path':
            out.append((cls, a['d']))
        elif tag == 'circle':
            cx, cy, r = float(a['cx']), float(a['cy']), float(a['r'])
            out.append((cls, f'M{cx} {cy - r}a{r} {r} 0 1 1 0 {2 * r}a{r} {r} 0 1 1 0 {-2 * r}z'))
        else:
            x, y, w, h = float(a['x']), float(a['y']), float(a['width']), float(a['height'])
            r = float(a.get('rx', a.get('ry', 0)))
            if r:
                out.append((cls, f'M{x + r} {y}H{x + w - r}A{r} {r} 0 0 1 {x + w} {y + r}V{y + h - r}A{r} {r} 0 0 1 {x + w - r} {y + h}'
                                 f'H{x + r}A{r} {r} 0 0 1 {x} {y + h - r}V{y + r}A{r} {r} 0 0 1 {x + r} {y}z'))
            else:
                out.append((cls, f'M{x} {y}H{x + w}V{y + h}H{x}z'))
    return out

symbols = re.findall(r'<symbol id="i-([a-z0-9-]+)"[^>]*?data-sf="([^"]*)"([^>]*)>(.*?)</symbol>', html, re.S)
cases, tables = [], []
for name, sf, attrs, body in symbols:
    layers = []
    for cls, d in elements(body):
        c = cls.split()
        kind = '.stroke' if c[0] == 's' else '.fill'
        tier = 3 if 'l3' in c else 2 if 'l2' in c else 1
        knock = 'k' in c
        layers.append(f'SymLayer({kind}, tier: {tier}, knock: {"true" if knock else "false"}, ops: {swift_ops(parse(d))})')
    key = camel(name)
    cases.append(f'    case {key} = "{name}"')
    glyph = 2.2 if name.startswith('chevron') or name in ('xmark', 'plus', 'filter', 'search') else 2.3 if name == 'check' else 2.5 if name == 'arrow-up' else 1.9
    slash = 'true' if 'data-slash' in attrs else 'false'
    tables.append(f'        case .{key}: return SymDef(sf: "{sf}", glyph: {glyph}, slashable: {slash}, layers: [\n            ' + ',\n            '.join(layers) + '\n        ])')

out = f'''// Generated by ios/tools/gen-symbols.py from the web app's sprite
// (public/index.html). Do not edit by hand.
import CoreGraphics

enum Sym: String, CaseIterable {{
{chr(10).join(cases)}
}}

extension Sym {{
    var def: SymDef {{
        switch self {{
{chr(10).join(tables)}
        }}
    }}
}}
'''
dest = ROOT / 'ios' / 'Cuven' / 'Design' / 'Symbols.generated.swift'
dest.write_text(out)
print(f'{len(symbols)} symbols -> {dest}')

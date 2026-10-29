"""Generate the icon sprite in public/index.html.

Symbols follow the SF Symbols authoring rules, adapted to SVG on the web:
one 24pt grid, every outline at the same weight (set per context through
--sym-w, like matching a symbol's weight to adjacent text), round caps and
joins, paths only (pathLength=1, so any stroke can be drawn on or off), flat
fills, and layers annotated for rendering modes:
  s / f      stroke or fill
  l2 / l3    secondary / tertiary layer (hierarchical and palette modes)
  v0..v3     variable-color order (first to light at v0)
  k          knock-out drawn in --sym-knock over a fill
Symbols marked slash=True can carry a slash that erases a gap in the base
as it draws (Magic Replace for X / X.slash pairs).

python3 tools/gen-symbols.py   # rewrites the sprite block in public/index.html
"""
import re, pathlib

def n(v):
    return f'{round(v, 3):g}'

def circle(cx, cy, r):
    return f'M{n(cx)} {n(cy - r)}a{n(r)} {n(r)} 0 1 1 0 {n(2 * r)} {n(r)} {n(r)} 0 0 1 0-{n(2 * r)}z'

SYMBOLS = [
  # name, SF Symbol it stands in for, layers, slashable
  ('chevron-left', 'chevron.left', [('s', 'M14.5 4.8 7.3 12l7.2 7.2')]),
  ('chevron-right', 'chevron.right', [('s', 'M9.5 4.8l7.2 7.2-7.2 7.2')]),
  ('chevron-down', 'chevron.down', [('s', 'M4.8 9.3l7.2 7.2 7.2-7.2')]),
  ('compose', 'square.and.pencil', [('s l2', 'M11.2 4.2H7.2a3 3 0 0 0-3 3v9.6a3 3 0 0 0 3 3h9.6a3 3 0 0 0 3-3v-4'), ('s', 'M17.7 3.8a1.9 1.9 0 0 1 2.7 2.7l-7.9 7.9-3.5.8.8-3.5z')]),
  ('search', 'magnifyingglass', [('s', circle(10.6, 10.6, 6.4)), ('s', 'M15.3 15.3 20 20')]),
  ('plus', 'plus', [('s', 'M12 5v14'), ('s', 'M5 12h14')]),
  ('arrow-up', 'arrow.up', [('s', 'M12 19.5V5'), ('s', 'M6 11l6-6 6 6')]),
  ('xmark', 'xmark', [('s', 'M6.5 6.5l11 11'), ('s', 'M17.5 6.5l-11 11')]),
  ('ellipsis', 'ellipsis', [('f v0', circle(5.5, 12, 1.7)), ('f v1', circle(12, 12, 1.7)), ('f v2', circle(18.5, 12, 1.7))]),
  ('filter', 'line.3.horizontal.decrease', [('s', 'M4.5 7h15'), ('s', 'M7.5 12h9'), ('s', 'M10.5 17h3')]),
  ('person', 'person', [('s', circle(12, 8.1, 3.9)), ('s', 'M4.6 20c.9-3.7 3.8-5.8 7.4-5.8s6.5 2.1 7.4 5.8')]),
  ('people', 'person.2', [('s', circle(9, 8.4, 3.4)), ('s', 'M2.9 19.5c.8-3.3 3.1-5.1 6.1-5.1s5.3 1.8 6.1 5.1'), ('s l2', 'M15.3 5.4a3.3 3.3 0 0 1 0 6.2'), ('s l2', 'M17.4 14.5c1.9.6 3.2 2.3 3.7 5')]),
  ('person-2', 'person.2', 'people'),
  ('bell', 'bell', [('s', 'M6 16.2V11a6 6 0 0 1 12 0v5.2l1.6 1.8H4.4z'), ('s l2', 'M10 20.6a2.2 2.2 0 0 0 4 0')], True),
  ('pin', 'pin', [('s', 'M9 3.5h6l-.9 5.2 3.4 3.3v2H6.5v-2l3.4-3.3z'), ('s l2', 'M12 14v6.5')], True),
  ('check', 'checkmark', [('s', 'M5 12.6l4.4 4.4L19 7.4')]),
  ('exclaim', 'exclamationmark.circle.fill', [('f', circle(12, 12, 9.5)), ('s k', 'M12 7v6.2'), ('f k', circle(12, 17, 1.35))]),
  ('play', 'play.fill', [('f', 'M8 5.3v13.4a1.1 1.1 0 0 0 1.7.9l10.6-6.7a1.1 1.1 0 0 0 0-1.8L9.7 4.4A1.1 1.1 0 0 0 8 5.3z')]),
  ('pause', 'pause.fill', [('f', 'M7.2 5h2.6A1.2 1.2 0 0 1 11 6.2v11.6a1.2 1.2 0 0 1-1.2 1.2H7.2A1.2 1.2 0 0 1 6 17.8V6.2A1.2 1.2 0 0 1 7.2 5z'), ('f', 'M14.2 5h2.6A1.2 1.2 0 0 1 18 6.2v11.6a1.2 1.2 0 0 1-1.2 1.2h-2.6a1.2 1.2 0 0 1-1.2-1.2V6.2A1.2 1.2 0 0 1 14.2 5z')]),
  ('doc', 'doc', [('s', 'M7.2 3h6.8L19 8v11a2 2 0 0 1-2 2H7.2a2 2 0 0 1-2-2V5a2 2 0 0 1 2-2z'), ('s l2', 'M13.8 3.2v5H19')]),
  ('link', 'link', [('s', 'M10.3 13.7a3.8 3.8 0 0 0 5.4 0l3-3a3.8 3.8 0 0 0-5.4-5.4l-1.1 1.1'), ('s', 'M13.7 10.3a3.8 3.8 0 0 0-5.4 0l-3 3a3.8 3.8 0 0 0 5.4 5.4l1.1-1.1')]),
  ('photo', 'photo', [('s', 'M6 4.5h12a3 3 0 0 1 3 3v9a3 3 0 0 1-3 3H6a3 3 0 0 1-3-3v-9a3 3 0 0 1 3-3z'), ('s l2', circle(15.5, 9.5, 1.6)), ('s', 'M3.4 16.6l5.1-5.1 4.2 4.2 2.4-2.4 5.4 5.2')]),
  ('camera', 'camera', [('s', 'M4.6 7.4h2.9L9.1 5h5.8l1.6 2.4h2.9A1.6 1.6 0 0 1 21 9v8.9a1.6 1.6 0 0 1-1.6 1.6H4.6A1.6 1.6 0 0 1 3 17.9V9a1.6 1.6 0 0 1 1.6-1.6z'), ('s l2', circle(12, 13.1, 3.5))]),
  ('mappin', 'mappin.and.ellipse', [('s', 'M12 21s-6.5-6.1-6.5-11a6.5 6.5 0 0 1 13 0c0 4.9-6.5 11-6.5 11z'), ('s l2', circle(12, 10, 2.3))]),
  ('yen', 'yensign.circle', [('s l2', circle(12, 12, 9)), ('s', 'M8.6 7l3.4 5 3.4-5'), ('s', 'M12 12v5.5'), ('s', 'M9 12.6h6'), ('s', 'M9 15.2h6')]),
  ('envelope', 'envelope (red packet)', [('s', 'M7 3h10a2.5 2.5 0 0 1 2.5 2.5v13A2.5 2.5 0 0 1 17 21H7a2.5 2.5 0 0 1-2.5-2.5v-13A2.5 2.5 0 0 1 7 3z'), ('s l2', 'M4.5 8.4c4.6 3 10.4 3 15 0'), ('s', circle(12, 12.7, 1.7))]),
  ('trash', 'trash', [('s', 'M4.5 6.5h15'), ('s', 'M9.5 6.5V4.6h5v1.9'), ('s', 'M6.6 6.5l.9 12.6a2 2 0 0 0 2 1.9h5a2 2 0 0 0 2-1.9l.9-12.6'), ('s l2', 'M10 10.5v6.5'), ('s l2', 'M14 10.5v6.5')]),
  ('undo', 'arrow.uturn.backward', [('s', 'M8.8 14.6 4 9.8 8.8 5'), ('s', 'M4 9.8h10.4a5.4 5.4 0 0 1 0 10.8H11')]),
  ('copy', 'doc.on.doc', [('s', 'M11 8.5h7a2.5 2.5 0 0 1 2.5 2.5v7.5A2.5 2.5 0 0 1 18 21h-7a2.5 2.5 0 0 1-2.5-2.5V11A2.5 2.5 0 0 1 11 8.5z'), ('s l2', 'M15.5 8.5V6A2.5 2.5 0 0 0 13 3.5H6.5A2.5 2.5 0 0 0 4 6v7a2.5 2.5 0 0 0 2.5 2.5h2')]),
  ('qrcode', 'qrcode', [('s', 'M5 3.5h3.5A1.5 1.5 0 0 1 10 5v3.5A1.5 1.5 0 0 1 8.5 10H5a1.5 1.5 0 0 1-1.5-1.5V5A1.5 1.5 0 0 1 5 3.5z'), ('s', 'M15.5 3.5H19A1.5 1.5 0 0 1 20.5 5v3.5A1.5 1.5 0 0 1 19 10h-3.5A1.5 1.5 0 0 1 14 8.5V5a1.5 1.5 0 0 1 1.5-1.5z'), ('s', 'M5 14h3.5a1.5 1.5 0 0 1 1.5 1.5V19a1.5 1.5 0 0 1-1.5 1.5H5A1.5 1.5 0 0 1 3.5 19v-3.5A1.5 1.5 0 0 1 5 14z'), ('s l2', 'M14 14h2.5v2.5H14z'), ('s l2', 'M18 18h2.5v2.5H18z'), ('s l2', 'M14 18.5v2'), ('s l2', 'M18.5 14h2')]),
  ('lock', 'lock', [('s', 'M7.5 10.5h9A2.5 2.5 0 0 1 19 13v5a2.5 2.5 0 0 1-2.5 2.5h-9A2.5 2.5 0 0 1 5 18v-5a2.5 2.5 0 0 1 2.5-2.5z'), ('s l2', 'M8 10.5V8a4 4 0 0 1 8 0v2.5')]),
  ('refresh', 'arrow.clockwise', [('s', 'M19.5 12a7.5 7.5 0 1 1-2.2-5.3'), ('s', 'M19.5 4.5v4h-4')]),
  ('info', 'info.circle', [('s l2', circle(12, 12, 9)), ('s', 'M12 11v5.6'), ('f', circle(12, 7.9, 1.1))]),
  ('download', 'arrow.down.to.line', [('s', 'M12 4v11'), ('s', 'M7 10.5l5 5 5-5'), ('s l2', 'M5 19.5h14')]),
  ('share', 'square.and.arrow.up', [('s', 'M12 14.5V3.5'), ('s', 'M8 7.5l4-4 4 4'), ('s l2', 'M8.5 10H7a2 2 0 0 0-2 2v6.5A2.5 2.5 0 0 0 7.5 21h9a2.5 2.5 0 0 0 2.5-2.5V12a2 2 0 0 0-2-2h-1.5')]),
  ('logout', 'rectangle.portrait.and.arrow.right', [('s l2', 'M13.5 4H7a2.5 2.5 0 0 0-2.5 2.5v11A2.5 2.5 0 0 0 7 20h6.5'), ('s', 'M10 12h10'), ('s', 'M16.5 8.5 20 12l-3.5 3.5')]),
  ('eye', 'eye', [('s', 'M12 5c5 0 8.3 4.5 9.2 6.2a1.7 1.7 0 0 1 0 1.6C20.3 14.5 17 19 12 19s-8.3-4.5-9.2-6.2a1.7 1.7 0 0 1 0-1.6C3.7 9.5 7 5 12 5z'), ('s l2', circle(12, 12, 3))], True),
  ('unread', 'app.badge', [('s l2', 'M20 12.5V17a3 3 0 0 1-3 3H7a3 3 0 0 1-3-3V8a3 3 0 0 1 3-3h5.5'), ('f', circle(18.5, 5.5, 2.5))]),
  ('bubble', 'bubble.left', [('s', 'M12 4C7 4 3 7.3 3 11.4c0 2.3 1.3 4.4 3.3 5.8-.2 1.3-.9 2.5-2 3.3 2.1.1 3.9-.6 5.1-1.7.8.2 1.7.3 2.6.3 5 0 9-3.3 9-7.7S17 4 12 4z')]),
  ('wifi', 'wifi', [('f v0', circle(12, 19.2, 1.3)), ('s v1', 'M8.8 15.9a4.8 4.8 0 0 1 6.4 0'), ('s v2', 'M5.8 12.6a9.4 9.4 0 0 1 12.4 0'), ('s v3', 'M2.8 9.3a14 14 0 0 1 18.4 0')], True),
  ('speaker', 'speaker.wave.2', [('s', 'M4 9.6v4.8h3.4l4.6 4.1V5.5L7.4 9.6z'), ('s v0', 'M15.4 9.2a4 4 0 0 1 0 5.6'), ('s v1', 'M17.9 6.6a7.7 7.7 0 0 1 0 10.8')]),
  ('video', 'video', [('s', 'M5.5 6.5h7.5a2.5 2.5 0 0 1 2.5 2.5v6a2.5 2.5 0 0 1-2.5 2.5H5.5A2.5 2.5 0 0 1 3 15V9a2.5 2.5 0 0 1 2.5-2.5z'), ('s', 'M15.5 10.4l4.6-2.8a.6.6 0 0 1 .9.5v7.8a.6.6 0 0 1-.9.5l-4.6-2.8')], True),
  ('sparkles', 'sparkles', [('f', 'M11 3.5c.6 3.7 1.8 5 5.5 5.5-3.7.6-4.9 1.8-5.5 5.5-.6-3.7-1.8-4.9-5.5-5.5 3.7-.5 4.9-1.8 5.5-5.5z'), ('f l2', 'M18 13.5c.3 1.8.9 2.4 2.7 2.7-1.8.3-2.4.9-2.7 2.7-.3-1.8-.9-2.4-2.7-2.7 1.8-.3 2.4-.9 2.7-2.7z')]),
  ('phone', 'phone', [('s', 'M5.2 3.6h2.4a1 1 0 0 1 1 .8l.8 3.4a1 1 0 0 1-.3 1L7.6 10.3a12.3 12.3 0 0 0 6.1 6.1l1.5-1.5a1 1 0 0 1 1-.3l3.4.8a1 1 0 0 1 .8 1v2.4a1.6 1.6 0 0 1-1.7 1.6C10.6 19.9 4.1 13.4 3.6 5.3a1.6 1.6 0 0 1 1.6-1.7z')]),
  ('phone-fill', 'phone.fill', [('f', 'M5.2 3.6h2.4a1 1 0 0 1 1 .8l.8 3.4a1 1 0 0 1-.3 1L7.6 10.3a12.3 12.3 0 0 0 6.1 6.1l1.5-1.5a1 1 0 0 1 1-.3l3.4.8a1 1 0 0 1 .8 1v2.4a1.6 1.6 0 0 1-1.7 1.6C10.6 19.9 4.1 13.4 3.6 5.3a1.6 1.6 0 0 1 1.6-1.7z')]),
  ('phone-down', 'phone.down.fill', [('f', 'M12 8.2c-3.3 0-6.3.7-8.5 2-1 .6-1.4 1.6-1.3 2.7l.2 1.7c.1.8.8 1.4 1.6 1.4l3-.3c.8-.1 1.4-.7 1.5-1.5l.2-1.6c2.1-.7 4.5-.7 6.6 0l.2 1.6c.1.8.7 1.4 1.5 1.5l3 .3c.8 0 1.5-.6 1.6-1.4l.2-1.7c.1-1.1-.3-2.1-1.3-2.7-2.2-1.3-5.2-2-8.5-2z')]),
  ('mic', 'mic.fill', [('f', 'M12 3a3 3 0 0 1 3 3v5a3 3 0 0 1-6 0V6a3 3 0 0 1 3-3z'), ('s', 'M6 11a6 6 0 0 0 12 0'), ('s', 'M12 17v3.5'), ('s l2', 'M8.5 20.5h7')], True),
  ('brush', 'pencil.and.scribble', [('s', 'M16.3 3.9a2.1 2.1 0 0 1 3 3L8.9 17.3l-4.4 1.5 1.5-4.4z'), ('s l2', 'M14.5 5.7l3 3'), ('s l2', 'M12.5 20.5c1.8 0 2.7-1.2 4.2-1.2 1.2 0 1.8.6 2.8.6')]),
]

def render():
    out = ['  <!-- Symbols drawn for this app after the SF Symbols rules; generated by tools/gen-symbols.py. -->',
           '  <svg class="sprite" aria-hidden="true" focusable="false">', '    <defs>']
    by_name = {}
    for entry in SYMBOLS:
        name, sf, layers = entry[0], entry[1], entry[2]
        slash = len(entry) > 3 and entry[3]
        if isinstance(layers, str):
            layers, slash = by_name[layers]
        by_name[name] = (layers, slash)
        parts = []
        for cls, d in layers:
            length = ' pathLength="1"' if cls.split()[0] == 's' else ''
            parts.append(f'<path class="{cls}" d="{d}"{length}/>')
        attrs = ' data-slash=""' if slash else ''
        out.append(f'      <symbol id="i-{name}" viewBox="0 0 24 24" data-sf="{sf}"{attrs}>{"".join(parts)}</symbol>')
    out += ['    </defs>', '  </svg>']
    return '\n'.join(out)

page = pathlib.Path(__file__).resolve().parent.parent / 'public' / 'index.html'
html = page.read_text()
block = re.compile(r'  <!-- (?:SF Symbols–style line icons, 24×24, drawn for this app\.|Symbols drawn for this app after the SF Symbols rules; generated by tools/gen-symbols\.py\.) -->\n  <svg class="sprite".*?</svg>', re.S)
assert block.search(html), 'sprite block not found'
page.write_text(block.sub(lambda m: render(), html, count=1))
print(f'{len(SYMBOLS)} symbols written to {page}')

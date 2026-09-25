import math, os
CX, CY = 495, 540          # ring centre on screen
R = 290                    # ring radius
TILT = math.radians(26)    # camera looks down this much
D = 1900                   # perspective distance
W, H = 265, 160          # on its side: long edge runs along the radius
R_IN = 80
STRETCH = 0.25           # extra length for cards on the right of the ring            # ordinary card
SPACING = 24               # degrees between cards
SHOW_PHI = 0               # showing card: right side, flat to the viewer
SHOW_SPIN = 14             # then spun clockwise in the picture plane: right corner lower

def proj(x, y, z):
    s = D / (D - z)
    return CX + x * s, CY + (-y * math.cos(TILT) + z * math.sin(TILT)) * s, s

def card_quad(phi, facing_viewer=False, w=W, h=H):
    p = math.radians(phi)
    cx, cz = R * math.cos(p), R * math.sin(p)
    tx, tz = (1, 0) if facing_viewer else (-math.sin(p), math.cos(p))
    pts = []
    for dx, y in ((-1, h), (1, h), (1, 0), (-1, 0)):   # TL TR BR BL
        pts.append(proj(cx + tx * dx * w / 2, y - h * 0.35, cz + tz * dx * w / 2)[:2])
    return pts, cz

def affine(quad, w, h):
    # map card-local (0,0)-(w,h) onto quad TL, TR, BL (parallelogram approx)
    (x0, y0), (x1, y1), _, (x3, y3) = quad
    a, b = (x1 - x0) / w, (y1 - y0) / w
    c, d = (x3 - x0) / h, (y3 - y0) / h
    return f"matrix({a:.4f} {b:.4f} {c:.4f} {d:.4f} {x0:.2f} {y0:.2f})"

FACES = [("#f4b6a0", "#9fc98a"), ("#b9d8f0", "#e8d37a"), ("#d7b8e8", "#8fbfb0"),
         ("#f6d58e", "#7fb3d5"), ("#a8d5ba", "#e9a3a3")]

def mix(a, b, t):
    ca = [int(a[i:i+2], 16) for i in (1, 3, 5)]
    cb = [int(b[i:i+2], 16) for i in (1, 3, 5)]
    return "#" + "".join(f"{round(x + (y - x) * t):02x}" for x, y in zip(ca, cb))

def radial_quad(phi):
    p = math.radians(phi)
    ux, uz = math.cos(p), math.sin(p)
    pts = []
    w = W * (1 + STRETCH * max(0.0, ux))   # right-hand cards reach farther out
    for r, y in ((R_IN, H), (R_IN + w, H), (R_IN + w, 0), (R_IN, 0)):   # inner-top, outer-top, outer-bottom, inner-bottom
        pts.append(proj(ux * r, y - H * 0.35, uz * r)[:2])
    return pts, uz * (R_IN + w / 2)

def ordinary_card(phi, i):
    quad, z = radial_quad(phi)
    p = math.radians(phi)
    shows_face = False
    t = (z + R) / (2 * R)                   # 0 = far back, 1 = front
    fade = 1
    m = affine(quad, W, H)
    if shows_face:
        top, bot = FACES[i % len(FACES)]
        inner = (f'<rect x="6" y="6" width="{W-12}" height="{H*0.6:.0f}" fill="{top}"/>'
                 f'<rect x="8" y="{8+H*0.6:.0f}" width="{W-16}" height="{H-16-H*0.6:.0f}" fill="{bot}"/>')
        body = "#ffffff"
    else:
        inner = (f'<rect x="10" y="10" width="{W-20}" height="{H-20}" rx="6" fill="none" '
                 f'stroke="#ffffff" stroke-opacity="0.7" stroke-width="4"/>')
        body = mix("#b4cdf0", "#4f86d4", t)
    return (z, f'<g transform="{m}" opacity="{fade:.2f}">'
               f'<rect width="{W}" height="{H}" rx="10" fill="{body}" stroke="#2f4a73" '
               f'stroke-opacity="0.25" stroke-width="2"/>{inner}</g>')

def showing_card():
    w, h = 300, 200                        # art is drawn at this size
    big, r_in = 1.071, 40                    # and shown this much larger
    bw, bh = w * big, h * big
    p = math.radians(SHOW_PHI)
    pts = [proj(math.cos(p) * r, y - bh * 0.35, math.sin(p) * r)[:2] for r, y in ((r_in, bh), (r_in + bw, bh), (r_in + bw, 0), (r_in, 0))]
    m = affine(pts, w, h)
    rays = ''.join(f'<line x1="0" y1="0" x2="{30*math.cos(a):.1f}" y2="{30*math.sin(a):.1f}" stroke="#ffb800" stroke-width="5" stroke-linecap="round"/>' for a in [k*math.pi/4 for k in range(8)])
    art = f'''
      <rect width="{w}" height="{h}" rx="14" fill="#ffffff"/>
      <clipPath id="pic"><rect x="12" y="12" width="{w-24}" height="{h-24}" rx="8"/></clipPath>
      <g clip-path="url(#pic)">
        <rect width="{w}" height="{h}" fill="url(#sky)"/>
        <rect y="145" width="{w}" height="{h}" fill="#5cc85a"/>
        <g transform="translate(58 52)">{rays}<circle r="19" fill="#ffd21f"/></g>
        <rect x="110" y="100" width="90" height="50" fill="#ffcf5a"/>
        <polygon points="100,102 155,62 210,102" fill="#e8453c"/>
        <rect x="145" y="118" width="20" height="32" fill="#7a3fa0"/>
        <rect x="120" y="110" width="18" height="16" fill="#7fd3ff" stroke="#ffffff" stroke-width="3"/>
        <rect x="241" y="108" width="11" height="42" fill="#8a5a32"/>
        <circle cx="246" cy="96" r="27" fill="#2fa84f"/>
      </g>
      <rect width="{w}" height="{h}" rx="14" fill="none" stroke="#2f4a73" stroke-opacity="0.3" stroke-width="2"/>'''
    mx = sum(x for x, _ in pts) / 4
    my = sum(y for _, y in pts) / 4
    return f'<g transform="rotate({SHOW_SPIN} {mx:.1f} {my:.1f})" filter="url(#lift)"><g transform="{m}">{art}</g></g>'

cards = [ordinary_card(-SPACING * k, k) for k in range(1, 12)]
cards.sort(key=lambda t: t[0])

svg = f'''<svg xmlns="http://www.w3.org/2000/svg" viewBox="0 0 1024 1024" width="1024" height="1024">
  <defs>
    <linearGradient id="bg" x1="0" y1="0" x2="1" y2="1">
      <stop offset="0" stop-color="#fff4b8"/><stop offset="1" stop-color="#bfe0ff"/>
    </linearGradient>
    <linearGradient id="sky" x1="0" y1="0" x2="0" y2="1">
      <stop offset="0" stop-color="#6ec6ff"/><stop offset="1" stop-color="#c9ecff"/>
    </linearGradient>
    <radialGradient id="shadow"><stop offset="0" stop-color="#2f4a73" stop-opacity="0.22"/>
      <stop offset="1" stop-color="#2f4a73" stop-opacity="0"/></radialGradient>
    <filter id="lift" x="-20%" y="-20%" width="140%" height="140%">
      <feDropShadow dx="0" dy="10" stdDeviation="12" flood-color="#2f4a73" flood-opacity="0.35"/>
    </filter>
  </defs>
  <rect x="100" y="100" width="824" height="824" rx="185" fill="url(#bg)"/>
  <ellipse cx="{CX}" cy="{CY + 150}" rx="{R + 90}" ry="{R * math.sin(TILT) + 50:.0f}" fill="url(#shadow)"/>
  {''.join(c[1] for c in cards)}
  {showing_card()}
</svg>'''
open(os.path.join(os.path.dirname(os.path.abspath(__file__)), "..", "Mockups", "ring-dozen.svg"), "w").write(svg)

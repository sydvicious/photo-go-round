import math, os
N = 12                     # a dozen cards, the house card among them
STEP = (24, -20)           # each card sits this far up and to the right of the one in front
CW, CH = 360, 240          # card size on screen
HOUSE_AT = 4               # the house card's place in the row, 0 = front (bottom left)
LIFT = 110                 # how far it is pulled up out of the row
TILT = 24                  # turned counterclockwise about its lower-left corner

def mix(a, b, t):
    ca = [int(a[i:i+2], 16) for i in (1, 3, 5)]
    cb = [int(b[i:i+2], 16) for i in (1, 3, 5)]
    return "#" + "".join(f"{round(x + (y - x) * t):02x}" for x, y in zip(ca, cb))

def base(i):               # lower-left corner of card i
    return STEP[0] * i, STEP[1] * i

def rot(px, py, ox, oy, deg):   # counterclockwise on screen
    t = math.radians(deg)
    dx, dy = px - ox, py - oy
    return ox + dx * math.cos(t) + dy * math.sin(t), oy - dx * math.sin(t) + dy * math.cos(t)

hx, hy = base(HOUSE_AT)
hy -= LIFT
house_pts = [rot(hx + u, hy + v, hx, hy, TILT) for u, v in ((0, 0), (CW, 0), (CW, -CH), (0, -CH))]
deck_pts = [(x + u, y + v) for i in range(N) for x, y in [base(i)] for u, v in ((0, 0), (CW, -CH))]
xs = [p[0] for p in deck_pts + house_pts]; ys = [p[1] for p in deck_pts + house_pts]
OX = 512 - (min(xs) + max(xs)) / 2
OY = 530 - (min(ys) + max(ys)) / 2

def back_card(i):
    x, y = base(i)
    t = i / (N - 1)                       # 0 = front, 1 = back
    return (f'<g transform="translate({x + OX:.1f} {y + OY - CH:.1f})">'
            f'<rect width="{CW}" height="{CH}" rx="16" fill="{mix("#5b8fd6", "#a9c6ee", t)}" '
            f'stroke="#2f4a73" stroke-opacity="0.35" stroke-width="2"/>'
            f'<rect x="14" y="14" width="{CW-28}" height="{CH-28}" rx="9" fill="none" stroke="#ffffff" '
            f'stroke-opacity="0.7" stroke-width="4"/></g>')

def house_card():
    w, h = 300, 200                       # art is drawn at this size
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
    x, y = hx + OX, hy + OY
    return (f'<g filter="url(#lift)" transform="rotate({-TILT} {x:.1f} {y:.1f}) '
            f'translate({x:.1f} {y - CH:.1f}) scale({CW / w:.4f} {CH / h:.4f})">{art}</g>')

layers = [back_card(i) for i in range(N - 1, HOUSE_AT, -1)] + [house_card()] + \
         [back_card(i) for i in range(HOUSE_AT - 1, -1, -1)]
svg = f'''<svg xmlns="http://www.w3.org/2000/svg" viewBox="0 0 1024 1024" width="1024" height="1024">
  <defs>
    <linearGradient id="bg" x1="0" y1="0" x2="1" y2="1">
      <stop offset="0" stop-color="#fff4b8"/><stop offset="1" stop-color="#bfe0ff"/>
    </linearGradient>
    <linearGradient id="sky" x1="0" y1="0" x2="0" y2="1">
      <stop offset="0" stop-color="#6ec6ff"/><stop offset="1" stop-color="#c9ecff"/>
    </linearGradient>
    <filter id="lift" x="-20%" y="-20%" width="140%" height="140%">
      <feDropShadow dx="0" dy="8" stdDeviation="10" flood-color="#2f4a73" flood-opacity="0.35"/>
    </filter>
  </defs>
  <rect x="100" y="100" width="824" height="824" rx="185" fill="url(#bg)"/>
  {"".join(layers)}
</svg>'''
open(os.path.join(os.path.dirname(os.path.abspath(__file__)), "..", "Mockups", "row.svg"), "w").write(svg)

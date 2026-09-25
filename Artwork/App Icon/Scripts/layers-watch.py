# Split the ring keeper into full-bleed layers for a watchOS icon.
# The watch masks the icon to a circle and shows it small, so the ring is
# scaled up to fill the circle and the house card grows more than the ring.
import math, os, re
import ring as make                            # the ring keeper's geometry

RING_SCALE = 1.15          # mockup units to watch canvas
MOCKUP_CENTER = (520, 548) # middle of the ring and house card in the mockup
HOUSE_SCALE = 1.5          # extra growth for the house card, so it reads at 16 points
HOUSE_CENTER = (640, 545)  # where the house card's middle moves to, in mockup units

cx, cy = MOCKUP_CENTER
FIT = f'transform="translate(512 512) scale({RING_SCALE}) translate({-cx} {-cy})"'
HEAD = '<svg xmlns="http://www.w3.org/2000/svg" viewBox="0 0 1024 1024" width="1024" height="1024">'
SKY = '''<linearGradient id="sky" x1="0" y1="0" x2="0" y2="1">
      <stop offset="0" stop-color="#6ec6ff"/><stop offset="1" stop-color="#c9ecff"/></linearGradient>'''

background = f'''{HEAD}
  <defs><linearGradient id="bg" x1="0" y1="0" x2="1" y2="1">
    <stop offset="0" stop-color="#fff4b8"/><stop offset="1" stop-color="#bfe0ff"/></linearGradient></defs>
  <rect width="1024" height="1024" fill="url(#bg)"/>
</svg>'''

# No shadow under the ring: Icon Composer lights every shape in a layer,
# and gives even a soft shadow a glass rim.
ring = f'''{HEAD}
  <g {FIT}>
    {"".join(c[1] for c in make.cards)}
  </g>
</svg>'''

# Icon Composer adds its own layer shadow, so the house card goes without one.
card = make.showing_card().replace(' filter="url(#lift)"', '')
mx, my = map(float, re.search(r'rotate\(\S+ (\S+) (\S+)\)', card).groups())
hx, hy = HOUSE_CENTER
house = f'''{HEAD}
  <defs>{SKY}</defs>
  <g {FIT}><g transform="translate({hx} {hy}) scale({HOUSE_SCALE}) translate({-mx:.1f} {-my:.1f})">{card}</g></g>
</svg>'''

OUT = os.path.join(os.path.dirname(os.path.abspath(__file__)), "..", "Icon Composer (Watch)")
os.makedirs(OUT, exist_ok=True)
for name, body in (("1 Background", background), ("2 Ring", ring), ("3 House Card", house)):
    open(os.path.join(OUT, f"{name}.svg"), "w").write(body)

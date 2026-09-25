# Split the ring keeper into full-bleed layers for Icon Composer.
# The mockup drew the icon inside an 824-point rounded square at (100, 100);
# Icon Composer wants the whole 1024 canvas and draws the shape itself.
import math, os
import ring as make                            # the ring keeper's geometry

S = 1024 / 824
FIT = f'transform="translate({-100 * S:.2f} {-100 * S:.2f}) scale({S:.5f})"'
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
house = f'''{HEAD}
  <defs>{SKY}</defs>
  <g {FIT}>{make.showing_card().replace(' filter="url(#lift)"', '')}</g>
</svg>'''

OUT = os.path.join(os.path.dirname(os.path.abspath(__file__)), "..", "Icon Composer")
for name, body in (("1 Background", background), ("2 Ring", ring), ("3 House Card", house)):
    open(os.path.join(OUT, f"{name}.svg"), "w").write(body)

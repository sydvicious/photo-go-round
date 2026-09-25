# App Icon

## The idea

Many, many cards arranged in a circular deck — about 40 besides the house card.
Tried 60; 40 is better. The cards are on their sides,
with one edge near the center of the circle and one on the outside.

- **The showing card** is on the right-hand side: a cartoon picture of a house
  with a tree and the sun, in bright colors. It lies flat to the viewer, tipped
  so its right corner is lower than its left.
  The cartoon style is deliberate: it says your own pictures will be better.
  Its colors differ in lightness as well as hue — dark roof and tree, light
  walls and grass — so it still reads in red-green color blindness. Its shapes
  are bold, with no small details (no window; a big sun with thick rays; a big
  tree), so it is discernible at 32 points. 16 points is hopeless whatever the
  design, and a `.icon` file has no per-size artwork to fix it with.
  A thin navy edge (`#2f4a73`) sets the card apart from the pale yellow, where
  its white border alone vanishes. Navy, not black: black reads as a sticker.
- **The rest of the deck** wraps around the circle from there, in mixed
  colors: coral, amber, teal, violet and pink, paler toward the back. Not
  another solid blue icon. Coral, violet and white prints were also tried.
- **A gap** sits in front of the showing picture, toward the viewer, so nothing
  blocks it. At its present size the house card covers most of the gap. Moving
  it right to uncover the gap was tried; the current layout pops, so it stays.
- **The background** is a gradient from light yellow to light blue.

## Variation: a pile

Same background and color scheme. The house picture is sitting on a pile of
cards, and we are looking at it from above at about 45 degrees.

Rejected on 2026-09-24: a pile does not indicate rotation. The ring does.

## Variation: a row

A bunch of cards going from bottom left to upper right, tightly packed. The
house picture is tilted up out of the pile so you can see what it is, but its
lower-left corner is still in the deck.

Viable, 2026-09-24, once the house card sat lower in the row.

## Artwork

`Artwork/App Icon/Scripts/` is the source, and the only part committed. Each
script writes generated SVGs beside it, which are not committed:
`python3 Scripts/ring.py` (and `ring-dozen.py`, `row.py`) write `Mockups/`;
`layers.py` writes `Icon Composer/`, the ring split into full-bleed layers;
`layers-watch.py` writes `Icon Composer (Watch)/`, the same layers enlarged for
the watch's circle, with the house card grown more than the ring.

The icon uses the watch layers. After regenerating them, copy `2 Ring.svg` and
`3 House Card.svg` into `Artwork/PhotosGoRound.icon/Assets/`, where the ring is
named `2 Ring 2.svg`.

## The icon file

`Artwork/PhotosGoRound.icon`, made in Icon Composer from the watch layers. One
file for every platform: the enlarged design is used on the Mac as well as the
watch. The fill is Icon Composer's own gradient, brighter than the mockups —
about `#FFFC78` to `#76D6FF`, chosen on purpose.

It is the Photos-Go-Round app target's icon: a resource of that target, with
`ASSETCATALOG_COMPILER_APPICON_NAME = PhotosGoRound` in all three
configurations. The agent and the Wallpaper Host have no icon of their own.

## The wallpaper pane's picture

The wallpaper extension's item in System Settings shows the icon's ring and
house card on the icon's fill, with no icon frame, filling the picture to a
40-pixel margin: `MacOS/Wallpaper/Sources/PaneThumbnail.png`, 1920 × 1080, also
the desktop's picture before the first photograph arrives. It is drawn ahead of
time and committed — Syd, 2026-09-24: "could we predraw that image and store the
static asset?" — because the sandboxed extension may not read the icon from the
app it is inside (`deny(1) file-read-data`, measured the same day). Redraw it
whenever the icon changes: `swift "Artwork/App Icon/Scripts/pane-thumbnail.swift"`
from the repository root. It draws the layers inside `PhotosGoRound.icon`
itself, so it follows any change to them. Syd: "What I really want is the ring
and photo on the gradient, but without the icon frame."

The Screen Saver pane shows the same picture as the saver's tile, drawn at the
tile's two sizes by the same script — `MacOS/Screensaver/Sources/thumbnail.png`,
107 × 65, and `thumbnail@2x.png`, 214 × 130, the sizes Apple's own savers carry.
Syd, 2026-09-24: "you can reuse the wallpaper icon we already generated." Redraw
them with the wallpaper's whenever the icon changes:

```bash
swift "Artwork/App Icon/Scripts/pane-thumbnail.swift" 107 65 MacOS/Screensaver/Sources/thumbnail.png
swift "Artwork/App Icon/Scripts/pane-thumbnail.swift" 214 130 "MacOS/Screensaver/Sources/thumbnail@2x.png"
```

How the pane finds the picture, the cache that hides a new one until it is
removed, and why only the Release saver can show it are in
`Screensaver Plan.md`, *The tile in the Screen Saver pane*.

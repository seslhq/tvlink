# Brand

## Logo

Files are in [brand/](brand/).

| File | Use |
| --- | --- |
| `mark.svg` | The symbol alone: avatars, favicons, small spaces |
| `lockup.svg` | Mark and name, dark ink, for light backgrounds |
| `lockup-white.svg` | Mark and name, light ink, for dark backgrounds (the TV splash) |
| `hero.svg` | Landing graphic, 1280x640; also the repo's social preview |

- The mark is a screen outline with a dot in its bottom-right corner, where tvlink draws its status badge. The dot
  says the screen is live.
- The wordmark is drawn as strokes, not typed, so it renders the same everywhere with no font installed.
- Keep clear space of twice the dot's diameter; the mark is at least 24 px wide, the lockup 120 px.
- Don't stretch, rotate, outline, shadow or recolour it, or rebuild the wordmark in a font.

## Colour

| Token | Hex | Use |
| --- | --- | --- |
| Ink | `#0E1116` | Backgrounds on screens, the logo on light backgrounds |
| Paper | `#F4F6F8` | Text and the logo on dark backgrounds |
| Muted | `#9AA4B2` | Secondary text |
| Live | `#2FD07A` | The dot when the screen is live, and nothing else |
| Warn | `#F5A524` | Setup, waiting, cached, not found, unplayable files |
| Fault | `#F04438` | No network, offline |

The dot's colour is status, never decoration. Type is the system sans (DejaVu Sans on Raspberry Pi OS): no bundled
fonts.

## Trademarks

The tvlink name and the logos in [brand/](brand/) are trademarks of cpwillis. The files are under Apache-2.0 like the
rest of the repo; the licence grants no trademark rights (its section 6).

- Fine without asking: saying what something is, eg "based on tvlink", "works with tvlink", "forked from
  github.com/seslhq/tvlink"; running and sharing unmodified copies with the original splash.
- Ask first (open an issue): naming a fork, product, service, domain or device image tvlink or anything confusingly
  close; using the marks or a changed version of them; anything that suggests endorsement.
- A fork that is passed on: rename it, replace the logo and the splash branding, and keep [NOTICE](../NOTICE).

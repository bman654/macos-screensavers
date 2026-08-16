# Screensaver backlog

Ideas beyond the aquarium, with the analysis behind their ordering. Nothing here is
started. The aquarium (`aquarium-plan.md`) is the active track.

## The architectural point that drives all of this

Roughly eight of the candidate visuals are the same program with different maths:

```
state texture(s) → local update kernel → palette / colour pass
```

That is **one Metal pipeline and N small kernels**, not N screensavers. It is also the
same full-screen shader host the space-scene idea needs. So building a raw Metal
full-screen host once unlocks most of this list, entirely independently of the
aquarium's SceneKit + baked-asset track.

This is why `Shared/SaverKit` must expose **both** a SceneKit host and a raw Metal
full-screen host from the start.

## Ordering

| Idea | Effort | Why |
|---|---|---|
| Field simulations (collection) | Lowest | Art direction already done and tuned; one shared pipeline |
| Space scenes | Low | Same host. Pure shader maths, no models, no bake step |
| Space battle | Medium | Sprite sheets from Blender; real work is the combat sim |
| Isometric city | High | Road generation, traffic pathfinding, weather, disasters, growth/reset |

The reason field sims rank first: the expensive part of a generative visual is art
direction — palettes, parameter regimes, and lifecycle tuning so it never settles into
something boring. In the creative-space pieces that work is already done and validated.
Porting a 400-line kernel is the cheap part.

A single "collection" saver cycling through several of these amortizes the `.saver`
shell across many visuals.

## 1. Space battle (overhead)

Reference: `references/weird-worlds-space-battle.png` (Weird Worlds: Return to Infinite
Space main menu).

Ships stream in from off-screen as others die. Many hull types, varied weapons — missiles,
lasers of different colours and thicknesses, gravity guns.

Reading the reference: ships are small, chunky, stylised, readable at ~60px. The visual
weight is carried by **effects**, not models — thin coloured beams spanning the screen,
missiles with smoke trails, additive explosion bursts, nebula backdrop. Nobody inspects
hull panel lines.

**Therefore: pre-rendered sprite sheets from Blender, not runtime 3D.** Render each ship
at N rotations once; the runtime is a 2D compositor. Matches the reference aesthetic
better than clean 3D would, and sidesteps runtime 3D entirely. Good test of whether
`saverlib` generalizes past fish — a ship hull is a lofted body.

## 2. Space scenes

Cycle through randomly generated scenes: close-ups of various star types; solar systems
with time sped up so orbits are visible; binaries ranging to neutron stars and black
holes accreting from a companion; two black holes spinning close; nebulae; supernovae;
planets with varied atmospheres, oceans, landmasses, cloud decks, gas giants; asteroid
strikes.

Almost entirely shader work. Nebulae, star surfaces and gas giants are fBm noise;
orbital mechanics is trivial; black hole lensing has well-known cheap approximations.
Naturally incremental — one star shader is already a shippable saver, and each new scene
type adds variety with no content pipeline. Watch GPU cost on volumetric nebulae and
lensing.

## 3. Ports from creative-space

Source: `~/dev/general/creative-space` (489 pieces, mapped by its `INDEX.md`).

**These cannot be wrapped — WebKit is dead inside a screensaver on macOS 26.** Every one
must be reimplemented natively. Most also need their entrance gates and UI chrome
removed; several gate on a click before animating.

> **The shortlist below is not settled. Brandon wants to choose the list together before
> any porting starts.** Treat it as survey output, not a decision.

### Named specifically

| Piece | Path | Tech | Notes |
|---|---|---|---|
| **Lattice** | `sound-garden/lattice.html` | Canvas2D + Web Audio, ~1000 ln | See `references/lattice.png` |
| **Particle Life** | `strange-garden/pieces/particle-life.html` | Canvas2D | See `references/particle-life.png` |
| Orrery | `orrery/index.html` | Canvas2D, ~1333 ln | Keplerian solar system |

**Lattice** (from the screenshot): a 16×14 grid of faint teal dots on near-black, with a
bright cyan vertical playhead sweeping left to right. Cells bloom into large soft white
and cyan halos as they fire, each throwing expanding concentric ripple rings. Very
striking, and it reads beautifully with sound disabled — as a screensaver it needs only
the grid, playhead, seeded pattern evolution, bloom and ripples. One of the easiest
polished ports here.

**Particle Life** (from the screenshot): ~2000 small particles in 7 colours on black,
each colour attracting and repelling the others by its own random rule set. Cells,
chasers, worms and membranes emerge — dotted clusters, chains, and orbiting shells, with
motion trails. Classic particle-life; an ideal Metal compute workload and endlessly
watchable. Needs periodic rule reseeding so it never settles.

**Orrery**: Keplerian orbital elements from JPL, Newton-solved, with brass / blueprint /
observatory visual treatments. Calm and precise rather than cinematic. The hard part of
this port is the typography and engraved styling, not the simulation.

### Other autonomous candidates from the survey

Strange Attractors (`strange-garden/pieces/strange-attractors.html`, ~553 ln, Canvas2D) —
Clifford/De Jong maps accumulated into a density buffer with log scaling and slow
parameter morphing. Probably the strongest pure-ambient candidate.

Lenia (`.../lenia.html`, ~552 ln, WebGL2) — continuous cellular automaton; gliding
amoeba-like organisms with a deliberate sparse→collision→bloom→reseed lifecycle.
Ping-pong float textures map directly to Metal compute.

Reaction–Diffusion (`.../reaction-diffusion.html`, ~396 ln) — Gray-Scott; coral, mitosis,
worms, maze, spots regimes.

Belousov–Zhabotinsky (`.../bz-reaction.html`, ~317 ln) — chemical clock, spiral waves.
Computationally simpler than Lenia and still visually rich.

Physarum (`.../physarum.html`, ~403 ln) — 120k slime-mould agents depositing and sensing
trails. Expensive in JS, ideal in Metal compute. Branching vein networks.

Also noted: Chladni (~377 ln), Metaballs (~467 ln, WebGL2), Flow Field (~381 ln),
Kaleidoscope (~1778 ln), Boids (~380 ln), Iridescence (~2569 ln, use soap/oil mode — the
default Newton mode is static).

### The existing web aquarium

`the-aquarium/index.html` — 3047 lines of WebGL2 with instanced reef geometry, caustic
ray splatting into a float texture, bloom, and procedural vertex-displacement fish. This
is the piece whose fish-model quality prompted this whole project. Same swim technique as
the SceneKit modifier in spike 001. Useful as a reference for the tank look and the
caustic approach; not portable as-is.

## 4. Isometric city

SimCity-style isometric city: cars on roads, weather, day/night cycle, buildings catching
fire, emergency vehicles responding, floods, earthquakes, alien invasions, plus rainbows
after storms, fireworks, carnivals. City grows over time, then resets.

Largest by a wide margin — every clause is its own subsystem with its own assets and
logic. Recommend last, scoped hard: a v1 of isometric city + traffic + day/night is
already substantial, and the event catalogue is where it becomes open-ended.

Screensaver-specific constraint that bites this one hardest: it must start instantly. A
city that takes seconds to generate a world is bad screensaver behaviour, so generation
needs to be progressive or pre-seeded. Multi-display also matters — each screen gets its
own instance, and a shared world across displays is much harder than independent ones.

## Constraints that apply to everything here

- **Battery and GPU cost.** These run on a laptop, often unplugged. Cap frame rate and
  ease off on battery.
- **`legacyScreenSaver` crashes mean a black screen.** Heavier savers are riskier. Keep
  state small and fail soft.
- **The preview thumbnail is tiny.** The visual has to still read at that size.

## Ambient audio

Wanted, and settled in direction if not in mechanism: **ambient sound only, toggleable,
defaulting to off.** The aquarium gets a low bubbling bed. Other savers may borrow the hum
from the orrery estate's living calendar — "the air" — which lives outside this repo, so
whoever implements it should ask for the source rather than invent one.

Default-off is not timidity. A screensaver starts *because* the user walked away, so
unrequested sound plays to an empty room, or into a meeting they just walked into, or at
2am. Opted-in ambience is charming; the same audio uninvited is why people uninstall
screensavers.

**Proven, and the mechanism is settled — see `spikes/006-saver-audio/README.md`.** Audio does
reach the output device from inside the sandboxed `legacyScreenSaver`, confirmed by ear on the
installed build. The three hazards below were all real, and two of them had causes that could
not have been reasoned out; read the spike before writing any of this.

The one rule it produced: **gate audio on the screensaver session, never on the view.** No
property of a saver view distinguishes the real screensaver from the picker's thumbnail — the
tile is a *full-screen* view with `isPreview == false`, and an abandoned view goes on rendering
at 60 fps forever. `com.apple.screensaver.didstart` / `willstop` / `didstop` are the signal,
registered `.deliverImmediately`, seeded at startup because `didstart` is posted before the host
process exists.

Hazards, now measured rather than guessed:

- **One instance per display.** Confirmed within a process — three instances play three voices
  — and a `static` owner fixes it there. Across processes it is unfixed and untested: the picker
  alone spawns two hosts. Two real displays remain untested on this machine, which mirrors.
- **The System Settings thumbnail plays**, and no size test prevents it. This is also a
  *rendering* bug for every saver: `HostContext.isPreview` is false for that tile, so the
  aquarium has been drawing full-fat tanks into a two-inch thumbnail. Its own item, below.
- **The login window runs savers too**, still untested, and now the most likely thing to differ
  since the audio gate depends on a distributed notification posted in a session context.
- **Every asset ships in the bundle**, since the saver is sandboxed with no network. A loop
  long enough not to feel repetitive is real bundle weight; the model library is already
  ~35 MB. The spike's recommendation is to bake short grains and schedule them stochastically
  rather than ship a loop — a bubble is a Minnaert resonator whose frequency follows its radius
  alone, so an aquarium bed is genuinely parametric in the way this repo's models are.

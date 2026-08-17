"""How the baked grains are played — the numbers, in one place, for two readers.

There is no loop in this saver's audio. A bubble bed that repeats is worse than no bed at
all, because a screensaver runs for hours and the ear finds a period of any length; so the
bed is *scheduled* from the grain library at runtime, and what makes it a bed rather than a
sample is this file.

**These numbers are baked into the manifest that ships beside the grains**, and the saver
reads them from there. That is deliberate: `tools/audio-preview.py` renders a minute of the
finished soundscape to a WAV that can be played with `afplay` before anything is built or
installed, and a preview that used different numbers from the saver would be a lie. The two
readers share the manifest so that the loop stays the one this repo already has — edit the
script, render, *listen*, adjust the numbers.
"""

from __future__ import annotations

# --- The bed -----------------------------------------------------------------------

#: Audible bubbles per second, as a fraction of an emitter's declared particle rate.
#:
#: The sound follows the picture rather than running beside it. Every bubble emitter in the
#: library already declares a birth rate — 7 a second for the clamshell, 24 for the thermal
#: vent, 55 for the treasure chest — and `Bubbler` already knows which of them are emitting
#: this instant, so the bed's density is a property of the tank that was actually drawn.
#:
#: The fraction is well under one because most of what an aerator releases is inaudible: a
#: bubble under half a millimetre rings above 6.5 kHz, where `water.submerged` removes it
#: entirely. What reaches a submerged listener is the coarse tail of the distribution, and
#: that arrives at a rate a person could almost count.
RATE_SCALE = 0.34

#: Ceiling on the summed rate, whatever the tank draws.
#:
#: A layout with three emitters running at once would otherwise ask for a hundred bubbles a
#: second, which is not a bed — it is white noise with a tank reverb on it, and it costs
#: forty simultaneous voices to produce.
MAX_RATE = 26.0

#: Bubbles per second the rest of the time.
#:
#: The bubbler props idle for eleven to twenty-six seconds between bursts, and a tank that
#: falls completely silent for twenty seconds reads as broken rather than as calm. Gas
#: works loose from gravel and from the backs of leaves continuously in a real tank, so a
#: slow trickle is both true and necessary.
IDLE_RATE = 1.1

#: Radius distribution, log-normal, in millimetres. Median 1.2 mm rings at 2.7 kHz.
#:
#: Log-normal because bubble-size distributions from a porous stone are, and because the
#: long tail is what supplies the occasional low blorp that stops a bed sounding like rice
#: on a drum. Clamped to what the library can cover by resampling.
RADIUS_MEDIAN = 1.2
RADIUS_SIGMA = 0.62
RADIUS_MIN = 0.38
RADIUS_MAX = 5.60

#: Fraction of bed events that are a baked train rather than a single bubble.
BURST_SHARE = 0.14

#: Peak gain applied to a bubble grain, before its own size-dependent level.
BUBBLE_GAIN = 0.55

# --- The water underneath ----------------------------------------------------------
#
# **Nothing, now.** There used to be a continuous layer of tilted brown noise here, on the
# reasoning that bubbles arriving into digital silence sound like samples being triggered
# and a moving floor would turn them into events happening somewhere.
#
# It did, and it also produced the other half of what the user described as "a steady
# background hum or bass bed... I don't know what that's supposed to represent, but it's
# kind of irritating". Which is a fair question, and the honest answer was: nothing. A real
# aquarium's continuous component is the *plume*, and the plume is not stationary — it is
# made of arrivals, and it stops when the aerator stops. A stationary layer underneath it
# is a synthesiser pad, and an hour of one is exactly the thing a screensaver must not do.
#
# Kept as a knob at zero rather than deleted, because the diagnosis was specific: the hum
# was a *fixed-frequency* floor. If a bed of pure arrivals ever proves too sparse, the thing
# to add back is more arrivals, not a pad.
WATER_LOW = 175.0
WATER_HIGH = 700.0
WATER_GAIN = 0.0
WATER_LFO_HZ = 0.037
WATER_LFO_DEPTH = 0.45

# --- The fish ----------------------------------------------------------------------

#: A fish must be working this much harder than its cruise speed before it is heard at all.
#:
#: `effort` in `School.simulate` is speed over cruise speed. Cruising is silent, and that is
#: the point: a tank in which every fish is audible all the time is a tank of noise, and the
#: sound has nothing left to say when one of them bolts.
SWISH_MIN_EFFORT = 1.35

#: How hard a turn has to be, as a fraction of the lateral acceleration this fish makes at
#: cruise speed turning at its own maximum rate.
#:
#: Effort alone will not do, and measuring is what showed it: of the seven behaviours in
#: `FishDecision` only `dart` asks for more than 1.15 times cruise speed, so any effort
#: threshold in the usable range means "darts only" — and darts are deliberately rare, four
#: entries in a hundred and fifty seconds across a whole school. Measured on the built saver,
#: that gave two swishes in eighty seconds, which is a feature nobody would ever notice.
#:
#: Turning is the same physics: a fish comes round by pushing water sideways with its body, and
#: that push is a tail stroke. But *yaw rate* alone is the wrong measure of it — tried, and it
#: saturated at fifty-three swishes in ninety seconds with more than half refused by the tank
#: cooldown, which means the cooldown had become the rate rather than the fish. A hovering fish
#: pivoting on its pectorals comes round fast and moves almost no water.
#:
#: Speed times yaw rate is the lateral acceleration, which is what actually displaces water, and
#: it selects for what a listener would notice for free: it is large only when the animal is
#: both moving and turning.
TURN_SHARE = 1.05

#: Seconds one fish must wait before it may be heard again, and seconds any fish must.
#:
#: The per-tank floor is the load-bearing one. Ten fish each entitled to a swish every two
#: seconds is five swishes a second, which is a shoal of whispers rather than a tank.
SWISH_FISH_COOLDOWN = 5.0
SWISH_TANK_COOLDOWN = 1.6

#: Peak gain for a stroke and for a bolt.
#:
#: `SWISH_GAIN` is very nearly unreachable now and is kept rather than removed: the gesture is
#: gated on the fish actually darting (see `docs/tank-sound.md` §"The fish"), so `dart` is what
#: plays. A fish that crosses into strain during the first frames of a dart, before its speed
#: has built, still takes the stroke.
SWISH_GAIN = 0.30
DART_GAIN = 0.52

#: Rate limits on the size resample. A 7 cm cardinalfish asks for 1.7x and a 1.5 m moray
#: for 0.37x; the low end stretches the baked tank reverb into a cave, so the ask is
#: clamped and the remaining size difference is carried by gain instead.
SWISH_RATE_MIN = 0.62
SWISH_RATE_MAX = 1.55

# --- The props letting go ------------------------------------------------------------

#: Peak gain for an aerator release.
#:
#: Louder than a fish stroke, and that is the feature rather than a mix accident. The user's
#: verdict on the first build with sound was that the bed was "fairly steady" and that
#: nothing was tied to what could be seen — so a puff has to be recognisable *over* the bed
#: it arrives on top of, or it is another density change and changes nothing.
PUFF_GAIN = 0.66

#: Which baked size a release plays, chosen by the emitter's declared birth rate.
#:
#: The rate is what the picture is doing — 7 particles a second for a clamshell, 24 for a
#: thermal vent, 55 for a treasure chest — so the chest's release is the big one and the
#: clam's is the small one, without anything having to be authored per prop.
PUFF_RATE_SMALL = 12.0
PUFF_RATE_LARGE = 40.0

#: Rate limits on the size resample, as everywhere else here: the tank's response is baked
#: into the grain and stretching it too far turns the tank into a cave.
PUFF_RATE_MIN = 0.78
PUFF_RATE_MAX = 1.30

#: Seconds a single emitter must wait before it may be heard again.
#:
#: A prop's cycle idles for eleven to twenty-six seconds between releases, so this never
#: binds in normal play. It exists for `AQUARIUM_BUBBLER_RUSH=1`, which collapses the idle
#: phases to 0.18 s, and for a malformed cycle — neither should be able to machine-gun it.
PUFF_COOLDOWN = 4.0

# --- Placement and level -----------------------------------------------------------

#: How far a sound may be moved off centre, as a fraction of full pan.
#:
#: Small, and it is a physical statement rather than a taste. Sound travels at 1480 m/s in
#: water, so the interaural delay across a head is about 40 microseconds and the head casts
#: almost no shadow — a submerged listener localises very poorly. A hard pan is an air cue,
#: and using one would undo the work `water.py` does.
PAN_WIDTH = 0.40

#: Master gain, and the fade the session gate rides.
#:
#: Quiet on purpose. This plays when nobody asked for it in a room nobody is in; the
#: failure mode to avoid is not "too subtle", it is "audible from the next room at 2 am".
MASTER_GAIN = 0.62
#: Seconds. The audio spike measured `AVAudioEngine.start()` at 470 ms, so the engine runs
#: continuously and this ramp is the gate — and a slow fade in is also simply what ambience
#: should do rather than appearing.
FADE_IN = 3.5
FADE_OUT = 0.8


def manifest() -> dict:
    """The subset the saver and the preview both read, as plain JSON."""
    return {
        "bed": {
            "rateScale": RATE_SCALE,
            "maxRate": MAX_RATE,
            "idleRate": IDLE_RATE,
            "radiusMedian": RADIUS_MEDIAN,
            "radiusSigma": RADIUS_SIGMA,
            "radiusMin": RADIUS_MIN,
            "radiusMax": RADIUS_MAX,
            "burstShare": BURST_SHARE,
            "bubbleGain": BUBBLE_GAIN,
        },
        "water": {
            "low": WATER_LOW,
            "high": WATER_HIGH,
            "gain": WATER_GAIN,
            "lfoHz": WATER_LFO_HZ,
            "lfoDepth": WATER_LFO_DEPTH,
        },
        "fish": {
            "minEffort": SWISH_MIN_EFFORT,
            "turnShare": TURN_SHARE,
            "fishCooldown": SWISH_FISH_COOLDOWN,
            "tankCooldown": SWISH_TANK_COOLDOWN,
            "swishGain": SWISH_GAIN,
            "dartGain": DART_GAIN,
            "rateMin": SWISH_RATE_MIN,
            "rateMax": SWISH_RATE_MAX,
        },
        "puff": {
            "gain": PUFF_GAIN,
            "rateSmall": PUFF_RATE_SMALL,
            "rateLarge": PUFF_RATE_LARGE,
            "rateMin": PUFF_RATE_MIN,
            "rateMax": PUFF_RATE_MAX,
            "cooldown": PUFF_COOLDOWN,
        },
        "mix": {
            "panWidth": PAN_WIDTH,
            "masterGain": MASTER_GAIN,
            "fadeIn": FADE_IN,
            "fadeOut": FADE_OUT,
        },
    }

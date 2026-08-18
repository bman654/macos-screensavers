# Spike 010 — what a SceneKit geometry modifier's custom-argument block will actually take

**Question:** the eel's spine needs an *array* of sixteen points inside a
`shaderModifiers[.geometry]`. Can a shader modifier declare one? If not, how much can the
custom-argument block hold before it stops working?

**Answer:** no array of any kind, and the block breaks silently somewhere past 256 bytes. So the
spine is packed three floats to a sample through the columns of three `float4x4`s — 240 bytes
all in — which is why `SwimDeformation` looks the way it does.

Every failure below is **silent**: nothing is logged, no shader compiles with a diagnostic, no
API returns an error. The only signal is what the tank looks like.

Measured on macOS 26.5.1 on this machine, 2026-08-17, against the shipping aquarium.

## Reproduce

`probe.py` patches one probe into the real modifier and `School.makeFish`, so that what is
measured is how SceneKit binds an actual fish material rather than a standalone scene — the
material-to-material difference below is the finding, and a purpose-built probe material would
not show it. It snapshots the two files it edits on first use.

```bash
for probe in array helper six eight; do
    spikes/010-shader-uniform-block/probe.py "$probe"
    tools/build-saver.sh Aquarium
    AQUARIUM_STYLE=aquarium AQUARIUM_SEED=4 tools/run-saver.swift Aquarium \
        --size 1600x900 --seconds 18 --screenshot "/tmp/probe-$probe.png"
done
spikes/010-shader-uniform-block/probe.py restore
```

Seed 4 because it is the only aquarium seed in 1–26 that draws the moray, and the moray's
material is the one that fails first. `output/probes.png` is the four results, in that order.

## The block, byte by byte

`swimModifierSource` declares eleven floats and then the matrices. Floats are 4-byte aligned
and a `float4x4` is 16-byte aligned, so the eleven floats occupy 0–43 and the matrices start at
48:

| matrices declared | block size | shipping? |
| ---: | ---: | --- |
| 3 | 240 B | yes — 16 B of headroom |
| 6 | 432 B | fourth matrix at 240–303 |
| 8 | 560 B | — |

## What fails

- **An array argument does not compile.** `float probeArray[4];` in `#pragma arguments`, read
  once in the body, turns **every fish in the tank magenta**. This is SceneKit's shader-compile
  failure colour and it is the only notice given. Previously tried and equally refused in the
  session this spike documents: `float3`/`float4` arrays and passing the run as `NSData`.
- **A helper function between the pragmas does not compile either.** A one-line
  `float3 probeHelper(float4 c) { return c.xyz; }` declared after `#pragma arguments` produces
  the same whole-school magenta. That is why the sample unpack in `SwimDeformation` is spelled
  out inline rather than factored into a function.
- **Past 256 bytes the block is read wrongly, and only some materials are affected.** With six
  matrices declared, all three extra ones written as *all-zero* matrices from Swift, and the
  fourth (bytes 240–303) read and added to the vertex position, a correct read is a no-op. It is
  not one: **the moray collapses to a thin sliver** while every other fish in the tank is
  untouched, correctly shaded and correctly positioned. The eel is the fish whose spine
  arguments are actually written, so it is the material whose block is fullest in practice.
- **With eight matrices the eel is gone entirely and other materials are damaged too.** No
  moray anywhere in frame, the tang's fin material renders **black**, and the clownfish loses
  its orange — so at 560 bytes the surface appearance goes wrong as well as the geometry, not
  only the vertex stage.

Both size failures are deterministic across runs on the same seed.

## What holds

- **`float4x4` is a working transport for bulk floats.** `NSValue(scnMatrix4: SCNMatrix4(m))`
  binds, `mat[i]` is **column i**, and both the column and the component may be indexed with a
  dynamic integer inside the modifier. Sixteen floats per argument is the widest channel
  available, and three of them is 48 floats — exactly the sixteen three-component samples the
  spine needs.
- **Three matrices are fine.** The shipping build renders the eel correctly on every run in this
  session, so 240 bytes is proven and 256 is the number to stay under.

## Traps

- **Do not read the headroom as "16 more bytes are safe".** The argument that read wrongly at
  six matrices *straddles* byte 256 (240–303); nothing here proves an argument that ends exactly
  at 256 is bound correctly. Treat the whole block, not any one argument, as the thing that must
  stay under.
- **A magenta fish and a vanished fish are different failures.** Magenta is the modifier failing
  to compile — an array, a helper function, a syntax error. A fish that renders as a sliver or
  not at all with a modifier that plainly compiled is the argument block, and the two want
  opposite investigations.
- **Test with the eel in frame.** Every size failure here showed on the moray's material first
  and on nothing else, and a probe scene without a lurker would have reported the 432-byte block
  as working.

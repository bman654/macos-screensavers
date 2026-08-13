// The school: a mixed assortment of species drawn from the library, each at the size its
// manifest says it is and in the depth band its manifest asks for.
//
// Everything here about how one fish moves came out of the shell proof and is unchanged; what
// is new is that there are several species in the water at once, and that the sand is now a
// surface a fish can be placed below by accident.

import Foundation
import SceneKit
import simd

// MARK: - Swim deformation

/// A travelling sine wave down the body, applied in the vertex stage.
///
/// Proven in `spikes/001-fish-pipeline`. It works in the mesh's own object space, which is
/// only valid because the fish is exported as a single joined mesh — reaching for world
/// space via `u_modelTransform` inside a geometry modifier produces shredded geometry and a
/// magenta surface, with no diagnostic. The `tailward²` envelope holds the head steady; a
/// fish that translates bodily side to side reads as a bar of soap.
private let swimModifier = """
#pragma arguments
float swimPhase;
float swimAmplitude;
float swimWaves;
float bodyMinX;
float bodyLength;

#pragma body
float tailward = clamp((bodyMinX + bodyLength - _geometry.position.x) / bodyLength, 0.0, 1.0);
float envelope = tailward * tailward;
_geometry.position.y += sin(tailward * swimWaves * 6.2831853 - swimPhase)
                      * swimAmplitude * envelope;
"""

// MARK: - One fish

private final class Fish {
    let node: SCNNode
    /// Held directly because the swim phase is a material uniform, and walking the hierarchy
    /// to find them again every frame would be the most expensive thing in the update.
    let materials: [SCNMaterial]
    /// World length, from the species manifest. Every margin this fish is judged by is its own
    /// size — a 6 cm gramma and a 30 cm moray cannot share one constant.
    let length: Float
    /// Fractions of the tank's depth range, from the manifest, so a species stays in the water
    /// it was written for.
    let depthBand: Span

    var position = SIMD3<Float>(repeating: 0)
    var velocity = SIMD3<Float>(repeating: 0)
    var beat: Float = 1.5
    var phaseOffset: Float = 0
    var bobRate: Float = 0.3
    var bobPhase: Float = 0
    var bobAmplitude: Float = 0

    init(node: SCNNode, materials: [SCNMaterial], length: Float, depthBand: Span) {
        self.node = node
        self.materials = materials
        self.length = length
        self.depthBand = depthBand
    }
}

// MARK: - The school

final class School {
    /// One parent for every fish, so the scene root stays readable in a debugger and the
    /// school can be hidden in one move.
    let node = SCNNode()

    private var fishes: [Fish] = []
    private var rand: Rand
    private var aspect: Float

    /// Draws species until the tank is stocked, then a school of each.
    ///
    /// Species are drawn without replacement: two schools of the same fish is the one outcome
    /// that makes a "mixed" school look like a bug rather than a choice.
    init(library: ModelLibrary, cache: ModelCache, count: Int, aspect: Float, rand: inout Rand) {
        self.rand = rand.fork()
        self.aspect = aspect

        var pool = library.fish
        var spawned = 0
        while spawned < count, !pool.isEmpty {
            guard let index = self.rand.weightedIndex(pool, weight: { $0.fish?.weight ?? 1 }),
                  let spec = pool[index].fish
            else { break }
            let manifest = pool.remove(at: index)
            guard let model = cache.model(named: manifest.asset), model.length > 0 else { continue }

            let wanted = Int(spec.school.sample(&self.rand).rounded())
            let size = max(1, min(count - spawned, wanted))
            for member in 0..<size {
                let fish = makeFish(from: model, spec: spec)
                // Depth spread within this species' own band, width spread across the whole
                // frame: left to chance, a school of a dozen routinely clumps into one corner
                // and leaves half the tank empty — and the first seconds after the screen
                // blanks are the ones that get looked at.
                place(fish, spawningOffScreen: false,
                      stratum: (Float(member) + 0.5) / Float(size), spreadIndex: spawned + member)
                // Spread the tail beats so a school of clones does not pulse in unison.
                fish.phaseOffset = Float(member) / Float(size) * 2 * .pi
                fishes.append(fish)
                node.addChildNode(fish.node)
            }
            spawned += size
        }
    }

    // MARK: Per-frame update

    func update(time: CFTimeInterval, dt: Float) {
        for fish in fishes {
            fish.position += fish.velocity * dt
            if hasLeftTank(fish) { place(fish, spawningOffScreen: true) }

            let bob = sin(School.wrappedPhase(time, rate: fish.bobRate, offset: fish.bobPhase))
                * fish.bobAmplitude
            fish.node.position = SCNVector3(fish.position.x,
                                            fish.position.y + bob,
                                            fish.position.z)

            let phase = School.wrappedPhase(time, rate: fish.beat * 2 * .pi,
                                            offset: fish.phaseOffset)
            for material in fish.materials {
                material.setValue(NSNumber(value: phase), forKey: "swimPhase")
            }

            // The wave displaces the body laterally, which for a fish swimming across the
            // frame is almost straight into the camera and therefore nearly invisible. Real
            // fish also yaw their heads in recoil against the tail; borrowing that here is
            // what makes the deformation read from the front-on view of the tank.
            let recoil = 0.10 * sin(phase)
            fish.node.eulerAngles = SCNVector3(0, headingYaw(of: fish.velocity) + recoil, 0)
        }
    }

    /// Evaluates `time * rate + offset` in `Double` and reduces it into one period before it
    /// is narrowed to the `Float` the sine and the material uniform carry.
    ///
    /// A screensaver on an unattended machine runs for days, and an ever-growing `Float` clock
    /// loses timing resolution as it does: at 48 hours its ULP is already 1/64 s, so the
    /// fastest tail beats start advancing in visibly uneven steps, and by a week barely a
    /// quarter of the frames at 60 Hz land on a distinct value — the school stutters. Wrapping
    /// after the conversion cannot recover precision the conversion already discarded, so the
    /// reduction has to happen here, in `Double`. It is seamless because a phase is periodic:
    /// every consumer of this value is a sine, for which 2π is an exact period.
    ///
    /// Per fish rather than once for the whole school: the beats are unrelated reals, so there
    /// is no shared time period that is a whole number of cycles for all of them.
    private static func wrappedPhase(_ time: CFTimeInterval, rate: Float, offset: Float) -> Float {
        let phase = time * Double(rate) + Double(offset)
        return Float(phase.truncatingRemainder(dividingBy: 2 * .pi))
    }

    // MARK: Fish construction and motion

    private func makeFish(from model: ModelCache.LoadedModel, spec: FishSpec) -> Fish {
        let instance = model.template.clone()

        // `clone()` shares geometry *and* materials with the original. Each fish needs its
        // own materials because the swim phase is a material uniform — sharing them would
        // make the whole school beat as one animal. Copying the geometry is cheap: the
        // vertex buffers stay shared, only the material list is duplicated.
        var materials: [SCNMaterial] = []
        instance.enumerateHierarchy { node, _ in
            guard let geometry = node.geometry,
                  let copy = geometry.copy() as? SCNGeometry else { return }
            copy.materials = geometry.materials.compactMap { $0.copy() as? SCNMaterial }
            for material in copy.materials {
                material.shaderModifiers = [.geometry: swimModifier]
                material.setValue(NSNumber(value: 0.0), forKey: "swimPhase")
                // Amplitude is in the model's own object space, so it scales with the source
                // mesh, not with the fish's world size.
                material.setValue(NSNumber(value: model.length * 0.11), forKey: "swimAmplitude")
                material.setValue(NSNumber(value: 1.15), forKey: "swimWaves")
                material.setValue(NSNumber(value: model.minBound.x), forKey: "bodyMinX")
                material.setValue(NSNumber(value: model.length), forKey: "bodyLength")
            }
            node.geometry = copy
            materials.append(contentsOf: copy.materials)
        }

        // Blender exports Z-up with the nose at +X; the tank is Y-up. The pivot carries that
        // correction plus the scale, and the model is offset inside it so the fish turns
        // about its own centre rather than about the origin of the export.
        //
        // The scale comes from the manifest's `bodyLength` against the mesh's measured extent,
        // so a species that is re-exported slightly longer still swims at the size the library
        // says it is.
        let pivot = SCNNode()
        pivot.eulerAngles = SCNVector3(-Float.pi / 2, 0, 0)
        let scale = spec.bodyLength / model.length
        pivot.scale = SCNVector3(scale, scale, scale)
        let center = model.center
        instance.position = SCNVector3(-center.x, -center.y, -center.z)
        pivot.addChildNode(instance)

        let node = SCNNode()
        node.addChildNode(pivot)
        return Fish(node: node, materials: materials,
                    length: spec.bodyLength, depthBand: spec.depthBand)
    }

    /// Positions a fish on a straight crossing of the tank.
    ///
    /// The heading is deliberately never parallel to the frame: a fish angled 13–30° in depth
    /// changes size and fog as it crosses, which is what sells the depth lanes, and it keeps
    /// the tail sweep off the view axis. The depth component always aims at the far side of
    /// the tank from where the fish starts, so every crossing is a long one — a fish that
    /// spawned near the camera heading further forward would vanish again immediately.
    ///
    /// `stratum` and `spreadIndex` are set only for the opening layout. Respawns are
    /// unconstrained; by then the school has mixed.
    private func place(_ fish: Fish, spawningOffScreen: Bool,
                       stratum: Float? = nil, spreadIndex: Int = 0) {
        let band = fish.depthBand
        let near = Tank.nearDepth + band.lower * (Tank.farDepth - Tank.nearDepth)
        let far = Tank.nearDepth + band.upper * (Tank.farDepth - Tank.nearDepth)
        // Jittered off the stratum by a fraction of one stratum's width, so the opening layout
        // is spread without being a visible ladder of evenly spaced depths.
        let fraction = stratum.map { min(max($0 + rand.inRange(-0.035, 0.035), 0), 1) }
            ?? rand.next()
        let depth = near + fraction * (far - near)

        let speed = depth * Tank.speedPerDepth * rand.inRange(0.75, 1.3)
        let tilt = rand.inRange(0.22, 0.52)
        let towardFar: Float = depth < (near + far) / 2 ? -1 : 1
        let horizontal = rand.sign()

        fish.velocity = SIMD3<Float>(horizontal * speed * cos(tilt), 0,
                                     towardFar * speed * sin(tilt))

        let margin = fish.length * 1.05
        let edge = Tank.halfWidth(atDepth: depth) + margin
        // Golden-ratio stride: consecutive fish land far apart horizontally even though their
        // depths are adjacent, so the opening frame reads as a spread school. Indexed across
        // the whole tank rather than within one species, or two species would stack.
        let spread = stratum.map { _ in
            ((Float(spreadIndex) * 0.618_034 + 0.31).truncatingRemainder(dividingBy: 1) * 2 - 1)
                * edge
        }
        let x = spawningOffScreen ? -horizontal * edge : (spread ?? rand.inRange(-edge, edge))

        let halfHeight = Tank.halfHeight(atDepth: depth, aspect: aspect)
        fish.bobAmplitude = halfHeight * 0.07
        // The sand is a floor now, and at the far end of the tank it sits well inside the
        // frustum — a fish spawned by the old rule would have started buried. The clearance is
        // its own length plus the bob it is about to do, since the bob is applied on top of a
        // height it holds for the whole crossing.
        let ceiling = halfHeight * Tank.verticalFill
        let sand = Tank.floorY(aspect: aspect) + fish.length * Tank.fishFloorClearance
            + fish.bobAmplitude
        fish.position = SIMD3<Float>(x, rand.inRange(min(max(-ceiling, sand), ceiling), ceiling),
                                     -depth)

        fish.beat = rand.inRange(1.15, 1.75)
        fish.bobRate = rand.inRange(0.18, 0.42)
        fish.bobPhase = rand.inRange(0, 2 * .pi)
    }

    /// Rescales the school when the drawable changes shape.
    ///
    /// Half-height is inversely proportional to the aspect ratio at every depth, so scaling
    /// each fish by the ratio of the two aspects leaves it exactly where it was in the frame.
    /// Clamping instead would pile the school onto the new edges; leaving them alone would
    /// strand the outermost ones outside a frame they never leave, because a crossing only
    /// ends horizontally. The floor moves by the same factor, so a fish that cleared the sand
    /// still clears it.
    func adoptAspect(_ newAspect: Float) {
        guard newAspect != aspect, newAspect > 0 else { return }
        let scale = aspect / newAspect
        aspect = newAspect
        for fish in fishes {
            fish.position.y *= scale
            fish.bobAmplitude *= scale
        }
    }

    private func hasLeftTank(_ fish: Fish) -> Bool {
        let depth = -fish.position.z
        if depth < Tank.depthCullNear || depth > Tank.depthCullFar { return true }
        // Vertical as well as horizontal. A fish holds its world height while its depth
        // changes, so one that started high in the far, tall part of the frustum can end up
        // above the near, short part of it — and a crossing only ever *ends* horizontally, so
        // without this it would stay invisible for the rest of a crossing and the school would
        // silently look thinner. The margin is well outside anything `place` produces, so this
        // fires only once a fish is genuinely out of frame, and the respawn is off-screen.
        if abs(fish.position.y) > Tank.halfHeight(atDepth: depth, aspect: aspect)
            + fish.length { return true }
        let edge = Tank.halfWidth(atDepth: depth) + fish.length * 1.25
        return abs(fish.position.x) > edge && fish.position.x * fish.velocity.x > 0
    }

    /// Yaw that points the model's +X nose along `velocity`. A node rotated by `yaw` about
    /// +Y sends local +X to `(cos yaw, 0, -sin yaw)`, hence the negated z.
    private func headingYaw(of velocity: SIMD3<Float>) -> Float {
        atan2(-velocity.z, velocity.x)
    }
}

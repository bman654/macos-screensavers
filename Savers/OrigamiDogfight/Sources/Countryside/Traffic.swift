// The little cars: one to a road, driving from one end to the other, stopping a while in the
// village, and coming back. A car that meets a tank on its road waits for it to pass.
//
// Fixed-step on the countryside's own clock, like the sheep (`Pasture`), and interpolated between
// steps for the frame.

import Foundation
import simd

struct Car {
    let road: Int
    /// Metres along its road, and the way it is going along it: +1 or -1.
    var along: Float
    var previousAlong: Float
    var direction: Float
    var speed: Float = 0
    var parkedUntil: Double
    /// Which of the paper colours it is folded from.
    let paper: Int
}

struct Traffic {
    static let step: Double = 1.0 / 30
    /// About forty km/h at the diorama's scale of fifty to one — a country lane's pace.
    static let cruise: Float = 0.11

    private(set) var cars: [Car] = []
    private(set) var steps = 0
    private let roads: [Road]
    private var rand: Rand

    init(roads: [Road], seed: UInt64) {
        self.roads = roads
        rand = Rand(seed: seed ^ 0xCA25_0A_D5)
        for index in roads.indices where roads[index].length > 0.3 {
            let start = rand.inRange(0, roads[index].length)
            cars.append(Car(road: index, along: start, previousAlong: start, direction: rand.sign(),
                            parkedUntil: 0, paper: rand.index(count: 6)))
        }
    }

    /// Whether `advance(to:)` would do anything at `time`.
    func isDue(at time: Double) -> Bool { Int(floor(time / Traffic.step)) != steps }

    /// `tanks` are where any tank is now: a car will not drive into one.
    mutating func advance(to time: Double, tanks: [SIMD2<Float>]) {
        let due = Int(floor(time / Traffic.step)) - steps
        if due > 90 || due < 0 {
            steps = Int(floor(time / Traffic.step))
            for i in cars.indices { cars[i].previousAlong = cars[i].along }
            return
        }
        for _ in 0..<due {
            steps += 1
            stepOnce(now: Double(steps) * Traffic.step, tanks: tanks)
        }
    }

    private mutating func stepOnce(now: Double, tanks: [SIMD2<Float>]) {
        let dt = Float(Traffic.step)
        for i in cars.indices {
            var car = cars[i]
            car.previousAlong = car.along
            let road = roads[car.road]
            defer { cars[i] = car }
            guard now >= car.parkedUntil else { continue }

            // Slowing for the end of the road, and for a tank on the road ahead.
            let ahead = road.sample(at: car.along + car.direction * 0.12).position
            let blocked = tanks.contains { simd_distance($0, ahead) < 0.14 }
            let left = car.direction > 0 ? road.length - car.along : car.along
            let wanted = blocked ? 0 : min(Traffic.cruise, 0.04 + left * 0.8)
            car.speed += max(min(wanted - car.speed, 0.12 * dt), -0.3 * dt)
            car.along += car.direction * car.speed * dt

            if left < 0.01 {
                // Parked at the end for a while — a call in the village — then back the other way.
                car.along = car.direction > 0 ? road.length : 0
                car.direction = -car.direction
                car.speed = 0
                car.parkedUntil = now + Double(rand.inRange(3, 9))
            }
        }
    }

    /// Where a car is between the last two steps, and which way it faces — drawn a step behind
    /// the frame's time, as the sheep are (`Pasture.pose`).
    func pose(of index: Int, at frameTime: Double) -> (position: SIMD2<Float>, heading: Float) {
        let car = cars[index]
        let time = frameTime - Traffic.step
        let alpha = Float(min(max(time / Traffic.step - Double(steps - 1), 0), 1))
        let along = car.previousAlong + (car.along - car.previousAlong) * alpha
        let sample = roads[car.road].sample(at: along)
        let d = sample.direction * car.direction
        let heading = atan2(d.y, d.x)
        guard time < car.parkedUntil else { return (sample.position, heading) }
        // Parked, it faces the way it came in, and turns round in the last second and a half
        // before it sets off — a car that flipped end for end would read as a glitch.
        let turn = smoothstep(Float(car.parkedUntil - 1.5), Float(car.parkedUntil), Float(time))
        return (sample.position, heading + .pi * (1 - turn))
    }
}

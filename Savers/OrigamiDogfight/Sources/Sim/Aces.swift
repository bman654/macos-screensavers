// Aces and their stickers, and how worn a vehicle's paper is.
//
// A plane or tank that keeps scoring earns a sticker at each milestone, the way a teacher sticks
// a gold star on good work — and a few of the other things off the same sheet, so a long fight
// shows a little range. The stickers belong to the vehicle: a replacement starts clean, and so
// does every plane in a new match. The card in the corner keeps a side's stickers for the rest
// of the match, so an ace's record outlives the ace.
//
// Pure data. What a sticker looks like is `Render/Stickers.swift`.

import Foundation

enum Sticker: Int, CaseIterable, Equatable {
    case silverStar, smiley, heart, goldStar, rainbow
}

enum Aces {
    /// Kills, since it took to the air, that each earn a sticker. Tuned against the soak: at a
    /// few planes a plane that lives long enough to score three is roughly one a match, and at
    /// "lots", where a plane lives about a minute, three is still reached a few times a match —
    /// so the first sticker is seen often and the third is an event.
    static let milestones = [3, 5, 8]

    /// The first sticker is whatever came off the sheet — a silver star, a smiley or a heart,
    /// told apart by the vehicle's id so the same fight always sticks on the same one; the
    /// second is the gold star, and the third the rainbow, which is rare enough to mean it.
    static func sticker(milestone index: Int, id: Int) -> Sticker {
        switch index {
        case 0: return [Sticker.silverStar, .smiley, .heart][id % 3]
        case 1: return .goldStar
        default: return .rainbow
        }
    }

    static func stickers(kills: Int, id: Int) -> [Sticker] {
        milestones.indices.filter { kills >= milestones[$0] }.map { sticker(milestone: $0, id: id) }
    }
}

enum Damage {
    /// 0 clean, 1 smudged, 2 scorched, 3 charred — at three quarters, half and a quarter of the
    /// armour left. A plane going down is charred whatever it had left: a collision takes a
    /// healthy plane out of the sky, and it should not fall looking untouched.
    static func stage(health: Float, armour: Float, downed: Bool) -> Int {
        if downed { return 3 }
        let left = health / max(armour, 1e-3)
        return left > 0.75 ? 0 : (left > 0.5 ? 1 : (left > 0.25 ? 2 : 3))
    }
}

extension DogfightSim {
    /// A kill for whatever fired the shot, plane or tank, and a sticker if that was a milestone.
    /// Gated like the score: a shot still in the air when the winner is named counts for
    /// nothing. A plane already going down still gets the kill — the shot was fair.
    func awardKill(to shooter: Int, now: Double) {
        guard match.phase == .fighting else { return }
        var side: Int
        var kills: Int
        if let i = planes.firstIndex(where: { $0.id == shooter }) {
            planes[i].kills += 1
            (side, kills) = (planes[i].side, planes[i].kills)
        } else if let i = tanks.firstIndex(where: { $0.id == shooter }) {
            tanks[i].kills += 1
            (side, kills) = (tanks[i].side, tanks[i].kills)
        } else {
            return
        }
        guard let milestone = Aces.milestones.firstIndex(of: kills) else { return }
        let sticker = Aces.sticker(milestone: milestone, id: shooter)
        if match.stickers.indices.contains(side) { match.stickers[side].append(sticker) }
        emit(.stickered(vehicle: shooter, sticker: sticker, kills: kills))
    }
}

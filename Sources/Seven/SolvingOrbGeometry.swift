import Foundation

enum SolvingOrbGeometry {
    struct Dot: Equatable {
        let x: Double, y: Double, z: Double, r: Double, white: Double
    }
    
    static let options: [String: Double] = [
        "latRings": 4, "lonDensity": 12, "moveCount": 14,
        "rBase": 0.6 * 1.9, "rDepth": 1.7 * 1.9, "rActive": 0.3 * 1.9
    ]
    static func dots(size: Double, elapsed: Double) -> [Dot] {
        frame(size, max(0, elapsed) * 1.95, options)
    }
    private static func hashD(_ a: Double, _ b: Double) -> Double {
        let h = sin(a * 12.9898 + b * 78.233) * 43758.5453
        return h - floor(h)
    }
    private static func radiusScale(_ size: Double, pow exponent: Double) -> Double {
        pow(size / 300, exponent)
    }
    private struct Projector {
        let yaw: Double, tilt: Double, cx: Double, cy: Double, scale: Double
        func callAsFunction(_ x: Double, _ y: Double, _ z: Double) -> (Double, Double, Double) {
            let x1 = x * cos(yaw) + z * sin(yaw)
            let z1 = -x * sin(yaw) + z * cos(yaw)
            let y1 = y * cos(tilt) - z1 * sin(tilt)
            return (cx + x1 * scale, cy - y1 * scale, y * sin(tilt) + z1 * cos(tilt))
        }
    }
private struct Move {
    let axis: Int
    let lo: Double
    let hi: Double
    let ang: Double
}

private struct SolveCycle {
    var amount: [Double]
    var active: Int
}

private static func solveCycle(_ time: Double, _ count: Int, _ slotDur: Double, _ rest: Double) -> SolveCycle {
    let cyc = 2 * Double(count) * slotDur + rest
    let tc = time.truncatingRemainder(dividingBy: cyc)
    var amount = [Double](repeating: 0, count: count)
    var active = -1
    if tc < 2 * Double(count) * slotDur {
        let slot = Int(floor(tc / slotDur))
        let p = (tc - Double(slot) * slotDur) / slotDur
        let cl = Swift.min(1, p / 0.7)
        let ep = 1 - pow(1 - cl, 3) // machine ease-out
        if slot < count {
            for i in 0..<slot { amount[i] = 1 }
            amount[slot] = ep
            active = slot
        } else {
            let u = 2 * count - 1 - slot
            for i in 0..<u { amount[i] = 1 }
            amount[u] = 1 - ep
            active = u
        }
    }
    return SolveCycle(amount: amount, active: active)
}

private static func applyMoves(
    _ pt3: (Double, Double, Double), _ moves: [Move], _ sc: SolveCycle
) -> (Double, Double, Double, Bool) {
    var (x, y, z) = pt3
    var inActive = false
    for i in 0..<moves.count {
        if sc.amount[i] <= 0 { continue }
        let mv = moves[i]
        let coord = mv.axis == 0 ? x : (mv.axis == 1 ? y : z)
        if coord < mv.lo || coord >= mv.hi { continue }
        if i == sc.active { inActive = true }
        let a = mv.ang * sc.amount[i]
        let ca = cos(a)
        let sa = sin(a)
        if mv.axis == 0 {
            let y2 = y * ca - z * sa
            z = y * sa + z * ca
            y = y2
        } else if mv.axis == 1 {
            let x2 = x * ca + z * sa
            z = -x * sa + z * ca
            x = x2
        } else {
            let x2 = x * ca - y * sa
            y = x * sa + y * ca
            x = x2
        }
    }
    return (x, y, z, inActive)
}

private static func makeMoves(_ count: Int) -> [Move] {
    var moves: [Move] = []
    for i in 0..<count {
        let axis = Swift.min(2, Int(floor(hashD(Double(i), 2.3) * 3)))
        let lo = -1.0 + 0.5 * Double(Swift.min(3, Int(floor(hashD(Double(i), 5.9) * 4))))
        let dir: Double = hashD(Double(i), 7.7) < 0.5 ? 1 : -1
        moves.append(Move(axis: axis, lo: lo, hi: lo + 0.5, ang: dir * Double.pi / 2))
    }
    return moves
}

static func frame(_ size: Double, _ t: Double, _ o: [String: Double]) -> [Dot] {
    let cx = size / 2
    let cy = size / 2
    let R = (size / 2) * 0.82
    let pt = Projector(yaw: t * 0.55, tilt: 0.35 + 0.1 * sin(t * 0.9), cx: cx, cy: cy, scale: R)
    let rs = radiusScale(size, pow: o["rsPow"] ?? 0.6)
    let moveCount = Int(o["moveCount"] ?? 14)
    let moves = makeMoves(moveCount)
    let sc = solveCycle(t, moveCount, 0.42, 1.2)

    var dots: [Dot] = []
    let latRings = Int(o["latRings"] ?? 15)
    let lonDensity = o["lonDensity"] ?? 40
    for li in 0...latRings {
        let lat = -Double.pi / 2 + (Double(li) / Double(latRings)) * Double.pi
        let cosLat = cos(lat)
        let sinLat = sin(lat)
        let lonCount = Swift.max(1, Int((abs(cosLat) * lonDensity).rounded(.toNearestOrAwayFromZero)))
        for lj in 0..<lonCount {
            let lon = (Double(lj) / Double(lonCount)) * 2 * Double.pi
            let (x, y, z, inActive) = applyMoves(
                (cosLat * cos(lon), sinLat, cosLat * sin(lon)), moves, sc)
            let (px, py, zr) = pt(x, y, z)
            let depth = (zr + 1) / 2
            // the band being turned inks a touch darker — the "hand"
            dots.append(Dot(
                x: px, y: py, z: zr,
                r: ((o["rBase"] ?? 0.6) + (o["rDepth"] ?? 1.7) * depth + (inActive ? (o["rActive"] ?? 0.3) : 0)) * rs,
                white: (o["inkFar"] ?? 0.62) - (o["inkSpan"] ?? 0.54) * depth - (inActive ? 0.14 : 0)
            ))
        }
    }
    return dots.map { Dot(x: $0.x, y: $0.y, z: $0.z, r: max(0.3, $0.r), white: $0.white) }.sorted { $0.z < $1.z }
}

}

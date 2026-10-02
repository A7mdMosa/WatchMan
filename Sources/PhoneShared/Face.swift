import SwiftUI
import WatchManCore

/// How WatchMan's ball looks, as on the Mac: only through its eyes and their lids.
enum FaceMood: String, Codable, Hashable, Sendable {
    /// Open, at ease.
    case calm
    /// Reading along: the upper lids come down flat.
    case working
    /// Wide open: something waits on you.
    case needsYou
    /// Smiling arches: done.
    case happy
    /// Lids tilted, inner corners up: stopped with an error.
    case worried
    /// Heavy lids: the usage limit.
    case sleepy
    /// Shut: nothing going on.
    case asleep
    /// One eye shut, one smiling.
    case wink
    /// Wider still.
    case surprised

    init(_ state: SessionSnapshot.State?) {
        switch state {
        case .needsYou?: self = .needsYou
        case .working?: self = .working
        case .failed?: self = .worried
        case .limited?: self = .sleepy
        case .idle?: self = .asleep
        case .done?, nil: self = .happy
        }
    }

    /// The colours turning inside the ball, the same as the Mac's orb for the same moment (NotchMood's palettes).
    var palette: [Color] {
        func rgb(_ r: Double, _ g: Double, _ b: Double) -> Color { Color(red: r, green: g, blue: b) }
        switch self {
        case .calm: return [rgb(0.42, 0.40, 1.0), rgb(0.62, 0.42, 1.0), rgb(0.36, 0.58, 1.0)]
        case .working: return [rgb(0.30, 0.56, 1.0), rgb(0.62, 0.40, 1.0), rgb(0.22, 0.82, 0.70), rgb(0.95, 0.45, 0.80)]
        // The usage limit waits on you too, as on the Mac
        case .needsYou, .sleepy: return [rgb(1.0, 0.66, 0.18), rgb(1.0, 0.46, 0.22), rgb(1.0, 0.78, 0.30)]
        case .happy, .wink, .surprised: return [rgb(0.30, 0.66, 1.0), rgb(0.30, 0.86, 0.96), rgb(0.46, 0.56, 1.0)]
        case .worried: return [rgb(0.97, 0.28, 0.34), rgb(0.85, 0.18, 0.42), rgb(1.0, 0.42, 0.30)]
        case .asleep: return [rgb(0.32, 0.32, 0.50), rgb(0.38, 0.32, 0.52), rgb(0.30, 0.38, 0.52)]
        }
    }
}

/// An eye's outline as a top edge and a bottom edge, each from the left side through the middle to the right
/// side, in units of the ball's radius within the eye's box (0.3 wide, 0.8 tall). Every pose has the same parts,
/// so one morphs into another: lids close over the eye instead of the eye being squashed. The Mac's orb draws the
/// same shapes.
struct BallEyePose: VectorArithmetic, Sendable {
    var topLeft: Double, topMid: Double, topRight: Double
    var bottomLeft: Double, bottomMid: Double, bottomRight: Double
    /// 1: the edge curves like the eye's round end; 0: straight, like a lid.
    var topRound: Double = 1
    var bottomRound: Double = 1
    var width: Double = BallEyePose.eyeWidth

    static let boxHeight = 0.8
    static let eyeWidth = 0.26

    /// An open eye `height` tall, centred in its box.
    static func open(_ height: Double) -> BallEyePose {
        let a = eyeWidth / 2, top = boxHeight / 2 - height / 2, bottom = top + height
        return BallEyePose(topLeft: top + a, topMid: top, topRight: top + a,
                       bottomLeft: bottom - a, bottomMid: bottom, bottomRight: bottom - a)
    }

    /// The upper lid straight across, covering `cover` of the eye; `tilt` lowers its outer end (left eye).
    static func lidded(_ height: Double, cover: Double, tilt: Double = 0) -> BallEyePose {
        var pose = open(height)
        let lid = pose.topMid + height * cover
        pose.topLeft = lid + height * tilt
        pose.topMid = lid
        pose.topRight = lid - height * tilt
        pose.topRound = 0
        return pose
    }

    /// Smiling: the lower lid pushes up until only an arch shows.
    static var happy: BallEyePose {
        let top = boxHeight / 2 - 0.16, band = 0.16, legs = 0.13
        return BallEyePose(topLeft: top + legs, topMid: top, topRight: top + legs,
                       bottomLeft: top + legs + band, bottomMid: top + band, bottomRight: top + legs + band, width: 0.4)
    }

    /// Shut: the upper lid down on the lower one, leaving a thin curve.
    func closed(_ thickness: Double) -> BallEyePose {
        BallEyePose(topLeft: bottomLeft - thickness, topMid: bottomMid - thickness, topRight: bottomRight - thickness,
                bottomLeft: bottomLeft, bottomMid: bottomMid, bottomRight: bottomRight,
                topRound: bottomRound, bottomRound: bottomRound, width: width)
    }

    /// The same pose for the right eye.
    var mirrored: BallEyePose {
        BallEyePose(topLeft: topRight, topMid: topMid, topRight: topLeft, bottomLeft: bottomRight, bottomMid: bottomMid,
                bottomRight: bottomLeft, topRound: topRound, bottomRound: bottomRound, width: width)
    }

    /// Both eyes for a mood, left then right.
    static func eyes(_ mood: FaceMood) -> (BallEyePose, BallEyePose) {
        let left: BallEyePose
        switch mood {
        case .calm: left = .open(0.52)
        case .working: left = .lidded(0.46, cover: 0.32)
        case .needsYou: left = .open(0.64)
        case .happy: left = .happy
        case .worried: left = .lidded(0.48, cover: 0.22, tilt: 0.14)
        case .sleepy: left = .lidded(0.48, cover: 0.5)
        case .asleep: left = BallEyePose.open(0.5).closed(0.12)
        case .surprised: left = .open(0.72)
        case .wink: return (BallEyePose.open(0.5).closed(0.12), BallEyePose.happy.mirrored)
        }
        return (left, left.mirrored)
    }

    // MARK: VectorArithmetic, so SwiftUI morphs one pose into the next

    private var values: [Double] { [topLeft, topMid, topRight, bottomLeft, bottomMid, bottomRight, topRound, bottomRound, width] }

    static var zero: BallEyePose { BallEyePose(Array(repeating: 0, count: 9)) }
    static func + (a: BallEyePose, b: BallEyePose) -> BallEyePose { BallEyePose(zip(a.values, b.values).map(+)) }
    static func - (a: BallEyePose, b: BallEyePose) -> BallEyePose { BallEyePose(zip(a.values, b.values).map(-)) }
    mutating func scale(by rhs: Double) { self = BallEyePose(values.map { $0 * rhs }) }
    var magnitudeSquared: Double { values.reduce(0) { $0 + $1 * $1 } }
}

private extension BallEyePose {
    // In an extension, so the struct keeps its memberwise initializer
    init(_ v: [Double]) {
        self.init(topLeft: v[0], topMid: v[1], topRight: v[2], bottomLeft: v[3], bottomMid: v[4], bottomRight: v[5],
                  topRound: v[6], bottomRound: v[7], width: v[8])
    }
}

/// One eye, drawn in its box.
struct BallEye: Shape {
    var pose: BallEyePose

    var animatableData: BallEyePose {
        get { pose }
        set { pose = newValue }
    }

    func path(in rect: CGRect) -> Path {
        let r = rect.height / BallEyePose.boxHeight
        let w = pose.width * r, a = w / 2, k = 0.5523
        let x = rect.minX + (rect.width - w) / 2
        func y(_ value: Double) -> Double { rect.minY + value * r }
        func mix(_ p: CGPoint, _ q: CGPoint, _ t: Double) -> CGPoint {
            CGPoint(x: p.x + (q.x - p.x) * t, y: p.y + (q.y - p.y) * t)
        }
        // Between a straight edge (a third of the way along) and a round one (a quarter ellipse)
        func control(_ from: CGPoint, _ to: CGPoint, _ third: Double, round: CGPoint, _ amount: Double) -> CGPoint {
            mix(mix(from, to, third), round, amount)
        }
        let tl = CGPoint(x: x, y: y(pose.topLeft)), tm = CGPoint(x: x + a, y: y(pose.topMid))
        let tr = CGPoint(x: x + w, y: y(pose.topRight)), br = CGPoint(x: x + w, y: y(pose.bottomRight))
        let bm = CGPoint(x: x + a, y: y(pose.bottomMid)), bl = CGPoint(x: x, y: y(pose.bottomLeft))
        var path = Path()
        path.move(to: tl)
        path.addCurve(to: tm, control1: control(tl, tm, 1 / 3, round: CGPoint(x: x, y: tl.y + k * (tm.y - tl.y)), pose.topRound),
                      control2: control(tl, tm, 2 / 3, round: CGPoint(x: x + a - k * a, y: tm.y), pose.topRound))
        path.addCurve(to: tr, control1: control(tm, tr, 1 / 3, round: CGPoint(x: x + a + k * a, y: tm.y), pose.topRound),
                      control2: control(tm, tr, 2 / 3, round: CGPoint(x: x + w, y: tr.y + k * (tm.y - tr.y)), pose.topRound))
        path.addLine(to: br)
        path.addCurve(to: bm, control1: control(br, bm, 1 / 3, round: CGPoint(x: x + w, y: br.y + k * (bm.y - br.y)), pose.bottomRound),
                      control2: control(br, bm, 2 / 3, round: CGPoint(x: x + a + k * a, y: bm.y), pose.bottomRound))
        path.addCurve(to: bl, control1: control(bm, bl, 1 / 3, round: CGPoint(x: x + a - k * a, y: bm.y), pose.bottomRound),
                      control2: control(bm, bl, 2 / 3, round: CGPoint(x: x, y: bl.y + k * (bm.y - bl.y)), pose.bottomRound))
        path.closeSubpath()
        return path
    }
}

/// The app icon's face: the violet-to-blue ball with its soft glow and two white eyes looking up at you. The Live
/// Activity and the Dynamic Island show this one, as they can't show the ball's moods moving.
struct IconFace: View {
    var size: CGFloat = 38

    static let violet = Color(red: 0.62, green: 0.42, blue: 1.0)
    static let indigo = Color(red: 0.42, green: 0.40, blue: 1.0)
    static let blue = Color(red: 0.25, green: 0.64, blue: 1.0)

    var body: some View {
        // In the icon's proportions: a 512 ball with 72 × 112 eyes, 36 apart, up and to the right
        ZStack {
            Circle()
                .fill(LinearGradient(colors: [Self.violet, Self.indigo, Self.blue], startPoint: UnitPoint(x: 0.15, y: 0.1),
                                     endPoint: UnitPoint(x: 0.85, y: 0.95)))
            HStack(spacing: size * 36 / 512) {
                Ellipse().fill(.white).frame(width: size * 72 / 512, height: size * 112 / 512)
                Ellipse().fill(.white).frame(width: size * 72 / 512, height: size * 112 / 512)
            }
            .offset(x: size * 30 / 512, y: -size * 54 / 512)
        }
        .frame(width: size, height: size)
        .shadow(color: Self.indigo.opacity(0.6), radius: size * 0.15)
        .accessibilityHidden(true)
    }
}

/// WatchMan's ball with its eyes, drawn like the Mac's orb: its mood's colours turning around it, a soft light
/// from the middle, a glow in its first colour, and the mood's look.
struct FaceView: View {
    var colors: [Color] = FaceMood.calm.palette
    var size: CGFloat = 44
    var mood: FaceMood = .calm

    /// The ball for a mood, in that mood's colours.
    init(mood: FaceMood, size: CGFloat = 44) {
        colors = mood.palette
        self.size = size
        self.mood = mood
    }

    init(colors: [Color] = FaceMood.calm.palette, size: CGFloat = 44, mood: FaceMood = .calm) {
        self.colors = colors
        self.size = size
        self.mood = mood
    }

    var body: some View {
        let r = size / 2
        let (left, right) = BallEyePose.eyes(mood)
        let ink = Color(white: 0.06).opacity(mood == .asleep ? 0.72 : 0.88)
        ZStack {
            Circle().fill(AngularGradient(colors: colors + [colors[0]], center: .center))
            // The Mac orb's core: white at the middle, fading out by the edge
            Circle().fill(RadialGradient(colors: [.white.opacity(0.45), .white.opacity(0)], center: .center,
                                         startRadius: 0, endRadius: r * 1.414))
            BallEye(pose: left).fill(ink)
                .frame(width: r * 0.3, height: r * BallEyePose.boxHeight)
                .offset(x: -r * 0.31)
            BallEye(pose: right).fill(ink)
                .frame(width: r * 0.3, height: r * BallEyePose.boxHeight)
                .offset(x: r * 0.31)
        }
        .frame(width: size, height: size)
        .shadow(color: colors[0].opacity(0.5), radius: size * 0.2)
        .animation(.spring(response: 0.45, dampingFraction: 0.7), value: mood)
        .accessibilityHidden(true)
    }
}

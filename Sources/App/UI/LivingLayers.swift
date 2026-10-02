import AppKit
import CoreImage
import QuartzCore
import SwiftUI
import WatchManCore

/// The living notch in Core Animation. Its motion (breathing, the colours, the light on the edge) runs in the
/// system's render server, so WatchMan itself does no work per frame, only when something changes.

/// Reduce Motion (System Settings › Accessibility › Display): the notch holds still and changes by fading.
@MainActor
enum Motion {
    static var reduced: Bool { NSWorkspace.shared.accessibilityDisplayShouldReduceMotion }
}

extension NotchMood {
    private static func rgb(_ r: Double, _ g: Double, _ b: Double) -> Color { Color(red: r, green: g, blue: b) }

    /// The colours shifting inside the orb and along the island's edge.
    var palette: [Color] {
        switch self {
        case .quiet: [Self.rgb(0.42, 0.40, 1.0), Self.rgb(0.62, 0.42, 1.0), Self.rgb(0.36, 0.58, 1.0)]
        case .working: [Self.rgb(0.30, 0.56, 1.0), Self.rgb(0.62, 0.40, 1.0), Self.rgb(0.22, 0.82, 0.70), Self.rgb(0.95, 0.45, 0.80)]
        case .needsYou: [Self.rgb(1.0, 0.66, 0.18), Self.rgb(1.0, 0.46, 0.22), Self.rgb(1.0, 0.78, 0.30)]
        case .done: [Self.rgb(0.30, 0.66, 1.0), Self.rgb(0.30, 0.86, 0.96), Self.rgb(0.46, 0.56, 1.0)]
        case .worried: [Self.rgb(0.97, 0.28, 0.34), Self.rgb(0.85, 0.18, 0.42), Self.rgb(1.0, 0.42, 0.30)]
        case .asleep: [Self.rgb(0.32, 0.32, 0.50), Self.rgb(0.38, 0.32, 0.52), Self.rgb(0.30, 0.38, 0.52)]
        }
    }

    /// How fast the colours turn (turns per second).
    var drift: Double {
        switch self {
        case .quiet: 0.06
        case .working: 0.22
        case .needsYou, .done: 0.1
        case .worried: 0.15
        case .asleep: 0.02
        }
    }

    /// The palette as a closed loop for a conic gradient.
    var loop: [CGColor] { (palette + [palette[0]]).map { NSColor($0).cgColor } }
}

/// Behind the island: the part of it that breathes past its laid-out shape, its glow and the light on its edge,
/// all in the orb's colours.
@MainActor
final class IslandBackView: NSView {
    override func hitTest(_ point: NSPoint) -> NSView? { nil }

    /// Top-left origin, like SwiftUI, so paths and rects can be shared with the SwiftUI island.
    private let stage = CALayer()
    private let breathe = CALayer()
    private let body = CAShapeLayer()
    private let edgeClip = CALayer()
    private let edge = CALayer()
    private let edgeMask = CAShapeLayer()
    private let gradient = CAGradientLayer()

    private var mood: NotchMood?
    /// When a session last started waiting (in the body layer's time): full attention for ~8 s from then.
    private var attentionStart: CFTimeInterval = 0
    private var island = CGRect.zero
    private var shoulder = NotchModel.shoulder
    private var radius = NotchModel.stripRadius
    private var shown = false

    override init(frame: NSRect) {
        super.init(frame: frame)
        wantsLayer = true
        alphaValue = 0
        guard let root = layer else { return }
        stage.isGeometryFlipped = true
        root.addSublayer(stage)
        stage.addSublayer(breathe)
        breathe.anchorPoint = .zero
        breathe.addSublayer(body)
        breathe.addSublayer(edgeClip)
        edgeClip.masksToBounds = true
        edgeClip.addSublayer(edge)
        edge.addSublayer(gradient)
        edge.mask = edgeMask
        body.fillColor = .black
        body.shadowOffset = .zero
        body.shadowRadius = 8
        edgeMask.fillColor = nil
        edgeMask.strokeColor = .white
        edgeMask.lineWidth = 2
        gradient.type = .conic
        gradient.startPoint = CGPoint(x: 0.5, y: 0.5)
        gradient.endPoint = CGPoint(x: 1, y: 0.5)
    }

    required init?(coder: NSCoder) { nil }

    override func layout() {
        super.layout()
        CATransaction.begin()
        CATransaction.setDisableActions(true)
        stage.frame = bounds
        breathe.bounds = bounds
        breathe.position = .zero
        // Keep the light off the very top row: that edge is the top of the screen
        edgeClip.frame = CGRect(x: 0, y: 1.5, width: bounds.width, height: bounds.height)
        edge.frame = CGRect(x: 0, y: -1.5, width: bounds.width, height: bounds.height)
        body.frame = bounds
        edgeMask.frame = bounds
        CATransaction.commit()
    }

    /// `island`: the closed island in this view's coordinates (top-left origin).
    func update(mood: NotchMood, island: CGRect, shoulder: CGFloat, radius: CGFloat, shown: Bool) {
        let moved = island != self.island || shoulder != self.shoulder || radius != self.radius
        let changed = mood != self.mood
        let appearing = shown && !self.shown
        self.island = island
        self.shoulder = shoulder
        self.radius = radius
        self.mood = mood
        self.shown = shown
        // Appearing, it takes its shape at once (never morphing from the open panel's size)
        if moved || appearing { setPaths(duration: appearing ? 0 : NotchModel.adjustDuration) }
        if changed {
            if mood == .needsYou { attentionStart = body.convertTime(CACurrentMediaTime(), from: nil) }
            applyMood()
        }
        // Shape animations hold the island's outline, so they're rebuilt whenever it changes. Built while the
        // island was open, they'd keep the open panel's shape after it closes.
        if shown, moved || changed || appearing {
            startBreathing()
            startShapeAnimations(fresh: changed)
        }
        if appearing || (!shown && alphaValue > 0) { fadeView(self, in: shown) }
    }

    /// The Reduce Motion setting changed: start again from the current state.
    func motionSettingChanged() {
        breathe.removeAllAnimations()
        applyMood()
        if shown {
            startBreathing()
            startShapeAnimations(fresh: false)
        }
    }

    /// Another session started waiting: the full ~8 s of attention again.
    func renewAttention() {
        guard mood == .needsYou else { return }
        attentionStart = body.convertTime(CACurrentMediaTime(), from: nil)
        applyMood()
        if shown { startShapeAnimations(fresh: false) }
    }

    /// The pointer came onto the strip while something waits: one nudge.
    func poke() {
        guard shown, mood == .needsYou, !Motion.reduced else { return }
        animatePaths(key: "poke", duration: 2.4, extras: Self.nudge)
    }

    /// You did something from WatchMan: a small bounce of acknowledgement.
    func acknowledge() {
        guard shown, !Motion.reduced else { return }
        let samples = stride(from: 0.0, through: 0.7, by: 0.05).map { t in CGFloat(max(0, exp(-t * 6) * sin(t * 18))) * 6 }
        animatePaths(key: "ack", duration: 0.7, extras: samples.map { ($0, $0, 0) })
    }

    /// Holds still (an idle WatchMan does no work at all) or moves.
    func setRunning(_ running: Bool) {
        layer?.setRunning(running)
    }

    // MARK: - Shape

    private func outline(left: CGFloat = 0, right: CGFloat = 0, bottom: CGFloat = 0) -> CGPath {
        let rect = CGRect(x: island.minX - left, y: island.minY, width: island.width + left + right, height: island.height + bottom)
        return NotchShape(shoulder: shoulder, radius: radius).path(in: rect).cgPath
    }

    private func setPaths(duration: Double) {
        let path = outline()
        CATransaction.begin()
        // While paused an implicit animation would never finish and keep the old shape
        CATransaction.setDisableActions(duration == 0 || layer?.speed == 0 || !shown)
        CATransaction.setAnimationDuration(duration)
        CATransaction.setAnimationTimingFunction(CAMediaTimingFunction(name: .easeInEaseOut))
        body.path = path
        body.shadowPath = path
        edgeMask.path = path
        let side = max(island.width, island.height) * 1.5
        gradient.bounds = CGRect(x: 0, y: 0, width: side, height: side)
        gradient.position = CGPoint(x: island.midX, y: island.midY)
        CATransaction.commit()
    }

    /// The same keyframes on the outline, its shadow and the edge light. `keyTimes` (one more than `extras`, for the
    /// closing rest shape) spread them unevenly; `beginTime` is in the body layer's time.
    private func animatePaths(key: String, duration: Double, repeatCount: Float = 1, extras: [(CGFloat, CGFloat, CGFloat)],
                              keyTimes: [NSNumber]? = nil, beginTime: CFTimeInterval? = nil) {
        let paths = extras.map { outline(left: $0.0, right: $0.1, bottom: $0.2) } + [outline()]
        for (layer, keyPath) in [(body, "path"), (body, "shadowPath"), (edgeMask, "path")] as [(CALayer, String)] {
            let animation = CAKeyframeAnimation(keyPath: keyPath)
            animation.values = paths
            animation.keyTimes = keyTimes
            animation.duration = duration
            animation.repeatCount = repeatCount
            if let beginTime { animation.beginTime = beginTime }
            layer.add(animation, forKey: key + keyPath)
        }
    }

    /// Drops a little and springs back (2.4 s, sampled every 0.05 s).
    static let nudge: [(CGFloat, CGFloat, CGFloat)] = stride(from: 0.0, to: 2.4, by: 0.05).map { p in
        let drop: Double = p < 0.18 ? sin(.pi / 2 * p / 0.18)
            : p < 1 ? max(0, exp(-(p - 0.18) * 7) * cos((p - 0.18) * 22)) : 0
        return (0, 0, CGFloat(6 * drop))
    }

    private func removePathAnimations(_ key: String) {
        for (layer, keyPath) in [(body, "path"), (body, "shadowPath"), (edgeMask, "path")] as [(CALayer, String)] {
            layer.removeAnimation(forKey: key + keyPath)
        }
    }

    /// The nudge while a session needs you, and the stretch when something's done (only when it just happened).
    private func startShapeAnimations(fresh: Bool) {
        removePathAnimations("nudge")
        removePathAnimations("renudge")
        if fresh { removePathAnimations("stretch") }
        guard !Motion.reduced else { return }
        switch mood {
        case .needsYou:
            // Four nudges (the one starting at 7.2 s finishes), then one a minute while it still waits. Both are
            // timed from when the waiting began, so a rebuilt shape doesn't start the attention over.
            animatePaths(key: "nudge", duration: 2.4, repeatCount: 4, extras: Self.nudge, beginTime: attentionStart)
            let period = 60.0
            let rest = (period - 2.4) / period
            let times = [0.0] + Self.nudge.indices.map { rest + Double($0) * 0.05 / period } + [1.0]
            animatePaths(key: "renudge", duration: period, repeatCount: .infinity, extras: [(0, 0, 0)] + Self.nudge,
                         keyTimes: times.map { NSNumber(value: $0) }, beginTime: attentionStart + 9.6)
        case .done where fresh:
            let stretch = stride(from: 0.0, through: 1.2, by: 0.05).map { m -> (CGFloat, CGFloat, CGFloat) in
                let s = CGFloat(max(0, exp(-m * 5) * sin(m * 14)))
                return (12 * s, 12 * s, 3 * s)
            }
            animatePaths(key: "stretch", duration: 1.2, extras: stretch)
        default:
            break
        }
    }

    private func startBreathing() {
        guard island.width > 0, island.height > 0, !Motion.reduced else {
            breathe.removeAnimation(forKey: "breath")
            return
        }
        let top = CGPoint(x: island.midX, y: island.minY)
        var grown = CATransform3DMakeTranslation(top.x, top.y, 0)
        grown = CATransform3DScale(grown, 1 + 1.5 / island.width, 1 + 1 / island.height, 1)
        grown = CATransform3DTranslate(grown, -top.x, -top.y, 0)
        let breath = CABasicAnimation(keyPath: "transform")
        breath.fromValue = CATransform3DIdentity
        breath.toValue = grown
        breath.duration = mood == .asleep ? 2.7 : 2
        breath.autoreverses = true
        breath.repeatCount = .infinity
        breath.timingFunction = CAMediaTimingFunction(name: .easeInEaseOut)
        breathe.add(breath, forKey: "breath")
    }

    // MARK: - Mood

    private func applyMood() {
        guard let mood else { return }
        for layer in [body, edge] as [CALayer] {
            layer.removeAnimation(forKey: "glow")
            layer.removeAnimation(forKey: "calm")
        }
        CATransaction.begin()
        CATransaction.setAnimationDuration(0.7)
        body.shadowColor = NSColor(mood.palette[0]).cgColor
        gradient.colors = mood.loop
        CATransaction.commit()

        // The edge light turns slowly in the orb's colours
        gradient.removeAnimation(forKey: "spin")
        if !Motion.reduced {
            let spin = CABasicAnimation(keyPath: "transform.rotation.z")
            spin.fromValue = 0
            spin.toValue = 2 * Double.pi
            spin.duration = 1 / mood.drift
            spin.repeatCount = .infinity
            gradient.add(spin, forKey: "spin")
        }

        // The island only lights up when something calls for you; the orb shows the rest
        if Motion.reduced {
            // Still light instead of a heartbeat or a flicker
            let lit: Float = mood == .needsYou || mood == .worried ? 0.6 : 0
            body.shadowOpacity = lit
            edge.opacity = lit
            return
        }
        switch mood {
        case .quiet, .working:
            body.shadowOpacity = 0
            edge.opacity = 0
        case .needsYou:
            // Heartbeat (two beats, a pause) for the first ~8 s, then a slow calm breath while it still waits
            let beat: [Double] = [0.35, 1, 0.45, 0.85, 0.35, 0.35]
            glow(from: beat, edge: beat, duration: 1.2, keyTimes: [0, 0.07, 0.17, 0.25, 0.4, 1], repeatCount: 7,
                 beginTime: attentionStart)
            for (layer, range) in [(body, (0.22, 0.42)), (edge, (0.25, 0.40))] as [(CALayer, (Double, Double))] {
                let calm = CABasicAnimation(keyPath: layer === body ? "shadowOpacity" : "opacity")
                calm.fromValue = range.0
                calm.toValue = range.1
                calm.duration = 2
                calm.autoreverses = true
                calm.repeatCount = .infinity
                calm.timingFunction = CAMediaTimingFunction(name: .easeInEaseOut)
                calm.beginTime = attentionStart + 8.4
                calm.fillMode = .forwards
                layer.add(calm, forKey: "calm")
            }
        case .done:
            // A short flash, then dark again
            glow(from: [1, 1, 0], edge: [1, 1, 0], duration: 3, keyTimes: [0, 0.35, 1], repeating: false)
        case .worried:
            // A few seconds of flicker, then a quiet red line
            let flicker = (0..<12).map { 0.4 + 0.5 * abs(sin(Double($0) * 2.3) * sin(Double($0) * 0.9)) } + [0.3]
            glow(from: flicker.map { $0 * 0.6 }, edge: flicker, duration: 3, repeating: false)
        case .asleep:
            body.shadowOpacity = 0
            edge.opacity = 0
        }
    }

    /// Animates the glow and the edge light through `values` (from-to when `reversing`).
    private func glow(from values: [Double], edge edgeValues: [Double], duration: Double, keyTimes: [NSNumber]? = nil,
                      reversing: Bool = false, repeating: Bool = true, repeatCount: Float? = nil,
                      beginTime: CFTimeInterval? = nil) {
        body.shadowOpacity = Float(values.last ?? 0.3)
        edge.opacity = Float(edgeValues.last ?? 0.5)
        for (layer, key, list) in [(body, "shadowOpacity", values), (edge, "opacity", edgeValues)] as [(CALayer, String, [Double])] {
            let animation = CAKeyframeAnimation(keyPath: key)
            animation.values = list
            animation.keyTimes = keyTimes
            animation.duration = duration
            animation.autoreverses = reversing
            if repeating { animation.repeatCount = repeatCount ?? .infinity }
            if let beginTime { animation.beginTime = beginTime }
            if reversing { animation.timingFunction = CAMediaTimingFunction(name: .easeInEaseOut) }
            layer.add(animation, forKey: "glow")
        }
    }
}

/// In front of the island: WatchMan's orb, a small ball of soft light that breathes, its colours shifting,
/// with a face of two small eyes that shows what's going on, only through the eyes and their lids: they blink
/// and glance about while it's quiet, read along (now and then narrowing to concentrate) while Claude works,
/// open wide when a session needs you, smile when something's done (with a burst of confetti), tilt worried and
/// search when WatchMan can't hear Claude, and droop shut when it's asleep.
/// A one-off move of the ball for a moment that needs no message: it says it with a reaction, and the line
/// beside the notch says it in words.
enum OrbReaction: Equatable, Sendable {
    /// Springs awake: a bounce, a ring of light, eyes wide.
    case started
    /// Worried: eyes dart, a small wobble, an amber glow.
    case stuck
    /// Flinches: a shake, a red flash, eyes squeezed shut.
    case error
    /// Sleepy: heavy lids, a drifting z, an orange glow.
    case limit
    /// Glances at the line while a ring fills to the share used.
    case usage(Double)
    /// You're back: two little hops and a smile.
    case back
}

struct OrbReactionEvent: Equatable, Sendable {
    let id = UUID()
    let kind: OrbReaction
}

@MainActor
final class OrbView: NSView {
    override func hitTest(_ point: NSPoint) -> NSView? { nil }

    /// The ball's radius (a 20 pt ball).
    static let radius: CGFloat = 10

    private let stage = CALayer()
    private let holder = CALayer()
    /// Carries the whole ball's own moves (the spring when its mood changes); the holder places it and grows it on hover.
    private let body = CALayer()
    private let orb = CALayer()
    private let tile = CALayer()
    private let colors = CALayer()
    private let core = CAGradientLayer()
    private let face = CALayer()
    private let eyes = [CAShapeLayer(), CAShapeLayer()]
    private let zee = CAShapeLayer()
    private let confetti = CALayer()
    private let bits = (0..<26).map { _ in CALayer() }
    /// A ring around the ball for reactions: light spreading out when a session starts, a gauge for usage.
    private let ring = CAShapeLayer()

    private var r: CGFloat { Self.radius }
    /// Half the side of the box each eye is drawn in.
    private var eyeHalf: CGFloat { r * 0.36 }
    private var mood: NotchMood?
    private var hovered = false
    private var shown = false

    override init(frame: NSRect) {
        super.init(frame: frame)
        wantsLayer = true
        alphaValue = 0
        guard let root = layer else { return }
        let side = 2 * r
        let box = CGRect(x: 0, y: 0, width: side, height: side)
        stage.isGeometryFlipped = true
        root.addSublayer(stage)
        // Confetti flies out from behind the ball
        stage.addSublayer(confetti)
        for (i, bit) in bits.enumerated() {
            let dot = i % 3 == 0
            bit.bounds = dot ? CGRect(x: 0, y: 0, width: 2.2, height: 2.2) : CGRect(x: 0, y: 0, width: 4.6, height: 1.6)
            bit.cornerRadius = dot ? 1.1 : 0.8
            bit.opacity = 0
            confetti.addSublayer(bit)
        }
        stage.addSublayer(holder)
        holder.bounds = box
        holder.addSublayer(ring)
        ring.frame = box
        // From the top, clockwise, so a gauge fills like a clock
        let circle = CGMutablePath()
        circle.addArc(center: CGPoint(x: r, y: r), radius: r, startAngle: -.pi / 2, endAngle: 1.5 * .pi, clockwise: false)
        ring.path = circle
        ring.fillColor = nil
        ring.lineWidth = 1.6
        ring.lineCap = .round
        ring.opacity = 0
        holder.addSublayer(body)
        body.frame = box
        body.addSublayer(orb)
        orb.frame = box
        orb.shadowOffset = .zero
        orb.shadowRadius = r * 0.7
        orb.shadowPath = CGPath(ellipseIn: box, transform: nil)
        orb.addSublayer(tile)
        tile.frame = box
        tile.cornerRadius = r
        tile.masksToBounds = true

        // The colours, blended softly and turning; a soft bright core makes it light, not paint
        tile.addSublayer(colors)
        colors.bounds = CGRect(x: 0, y: 0, width: side * 1.5, height: side * 1.5)
        colors.position = CGPoint(x: r, y: r)
        colors.contentsGravity = .resize
        tile.addSublayer(core)
        core.type = .radial
        core.frame = box
        core.startPoint = CGPoint(x: 0.5, y: 0.5)
        core.endPoint = CGPoint(x: 1, y: 1)
        core.colors = [NSColor.white.withAlphaComponent(0.45).cgColor, NSColor.white.withAlphaComponent(0).cgColor]

        // The face: two eyes in dark ink, and a z that drifts up off the ball while it sleeps
        orb.addSublayer(face)
        face.frame = box
        for eye in eyes {
            eye.bounds = CGRect(origin: .zero, size: eyeBox)
            face.addSublayer(eye)
        }
        // On the half point, so the eyes stay sharp at the notch's small size
        for (i, eye) in eyes.enumerated() {
            eye.position = CGPoint(x: snap(r + (i == 0 ? -1 : 1) * r * 0.3), y: snap(r * 0.96))
        }
        zee.bounds = CGRect(x: 0, y: 0, width: 2 * eyeHalf, height: 2 * eyeHalf)
        zee.fillColor = nil
        zee.lineCap = .round
        zee.lineJoin = .round
        face.addSublayer(zee)
        zee.position = CGPoint(x: r * 1.95, y: r * 0.45)
        zee.strokeColor = NSColor.white.withAlphaComponent(0.75).cgColor
        zee.lineWidth = r * 0.12
        let s = r * 0.16, m = eyeHalf
        let z = CGMutablePath()
        z.move(to: CGPoint(x: m - s, y: m - s))
        z.addLine(to: CGPoint(x: m + s, y: m - s))
        z.addLine(to: CGPoint(x: m - s, y: m + s))
        z.addLine(to: CGPoint(x: m + s, y: m + s))
        zee.path = z
        zee.opacity = 0
    }

    required init?(coder: NSCoder) { nil }

    override func layout() {
        super.layout()
        CATransaction.begin()
        CATransaction.setDisableActions(true)
        stage.frame = bounds
        CATransaction.commit()
    }

    /// `center`: where the orb sits, in this view's coordinates (top-left origin); nil hides it.
    func update(mood: NotchMood, center: CGPoint?, hovered: Bool) {
        if let center, center != holder.position {
            CATransaction.begin()
            CATransaction.setDisableActions(layer?.speed == 0 || !shown)
            CATransaction.setAnimationDuration(NotchModel.adjustDuration)
            holder.position = center
            CATransaction.commit()
        }
        if hovered != self.hovered {
            self.hovered = hovered
            holder.transform = hovered ? CATransform3DMakeScale(1.15, 1.15, 1) : CATransform3DIdentity
        }
        if mood != self.mood {
            self.mood = mood
            applyMood()
            if mood == .done, let center { burst(from: center) }
        }
        let shown = center != nil
        if shown != self.shown {
            self.shown = shown
            fadeView(self, in: shown)
        }
    }

    func setRunning(_ running: Bool) {
        layer?.setRunning(running)
    }

    /// Another session started waiting: the heartbeat again for ~8 s.
    func renewAttention() {
        guard mood == .needsYou else { return }
        applyMood()
    }

    /// The Reduce Motion setting changed: start again from the current state.
    func motionSettingChanged() {
        applyMood()
    }

    // MARK: Reactions

    /// A moment said by the ball, on top of its mood (which carries on underneath). With Reduce Motion only the
    /// glow changes colour.
    func react(_ reaction: OrbReaction) {
        guard shown else { return }
        let g = r * 0.13
        switch reaction {
        case .started:
            glow(NSColor(NotchMood.working.palette[0]), strength: 0.9, duration: 1.2)
            guard !Motion.reduced else { return }
            let spring = CASpringAnimation(keyPath: "transform.scale")
            spring.fromValue = 0.7
            spring.toValue = 1
            spring.stiffness = 260
            spring.damping = 9
            spring.duration = spring.settlingDuration
            spring.beginTime = time(body)
            body.add(spring, forKey: "reactSpring")
            spreadRing(NSColor(NotchMood.working.palette[0]))
            eyesFor([wideEye(), wideEye()], times: [0, 0.15, 0.75, 1], duration: 1)
        case .stuck:
            glow(NSColor(NotchMood.needsYou.palette[0]), strength: 0.85, duration: 1.6)
            guard !Motion.reduced else { return }
            additive(body, "transform.rotation.z", [0, 0.14, -0.12, 0.09, -0.06, 0.03, 0], duration: 1.3)
            additive(face, "transform.translation.x", [0, -g, g, -g, g * 0.6, 0], duration: 1.5)
        case .error:
            glow(NSColor(Theme.failed), strength: 1, duration: 1.4)
            guard !Motion.reduced else { return }
            additive(body, "transform.translation.x", [0, -3, 3, -2.5, 2.5, -1.5, 1.5, 0], duration: 0.5)
            let base = eyePlan(mood ?? .quiet).base
            eyesFor([base.closed(r * 0.1), base.closed(r * 0.1)], times: [0, 0.1, 0.7, 1], duration: 1.1)
        case .limit:
            glow(NSColor(Theme.limit), strength: 0.8, duration: 2)
            guard !Motion.reduced else { return }
            let heavy = lidded(snap(r * 0.5), cover: 0.68)
            eyesFor([heavy, heavy], times: [0, 0.2, 0.8, 1], duration: 2.4)
            additive(body, "transform.scale", [0, -0.08, -0.05, 0], duration: 2)
            for (key, values) in [("opacity", [0, 0.8, 0.8, 0]), ("transform.translation.y", [0, -Double(r) * 0.6]),
                                  ("transform.scale", [0.6, 1.1])] {
                keyframes(zee, key, values, times: values.count == 4 ? [0, 0.2, 0.6, 1] : nil, duration: 2.2, repeating: false,
                          delay: 0.3, name: "react-" + key)
            }
        case .usage(let share):
            glow(NSColor(Theme.limit), strength: 0.6, duration: 2.2)
            gauge(min(1, max(0, share)), NSColor(Theme.limit))
            guard !Motion.reduced else { return }
            // The line is left of the notch: a glance that way and back
            additive(face, "transform.translation.x", [0, -g, -g, 0], duration: 2, times: [0, 0.15, 0.8, 1])
        case .back:
            glow(NSColor(NotchMood.done.palette[0]), strength: 0.8, duration: 1.6)
            guard !Motion.reduced else { return }
            additive(body, "transform.translation.y", [0, -4, 0, -3, 0], duration: 1, times: [0, 0.22, 0.45, 0.68, 1])
            eyesFor([happyEye(), happyEye()], times: [0, 0.12, 0.8, 1], duration: 1.8)
        }
    }

    private func time(_ layer: CALayer) -> CFTimeInterval { layer.convertTime(CACurrentMediaTime(), from: nil) }

    /// The glow takes a colour for a moment, then goes back to the mood's.
    private func glow(_ color: NSColor, strength: Float, duration: Double) {
        let now = time(orb)
        let back = orb.shadowColor ?? color.cgColor
        let tint = CAKeyframeAnimation(keyPath: "shadowColor")
        tint.values = [color.cgColor, color.cgColor, back]
        tint.keyTimes = [0, 0.6, 1]
        let bright = CAKeyframeAnimation(keyPath: "shadowOpacity")
        bright.values = [strength, strength, orb.shadowOpacity]
        bright.keyTimes = [0, 0.6, 1]
        let group = CAAnimationGroup()
        group.animations = [tint, bright]
        group.duration = duration
        group.beginTime = now
        orb.add(group, forKey: "reactGlow")
    }

    /// Moves added on top of what the layer is already doing (a gaze, a breath), so both show.
    private func additive(_ layer: CALayer, _ key: String, _ values: [Double], duration: Double, times: [NSNumber]? = nil) {
        let animation = CAKeyframeAnimation(keyPath: key)
        animation.values = values
        animation.keyTimes = times
        animation.isAdditive = true
        animation.duration = duration
        animation.timingFunctions = Array(repeating: CAMediaTimingFunction(name: .easeInEaseOut), count: max(values.count - 1, 1))
        animation.beginTime = time(layer)
        layer.add(animation, forKey: "react-" + key)
    }

    /// The eyes take a pose for a while (wide, shut, heavy, smiling), then return to the mood's own.
    private func eyesFor(_ poses: [EyePose], times: [NSNumber], duration: Double) {
        let base = eyePlan(mood ?? .quiet).base
        for (i, eye) in eyes.enumerated() {
            let side = { (pose: EyePose) in i == 0 ? pose : pose.mirrored }
            let animation = CAKeyframeAnimation(keyPath: "path")
            animation.values = [base, poses[0], poses[1], base].map { path(side($0)) }
            animation.keyTimes = times
            animation.timingFunctions = Array(repeating: CAMediaTimingFunction(name: .easeInEaseOut), count: 3)
            animation.duration = duration
            animation.beginTime = time(eye)
            eye.add(animation, forKey: "react")
        }
    }

    private func wideEye() -> EyePose { openEye(snap(r * 0.66)) }

    /// Light spreading out from the ball and fading.
    private func spreadRing(_ color: NSColor) {
        CATransaction.begin()
        CATransaction.setDisableActions(true)
        ring.strokeColor = color.cgColor
        ring.strokeEnd = 1
        CATransaction.commit()
        let grow = CABasicAnimation(keyPath: "transform.scale")
        grow.fromValue = 1
        grow.toValue = 2.3
        let fade = CAKeyframeAnimation(keyPath: "opacity")
        fade.values = [0.9, 0.5, 0]
        fade.keyTimes = [0, 0.5, 1]
        let group = CAAnimationGroup()
        group.animations = [grow, fade]
        group.duration = 0.9
        group.timingFunction = CAMediaTimingFunction(name: .easeOut)
        group.beginTime = time(ring)
        ring.add(group, forKey: "react")
    }

    /// A ring just outside the ball fills to `share`, holds, and fades.
    private func gauge(_ share: Double, _ color: NSColor) {
        CATransaction.begin()
        CATransaction.setDisableActions(true)
        ring.strokeColor = color.cgColor
        CATransaction.commit()
        let size = CABasicAnimation(keyPath: "transform.scale")
        size.fromValue = 1.45
        size.toValue = 1.45
        let fill = CAKeyframeAnimation(keyPath: "strokeEnd")
        fill.values = [0, share, share]
        fill.keyTimes = [0, 0.35, 1]
        let fade = CAKeyframeAnimation(keyPath: "opacity")
        fade.values = [0, 1, 1, 0]
        fade.keyTimes = [0, 0.1, 0.8, 1]
        let group = CAAnimationGroup()
        group.animations = [size, fill, fade]
        group.duration = Motion.reduced ? 2.4 : 2.4
        group.beginTime = time(ring)
        ring.add(group, forKey: "react")
    }

    private func applyMood() {
        guard let mood else { return }
        let now = orb.convertTime(CACurrentMediaTime(), from: nil)
        for layer in [body, orb, tile, core, colors, face, zee] + eyes { layer.removeAllAnimations() }

        // New colours blend in; the glow takes the first one
        CATransaction.begin()
        CATransaction.setAnimationDuration(0.7)
        colors.contents = Self.swirl(mood, side: colors.bounds.width)
        orb.shadowColor = NSColor(mood.palette[0]).cgColor
        core.opacity = mood == .asleep ? 0.3 : 1
        CATransaction.commit()

        if Motion.reduced {
            // Still: the colour and the face say it all
            orb.shadowOpacity = mood == .asleep ? 0.15 : 0.5
            orb.transform = mood == .asleep ? CATransform3DMakeScale(0.84, 0.84, 1) : CATransform3DIdentity
            drawFace(mood, at: now)
            return
        }
        orb.transform = CATransform3DIdentity
        // A change of mood shows in the whole ball: it springs from a little smaller to full size
        if mood != .asleep {
            let pop = CASpringAnimation(keyPath: "transform.scale")
            pop.fromValue = 0.86
            pop.toValue = 1
            pop.stiffness = 320
            pop.damping = 14
            pop.duration = pop.settlingDuration
            pop.beginTime = now
            body.add(pop, forKey: "pop")
        }

        let spin = CABasicAnimation(keyPath: "transform.rotation.z")
        spin.fromValue = 0
        spin.toValue = 2 * Double.pi
        spin.duration = 1 / mood.drift
        spin.repeatCount = .infinity
        spin.beginTime = now
        colors.add(spin, forKey: "spin")

        // Breathing, a heartbeat when it needs you, a bloom when something's done
        switch mood {
        case .quiet: breathe(scale: (0.92, 1.1), glow: (0.2, 0.45), duration: 2)
        case .working: breathe(scale: (0.94, 1.1), glow: (0.4, 0.7), duration: 1.2)
        case .needsYou:
            // A heartbeat for the first ~8 s, then it breathes calmly (1.0–1.05 over 4 s) while it still waits
            let scale: [Double] = [1.02, 1.12, 1.04, 1.1, 1.02, 1.02]
            let glow: [Double] = [0.45, 1, 0.55, 0.9, 0.45, 0.45]
            let times: [NSNumber] = [0, 0.07, 0.17, 0.25, 0.4, 1]
            keyframes(orb, "transform.scale", scale, times: times, duration: 1.2, repeatCount: 7)
            keyframes(orb, "shadowOpacity", glow, times: times, duration: 1.2, repeatCount: 7)
            for (key, range) in [("calmScale", (1.0, 1.05)), ("calmGlow", (0.4, 0.6))] {
                let calm = CABasicAnimation(keyPath: key == "calmScale" ? "transform.scale" : "shadowOpacity")
                calm.fromValue = range.0
                calm.toValue = range.1
                calm.duration = 2
                calm.autoreverses = true
                calm.repeatCount = .infinity
                calm.timingFunction = CAMediaTimingFunction(name: .easeInEaseOut)
                calm.beginTime = now + 8.4
                orb.add(calm, forKey: key)
            }
        case .done:
            keyframes(orb, "transform.scale", [1, 1.25, 0.96, 1.04, 1], times: [0, 0.12, 0.3, 0.45, 1], duration: 1.6, repeating: false)
            keyframes(orb, "shadowOpacity", [1, 1, 0.5], times: [0, 0.4, 1], duration: 2.5, repeating: false)
            orb.shadowOpacity = 0.5
        case .worried:
            let flicker = (0..<16).map { 0.35 + 0.55 * abs(sin(Double($0) * 2.3) * sin(Double($0) * 0.9)) }
            keyframes(orb, "shadowOpacity", flicker, times: nil, duration: 1.3)
        case .asleep: breathe(scale: (0.8, 0.88), glow: (0.1, 0.25), duration: 2.7)
        }

        drawFace(mood, at: now)
    }

    private static var swirls: [NotchMood: CGImage] = [:]

    /// The mood's colours swept round the centre and blurred together, drawn once and then only turned.
    static func swirl(_ mood: NotchMood, side: CGFloat) -> CGImage? {
        if let cached = swirls[mood] { return cached }
        let scale: CGFloat = 3
        let px = Int(side * scale)
        guard let space = CGColorSpace(name: CGColorSpace.sRGB),
              let ctx = CGContext(data: nil, width: px, height: px, bitsPerComponent: 8, bytesPerRow: 0, space: space,
                                  bitmapInfo: CGImageAlphaInfo.premultipliedLast.rawValue) else { return nil }
        let conic = CAGradientLayer()
        conic.type = .conic
        conic.startPoint = CGPoint(x: 0.5, y: 0.5)
        conic.endPoint = CGPoint(x: 1, y: 0.5)
        conic.colors = mood.loop
        conic.frame = CGRect(x: 0, y: 0, width: px, height: px)
        conic.render(in: ctx)
        guard let sharp = ctx.makeImage() else { return nil }
        let extent = CGRect(x: 0, y: 0, width: px, height: px)
        let soft = CIImage(cgImage: sharp).clampedToExtent().applyingGaussianBlur(sigma: Double(side) * 0.3 * Double(scale) / 2)
            .cropped(to: extent)
        let image = CIContext().createCGImage(soft, from: extent)
        swirls[mood] = image
        return image
    }

    // MARK: The eyes

    /// An eye's outline as a top edge and a bottom edge, each running from the left side through the middle to the
    /// right side. Every pose has the same parts, so Core Animation morphs one into another: lids close over the
    /// eye and settle into a new shape, instead of the eye being squashed.
    private struct EyePose {
        /// Heights from the top of the eye's box where each edge meets the left side, the middle and the right side.
        var topLeft: CGFloat, topMid: CGFloat, topRight: CGFloat
        var bottomLeft: CGFloat, bottomMid: CGFloat, bottomRight: CGFloat
        /// 1: the edge curves like the eye's round end; 0: it runs straight, like a lid.
        var topRound: CGFloat = 1
        var bottomRound: CGFloat = 1
        /// Wider than the usual eye (the smiling arch), centred on it.
        var width: CGFloat?

        /// The same pose for the other eye, left and right swapped.
        var mirrored: EyePose {
            EyePose(topLeft: topRight, topMid: topMid, topRight: topLeft, bottomLeft: bottomRight, bottomMid: bottomMid,
                    bottomRight: bottomLeft, topRound: topRound, bottomRound: bottomRound, width: width)
        }

        /// Shut: the upper lid down on the lower one, leaving a thin curve of the eye's bottom.
        func closed(_ thickness: CGFloat) -> EyePose {
            EyePose(topLeft: bottomLeft - thickness, topMid: bottomMid - thickness, topRight: bottomRight - thickness,
                    bottomLeft: bottomLeft, bottomMid: bottomMid, bottomRight: bottomRight, topRound: bottomRound,
                    bottomRound: bottomRound, width: width)
        }

        func path(x: CGFloat, width w: CGFloat) -> CGPath {
            let a = w / 2, k: CGFloat = 0.5523
            func mix(_ p: CGPoint, _ q: CGPoint, _ t: CGFloat) -> CGPoint {
                CGPoint(x: p.x + (q.x - p.x) * t, y: p.y + (q.y - p.y) * t)
            }
            // Between a straight edge (a third of the way along) and a round one (a quarter ellipse)
            func control(_ from: CGPoint, _ to: CGPoint, _ third: CGFloat, round: CGPoint, _ amount: CGFloat) -> CGPoint {
                mix(mix(from, to, third), round, amount)
            }
            let tl = CGPoint(x: x, y: topLeft), tm = CGPoint(x: x + a, y: topMid), tr = CGPoint(x: x + w, y: topRight)
            let br = CGPoint(x: x + w, y: bottomRight), bm = CGPoint(x: x + a, y: bottomMid), bl = CGPoint(x: x, y: bottomLeft)
            let path = CGMutablePath()
            path.move(to: tl)
            path.addCurve(to: tm, control1: control(tl, tm, 1 / 3, round: CGPoint(x: x, y: topLeft + k * (topMid - topLeft)), topRound),
                          control2: control(tl, tm, 2 / 3, round: CGPoint(x: x + a - k * a, y: topMid), topRound))
            path.addCurve(to: tr, control1: control(tm, tr, 1 / 3, round: CGPoint(x: x + a + k * a, y: topMid), topRound),
                          control2: control(tm, tr, 2 / 3, round: CGPoint(x: x + w, y: topRight + k * (topMid - topRight)),
                                            topRound))
            path.addLine(to: br)
            path.addCurve(to: bm, control1: control(br, bm, 1 / 3, round: CGPoint(x: x + w, y: bottomRight + k * (bottomMid - bottomRight)),
                                                    bottomRound),
                          control2: control(br, bm, 2 / 3, round: CGPoint(x: x + a + k * a, y: bottomMid), bottomRound))
            path.addCurve(to: bl, control1: control(bm, bl, 1 / 3, round: CGPoint(x: x + a - k * a, y: bottomMid), bottomRound),
                          control2: control(bm, bl, 2 / 3, round: CGPoint(x: x, y: bottomLeft + k * (bottomMid - bottomLeft)),
                                            bottomRound))
            path.closeSubpath()
            return path
        }
    }

    /// What the eyes do in a mood: their own pose, other poses held for a while, and blinks, over a loop.
    private struct EyePlan {
        var base: EyePose
        var holds: [(from: Double, to: Double, pose: EyePose)] = []
        var blinks: [Double] = []
        var loop: Double = 0
    }

    private var eyeBox: CGSize { CGSize(width: r * 0.3, height: r * 0.8) }
    private var eyeWidth: CGFloat { snap(r * 0.26) }
    private func snap(_ value: CGFloat) -> CGFloat { (value * 2).rounded() / 2 }
    private func path(_ pose: EyePose) -> CGPath {
        let width = pose.width ?? eyeWidth
        return pose.path(x: (eyeBox.width - width) / 2, width: width)
    }

    /// An open eye `height` tall, centred in its box.
    private func openEye(_ height: CGFloat) -> EyePose {
        let a = eyeWidth / 2, top = eyeBox.height / 2 - height / 2, bottom = top + height
        return EyePose(topLeft: top + a, topMid: top, topRight: top + a, bottomLeft: bottom - a, bottomMid: bottom,
                       bottomRight: bottom - a)
    }

    /// The upper lid straight across, covering `cover` of the eye from the top; `tilt` lowers its outer end and
    /// raises its inner end (drawn for the left eye).
    private func lidded(_ height: CGFloat, cover: CGFloat, tilt: CGFloat = 0) -> EyePose {
        var pose = openEye(height)
        let lid = pose.topMid + height * cover
        pose.topLeft = lid + height * tilt
        pose.topMid = lid
        pose.topRight = lid - height * tilt
        pose.topRound = 0
        return pose
    }

    /// Smiling: the lower lid pushes up until only an arch of the eye shows.
    private func happyEye() -> EyePose {
        let top = eyeBox.height / 2 - r * 0.16, band = r * 0.16, legs = r * 0.13
        return EyePose(topLeft: top + legs, topMid: top, topRight: top + legs,
                       bottomLeft: top + legs + band, bottomMid: top + band, bottomRight: top + legs + band, width: snap(r * 0.4))
    }

    private func eyePlan(_ mood: NotchMood) -> EyePlan {
        switch mood {
        case .quiet:
            // Calm: long pauses, blinks at uneven gaps (sometimes twice), and now and then a softer, content look
            let eye = openEye(snap(r * 0.52))
            let soft = lidded(snap(r * 0.52), cover: 0.2)
            return EyePlan(base: eye, holds: [(24, 27, soft), (44, 46.5, soft)],
                           blinks: [2.1, 6.9, 10.4, 10.62, 15.3, 19.8, 23.1, 29.6, 33.4, 33.62, 38.7, 42, 48.3, 52.9, 56.8], loop: 60)
        case .working:
            // Concentrating: every so often the upper lids come down flat while it reads
            let h = snap(r * 0.46)
            return EyePlan(base: openEye(h), holds: [(3.1, 5.3, lidded(h, cover: 0.4))], blinks: [2.2, 7], loop: 9.6)
        case .needsYou:
            return EyePlan(base: openEye(snap(r * 0.64)), blinks: [2.9, 3.12], loop: 3.6)
        case .done:
            return EyePlan(base: happyEye())
        case .worried:
            // Worried: the lids tilt, inner corners up
            return EyePlan(base: lidded(snap(r * 0.48), cover: 0.22, tilt: 0.14), blinks: [2, 3.05, 3.27], loop: 3.6)
        case .asleep:
            return EyePlan(base: openEye(snap(r * 0.5)).closed(r * 0.12))
        }
    }

    /// The face for the mood. The eyes close and open into the mood's shape (or droop shut, falling asleep), then
    /// live in it: lids, blinks, glances, a hop or a slow breath.
    private func drawFace(_ mood: NotchMood, at now: CFTimeInterval) {
        let plan = eyePlan(mood)
        // Where the face looks: down at the work, up at you
        let look: CGFloat = switch mood {
        case .working: r * 0.06
        case .needsYou: -r * 0.05
        default: 0
        }
        CATransaction.begin()
        CATransaction.setDisableActions(true)
        face.position = CGPoint(x: r, y: r + look)
        for (i, eye) in eyes.enumerated() {
            eye.path = path(i == 0 ? plan.base : plan.base.mirrored)
            eye.fillColor = NSColor(white: 0.06, alpha: mood == .asleep ? 0.72 : 0.88).cgColor
        }
        zee.opacity = mood == .asleep && Motion.reduced ? 0.6 : 0
        CATransaction.commit()
        guard !Motion.reduced else { return }

        for (i, eye) in eyes.enumerated() {
            let side = { (pose: EyePose) in i == 0 ? pose : pose.mirrored }
            // In: a quick blink into the new shape, or a slow droop when it falls asleep
            let intro = CAKeyframeAnimation(keyPath: "path")
            if mood == .asleep {
                let awake = openEye(snap(r * 0.52))
                intro.values = [awake, lidded(snap(r * 0.52), cover: 0.55), plan.base].map { path(side($0)) }
                intro.keyTimes = [0, 0.45, 1]
                intro.duration = 2
            } else {
                intro.values = [plan.base.closed(r * 0.06), plan.base].map { path(side($0)) }
                intro.duration = 0.32
            }
            intro.timingFunctions = Array(repeating: CAMediaTimingFunction(name: .easeInEaseOut), count: intro.values!.count - 1)
            intro.beginTime = now
            intro.fillMode = .backwards
            eye.add(intro, forKey: "intro")
            guard plan.loop > 0 else { continue }
            // The right eye blinks a hair after the left
            let track = eyeTrack(plan, side: side, offset: i == 0 ? 0 : 0.025)
            track.beginTime = now + intro.duration
            eye.add(track, forKey: "pose")
        }

        let g = r * 0.13
        switch mood {
        case .quiet:
            gaze([(4, -g, 0), (6.2, 0, 0), (12.5, g * 0.8, -r * 0.04), (14.2, 0, 0), (18, r * 0.03, r * 0.1), (20.6, 0, 0),
                  (27.5, -g * 1.1, r * 0.02), (28.6, g, r * 0.02), (30.2, 0, 0), (36, 0, -r * 0.08), (37.8, 0, 0),
                  (45, -g * 0.6, r * 0.08), (47.5, 0, 0), (53.5, g * 0.7, 0), (55.5, 0, 0)], loop: 60)
        case .working:
            // Reading: hops along a line, a sweep back to the start of the next, four lines and round again
            var points: [(Double, CGFloat, CGFloat)] = []
            for line in 0..<4 {
                let start = 2.4 * Double(line), y = r * 0.02 * CGFloat(line)
                points += [(start + 0.5, -g / 3, y), (start + 1, g / 3, y), (start + 1.5, g, y),
                           (start + 2.2, -g, line == 3 ? 0 : y + r * 0.02)]
            }
            gaze(points, from: (-g, 0), loop: 9.6)
        case .needsYou:
            // Eyes wide, swelling with each heartbeat; a glance down at the message and back up at you
            gaze([(1, -r * 0.12, r * 0.13), (1.9, 0, 0)], loop: 3.6)
            for eye in eyes {
                keyframes(eye, "transform.scale", [1, 1.1, 1.02, 1.07, 1, 1], times: [0, 0.07, 0.17, 0.25, 0.4, 1], duration: 1.2,
                          repeatCount: 6, delay: 0.3)
            }
        case .done:
            // A happy hop of the eyes, then a little giggle now and then
            let hop = r * 0.14
            keyframes(face, "transform.translation.y", [0, -hop, 0, -hop / 2, 0, 0], times: [0, 0.15, 0.35, 0.5, 0.65, 1],
                      duration: 1.2, repeating: false)
            keyframes(face, "transform.translation.y", [0, -hop * 0.5, 0, -hop * 0.3, 0, 0], times: [0, 0.04, 0.08, 0.12, 0.16, 1],
                      duration: 5, delay: 1.5, name: "giggle")
        case .worried:
            // Searching for Claude: one way, the other, back
            gaze([(0.3, -g, 0), (1.5, g, 0), (2.7, 0, 0)], loop: 3.6)
        case .asleep:
            // The closed eyes sink and lift with each slow breath; a z drifts up off the ball
            keyframes(face, "transform.translation.y", [0, r * 0.05, 0], times: nil, duration: 5.4, delay: 2)
            keyframes(zee, "opacity", [0, 0.8, 0.8, 0], times: [0, 0.2, 0.6, 1], duration: 3, delay: 1.5)
            keyframes(zee, "transform.translation.y", [0, -r * 0.6], times: nil, duration: 3, delay: 1.5)
            keyframes(zee, "transform.scale", [0.6, 1.1], times: nil, duration: 3, delay: 1.5)
        }
    }

    /// One eye's poses over the plan's loop. Lids move in a quarter second; a blink shuts in 0.08 s and opens
    /// in 0.16 s, as real eyes do.
    private func eyeTrack(_ plan: EyePlan, side: (EyePose) -> EyePose, offset: Double) -> CAKeyframeAnimation {
        var keys: [(time: Double, pose: EyePose, ease: CAMediaTimingFunctionName)] = [(0, plan.base, .easeInEaseOut)]
        for hold in plan.holds {
            keys += [(hold.from, plan.base, .easeInEaseOut), (hold.from + 0.24, hold.pose, .easeInEaseOut),
                     (hold.to, hold.pose, .easeInEaseOut), (hold.to + 0.24, plan.base, .easeInEaseOut)]
        }
        for blink in plan.blinks.map({ $0 + offset }) {
            let open = plan.holds.first { $0.from + 0.24 <= blink && blink <= $0.to }?.pose ?? plan.base
            keys += [(blink, open, .easeInEaseOut), (blink + 0.08, open.closed(r * 0.06), .easeIn), (blink + 0.24, open, .easeOut)]
        }
        keys.append((plan.loop, plan.base, .easeInEaseOut))
        keys.sort { $0.time < $1.time }
        let track = CAKeyframeAnimation(keyPath: "path")
        track.values = keys.map { path(side($0.pose)) }
        track.keyTimes = keys.map { NSNumber(value: $0.time / plan.loop) }
        track.timingFunctions = keys.dropFirst().map { CAMediaTimingFunction(name: $0.ease) }
        track.duration = plan.loop
        track.repeatCount = .infinity
        return track
    }

    /// Where the eyes look over a loop: quick jumps (a hair past the target, settled by 0.15 s) between held
    /// points, ending where they started. The face carries the eyes; the ball follows a moment later and less far
    /// while its bright core drifts the other way, so it reads as round; looking aside narrows the face a little,
    /// as if the eyes wrap round the ball.
    private func gaze(_ points: [(Double, CGFloat, CGFloat)], from start: (CGFloat, CGFloat) = (0, 0), loop: Double) {
        // Each jump leaves fast and arrives slowly, a hair past the target, then settles back onto it
        let leave = CAMediaTimingFunction(controlPoints: 0.3, 0, 0.15, 1)
        let settle = CAMediaTimingFunction(controlPoints: 0.4, 0, 0.6, 1)
        let rest = CAMediaTimingFunction(name: .linear)
        var times: [Double] = [0], xs = [Double(start.0)], ys = [Double(start.1)], curves: [CAMediaTimingFunction] = []
        for (time, x, y) in points {
            let last = (xs.last!, ys.last!)
            times += [time, time + 0.13, time + 0.3]
            xs += [last.0, last.0 + (Double(x) - last.0) * 1.05, Double(x)]
            ys += [last.1, last.1 + (Double(y) - last.1) * 1.05, Double(y)]
            curves += [rest, leave, settle]
        }
        times.append(loop)
        xs.append(xs.last!)
        ys.append(ys.last!)
        curves.append(rest)
        let keyTimes = times.map { NSNumber(value: $0 / loop) }
        let reach = Double(r) * 0.16
        func move(_ layer: CALayer, _ key: String, _ values: [Double], delay: Double = 0) {
            keyframes(layer, key, values, times: keyTimes, duration: loop, delay: delay, curves: curves)
        }
        move(face, "transform.translation.x", xs)
        move(face, "transform.translation.y", ys)
        move(face, "transform.scale.x", xs.map { 1 - 0.1 * min(abs($0) / reach, 1) })
        move(face, "transform.scale.y", ys.map { 1 - 0.06 * min(abs($0) / reach, 1) })
        move(tile, "transform.translation.x", xs.map { $0 * 0.25 }, delay: 0.09)
        move(tile, "transform.translation.y", ys.map { $0 * 0.25 }, delay: 0.09)
        move(core, "transform.translation.x", xs.map { -$0 * 0.5 }, delay: 0.06)
        move(core, "transform.translation.y", ys.map { -$0 * 0.5 }, delay: 0.06)
    }

    /// Something finished: confetti flies out of the ball, mostly sideways along the island and mostly towards
    /// its middle, spinning and fading within a second or so. Not with Reduce Motion.
    private func burst(from center: CGPoint) {
        guard !Motion.reduced else { return }
        let now = confetti.convertTime(CACurrentMediaTime(), from: nil)
        let colors = (NotchMood.done.palette + NotchMood.working.palette + NotchMood.needsYou.palette).map { NSColor($0).cgColor }
        let inward: CGFloat = center.x < bounds.midX ? 1 : -1
        for (i, bit) in bits.enumerated() {
            let side = i % 4 == 0 ? -inward : inward
            let angle = CGFloat.random(in: -0.6...0.6)
            let distance = side == inward ? CGFloat.random(in: 20...64) : CGFloat.random(in: 12...26)
            let end = CGPoint(x: center.x + side * cos(angle) * distance, y: center.y + sin(angle) * distance * 0.5 + 4)
            let path = CGMutablePath()
            path.move(to: center)
            path.addQuadCurve(to: end, control: CGPoint(x: (center.x + end.x) / 2, y: min(center.y, end.y) - 10))
            CATransaction.begin()
            CATransaction.setDisableActions(true)
            bit.position = center
            bit.backgroundColor = colors.randomElement()
            CATransaction.commit()

            let fly = CAKeyframeAnimation(keyPath: "position")
            fly.path = path
            fly.timingFunction = CAMediaTimingFunction(controlPoints: 0.2, 0.7, 0.4, 1)
            let fade = CAKeyframeAnimation(keyPath: "opacity")
            fade.values = [0, 1, 1, 0]
            fade.keyTimes = [0, 0.08, 0.55, 1]
            let spin = CABasicAnimation(keyPath: "transform.rotation.z")
            let start = Double.random(in: 0...Double.pi)
            spin.fromValue = start
            spin.toValue = start + Double.random(in: 3...9) * (Bool.random() ? 1 : -1)
            let group = CAAnimationGroup()
            group.animations = [fly, fade, spin]
            group.duration = Double.random(in: 0.9...1.4)
            group.beginTime = now + Double.random(in: 0...0.1)
            group.fillMode = .backwards
            bit.add(group, forKey: "burst")
        }
    }

    private func breathe(scale: (Double, Double), glow: (Double, Double), duration: Double) {
        orb.shadowOpacity = Float(glow.0)
        for (key, range) in [("transform.scale", scale), ("shadowOpacity", glow)] {
            let animation = CABasicAnimation(keyPath: key)
            animation.fromValue = range.0
            animation.toValue = range.1
            animation.duration = duration
            animation.autoreverses = true
            animation.repeatCount = .infinity
            animation.timingFunction = CAMediaTimingFunction(name: .easeInEaseOut)
            animation.beginTime = orb.convertTime(CACurrentMediaTime(), from: nil)
            orb.add(animation, forKey: key)
        }
    }

    /// Every move eases in and out, so nothing starts or stops with a jolt. `name` lets two animations of the same
    /// property live side by side (a hop now, a giggle later).
    private func keyframes(_ layer: CALayer, _ key: String, _ values: [Double], times: [NSNumber]?, duration: Double,
                           repeating: Bool = true, repeatCount: Float = .infinity, delay: Double = 0, name: String? = nil,
                           curves: [CAMediaTimingFunction]? = nil) {
        let animation = CAKeyframeAnimation(keyPath: key)
        animation.values = values
        animation.keyTimes = times
        animation.duration = duration
        animation.timingFunctions = curves
            ?? Array(repeating: CAMediaTimingFunction(name: .easeInEaseOut), count: max(values.count - 1, 1))
        if repeating { animation.repeatCount = repeatCount }
        animation.beginTime = layer.convertTime(CACurrentMediaTime(), from: nil) + delay
        layer.add(animation, forKey: name ?? key)
    }
}

/// The working session's line left of the notch ("Trailmap · Edit main.dart"), drawn in Core Animation so a soft
/// shimmer can sweep across it and each new step can slide in, without SwiftUI redrawing anything.
@MainActor
final class ActivityTextView: NSView {
    override func hitTest(_ point: NSPoint) -> NSView? { nil }

    private let stage = CALayer()
    private let current = CATextLayer()
    private let outgoing = CATextLayer()
    private let shimmer = CALayer()
    private let shimmerMask = CATextLayer()
    private let sweep = CAGradientLayer()

    static let font = NSFont.systemFont(ofSize: 11, weight: .semibold)
    private var shownText: NSAttributedString?
    private var origin = CGPoint.zero
    private var shown = false

    override init(frame: NSRect) {
        super.init(frame: frame)
        wantsLayer = true
        alphaValue = 0
        guard let root = layer else { return }
        stage.isGeometryFlipped = true
        root.addSublayer(stage)
        let scale = NSScreen.main?.backingScaleFactor ?? 2
        for text in [current, outgoing, shimmerMask] {
            text.contentsScale = scale
            text.anchorPoint = CGPoint(x: 0, y: 0.5)
            text.truncationMode = .end
        }
        stage.addSublayer(outgoing)
        stage.addSublayer(current)
        // The shimmer: a soft light sweeping across, only where the letters are
        stage.addSublayer(shimmer)
        shimmer.anchorPoint = CGPoint(x: 0, y: 0.5)
        shimmer.mask = shimmerMask
        shimmerMask.anchorPoint = .zero
        shimmer.addSublayer(sweep)
        sweep.startPoint = CGPoint(x: 0, y: 0.5)
        sweep.endPoint = CGPoint(x: 1, y: 0.5)
        sweep.colors = [NSColor.white.withAlphaComponent(0).cgColor, NSColor.white.withAlphaComponent(0.9).cgColor,
                        NSColor.white.withAlphaComponent(0).cgColor]
        outgoing.opacity = 0
    }

    required init?(coder: NSCoder) { nil }

    override func layout() {
        super.layout()
        CATransaction.begin()
        CATransaction.setDisableActions(true)
        stage.frame = bounds
        CATransaction.commit()
    }

    static func attributed(name: String, detail: String?) -> NSAttributedString {
        let text = NSMutableAttributedString(string: name, attributes: [.font: font, .foregroundColor: NSColor(Theme.primary)])
        if let detail {
            text.append(NSAttributedString(string: " · " + detail, attributes: [.font: font, .foregroundColor: NSColor(Theme.secondary)]))
        }
        return text
    }

    /// `origin`: where the line starts (left edge, vertical centre) in this view's coordinates; nil hides it.
    func update(text: NSAttributedString?, origin: CGPoint?, width: CGFloat) {
        let showing = text != nil && origin != nil
        if let text, let origin {
            let height = ceil(Self.font.ascender - Self.font.descender + Self.font.leading) + 1
            let size = CGSize(width: width, height: height)
            CATransaction.begin()
            CATransaction.setDisableActions(true)
            for layer in [current, outgoing] as [CALayer] { layer.bounds = CGRect(origin: .zero, size: size) }
            shimmer.bounds = CGRect(origin: .zero, size: size)
            shimmerMask.frame = CGRect(origin: .zero, size: size)
            sweep.frame = CGRect(x: -80, y: 0, width: 80, height: height)
            if origin != self.origin {
                self.origin = origin
                for layer in [current, outgoing, shimmer] as [CALayer] { layer.position = origin }
            }
            CATransaction.commit()
            if text != shownText {
                let previous = shownText
                shownText = text
                change(to: text, from: shown ? previous : nil)
                startShimmer(width: width, text: text)
            }
        }
        if showing != shown {
            shown = showing
            fadeView(self, in: showing)
            if !showing { shownText = nil }
        }
    }

    func setRunning(_ running: Bool) {
        layer?.setRunning(running)
    }

    /// The Reduce Motion setting changed: stop or allow the shimmer.
    func motionSettingChanged() {
        sweep.removeAllAnimations()
        if shown, let text = shownText { startShimmer(width: current.bounds.width, text: text) }
    }

    /// The old line slides up and out while the new one slides in from below (fades only with Reduce Motion).
    private func change(to text: NSAttributedString, from previous: NSAttributedString?) {
        let plain = NSMutableAttributedString(attributedString: text)
        plain.addAttribute(.foregroundColor, value: NSColor.white, range: NSRange(location: 0, length: plain.length))
        CATransaction.begin()
        CATransaction.setDisableActions(true)
        current.string = text
        shimmerMask.string = plain
        CATransaction.commit()
        guard let previous else { return }
        outgoing.string = previous
        let lift: CGFloat = Motion.reduced ? 0 : 9
        let now = current.convertTime(CACurrentMediaTime(), from: nil)
        func slide(_ layer: CALayer, fromY: CGFloat, toY: CGFloat, fromOpacity: Float, toOpacity: Float,
                   delay: Double, duration: Double) {
            let move = CABasicAnimation(keyPath: "position.y")
            move.fromValue = origin.y + fromY
            move.toValue = origin.y + toY
            let fade = CABasicAnimation(keyPath: "opacity")
            fade.fromValue = fromOpacity
            fade.toValue = toOpacity
            let group = CAAnimationGroup()
            group.animations = [move, fade]
            group.duration = duration
            group.beginTime = now + delay
            group.fillMode = .backwards
            group.timingFunction = CAMediaTimingFunction(name: .easeOut)
            layer.add(group, forKey: "slide")
        }
        // The old line leaves first; the new one follows just behind it, so they barely overlap
        slide(outgoing, fromY: 0, toY: -lift, fromOpacity: 1, toOpacity: 0, delay: 0, duration: 0.18)
        slide(current, fromY: lift, toY: 0, fromOpacity: 0, toOpacity: 1, delay: 0.1, duration: 0.28)
        slide(shimmer, fromY: lift, toY: 0, fromOpacity: 0, toOpacity: 1, delay: 0.1, duration: 0.28)
    }

    /// Two sweeps of light (about 3 s) when a new step arrives, then it holds still: no motion all day.
    private func startShimmer(width: CGFloat, text: NSAttributedString) {
        sweep.removeAnimation(forKey: "shimmer")
        guard !Motion.reduced else { return }
        let run = CABasicAnimation(keyPath: "position.x")
        run.fromValue = -40
        run.toValue = width + 40
        run.duration = 1.2
        run.timingFunction = CAMediaTimingFunction(name: .easeInEaseOut)
        let cycle = CAAnimationGroup()
        cycle.animations = [run]
        cycle.duration = 1.6
        cycle.repeatCount = 2
        cycle.beginTime = sweep.convertTime(CACurrentMediaTime(), from: nil) + 0.2
        sweep.add(cycle, forKey: "shimmer")
    }
}

@MainActor
private func fadeView(_ view: NSView, in shown: Bool) {
    // While paused (an idle WatchMan) a fade would never run and the view would stay as it was: switch at once
    if view.layer?.speed == 0 {
        view.alphaValue = shown ? 1 : 0
        return
    }
    NSAnimationContext.runAnimationGroup { context in
        context.duration = shown ? 0.2 : 0.1
        view.animator().alphaValue = shown ? 1 : 0
    }
}

extension CALayer {
    /// Pauses or resumes every animation in this layer's tree, keeping their place. Pausing first finishes a fade
    /// on this layer itself (its only own animation), so a view fading out doesn't freeze half-visible.
    func setRunning(_ running: Bool) {
        if !running, speed != 0 { removeAllAnimations() }
        if running, speed == 0 {
            let paused = timeOffset
            speed = 1
            timeOffset = 0
            beginTime = 0
            beginTime = convertTime(CACurrentMediaTime(), from: nil) - paused
        } else if !running, speed != 0 {
            let paused = convertTime(CACurrentMediaTime(), from: nil)
            speed = 0
            timeOffset = paused
        }
    }
}

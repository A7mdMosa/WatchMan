import SwiftUI
import WatchManCore

/// A fixed, transparent canvas holding the black island. The island morphs between its
/// closed strip, the hover preview and the opened list with one spring, like the Dynamic Island.
struct NotchView: View {
    let model: NotchModel
    let store: SessionStore
    @Environment(\.accessibilityReduceMotion) private var reduceMotion
    @State private var hoveredZone: NotchZone?
    @State private var headerHeight: CGFloat = 26
    /// Files are being dragged over the island.
    @State private var dropTargeted = false

    /// Slides in from the top, or only fades with Reduce Motion.
    private var dropIn: AnyTransition {
        reduceMotion ? .opacity : .asymmetric(insertion: .move(edge: .top).combined(with: .opacity), removal: .opacity)
    }

    var body: some View {
        ZStack(alignment: .topLeading) {
            island
                .frame(width: model.islandWidth, height: model.islandHeight, alignment: .top)
                .offset(x: model.islandX)

            // What just happened: the newest message grows out of the island (drawn inside it), others below
            if model.mode == .collapsed, store.toasts.count > 1 {
                VStack(spacing: NotchModel.toastSpacing) {
                    ForEach(store.toasts.dropFirst()) { toast in
                        ToastView(toast: toast, store: store) { model.onShowSession(toast.sessionId, false) }
                            .frame(width: NotchModel.toastWidth, height: toast.height)
                            .transition(dropIn)
                    }
                }
                .offset(x: (model.panelWidth - NotchModel.toastWidth) / 2, y: model.islandHeight + NotchModel.toastTop)
            } else if let moment = pillActivity {
                // "Sent" drops down below the notch when it can't show beside it
                TickerPill(activity: moment)
                    .frame(width: NotchModel.pillWidth)
                    .offset(x: (model.panelWidth - NotchModel.pillWidth) / 2, y: model.notchHeight + 5)
                    .transition(dropIn)
            }
        }
        .frame(maxWidth: .infinity, maxHeight: .infinity, alignment: .topLeading)
        .animation(NotchModel.adjust, value: pillActivity)
        .animation(NotchModel.open, value: store.toasts)
    }

    /// What the drop-down pill shows: only while closed, only when the left side has no room for it.
    private var pillActivity: NotchActivity? {
        guard model.mode == .collapsed, model.ears.left.activity == nil, store.toasts.isEmpty else { return nil }
        return store.feedback
    }

    private var shape: NotchShape {
        NotchShape(shoulder: model.shapeShoulder, radius: model.shapeRadius)
    }

    private var island: some View {
        ZStack(alignment: .topLeading) {
            // The strip's row stays put while the island grows under it, so hovering doesn't flicker
            if model.mode != .expanded {
                ears
                    .transition(.opacity.animation(NotchModel.fade))
            }
            if model.mode == .collapsed, let top = store.toasts.first {
                ToastView(toast: top, store: store, inIsland: true) { model.onShowSession(top.sessionId, false) }
                    .frame(height: top.height)
                    .padding(.top, model.notchHeight)
                    .padding(.horizontal, 8)
                    .id(top.id)
                    .arrive(1)
                    .transition(.opacity.animation(.easeOut(duration: 0.12)))
            }
            if model.mode == .peek {
                TopSessionsView(store: store, model: model)
                    .padding(.top, model.notchHeight + 6)
                    .padding(.horizontal, 12)
                    .transition(.asymmetric(insertion: .opacity.animation(NotchModel.fade.delay(0.04)),
                                            removal: .opacity.animation(NotchModel.fade)))
            }
            if model.mode == .expanded, headerInNotch {
                notchHeader
                    .frame(width: model.islandWidth, height: model.notchHeight)
                    .transition(.asymmetric(insertion: .opacity.animation(NotchModel.fade.delay(0.04)),
                                            removal: .opacity.animation(NotchModel.fade)))
            }
            if model.mode == .expanded {
                expandedContent
                    .padding(.top, model.notchHeight + 4)
                    .padding(.horizontal, 10)
                    .transition(.asymmetric(insertion: .opacity.animation(NotchModel.fade.delay(0.04)),
                                            removal: .opacity.animation(NotchModel.fade)))
            }
        }
        .frame(width: model.islandWidth, height: model.islandHeight, alignment: .topLeading)
        .clipShape(shape)
        .background {
            ZStack {
                shape
                    .fill(Color.black)
                    .shadow(color: .black.opacity(model.mode == .expanded ? 0.55 : model.mode == .peek ? 0.35 : 0),
                            radius: model.mode == .collapsed ? 0 : 18, y: 8)
            }
        }
        // A faint rim once it drops below the menu bar, so the edge reads on dark wallpapers
        .overlay(
            shape.stroke(LinearGradient(colors: [.white.opacity(0), .white.opacity(0.10)], startPoint: .top, endPoint: .bottom),
                         lineWidth: 1)
                .opacity(model.mode == .collapsed ? 0 : 1)
        )
        .contentShape(shape)
        .onTapGesture { if model.mode != .expanded { model.onTap() } }
        // Drop files or a screenshot on the island: pick the session they go to
        .onDrop(of: [.fileURL, .image], isTargeted: $dropTargeted) { providers in
            Attachments.paths(from: providers) { paths in model.onDropFiles(paths) }
            return true
        }
        .overlay(alignment: .top) {
            if dropTargeted, model.mode == .collapsed {
                HStack(spacing: 6) {
                    Image(systemName: "tray.and.arrow.down.fill").font(.system(size: 11, weight: .semibold))
                    Text("Drop to send to a session").font(.system(size: 11.5, weight: .semibold))
                }
                .foregroundStyle(Theme.unseen)
                .frame(width: model.islandWidth, height: model.notchHeight)
                .background(Color.black)
                .offset(x: model.islandX - (model.panelWidth - model.islandWidth) / 2)
                .allowsHitTesting(false)
            }
        }
        .overlay(shape.stroke(Theme.unseen, lineWidth: 1.5).opacity(dropTargeted ? 1 : 0).allowsHitTesting(false))
    }

    /// Left side, the notch gap, right side. Each part is its own click target, softly lit under the pointer.
    private var ears: some View {
        HStack(spacing: 0) {
            Color.clear.frame(width: model.barOffset + NotchModel.shoulder)
            LeftEar(layout: model.ears.left, model: model)
                .frame(width: model.ears.left.width, alignment: .leading)
                .zone(.left, hovered: $hoveredZone)
                .onTapGesture { model.onTapLeft() }
                .help(model.ears.left.activity.map { "Show \($0.name)" } ?? "")
            Color.clear
                .frame(width: model.notchWidth)
                .contentShape(Rectangle())
                .onTapGesture { model.onTap() }
                .help("Show all sessions")
            RightEar(layout: model.ears.right, model: model)
                .frame(width: model.ears.right.width, alignment: .trailing)
                .zone(.right, hovered: $hoveredZone)
                .onTapGesture { model.onTapRight() }
                .help(model.ears.right.waiting + model.ears.right.fresh > 0 ? "Show what needs you and what's new" : "Show all sessions")
            Spacer(minLength: 0)
        }
        .frame(height: model.notchHeight)
    }

    // MARK: - Expanded

    /// On a screen with a notch the panel's header sits in the notch row, around the camera, and saves a row.
    private var headerInNotch: Bool { model.hasNotch && model.notchWidth > 60 }

    /// The notch row while open: counts on the left of the camera, actions on the right; on a session's page,
    /// the way back on the left and Open, ⋯ and × on the right.
    private var notchHeader: some View {
        let side = max(0, (model.islandWidth - model.notchWidth) / 2)
        let page = store.pageId.flatMap { store.sessions[$0] }
        return HStack(spacing: 0) {
            Group {
                if page != nil || store.otherPage != nil {
                    BackToSessions(store: store, title: "All sessions")
                } else {
                    HStack(spacing: 10) {
                        MemoryChip(store: store)
                        PanelSummary(store: store)
                    }
                }
            }
            // Room for the ball at the far left
            .frame(width: max(0, side - 12 - NotchModel.openOrbInset * 2), alignment: .trailing)
            .padding(.leading, NotchModel.openOrbInset * 2)
            .padding(.trailing, 12)
            Color.clear.frame(width: model.notchWidth)
            Group {
                if let page {
                    PageControls(session: page, store: store, close: { model.onClose() })
                } else if store.otherPage != nil {
                    HStack {
                        Spacer()
                        IconButton(symbol: "xmark", help: "Close (Esc)") { model.onClose() }
                    }
                } else {
                    panelTools
                }
            }
            .frame(width: max(0, side - 12 - 14), alignment: .leading)
            .padding(.leading, 12)
            .padding(.trailing, 14)
        }
        .arrive(0)
    }

    /// + New and the icon buttons; the less used ones drop out when the panel is narrow.
    private var panelTools: some View {
        let full = HStack(spacing: 6) {
            NewSessionButton(store: store)
            Spacer(minLength: 0)
            windowButton
            muteButton
            keyboardHint
            IconButton(symbol: "gauge.with.dots.needle.33percent", help: "System: memory, leftover processes, tokens and the Dev Log") {
                store.otherPage = .system
            }
            pinButton
            IconButton(symbol: "gearshape", help: "Settings") { model.onSettings() }
            IconButton(symbol: "xmark", help: "Close (Esc)") { model.onClose() }
        }
        let small = HStack(spacing: 6) {
            NewSessionButton(store: store)
            Spacer(minLength: 0)
            windowButton
            muteButton
            pinButton
            IconButton(symbol: "gearshape", help: "Settings") { model.onSettings() }
            IconButton(symbol: "xmark", help: "Close (Esc)") { model.onClose() }
        }
        return ViewThatFits(in: .horizontal) { full; small }
    }

    /// Everything in a normal window (with a Dock icon while it's open).
    private var windowButton: some View {
        IconButton(symbol: "macwindow", help: "Open the WatchMan window") {
            NotificationCenter.default.post(name: .watchManOpenWindow, object: nil)
        }
    }

    /// Sounds on or off, right in the panel.
    private var muteButton: some View {
        let on = AppSettings.shared.soundEnabled
        return IconButton(symbol: on ? "speaker.wave.2.fill" : "speaker.slash.fill",
                          help: on ? "Mute: no sounds (messages still show)" : "Unmute: sounds back on",
                          tint: on ? Theme.secondary : Theme.needsYou) {
            AppSettings.shared.soundEnabled.toggle()
        }
    }

    private var keyboardHint: some View {
        Image(systemName: "keyboard")
            .font(.system(size: 10, weight: .semibold))
            .foregroundStyle(Theme.faint)
            .frame(width: 20, height: 20)
            .help("Keys: \(AppSettings.shared.hotKeyLabel) go through what's waiting · ↑↓ move · 1–9 jump · ↩ the chat · ⌘↩ Allow · ⌘⌫ Deny · O open in the terminal · R reply · ⇥ next waiting · Esc back")
            .accessibilityLabel("Keyboard shortcuts")
    }

    private var pinButton: some View {
        IconButton(symbol: model.pinned ? "pin.fill" : "pin",
                   help: model.pinned ? "Unpin: close normally again" : "Pin: stay open until you close it",
                   tint: model.pinned ? Theme.needsYou : Theme.secondary) {
            model.pinned.toggle()
        }
    }

    /// The list's height: yours (drag the handle), never more than the screen has room for, so the bottom
    /// can't be cut off. A session's page fits its content, up to the room there is.
    private var listHeight: CGFloat {
        // The island ends 8 pt below its content; the header row (unless it's in the notch row), the gaps,
        // the handle and the bottom padding
        let header = headerInNotch ? 0 : headerHeight + 10
        let chrome = model.notchHeight + 8 + header + 6 + (store.pageOpen ? 0 : 10 + 12)
        let room = model.maxIslandHeight - chrome
        return store.pageOpen ? max(240, room) : min(CGFloat(AppSettings.shared.listHeight), max(160, room))
    }

    private var expandedContent: some View {
        VStack(alignment: .leading, spacing: 10) {
            // No notch (an external display): a normal header row
            if !headerInNotch {
                HStack(spacing: 8) {
                    if let page = store.pageId.flatMap({ store.sessions[$0] }) {
                        BackToSessions(store: store, title: "All sessions")
                        Spacer()
                        PageControls(session: page, store: store, close: { model.onClose() })
                    } else if store.otherPage != nil {
                        BackToSessions(store: store, title: "All sessions")
                        Spacer()
                        IconButton(symbol: "xmark", help: "Close (Esc)") { model.onClose() }
                    } else {
                        Text("WatchMan").font(.system(size: 13, weight: .bold)).foregroundStyle(Theme.primary)
                        MemoryChip(store: store)
                        PanelSummary(store: store)
                        Spacer()
                        panelTools.frame(maxWidth: 260)
                    }
                }
                .onGeometryChange(for: CGFloat.self) { $0.size.height } action: { headerHeight = $0 }
                .arrive(0)
            }
            SessionListView(store: store, maxHeight: listHeight)
            if !store.pageOpen { ResizeHandle().arrive(8) }
        }
        .padding(.horizontal, 16)
        .padding(.bottom, 6)
        .fixedSize(horizontal: false, vertical: true)
        .onGeometryChange(for: CGFloat.self) { $0.size.height } action: { height in
            model.expandedContentHeight = height
            model.onContentHeight()
        }
    }
}

struct ResizeHandle: View {
    @State private var startHeight: Double?
    @State private var hovering = false

    var body: some View {
        Capsule()
            .fill(Color.white.opacity(hovering ? 0.35 : 0.15))
            .frame(width: 44, height: 4)
            .frame(maxWidth: .infinity)
            .frame(height: 12)
            .contentShape(Rectangle())
            .onHover { inside in
                hovering = inside
                if inside { NSCursor.resizeUpDown.push() } else { NSCursor.pop() }
            }
            .gesture(
                DragGesture(minimumDistance: 1, coordinateSpace: .global)
                    .onChanged { value in
                        let settings = AppSettings.shared
                        let start = startHeight ?? settings.listHeight
                        startHeight = start
                        // Dragging down makes it taller
                        settings.listHeight = min(900, max(160, start + value.translation.height))
                    }
                    .onEnded { _ in startHeight = nil }
            )
            .help("Drag to resize")
    }
}

/// What the closed notch shows on each side, fitted to the free menu bar space.
/// Left: what is happening (one line). Right: status (the working ring and the counts).
@MainActor
enum NotchEars {
    struct Left: Equatable {
        var orb = false         // at the outer edge, before the line: WatchMan's usual place
        var activity: NotchActivity?
        var useShort = false
        var width: CGFloat = 0
        var text: String? { activity.map { useShort ? $0.short : $0.text } }
    }

    struct Right: Equatable {
        var waiting = 0
        var fresh = 0
        /// Subagents at work across sessions: one small dot each (up to four).
        var agents = 0
        var orb = false         // only when the left side has no room for it
        var width: CGFloat = 0
    }

    struct Layout: Equatable {
        var left = Left()
        var right = Right()
        /// The line the left side would show, even when it has no room for it.
        var activity: NotchActivity?
        var mood = NotchMood.asleep
    }

    /// The orb's slot (the tile is 16 pt; its glow spills a little past it).
    static let orbWidth: CGFloat = 18
    static let gap: CGFloat = 6
    /// Padding at the outer end of each side (inside the strip's rounded corner) and next to the notch.
    static let outerPadding: CGFloat = 11
    static let innerPadding: CGFloat = 6
    static let font = NSFont.systemFont(ofSize: 11, weight: .semibold)
    static let digitWidth: CGFloat = 7

    static func textWidth(_ text: String) -> CGFloat {
        ceil((text as NSString).size(withAttributes: [.font: font]).width)
    }

    static func agentDotsWidth(_ count: Int) -> CGFloat { CGFloat(min(count, 4)) * 7 - 2 }

    static func countWidth(_ count: Int) -> CGFloat { 12 + 2 + CGFloat(String(count).count) * digitWidth }

    static func width(of right: Right) -> CGFloat {
        var items: [CGFloat] = []
        if right.waiting > 0 { items.append(countWidth(right.waiting)) }
        if right.fresh > 0 { items.append(countWidth(right.fresh)) }
        if right.agents > 0 { items.append(agentDotsWidth(right.agents)) }
        if right.orb { items.append(orbWidth) }
        guard !items.isEmpty else { return 0 }
        return items.reduce(0, +) + CGFloat(items.count - 1) * gap + innerPadding + outerPadding
    }

    /// `leftSpace` is nil when the app menus can't be measured (no Accessibility permission).
    static func layout(_ store: SessionStore, leftSpace: CGFloat?, rightSpace: CGFloat, rotation: Int = 0, now: Date = Date(),
                       problem: String? = nil,
                       left leftChoice: AppSettings.LeftContent = .automatic,
                       right rightChoice: AppSettings.RightContent = .automatic) -> Layout {
        let leftSpace = leftChoice == .nothing ? 0 : leftSpace
        let rightSpace = rightChoice == .nothing ? 0 : rightSpace
        let sessions = store.ordered
        // While a message shows below the notch it says the same as the counts: they step aside
        let counting = store.toasts.isEmpty
        let waiting = counting ? sessions.filter { $0.status.isNeedsYou }.count : 0
        let fresh = counting ? sessions.filter(\.isUnseenResult).count : 0
        let busy = NotchActivity.working(in: sessions)
        var layout = Layout()
        // The left line steps aside too while a message shows: the message says it
        layout.activity = counting
            ? NotchActivity.pick(sessions, feedback: store.feedback, problem: problem, now: now, rotation: rotation, name: { $0.label })
            : nil
        layout.mood = NotchMood.pick(sessions, problem: problem != nil, now: now)

        // The orb is WatchMan's presence: always there, small and dim when asleep. It sits on the left, beside
        // the line it speaks and where it is in the open panel; on the right only when the left has no room.
        let orbLeft = leftSpace.map { leftChoice != .nothing && orbWidth + innerPadding + outerPadding <= $0 } ?? false
        let orbRight = !orbLeft && leftChoice != .ring

        // Right: needs-you count, new results, subagents (and the orb when it couldn't go left); drop from the
        // least important until it fits.
        let agents = store.subagentCount
        let full = Right(waiting: waiting, fresh: fresh, agents: agents, orb: orbRight)
        let options = [full, Right(waiting: waiting, fresh: fresh, orb: full.orb), Right(waiting: waiting, orb: full.orb),
                       Right(waiting: waiting, fresh: fresh), Right(waiting: waiting)]
        for var option in options where !(option == Right()) {
            option.width = width(of: option)
            if option.width <= rightSpace {
                layout.right = option
                break
            }
        }

        // Left: the orb, then the activity line
        if let leftSpace {
            let orb = orbLeft
            let orbPart = orb ? orbWidth + gap : 0
            let room = leftSpace - orbPart - innerPadding - outerPadding
            if leftChoice == .automatic, let activity = layout.activity {
                // Rotating working lines share one width, so the strip doesn't resize every few seconds
                let lines = activity.kind == .working ? busy.map { NotchActivity.working($0, name: $0.label) } : [activity]
                let fits = lines.map { line -> (short: Bool, width: CGFloat)? in
                    if textWidth(line.text) <= room { return (false, textWidth(line.text)) }
                    if textWidth(line.short) <= room { return (true, textWidth(line.short)) }
                    return nil
                }
                let shown = fits[lines.firstIndex { $0.sessionId == activity.sessionId } ?? 0]
                if let shown {
                    var textWidth = fits.compactMap { $0?.width }.max() ?? shown.width
                    // Small steps in width as the step text changes, so the edge doesn't twitch
                    textWidth = min(room, ceil(textWidth / 12) * 12)
                    layout.left = Left(orb: orb, activity: activity, useShort: shown.short,
                                       width: orbPart + textWidth + innerPadding + outerPadding)
                }
            }
            if layout.left.activity == nil, orb, orbWidth + innerPadding + outerPadding <= leftSpace {
                layout.left = Left(orb: true, width: orbWidth + innerPadding + outerPadding)
            }
        }

        // Balance: the shorter side grows to match, where the menu bar has room, so the strip sits centred
        let target = max(layout.left.width, layout.right.width)
        if let leftSpace, leftChoice != .nothing, target > 0 { layout.left.width = max(layout.left.width, min(target, leftSpace)) }
        if rightChoice != .nothing, target > 0 { layout.right.width = max(layout.right.width, min(target, rightSpace)) }
        return layout
    }
}

/// Left of the notch: what's going on, from the outer edge in.
struct LeftEar: View {
    let layout: NotchEars.Left
    let model: NotchModel
    @Environment(\.accessibilityReduceMotion) private var reduceMotion

    var body: some View {
        HStack(spacing: NotchEars.gap) {
            if layout.orb { OrbSlot(model: model) }
            if let activity = layout.activity {
                line(activity)
                    // The working line is drawn in front, shimmering (ActivityTextView); this keeps its place
                    .opacity(activity.kind == .working ? 0 : 1)
                    .id(layout.text)
                    .transition(reduceMotion ? .opacity
                                : .asymmetric(insertion: .move(edge: .bottom).combined(with: .opacity),
                                              removal: .move(edge: .top).combined(with: .opacity)))
            }
        }
        .padding(.leading, NotchEars.outerPadding)
        .padding(.trailing, NotchEars.innerPadding)
        .frame(maxHeight: .infinity)
        .clipped()
        .animation(NotchModel.adjust, value: layout.text)
    }

    @ViewBuilder
    private func line(_ activity: NotchActivity) -> some View {
        let text = layout.useShort ? activity.short : activity.text
        HStack(spacing: 4) {
            if activity.kind == .feedback {
                Image(systemName: "checkmark.circle.fill")
                    .font(.system(size: 10.5, weight: .semibold))
                    .foregroundStyle(Theme.working)
            } else if case .news(let tone) = activity.kind {
                Image(systemName: Self.symbol(tone))
                    .font(.system(size: 9.5, weight: .bold))
                    .foregroundStyle(Self.color(tone))
            }
            if activity.kind == .working, !layout.useShort, text.hasPrefix(activity.name) {
                // The name stands out; the step is quieter
                let rest = String(text.dropFirst(activity.name.count))
                Text("\(Text(activity.name).foregroundStyle(Theme.primary))\(Text(rest).foregroundStyle(Theme.secondary))")
            } else {
                Text(text).foregroundStyle(color(activity.kind))
            }
        }
        .font(.system(size: 11, weight: .semibold))
        .lineLimit(1)
        .fixedSize()
    }

    private func color(_ kind: NotchActivity.Kind) -> Color {
        switch kind {
        case .needsYou: Theme.needsYou
        case .finished: Theme.unseen
        case .working, .feedback: Theme.primary
        case .problem, .failed: Theme.failed
        case .limited: Theme.limit
        case .news(let tone): Self.color(tone)
        }
    }

    static func color(_ tone: NotchActivity.Tone) -> Color {
        switch tone {
        case .started: Theme.working
        case .finished, .info: Theme.unseen
        case .warning: Theme.needsYou
        case .error: Theme.failed
        case .limit: Theme.limit
        }
    }

    static func symbol(_ tone: NotchActivity.Tone) -> String {
        switch tone {
        case .started: "play.fill"
        case .finished: "checkmark.circle.fill"
        case .warning: "exclamationmark.triangle.fill"
        case .error: "xmark.octagon.fill"
        case .limit: "gauge.with.dots.needle.67percent"
        case .info: "sun.horizon.fill"
        }
    }
}

/// Right of the notch: how many need you, how many are new, and the working ring at the outer edge.
struct RightEar: View {
    let layout: NotchEars.Right
    let model: NotchModel

    var body: some View {
        HStack(spacing: NotchEars.gap) {
            if layout.waiting > 0 { count(layout.waiting, "exclamationmark.circle.fill", Theme.needsYou) }
            if layout.fresh > 0 { count(layout.fresh, "checkmark.circle.fill", Theme.unseen) }
            if layout.agents > 0 {
                HStack(spacing: 2) {
                    ForEach(0..<min(layout.agents, 4), id: \.self) { _ in
                        Circle().fill(Theme.primary.opacity(0.75)).frame(width: 5, height: 5)
                    }
                }
                .help("\(layout.agents) subagent\(layout.agents == 1 ? "" : "s") at work")
            }
            if layout.orb { OrbSlot(model: model) }
        }
        .padding(.leading, NotchEars.innerPadding)
        .padding(.trailing, NotchEars.outerPadding)
        .fixedSize()
        .animation(NotchModel.adjust, value: layout)
    }

    private func count(_ value: Int, _ symbol: String, _ color: Color) -> some View {
        HStack(spacing: 2) {
            Image(systemName: symbol).font(.system(size: 11))
            Text("\(value)")
                .font(.system(size: 11, weight: .semibold, design: .rounded))
                .monospacedDigit()
                .contentTransition(.numericText(value: Double(value)))
                .fixedSize()
        }
        .foregroundStyle(color)
    }
}

/// Where WatchMan's orb goes. It's drawn by Core Animation in front of the island (`OrbView`), so it moves
/// without SwiftUI redrawing anything.
struct OrbSlot: View {
    let model: NotchModel

    var body: some View {
        Color.clear.frame(width: NotchEars.orbWidth, height: model.notchHeight)
    }
}

/// A message below the notch. Clicking it opens the session's page; Allow / Deny or Claude's options answer
/// right there.
struct ToastView: View {
    let toast: SessionStore.Toast
    let store: SessionStore
    /// Drawn inside the island, which is its background; otherwise a pill of its own below it.
    var inIsland = false
    let open: () -> Void
    @State private var hovering = false

    private var look: (symbol: String, tint: Color, title: String, detail: String) {
        switch toast.kind {
        case .started(let prompt): ("play.circle.fill", Theme.working, "\(toast.name) started", prompt ?? "Working on it")
        case .permission(let approval) where approval.isQuestion:
            ("questionmark.bubble.fill", Theme.needsYou, "\(toast.name) asks", approval.title)
        case .permission(let approval) where approval.isPlan:
            ("list.bullet.clipboard.fill", Theme.needsYou, "\(toast.name)'s plan is ready", approval.title)
        case .permission(let approval):
            ("hand.raised.fill", Theme.needsYou, "\(toast.name) wants to \(approval.kind == .command ? "run" : approval.kind == .other ? "use \(approval.tool)" : "edit")",
             approval.command ?? approval.fileName ?? approval.detail)
        case .question(let text, _): ("questionmark.bubble.fill", Theme.unseen, "\(toast.name) asks", text)
        case .finished(let text): ("checkmark.circle.fill", Theme.unseen, "\(toast.name) finished", text)
        case .brief(let text, let tone): (LeftEar.symbol(tone), LeftEar.color(tone), text, "")
        case .finishedMany(let names):
            ("checkmark.circle.fill", Theme.unseen, "\(names.count) finished", ListFormatter.localizedString(byJoining: names))
        case .stuck(let text): ("exclamationmark.triangle.fill", Theme.needsYou, "\(toast.name) may be stuck", text)
        case .failed(let text): ("xmark.octagon.fill", Theme.failed, "\(toast.name) stopped with an error", text)
        case .limit(let resets):
            ("hourglass", Theme.limit, "\(toast.name) hit the usage limit",
             resets.map { "Resets \($0). Retry then, or keep it for later." } ?? "Retry once it resets.")
        case .usage(let window, let percent, let resets):
            ("gauge.with.dots.needle.67percent", percent >= 90 ? Theme.failed : Theme.limit, "\(window) usage at \(percent)%",
             resets.map { "Resets \($0). Claude pauses at 100% until then." } ?? "Claude pauses at 100% until it resets.")
        case .away(let finished, let waiting, let stuck):
            ("sun.horizon.fill", waiting > 0 ? Theme.needsYou : Theme.unseen, "While you were away",
             [finished > 0 ? "\(finished) finished" : nil, waiting > 0 ? "\(waiting) need you" : nil,
              stuck > 0 ? "\(stuck) may be stuck" : nil].compactMap { $0 }.joined(separator: " · "))
        }
    }

    /// About what two monospaced lines hold; a longer command would be cut, so it's reviewed on the page.
    static let fullyShown = 70

    private var isPermission: Bool {
        if case .permission(let approval) = toast.kind { return !approval.isQuestion && !approval.isPlan }
        return false
    }

    /// A question or a plan: plain words on two lines, not a command.
    private var isQuestion: Bool {
        if case .permission(let approval) = toast.kind { return approval.isQuestion || approval.isPlan }
        return false
    }

    var body: some View {
        let look = look
        HStack(spacing: 11) {
            Image(systemName: look.symbol).font(.system(size: 16)).foregroundStyle(look.tint)
            VStack(alignment: .leading, spacing: 2) {
                Text(look.title).font(.system(size: 12, weight: .semibold)).foregroundStyle(Theme.primary).lineLimit(1)
                if isPermission {
                    // The exact command, on up to two lines, so you know what you're allowing
                    Text(look.detail)
                        .font(.system(size: 11.5, design: .monospaced))
                        .foregroundStyle(Theme.primary.opacity(0.85))
                        .lineLimit(2)
                        .truncationMode(.middle)
                        .help(look.detail)
                } else if !look.detail.isEmpty {
                    Text(look.detail).font(.system(size: 11.5)).foregroundStyle(isQuestion ? Theme.primary.opacity(0.85) : Theme.secondary)
                        .lineLimit(isQuestion ? 2 : 1)
                        .help(look.detail)
                }
            }
            .layoutPriority(1)
            Spacer(minLength: 4)
            HStack(spacing: 6) { buttons(tint: look.tint) }
                .fixedSize()
        }
        .padding(.horizontal, 12)
        .frame(maxHeight: .infinity)
        .background {
            ZStack {
                if !inIsland { RoundedRectangle(cornerRadius: 14, style: .continuous).fill(Color.black) }
                // The state's colour washing up from below, in place of a coloured outline
                RadialGradient(colors: [look.tint.opacity(hovering ? 0.34 : 0.26), .clear], center: UnitPoint(x: 0.5, y: 1.5),
                               startRadius: 0, endRadius: 300)
                    .clipShape(RoundedRectangle(cornerRadius: 14, style: .continuous))
            }
        }
        // The running-out line only where time matters: a prompt the terminal takes back when it ends
        .overlay(alignment: .bottomLeading) { if case .permission = toast.kind { countdown } }
        .shadow(color: .black.opacity(inIsland ? 0 : 0.4), radius: 10, y: 4)
        .contentShape(RoundedRectangle(cornerRadius: 14))
        .onTapGesture(perform: open)
        .onHover { hovering = $0 }
        .accessibilityElement(children: .contain)
        .accessibilityLabel("\(look.title): \(look.detail)")
        .modifier(ApprovalAccessibility(session: store.sessions[toast.sessionId] ?? Session(id: toast.sessionId, cwd: "", host: .other, now: Date()),
                                        store: store, active: isPermission && store.hasPendingPrompt(toast.sessionId)))
    }

    /// A thin line that runs out over a timed message's last ten seconds (frozen while the pointer is on it).
    /// It only ticks during those seconds.
    private var countdown: some View {
        let start = toast.expires.addingTimeInterval(-10)
        let ticks = stride(from: 0.0, through: 10.0, by: 0.1).map { start.addingTimeInterval($0) }
        return TimelineView(.explicit(ticks)) { context in
            let left = store.timeLeft(toast, now: context.date)
            GeometryReader { geo in
                if left < 10, left > 0 {
                    Rectangle().fill(Color.white.opacity(0.35))
                        .frame(width: max(0, (geo.size.width - 24) * CGFloat(left / 10)), height: 2)
                        .offset(x: 12, y: geo.size.height - 3)
                }
            }
        }
        .allowsHitTesting(false)
    }

    @ViewBuilder
    private func buttons(tint: Color) -> some View {
        let session = store.sessions[toast.sessionId]
        switch toast.kind {
        case .permission(let approval) where store.hasPendingPrompt(toast.sessionId) && approval.isQuestion:
            // Claude's question: its first choices right here, the rest on the page
            if let question = approval.simpleQuestion, let session, question.options.count <= 3,
               question.options.allSatisfy({ $0.label.count <= 16 }) {
                QuestionChoices(session: session, question: question, store: store, limit: 3) { store.dismissToast(toast.id) }
            } else {
                button("Answer", tint, dismiss: false) { open() }
            }
        case .permission(let approval) where store.hasPendingPrompt(toast.sessionId):
            if approval.needsReview {
                // Deletes, force-pushes, runs as root, or too long to read here: look at it on the page first
                button("Review", tint, dismiss: false) { open() }
            } else {
                // No key hints: the notch doesn't have the keyboard while a message shows
                AllowButton { store.respond(to: toast.sessionId, with: .allow); store.dismissToast(toast.id) }
                DenyButton { store.respond(to: toast.sessionId, with: .deny); store.dismissToast(toast.id) }
            }
        case .limit where session?.host.canSend == true:
            // Retrying would hit the limit again: continue when it resets
            if let session, store.scheduledContinues[session.id] == nil, let reset = store.limitResetDate(for: session) {
                button("At \(reset.addingTimeInterval(60).formatted(date: .omitted, time: .shortened))", tint) { store.scheduleContinue(session.id) }
                    .help("Type \"continue\" when the limit resets")
            } else {
                button("Retry", tint) { store.retry(toast.sessionId) }
            }
        case .failed where session?.host.canSend == true:
            button("Retry", tint) { store.retry(toast.sessionId) }
        case .away(_, let waiting, _) where waiting > 0:
            // Go through what's waiting, one after another
            button("Start", tint, dismiss: true) { store.startInboxRequest() }
        case .question(_, let answers) where session?.host.canSend == true && !answers.isEmpty:
            ForEach(answers.prefix(2), id: \.text) { answer in
                button(answer.label, tint) {
                    Task { _ = await store.reply(answer.text, to: toast.sessionId) }
                }
            }
        default:
            Image(systemName: "chevron.right").font(.system(size: 9.5, weight: .semibold)).foregroundStyle(Theme.faint)
        }
    }

    private func button(_ title: String, _ tint: Color, dismiss: Bool = true, action: @escaping () -> Void) -> some View {
        Button {
            action()
            if dismiss { store.dismissToast(toast.id) }
        } label: {
            Text(title)
                .font(.system(size: 11, weight: .semibold))
                .foregroundStyle(tint)
                .lineLimit(1)
                .frame(maxWidth: 96)
                .fixedSize()
                .padding(.horizontal, 9)
                .padding(.vertical, 4)
                .background(tint.opacity(0.16), in: Capsule())
        }
        .buttonStyle(.plain)
    }
}

/// A moment (needs you, sent) dropped below the notch when the left side has no room for it.
struct TickerPill: View {
    let activity: NotchActivity

    var body: some View {
        HStack(spacing: 6) {
            Circle().fill(color).frame(width: 6, height: 6)
            Text(activity.text)
                .font(.system(size: 11, weight: .semibold))
                .foregroundStyle(Theme.primary)
        }
        .lineLimit(1)
        .truncationMode(.tail)
        .padding(.horizontal, 12)
        .frame(height: NotchModel.pillHeight)
        .background(Capsule().fill(Color.black))
        .overlay(Capsule().strokeBorder(Color.white.opacity(0.08), lineWidth: 1))
        .fixedSize(horizontal: true, vertical: false)
        .frame(maxWidth: NotchModel.pillWidth)
    }

    private var color: Color {
        switch activity.kind {
        case .needsYou: Theme.needsYou
        case .finished: Theme.unseen
        case .working, .feedback: Theme.working
        case .problem, .failed: Theme.failed
        case .limited: Theme.limit
        case .news(let tone): LeftEar.color(tone)
        }
    }
}

/// Shown on hover: the most urgent active sessions (up to 3 unless Settings says otherwise; not the ones idle
/// for over an hour). Click a row for its details; each row has one action.
struct TopSessionsView: View {
    let store: SessionStore
    let model: NotchModel

    /// Room for the hover card's content below the notch.
    static func room(in model: NotchModel) -> CGFloat { model.maxIslandHeight - model.notchHeight - 16 }

    /// The sessions the hover card can list: all but the ones idle for over an hour.
    static func active(_ sessions: [Session]) -> [Session] {
        let now = Date()
        return sessions.filter { !$0.isDormant(now: now) }
    }

    /// How many rows the hover card lists: the number set in Settings, fewer when they wouldn't fit in `room`.
    static func rowCount(for sessions: [Session], room: CGFloat) -> Int {
        let limit = max(1, min(AppSettings.shared.hoverRows, 20))
        var used = StateBar.height + 6 + 24
        var count = 0
        for session in sessions.prefix(limit) {
            used += TopSessionRow.height(for: session)
            if used > room, count > 0 { break }
            count += 1
        }
        return count
    }

    /// How tall the hover card's content is: the state bar, its rows (a row grows for running subagents)
    /// and "Show all".
    static func height(for sessions: [Session], room: CGFloat = .infinity) -> CGFloat {
        guard !sessions.isEmpty else { return 31 }
        let active = Self.active(sessions)
        let shown = active.prefix(rowCount(for: active, room: room))
        let rows = shown.reduce(CGFloat(0)) { $0 + TopSessionRow.height(for: $1) }
        return StateBar.height + 6 + rows + (sessions.count > shown.count ? 24 : 0)
    }

    var body: some View {
        let sessions = store.ordered
        let active = Self.active(sessions)
        let count = Self.rowCount(for: active, room: Self.room(in: model))
        VStack(spacing: 0) {
            if sessions.isEmpty {
                Text("No Claude sessions yet · click to open WatchMan")
                    .font(.system(size: 11))
                    .foregroundStyle(Theme.secondary)
                    .padding(.vertical, 6)
            } else {
                StateBar(store: store).padding(.bottom, 6).arrive(0)
            }
            let shared = store.sharedLabels
            ForEach(Array(active.prefix(count).enumerated()), id: \.element.id) { index, session in
                TopSessionRow(session: session, store: store, model: model, sharedLabel: shared.contains(session.label))
                    .arrive(min(index + 1, 6))
            }
            if sessions.count > count {
                Button { model.onTap() } label: {
                    Text("Show all \(sessions.count)")
                        .font(.system(size: 10.5, weight: .medium))
                        .foregroundStyle(Theme.secondary)
                        .padding(.horizontal, 10)
                        .padding(.vertical, 2)
                        .background(Color.white.opacity(0.07), in: Capsule())
                }
                .buttonStyle(.plain)
                .frame(maxWidth: .infinity)
                .padding(.top, 6)
                .arrive(min(count, 5) + 1)
            }
        }
    }
}

/// Everything at a glance: one dot per session in its state's colour (waiting, working, new, idle), and every
/// count in words, so it can't be mistaken for a progress bar.
struct StateBar: View {
    let store: SessionStore
    static let height: CGFloat = 14
    private static let maxDots = 24

    var body: some View {
        let sessions = store.ordered
        let waiting = sessions.filter { $0.status.isNeedsYou || $0.failed || $0.rateLimited }.count
        let working = sessions.filter { $0.status == .working }.count
        let fresh = sessions.filter(\.isUnseenResult).count
        let idle = max(0, sessions.count - waiting - working - fresh)
        let dots = Array(repeating: Theme.needsYou, count: waiting) + Array(repeating: Theme.working, count: working)
            + Array(repeating: Theme.unseen, count: fresh) + Array(repeating: Color.white.opacity(0.22), count: idle)
        let counts = HStack(spacing: 8) {
            if waiting > 0 { count(waiting, "waiting", Theme.needsYou) }
            if working > 0 { count(working, "working", Theme.working) }
            if fresh > 0 { count(fresh, "new", Theme.unseen) }
            // Idle ones only when nothing else is going on (they're most of the list, and quiet)
            if idle > 0, store.planUsage == nil || waiting + working + fresh == 0 { count(idle, "idle", Theme.secondary) }
        }
        .fixedSize()
        Group {
            if let usage = store.planUsage {
                // Your plan: ten dots for the session and ten for the week, each a tenth. What doesn't fit goes:
                // the counts first, then the week
                ViewThatFits(in: .horizontal) {
                    usageRow(usage, week: true) { counts }
                    usageRow(usage, week: true) { EmptyView() }
                    usageRow(usage, week: false) { counts }
                    usageRow(usage, week: false) { EmptyView() }
                }
                .help("Your Claude plan: \(PlanUsage.summary(usage))")
            } else {
                sessionDots(dots, counts: counts)
            }
        }
        .frame(height: Self.height)
        .padding(.horizontal, 8)
        .accessibilityElement(children: .ignore)
        .accessibilityLabel("\(store.planUsage.map { "Claude plan: \(PlanUsage.summary($0)). " } ?? "")"
                            + "\(sessions.count) sessions: \(waiting) waiting, \(working) working, \(fresh) new, \(idle) idle")
    }

    private func usageRow<Trailing: View>(_ usage: PlanUsage, week: Bool, @ViewBuilder trailing: () -> Trailing) -> some View {
        HStack(spacing: 10) {
            HStack(spacing: 14) {
                if let session = usage.session { DotMeter(name: "Session", window: session) }
                if week, let weekly = usage.week { DotMeter(name: "Week", window: weekly) }
            }
            Spacer(minLength: 6)
            trailing()
        }
    }

    /// Without the plan's numbers: one dot per session, in its state's colour.
    private func sessionDots<Counts: View>(_ dots: [Color], counts: Counts) -> some View {
        HStack(spacing: 10) {
            HStack(spacing: 3) {
                ForEach(Array(dots.prefix(Self.maxDots).enumerated()), id: \.offset) { _, color in
                    Circle().fill(color).frame(width: 6, height: 6)
                }
                if dots.count > Self.maxDots {
                    Text("+\(dots.count - Self.maxDots)").font(.system(size: 9.5, weight: .medium)).foregroundStyle(Theme.faint)
                }
            }
            .help("One dot per session")
            Spacer(minLength: 6)
            counts
        }
    }

    private func count(_ n: Int, _ label: String, _ color: Color) -> some View {
        HStack(spacing: 3) {
            Text("\(n)").font(.system(size: 10.5, weight: .bold, design: .rounded)).foregroundStyle(color)
            Text(label).font(.system(size: 10.5)).foregroundStyle(Theme.faint)
        }
    }
}

/// A limit as ten dots, each a tenth, lit in the limit's colour (green, orange from 70%, red from 90%).
private struct DotMeter: View {
    let name: String
    let window: UsageWindow

    var body: some View {
        // Any use lights the first dot, so 1% doesn't read as nothing
        let lit = window.percent <= 0 ? 0 : min(10, Int((window.percent / 10).rounded(.up)))
        HStack(spacing: 6) {
            Text(name).font(.system(size: 10.5)).foregroundStyle(Theme.faint)
            HStack(spacing: 2.5) {
                ForEach(0..<10, id: \.self) { index in
                    Circle().fill(index < lit ? window.color : Color.white.opacity(0.16)).frame(width: 5.5, height: 5.5)
                }
            }
            Text("\(Int(window.percent))%").font(.system(size: 10.5, weight: .bold, design: .rounded)).monospacedDigit()
                .foregroundStyle(window.percent >= 70 ? window.color : Theme.secondary)
        }
        .fixedSize()
    }
}

private struct TopSessionRow: View {
    let session: Session
    let store: SessionStore
    let model: NotchModel
    var sharedLabel = false
    @State private var hovering = false

    enum Action { case allow, review, retry, reply, open }

    static func height(for session: Session) -> CGFloat {
        34 + (session.subagents.isEmpty ? 0 : 24)
    }

    /// Retry after an error; Allow a held prompt (Review when the command is risky or too long to read);
    /// reply to a question or a result; otherwise open the tab.
    private var action: Action {
        if session.failed, session.host.canSend { return .retry }
        if let approval = session.pendingApproval, store.hasPendingPrompt(session.id) {
            // A question opens its page, where the choices are
            return approval.needsReview || approval.isQuestion ? .review : .allow
        }
        if session.host.canSend, session.status == .finished { return .reply }
        if session.host.canSend, case .needsYou(let reason) = session.status, !reason.lowercased().contains("permission") {
            return .reply
        }
        return .open
    }

    /// After the usage limit: "At 9:01 PM" to continue then ("Scheduled" once set); otherwise Retry.
    private var retryTitle: String {
        guard session.rateLimited else { return "Retry" }
        if store.scheduledContinues[session.id] != nil { return "Scheduled" }
        return store.limitResetDate(for: session).map { "At " + $0.addingTimeInterval(60).formatted(date: .omitted, time: .shortened) } ?? "Retry"
    }

    /// Allow, Review and Retry always show; Reply and Open only under the pointer.
    private var urgent: Bool { action == .allow || action == .review || action == .retry }

    var body: some View {
        VStack(alignment: .leading, spacing: 4) {
            mainRow
            if !session.subagents.isEmpty { SubagentPills(agents: session.subagents) }
        }
        .padding(.bottom, session.subagents.isEmpty ? 0 : 5)
        .background(hovering ? Theme.cardHover : Color.clear, in: RoundedRectangle(cornerRadius: 9, style: .continuous))
        .contentShape(Rectangle())
        .onHover { hovering = $0 }
        .onTapGesture {
            if NSEvent.modifierFlags.contains(.command) { store.open(session) } else { model.onShowSession(session.id, false) }
        }
        .contextMenu { RowMenu(session: session, store: store, openChat: { model.onShowSession(session.id, false) }) }
        .help("Show the chat · ⌘-click opens \(session.host.label)")
        .accessibilityElement(children: .contain)
        .accessibilityLabel(session.label)
        .modifier(ApprovalAccessibility(session: session, store: store, active: action == .allow))
    }

    private var mainRow: some View {
        HStack(spacing: 9) {
            ProjectTile(session: session, size: 22)
            Text(session.rowTitles(shared: sharedLabel).title)
                .font(.system(size: 12.5, weight: .semibold))
                .foregroundStyle(Theme.primary)
                .lineLimit(1)
                .frame(maxWidth: 170, alignment: .leading)
                .fixedSize(horizontal: true, vertical: false)
            RowDetail(session: session, size: 11)
            Spacer(minLength: 4)
            if !session.tasks.isEmpty, action != .allow, action != .review { PlanTrack(tasks: session.tasks, width: 40, showCount: false) }
            StatusChip(session: session)
                .opacity(hovering ? 0 : 1)
                .overlay(alignment: .trailing) {
                    OpenButtons(session: session, store: store, size: 22) { model.onShowSession(session.id, false) }
                        .opacity(hovering ? 1 : 0)
                        .allowsHitTesting(hovering)
                }
            actionButton
                .opacity(urgent || hovering ? 1 : 0)
                .allowsHitTesting(urgent || hovering)
        }
        .padding(.horizontal, 8)
        .frame(height: 34)
    }

    @ViewBuilder
    private var actionButton: some View {
        switch action {
        case .allow:
            AllowButton(height: 22) { store.respond(to: session.id, with: .allow) }
                .help("Allow: \(session.pendingApproval?.command ?? session.pendingApproval?.detail ?? "")")
        default:
            let (title, tint): (String, Color) = switch action {
            case .review: (session.pendingApproval?.isQuestion == true ? "Answer"
                           : session.pendingApproval?.isPlan == true ? "Read Plan" : "Review", Theme.needsYou)
            case .retry: (retryTitle, session.rateLimited ? Theme.limit : Theme.failed)
            case .reply: ("Reply", Theme.primary)
            default: ("Open", Theme.primary)
            }
            Button {
                switch action {
                case .review: model.onShowSession(session.id, false)
                case .retry where session.rateLimited: store.scheduleContinue(session.id)
                case .retry: store.retry(session.id)
                case .reply: model.onShowSession(session.id, true)
                default: store.open(session)
                }
            } label: {
                Text(title)
                    .font(.system(size: 11, weight: .semibold))
                    .foregroundStyle(tint)
                    .padding(.horizontal, 10)
                    .frame(height: 22)
                    .background(tint.opacity(0.12), in: Capsule())
                    .contentShape(Capsule())
            }
            .buttonStyle(.plain)
            .help(action == .review ? "Risky or long: read it first"
                  : action == .retry ? "Type \"continue\" so Claude picks up where it stopped"
                  : action == .reply ? "Reply to \(session.label)" : "Open in \(session.host.label)")
        }
    }
}

struct TabPill: View {
    let title: String
    let selected: Bool
    let action: () -> Void

    var body: some View {
        Button(action: action) {
            Text(title)
                .font(.system(size: 11.5, weight: .medium))
                .foregroundStyle(selected ? Theme.primary : Theme.secondary)
                .padding(.horizontal, 10)
                .padding(.vertical, 4)
                .background(selected ? Color.white.opacity(0.12) : Color.clear, in: Capsule())
        }
        .buttonStyle(.plain)
    }
}

/// The notch outline: concave shoulders flowing out of the menu bar at the top,
/// rounded corners at the bottom, like the hardware notch.
struct NotchShape: Shape {
    var shoulder: CGFloat
    var radius: CGFloat

    var animatableData: AnimatablePair<CGFloat, CGFloat> {
        get { AnimatablePair(shoulder, radius) }
        set { shoulder = newValue.first; radius = newValue.second }
    }

    func path(in rect: CGRect) -> Path {
        let s = min(shoulder, rect.width / 4)
        let r = min(radius, rect.height / 2, (rect.width - 2 * s) / 2)
        var path = Path()
        path.move(to: CGPoint(x: rect.minX, y: rect.minY))
        path.addQuadCurve(to: CGPoint(x: rect.minX + s, y: rect.minY + s), control: CGPoint(x: rect.minX + s, y: rect.minY))
        path.addLine(to: CGPoint(x: rect.minX + s, y: rect.maxY - r))
        path.addQuadCurve(to: CGPoint(x: rect.minX + s + r, y: rect.maxY), control: CGPoint(x: rect.minX + s, y: rect.maxY))
        path.addLine(to: CGPoint(x: rect.maxX - s - r, y: rect.maxY))
        path.addQuadCurve(to: CGPoint(x: rect.maxX - s, y: rect.maxY - r), control: CGPoint(x: rect.maxX - s, y: rect.maxY))
        path.addLine(to: CGPoint(x: rect.maxX - s, y: rect.minY + s))
        path.addQuadCurve(to: CGPoint(x: rect.maxX, y: rect.minY), control: CGPoint(x: rect.maxX - s, y: rect.minY))
        path.closeSubpath()
        return path
    }
}

enum NotchZone { case left, right }

extension View {
    /// A click target beside the notch, faintly lit while the pointer is on it.
    func zone(_ zone: NotchZone, hovered: Binding<NotchZone?>) -> some View {
        contentShape(Rectangle())
            .background(
                RoundedRectangle(cornerRadius: 7, style: .continuous)
                    .fill(Color.white.opacity(hovered.wrappedValue == zone ? 0.08 : 0))
                    .padding(.vertical, 3)
                    .padding(.horizontal, 2)
            )
            .onHover { inside in
                withAnimation(.smooth(duration: 0.12)) {
                    if inside { hovered.wrappedValue = zone } else if hovered.wrappedValue == zone { hovered.wrappedValue = nil }
                }
            }
    }
}

/// Claude's to-do list at a glance: the last done, the one in progress, the next.
struct TaskGlance: View {
    let tasks: [ClaudeTask]

    var body: some View {
        let glance = tasks.glance
        HStack(spacing: 10) {
            Text("\(tasks.doneCount)/\(tasks.count)")
                .font(.system(size: 10, weight: .semibold, design: .rounded))
                .monospacedDigit()
                .foregroundStyle(Theme.faint)
            if let done = glance.done { item("checkmark.circle.fill", Theme.working, done.text, dim: true) }
            if let current = glance.current { item("circle.lefthalf.filled", Theme.unseen, current.text, dim: false) }
            if let next = glance.next { item("circle", Theme.faint, next.text, dim: true) }
            Spacer(minLength: 0)
        }
        .padding(.leading, 25)
        .padding(.trailing, 9)
        .frame(height: 15)
    }

    private func item(_ symbol: String, _ tint: Color, _ text: String, dim: Bool) -> some View {
        HStack(spacing: 4) {
            Image(systemName: symbol).font(.system(size: 9)).foregroundStyle(tint)
            Text(text)
                .font(.system(size: 10.5, weight: dim ? .regular : .medium))
                .foregroundStyle(dim ? Theme.secondary : Theme.primary)
                .lineLimit(1)
                .truncationMode(.tail)
        }
        .layoutPriority(dim ? 0 : 1)
    }
}

/// Subagents at work in a session: "Explore · Grep auth", one pill each.
struct SubagentPills: View {
    let agents: [Subagent]

    var body: some View {
        HStack(spacing: 5) {
            ForEach(agents.prefix(3)) { agent in
                HStack(spacing: 4) {
                    Circle().fill(Theme.working).frame(width: 5, height: 5)
                    Text(agent.type == "general-purpose" ? "Agent" : agent.type)
                        .font(.system(size: 10, weight: .semibold))
                        .foregroundStyle(Theme.primary)
                    Text(agent.step ?? agent.description)
                        .font(.system(size: 10))
                        .foregroundStyle(Theme.secondary)
                        .lineLimit(1)
                        .truncationMode(.tail)
                }
                .padding(.horizontal, 7)
                .frame(height: 19)
                .background(Color.white.opacity(0.07), in: Capsule())
                .help("\(agent.type): \(agent.description)")
            }
            if agents.count > 3 {
                Text("+\(agents.count - 3)").font(.system(size: 10, weight: .semibold)).foregroundStyle(Theme.faint)
            }
            Spacer(minLength: 0)
        }
        .padding(.leading, 25)
        .padding(.trailing, 9)
    }
}


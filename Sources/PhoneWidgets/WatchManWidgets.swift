import ActivityKit
import CloudKit
import SwiftUI
import WatchManCore
import WidgetKit

@main
struct WatchManWidgets: WidgetBundle {
    var body: some Widget {
        SessionsWidget()
        WatchManLiveActivity()
    }
}

// MARK: - Sessions widget

struct GlanceEntry: TimelineEntry {
    let date: Date
    let glance: Glance?
}

/// The newest of two: the Mac's summary in iCloud, which the widget reads by itself every 20 minutes or so (iOS
/// decides exactly), and what the app saved when it last heard from the Mac (the app also reloads the widgets then).
/// An entry a minute keeps "8m" counting in between.
struct GlanceProvider: TimelineProvider {
    func placeholder(in context: Context) -> GlanceEntry {
        GlanceEntry(date: .now, glance: .sample())
    }

    func getSnapshot(in context: Context, completion: @escaping (GlanceEntry) -> Void) {
        // The widget gallery shows the sample sessions until the app has saved real ones
        completion(GlanceEntry(date: .now, glance: GlanceStore.load() ?? (context.isPreview ? .sample() : nil)))
    }

    func getTimeline(in context: Context, completion: @escaping (Timeline<GlanceEntry>) -> Void) {
        let done = TimelineDone(completion)
        Task {
            let saved = GlanceStore.load()
            var glance = saved
            if let fetched = await GlanceFetch.latest(), fetched.updated > (saved?.updated ?? .distantPast) {
                glance = fetched
                GlanceStore.save(fetched)
            }
            let now = Date()
            let entries = (0..<20).map { GlanceEntry(date: now.addingTimeInterval(Double($0) * 60), glance: glance) }
            done.call(Timeline(entries: entries, policy: .atEnd))
        }
    }
}

/// WidgetKit's completion, carried into the task that reads iCloud (WidgetKit calls it from any thread).
private struct TimelineDone: @unchecked Sendable {
    let completion: (Timeline<GlanceEntry>) -> Void
    init(_ completion: @escaping (Timeline<GlanceEntry>) -> Void) { self.completion = completion }
    func call(_ timeline: Timeline<GlanceEntry>) { completion(timeline) }
}

/// The Mac's summary of the sessions, read straight from iCloud, so the widget is current while the app sleeps.
enum GlanceFetch {
    static func latest() async -> Glance? {
        let configuration = CKOperation.Configuration()
        configuration.timeoutIntervalForRequest = 8
        configuration.qualityOfService = .userInitiated
        let database = CloudRecords.container.privateCloudDatabase
        let record = try? await database.configuredWith(configuration: configuration) { database in
            try await database.record(for: CloudRecords.id(CloudRecords.glanceName))
        }
        return record.flatMap { CloudRecords.value(Glance.self, in: $0) }
    }
}

struct SessionsWidget: Widget {
    var body: some WidgetConfiguration {
        StaticConfiguration(kind: "Sessions", provider: GlanceProvider()) { entry in
            SessionsWidgetView(entry: entry)
        }
        .configurationDisplayName("Sessions")
        .description("What needs you, what's working, and your plan's usage.")
        .supportedFamilies([.systemSmall, .systemMedium, .systemLarge,
                            .accessoryCircular, .accessoryRectangular, .accessoryInline])
    }
}

struct SessionsWidgetView: View {
    let entry: GlanceEntry
    @Environment(\.widgetFamily) private var family

    var body: some View {
        content
            .environment(\.colorScheme, .dark)
            .containerBackground(for: .widget) {
                if !family.isAccessory { WidgetBackdrop() }
            }
            .widgetURL(entry.glance?.waiting.first.map { PhoneLinks.session($0.id) } ?? PhoneLinks.app)
    }

    @ViewBuilder
    private var content: some View {
        switch family {
        case .systemSmall: SmallGlanceView(glance: entry.glance, now: entry.date)
        case .systemMedium: MediumGlanceView(glance: entry.glance, now: entry.date)
        case .systemLarge: LargeGlanceView(glance: entry.glance, now: entry.date)
        case .accessoryCircular: CircularGlanceView(glance: entry.glance)
        case .accessoryRectangular: RectangularGlanceView(glance: entry.glance)
        case .accessoryInline: InlineGlanceView(glance: entry.glance)
        default: SmallGlanceView(glance: entry.glance, now: entry.date)
        }
    }
}

private extension WidgetFamily {
    var isAccessory: Bool { [.accessoryCircular, .accessoryRectangular, .accessoryInline].contains(self) }
}

// MARK: Lock screen

/// How many need you, else the week's usage as a gauge.
struct CircularGlanceView: View {
    let glance: Glance?

    var body: some View {
        let waiting = glance?.waiting.count ?? 0
        if waiting > 0 {
            ZStack {
                AccessoryWidgetBackground()
                VStack(spacing: -1) {
                    Image(systemName: "hand.raised.fill").font(.system(size: 11, weight: .semibold))
                    Text("\(waiting)").font(.system(size: 20, weight: .bold, design: .rounded))
                }
                .widgetAccentable()
            }
            .accessibilityLabel(waiting == 1 ? "1 session needs you" : "\(waiting) sessions need you")
        } else if let week = glance?.weekPercent {
            Gauge(value: min(week, 100), in: 0...100) {
                Text("Week")
            } currentValueLabel: {
                Text("\(Int(week))")
            }
            .gaugeStyle(.accessoryCircular)
            .accessibilityLabel("Nothing needs you. Week usage \(Int(week)) percent")
        } else {
            ZStack {
                AccessoryWidgetBackground()
                Image(systemName: "checkmark").font(.system(size: 18, weight: .bold)).widgetAccentable()
            }
            .accessibilityLabel("Nothing needs you")
        }
    }
}

/// What needs you (or all clear), the session it's about, and the counts.
struct RectangularGlanceView: View {
    let glance: Glance?

    var body: some View {
        let waiting = glance?.waiting.count ?? 0
        VStack(alignment: .leading, spacing: 1) {
            Label(waiting == 1 ? "1 needs you" : waiting > 1 ? "\(waiting) need you" : "All clear",
                  systemImage: waiting > 0 ? "hand.raised.fill" : "checkmark.circle.fill")
                .font(.headline)
                .widgetAccentable()
            if let focus = glance?.focus {
                Text(focus.prompt?.heading ?? "\(focus.name) · \(focus.detail)").font(.caption).lineLimit(1)
            }
            Text(glance.map { GlanceText.counts(waiting: 0, working: $0.working.count, new: $0.newResults.count) } ?? "Open WatchMan")
                .font(.caption2).foregroundStyle(.secondary).lineLimit(1)
        }
        .frame(maxWidth: .infinity, alignment: .leading)
    }
}

/// One line above the clock.
struct InlineGlanceView: View {
    let glance: Glance?

    var body: some View {
        let waiting = glance?.waiting.count ?? 0
        Label(glance.map(GlanceText.counts) ?? "WatchMan",
              systemImage: waiting > 0 ? "hand.raised.fill" : "checkmark.circle")
    }
}

// MARK: - Live Activity

struct WatchManLiveActivity: Widget {
    var body: some WidgetConfiguration {
        ActivityConfiguration(for: WatchManActivity.self) { context in
            ActivityLockView(state: context.state)
                .environment(\.colorScheme, .dark)
                .activityBackgroundTint(Color(red: 0.07, green: 0.07, blue: 0.11).opacity(0.92))
                .activitySystemActionForegroundColor(.white)
                .widgetURL(context.state.link)
        } dynamicIsland: { context in
            DynamicIsland {
                DynamicIslandExpandedRegion(.leading) {
                    IslandExpandedLeading(state: context.state)
                }
                DynamicIslandExpandedRegion(.trailing) {
                    IslandExpandedTrailing(state: context.state)
                        // Too wide beside the camera: it goes below, never squeezed
                        .dynamicIsland(verticalPlacement: .belowIfTooWide)
                }
                DynamicIslandExpandedRegion(.center) {
                    IslandExpandedCenter(state: context.state)
                        .environment(\.colorScheme, .dark)
                }
                DynamicIslandExpandedRegion(.bottom) {
                    IslandExpandedBottom(state: context.state)
                        .environment(\.colorScheme, .dark)
                }
            } compactLeading: {
                // Dynamic Island off in Settings: nothing in the closed island (a long press still opens it)
                if context.state.plainIsland != true { IslandLeading(state: context.state) }
            } compactTrailing: {
                if context.state.plainIsland != true { IslandTrailing(state: context.state) }
            } minimal: {
                if context.state.plainIsland != true { IconFace(size: 20) }
            }
            .widgetURL(context.state.link)
            // Dynamic Island off: no coloured outline either
            .keylineTint(context.state.plainIsland == true ? Color.clear : IconFace.indigo)
        }
    }
}

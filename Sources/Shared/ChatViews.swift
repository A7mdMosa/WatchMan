import SwiftUI
import WatchManCore
#if os(macOS)
import AppKit
#else
import UIKit
#endif

/// WatchMan's colours, the same on the Mac and the iPhone, in a dark and a light version (the Mac's panel and
/// window are always dark; the iPhone follows its appearance). The greys brighten with Increase Contrast.
enum Palette {
    static let primary = adaptive(dark: (0.96, 0.96, 0.97), light: (0.08, 0.08, 0.10))
    static let secondary = adaptive(dark: (0.68, 0.70, 0.74), light: (0.36, 0.37, 0.41), lift: 0.14)
    static let faint = adaptive(dark: (0.55, 0.57, 0.61), light: (0.40, 0.41, 0.45), lift: 0.19)
    static let needsYou = adaptive(dark: (0.98, 0.66, 0.16), light: (0.64, 0.37, 0.0))
    static let working = adaptive(dark: (0.20, 0.83, 0.45), light: (0.10, 0.47, 0.23))
    static let unseen = adaptive(dark: (0.36, 0.62, 1.0), light: (0.12, 0.37, 0.82))
    static let failed = adaptive(dark: (0.96, 0.33, 0.38), light: (0.77, 0.14, 0.18))
    static let obsidian = adaptive(dark: (0.66, 0.55, 0.98), light: (0.42, 0.25, 0.84))
    /// Claude Code's own colours in the terminal: its orange, and the lavender of inline code.
    static let claude = adaptive(dark: (0.85, 0.47, 0.34), light: (0.66, 0.30, 0.16))
    static let code = adaptive(dark: (0.69, 0.73, 0.98), light: (0.29, 0.31, 0.77))
    static let web = adaptive(dark: (0.30, 0.80, 0.78), light: (0.05, 0.45, 0.44))
    /// Claude's usage limit: orange, between waiting and an error.
    static let limit = adaptive(dark: (0.98, 0.57, 0.24), light: (0.70, 0.32, 0.04))
    /// Panels behind code and tables, and their lines: a little light on dark, a little shade on light.
    static let fill = adaptive(dark: (1, 1, 1), light: (0, 0, 0), alpha: 0.05)
    static let line = adaptive(dark: (1, 1, 1), light: (0, 0, 0), alpha: 0.12)

    /// A colour with its dark and light versions; `lift` brightens it on dark (darkens it on light) with
    /// Increase Contrast.
    private static func adaptive(dark: (CGFloat, CGFloat, CGFloat), light: (CGFloat, CGFloat, CGFloat), alpha: CGFloat = 1,
                                 lift: CGFloat = 0) -> Color {
        func make(_ rgb: (CGFloat, CGFloat, CGFloat), _ shift: CGFloat) -> (CGFloat, CGFloat, CGFloat) {
            (min(1, max(0, rgb.0 + shift)), min(1, max(0, rgb.1 + shift)), min(1, max(0, rgb.2 + shift)))
        }
        #if os(macOS)
        return Color(nsColor: NSColor(name: nil) { appearance in
            let isDark = appearance.bestMatch(from: [.darkAqua, .aqua]) == .darkAqua
            let high = NSWorkspace.shared.accessibilityDisplayShouldIncreaseContrast || appearance.name.rawValue.contains("HighContrast")
            let c = make(isDark ? dark : light, high ? (isDark ? lift : -lift * 0.5) : 0)
            return NSColor(srgbRed: c.0, green: c.1, blue: c.2, alpha: alpha)
        })
        #else
        return Color(uiColor: UIColor { traits in
            let isDark = traits.userInterfaceStyle == .dark
            let high = traits.accessibilityContrast == .high
            let c = make(isDark ? dark : light, high ? (isDark ? lift : -lift * 0.5) : 0)
            return UIColor(red: c.0, green: c.1, blue: c.2, alpha: alpha)
        })
        #endif
    }
}

/// Chat text: fixed sizes on the Mac (it has no Dynamic Type), text styles on the iPhone so it grows with
/// Larger Text. The Mac sizes map to the iPhone styles of the same rank.
enum ChatType {
    static func font(_ size: CGFloat, weight: Font.Weight = .regular, monospaced: Bool = false) -> Font {
        #if os(iOS)
        let style: Font.TextStyle = switch size {
        case 15...: .title3
        case 14..<15: .headline
        case 13..<14: .body
        case 12..<13: .callout
        case 11..<12: .footnote
        default: .caption2
        }
        return .system(style, design: monospaced ? .monospaced : .default, weight: weight)
        #else
        return .system(size: size, weight: weight, design: monospaced ? .monospaced : .default)
        #endif
    }
}

/// Claude's replies are markdown: show bold, italics and `code`, keep line breaks.
struct MarkdownText: View {
    let text: String
    var lineLimit: Int?

    var body: some View {
        Text(attributed)
            .lineLimit(lineLimit)
    }

    /// Inline code in lavender and links in blue, as the terminal shows them.
    private var attributed: AttributedString {
        let options = AttributedString.MarkdownParsingOptions(interpretedSyntax: .inlineOnlyPreservingWhitespace)
        var result = (try? AttributedString(markdown: text, options: options)) ?? AttributedString(text)
        let code = result.runs.filter { $0.inlinePresentationIntent?.contains(.code) == true }.map(\.range)
        let links = result.runs.filter { $0.link != nil }.map(\.range)
        for range in code { result[range].swiftUI.foregroundColor = Palette.code }
        for range in links { result[range].swiftUI.foregroundColor = Palette.unseen }
        return result
    }
}

/// Claude's steps between two messages, like the terminal's tool lines: a dot in the step's colour, what it
/// did and on what, and test results in green or red. A long run shows its last few, the rest a click away.
struct ChatStepsView: View {
    let steps: [TranscriptState.TimelineEntry]
    /// Every step at once (the iPhone's Steps tab), not the last few under "+ N earlier steps".
    var showsAll = false
    @State private var open = false

    private static let shown = 6

    var body: some View {
        let hidden = open || showsAll ? 0 : max(0, steps.count - Self.shown)
        VStack(alignment: .leading, spacing: 4) {
            if hidden > 0 {
                Button { withAnimation(.smooth(duration: 0.18)) { open = true } } label: {
                    Text("+ \(hidden) earlier step\(hidden == 1 ? "" : "s")")
                        .font(ChatType.font(11, monospaced: true))
                        .foregroundStyle(Palette.faint)
                        .padding(.leading, 15)
                        .contentShape(Rectangle())
                }
                .buttonStyle(.plain)
                .help("Show every step")
            }
            ForEach(steps.suffix(steps.count - hidden)) { step in
                line(step)
            }
        }
    }

    @ViewBuilder
    private func line(_ step: TranscriptState.TimelineEntry) -> some View {
        switch step.kind {
        case .passed, .failed:
            let color = step.kind == .passed ? Palette.working : Palette.failed
            HStack(alignment: .firstTextBaseline, spacing: 6) {
                Text("⎿").foregroundStyle(Palette.faint)
                Text(step.kind == .passed ? "✓" : "✗").fontWeight(.bold).foregroundStyle(color)
                Text(step.text).foregroundStyle(color)
            }
            .font(ChatType.font(11.5, monospaced: true))
            .padding(.leading, 15)
        default:
            let (verb, detail) = Self.split(step.text)
            HStack(alignment: .firstTextBaseline, spacing: 7) {
                Text("●").font(ChatType.font(8)).foregroundStyle(Self.color(for: verb))
                HStack(spacing: 0) {
                    Text(verb).fontWeight(.semibold).foregroundStyle(Palette.primary.opacity(0.9))
                    if let detail {
                        Text("(\(detail))").foregroundStyle(Palette.secondary).lineLimit(1).truncationMode(.middle)
                    }
                }
                .font(ChatType.font(11.5, monospaced: true))
            }
            .help(step.text)
        }
    }

    /// "Edit · main.dart" → ("Edit", "main.dart").
    static func split(_ text: String) -> (String, String?) {
        guard let range = text.range(of: " · ") else { return (text, nil) }
        return (String(text[..<range.lowerBound]), String(text[range.upperBound...]))
    }

    /// Changes in green, commands in Claude's orange, reading and searching in blue, agents and skills in
    /// purple, the web in teal.
    static func color(for verb: String) -> Color {
        switch verb {
        case "Edit", "Write": Palette.working
        case "Run": Palette.claude
        case "Read", "Search", "Find": Palette.unseen
        case "Agent", "Skill": Palette.obsidian
        case "Fetch", "Web search": Palette.web
        default: Palette.faint
        }
    }
}

/// Markdown drawn properly: headings, paragraphs, bullet and numbered lists, quotes, code and tables.
struct MarkdownBlocksView: View {
    let blocks: [MarkdownBlock]

    var body: some View {
        VStack(alignment: .leading, spacing: 8) {
            ForEach(Array(blocks.enumerated()), id: \.offset) { _, block in
                view(for: block)
            }
        }
        .textSelection(.enabled)
    }

    /// A column whose cells are all short (like "#" or "Medium").
    static func isNarrow(_ column: Int, rows: [[String]]) -> Bool {
        rows.allSatisfy { column >= $0.count || $0[column].count <= 8 }
    }

    private func inline(_ text: String, size: CGFloat = 13, weight: Font.Weight = .regular, color: Color = Palette.primary.opacity(0.92)) -> some View {
        MarkdownText(text: text)
            .font(ChatType.font(size, weight: weight))
            .foregroundStyle(color)
            .lineSpacing(2.5)
            .fixedSize(horizontal: false, vertical: true)
    }

    @ViewBuilder
    private func view(for block: MarkdownBlock) -> some View {
        switch block {
        case .heading(let level, let text):
            inline(text, size: level <= 1 ? 16 : level == 2 ? 14.5 : 13.5, weight: .bold, color: Palette.primary)
                .padding(.top, 4)
        case .paragraph(let text):
            inline(text)
        case .bullet(let indent, let text):
            HStack(alignment: .firstTextBaseline, spacing: 7) {
                Text(indent == 0 ? "•" : "◦").font(ChatType.font(13, weight: .bold)).foregroundStyle(Palette.secondary)
                inline(text)
            }
            .padding(.leading, CGFloat(indent) * 16)
        case .numbered(let indent, let number, let text):
            HStack(alignment: .firstTextBaseline, spacing: 6) {
                Text("\(number).").font(ChatType.font(12.5, weight: .semibold)).monospacedDigit()
                    .foregroundStyle(Palette.secondary).frame(minWidth: 16, alignment: .trailing)
                inline(text)
            }
            .padding(.leading, CGFloat(indent) * 16)
        case .quote(let text):
            HStack(spacing: 8) {
                RoundedRectangle(cornerRadius: 1).fill(Palette.secondary.opacity(0.5)).frame(width: 2)
                inline(text, color: Palette.secondary)
            }
            .fixedSize(horizontal: false, vertical: true)
        case .code(let language, let text):
            CodeBlockView(language: language, text: text)
        case .table(let header, let rows):
            // Columns share the width; long cells wrap and their row grows
            Grid(alignment: .topLeading, horizontalSpacing: 14, verticalSpacing: 7) {
                GridRow {
                    ForEach(Array(header.enumerated()), id: \.offset) { _, cell in
                        inline(cell, size: 11.5, weight: .semibold, color: Palette.secondary)
                    }
                }
                Divider().overlay(Palette.line).gridCellUnsizedAxes(.horizontal)
                ForEach(Array(rows.enumerated()), id: \.offset) { _, row in
                    GridRow {
                        ForEach(0..<header.count, id: \.self) { column in
                            let cell = column < row.count ? row[column] : ""
                            // Short columns (numbers, one word) keep their size; the rest share the width
                            if Self.isNarrow(column, rows: rows) {
                                inline(cell, size: 12.5).fixedSize()
                            } else {
                                inline(cell, size: 12.5).frame(maxWidth: .infinity, alignment: .leading)
                            }
                        }
                    }
                }
            }
            .padding(10)
            .frame(maxWidth: .infinity, alignment: .leading)
            .background(Palette.fill, in: RoundedRectangle(cornerRadius: 8))
            .overlay(RoundedRectangle(cornerRadius: 8).strokeBorder(Palette.line, lineWidth: 1))
        case .rule:
            Divider().overlay(Palette.line)
        }
    }
}

/// A code block the way the terminal colours it: monospaced on a darker panel, a diff's added and removed lines
/// in green and red, a shell's $ prompt in green, comments dimmed. Long lines wrap.
struct CodeBlockView: View {
    let language: String?
    let text: String

    enum Kind { case diff, shell, other }

    var body: some View {
        let lines = text.components(separatedBy: "\n")
        let kind = Self.kind(language, lines: lines)
        VStack(alignment: .leading, spacing: 0) {
            ForEach(Array(lines.enumerated()), id: \.offset) { _, line in
                Text(Self.styled(line, kind: kind))
                    .font(ChatType.font(11.5, monospaced: true))
                    .fixedSize(horizontal: false, vertical: true)
                    .padding(.horizontal, 10)
                    .padding(.vertical, 1)
                    .frame(maxWidth: .infinity, alignment: .leading)
                    .background(Self.background(line, kind: kind))
            }
        }
        .padding(.vertical, 8)
        .background(Palette.fill, in: RoundedRectangle(cornerRadius: 8))
        .clipShape(RoundedRectangle(cornerRadius: 8))
        .overlay(alignment: .topTrailing) {
            if let language {
                Text(language)
                    .font(ChatType.font(10, monospaced: true))
                    .foregroundStyle(Palette.faint)
                    .padding(.horizontal, 8)
                    .padding(.top, 5)
            }
        }
    }

    static func kind(_ language: String?, lines: [String]) -> Kind {
        switch language?.lowercased() {
        case "diff", "patch": return .diff
        case "bash", "sh", "zsh", "shell", "console", "terminal", "fish": return .shell
        default:
            if lines.contains(where: { $0.hasPrefix("@@") }) { return .diff }
            return .other
        }
    }

    private static func isAdded(_ line: String) -> Bool { line.hasPrefix("+") && !line.hasPrefix("+++") }
    private static func isRemoved(_ line: String) -> Bool { line.hasPrefix("-") && !line.hasPrefix("---") }

    static func styled(_ line: String, kind: Kind) -> AttributedString {
        let trimmed = line.trimmingCharacters(in: .whitespaces)
        var text = AttributedString(line.isEmpty ? " " : line)
        text.swiftUI.foregroundColor = Palette.primary.opacity(0.9)
        switch kind {
        case .diff:
            if isAdded(line) { text.swiftUI.foregroundColor = Palette.working }
            else if isRemoved(line) { text.swiftUI.foregroundColor = Palette.failed }
            else if line.hasPrefix("@@") { text.swiftUI.foregroundColor = Palette.unseen }
            else if line.hasPrefix("+++") || line.hasPrefix("---") { text.swiftUI.foregroundColor = Palette.faint }
            else { text.swiftUI.foregroundColor = Palette.secondary }
        case .shell:
            if trimmed.hasPrefix("#") {
                text.swiftUI.foregroundColor = Palette.faint
            } else if trimmed.hasPrefix("$ "), let range = text.range(of: "$") {
                text[range].swiftUI.foregroundColor = Palette.working
            }
        case .other:
            if trimmed.hasPrefix("//") || trimmed.hasPrefix("#") || trimmed.hasPrefix("--") || trimmed.hasPrefix("/*")
                || trimmed.hasPrefix("*") {
                text.swiftUI.foregroundColor = Palette.faint
            }
        }
        return text
    }

    static func background(_ line: String, kind: Kind) -> Color {
        guard kind == .diff else { return .clear }
        if isAdded(line) { return Palette.working.opacity(0.13) }
        if isRemoved(line) { return Palette.failed.opacity(0.13) }
        return .clear
    }
}


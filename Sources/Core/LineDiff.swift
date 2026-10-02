import Foundation

/// A small line diff for showing an edit: removed, added and context lines, with the totals.
public struct LineDiff: Equatable, Sendable {
    public enum Kind: Equatable, Sendable { case context, removed, added, gap }
    public struct Line: Equatable, Sendable {
        public var kind: Kind
        public var text: String
        public init(kind: Kind, text: String) { self.kind = kind; self.text = text }
    }

    public var lines: [Line]
    public var added: Int
    public var removed: Int

    public init(lines: [Line], added: Int, removed: Int) {
        self.lines = lines
        self.added = added
        self.removed = removed
    }

    /// "+2 −1".
    public var counts: String { "+\(added) −\(removed)" }

    /// Lines that changed with `context` unchanged lines around them; longer unchanged runs become a gap.
    public static func make(old: String, new: String, context: Int = 1) -> LineDiff {
        let a = old.isEmpty ? [] : old.components(separatedBy: "\n")
        let b = new.isEmpty ? [] : new.components(separatedBy: "\n")
        let difference = b.difference(from: a)
        var removedAt = Set<Int>(), addedAt = Set<Int>()
        for change in difference {
            switch change {
            case .remove(let offset, _, _): removedAt.insert(offset)
            case .insert(let offset, _, _): addedAt.insert(offset)
            }
        }
        var all: [Line] = []
        var i = 0, j = 0
        while i < a.count || j < b.count {
            if i < a.count, removedAt.contains(i) {
                all.append(Line(kind: .removed, text: a[i])); i += 1
            } else if j < b.count, addedAt.contains(j) {
                all.append(Line(kind: .added, text: b[j])); j += 1
            } else {
                if i < a.count { all.append(Line(kind: .context, text: a[i])) }
                i += 1; j += 1
            }
        }
        return LineDiff(lines: trim(all, context: context), added: addedAt.count, removed: removedAt.count)
    }

    /// Several replacements in one file, one after another with a gap between.
    public static func make(edits: [TextEdit], context: Int = 1) -> LineDiff {
        var result = LineDiff(lines: [], added: 0, removed: 0)
        for edit in edits {
            let part = make(old: edit.oldString, new: edit.newString, context: context)
            if !result.lines.isEmpty, !part.lines.isEmpty { result.lines.append(Line(kind: .gap, text: "")) }
            result.lines += part.lines
            result.added += part.added
            result.removed += part.removed
        }
        return result
    }

    private static func trim(_ lines: [Line], context: Int) -> [Line] {
        let changed = lines.indices.filter { lines[$0].kind != .context }
        guard !changed.isEmpty else { return [] }
        var keep = Set<Int>()
        for index in changed {
            for k in max(0, index - context)...min(lines.count - 1, index + context) { keep.insert(k) }
        }
        var out: [Line] = []
        var last = -1
        for index in keep.sorted() {
            if last >= 0, index > last + 1 { out.append(Line(kind: .gap, text: "")) }
            out.append(lines[index])
            last = index
        }
        return out
    }
}

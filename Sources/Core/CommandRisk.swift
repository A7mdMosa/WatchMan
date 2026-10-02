import Foundation

/// Commands that delete, overwrite, run as root, rewrite history or pipe a download into a shell. A permission
/// prompt for one of these is never answered from a small message: it opens the session's page to review first.
public enum CommandRisk {
    private static let patterns = [
        #"\brm\s+(-[a-zA-Z]*[rRf]|--recursive|--force)"#,   // rm -rf, rm -r, rm -f
        #"\bsudo\b"#,
        #"\bgit\s+push\b.*(--force|\s-f\b|--force-with-lease)"#,
        #"\bgit\s+reset\s+--hard"#,
        #"\bgit\s+clean\s+-[a-zA-Z]*f"#,
        #"\bgit\s+(checkout|restore)\s+(--\s+)?\.(\s|$)"#,   // throws away local changes
        #"\bgit\s+branch\s+-D\b"#,
        #"(curl|wget)\b[^|]*\|\s*(sudo\s+)?(sh|bash|zsh)\b"#,
        #"\bmkfs\b"#,
        #"\bdd\s+if="#,
        #"\b(chmod|chown)\s+-R\b"#,
        #"\bdrop\s+(table|database|schema)\b"#,
        #"\btruncate\s+table\b"#,
        #"\bkill(all)?\s+-9\b"#,
        #"\bfirebase\s+.*\bdelete\b"#,
        #">\s*/dev/(disk|sd)"#,
    ]

    public static func isRisky(_ command: String) -> Bool {
        patterns.contains { command.range(of: $0, options: [.regularExpression, .caseInsensitive]) != nil }
    }
}

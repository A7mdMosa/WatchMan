import AppKit

/// The kinds of moments WatchMan can sound for, each with its own sound.
enum SoundEvent: String, CaseIterable, Identifiable {
    case permission, question, finished, error, limit, stuck
    var id: Self { self }

    var title: String {
        switch self {
        case .permission: "Wants permission"
        case .question: "Asks a question"
        case .finished: "Finished"
        case .error: "Stopped with an error"
        case .limit: "Hit the usage limit"
        case .stuck: "May be stuck"
        }
    }

    var defaultSound: String {
        switch self {
        case .permission: "Funk"
        case .question: "Ping"
        case .finished: "Glass"
        case .error: "Basso"
        case .limit: "Submarine"
        case .stuck: "Sosumi"
        }
    }
}

/// Plays a moment's sound at the chosen volume (macOS's own sounds, so nothing to ship). A copy of the sound
/// plays each time, so two moments close together both sound.
@MainActor
enum Sounds {
    static let names = ["Basso", "Blow", "Bottle", "Frog", "Funk", "Glass", "Hero", "Morse", "Ping", "Pop", "Purr", "Sosumi",
                        "Submarine", "Tink"]

    static func name(for event: SoundEvent) -> String {
        AppSettings.shared.eventSounds[event.rawValue] ?? event.defaultSound
    }

    /// A finished project with its own sound plays that one.
    static func play(_ event: SoundEvent, project: String? = nil) {
        guard AppSettings.shared.soundEnabled else { return }
        let projectSound = event == .finished ? ProjectSettings.shared.sound(for: project) : nil
        preview(projectSound ?? name(for: event))
    }

    static func preview(_ name: String) {
        guard name != "None", let sound = NSSound(named: name)?.copy() as? NSSound else { return }
        sound.volume = Float(AppSettings.shared.soundVolume)
        sound.play()
    }
}

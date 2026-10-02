import SwiftUI
import UIKit
import UserNotifications
import UserNotificationsUI

/// A question notification, long-pressed: the question and its choices, each choice a button (the app sends it to
/// the Mac). The Mac writes the question on the first line and the choices on the second, joined by " · ".
final class NotificationViewController: UIViewController, @preconcurrency UNNotificationContentExtension {
    private var host: UIHostingController<QuestionView>?

    func didReceive(_ notification: UNNotification) {
        let lines = notification.request.content.body.components(separatedBy: "\n")
        let question = lines.first ?? ""
        let choices = lines.count > 1 ? lines[1].components(separatedBy: " · ").filter { !$0.isEmpty } : []
        let content = QuestionView(asker: notification.request.content.title, question: question, choices: choices)
        if let host {
            host.rootView = content
        } else {
            let host = UIHostingController(rootView: content)
            addChild(host)
            host.view.translatesAutoresizingMaskIntoConstraints = false
            host.view.backgroundColor = .clear
            self.view.addSubview(host.view)
            NSLayoutConstraint.activate([
                host.view.leadingAnchor.constraint(equalTo: self.view.leadingAnchor),
                host.view.trailingAnchor.constraint(equalTo: self.view.trailingAnchor),
                host.view.topAnchor.constraint(equalTo: self.view.topAnchor),
                host.view.bottomAnchor.constraint(equalTo: self.view.bottomAnchor),
            ])
            host.didMove(toParent: self)
            self.host = host
        }
        // The choices as the notification's buttons (up to four), then your own answer
        var actions: [UNNotificationAction] = choices.prefix(4).enumerated().map { index, choice in
            UNNotificationAction(identifier: "CHOICE_\(index)", title: choice, options: [])
        }
        actions.append(UNTextInputNotificationAction(identifier: "ANSWER", title: "Other Answer…", options: [],
                                                     textInputButtonTitle: "Send", textInputPlaceholder: "Your answer"))
        extensionContext?.notificationActions = actions
        preferredContentSize = CGSize(width: view.bounds.width, height: CGFloat(60 + 26 * min(choices.count, 4)))
    }

    /// The app sends the answer, so it reaches the Mac through iCloud.
    func didReceive(_ response: UNNotificationResponse, completionHandler completion: @escaping (UNNotificationContentExtensionResponseOption) -> Void) {
        completion(.dismissAndForwardAction)
    }
}

struct QuestionView: View {
    let asker: String
    let question: String
    let choices: [String]

    var body: some View {
        VStack(alignment: .leading, spacing: 8) {
            Text(asker).font(.footnote.weight(.semibold)).foregroundStyle(Color(red: 0.98, green: 0.66, blue: 0.16))
            Text(question).font(.headline)
            ForEach(Array(choices.prefix(4).enumerated()), id: \.offset) { index, choice in
                Text("\(index + 1). \(choice)").font(.subheadline).foregroundStyle(.secondary)
            }
        }
        .padding()
        .frame(maxWidth: .infinity, alignment: .leading)
    }
}

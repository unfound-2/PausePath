import Foundation
import Observation
import UserNotifications

struct SocialProfile: Codable {
    var id: UUID?
    var username = ""
    var discoverable = false
    var allow_requests = true
    var allow_walk_invites = true
    var notify_invites = true
    var notify_walks = true
    var notify_goals = true
    var body: [String: Any] {
        ["username": username, "discoverable": discoverable, "allow_requests": allow_requests,
         "allow_walk_invites": allow_walk_invites, "notify_invites": notify_invites, "notify_walks": notify_walks, "notify_goals": notify_goals]
    }
}
struct SocialPerson: Decodable, Identifiable { let id: UUID; let username: String }
struct SocialFriend: Decodable, Identifiable {
    let id: UUID; let person_id: UUID; let username: String; let status: String; let incoming: Bool
}
struct SocialInvitation: Decodable, Identifiable {
    let id: UUID; let walk_id: UUID; let title: String; let starts_at: String; let community_name: String; let sender: String
}
struct SocialNotification: Decodable, Identifiable {
    let id: UUID; let category: String; let message: String; let community_id: UUID?; let walk_id: UUID?; let created_at: String; let read_at: String?
}
struct SocialWalkReminder: Decodable { let id: UUID; let title: String; let starts_at: String }
struct PeopleResponse: Decodable { let people: [SocialPerson] }
struct FriendsResponse: Decodable { let friends: [SocialFriend] }
struct ProfileResponse: Decodable { let profile: SocialProfile? }
struct NotificationsResponse: Decodable { let notifications: [SocialNotification] }
struct InvitationsResponse: Decodable { let invitations: [SocialInvitation] }
struct RemindersResponse: Decodable { let walks: [SocialWalkReminder] }

@MainActor enum SocialAPI {
    static func get<T: Decodable>(_ path: String, query: [URLQueryItem] = []) async throws -> T {
        let data = try await PausePathAPI.request("api/v1/social/" + path, requiresAccount: true, query: query)
        return try JSONDecoder().decode(T.self, from: data)
    }
    static func post(_ path: String, _ body: [String: Any] = [:]) async throws {
        _ = try await PausePathAPI.request("api/v1/social/" + path, body: body, requiresAccount: true)
        NotificationCenter.default.post(name: .pausePathSocialChanged, object: nil)
        if path.hasPrefix("invitations/"), body["accept"] as? Bool == true {
            NotificationCenter.default.post(name: .pausePathCommunityMembershipChanged, object: nil)
        }
    }
    static func date(_ raw: String) -> Date? {
        let parser = ISO8601DateFormatter(); parser.formatOptions = [.withInternetDateTime, .withFractionalSeconds]
        return parser.date(from: raw) ?? ISO8601DateFormatter().date(from: raw)
    }
}

@MainActor @Observable final class SocialActivityStore {
    static let shared = SocialActivityStore()
    var notifications: [SocialNotification] = []
    var invitations: [SocialInvitation] = []
    var error: String?
    var refreshing = false
    private var owner: String?
    var unread: Int { notifications.filter { $0.read_at == nil }.count }
    private static let reminderPrefix = "pausepath.group-walk."
    func reset() {
        owner = nil; notifications = []; invitations = []; error = nil
        Task { await Self.clearReminders() }
    }
    func refresh() async {
        guard let subject = PausePathAccount.shared.userID, !refreshing else { return }
        if owner != subject { notifications = []; invitations = []; owner = subject }
        refreshing = true; defer { refreshing = false }
        do {
            async let inbox: NotificationsResponse = SocialAPI.get("inbox")
            async let invites: InvitationsResponse = SocialAPI.get("invitations")
            async let walks: RemindersResponse = SocialAPI.get("reminders")
            let results = try await (inbox, invites, walks)
            guard PausePathAccount.shared.userID == subject, !Task.isCancelled else { return }
            notifications = results.0.notifications; invitations = results.1.invitations; error = nil
            if UserDefaults.standard.bool(forKey: "pausepath.walkReminders.\(subject)") { await reconcile(results.2.walks, subject: subject) }
            else { await Self.clearReminders() }
        } catch { if PausePathAccount.shared.userID == subject, !Task.isCancelled { self.error = "Couldn’t update community activity. Pull down to retry." } }
    }
    static func clearReminders() async {
        let center = UNUserNotificationCenter.current()
        let pending = await center.pendingNotificationRequests().filter { $0.identifier.hasPrefix(reminderPrefix) }.map(\.identifier)
        center.removePendingNotificationRequests(withIdentifiers: pending)
        let delivered = await center.deliveredNotifications().filter { $0.request.identifier.hasPrefix(reminderPrefix) }.map { $0.request.identifier }
        center.removeDeliveredNotifications(withIdentifiers: delivered)
    }
    private func reconcile(_ walks: [SocialWalkReminder], subject: String) async {
        let center = UNUserNotificationCenter.current()
        let access = await center.notificationSettings()
        guard [.authorized, .provisional].contains(access.authorizationStatus) else { return }
        let wanted = Set(walks.map { Self.reminderPrefix + $0.id.uuidString })
        let pending = await center.pendingNotificationRequests().filter { $0.identifier.hasPrefix(Self.reminderPrefix) }
        center.removePendingNotificationRequests(withIdentifiers: pending.filter { !wanted.contains($0.identifier) }.map(\.identifier))
        for walk in walks {
            guard PausePathAccount.shared.userID == subject, UserDefaults.standard.bool(forKey: "pausepath.walkReminders.\(subject)"), !Task.isCancelled else { await Self.clearReminders(); return }
            guard let start = SocialAPI.date(walk.starts_at), start.timeIntervalSinceNow > 900 else { continue }
            let content = UNMutableNotificationContent()
            content.title = "Your group walk starts soon"
            content.body = "Open PausePath to check the latest plan before you set off."
            content.sound = .default
            let fire = start.addingTimeInterval(-900)
            if let existing = pending.first(where: { $0.identifier == Self.reminderPrefix + walk.id.uuidString }),
               let existingDate = (existing.trigger as? UNCalendarNotificationTrigger)?.nextTriggerDate(), abs(existingDate.timeIntervalSince(fire)) < 2 { continue }
            var components = Calendar.current.dateComponents([.year,.month,.day,.hour,.minute,.second], from: fire)
            components.calendar = Calendar.current; components.timeZone = TimeZone.current
            do { try await center.add(UNNotificationRequest(identifier: Self.reminderPrefix + walk.id.uuidString,
                content: content, trigger: UNCalendarNotificationTrigger(dateMatching: components,repeats: false))) }
            catch { self.error = "Some walk reminders could not be scheduled. Check Notifications settings and try again." }
        }
    }
}

extension Notification.Name {
    static let pausePathSocialChanged = Notification.Name("pausepath.socialChanged")
    static let pausePathCommunityMembershipChanged = Notification.Name("pausepath.communityMembershipChanged")
    static let pausePathShowInbox = Notification.Name("pausepath.showInbox")
}

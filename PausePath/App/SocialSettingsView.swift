import SwiftUI
import UserNotifications

struct FriendsSettingsView: View {
    @State private var account = PausePathAccount.shared
    @State private var people: [SocialPerson] = []
    @State private var friends: [SocialFriend] = []
    @State private var query = ""
    @State private var configured = false
    @State private var loadedOwner: String?
    @State private var busy = false
    @State private var searching = false
    @State private var message = ""
    @State private var pendingBlock: SocialPerson?
    var body: some View {
        List {
            if !account.isSignedIn {
                Section { NavigationLink("Sign in with Apple") { AccountView() } }
            } else {
                Section {
                    NavigationLink { FriendPrivacyView() } label: { Label("Friend privacy & username", systemImage: "hand.raised") }
                    NavigationLink { BlockedPeopleView() } label: { Label("Blocked people", systemImage: "person.slash") }
                }
                if !configured { Text("Choose a unique friend username in privacy settings to get started. Being searchable is optional.").font(.callout) }
                if configured {
                    Section("Find people") {
                        TextField("Search username (at least 3 characters)", text: $query).textInputAutocapitalization(.never).autocorrectionDisabled()
                        if searching { ProgressView("Searching…") }
                        ForEach(people) { person in
                            VStack(alignment: .leading, spacing: 8) {
                                Text("@\(person.username)").font(.headline)
                                HStack {
                                    if friends.contains(where: { $0.person_id == person.id }) { Text("Connected or request pending").font(.caption).foregroundStyle(.secondary) }
                                    else { Button("Add friend", systemImage: "person.badge.plus") { act("friends",["person_id": person.id.uuidString]) } }
                                    Spacer()
                                    Button("Block", role: .destructive) { pendingBlock = person }
                                }.font(.subheadline)
                            }
                        }
                        if query.count >= 3 && !searching && people.isEmpty { Text("No searchable people found.").font(.caption).foregroundStyle(.secondary) }
                    }
                    friendSection("Requests", values: friends.filter { $0.status == "pending" })
                    friendSection("Friends", values: friends.filter { $0.status == "accepted" })
                }
                if !message.isEmpty { Section { Text(message).font(.callout) } }
            }
        }.disabled(busy).pausePathSurface().navigationTitle("Friends").navigationBarTitleDisplayMode(.inline)
            .task(id: account.userID) {
                while !Task.isCancelled {
                    await load()
                    do { try await Task.sleep(for: .seconds(60)) } catch { return }
                }
            }.refreshable { await load() }
            .task(id: query) {
                people = []; searching = false
                guard configured, query.count >= 3, query.count <= 24, query.allSatisfy({ $0.isASCII && ($0.isLowercase || $0.isNumber || $0 == "_") }) else { return }
                searching = true; defer { if !Task.isCancelled { searching = false } }
                do {
                    try await Task.sleep(for: .milliseconds(350))
                    let response: PeopleResponse = try await SocialAPI.get("search", query: [URLQueryItem(name: "q",value: query)])
                    guard !Task.isCancelled else { return }; people = response.people
                } catch { if !Task.isCancelled { message = error.localizedDescription } }
            }
            .onReceive(NotificationCenter.default.publisher(for: .pausePathSocialChanged)) { _ in Task { await load() } }
            .confirmationDialog("Block this person?", isPresented: Binding(get: { pendingBlock != nil },set: { if !$0 { pendingBlock = nil } }), titleVisibility: .visible) {
                Button("Block person",role: .destructive) { if let person = pendingBlock { act("blocks",["person_id": person.id.uuidString]) }; pendingBlock = nil }
            } message: { Text("Removes your friendship and pending invitations. They cannot find or contact you through Friends. Shared community posts and membership remain visible to group members.") }
    }
    @ViewBuilder private func friendSection(_ title: String, values: [SocialFriend]) -> some View {
        Section(title) {
            ForEach(values) { friend in
                VStack(alignment: .leading, spacing: 8) {
                    Text("@\(friend.username)").font(.headline)
                    if friend.status == "pending" {
                        HStack {
                            if friend.incoming {
                                Button("Accept") { act("friends/\(friend.id)",["action":"accept"]) }
                                Button("Decline") { act("friends/\(friend.id)",["action":"decline"]) }
                            } else {
                                Text("Request sent").foregroundStyle(.secondary)
                                Button("Cancel") { act("friends/\(friend.id)",["action":"cancel"]) }
                            }
                        }.font(.subheadline).buttonStyle(.bordered)
                    } else {
                        HStack {
                            Button("Remove friend") { act("friends/\(friend.id)",["action":"remove"]) }
                            Spacer()
                            Button("Block",role: .destructive) { pendingBlock = SocialPerson(id: friend.person_id,username: friend.username) }
                        }.font(.caption).buttonStyle(.borderless)
                    }
                }.padding(.vertical,4)
            }
            if values.isEmpty { Text(title == "Friends" ? "Your friends will appear here." : "No pending requests.").foregroundStyle(.secondary) }
        }
    }
    private func act(_ path: String,_ body: [String: Any]) {
        guard !busy else { return }; busy = true
        Task {
            defer { busy = false }
            do { try await SocialAPI.post(path,body); message = "Saved"; await load() }
            catch { message = error.localizedDescription }
        }
    }
    @MainActor private func load() async {
        let owner = account.userID
        if loadedOwner != owner { people = []; friends = []; configured = false; loadedOwner = owner }
        guard owner != nil else { configured = false; people = []; friends = []; return }
        do {
            let response: ProfileResponse = try await SocialAPI.get("profile")
            guard owner == account.userID else { return }; configured = response.profile != nil
            if configured { let result: FriendsResponse = try await SocialAPI.get("friends"); guard owner == account.userID else { return }; friends = result.friends }
        } catch { if owner == account.userID { message = error.localizedDescription } }
    }
}

struct FriendPrivacyView: View {
    @State private var draft = SocialProfile()
    @State private var busy = true
    @State private var message = ""
    @State private var loaded = false
    @State private var account = PausePathAccount.shared
    var body: some View {
        Form {
            Section("Your friend username") {
                TextField("e.g. trail_walker", text: $draft.username).textInputAutocapitalization(.never).autocorrectionDisabled()
                Text("3–24 lowercase letters, numbers or underscores. This unique username is separate from your community display name.").font(.caption).foregroundStyle(.secondary)
            }
            Section("Privacy") {
                Toggle("Let people find my username", isOn: $draft.discoverable)
                Toggle("Allow friend requests", isOn: $draft.allow_requests)
                Toggle("Allow walk invitations from friends", isOn: $draft.allow_walk_invites)
                Text("Discovery is off by default. Friends cannot see your location, Health data or recorded walks. Blocking stops direct discovery, requests and invitations; it does not hide shared group content. Turning requests or invitations off declines pending incoming items.").font(.caption).foregroundStyle(.secondary)
            }
            Section { Button("Save preferences") { Task { await save() } }.disabled(!loaded || busy || draft.username.range(of: "^[a-z0-9_]{3,24}$", options: .regularExpression) == nil); if !message.isEmpty { Text(message) } }
        }.disabled(busy).pausePathSurface().navigationTitle("Friend privacy").navigationBarTitleDisplayMode(.inline)
            .task(id: account.userID) {
                busy = true; loaded = false; draft = SocialProfile(); defer { busy = false }
                let owner = account.userID
                do { let response: ProfileResponse = try await SocialAPI.get("profile"); guard owner == account.userID else { return }; draft = response.profile ?? SocialProfile(); loaded = true }
                catch { message = error.localizedDescription }
            }
    }
    @MainActor private func save() async {
        busy = true; defer { busy = false }
        do { try await SocialAPI.post("profile",draft.body); message = "Preferences saved." }
        catch { message = error.localizedDescription }
    }
}

struct BlockedPeopleView: View {
    @State private var people: [SocialPerson] = []
    @State private var message = ""
    @State private var busy = false
    var body: some View {
        List {
            ForEach(people) { person in
                HStack { Text("@\(person.username)"); Spacer(); Button("Unblock") { Task { await unblock(person) } }.disabled(busy) }
            }
            if people.isEmpty { ContentUnavailableView("No blocked people", systemImage: "person.slash") }
            if !message.isEmpty { Text(message) }
        }.pausePathSurface().navigationTitle("Blocked people").navigationBarTitleDisplayMode(.inline).task { await load() }
    }
    private func load() async { do { let response: PeopleResponse = try await SocialAPI.get("blocks"); people = response.people } catch { message = error.localizedDescription } }
    private func unblock(_ person: SocialPerson) async {
        busy = true; defer { busy = false }
        do { try await SocialAPI.post("blocks/\(person.id)/remove"); await load() } catch { message = error.localizedDescription }
    }
}

struct NotificationSettingsView: View {
    @State private var profile: SocialProfile?
    @State private var reminders = false
    @State private var busy = false
    @State private var loaded = false
    @State private var message = ""
    @State private var account = PausePathAccount.shared
    @Environment(\.openURL) private var openURL
    var body: some View {
        Form {
            if !account.isSignedIn { Section { NavigationLink("Sign in with Apple") { AccountView() } } }
            Section {
                NavigationLink { SocialInboxView() } label: { Label("Community inbox", systemImage: "tray") }
                Text("The inbox updates while PausePath is open. Remote push alerts are not enabled in this build.").font(.caption).foregroundStyle(.secondary)
            }
            Section("Inbox updates") {
                if profile != nil {
                    Toggle("Friend requests & invitations", isOn: preference(\.notify_invites))
                    Toggle("Group walks & cancellations", isOn: preference(\.notify_walks))
                    Toggle("Shared goal updates", isOn: preference(\.notify_goals))
                    Button("Save inbox preferences") { Task { await save() } }.disabled(busy)
                } else { NavigationLink("Set up your friend username") { FriendPrivacyView() } }
            }
            Section("On this phone") {
                Toggle("Remind me 15 minutes before joined walks", isOn: $reminders).disabled(!loaded || account.userID == nil)
                    .onChange(of: reminders) { _, enabled in guard loaded else { return }; Task { await setReminders(enabled) } }
                Text("Local reminders use your last synced RSVPs. Open PausePath to pick up cancellations or time changes. Alerts omit route and meeting-point details.").font(.caption).foregroundStyle(.secondary)
                Button("Open iOS notification settings") { if let url = URL(string: UIApplication.openNotificationSettingsURLString) { openURL(url) } }
            }
            if !message.isEmpty { Section { Text(message) } }
        }.pausePathSurface().navigationTitle("Notifications").navigationBarTitleDisplayMode(.inline)
            .task(id: account.userID) { await load() }
    }
    private func preference(_ path: WritableKeyPath<SocialProfile,Bool>) -> Binding<Bool> {
        Binding(get: { profile?[keyPath: path] ?? false },set: { profile?[keyPath: path] = $0 })
    }
    private func load() async {
        loaded = false; profile = nil; let owner = account.userID
        guard owner != nil else { message = "Sign in to manage community notifications."; return }
        do {
            let response: ProfileResponse = try await SocialAPI.get("profile"); guard owner == account.userID else { return }
            profile = response.profile; reminders = UserDefaults.standard.bool(forKey: "pausepath.walkReminders.\(owner ?? "")"); loaded = true
        } catch { message = error.localizedDescription; loaded = account.isSignedIn }
    }
    private func save() async {
        guard let profile else { return }; busy = true; defer { busy = false }
        do { try await SocialAPI.post("notification-preferences",["notify_invites":profile.notify_invites,"notify_walks":profile.notify_walks,"notify_goals":profile.notify_goals]); message = "Inbox preferences saved." } catch { message = error.localizedDescription }
    }
    private func setReminders(_ enabled: Bool) async {
        guard let owner = account.userID else { return }
        if enabled {
            let allowed = (try? await UNUserNotificationCenter.current().requestAuthorization(options: [.alert,.sound])) ?? false
            guard owner == account.userID else { return }
            if !allowed { reminders = false; message = "Notifications are off. Enable them in iOS Settings."; return }
        }
        UserDefaults.standard.set(enabled,forKey: "pausepath.walkReminders.\(owner)")
        if enabled { await SocialActivityStore.shared.refresh() } else { await SocialActivityStore.clearReminders() }
    }
}

struct SocialInboxView: View {
    @State private var store = SocialActivityStore.shared
    @State private var account = PausePathAccount.shared
    @State private var selectedGroup: WalkingCommunity?
    @State private var message = ""
    @State private var busy = false
    var body: some View {
        List {
            if !account.isSignedIn { Section { NavigationLink("Sign in with Apple") { AccountView() }; Text("Sign in to receive friend, walk and shared-goal updates.").font(.caption).foregroundStyle(.secondary) } }
            Section { NavigationLink { FriendsSettingsView() } label: { Label("Friends & requests", systemImage: "person.2") } }
            if !store.invitations.isEmpty {
                Section("Walk invitations") {
                    ForEach(store.invitations) { invite in
                        VStack(alignment: .leading, spacing: 8) {
                            Text(invite.title).font(.headline)
                            Text("@\(invite.sender) · \(invite.community_name)").font(.subheadline)
                            if let date = SocialAPI.date(invite.starts_at) { Text(date.formatted()).font(.caption).foregroundStyle(.secondary) }
                            Text("Accepting joins this community and RSVPs to the walk. Group members will see your username.").font(.caption).foregroundStyle(.secondary)
                            HStack {
                                Button("Join group & walk") { respond(invite,true) }
                                Button("Decline") { respond(invite,false) }
                            }.font(.subheadline).buttonStyle(.bordered).disabled(busy)
                        }.padding(.vertical,5)
                    }
                }
            }
            if account.isSignedIn {
                Section("Updates") {
                    ForEach(store.notifications) { notification in
                        VStack(alignment: .leading, spacing: 8) {
                            HStack(alignment: .top) {
                                if notification.read_at == nil { Circle().fill(PausePathPalette.teal).frame(width: 7,height: 7).padding(.top,6).accessibilityLabel("Unread") }
                                Text(notification.message).font(.subheadline)
                            }
                            if let date = SocialAPI.date(notification.created_at) { Text(date.formatted()).font(.caption).foregroundStyle(.secondary) }
                            if let group = notification.community_id { Button("Open community") { Task { await open(group, notification: notification.id) } }.disabled(busy) }
                            else if notification.read_at == nil { Button("Mark read") { Task { try? await SocialAPI.post("inbox/read",["ids":[notification.id.uuidString]]); await store.refresh() } } }
                        }.padding(.vertical,5)
                    }
                    if store.notifications.isEmpty && store.invitations.isEmpty { ContentUnavailableView("All caught up",systemImage: "tray",description: Text("Friend, walk and goal updates will appear here.")) }
                }
            }
            if let error = store.error { Text(error).font(.callout) }
            if !message.isEmpty { Text(message) }
        }.pausePathSurface().navigationTitle("Community inbox").navigationBarTitleDisplayMode(.inline)
            .task(id: account.userID) { await store.refresh() }.refreshable { await store.refresh() }
            .sheet(item: $selectedGroup) { community in NavigationStack { CommunityHubView(community: community) } }
    }
    private func respond(_ invite: SocialInvitation,_ accept: Bool) {
        busy = true
        Task { defer { busy = false }; do { try await SocialAPI.post("invitations/\(invite.id)",["accept":accept]); message = accept ? "Joined \(invite.community_name) and RSVPed to the walk." : "Invitation declined."; await store.refresh() } catch { message = error.localizedDescription } }
    }
    private func open(_ group: UUID,notification: UUID) async {
        busy = true; defer { busy = false }
        do {
            let groups = try await PausePathAPI.communities()
            guard let match = groups.first(where: { $0.id == group }) else { message = "This group is no longer available, or its invitation needs accepting first."; return }
            try await SocialAPI.post("inbox/read",["ids":[notification.uuidString]])
            selectedGroup = match; await store.refresh()
        } catch { message = error.localizedDescription }
    }
}

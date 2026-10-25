import SwiftUI
import UserNotifications

struct FriendsSettingsView: View {
    @State private var account = PausePathAccount.shared
    @State private var people: [SocialPerson] = []
    @State private var friends: [SocialFriend] = []
    @State private var profile: SocialProfile?
    @State private var query = ""
    @State private var section = "Find"
    @State private var username = ""
    @State private var discoverable = false
    @State private var loadedOwner: String?
    @State private var busy = false
    @State private var loading = true
    @State private var loaded = false
    @State private var searching = false
    @State private var message = ""
    @State private var searchError = ""
    @State private var pendingBlock: SocialPerson?
    private var cleanedQuery: String {
        query.trimmingCharacters(in: .whitespacesAndNewlines).lowercased().replacingOccurrences(of: "@", with: "")
    }
    private var validQuery: Bool { cleanedQuery.range(of: "^[a-z0-9_]{3,24}$", options: .regularExpression) != nil }
    private var cleanUsername: String { username.trimmingCharacters(in: .whitespacesAndNewlines).lowercased() }
    private var requests: [SocialFriend] { friends.filter { $0.status == "pending" } }
    var body: some View {
        List {
            if !account.isSignedIn {
                Section {
                    ContentUnavailableView("Find your trail crew", systemImage: "person.2", description: Text("Sign in to find friends and plan walks together."))
                    NavigationLink("Sign in with Apple") { AccountView() }
                }
            } else {
                if let profile {
                    Section {
                        HStack(spacing: 12) {
                            friendAvatar(profile.username)
                            VStack(alignment: .leading, spacing: 3) {
                                Text("@" + profile.username).font(.headline)
                                Text(profile.discoverable ? "Friends can find this username" : "Your username is hidden from search")
                                    .font(.caption).foregroundStyle(.secondary)
                            }
                        }.padding(.vertical, 4)
                    }.listRowBackground(PausePathPalette.teal.opacity(0.05))
                    if section == "Find" { findSection }
                    else if section == "Requests" { requestSections }
                    else { friendSection("Your friends", values: friends.filter { $0.status == "accepted" }) }
                } else if loading {
                    Section { ProgressView("Getting your friends ready…") }
                } else if loaded {
                    setupSection
                }
                if !message.isEmpty {
                    Section {
                        Label(message, systemImage: "info.circle").font(.callout).foregroundStyle(.secondary)
                        if !loaded { Button("Try again") { Task { await load() } } }
                    }
                }
            }
        }.pausePathSurface().navigationTitle("Find friends").navigationBarTitleDisplayMode(.inline)
            .safeAreaInset(edge: .top, spacing: 0) {
                if account.isSignedIn, profile != nil {
                    VStack(spacing: 0) {
                        PathSectionPicker(titles: ["Find", "Requests", "Friends"], selection: $section)
                        if !requests.isEmpty && section != "Requests" {
                            Button { section = "Requests" } label: {
                                Label("\(requests.filter(\.incoming).count) received · \(requests.filter { !$0.incoming }.count) sent", systemImage: "envelope")
                                    .font(.caption.weight(.semibold)).padding(.bottom, 8)
                            }.tint(PausePathPalette.teal)
                        }
                    }.background(.regularMaterial)
                }
            }
            .toolbar {
                if account.isSignedIn, profile != nil {
                    ToolbarItem(placement: .topBarTrailing) {
                        NavigationLink { FriendPrivacyView() } label: { Image(systemName: "slider.horizontal.3") }
                            .accessibilityLabel("Friend settings")
                    }
                }
            }
            .task(id: account.userID) {
                while !Task.isCancelled {
                    await load()
                    do { try await Task.sleep(for: .seconds(60)) } catch { return }
                }
            }
            .refreshable { await load(); if validQuery { await search() } }
            .task(id: cleanedQuery) { await search() }
            .onReceive(NotificationCenter.default.publisher(for: .pausePathSocialChanged)) { _ in Task { await load() } }
            .confirmationDialog("Block this person?", isPresented: Binding(get: { pendingBlock != nil },set: { if !$0 { pendingBlock = nil } }), titleVisibility: .visible) {
                Button("Block person",role: .destructive) { if let person = pendingBlock { act("blocks",["person_id": person.id.uuidString]) }; pendingBlock = nil }
            } message: { Text("Removes your friendship and pending invitations. Shared community posts and membership remain visible to group members.") }
    }
    private var setupSection: some View {
        Section {
            VStack(alignment: .leading, spacing: 12) {
                Image(systemName: "person.crop.circle.badge.plus").font(.largeTitle).foregroundStyle(PausePathPalette.teal).accessibilityHidden(true)
                Text("Pick a trail name.").font(.system(.title2, design: .rounded).bold())
                Text("Choose a unique username to start adding friends.").font(.subheadline).foregroundStyle(.secondary)
                HStack {
                    Text("@").foregroundStyle(.secondary)
                    TextField("trail_walker", text: $username).textInputAutocapitalization(.never).autocorrectionDisabled()
                        .accessibilityLabel("Your friend username")
                }.padding(12).background(PausePathPalette.teal.opacity(0.06), in: RoundedRectangle(cornerRadius: 12))
                Text("3–24 letters, numbers or underscores. Separate from your group display name.").font(.caption).foregroundStyle(.secondary)
                Toggle("Let friends find me by username", isOn: $discoverable).tint(PausePathPalette.teal)
                Button { Task { await createProfile() } } label: {
                    HStack { if busy { ProgressView() }; Text(busy ? "Saving…" : "Start finding friends") }
                        .frame(maxWidth: .infinity, minHeight: 44)
                }.buttonStyle(.borderedProminent).tint(PausePathPalette.lime).foregroundStyle(PausePathPalette.ink)
                    .disabled(busy || cleanUsername.range(of: "^[a-z0-9_]{3,24}$", options: .regularExpression) == nil)
                Text("Search visibility is optional. Friends don't see your location or Health data.").font(.caption).foregroundStyle(.secondary)
            }.padding(.vertical, 10)
        }
    }
    private var findSection: some View {
        Section {
            HStack(spacing: 10) {
                Image(systemName: "magnifyingglass").foregroundStyle(PausePathPalette.teal)
                TextField("Search a friend's username", text: $query).textInputAutocapitalization(.never).autocorrectionDisabled().submitLabel(.search)
                    .accessibilityLabel("Search friends by username")
                if !query.isEmpty {
                    Button { query = "" } label: { Image(systemName: "xmark.circle.fill").foregroundStyle(.secondary) }
                        .buttonStyle(.borderless).accessibilityLabel("Clear friend search")
                }
            }.frame(minHeight: 44)
            if searching { ProgressView("Looking for your crew…") }
            ForEach(people) { person in
                HStack(spacing: 12) {
                    friendAvatar(person.username)
                    Text("@\(person.username)").font(.subheadline.bold())
                    Spacer(minLength: 4)
                    if let connection = friends.first(where: { $0.person_id == person.id }) {
                        Text(connection.status == "accepted" ? "Friends" : "Pending").font(.caption).foregroundStyle(.secondary)
                    } else {
                        Button("Add", systemImage: "person.badge.plus") { act("friends", ["person_id": person.id.uuidString]) }
                            .buttonStyle(.bordered).tint(PausePathPalette.teal).disabled(busy)
                            .accessibilityLabel("Add @\(person.username) as a friend")
                    }
                    Menu {
                        Button("Block", role: .destructive) { pendingBlock = person }
                    } label: { Image(systemName: "ellipsis").frame(width: 44, height: 44) }.accessibilityLabel("Options for @\(person.username)")
                }.padding(.vertical, 4)
            }
            if !searchError.isEmpty { Label(searchError, systemImage: "wifi.exclamationmark").font(.callout).foregroundStyle(.secondary) }
            else if !searching && people.isEmpty {
                if validQuery {
                    ContentUnavailableView("No matching friends", systemImage: "person.crop.circle.badge.questionmark", description: Text("Check the username. Your friend also needs to turn on search visibility."))
                } else {
                    ContentUnavailableView("Find your next walking buddy", systemImage: "person.2", description: Text(query.isEmpty ? "Enter at least 3 characters of a friend's username." : "Use 3–24 letters, numbers or underscores. You can paste a username with @."))
                }
            }
        } header: { Text("Find your crew") }
    }
    @ViewBuilder private var requestSections: some View {
        friendSection("Received requests", values: requests.filter(\.incoming))
        friendSection("Sent requests", values: requests.filter { !$0.incoming })
    }
    @ViewBuilder private func friendSection(_ title: String, values: [SocialFriend]) -> some View {
        Section(title) {
            ForEach(values) { friend in
                VStack(alignment: .leading, spacing: 10) {
                    HStack(spacing: 12) {
                        friendAvatar(friend.username)
                        Text("@\(friend.username)").font(.headline)
                        Spacer()
                        if friend.status == "accepted" {
                            Menu {
                                Button("Remove friend", role: .destructive) { act("friends/\(friend.id)",["action":"remove"]) }
                                Button("Block",role: .destructive) { pendingBlock = SocialPerson(id: friend.person_id,username: friend.username) }
                            } label: { Image(systemName: "ellipsis").frame(width: 44, height: 44) }.accessibilityLabel("Options for @\(friend.username)")
                        }
                    }
                    if friend.status == "pending" {
                        HStack {
                            if friend.incoming {
                                Button("Accept") { act("friends/\(friend.id)",["action":"accept"]) }.tint(PausePathPalette.teal)
                                Button("Decline") { act("friends/\(friend.id)",["action":"decline"]) }
                            } else {
                                Label("Request sent", systemImage: "paperplane").foregroundStyle(.secondary)
                                Spacer()
                                Button("Cancel") { act("friends/\(friend.id)",["action":"cancel"]) }
                            }
                        }.font(.subheadline).buttonStyle(.bordered).disabled(busy)
                    }
                }.padding(.vertical, 6)
            }
            if values.isEmpty {
                Label(title == "Your friends" ? "Your walking crew will appear here." : "No \(title.lowercased()).", systemImage: title == "Your friends" ? "person.2" : "envelope.open")
                    .font(.subheadline).foregroundStyle(.secondary).padding(.vertical, 12)
            }
        }
    }
    private func friendAvatar(_ name: String) -> some View {
        Text(String(name.prefix(1)).uppercased()).font(.system(.headline, design: .rounded))
            .foregroundStyle(PausePathPalette.teal).frame(width: 42, height: 42)
            .background(PausePathPalette.teal.opacity(0.1), in: Circle()).accessibilityHidden(true)
    }
    @MainActor private func search() async {
        let term = cleanedQuery
        let owner = account.userID
        people = []; searching = false; searchError = ""
        guard owner != nil, validQuery else { return }
        searching = true
        defer { if !Task.isCancelled { searching = false } }
        do {
            try await Task.sleep(for: .milliseconds(350))
            let response: PeopleResponse = try await SocialAPI.get("search", query: [URLQueryItem(name: "q", value: term)])
            guard !Task.isCancelled, owner == account.userID, cleanedQuery == term else { return }
            people = response.people
        } catch {
            if !Task.isCancelled, owner == account.userID { searchError = "Search couldn't connect. Edit the username or pull down to try again." }
        }
    }
    private func act(_ path: String,_ body: [String: Any]) {
        guard !busy else { return }; busy = true
        Task {
            defer { busy = false }
            do { try await SocialAPI.post(path,body); message = ""; await load() }
            catch { message = error.localizedDescription }
        }
    }
    @MainActor private func createProfile() async {
        guard !busy else { return }; busy = true; defer { busy = false }
        var draft = SocialProfile(); draft.username = cleanUsername; draft.discoverable = discoverable
        do { try await SocialAPI.post("profile", draft.body); await load() }
        catch { message = error.localizedDescription }
    }
    @MainActor private func load() async {
        let owner = account.userID
        if loadedOwner != owner { people = []; friends = []; profile = nil; query = ""; message = ""; searchError = ""; loaded = false; loadedOwner = owner }
        guard owner != nil else { profile = nil; people = []; friends = []; loading = false; return }
        loading = true; defer { loading = false }
        do {
            let response: ProfileResponse = try await SocialAPI.get("profile")
            guard owner == account.userID, !Task.isCancelled else { return }; profile = response.profile; loaded = true; message = ""
            if profile != nil {
                let result: FriendsResponse = try await SocialAPI.get("friends")
                guard owner == account.userID, !Task.isCancelled else { return }; friends = result.friends
            }
        } catch { if owner == account.userID, !Task.isCancelled { message = "Friends couldn't refresh. Pull down to retry." } }
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
            Section("Your username") {
                TextField("e.g. trail_walker", text: $draft.username).textInputAutocapitalization(.never).autocorrectionDisabled()
                Text("3–24 lowercase letters, numbers or underscores. This unique username is separate from your community display name.").font(.caption).foregroundStyle(.secondary)
            }
            Section("Who can reach you") {
                Toggle("Let people find my username", isOn: $draft.discoverable)
                Toggle("Allow friend requests", isOn: $draft.allow_requests)
                Toggle("Allow walk invitations from friends", isOn: $draft.allow_walk_invites)
                Text("Discovery is off by default. Friends cannot see your location, Health data or recorded walks. Blocking stops direct discovery, requests and invitations; it does not hide shared group content. Turning requests or invitations off declines pending incoming items.").font(.caption).foregroundStyle(.secondary)
            }
            Section { Button("Save changes") { Task { await save() } }.disabled(!loaded || busy || draft.username.range(of: "^[a-z0-9_]{3,24}$", options: .regularExpression) == nil); if !message.isEmpty { Text(message) } }
            Section {
                NavigationLink { BlockedPeopleView() } label: { Label("Blocked people", systemImage: "person.slash") }
            }
        }.disabled(busy).pausePathSurface().navigationTitle("Friend settings").navigationBarTitleDisplayMode(.inline)
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

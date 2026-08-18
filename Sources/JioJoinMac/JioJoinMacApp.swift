import AppKit
import SwiftUI
import UniformTypeIdentifiers

private enum AppSection: String, CaseIterable, Identifiable {
    case calls
    case history
    case settings

    var id: String { rawValue }
    var title: String {
        switch self {
        case .calls: return "Keypad"
        case .history: return "Recents"
        case .settings: return "Settings"
        }
    }
    var symbol: String {
        switch self {
        case .calls: return "circle.grid.3x3.fill"
        case .history: return "clock.fill"
        case .settings: return "gearshape.fill"
        }
    }
}

private enum HistoryFilter: String, CaseIterable, Identifiable {
    case all = "All"
    case missed = "Missed"
    var id: String { rawValue }
}

@main
struct JioJoinMacApp: App {
    @Environment(\.scenePhase) private var scenePhase
    @StateObject private var engine = EngineManager()
    @StateObject private var provisioner = RouterProvisioner()
    @StateObject private var loginItemManager = LoginItemManager()
    @AppStorage("JioJoinRouter") private var router = LocalNetwork.defaultGateway()
    @AppStorage("JioJoinDeviceAlias") private var alias = DeviceIdentity.defaultAlias()
    @AppStorage("JioJoinAutoRegister") private var autoRegister = true
    @AppStorage("JioJoinNotificationsEnabled") private var notificationsEnabled = true
    @AppStorage("JioJoinLaunchAtLogin") private var launchAtLogin = true
    @State private var selection = AppSection.calls
    @State private var otp = ""
    @State private var number = ""
    @State private var credentials = CredentialStore.load()
    @State private var errorMessage: String?
    @State private var notificationStatus = "Checking…"
    @State private var registrationInProgress = false
    @State private var performedStartupTasks = false
    @State private var confirmingForget = false
    @State private var confirmingClearHistory = false

    var body: some Scene {
        WindowGroup("JioJoin for Mac", id: "main") {
            NavigationSplitView {
                AppSidebar(selection: $selection, engine: engine, authorized: credentials != nil)
            } detail: {
                ZStack {
                    AppBackground()
                    detailView
                }
                .navigationTitle(selection.title)
                .toolbar {
                    ToolbarItem(placement: .primaryAction) {
                        ConnectionPill(engine: engine)
                    }
                }
            }
            .navigationSplitViewStyle(.balanced)
            .frame(minWidth: 920, minHeight: 650)
            .task { await performStartupTasks() }
            .onChange(of: notificationsEnabled) { enabled in
                Task { await updateNotificationPreference(enabled: enabled) }
            }
            .onChange(of: launchAtLogin) { enabled in
                updateLaunchAtLogin(enabled: enabled)
            }
            .onChange(of: autoRegister) { enabled in
                engine.setAutomaticRecoveryEnabled(enabled && credentials != nil)
            }
            .onChange(of: router) { _ in configureReliability(enabled: autoRegister && credentials != nil) }
            .onChange(of: alias) { _ in configureReliability(enabled: autoRegister && credentials != nil) }
            .onChange(of: selection) { section in
                if section == .history { engine.markMissedCallsRead() }
            }
            .onChange(of: scenePhase) { phase in
                guard phase == .active else { return }
                Task { notificationStatus = await NotificationManager.shared.authorizationDescription() }
            }
            .alert("JioJoin for Mac", isPresented: Binding(
                get: { errorMessage != nil },
                set: { if !$0 { errorMessage = nil } }
            )) {
                Button("OK") { errorMessage = nil }
            } message: {
                Text(errorMessage ?? "")
            }
            .confirmationDialog("Forget this Mac's authorization?", isPresented: $confirmingForget) {
                Button("Forget Authorization", role: .destructive) { forgetAuthorization() }
                Button("Cancel", role: .cancel) {}
            } message: {
                Text("This removes the SIP credentials from this Mac's Keychain. Call history stays on this Mac.")
            }
            .confirmationDialog("Clear all call history?", isPresented: $confirmingClearHistory) {
                Button("Clear History", role: .destructive) { engine.clearHistory() }
                Button("Cancel", role: .cancel) {}
            }
        }
        .windowStyle(.titleBar)
        .defaultSize(width: 1120, height: 760)

        MenuBarExtra {
            MenuBarStatusView(engine: engine, onShowRecents: {
                selection = .history
                engine.markMissedCallsRead()
            })
                .task { await performStartupTasks() }
        } label: {
            ZStack(alignment: .topTrailing) {
                Image(systemName: engine.activeCall == nil ? "phone.fill" : "phone.connection.fill")
                if engine.hasUnreadMissedCall {
                    Circle()
                        .fill(Color.red)
                        .frame(width: 6, height: 6)
                        .offset(x: 4, y: -3)
                        .accessibilityHidden(true)
                }
            }
            .accessibilityLabel(engine.hasUnreadMissedCall ? "JioJoin, missed call" : "JioJoin")
        }
    }

    @ViewBuilder
    private var detailView: some View {
        switch selection {
        case .calls:
            CallsView(number: $number, engine: engine, onShowHistory: { selection = .history })
        case .history:
            HistoryView(engine: engine, onCallBack: { value in
                number = value
                selection = .calls
            }, onClear: { confirmingClearHistory = true })
        case .settings:
            SettingsView(
                engine: engine,
                provisioner: provisioner,
                router: $router,
                alias: $alias,
                otp: $otp,
                credentials: credentials,
                autoRegister: $autoRegister,
                launchAtLogin: $launchAtLogin,
                loginItemManager: loginItemManager,
                notificationsEnabled: $notificationsEnabled,
                notificationStatus: notificationStatus,
                registrationInProgress: registrationInProgress,
                requestOTP: requestOTP,
                verifyOTP: verifyOTP,
                registerNow: { Task { await registerNow() } },
                forgetAuthorization: { confirmingForget = true },
                exportDiagnostics: exportDiagnostics,
                openNotificationSettings: openNotificationSettings,
                openLoginItemSettings: openLoginItemSettings
            )
        }
    }

    @MainActor
    private func performStartupTasks() async {
        guard !performedStartupTasks else { return }
        performedStartupTasks = true
        NotificationManager.shared.configureCallActions(
            answer: { engine.answer() },
            decline: { engine.reject() }
        )
        updateLaunchAtLogin(enabled: launchAtLogin, reportErrors: false)
        notificationStatus = notificationsEnabled ? "Permission requested" : "Disabled"
        Task { @MainActor in
            if notificationsEnabled { _ = await NotificationManager.shared.requestAuthorization() }
            notificationStatus = await NotificationManager.shared.authorizationDescription()
        }
        if credentials == nil { selection = .settings }
        configureReliability(enabled: false)
        if autoRegister, credentials != nil { await registerNow() }
        configureReliability(enabled: autoRegister && credentials != nil)
    }

    @MainActor
    private func updateNotificationPreference(enabled: Bool) async {
        if enabled { _ = await NotificationManager.shared.requestAuthorization() }
        else { NotificationManager.shared.clearIncomingCall() }
        notificationStatus = await NotificationManager.shared.authorizationDescription()
    }

    @MainActor
    private func registerNow(reportErrors: Bool = true) async {
        guard credentials != nil, !registrationInProgress, !engine.registered else { return }
        registrationInProgress = true
        defer { registrationInProgress = false }
        do {
            let refreshed = try await provisioner.refreshCredentials(router: router, deviceAlias: alias)
            credentials = refreshed
            try engine.register(refreshed)
        } catch {
            if reportErrors { errorMessage = error.localizedDescription }
        }
    }

    private func requestOTP() {
        Task {
            do { try await provisioner.requestOTP(router: router, deviceAlias: alias) }
            catch { errorMessage = error.localizedDescription }
        }
    }

    private func verifyOTP() {
        Task {
            do {
                credentials = try await provisioner.verify(otp: otp)
                otp = ""
                if autoRegister {
                    await registerNow()
                    configureReliability(enabled: true)
                }
            } catch { errorMessage = error.localizedDescription }
        }
    }

    private func forgetAuthorization() {
        engine.stop()
        CredentialStore.remove()
        credentials = nil
        configureReliability(enabled: false)
    }

    @MainActor
    private func configureReliability(enabled: Bool) {
        let recoveryRouter = router
        let recoveryAlias = alias
        engine.configureReliability(enabled: enabled) { [weak engine, weak provisioner] in
            guard let engine, let provisioner else {
                throw NSError(domain: "JioJoinMac", code: 2,
                              userInfo: [NSLocalizedDescriptionKey: "Recovery components are unavailable."])
            }
            let refreshed = try await provisioner.refreshCredentials(
                router: recoveryRouter, deviceAlias: recoveryAlias
            )
            try engine.register(refreshed)
        }
    }

    @MainActor
    private func exportDiagnostics() {
        let panel = NSSavePanel()
        panel.title = "Export JioJoin Diagnostics"
        panel.nameFieldStringValue = "JioJoin-Diagnostics-\(Int(Date().timeIntervalSince1970)).txt"
        panel.allowedContentTypes = [.plainText]
        guard panel.runModal() == .OK, let url = panel.url else { return }
        do { try engine.exportDiagnostics(to: url) }
        catch { errorMessage = "Could not export diagnostics: \(error.localizedDescription)" }
    }

    private func openNotificationSettings() {
        guard let url = URL(string: "x-apple.systempreferences:com.apple.Notifications-Settings.extension") else { return }
        NSWorkspace.shared.open(url)
    }

    @MainActor
    private func updateLaunchAtLogin(enabled: Bool, reportErrors: Bool = true) {
        do {
            try loginItemManager.setEnabled(enabled)
        } catch {
            loginItemManager.refresh()
            if reportErrors { errorMessage = "Could not update Launch at Login: \(error.localizedDescription)" }
        }
    }

    private func openLoginItemSettings() {
        guard let url = URL(string: "x-apple.systempreferences:com.apple.LoginItems-Settings.extension") else { return }
        NSWorkspace.shared.open(url)
    }
}

private struct AppSidebar: View {
    @Binding var selection: AppSection
    @ObservedObject var engine: EngineManager
    let authorized: Bool

    var body: some View {
        VStack(spacing: 0) {
            HStack(spacing: 12) {
                ZStack {
                    RoundedRectangle(cornerRadius: 12, style: .continuous)
                        .fill(Color.green)
                    Image(systemName: "phone.fill").font(.system(size: 19, weight: .semibold)).foregroundStyle(.white)
                }
                .frame(width: 42, height: 42)
                VStack(alignment: .leading, spacing: 2) {
                    Text("JioJoin").font(.headline)
                    Text("for Mac").font(.caption).foregroundStyle(.secondary)
                }
                Spacer()
            }
            .padding(.horizontal, 16).padding(.vertical, 18)

            List(selection: $selection) {
                ForEach(AppSection.allCases) { section in
                    Label(section.title, systemImage: section.symbol)
                        .tag(section)
                        .padding(.vertical, 4)
                }
            }
            .listStyle(.sidebar)

            VStack(alignment: .leading, spacing: 10) {
                HStack(spacing: 8) {
                    Circle().fill(engine.registered ? Color.green : Color.secondary.opacity(0.5)).frame(width: 8, height: 8)
                    Text(engine.state).font(.caption).lineLimit(2)
                }
                HStack(spacing: 6) {
                    Image(systemName: authorized ? "lock.shield.fill" : "lock.trianglebadge.exclamationmark")
                    Text(authorized ? "Authorized on this Mac" : "Setup required")
                }
                .font(.caption2).foregroundStyle(.secondary)
            }
            .padding(14)
            .frame(maxWidth: .infinity, alignment: .leading)
            .background(Color(nsColor: .controlBackgroundColor), in: RoundedRectangle(cornerRadius: 14, style: .continuous))
            .overlay(RoundedRectangle(cornerRadius: 14).stroke(Color.primary.opacity(0.07)))
            .padding(12)
        }
        .frame(minWidth: 220)
    }
}

private struct ConnectionPill: View {
    @ObservedObject var engine: EngineManager

    var body: some View {
        HStack(spacing: 7) {
            Circle().fill(engine.registered ? Color.green : Color.orange).frame(width: 7, height: 7)
            Text(engine.registered ? "Connected" : "Offline").font(.caption.weight(.medium))
        }
        .padding(.horizontal, 11).padding(.vertical, 6)
        .background(.thinMaterial, in: Capsule())
    }
}

private struct MenuBarStatusView: View {
    @ObservedObject var engine: EngineManager
    let onShowRecents: () -> Void
    @Environment(\.openWindow) private var openWindow

    var body: some View {
        if let call = engine.activeCall, call.direction == .incoming, call.connectedAt == nil {
            Text("Incoming call")
            Text(call.remoteParty)
            Divider()
            Button("Answer", systemImage: "phone.fill") { engine.answer() }
            Button("Decline", systemImage: "phone.down.fill", role: .destructive) { engine.reject() }
            Divider()
        } else if let call = engine.activeCall {
            Text(engine.state)
            Text(call.remoteParty)
            Divider()
            if call.connectedAt != nil {
                Button(engine.isOnHold ? "Resume Call" : "Hold Call",
                       systemImage: engine.isOnHold ? "play.fill" : "pause.fill") {
                    if engine.isOnHold { engine.resume() } else { engine.hold() }
                }
            }
            Button("End Call", systemImage: "phone.down.fill", role: .destructive) { engine.hangup() }
            Divider()
        } else {
            Label(engine.registered ? "Ready for calls" : "Not connected",
                  systemImage: engine.registered ? "checkmark.circle.fill" : "exclamationmark.circle")
            Text(engine.state)
            Divider()
        }

        Button("Open JioJoin", systemImage: "macwindow") {
            openWindow(id: "main")
            NSApp.activate(ignoringOtherApps: true)
        }
        if engine.hasUnreadMissedCall {
            Button("View Missed Calls", systemImage: "phone.badge.xmark") {
                onShowRecents()
                openWindow(id: "main")
                NSApp.activate(ignoringOtherApps: true)
            }
        }
        Divider()
        Button("Quit JioJoin") {
            engine.stop()
            NSApp.terminate(nil)
        }
    }
}

private struct AppBackground: View {
    var body: some View {
        Color(nsColor: .windowBackgroundColor).ignoresSafeArea()
    }
}

private struct CallsView: View {
    @Binding var number: String
    @ObservedObject var engine: EngineManager
    let onShowHistory: () -> Void

    private let keys = ["1", "2", "3", "4", "5", "6", "7", "8", "9", "+", "0", "delete.left"]
    private let columns = Array(repeating: GridItem(.flexible(), spacing: 14), count: 3)

    var body: some View {
        ScrollView {
            HStack(alignment: .top, spacing: 22) {
                VStack(spacing: 18) {
                    if let call = engine.activeCall { ActiveCallCard(call: call, engine: engine) }
                    DialerCard(number: $number, engine: engine, keys: keys, columns: columns)
                }
                .frame(maxWidth: 510)

                VStack(spacing: 18) {
                    ReadinessCard(engine: engine)
                    RecentCallsCard(engine: engine, number: $number, onShowHistory: onShowHistory)
                }
                .frame(maxWidth: 380)
            }
            .frame(maxWidth: 930)
            .padding(28)
        }
    }
}

private struct DialerCard: View {
    @Binding var number: String
    @ObservedObject var engine: EngineManager
    let keys: [String]
    let columns: [GridItem]

    var body: some View {
        VStack(spacing: 22) {
            VStack(spacing: 7) {
                Text("New call").font(.title2.bold())
                Text("Enter a phone number").font(.callout).foregroundStyle(.secondary)
            }
            TextField("Phone number", text: $number)
                .textFieldStyle(.plain)
                .font(.system(size: 29, weight: .medium, design: .rounded))
                .multilineTextAlignment(.center)
                .padding(.vertical, 13).padding(.horizontal, 18)
                .background(Color.primary.opacity(0.055), in: RoundedRectangle(cornerRadius: 14, style: .continuous))
                .overlay(RoundedRectangle(cornerRadius: 14).stroke(Color.primary.opacity(0.08)))

            LazyVGrid(columns: columns, spacing: 13) {
                ForEach(keys, id: \.self) { key in
                    Button {
                        if key == "delete.left" { if !number.isEmpty { number.removeLast() } }
                        else { number.append(key) }
                    } label: {
                        Group {
                            if key == "delete.left" { Image(systemName: key) }
                            else { Text(key) }
                        }
                        .font(.system(size: 20, weight: .medium, design: .rounded))
                        .frame(width: 58, height: 58)
                        .contentShape(Circle())
                    }
                    .buttonStyle(KeypadButtonStyle())
                }
            }

            Button { engine.dial(number) } label: {
                Image(systemName: "phone.fill")
                    .font(.system(size: 21, weight: .semibold))
                    .foregroundStyle(.white)
                    .frame(width: 60, height: 60)
                    .background(Color.green, in: Circle())
            }
            .buttonStyle(.plain)
            .accessibilityLabel("Call")
            .disabled(!engine.registered || number.isEmpty || engine.inCall)
            .opacity(!engine.registered || number.isEmpty || engine.inCall ? 0.42 : 1)
        }
        .modernCard()
    }
}

private struct ActiveCallCard: View {
    let call: ActiveCall
    @ObservedObject var engine: EngineManager

    var body: some View {
        VStack(spacing: 16) {
            ZStack {
                Circle().fill(Color.green.opacity(0.13)).frame(width: 70, height: 70)
                Image(systemName: call.direction.symbol).font(.system(size: 26, weight: .semibold)).foregroundStyle(.green)
            }
            VStack(spacing: 4) {
                Text(engine.state).font(.caption.weight(.semibold)).foregroundStyle(.secondary).textCase(.uppercase)
                Text(call.remoteParty).font(.title2.bold()).textSelection(.enabled)
            }
            if call.direction == .incoming && call.connectedAt == nil {
                HStack(spacing: 12) {
                    Button("Decline", role: .destructive) { engine.reject() }.buttonStyle(.borderedProminent).tint(.red)
                    Button("Answer") { engine.answer() }.buttonStyle(.borderedProminent).tint(.green)
                }
            } else {
                HStack(spacing: 12) {
                    if call.connectedAt != nil {
                        Button(engine.isOnHold ? "Resume" : "Hold") {
                            if engine.isOnHold { engine.resume() } else { engine.hold() }
                        }
                        .buttonStyle(.borderedProminent)
                        .tint(.gray)
                    }
                    Button("End Call", role: .destructive) { engine.hangup() }
                        .buttonStyle(.borderedProminent).tint(.red)
                }
            }
        }
        .frame(maxWidth: .infinity)
        .modernCard(accent: .green)
    }
}

private struct ReadinessCard: View {
    @ObservedObject var engine: EngineManager

    var body: some View {
        HStack(spacing: 14) {
            ZStack {
                Circle().fill((engine.registered ? Color.green : Color.orange).opacity(0.14)).frame(width: 48, height: 48)
                Image(systemName: engine.registered ? "checkmark.circle.fill" : "wifi.exclamationmark")
                    .font(.title2).foregroundStyle(engine.registered ? .green : .orange)
            }
            VStack(alignment: .leading, spacing: 3) {
                Text(engine.registered ? "Ready to call" : "Not connected").font(.headline)
                Text(engine.state).font(.caption).foregroundStyle(.secondary).lineLimit(2)
            }
            Spacer()
        }
        .modernCard()
    }
}

private struct RecentCallsCard: View {
    @ObservedObject var engine: EngineManager
    @Binding var number: String
    let onShowHistory: () -> Void

    var body: some View {
        VStack(alignment: .leading, spacing: 14) {
            HStack {
                Text("Recent calls").font(.headline)
                Spacer()
                Button("View all", action: onShowHistory).buttonStyle(.plain).foregroundStyle(.primary)
            }
            if engine.callHistory.isEmpty {
                VStack(spacing: 9) {
                    Image(systemName: "clock.arrow.circlepath").font(.title).foregroundStyle(.tertiary)
                    Text("Your call history will appear here").font(.callout).foregroundStyle(.secondary)
                }
                .frame(maxWidth: .infinity).padding(.vertical, 28)
            } else {
                ForEach(engine.callHistory.prefix(5)) { record in
                    HStack(spacing: 10) {
                        CallIcon(record: record, compact: true)
                        VStack(alignment: .leading, spacing: 2) {
                            Text(record.remoteParty).font(.callout.weight(.medium)).lineLimit(1)
                            Text(record.outcome.title).font(.caption).foregroundStyle(record.outcome == .missed ? .red : .secondary)
                        }
                        Spacer()
                        Button { number = record.remoteParty } label: { Image(systemName: "phone.fill") }
                            .buttonStyle(.borderless).help("Use this number")
                    }
                    if record.id != engine.callHistory.prefix(5).last?.id { Divider() }
                }
            }
        }
        .modernCard()
    }
}

private struct HistoryView: View {
    @ObservedObject var engine: EngineManager
    let onCallBack: (String) -> Void
    let onClear: () -> Void
    @State private var filter = HistoryFilter.all
    @State private var search = ""

    private var filteredRecords: [CallRecord] {
        engine.callHistory.filter { record in
            (filter == .all || record.outcome == .missed) &&
            (search.isEmpty || record.remoteParty.localizedCaseInsensitiveContains(search))
        }
    }

    var body: some View {
        VStack(spacing: 0) {
            HStack(spacing: 12) {
                Picker("Filter", selection: $filter) {
                    ForEach(HistoryFilter.allCases) { Text($0.rawValue).tag($0) }
                }
                .pickerStyle(.segmented).frame(width: 190)
                TextField("Search call history", text: $search).textFieldStyle(.roundedBorder).frame(maxWidth: 280)
                Spacer()
                Button("Clear", role: .destructive, action: onClear).disabled(engine.callHistory.isEmpty)
            }
            .padding(.horizontal, 28).padding(.vertical, 18)

            if filteredRecords.isEmpty {
                Spacer()
                VStack(spacing: 12) {
                    Image(systemName: filter == .missed ? "phone.badge.xmark" : "clock.arrow.circlepath")
                        .font(.system(size: 38)).foregroundStyle(.tertiary)
                    Text(search.isEmpty ? "No calls yet" : "No matching calls").font(.title3.bold())
                    Text("Incoming, outgoing, and missed calls are stored locally on this Mac.")
                        .font(.callout).foregroundStyle(.secondary)
                }
                Spacer()
            } else {
                ScrollView {
                    LazyVStack(spacing: 10) {
                        ForEach(filteredRecords) { record in
                            HistoryRow(record: record, callBack: { onCallBack(record.remoteParty) })
                        }
                    }
                    .frame(maxWidth: 850).padding(.horizontal, 28).padding(.bottom, 28)
                }
            }
        }
    }
}

private struct HistoryRow: View {
    let record: CallRecord
    let callBack: () -> Void

    var body: some View {
        HStack(spacing: 14) {
            CallIcon(record: record, compact: false)
            VStack(alignment: .leading, spacing: 4) {
                Text(record.remoteParty).font(.headline).textSelection(.enabled)
                HStack(spacing: 5) {
                    Text(record.direction.title)
                    Text("•")
                    Text(record.outcome.title)
                }
                .font(.caption).foregroundStyle(record.outcome == .missed ? .red : .secondary)
            }
            Spacer()
            VStack(alignment: .trailing, spacing: 4) {
                Text(record.startedAt.formatted(date: .abbreviated, time: .shortened)).font(.callout)
                if record.duration > 0 { Text(formatDuration(record.duration)).font(.caption).foregroundStyle(.secondary) }
            }
            Button(action: callBack) { Image(systemName: "phone.fill").frame(width: 30, height: 30) }
                .buttonStyle(.bordered).help("Call back")
        }
        .modernCard(padding: 16)
    }
}

private struct CallIcon: View {
    let record: CallRecord
    let compact: Bool

    var body: some View {
        ZStack {
            Circle().fill(iconColor.opacity(0.14))
            Image(systemName: record.direction.symbol).font(.system(size: compact ? 12 : 16, weight: .semibold)).foregroundStyle(iconColor)
        }
        .frame(width: compact ? 32 : 44, height: compact ? 32 : 44)
    }

    private var iconColor: Color {
        if record.outcome == .missed || record.outcome == .declined { return .red }
        return .green
    }
}

private struct SettingsView: View {
    @ObservedObject var engine: EngineManager
    @ObservedObject var provisioner: RouterProvisioner
    @Binding var router: String
    @Binding var alias: String
    @Binding var otp: String
    let credentials: SIPCredentials?
    @Binding var autoRegister: Bool
    @Binding var launchAtLogin: Bool
    @ObservedObject var loginItemManager: LoginItemManager
    @Binding var notificationsEnabled: Bool
    let notificationStatus: String
    let registrationInProgress: Bool
    let requestOTP: () -> Void
    let verifyOTP: () -> Void
    let registerNow: () -> Void
    let forgetAuthorization: () -> Void
    let exportDiagnostics: () -> Void
    let openNotificationSettings: () -> Void
    let openLoginItemSettings: () -> Void

    var body: some View {
        ScrollView {
            VStack(spacing: 18) {
                SettingsSection(title: "Account & registration", symbol: "person.crop.circle.badge.checkmark") {
                    SettingStatusRow(title: "Authorization", value: credentials == nil ? "Setup required" : "Stored securely in Keychain",
                                     symbol: credentials == nil ? "exclamationmark.triangle.fill" : "checkmark.shield.fill",
                                     color: credentials == nil ? .orange : .green)
                    Divider()
                    Toggle(isOn: $autoRegister) {
                        SettingLabel(title: "Register automatically", subtitle: "Connect to JioFiberVoice whenever the app opens", symbol: "bolt.horizontal.circle")
                    }
                    Divider()
                    HStack {
                        Toggle(isOn: $launchAtLogin) {
                            SettingLabel(title: "Launch at login", subtitle: "Keep JioJoin available in the menu bar after you sign in", symbol: "menubar.rectangle")
                        }
                        Spacer()
                        Text(loginItemManager.statusText).font(.caption).foregroundStyle(.secondary)
                        if loginItemManager.requiresApproval {
                            Button("System Settings…", action: openLoginItemSettings)
                        }
                    }
                    if credentials != nil {
                        Divider()
                        HStack {
                            VStack(alignment: .leading, spacing: 3) {
                                Text(engine.registered ? "This Mac is connected" : "This Mac is not connected").font(.callout.weight(.medium))
                                Text(engine.state).font(.caption).foregroundStyle(.secondary)
                            }
                            Spacer()
                            if engine.registered {
                                Button("Disconnect") { engine.stop() }
                            } else {
                                Button(registrationInProgress ? "Connecting…" : "Register now", action: registerNow)
                                    .buttonStyle(.borderedProminent).disabled(registrationInProgress)
                            }
                        }
                        Divider()
                        Button("Forget authorization…", role: .destructive, action: forgetAuthorization)
                    }
                }

                if credentials == nil {
                    SettingsSection(title: "Authorize this Mac", symbol: "key.fill") {
                        Text("Authorize once with the SMS OTP sent by your JioFiber router. The app can then register automatically.")
                            .font(.callout).foregroundStyle(.secondary)
                        LabeledContent("Router") { TextField("jiofiber.local.html", text: $router).textFieldStyle(.roundedBorder).frame(width: 320) }
                        LabeledContent("Device name") { TextField("Device name", text: $alias).textFieldStyle(.roundedBorder).frame(width: 320) }
                        HStack {
                            Button("Request OTP", action: requestOTP).disabled(provisioner.otpPending)
                            TextField("SMS OTP", text: $otp).textFieldStyle(.roundedBorder).frame(width: 120)
                            Button("Verify & save", action: verifyOTP).buttonStyle(.borderedProminent)
                                .disabled(!provisioner.otpPending || otp.isEmpty)
                        }
                        Text(provisioner.activity).font(.caption).foregroundStyle(.secondary)
                    }
                }

                SettingsSection(title: "Calls & notifications", symbol: "bell.badge.fill") {
                    Toggle(isOn: $notificationsEnabled) {
                        SettingLabel(title: "Call notifications", subtitle: "Show incoming and missed-call alerts", symbol: "bell")
                    }
                    Divider()
                    HStack {
                        Text("macOS permission").font(.callout)
                        Spacer()
                        Text(notificationStatus).font(.callout).foregroundStyle(.secondary)
                        Button("System Settings…", action: openNotificationSettings)
                    }
                    Divider()
                    SettingLabel(title: "Local call history", subtitle: "Up to 500 calls are kept on this Mac", symbol: "clock")
                }

                SettingsSection(title: "Network", symbol: "network") {
                    LabeledContent("Jio router") { TextField("Router", text: $router).textFieldStyle(.roundedBorder).frame(width: 320) }
                    Divider()
                    LabeledContent("Device name") { TextField("Device name", text: $alias).textFieldStyle(.roundedBorder).frame(width: 320) }
                    Text("The router must be on your private local network. Changing the device name may require authorization again.")
                        .font(.caption).foregroundStyle(.secondary)
                }

                SettingsSection(title: "Diagnostics", symbol: "waveform.path.ecg") {
                    HStack {
                        VStack(alignment: .leading, spacing: 3) {
                            Text("Credential-safe activity log").font(.callout.weight(.medium))
                            Text("Phone numbers, SIP identities, passwords, OTPs, tokens, and authorization headers are removed.")
                                .font(.caption).foregroundStyle(.secondary)
                        }
                        Spacer()
                        Button("Export…", action: exportDiagnostics)
                    }
                    Divider()
                    if engine.diagnostics.isEmpty {
                        Text("No diagnostic activity in this session.").font(.callout).foregroundStyle(.secondary)
                    } else {
                        ForEach(engine.diagnostics.suffix(8).reversed()) { entry in
                            HStack(alignment: .firstTextBaseline) {
                                Text(entry.event).font(.system(.caption, design: .monospaced)).foregroundStyle(.secondary).frame(width: 120, alignment: .leading)
                                Text(entry.message).font(.caption).textSelection(.enabled)
                                Spacer()
                            }
                        }
                    }
                }

                Text("JioJoin for Mac 0.7.0 • Supervised JioFiberVoice calling • No phone tether")
                    .font(.caption).foregroundStyle(.tertiary).padding(.top, 4)
            }
            .frame(maxWidth: 760).padding(28)
        }
    }
}

private struct SettingsSection<Content: View>: View {
    let title: String
    let symbol: String
    @ViewBuilder let content: Content

    init(title: String, symbol: String, @ViewBuilder content: () -> Content) {
        self.title = title
        self.symbol = symbol
        self.content = content()
    }

    var body: some View {
        VStack(alignment: .leading, spacing: 14) {
            Label(title, systemImage: symbol).font(.headline)
            content
        }
        .modernCard()
    }
}

private struct EmptyStateView: View {
    let title: String
    let symbol: String
    let message: String

    var body: some View {
        VStack(spacing: 10) {
            Image(systemName: symbol).font(.system(size: 30)).foregroundStyle(.secondary)
            Text(title).font(.headline)
            Text(message).font(.callout).foregroundStyle(.secondary).multilineTextAlignment(.center)
        }
        .padding(28)
    }
}

private struct SettingLabel: View {
    let title: String
    let subtitle: String
    let symbol: String

    var body: some View {
        HStack(spacing: 12) {
            Image(systemName: symbol).foregroundStyle(.secondary).frame(width: 22)
            VStack(alignment: .leading, spacing: 2) {
                Text(title).font(.callout.weight(.medium))
                Text(subtitle).font(.caption).foregroundStyle(.secondary)
            }
        }
    }
}

private struct SettingStatusRow: View {
    let title: String
    let value: String
    let symbol: String
    let color: Color

    var body: some View {
        HStack(spacing: 12) {
            Image(systemName: symbol).foregroundStyle(color).frame(width: 22)
            Text(title).font(.callout.weight(.medium))
            Spacer()
            Text(value).font(.callout).foregroundStyle(.secondary)
        }
    }
}

private struct ModernCardModifier: ViewModifier {
    let accent: Color?
    let padding: CGFloat

    func body(content: Content) -> some View {
        content
            .padding(padding)
            .background(Color(nsColor: .controlBackgroundColor), in: RoundedRectangle(cornerRadius: 16, style: .continuous))
            .overlay {
                RoundedRectangle(cornerRadius: 16, style: .continuous)
                    .stroke(accent?.opacity(0.24) ?? Color.primary.opacity(0.07), lineWidth: 1)
            }
            .shadow(color: .black.opacity(0.035), radius: 10, y: 4)
    }
}

private extension View {
    func modernCard(accent: Color? = nil, padding: CGFloat = 20) -> some View {
        modifier(ModernCardModifier(accent: accent, padding: padding))
    }
}

private struct KeypadButtonStyle: ButtonStyle {
    func makeBody(configuration: Configuration) -> some View {
        configuration.label
            .background(Color.primary.opacity(configuration.isPressed ? 0.14 : 0.07), in: Circle())
            .scaleEffect(configuration.isPressed ? 0.96 : 1)
            .animation(.easeOut(duration: 0.12), value: configuration.isPressed)
    }
}

private func formatDuration(_ duration: TimeInterval) -> String {
    let total = Int(duration.rounded(.down))
    let minutes = total / 60
    let seconds = total % 60
    return minutes > 0 ? "\(minutes)m \(seconds)s" : "\(seconds)s"
}

private func formatCallClock(_ duration: TimeInterval) -> String {
    let total = max(0, Int(duration.rounded(.down)))
    return String(format: "%02d:%02d", total / 60, total % 60)
}

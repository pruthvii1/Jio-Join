import Foundation
import Network

struct EngineEvent: Decodable, Identifiable {
    var id = UUID()
    let event: String
    let message: String?
    let code: Int?
    let operation: String?
    let registered: Bool?
    let activeCallPresent: Bool?
    let protocolVersion: Int?
    let engineVersion: String?
    let platform: String?
    let architecture: String?
    let audioBackend: String?
    private enum CodingKeys: String, CodingKey {
        case event, message, code, operation, registered
        case activeCallPresent = "active_call"
        case protocolVersion = "protocol"
        case engineVersion = "engine_version"
        case platform, architecture
        case audioBackend = "audio_backend"
    }

    init(event: String, message: String?, code: Int?, operation: String? = nil,
         registered: Bool? = nil, activeCallPresent: Bool? = nil) {
        self.event = event
        self.message = message
        self.code = code
        self.operation = operation
        self.registered = registered
        self.activeCallPresent = activeCallPresent
        self.protocolVersion = nil
        self.engineVersion = nil
        self.platform = nil
        self.architecture = nil
        self.audioBackend = nil
    }
}

enum RegistrationPhase: Equatable {
    case offline
    case connecting
    case registered
    case failed(code: Int?)
}

enum CallPhase: Equatable {
    case idle
    case incoming
    case dialing
    case ringing
    case connecting
    case connected
    case held
    case ending
    case failed(code: Int?)
}

@MainActor
final class EngineManager: ObservableObject {
    @Published private(set) var state = "Offline"
    @Published private(set) var registered = false
    @Published private(set) var registrationPhase: RegistrationPhase = .offline
    @Published private(set) var incomingCaller: String?
    @Published private(set) var inCall = false
    @Published private(set) var callPhase: CallPhase = .idle
    @Published private(set) var isOnHold = false
    @Published private(set) var events: [EngineEvent] = []
    @Published private(set) var diagnostics: [DiagnosticEntry] = []
    @Published private(set) var activeCall: ActiveCall?
    @Published private(set) var callHistory: [CallRecord] = CallHistoryStorage.load()
    @Published private(set) var hasUnreadMissedCall = MissedCallBadgeStorage.load()

    private var process: Process?
    private var input: FileHandle?
    private var outputBuffer = Data()
    private var rejectionRequested = false
    private var intentionalStop = false
    private var recoveryEnabled = false
    private var recoverySuspended = false
    private var recoveryAttempt = 0
    private var recoveryHandler: (@MainActor () async throws -> Void)?
    private var recoveryTask: Task<Void, Never>?
    private var registrationTimeoutTask: Task<Void, Never>?
    private var heartbeatTask: Task<Void, Never>?
    private var callTimeoutTask: Task<Void, Never>?
    private var awaitingPongSince: Date?
    private var heartbeatCount = 0
    private var pathMonitor: NWPathMonitor?
    private var networkAvailable = true
    private var lastNetworkSignature: String?
    private var negotiatedProtocol: Int?
    private var pendingRegistration: SIPCredentials?

    private enum CallWatchdog: String {
        case incoming, outgoing, answering, ending, forcedEnding
    }

    func configureReliability(enabled: Bool,
                              recovery: @escaping @MainActor () async throws -> Void) {
        let wasEnabled = recoveryEnabled
        recoveryEnabled = enabled
        recoveryHandler = recovery
        if enabled, !wasEnabled { recoverySuspended = false }
        if enabled != wasEnabled {
            record(category: "supervisor", event: enabled ? "enabled" : "disabled",
                   message: enabled ? "Automatic recovery enabled" : "Automatic recovery disabled")
        }
        if enabled { startNetworkMonitoring() }
        else {
            recoveryTask?.cancel()
            recoveryTask = nil
            pathMonitor?.cancel()
            pathMonitor = nil
        }
    }

    func setAutomaticRecoveryEnabled(_ enabled: Bool) {
        recoveryEnabled = enabled
        if enabled {
            recoverySuspended = false
            startNetworkMonitoring()
            if !registered, registrationPhase != .connecting { requestRecovery(reason: "automatic registration enabled", immediate: true) }
        } else {
            recoveryTask?.cancel()
            recoveryTask = nil
            pathMonitor?.cancel()
            pathMonitor = nil
        }
        record(category: "supervisor", event: enabled ? "enabled" : "disabled",
               message: enabled ? "Automatic recovery enabled" : "Automatic recovery disabled")
    }

    func register(_ credentials: SIPCredentials) throws {
        recoverySuspended = false
        pendingRegistration = credentials
        if process == nil { try launch() }
        if negotiatedProtocol == 1 { sendPendingRegistration() }
        registrationPhase = .connecting
        state = negotiatedProtocol == 1 ? "Connecting…" : "Starting calling engine…"
        record(category: "registration", event: "queued", message: "Registration queued after protocol validation")
        scheduleRegistrationTimeout()
    }

    func dial(_ rawNumber: String) {
        guard let number = DialPlan.normalize(rawNumber) else {
            add(EngineEvent(event: "error", message: "Enter a valid telephone number.", code: 400)); return
        }
        guard registered, !inCall else {
            add(EngineEvent(event: "error", message: "Connect before starting a new call.", code: 409)); return
        }
        beginCall(remoteParty: number, direction: .outgoing)
        inCall = true
        callPhase = .dialing
        state = "Calling \(number)"
        send("DIAL\t\(base64(number))")
        record(category: "call", event: "dial", message: "Outgoing call requested")
        scheduleCallTimeout(.outgoing, after: ReliabilityPolicy.outgoingCallTimeout)
    }

    func answer() {
        send("ANSWER")
        incomingCaller = nil
        NotificationManager.shared.clearIncomingCall()
        callPhase = .connecting
        state = "Connecting call…"
        record(category: "call", event: "answer", message: "Incoming call answer requested")
        scheduleCallTimeout(.answering, after: ReliabilityPolicy.answeredCallTimeout)
    }

    func reject() {
        rejectionRequested = true
        send("REJECT")
        incomingCaller = nil
        NotificationManager.shared.clearIncomingCall()
        callPhase = .ending
        state = "Declining call…"
        record(category: "call", event: "reject", message: "Incoming call decline requested")
        scheduleCallTimeout(.ending, after: ReliabilityPolicy.hangupTimeout)
    }

    func hangup() {
        send("HANGUP")
        NotificationManager.shared.clearIncomingCall()
        if inCall {
            callPhase = .ending
            state = "Ending call…"
            record(category: "call", event: "hangup", message: "Call end requested")
            scheduleCallTimeout(.ending, after: ReliabilityPolicy.hangupTimeout)
        }
    }

    func hold() {
        guard inCall, activeCall?.connectedAt != nil, !isOnHold else { return }
        send("HOLD")
        isOnHold = true
        callPhase = .held
        state = "Call on hold"
    }

    func resume() {
        guard inCall, activeCall?.connectedAt != nil, isOnHold else { return }
        send("RESUME")
        isOnHold = false
        callPhase = .connecting
        state = "Resuming call…"
    }

    func stop() {
        intentionalStop = true
        recoverySuspended = true
        recoveryTask?.cancel()
        recoveryTask = nil
        registrationTimeoutTask?.cancel()
        callTimeoutTask?.cancel()
        pendingRegistration = nil
        negotiatedProtocol = nil
        send("QUIT")
        process?.terminate()
        process = nil
        input = nil
        registered = false
        registrationPhase = .offline
        let stoppedOutcome: CallOutcome? = activeCall?.connectedAt != nil
            ? .completed : (activeCall?.direction == .incoming ? .missed : .failed)
        finishActiveCall(forceOutcome: stoppedOutcome)
        incomingCaller = nil
        inCall = false
        isOnHold = false
        callPhase = .idle
        state = "Offline"
        record(category: "engine", event: "stop", message: "Disconnected by user")
    }

    func clearHistory() {
        callHistory.removeAll()
        CallHistoryStorage.save(callHistory)
        markMissedCallsRead()
    }

    func markMissedCallsRead() {
        guard hasUnreadMissedCall else { return }
        hasUnreadMissedCall = false
        MissedCallBadgeStorage.save(false)
    }

    private func launch() throws {
        let executable = try engineURL()
        let process = Process()
        let stdinPipe = Pipe(), stdoutPipe = Pipe()
        intentionalStop = false
        negotiatedProtocol = nil
        process.executableURL = executable
        process.standardInput = stdinPipe
        process.standardOutput = stdoutPipe
        process.standardError = FileHandle.nullDevice
        try process.run()
        self.process = process
        input = stdinPipe.fileHandleForWriting
        awaitingPongSince = nil
        beginHeartbeatLoop()
        record(category: "engine", event: "launch", message: "Native calling engine launched")
        stdoutPipe.fileHandleForReading.readabilityHandler = { [weak self] handle in
            let data = handle.availableData
            guard !data.isEmpty else { return }
            Task { @MainActor in self?.consume(data) }
        }
        process.terminationHandler = { [weak self] process in
            Task { @MainActor in
                self?.process = nil
                self?.input = nil
                self?.heartbeatTask?.cancel()
                self?.heartbeatTask = nil
                self?.awaitingPongSince = nil
                self?.registrationTimeoutTask?.cancel()
                self?.pendingRegistration = nil
                self?.negotiatedProtocol = nil
                self?.registered = false
                self?.registrationPhase = .offline
                let outcome: CallOutcome? = self?.activeCall?.connectedAt != nil
                    ? .completed : (self?.activeCall?.direction == .incoming ? .missed : .failed)
                self?.finishActiveCall(forceOutcome: outcome)
                self?.incomingCaller = nil
                self?.inCall = false
                self?.isOnHold = false
                self?.callPhase = .idle
                self?.state = self?.intentionalStop == true ? "Offline" : "Engine stopped (\(process.terminationStatus))"
                if self?.intentionalStop != true {
                    self?.record(category: "engine", event: "terminated",
                                 message: "Native engine stopped unexpectedly", code: Int(process.terminationStatus))
                    self?.requestRecovery(reason: "engine stopped unexpectedly")
                }
                self?.intentionalStop = false
            }
        }
    }

    private func engineURL() throws -> URL {
        if let override = ProcessInfo.processInfo.environment["JIOJOIN_ENGINE_PATH"] {
            return URL(fileURLWithPath: override)
        }
        let bundled = Bundle.main.bundleURL.appendingPathComponent("Contents/MacOS/jiojoin-engine")
        if FileManager.default.isExecutableFile(atPath: bundled.path) { return bundled }
        throw NSError(domain: "JioJoinMac", code: 1,
                      userInfo: [NSLocalizedDescriptionKey: "The native calling engine is missing from the app bundle."])
    }

    private func send(_ line: String) {
        guard let data = (line + "\n").data(using: .utf8) else { return }
        guard let input else {
            record(category: "engine", event: "write-failed", message: "Native engine is unavailable")
            return
        }
        do { try input.write(contentsOf: data) }
        catch { add(EngineEvent(event: "error", message: error.localizedDescription, code: nil)) }
    }

    private func base64(_ value: String) -> String { Data(value.utf8).base64EncodedString() }

    private func consume(_ data: Data) {
        outputBuffer.append(data)
        while let newline = outputBuffer.firstIndex(of: 0x0a) {
            let line = outputBuffer.prefix(upTo: newline)
            outputBuffer.removeSubrange(...newline)
            guard let event = try? JSONDecoder().decode(EngineEvent.self, from: line) else { continue }
            add(event)
        }
    }

    private func add(_ event: EngineEvent) {
        events.append(event)
        if events.count > 100 { events.removeFirst(events.count - 100) }
        if event.event != "pong" {
            record(category: event.event == "error" ? "error" : "engine",
                   event: event.event, message: event.message ?? event.event, code: event.code)
        }
        switch event.event {
        case "hello":
            handleHello(event)
        case "pong":
            awaitingPongSince = nil
        case "status":
            reconcileStatus(event)
        case "registered":
            registered = true
            registrationPhase = .registered
            state = "Ready for calls"
            registrationTimeoutTask?.cancel()
            recoveryTask?.cancel()
            recoveryTask = nil
            recoveryAttempt = 0
        case "registration", "engine":
            if event.event == "registration", let code = event.code {
                if code >= 200 && code < 300 {
                    registered = true
                    registrationPhase = .registered
                    registrationTimeoutTask?.cancel()
                    recoveryTask?.cancel()
                    recoveryTask = nil
                    recoveryAttempt = 0
                } else if code >= 300 {
                    registered = false
                    registrationPhase = .failed(code: code)
                    registrationTimeoutTask?.cancel()
                    requestRecovery(reason: "registration failed with status \(code)")
                } else if !registered {
                    registrationPhase = .connecting
                }
            } else if event.message?.localizedCaseInsensitiveContains("registration") == true {
                registrationPhase = .connecting
            }
            if !(event.event == "engine" && registrationPhase == .connecting) {
                state = event.message ?? event.event
            }
        case "incoming":
            let caller = CallerDisplay.clean(event.message ?? "Unknown caller")
            beginCall(remoteParty: caller, direction: .incoming)
            incomingCaller = caller
            inCall = true
            callPhase = .incoming
            state = "Incoming call"
            NotificationManager.shared.showIncomingCall(from: caller)
            scheduleCallTimeout(.incoming, after: ReliabilityPolicy.incomingCallTimeout)
        case "dialing":
            let number = CallerDisplay.clean(event.message ?? "Unknown number")
            if activeCall == nil { beginCall(remoteParty: number, direction: .outgoing) }
            inCall = true
            callPhase = .dialing
            state = "Calling \(number)"
            scheduleCallTimeout(.outgoing, after: ReliabilityPolicy.outgoingCallTimeout)
        case "call-state":
            handleCallState(event.message ?? "Call", statusCode: event.code)
        case "held":
            isOnHold = true
            callPhase = .held
            state = "Call on hold"
        case "resumed", "media":
            if event.event == "resumed" { isOnHold = false }
            if activeCall?.connectedAt != nil, !isOnHold {
                callPhase = .connected
                state = "Call connected"
            }
        case "remote-held":
            callPhase = .held
            state = event.message ?? "The other party placed the call on hold"
        case "error":
            if event.operation == "dial" {
                finishActiveCall(forceOutcome: .failed)
                incomingCaller = nil
                inCall = false
                isOnHold = false
                callPhase = .failed(code: event.code)
            }
            if ["initialize", "tls-transport", "start", "account"].contains(event.operation ?? "") {
                registered = false
                registrationPhase = .failed(code: event.code)
                registrationTimeoutTask?.cancel()
                requestRecovery(reason: "native registration setup failed")
            }
            state = event.message ?? "Engine error"
        default: break
        }
    }

    private func beginCall(remoteParty: String, direction: CallDirection) {
        if activeCall != nil { finishActiveCall(forceOutcome: direction == .incoming ? .missed : .failed) }
        activeCall = ActiveCall(id: UUID(), remoteParty: remoteParty, direction: direction,
                                startedAt: Date(), connectedAt: nil)
        rejectionRequested = false
        isOnHold = false
    }

    private func handleCallState(_ rawState: String, statusCode: Int?) {
        let normalized = rawState.uppercased()
        if normalized.contains("CONFIRMED") {
            callTimeoutTask?.cancel()
            if activeCall?.connectedAt == nil { activeCall?.connectedAt = Date() }
            incomingCaller = nil
            inCall = true
            callPhase = .connected
            state = "Call connected"
            NotificationManager.shared.clearIncomingCall()
        } else if normalized.contains("DISCON") {
            callTimeoutTask?.cancel()
            let outcome: CallOutcome
            if let call = activeCall {
                if call.connectedAt != nil { outcome = .completed }
                else if call.direction == .incoming { outcome = rejectionRequested ? .declined : .missed }
                else { outcome = .failed }
            } else { outcome = .failed }
            finishActiveCall(forceOutcome: outcome)
            incomingCaller = nil
            inCall = false
            isOnHold = false
            callPhase = .idle
            state = registered ? "Ready for calls" : "Offline"
            if !registered {
                requestRecovery(reason: "call ended while registration was unavailable", immediate: true)
            }
        } else {
            inCall = true
            if normalized.contains("EARLY") { callPhase = .ringing }
            else if normalized.contains("CALLING") { callPhase = .dialing }
            else if normalized.contains("INCOMING") { callPhase = .incoming }
            else { callPhase = .connecting }
            state = friendlyCallState(normalized, statusCode: statusCode)
        }
    }

    private func friendlyCallState(_ state: String, statusCode: Int?) -> String {
        if state.contains("EARLY") { return "Ringing…" }
        if state.contains("CALLING") { return "Calling…" }
        if state.contains("INCOMING") { return "Incoming call" }
        if let statusCode, statusCode >= 400 { return "Call status \(statusCode)" }
        return state.capitalized
    }

    private func finishActiveCall(forceOutcome outcome: CallOutcome?) {
        guard let call = activeCall, let outcome else { return }
        let record = CallRecord(id: call.id, remoteParty: call.remoteParty, direction: call.direction,
                                startedAt: call.startedAt, connectedAt: call.connectedAt,
                                endedAt: Date(), outcome: outcome)
        callHistory.insert(record, at: 0)
        if callHistory.count > 500 { callHistory.removeLast(callHistory.count - 500) }
        CallHistoryStorage.save(callHistory)
        if outcome == .missed {
            hasUnreadMissedCall = true
            MissedCallBadgeStorage.save(true)
            NotificationManager.shared.showMissedCall(from: call.remoteParty)
        }
        NotificationManager.shared.clearIncomingCall()
        activeCall = nil
        rejectionRequested = false
        isOnHold = false
    }

    private func handleHello(_ event: EngineEvent) {
        guard event.protocolVersion == 1 else {
            pendingRegistration = nil
            negotiatedProtocol = nil
            recoverySuspended = true
            registrationTimeoutTask?.cancel()
            registrationPhase = .failed(code: event.protocolVersion)
            state = "Incompatible calling engine"
            record(category: "engine", event: "protocol-rejected",
                   message: "Expected engine protocol 1")
            return
        }
        negotiatedProtocol = 1
        record(category: "engine", event: "protocol-ready",
               message: "Engine \(event.engineVersion ?? "unknown") on \(event.platform ?? "unknown") \(event.architecture ?? "unknown")")
        sendPendingRegistration()
    }

    private func sendPendingRegistration() {
        guard negotiatedProtocol == 1, let credentials = pendingRegistration else { return }
        pendingRegistration = nil
        let fields = [credentials.publicID, credentials.authUser, credentials.password,
                      credentials.realm, credentials.registrar, credentials.instanceID,
                      LocalNetwork.localAddress(), credentials.pani]
        send("START\t" + fields.map(base64).joined(separator: "\t"))
        registrationPhase = .connecting
        state = "Connecting…"
        record(category: "registration", event: "start", message: "Registration requested")
    }

    private func beginHeartbeatLoop() {
        heartbeatTask?.cancel()
        heartbeatTask = Task { [weak self] in
            while !Task.isCancelled {
                try? await Task.sleep(nanoseconds: UInt64(ReliabilityPolicy.heartbeatInterval * 1_000_000_000))
                guard !Task.isCancelled else { return }
                self?.heartbeatTick()
            }
        }
    }

    private func heartbeatTick() {
        guard process != nil else { return }
        if let awaitingPongSince,
           Date().timeIntervalSince(awaitingPongSince) >= ReliabilityPolicy.heartbeatTimeout {
            if activeCall != nil {
                state = "Call active; engine health check delayed"
                record(category: "supervisor", event: "heartbeat-delayed",
                       message: "Engine health response is late; active call was not restarted")
                self.awaitingPongSince = Date()
                return
            }
            record(category: "supervisor", event: "heartbeat-timeout",
                   message: "Native engine did not answer its health check")
            state = "Restarting calling engine…"
            process?.terminate()
            return
        }
        awaitingPongSince = Date()
        send("PING")
        heartbeatCount += 1
        if heartbeatCount.isMultiple(of: 3) { send("STATUS") }
    }

    private func scheduleRegistrationTimeout() {
        registrationTimeoutTask?.cancel()
        registrationTimeoutTask = Task { [weak self] in
            try? await Task.sleep(nanoseconds: UInt64(ReliabilityPolicy.registrationTimeout * 1_000_000_000))
            guard !Task.isCancelled, let self, !self.registered,
                  self.registrationPhase == .connecting else { return }
            self.registrationPhase = .failed(code: nil)
            self.state = "Registration timed out"
            self.record(category: "registration", event: "timeout",
                        message: "Registration did not complete in time")
            self.requestRecovery(reason: "registration timed out")
        }
    }

    private func requestRecovery(reason: String, immediate: Bool = false) {
        guard recoveryEnabled, !recoverySuspended, networkAvailable,
              activeCall == nil, !registered, recoveryTask == nil,
              let recoveryHandler else { return }
        if registrationPhase == .connecting, !reason.contains("timed out") { return }

        let attempt = recoveryAttempt
        recoveryAttempt += 1
        let delay = immediate ? 0 : ReliabilityPolicy.retryDelay(
            attempt: attempt, jitter: Double.random(in: -0.2...0.2)
        )
        record(category: "supervisor", event: "recovery-scheduled",
               message: "Registration recovery scheduled after \(reason); attempt \(attempt + 1) in \(Int(delay.rounded())) seconds")
        state = delay == 0 ? "Recovering registration…" : "Retrying in \(Int(delay.rounded()))s…"

        recoveryTask = Task { [weak self] in
            if delay > 0 {
                try? await Task.sleep(nanoseconds: UInt64(delay * 1_000_000_000))
            }
            guard !Task.isCancelled, let self, self.recoveryEnabled,
                  !self.recoverySuspended, self.networkAvailable,
                  self.activeCall == nil, !self.registered else { return }
            do {
                self.record(category: "supervisor", event: "recovery-attempt",
                            message: "Refreshing authorized configuration")
                try await recoveryHandler()
                self.recoveryTask = nil
                if case .failed = self.registrationPhase {
                    self.requestRecovery(reason: "registration attempt failed")
                }
            } catch {
                self.recoveryTask = nil
                self.registrationPhase = .failed(code: nil)
                self.record(category: "supervisor", event: "recovery-failed",
                            message: error.localizedDescription)
                self.requestRecovery(reason: "credential refresh failed")
            }
        }
    }

    private func startNetworkMonitoring() {
        guard pathMonitor == nil else { return }
        let monitor = NWPathMonitor()
        pathMonitor = monitor
        monitor.pathUpdateHandler = { [weak self] path in
            let available = path.status == .satisfied
            let signature = "\(path.status)-\(path.availableInterfaces.map(\.name).sorted().joined(separator: ","))-\(path.supportsIPv4)-\(path.supportsIPv6)"
            Task { @MainActor in self?.networkPathChanged(available: available, signature: signature) }
        }
        monitor.start(queue: DispatchQueue(label: "com.codetorso.JioJoinMac.network-monitor"))
    }

    private func networkPathChanged(available: Bool, signature: String) {
        let previousAvailability = networkAvailable
        let pathChanged = lastNetworkSignature != nil && lastNetworkSignature != signature
        networkAvailable = available
        lastNetworkSignature = signature
        if !available {
            recoveryTask?.cancel()
            recoveryTask = nil
            if activeCall == nil { state = "Waiting for network…" }
            record(category: "network", event: "unavailable", message: "Network path is unavailable")
        } else if !previousAvailability || pathChanged {
            record(category: "network", event: "changed", message: "Network path is available")
            if activeCall == nil, !registered, registrationPhase != .connecting {
                requestRecovery(reason: "network path changed", immediate: true)
            }
        }
    }

    private func reconcileStatus(_ event: EngineEvent) {
        if event.registered == true, !registered {
            registered = true
            registrationPhase = .registered
            registrationTimeoutTask?.cancel()
            recoveryTask?.cancel()
            recoveryTask = nil
            recoveryAttempt = 0
            if activeCall == nil { state = "Ready for calls" }
        } else if event.registered == false, registered {
            registered = false
            registrationPhase = .failed(code: event.code)
            if activeCall == nil {
                state = "Registration was lost"
                requestRecovery(reason: "engine status reported registration loss")
            }
        }

        if event.activeCallPresent == false, let call = activeCall, inCall {
            let outcome: CallOutcome
            if call.connectedAt != nil { outcome = .completed }
            else if call.direction == .incoming { outcome = rejectionRequested ? .declined : .missed }
            else { outcome = .failed }
            callTimeoutTask?.cancel()
            finishActiveCall(forceOutcome: outcome)
            incomingCaller = nil
            inCall = false
            callPhase = .idle
            state = registered ? "Ready for calls" : "Offline"
            record(category: "supervisor", event: "call-reconciled",
                   message: "Recovered from a missed native call-state event")
        } else if event.activeCallPresent == true, activeCall == nil {
            record(category: "supervisor", event: "state-mismatch",
                   message: "Native engine reports an unmanaged active call")
        }
    }

    private func scheduleCallTimeout(_ watchdog: CallWatchdog, after seconds: TimeInterval) {
        callTimeoutTask?.cancel()
        callTimeoutTask = Task { [weak self] in
            try? await Task.sleep(nanoseconds: UInt64(seconds * 1_000_000_000))
            guard !Task.isCancelled else { return }
            self?.callTimeoutExpired(watchdog)
        }
    }

    private func callTimeoutExpired(_ watchdog: CallWatchdog) {
        guard activeCall != nil else { return }
        switch watchdog {
        case .incoming:
            rejectionRequested = false
            send("REJECT")
            state = "Incoming call timed out"
            record(category: "call", event: "timeout", message: "Incoming call was not answered")
            scheduleCallTimeout(.forcedEnding, after: ReliabilityPolicy.forcedHangupGrace)
        case .outgoing, .answering:
            send("HANGUP")
            callPhase = .ending
            state = watchdog == .outgoing ? "Call attempt timed out" : "Answer attempt timed out"
            record(category: "call", event: "timeout", message: state)
            scheduleCallTimeout(.forcedEnding, after: ReliabilityPolicy.forcedHangupGrace)
        case .ending:
            send("HANGUP")
            state = "Waiting for call to end…"
            record(category: "call", event: "hangup-retry", message: "Native call end confirmation is late")
            scheduleCallTimeout(.forcedEnding, after: ReliabilityPolicy.forcedHangupGrace)
        case .forcedEnding:
            record(category: "call", event: "forced-recovery",
                   message: "Restarting an unresponsive engine after call termination failed")
            state = "Recovering after call…"
            process?.terminate()
        }
    }

    private func record(category: String, event: String, message: String, code: Int? = nil) {
        diagnostics.append(DiagnosticEntry(category: category, event: event, message: message, code: code))
        if diagnostics.count > 500 { diagnostics.removeFirst(diagnostics.count - 500) }
    }

    func diagnosticReport() -> String {
        let formatter = ISO8601DateFormatter()
        #if arch(arm64)
        let architecture = "arm64"
        #else
        let architecture = "unknown"
        #endif
        var lines = [
            "JioJoin for Mac diagnostics",
            "Generated: \(formatter.string(from: Date()))",
            "App version: 0.7.0 (12)",
            "macOS: \(ProcessInfo.processInfo.operatingSystemVersionString)",
            "Architecture: \(architecture)",
            "Registration: \(registered ? "registered" : "not registered")",
            "Call phase: \(String(describing: callPhase))",
            "Privacy: credentials, authorization headers, SIP identities, and telephone numbers are redacted.",
            "",
            "Recent events:"
        ]
        for entry in diagnostics {
            let code = entry.code.map { " code=\($0)" } ?? ""
            lines.append("\(formatter.string(from: entry.timestamp)) [\(entry.category)] \(entry.event)\(code): \(entry.message)")
        }
        return lines.joined(separator: "\n") + "\n"
    }

    func exportDiagnostics(to url: URL) throws {
        try Data(diagnosticReport().utf8).write(to: url, options: .atomic)
    }
}

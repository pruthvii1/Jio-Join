import XCTest
@testable import JioJoinMac

final class ProtocolTests: XCTestCase {
    func testJFCDeviceHashIsStable() {
        XCTAssertEqual(DeviceIdentity.mac(for: "AnkurSIPProxy"), "00:00:0f:10:ea:f2")
        XCTAssertEqual(DeviceIdentity.instanceID(mac: "00:00:0f:10:ea:f2"),
                       "<00000000-0000-1000-8000-00000F10EAF2>")
    }

    func testDialNormalization() {
        XCTAssertEqual(DialPlan.normalize("98765 43210"), "09876543210")
        XCTAssertEqual(DialPlan.normalize("+91 98765-43210"), "09876543210")
        XCTAssertEqual(DialPlan.normalize("1800123456"), "1800123456")
        XCTAssertNil(DialPlan.normalize("hello"))
    }

    func testPrivateRouterValidation() {
        XCTAssertTrue(LocalNetwork.isPrivateIPv4("192.168.31.1"))
        XCTAssertTrue(LocalNetwork.isPrivateIPv4("jiofiber.local.html"))
        XCTAssertFalse(LocalNetwork.isPrivateIPv4("8.8.8.8"))
    }

    func testTLSServiceNameIsTheDefault() {
        XCTAssertEqual(LocalNetwork.defaultGateway(), "jiofiber.local.html")
    }

    func testSIPCallerDisplayIsCleanedForHistoryAndNotifications() {
        XCTAssertEqual(CallerDisplay.clean("\"Ankur\" <sip:+919876543210@ims.example>"), "+919876543210")
        XCTAssertEqual(CallerDisplay.clean("sip:1800123456@ims.example;user=phone"), "1800123456")
    }

    func testCallHistoryRoundTripAndDuration() throws {
        let suiteName = "JioJoinMacTests-\(UUID().uuidString)"
        let defaults = try XCTUnwrap(UserDefaults(suiteName: suiteName))
        defer { defaults.removePersistentDomain(forName: suiteName) }
        let connected = Date(timeIntervalSince1970: 1_000)
        let record = CallRecord(
            id: UUID(), remoteParty: "09876543210", direction: .outgoing,
            startedAt: connected.addingTimeInterval(-5), connectedAt: connected,
            endedAt: connected.addingTimeInterval(65), outcome: .completed
        )
        CallHistoryStorage.save([record], defaults: defaults)
        XCTAssertEqual(CallHistoryStorage.load(defaults: defaults), [record])
        XCTAssertEqual(record.duration, 65)
    }

    func testIncomingCallNotificationActionsHaveStableIdentifiers() {
        XCTAssertEqual(NotificationManager.incomingCategoryIdentifier, "JIOJOIN_INCOMING_CALL")
        XCTAssertEqual(NotificationManager.answerActionIdentifier, "JIOJOIN_ANSWER")
        XCTAssertEqual(NotificationManager.declineActionIdentifier, "JIOJOIN_DECLINE")
    }

    func testMissedCallBadgePersistence() throws {
        let suiteName = "JioJoinMacBadgeTests-\(UUID().uuidString)"
        let defaults = try XCTUnwrap(UserDefaults(suiteName: suiteName))
        defer { defaults.removePersistentDomain(forName: suiteName) }

        XCTAssertFalse(MissedCallBadgeStorage.load(defaults: defaults))
        MissedCallBadgeStorage.save(true, defaults: defaults)
        XCTAssertTrue(MissedCallBadgeStorage.load(defaults: defaults))
        MissedCallBadgeStorage.save(false, defaults: defaults)
        XCTAssertFalse(MissedCallBadgeStorage.load(defaults: defaults))
    }

    func testProvisioningParserPreservesHierarchyAndRepeatedValues() throws {
        let xml = Data("""
        <?xml version="1.0" encoding="UTF-8"?>
        <wap-provisioningdoc>
          <characteristic type="APPLICATION">
            <parm name="address" value="unrelated.example:5060"/>
            <characteristic type="LBO_P-CSCF_Address">
              <parm name="Address" value="jiofiber.local.html:5068"/>
              <parm name="Address" value="192.168.29.1:5068"/>
            </characteristic>
          </characteristic>
        </wap-provisioningdoc>
        """.utf8)

        let document = try SIPProvisioningDocument(data: xml)

        XCTAssertEqual(document.values.filter { $0.name.caseInsensitiveCompare("address") == .orderedSame }.count, 3)
        XCTAssertEqual(document.preferredProxyAddress(), "jiofiber.local.html:5068")
        XCTAssertEqual(document.values[1].path, ["APPLICATION", "LBO_P-CSCF_Address"])
    }

    func testProvisioningProxyFallbackPrefersTLSPortThenFirstAddress() throws {
        let portFallback = try SIPProvisioningDocument(data: Data("""
        <root><parm name="address" value="first.example:5060"/>
        <parm name="address" value="tls.example:5068"/></root>
        """.utf8))
        XCTAssertEqual(portFallback.preferredProxyAddress(), "tls.example:5068")

        let firstFallback = try SIPProvisioningDocument(data: Data("""
        <root><parm name="address" value="first.example:5060"/>
        <parm name="address" value="second.example:5060"/></root>
        """.utf8))
        XCTAssertEqual(firstFallback.preferredProxyAddress(), "first.example:5060")
    }

    func testProvisioningParserRejectsMalformedXML() {
        XCTAssertThrowsError(try SIPProvisioningDocument(data: Data("<root>".utf8)))
    }

    func testEngineErrorPreservesFailedOperation() throws {
        let event = try JSONDecoder().decode(
            EngineEvent.self,
            from: Data(#"{"event":"error","operation":"dial","message":"Invalid URI","code":171039}"#.utf8)
        )
        XCTAssertEqual(event.event, "error")
        XCTAssertEqual(event.operation, "dial")
        XCTAssertEqual(event.code, 171_039)
    }

    func testEngineStatusCarriesAuthoritativeState() throws {
        let event = try JSONDecoder().decode(
            EngineEvent.self,
            from: Data(#"{"event":"status","message":"engine status","code":200,"registered":true,"active_call":false}"#.utf8)
        )
        XCTAssertTrue(event.registered == true)
        XCTAssertTrue(event.activeCallPresent == false)
    }

    func testEngineHelloCarriesPortableProtocolMetadata() throws {
        let event = try JSONDecoder().decode(
            EngineEvent.self,
            from: Data(#"{"event":"hello","message":"JioJoin headless engine","code":0,"protocol":1,"engine_version":"0.8.0","platform":"linux","architecture":"x86_64","audio_backend":"ALSA/PipeWire"}"#.utf8)
        )
        XCTAssertEqual(event.protocolVersion, 1)
        XCTAssertEqual(event.engineVersion, "0.8.0")
        XCTAssertEqual(event.platform, "linux")
        XCTAssertEqual(event.architecture, "x86_64")
        XCTAssertEqual(event.audioBackend, "ALSA/PipeWire")
    }

    func testRecoveryBackoffIsBoundedAndJittered() {
        XCTAssertEqual(ReliabilityPolicy.retryDelay(attempt: 0, jitter: 0), 2)
        XCTAssertEqual(ReliabilityPolicy.retryDelay(attempt: 2, jitter: 0), 15)
        XCTAssertEqual(ReliabilityPolicy.retryDelay(attempt: 50, jitter: 0), 300)
        XCTAssertEqual(ReliabilityPolicy.retryDelay(attempt: 1, jitter: 0.2), 6)
        XCTAssertEqual(ReliabilityPolicy.retryDelay(attempt: 1, jitter: -0.2), 4)
        XCTAssertLessThanOrEqual(ReliabilityPolicy.retryDelay(attempt: 50, jitter: 0.2), 300)
    }

    func testDiagnosticsRedactCredentialsAndTelephoneIdentities() {
        let raw = "Authorization: Digest secret-value password=hunter2 OTP=123456 token=abcdef sip:+919876543210@ims.example call 09876543210"
        let safe = DiagnosticSanitizer.sanitize(raw)
        XCTAssertFalse(safe.contains("secret-value"))
        XCTAssertFalse(safe.contains("hunter2"))
        XCTAssertFalse(safe.contains("123456"))
        XCTAssertFalse(safe.contains("abcdef"))
        XCTAssertFalse(safe.contains("9876543210"))
        XCTAssertTrue(safe.contains("REDACTED"))
    }

}

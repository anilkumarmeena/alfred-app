import XCTest
@testable import JarvisAudioCore

final class ServerAddressTests: XCTestCase {
    func testAssumesHttpsAndKeepsOnlyTheOrigin() throws {
        XCTAssertEqual(try ServerAddress("mac.tailnet.ts.net").string, "https://mac.tailnet.ts.net")
        XCTAssertEqual(try ServerAddress("  https://Mac.Tailnet.ts.net/some/path?q=1#x \n").string, "https://mac.tailnet.ts.net")
        XCTAssertEqual(try ServerAddress("http://localhost:8787/").string, "http://localhost:8787")
        XCTAssertEqual(try ServerAddress("https://mac.ts.net:443").string, "https://mac.ts.net")
        XCTAssertEqual(try ServerAddress("mac.ts.net:8443").string, "https://mac.ts.net:8443")
    }

    func testTokenURL() throws {
        XCTAssertEqual(try ServerAddress("mac.ts.net").tokenURL.absoluteString, "https://mac.ts.net/api/token")
        XCTAssertEqual(try ServerAddress("http://10.0.2.2:8787").tokenURL.absoluteString, "http://10.0.2.2:8787/api/token")
    }

    func testRefusesWhatIsntAWebAddress() {
        XCTAssertThrowsError(try ServerAddress("   ")) { XCTAssertEqual($0 as? ServerAddress.Problem, .empty) }
        XCTAssertThrowsError(try ServerAddress("ftp://mac.ts.net")) {
            XCTAssertEqual($0 as? ServerAddress.Problem, .unsupportedScheme("ftp"))
        }
        XCTAssertThrowsError(try ServerAddress("https://")) { XCTAssertEqual($0 as? ServerAddress.Problem, .noHost) }
    }

    func testCleartext() throws {
        XCTAssertTrue(try ServerAddress("http://localhost:8787").isCleartext)
        XCTAssertFalse(try ServerAddress("mac.ts.net").isCleartext)
    }

    func testPushURL() throws {
        XCTAssertEqual(try ServerAddress("mac.ts.net").pushURL.absoluteString, "https://mac.ts.net/api/push/native")
    }

    func testNotificationPagesStayOnTheServer() throws {
        let s = try ServerAddress("mac.ts.net")
        XCTAssertEqual(s.page("/?task=3")?.absoluteString, "https://mac.ts.net/?task=3")
        XCTAssertEqual(s.page("/?alert=calendar")?.absoluteString, "https://mac.ts.net/?alert=calendar")
        XCTAssertEqual(s.page("https://MAC.ts.net/?task=4")?.absoluteString, "https://MAC.ts.net/?task=4")
        XCTAssertNil(s.page("https://evil.example.com/?task=3"))
        XCTAssertNil(s.page("//evil.example.com/x"))
        XCTAssertNil(s.page("http://mac.ts.net/?task=3"))
        XCTAssertNil(s.page("https://mac.ts.net:8443/"))
        XCTAssertEqual(try ServerAddress("http://localhost:8787").page("/?task=1")?.absoluteString, "http://localhost:8787/?task=1")
    }

    func testNotificationPageCarriesItsTextLikeTheServiceWorker() throws {
        let url = try XCTUnwrap(ServerAddress("mac.ts.net").page("/?task=3", title: "Task 3 is done", body: "C++ & more: 100%"))
        XCTAssertEqual(url.query, "task=3")
        var hash = URLComponents()
        hash.percentEncodedQuery = url.fragment(percentEncoded: true)
        XCTAssertEqual(hash.queryItems, [URLQueryItem(name: "title", value: "Task 3 is done"), URLQueryItem(name: "body", value: "C++ & more: 100%")])
        XCTAssertFalse(url.fragment(percentEncoded: true)?.contains("+") ?? true)
    }
}

final class PushRegistrationTests: XCTestCase {
    private func data(_ s: String) -> Data { Data(s.utf8) }

    private func profile(_ entitlements: String) -> Data {
        // A signed profile's plist between binary CMS bytes, as in embedded.mobileprovision.
        var d = Data([0x30, 0x82, 0x3c, 0x00, 0xff])
        d.append(data("""
            <?xml version="1.0" encoding="UTF-8"?>
            <!DOCTYPE plist PUBLIC "-//Apple//DTD PLIST 1.0//EN" "http://www.apple.com/DTDs/PropertyList-1.0.dtd">
            <plist version="1.0"><dict><key>Name</key><string>iOS Team Provisioning Profile</string>
            <key>Entitlements</key><dict>\(entitlements)</dict></dict></plist>
            """))
        d.append(contentsOf: [0x00, 0xa0, 0x82])
        return d
    }

    func testTokenIsHex() {
        XCTAssertEqual(PushRegistration.tokenString(Data([0x00, 0x0f, 0xab, 0xff])), "000fabff")
    }

    func testEnvironmentFromTheProfile() {
        XCTAssertEqual(PushRegistration.environment(provisioningProfile: nil), "production")  // App Store, TestFlight
        XCTAssertEqual(PushRegistration.environment(provisioningProfile: profile(
            "<key>aps-environment</key><string>development</string>")), "development")
        XCTAssertEqual(PushRegistration.environment(provisioningProfile: profile(
            "<key>aps-environment</key><string>production</string>")), "production")
        XCTAssertEqual(PushRegistration.environment(provisioningProfile: profile("")), "development")
        XCTAssertEqual(PushRegistration.environment(provisioningProfile: data("garbage")), "development")
    }

    func testBody() throws {
        let body = PushRegistration.body(passcode: "123456", device: "iphone", token: "abcd", environment: "development", topic: "com.anil.jarvis")
        let json = try JSONSerialization.jsonObject(with: body) as? [String: String]
        XCTAssertEqual(json, ["passcode": "123456", "device": "iphone", "token": "abcd", "environment": "development", "topic": "com.anil.jarvis"])
    }

    func testReplies() {
        XCTAssertNoThrow(try PushRegistration.parse(status: 200, body: data(#"{"ok":true}"#)).get())
        func refusal(_ status: Int, _ body: String) -> PushRegistration.Refusal? {
            if case .failure(let r) = PushRegistration.parse(status: status, body: data(body)) { return r }
            return nil
        }
        XCTAssertEqual(refusal(401, #"{"error":"Wrong passcode."}"#), .unauthorized)
        XCTAssertEqual(refusal(404, "Not Found"), .notSupported)
        XCTAssertEqual(refusal(409, #"{"error":"Notifications are off on the Mac. Set JARVIS_PUSH=on"}"#),
                       .off("Notifications are off on the Mac. Set JARVIS_PUSH=on"))
        XCTAssertEqual(refusal(500, ""), .server("JARVIS didn't take the notification token (HTTP 500)."))
    }
}

final class TokenReplyTests: XCTestCase {
    private func data(_ s: String) -> Data { Data(s.utf8) }

    func testGrant() {
        let r = TokenReply.parse(status: 200, body: data(#"{"token":"jwt","url":"wss://mac.ts.net"}"#))
        XCTAssertEqual(try r.get(), Grant(token: "jwt", url: "wss://mac.ts.net"))
    }

    func testRefusals() {
        XCTAssertEqual(TokenReply.parse(status: 401, body: data(#"{"error":"Wrong passcode."}"#)), .failure(.unauthorized))
        XCTAssertEqual(TokenReply.parse(status: 429, body: data(#"{"error":"Slow down."}"#)), .failure(.rateLimited("Slow down.")))
        XCTAssertEqual(TokenReply.parse(status: 503, body: data("The JARVIS web app isn't built.")),
                       .failure(.server("Couldn't reach JARVIS (HTTP 503).")))
        XCTAssertEqual(TokenReply.parse(status: 200, body: data(#"{"token":""}"#)), .failure(.badReply))
    }

    func testOnlyRefusalsStopRetries() {
        XCTAssertFalse(TokenError.unauthorized.isRetryable)
        XCTAssertFalse(TokenError.rateLimited("x").isRetryable)
        XCTAssertTrue(TokenError.server("x").isRetryable)
        XCTAssertTrue(TokenError.badReply.isRetryable)
    }

    func testBodyMatchesThePage() throws {
        let json = try JSONSerialization.jsonObject(with: TokenReply.body(passcode: "123456", device: "iphone")) as? [String: String]
        XCTAssertEqual(json, ["passcode": "123456", "device": "iphone"])
    }
}

final class ReconnectPolicyTests: XCTestCase {
    func testBacksOffThenHolds() {
        let p = ReconnectPolicy(jitter: 0)
        XCTAssertEqual((1...8).map { p.delay(attempt: $0) }, [1, 2, 4, 8, 15, 30, 30, 30])
    }

    func testJitterOnlyAdds() {
        let p = ReconnectPolicy(delays: [10], jitter: 0.2)
        XCTAssertEqual(p.delay(attempt: 1, random: 0), 10)
        XCTAssertEqual(p.delay(attempt: 1, random: 0.5), 11, accuracy: 1e-9)
        XCTAssertEqual(p.delay(attempt: 1, random: 5), 12, accuracy: 1e-9)  // clamped
    }

    func testOnlyUnplannedEndsReconnect() {
        XCTAssertTrue(DisconnectCause.network.shouldReconnect)
        XCTAssertTrue(DisconnectCause.unknown.shouldReconnect)
        XCTAssertFalse(DisconnectCause.clientInitiated.shouldReconnect)
        XCTAssertFalse(DisconnectCause.agentLeft.shouldReconnect)
        XCTAssertFalse(DisconnectCause.removed.shouldReconnect)
        XCTAssertFalse(DisconnectCause.duplicateIdentity.shouldReconnect)
    }
}

final class EarphoneDebouncerTests: XCTestCase {
    func testOnePressCountsOnce() {
        var d = EarphoneDebouncer(window: 0.4)
        XCTAssertTrue(d.accept(at: 10))
        XCTAssertFalse(d.accept(at: 10.1))  // the same press, as a second command
        XCTAssertFalse(d.accept(at: 10.39))
        XCTAssertTrue(d.accept(at: 10.5))
        d.reset()
        XCTAssertTrue(d.accept(at: 10.6))
    }

    func testClockGoingBackIsANewPress() {
        var d = EarphoneDebouncer()
        XCTAssertTrue(d.accept(at: 100))
        XCTAssertTrue(d.accept(at: 5))
    }
}

final class ChimeTests: XCTestCase {
    func testFallsForMutedRisesForListening() {
        XCTAssertEqual(Chime.frequencies(muted: true), [880, 587])
        XCTAssertEqual(Chime.frequencies(muted: false), [587, 880])
    }

    func testWavHeader() {
        let wav = Chime.wav(muted: true, rate: 24_000)
        XCTAssertEqual(String(decoding: wav[0..<4], as: UTF8.self), "RIFF")
        XCTAssertEqual(String(decoding: wav[8..<12], as: UTF8.self), "WAVE")
        let samples = Chime.samples(muted: true, rate: 24_000)
        XCTAssertEqual(wav.count, 44 + samples.count * 2)
        XCTAssertEqual(samples.count, 24_000 * 19 / 100)  // 190 ms
    }

    func testQuietAndShort() {
        let s = Chime.samples(muted: false)
        let peak = s.map(abs).max() ?? 0
        XCTAssertGreaterThan(peak, 0.1)
        XCTAssertLessThanOrEqual(peak, 0.16)
        XCTAssertLessThan(abs(s.last ?? 1), 0.001)  // faded out, no click
    }
}

final class CaptionsTests: XCTestCase {
    func testStreamsWholeLines() {
        var c = Captions()
        XCTAssertEqual(c.append(id: "s1", chunk: "Good ", speaker: "jarvis").text, "Good ")
        XCTAssertEqual(c.append(id: "s1", chunk: "evening", speaker: "jarvis", final: true),
                       Captions.Line(id: "s1", speaker: "jarvis", text: "Good evening", final: true))
    }

    func testResentSegmentStartsOver() {
        var c = Captions()
        _ = c.append(id: "s1", chunk: "draft", speaker: "you")
        c.begin(id: "s1")
        XCTAssertEqual(c.append(id: "s1", chunk: "final", speaker: "you").text, "final")
    }

    func testForgetsOldSegments() {
        var c = Captions(limit: 2)
        for id in ["a", "b", "c"] { _ = c.append(id: id, chunk: id, speaker: "you") }
        XCTAssertNil(c.text(id: "a"))
        XCTAssertEqual(c.text(id: "c"), "c")
    }

    func testSpeaker() {
        XCTAssertEqual(Captions.speaker(sender: "anil-iphone-ab12", local: "anil-iphone-ab12"), "you")
        XCTAssertEqual(Captions.speaker(sender: "agent-AJ_x", local: "anil-iphone-ab12"), "jarvis")
        XCTAssertEqual(Captions.speaker(sender: nil, local: nil), "jarvis")
    }

    func testAgentStates() {
        XCTAssertEqual(AgentStates.parse("Speaking"), "speaking")
        XCTAssertNil(AgentStates.parse("dancing"))
        XCTAssertNil(AgentStates.parse(nil))
    }
}

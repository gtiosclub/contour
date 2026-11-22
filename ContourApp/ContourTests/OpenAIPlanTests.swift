//
//  OpenAIPlanTests.swift
//  ContourTests
//
//  Throwaway OpenAI demo: the token swap against a stubbed App Check, and the voice
//  flow against a fake plan server. No network. Nothing here proves the live server,
//  the real console setup, or the phone.
//

import ContourCore
import ContourFeedback
import ContourMocks
import Foundation
import SurfaceUnderstanding
import Testing
@testable import ContourApp

// Made up, and long enough that they'd be noticed anywhere they leaked to.
private let fakeAppID = "1:111111111111:ios:fakeappidfakeappid"
private let fakeAPIKey = "FAKE-API-KEY-should-never-show"
private let fakeDebugToken = "FAKE-DEBUG-TOKEN-should-never-show"
private let fakeToken = "FAKE-APP-CHECK-TOKEN-should-never-show"
private let fakes = [fakeAppID, fakeAPIKey, fakeDebugToken, fakeToken]

private func leaks(_ text: String) -> Bool { fakes.contains { text.contains($0) } }

// MARK: - App Check, stubbed

private final class AppCheckStub: URLProtocol, @unchecked Sendable {
    struct Seen: Sendable {
        var url: String
        var method: String?
        var headers: [String: String]
        var body: Data?
    }

    private static let lock = NSLock()
    nonisolated(unsafe) private static var answers: [String: (status: Int, body: String, hang: Bool)] = [:]
    nonisolated(unsafe) private static var seen: [String: [Seen]] = [:]

    static func answer(_ id: String, status: Int = 200, body: String = "", hang: Bool = false) {
        lock.withLock { answers[id] = (status, body, hang) }
    }

    static func requests(_ id: String) -> [Seen] { lock.withLock { seen[id] ?? [] } }

    /// A session of its own, so stubs never touch the real network.
    static func session() -> URLSession {
        let configuration = URLSessionConfiguration.ephemeral
        configuration.protocolClasses = [AppCheckStub.self]
        return URLSession(configuration: configuration)
    }

    override class func canInit(with request: URLRequest) -> Bool { true }
    override class func canonicalRequest(for request: URLRequest) -> URLRequest { request }

    override func startLoading() {
        // Each test uses its own project id, which keeps parallel tests apart.
        let id = request.url?.pathComponents.dropFirst(3).first ?? ""
        var body = request.httpBody
        if body == nil, let stream = request.httpBodyStream {
            stream.open()
            defer { stream.close() }
            var data = Data()
            var buffer = [UInt8](repeating: 0, count: 4096)
            while stream.hasBytesAvailable {
                let count = stream.read(&buffer, maxLength: buffer.count)
                guard count > 0 else { break }
                data.append(contentsOf: buffer[0..<count])
            }
            body = data
        }
        let answer = Self.lock.withLock {
            Self.seen[id, default: []].append(Seen(url: request.url?.absoluteString ?? "", method: request.httpMethod,
                                                   headers: request.allHTTPHeaderFields ?? [:], body: body))
            return Self.answers[id] ?? (500, "", false)
        }
        guard !answer.hang else { return }
        guard answer.status != 0 else {
            // A real one carries the address it failed on.
            client?.urlProtocol(self, didFailWithError: URLError(.notConnectedToInternet,
                userInfo: [NSURLErrorFailingURLErrorKey: request.url as Any]))
            return
        }
        let response = HTTPURLResponse(url: request.url!, statusCode: answer.status, httpVersion: nil, headerFields: nil)!
        client?.urlProtocol(self, didReceive: response, cacheStoragePolicy: .notAllowed)
        client?.urlProtocol(self, didLoad: Data(answer.body.utf8))
        client?.urlProtocolDidFinishLoading(self)
    }

    override func stopLoading() {}
}

private final class TestTime: @unchecked Sendable {
    private let lock = NSLock()
    private var time = Date(timeIntervalSince1970: 1_000_000)
    var now: Date { lock.withLock { time } }
    func advance(_ seconds: TimeInterval) { lock.withLock { time += seconds } }
}

private let config = AppCheckLocalConfig(appID: fakeAppID, apiKey: fakeAPIKey, debugToken: fakeDebugToken)
private let goodAnswer = "{\"token\":\"\(fakeToken)\",\"ttl\":\"3600s\"}"

private func tokens(_ id: String, time: TestTime = TestTime()) -> AppCheckDebugTokens {
    AppCheckDebugTokens(config: config, projectID: id, bundleID: "edu.example.app",
                        session: AppCheckStub.session(), now: { time.now })
}

@Suite("App Check debug tokens")
struct AppCheckDebugTokensTests {
    @Test("Sends what exchangeDebugToken asks for, and the key isn't in the URL")
    func request() async throws {
        let id = UUID().uuidString
        AppCheckStub.answer(id, body: goodAnswer)
        _ = try await tokens(id).token()

        let seen = try #require(AppCheckStub.requests(id).first)
        #expect(seen.url == "https://firebaseappcheck.googleapis.com/v1/projects/\(id)/apps/\(fakeAppID):exchangeDebugToken")
        #expect(seen.method == "POST")
        #expect(seen.headers["X-Goog-Api-Key"] == fakeAPIKey)
        #expect(seen.headers["X-Ios-Bundle-Identifier"] == "edu.example.app")
        #expect(seen.headers["Content-Type"] == "application/json")
        #expect(!seen.url.contains(fakeAPIKey))
        let body = try JSONSerialization.jsonObject(with: try #require(seen.body)) as? [String: String]
        #expect(body == ["debugToken": fakeDebugToken])
    }

    @Test("Keeps the token until just before it expires, then gets a new one")
    func caches() async throws {
        let id = UUID().uuidString
        let time = TestTime()
        let source = tokens(id, time: time)
        AppCheckStub.answer(id, body: goodAnswer)

        #expect(try await source.token() == fakeToken)
        time.advance(3500)
        #expect(try await source.token() == fakeToken)
        #expect(AppCheckStub.requests(id).count == 1)

        time.advance(100)
        AppCheckStub.answer(id, body: #"{"token":"second","ttl":"3600.5s"}"#)
        #expect(try await source.token() == "second")
        #expect(AppCheckStub.requests(id).count == 2)
    }

    @Test("Everyone asking at once shares one exchange, because of the quota")
    func sharesOne() async throws {
        let id = UUID().uuidString
        AppCheckStub.answer(id, body: goodAnswer)
        let source = tokens(id)
        async let first = source.token()
        async let second = source.token()
        async let third = source.token()
        #expect(try await [first, second, third] == [fakeToken, fakeToken, fakeToken])
        #expect(AppCheckStub.requests(id).count == 1)
    }

    @Test("A refusal says the status, isn't kept, and the next ask tries again", arguments: [400, 401, 403, 404, 429, 500])
    func refused(status: Int) async throws {
        let id = UUID().uuidString
        let source = tokens(id)
        // A real error body could echo anything back. It must not reach the text.
        AppCheckStub.answer(id, status: status, body: "{\"error\":\"\(fakeAPIKey)\"}")
        await #expect(throws: AppCheckTokenError.refused(status: status)) { try await source.token() }
        do {
            _ = try await source.token()
        } catch {
            #expect(error.localizedDescription == "App Check said \(status)")
            #expect(!leaks(error.localizedDescription) && !leaks(String(describing: error)))
        }
        #expect(AppCheckStub.requests(id).count == 2)

        AppCheckStub.answer(id, body: goodAnswer)
        #expect(try await source.token() == fakeToken)
    }

    @Test("A bad answer is an error, not a token", arguments: [
        "<html>", "{}", #"{"token":"","ttl":"3600s"}"#, #"{"token":"x","ttl":"3600"}"#,
        #"{"token":"x","ttl":"s"}"#, #"{"token":"x","ttl":"0s"}"#, #"{"token":"x","ttl":"-5s"}"#, #"{"ttl":"3600s"}"#,
    ])
    func badAnswer(body: String) async {
        let id = UUID().uuidString
        AppCheckStub.answer(id, body: body)
        await #expect(throws: AppCheckTokenError.badResponse) { try await tokens(id).token() }
    }

    @Test("Cancelling stops the wait right away, so the plan's time limit holds")
    func cancelling() async {
        let id = UUID().uuidString
        AppCheckStub.answer(id, hang: true)
        let source = tokens(id)
        let started = ContinuousClock.now
        let waiting = Task { try await source.token() }
        try? await Task.sleep(for: .milliseconds(50))
        waiting.cancel()
        _ = try? await waiting.value
        #expect(ContinuousClock.now - started < .seconds(2))
    }

    @Test("Never prints its values")
    func description() throws {
        var dumped = ""
        dump(config, to: &dumped)
        for text in [String(describing: config), String(reflecting: config), "\(config)", dumped] {
            #expect(!leaks(text))
        }
    }
}

// MARK: - The local file

@Suite("AppCheck.local.plist")
struct AppCheckLocalFileTests {
    private func bundle(with plist: [String: Any]?) throws -> Bundle {
        let folder = FileManager.default.temporaryDirectory.appending(path: UUID().uuidString)
        try FileManager.default.createDirectory(at: folder, withIntermediateDirectories: true)
        if let plist {
            try PropertyListSerialization.data(fromPropertyList: plist, format: .xml, options: 0)
                .write(to: folder.appending(path: "AppCheck.local.plist"))
        }
        return try #require(Bundle(url: folder))
    }

    private let complete = ["GOOGLE_APP_ID": fakeAppID, "API_KEY": fakeAPIKey, "DEBUG_TOKEN": fakeDebugToken]

    @Test("No file means no server, with nothing else to set up")
    func noFile() throws {
        #expect(OpenAIPlans.fromBundle(try bundle(with: nil)) == nil)
    }

    @Test("Reads the three values")
    func reads() throws {
        let folder = try bundle(with: complete)
        let url = try #require(folder.url(forResource: "AppCheck.local", withExtension: "plist"))
        #expect(try AppCheckLocalConfig(contentsOf: url) == config)
        #expect(OpenAIPlans.fromBundle(folder) != nil)
    }

    @Test("A missing or untouched value names the key, and sends nothing", arguments: ["GOOGLE_APP_ID", "API_KEY", "DEBUG_TOKEN"])
    func incomplete(key: String) async throws {
        var missing: [String: Any] = complete
        missing[key] = nil
        var untouched: [String: Any] = complete
        untouched[key] = "PASTE_\(key)_HERE"
        for plist in [missing, untouched] {
            let openAI = try #require(OpenAIPlans.fromBundle(try bundle(with: plist)))
            await #expect(throws: AppCheckTokenError.badConfig(key)) { try await openAI.token() }
            do {
                _ = try await openAI.token()
            } catch {
                #expect(error.localizedDescription == "check \(key) in AppCheck.local.plist")
            }
        }
    }

    @Test("A file that isn't a plist doesn't crash and doesn't guess")
    func notAPlist() async throws {
        let folder = try bundle(with: nil)
        try Data("not a plist".utf8).write(to: folder.bundleURL.appending(path: "AppCheck.local.plist"))
        let openAI = try #require(OpenAIPlans.fromBundle(folder))
        await #expect(throws: AppCheckTokenError.badConfig("the file")) { try await openAI.token() }
    }
}

// MARK: - The voice flow

/// A panel with a key OpenAI can pick and the phone can't get to from "coffee".
private func panel(labels: [String]? = nil) -> SurfaceMap {
    let labels = labels ?? (Array("1234567890").map(String.init) + ["Start/Pause", "Add 30 Sec", "Time Cook", "Beverage", "Popcorn"])
    return SurfaceMap(buttons: labels.enumerated().map { i, label in
        SurfaceMap.Button(label: label, bounds: PanelRect(x: Double(i % 4) * 0.25, y: Double(i / 4) * 0.2,
                                                          width: 0.2, height: 0.15), confidence: 1)
    }, confidence: 1)
}

/// The plan server. Answers by label, so a test reads like what the model would pick.
private final class FakeServer: PlanService, @unchecked Sendable {
    private let lock = NSLock()
    private var asked: [PlanRequest] = []
    var requests: [PlanRequest] { lock.withLock { asked } }

    var labels: [String] = ["Beverage", "Start/Pause"]
    var say = "Press Beverage, then Start."
    var failure: PlanFallback?
    var delay: Duration?

    func plan(_ request: PlanRequest) async throws -> PlanResponse {
        lock.withLock { asked.append(request) }
        if let delay { try await Task.sleep(for: delay) }
        if let failure { throw failure }
        let steps = labels.compactMap { label in request.buttons.first { $0.label == label }?.id }
        return PlanResponse(steps: steps, say: say)
    }
}

private final class Speaker: PlanSpeaking {
    var spoken: [String] = []
    func speak(_ text: String) async {
        spoken.append(text)
        try? await Task.sleep(for: .milliseconds(1))
    }
    func stop() {}
}

/// Each `frames()` holds the finger on the key `target` names.
private final class Finger: TrackingSource, @unchecked Sendable {
    private let lock = NSLock()
    private var streams = 0
    private let target: @MainActor () -> PanelPoint?
    init(target: @escaping @MainActor () -> PanelPoint?) { self.target = target }
    var streamCount: Int { lock.withLock { streams } }

    func frames() -> AsyncStream<TrackingFrame> {
        lock.withLock { streams += 1 }
        let target = target
        return AsyncStream { continuation in
            Task { @MainActor in
                for _ in 0..<14 {
                    continuation.yield(TrackingFrame(timestamp: Date(), fingertip: target(),
                        panel: PanelPose(column0: SIMD4(1,0,0,0), column1: SIMD4(0,1,0,0),
                            column2: SIMD4(0,0,1,0), column3: SIMD4(0,0,0,1), confidence: 1), trackingQuality: .good))
                }
                continuation.finish()
            }
        }
    }
}

@MainActor
@Suite("OpenAI in the voice flow")
struct OpenAIVoiceFlowTests {
    private struct Rig {
        var model: CameraLaunchModel
        var finger: Finger
        var server: FakeServer
        var speaker: Speaker
        var tokenCount: () -> Int
    }

    /// A scanned model that hears `say`. `service: false` is the app with no plist.
    private func rig(say: String, map: SurfaceMap = panel(), service: Bool = true, server: FakeServer = FakeServer(),
                     timeout: Duration = .seconds(5),
                     token: @escaping @Sendable () async throws -> String = { "t" },
                     openAI real: OpenAIPlans? = nil,
                     next: @escaping @MainActor () async throws -> Bool = { true }) async -> Rig {
        let epoch = ContinuousClock.now
        var tick = 0
        var read: (() -> PanelPoint?)?
        let finger = Finger { read?() }
        let pipeline = ContourPipeline(surfaceUnderstanding: MockSurfaceUnderstanding(map: map), tracking: finger,
            feedback: PrintingFeedbackEngine(isPrinting: false), liveComponents: [], guidanceNow: {
                defer { tick += 1 }
                return epoch.advanced(by: .milliseconds(tick * 100))
            })
        let speaker = Speaker()
        let count = TokenCount()
        let openAI = real ?? (service ? OpenAIPlans(planner: TaskPlanner(service: server, timeout: timeout), token: {
            count.add()
            return try await token()
        }) : nil)
        let model = CameraLaunchModel(camera: CameraService(), pipeline: pipeline,
            listen: { map in VoiceRequest.Heard(text: say, button: ButtonLookup.button(for: say, in: map)) },
            listenForNext: next, speaker: speaker, openAI: openAI)
        read = { [weak model] in
            guard let model, let map = model.map else { return nil }
            if let plan = model.plan { return plan.steps[model.planIndex].button.bounds.center }
            // A one-key guide has no plan to read: follow the status line.
            return map.buttons.first { model.status.contains($0.label ?? "\u{0}") }?.bounds.center
        }
        await model.setActive(true).value
        model.scan()
        await model.waitForWork()
        return Rig(model: model, finger: finger, server: server, speaker: speaker, tokenCount: { count.value })
    }

    private final class TokenCount: @unchecked Sendable {
        private let lock = NSLock()
        private var count = 0
        var value: Int { lock.withLock { count } }
        func add() { lock.withLock { count += 1 } }
    }

    private func until(_ condition: () -> Bool) async {
        for _ in 0..<500 where !condition() { try? await Task.sleep(for: .milliseconds(10)) }
        #expect(condition())
    }

    // MARK: Order

    @Test("A scan sends nothing to the server, and gets one token ready", arguments: [true, false])
    func scanSendsNothing(tokenWorks: Bool) async {
        let r = await rig(say: "start", token: { if tokenWorks { return "t" }; throw AppCheckTokenError.refused(status: 403) })
        await until { r.model.planNote != nil }
        #expect(r.server.requests.isEmpty)
        #expect(r.tokenCount() == 1)
        #expect(r.model.planNote == (tokenWorks ? "OpenAI ready" : "OpenAI not ready, App Check said 403"))
        #expect(r.model.displayStatus.hasPrefix(r.model.planNote!))
    }

    @Test("Cook times never reach the server", arguments: [
        "cook for a minute and a half", "2 minutes", "30 seconds", "one minute thirty seconds", "90 seconds", "1:30",
    ])
    func cookTimes(say: String) async {
        let r = await rig(say: say)
        r.model.sayAButton()
        await r.model.waitForWork()
        #expect(r.server.requests.isEmpty)
        #expect(r.model.planNote == "Plan from phone")
        #expect(r.finger.streamCount >= 3)
        #expect(!r.speaker.spoken.contains("Asking OpenAI."))
    }

    @Test("Times the phone doesn't know don't reach the server either", arguments: [
        "cook for 45 seconds", "run it for 99 minutes", "heat it for a minute", "1:45", "cook for 90",
        "2 and a half minutes", "add 45 seconds", "set a timer for 2 minutes",
        "cook for one", "heat it up for one", "defrost one pound",
    ])
    func unknownTimes(say: String) async {
        let r = await rig(say: say)
        r.model.sayAButton()
        await r.model.waitForWork()
        #expect(r.server.requests.isEmpty)
        #expect(r.finger.streamCount == 0)
        #expect(r.model.planNote == "Plan from phone")
        #expect(r.speaker.spoken == ["I only know a minute and a half, 2 minutes or 30 seconds, so I won't guess that."])
    }

    @Test("A button the phone is sure of doesn't reach the server",
          arguments: ["add 30 seconds", "start", "go", "press start please", "popcorn", "time cook", "five"])
    func exactNames(say: String) async {
        let r = await rig(say: say)
        r.model.sayAButton()
        await r.model.waitForWork()
        #expect(r.server.requests.isEmpty)
        #expect(r.finger.streamCount == 1)
        #expect(r.model.plan == nil)
        #expect(r.model.planNote == "Plan from phone")
        #expect(r.speaker.spoken.isEmpty)
    }

    @Test("The phone's guess at the next safest key wins, so pause never goes to Cancel", arguments: [
        ("stop", ["Cancel", "Start"], "Cancel"),
        ("pause", ["Stop", "Cancel", "Start"], "Stop"),
        ("cancel", ["Stop", "Start"], "Stop"),
    ])
    func nextSafestKeyStaysOnThePhone(say: String, labels: [String], key: String) async {
        let server = FakeServer()
        server.labels = ["Cancel"]
        let r = await rig(say: say, map: panel(labels: labels), server: server)
        r.model.sayAButton()
        await r.model.waitForWork()
        #expect(r.server.requests.isEmpty)
        #expect(r.model.planNote == "Plan from phone")
        #expect(r.model.status == "Reached \(key).")
        #expect(r.finger.streamCount == 1)
    }

    @Test("Stop, pause and cancel aren't sent to the server even when the phone has no key for them", arguments: [
        ("pause", ["Cancel", "Start"]),
        ("pause the microwave", ["Stop", "Cancel", "Start"]),
        ("stop", ["Start", "Beverage"]),
    ])
    func stoppingStaysOnThePhone(say: String, labels: [String]) async {
        let server = FakeServer()
        server.labels = ["Cancel"]
        let r = await rig(say: say, map: panel(labels: labels), server: server)
        r.model.sayAButton()
        await r.model.waitForWork()
        #expect(r.server.requests.isEmpty)
        #expect(r.finger.streamCount == 0)
        #expect(r.model.status == "No button matching “\(say)”. Try again or choose a button below.")
    }

    // MARK: No plist

    @Test("No plist: what the phone can't find is what it always was, and nothing's added")
    func noConfig() async {
        let r = await rig(say: "heat up my coffee", service: false)
        #expect(r.model.planNote == nil)
        r.model.sayAButton()
        await r.model.waitForWork()
        #expect(r.server.requests.isEmpty)
        #expect(r.model.planNote == nil)
        #expect(r.speaker.spoken.isEmpty)
        #expect(r.model.status == "No button matching “heat up my coffee”. Try again or choose a button below.")
        #expect(r.model.displayStatus == r.model.status)
    }

    @Test("No plist: cook times and exact names behave as before, with no note", arguments: ["2 minutes", "add 30 seconds"])
    func noConfigStillWorks(say: String) async {
        let r = await rig(say: say, service: false)
        r.model.sayAButton()
        await r.model.waitForWork()
        #expect(r.finger.streamCount > 0)
        #expect(r.model.planNote == nil)
        #expect(!r.model.displayStatus.contains("Plan from"))
    }

    // MARK: A plan from the server

    @Test("Asks out loud, says the whole plan, then walks it")
    func serverPlan() async {
        let r = await rig(say: "heat up my coffee")
        r.model.sayAButton()
        await r.model.waitForWork()
        #expect(r.server.requests.map(\.request) == ["heat up my coffee"])
        #expect(r.speaker.spoken == [
            "Asking OpenAI.",
            "Press Beverage, then Start.",
            "Step 1 of 2: Beverage", "Press Beverage. Say next to move on.",
            "Step 2 of 2: Start", "Press Start. That's the last key.",
        ])
        #expect(r.finger.streamCount == 2)
        #expect(r.model.planNote == "Plan from OpenAI")
        #expect(r.model.displayStatus == "Plan from OpenAI. Press Start. That's the last key.")
    }

    @Test("Shows that it's asking while it waits")
    func showsAsking() async {
        let server = FakeServer()
        server.delay = .seconds(60)
        let r = await rig(say: "heat up my coffee", server: server)
        r.model.sayAButton()
        await until { r.server.requests.count == 1 && r.model.status == "Asking OpenAI." && r.speaker.spoken == ["Asking OpenAI."] }
        #expect(r.model.busy)
        r.model.stop()
        await r.model.waitForWork()
    }

    @Test("Says what's really next, whatever the model wrote")
    func ignoresTheModelsSentence() async {
        let server = FakeServer()
        server.say = "Press Popcorn."
        let r = await rig(say: "heat up my coffee", server: server)
        r.model.sayAButton()
        await r.model.waitForWork()
        #expect(r.speaker.spoken[1] == "Press Beverage, then Start.")
        #expect(!r.speaker.spoken.contains { $0.contains("Popcorn") })
    }

    @Test("The status keeps saying where the plan came from, past the Next button")
    func noteSurvivesNext() async {
        let server = FakeServer()
        server.labels = ["Beverage", "Popcorn", "Start/Pause"]
        let r = await rig(say: "heat up my coffee", server: server,
                          next: { try await Task.sleep(for: .seconds(60)); return false })
        r.model.sayAButton()
        await until { r.model.listening && r.model.planIndex == 0 }
        #expect(r.model.displayStatus.hasPrefix("Plan from OpenAI. Step 1 of 3: Beverage. "))
        r.model.next()
        #expect(r.model.planNote == "Plan from OpenAI")
        await until { r.model.listening && r.model.planIndex == 1 }
        #expect(r.model.displayStatus.hasPrefix("Plan from OpenAI. Step 2 of 3: Popcorn. "))
        r.model.stop()
        #expect(r.model.planNote == nil)
        await r.model.waitForWork()
    }

    @Test("Eight steps run, nine don't", arguments: [(8, true), (9, false), (20, false)])
    func stepCap(count: Int, runs: Bool) async {
        let server = FakeServer()
        server.labels = Array(repeating: "Beverage", count: count)
        let r = await rig(say: "heat up my coffee", server: server)
        r.model.sayAButton()
        await r.model.waitForWork()
        #expect(r.finger.streamCount == (runs ? count : 0))
        #expect(r.model.planNote == "Plan from OpenAI")
        if !runs {
            #expect(r.speaker.spoken.last == "OpenAI's plan has \(count) steps. That's too many to trust, so I won't run it.")
            #expect(r.model.plan == nil)
        }
    }

    @Test("A key that's on the map twice is refused out loud, and nothing is guided")
    func twoKeysReadTheSame() async {
        let server = FakeServer()
        server.labels = ["1", "0", "0", "Start/Pause"]
        let r = await rig(say: "heat up my coffee", map: panel(labels: ["1", "1", "0", "Start/Pause", "Beverage"]), server: server)
        r.model.sayAButton()
        await r.model.waitForWork()
        #expect(r.speaker.spoken == [
            "Asking OpenAI.", "I can't find one clear key for 1 on this panel, so I won't guess. Try scanning again.",
        ])
        #expect(r.finger.streamCount == 0)
        #expect(r.model.plan == nil)
    }

    @Test("Numbers with no Time Cook key: refused out loud, and nothing is guided")
    func noTimeCookRefused() async {
        let server = FakeServer()
        server.labels = ["1", "0", "0", "Start/Pause"]
        let r = await rig(say: "heat up my coffee", map: panel(labels: Array("1234567890").map(String.init) + ["Start/Pause", "Beverage"]),
                          server: server)
        r.model.sayAButton()
        await r.model.waitForWork()
        #expect(r.speaker.spoken == ["Asking OpenAI.", CookTimePlan.noClearKey(for: ["Time Cook"])])
        #expect(r.finger.streamCount == 0)
        #expect(r.model.plan == nil)
    }

    @Test("No steps, no match: keeps the server's sentence and guides nowhere")
    func noSteps() async {
        let server = FakeServer()
        server.labels = []
        server.say = "This microwave doesn't have a defrost button."
        let r = await rig(say: "defrost", server: server)
        r.model.sayAButton()
        await r.model.waitForWork()
        #expect(r.finger.streamCount == 0)
        #expect(r.model.planNote == "Plan from OpenAI")
        #expect(r.model.status == server.say)
        #expect(r.speaker.spoken == ["Asking OpenAI.", server.say])
    }

    @Test("No steps, but the sentence names keys: it isn't said, so it can't sound like a plan", arguments: [
        "Press 1, 0, 0, then Start.", "One, zero, zero, then go.", "Try the popcorn key.", "You could tap Beverage.",
    ])
    func noStepsNamesKeys(say: String) async {
        let server = FakeServer()
        server.labels = []
        server.say = say
        let r = await rig(say: "heat up my coffee", server: server)
        r.model.sayAButton()
        await r.model.waitForWork()
        #expect(r.finger.streamCount == 0)
        #expect(r.speaker.spoken == ["Asking OpenAI.", "OpenAI didn't find a plan for that."])
        #expect(r.model.status == "OpenAI didn't find a plan for that.")
    }

    // MARK: Failing where everyone can see

    @Test("A failure shows why, says why, and goes to the phone's answer", arguments: [
        (PlanFallback.status(401), "said 401"),
        (PlanFallback.status(429), "said 429"),
        (PlanFallback.status(504), "said 504"),
        (PlanFallback.noToken("App Check said 403"), "has no token, App Check said 403"),
        (PlanFallback.unreachable, "can't be reached"),
        (PlanFallback.badAnswer, "sent a bad answer"),
    ])
    func failure(why: PlanFallback, words: String) async {
        let server = FakeServer()
        server.failure = why
        let r = await rig(say: "heat up my coffee", server: server)
        r.model.sayAButton()
        await r.model.waitForWork()
        #expect(r.model.planNote == "Plan from phone, OpenAI \(words)")
        #expect(r.model.displayStatus.hasPrefix("Plan from phone, OpenAI \(words). "))
        #expect(r.speaker.spoken == ["Asking OpenAI.", "OpenAI \(words), so using the phone.", "I couldn't find that on this panel."])
        #expect(r.finger.streamCount == 0)
        #expect(r.model.plan == nil)
    }

    @Test("Slow means timed out, on screen and out loud")
    func timesOut() async {
        let server = FakeServer()
        server.delay = .seconds(60)
        let r = await rig(say: "heat up my coffee", server: server, timeout: .milliseconds(50))
        r.model.sayAButton()
        await r.model.waitForWork()
        #expect(r.model.planNote == "Plan from phone, OpenAI timed out")
        #expect(r.speaker.spoken.contains("OpenAI timed out, so using the phone."))
    }

    @Test("Stop while asking ends it: nothing more said, nothing guided")
    func stopWhileAsking() async {
        let server = FakeServer()
        server.delay = .seconds(60)
        let r = await rig(say: "heat up my coffee", server: server)
        r.model.sayAButton()
        await until { r.server.requests.count == 1 && r.speaker.spoken == ["Asking OpenAI."] }
        r.model.stop()
        await r.model.waitForWork()
        #expect(r.speaker.spoken == ["Asking OpenAI."])
        #expect(r.finger.streamCount == 0)
        #expect(r.model.planNote == nil)
        #expect(r.model.status.hasPrefix("Stopped"))
    }

    @Test("A rescan while asking drops the answer: its ids are for the old map")
    func rescanWhileAsking() async {
        let server = FakeServer()
        server.delay = .milliseconds(100)
        let r = await rig(say: "heat up my coffee", server: server)
        r.model.sayAButton()
        await until { r.server.requests.count == 1 }
        r.model.scan()
        await r.model.waitForWork()
        try? await Task.sleep(for: .milliseconds(200))
        #expect(r.finger.streamCount == 0)
        #expect(r.model.plan == nil)
        #expect(!r.speaker.spoken.contains("Press Beverage, then Start."))
    }

    // MARK: Secrets

    @Test("No secret reaches a status line or anything said, through the real token code", arguments: [
        (401, ""), (403, "{\"error\":\"\(fakeAPIKey) \(fakeDebugToken) \(fakeAppID)\"}"), (500, fakeAPIKey),
        (0, ""), (200, "<html>\(fakeAPIKey)"),
    ])
    func noSecretsInStatus(status: Int, body: String) async throws {
        let id = UUID().uuidString
        AppCheckStub.answer(id, status: status, body: body)
        let tokens = tokens(id)
        let token: @Sendable () async throws -> String = { try await tokens.token() }
        // The token fails first, so this address is never called.
        let service = LivePlanService(baseURL: try #require(URL(string: "https://plan.invalid/api")),
                                      appCheckToken: token)
        let openAI = OpenAIPlans(planner: TaskPlanner(service: service, timeout: .seconds(5)), token: token)

        let r = await rig(say: "heat up my coffee", openAI: openAI)
        await until { r.model.planNote != nil }
        #expect(r.model.planNote?.hasPrefix("OpenAI not ready, ") == true)
        var seen = [r.model.status, r.model.displayStatus]
        r.model.sayAButton()
        await r.model.waitForWork()
        #expect(r.model.planNote?.hasPrefix("Plan from phone, OpenAI has no token, ") == true)
        seen += [r.model.status, r.model.displayStatus, r.model.planNote ?? "", r.model.error ?? ""] + r.speaker.spoken
        for text in seen { #expect(!leaks(text), "leaked: \(text)") }
    }

    @Test("The token itself isn't shown when everything works")
    func noTokenInStatus() async {
        let r = await rig(say: "heat up my coffee", token: { fakeToken })
        await until { r.model.planNote != nil }
        var seen = [r.model.status, r.model.displayStatus]
        r.model.sayAButton()
        await r.model.waitForWork()
        seen += [r.model.status, r.model.displayStatus, r.model.planNote ?? ""] + r.speaker.spoken
        for text in seen { #expect(!leaks(text), "leaked: \(text)") }
    }
}

@Suite("A server plan as steps")
struct ServerStepsTests {
    private let map = panel()
    private func button(_ label: String, in map: SurfaceMap) -> SurfaceMap.Button { map.buttons.first { $0.label == label }! }
    private func plan(_ labels: [String], in map: SurfaceMap = panel()) -> CookTimePlan? {
        guard case .plan(let plan) = CookTimePlan.make(serverSteps: labels.map { button($0, in: map) }, in: map) else {
            return nil
        }
        return plan
    }

    @Test("Start is called Start, whatever the scan read it as")
    func names() throws {
        let plan = try #require(plan(["Beverage", "Start/Pause"], in: map))
        #expect(plan.steps.map(\.name) == ["Beverage", "Start"])
        #expect(plan.say == "Press Beverage, then Start.")
    }

    @Test("One key, and several")
    func sentences() {
        #expect(plan(["Beverage"], in: map)?.say == "Press Beverage.")
        #expect(plan(["Time Cook", "1", "3", "0", "Start/Pause"], in: map)?.say == "Press Time Cook, 1, 3, 0, then Start.")
    }

    @Test("A key whose label is on the map twice is a guess, so the plan is refused", arguments: [
        (["1", "1", "0", "Start/Pause"], [1, 2, 2, 3], "1"),
        (["1", "0", "START", "Start"], [0, 1, 3], "Start"),
        (["Beverage", "beverage ", "Start/Pause"], [0, 2], "Beverage"),
    ])
    func twoKeysReadTheSame(labels: [String], picked: [Int], name: String) {
        let map = panel(labels: labels)
        #expect(CookTimePlan.make(serverSteps: picked.map { map.buttons[$0] }, in: map) == .missing(
            "I can't find one clear key for \(name) on this panel, so I won't guess. Try scanning again."))
    }

    @Test("No number before Time Cook: with Express Cook, a number pressed first can start cooking")
    func noNumberBeforeTimeCook() {
        let noTimeCook = panel(labels: Array("1234567890").map(String.init) + ["Start/Pause", "Beverage"])
        func outcome(_ labels: [String], in map: SurfaceMap) -> CookTimePlan.Outcome {
            CookTimePlan.make(serverSteps: labels.map { button($0, in: map) }, in: map)
        }
        #expect(outcome(["1", "0", "0", "Start/Pause"], in: noTimeCook) == .missing(CookTimePlan.noClearKey(for: ["Time Cook"])))
        #expect(outcome(["Beverage", "2", "Start/Pause"], in: noTimeCook) == .missing(CookTimePlan.noClearKey(for: ["Time Cook"])))
        #expect(outcome(["1", "0", "0", "Start/Pause"], in: map) == .missing(CookTimePlan.skipsTimeCook))
        #expect(outcome(["1", "Time Cook", "0", "0", "Start/Pause"], in: map) == .missing(CookTimePlan.skipsTimeCook))
        #expect(plan(["Beverage", "Start/Pause"], in: noTimeCook) != nil, "No numbers, nothing to refuse")
        #expect(plan(["Time Cook", "1", "0", "0", "Start/Pause"], in: map) != nil)
    }
}

@Suite("What stays on the phone")
struct MentionsATimeTests {
    @Test("Times and numbers", arguments: [
        "cook for 45 seconds", "a minute", "half a minute", "1:30", "90", "ninety", "two minutes", "an hour", "cook for 1",
        "cook for one", "heat it up for one", "defrost one pound", "the popcorn one",
    ])
    func yes(request: String) { #expect(CookTime.mentionsATime(request)) }

    @Test("Everything else", arguments: [
        "heat up my coffee", "reheat my food", "cook a baked potato", "turn it off", "defrost",
    ])
    func no(request: String) { #expect(!CookTime.mentionsATime(request)) }
}

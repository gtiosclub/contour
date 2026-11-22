//
//  LivePlanServiceTests.swift
//  SurfaceUnderstanding — Surface / Target Matching
//
//  Checks the one thing the fake can't: that LivePlanService sends the
//  App Check token the server needs, as the X-Firebase-AppCheck header.
//

import ContourCore
import Foundation
import Testing
@testable import SurfaceUnderstanding

/// Answers requests to plan.test with a canned plan and remembers the header.
final class PlanStubProtocol: URLProtocol, @unchecked Sendable {
    nonisolated(unsafe) static var lastAppCheck: String?
    nonisolated(unsafe) static var requests = 0
    nonisolated(unsafe) static var status = 200
    nonisolated(unsafe) static var reply = #"{"steps":[],"say":"ok"}"#

    override class func canInit(with request: URLRequest) -> Bool { request.url?.host == "plan.test" }
    override class func canonicalRequest(for request: URLRequest) -> URLRequest { request }

    override func startLoading() {
        Self.lastAppCheck = request.value(forHTTPHeaderField: "X-Firebase-AppCheck")
        Self.requests += 1
        let body = Data(Self.reply.utf8)
        let response = HTTPURLResponse(url: request.url!, statusCode: Self.status, httpVersion: nil,
                                       headerFields: ["Content-Type": "application/json"])!
        client?.urlProtocol(self, didReceive: response, cacheStoragePolicy: .notAllowed)
        client?.urlProtocol(self, didLoad: body)
        client?.urlProtocolDidFinishLoading(self)
    }

    override func stopLoading() {}
}

@Suite("Live plan service", .serialized)
struct LivePlanServiceTests {

    @Test("sends the App Check token as a header")
    func sendsAppCheckHeader() async throws {
        URLProtocol.registerClass(PlanStubProtocol.self)
        defer { URLProtocol.unregisterClass(PlanStubProtocol.self) }
        PlanStubProtocol.lastAppCheck = nil

        let service = LivePlanService(baseURL: URL(string: "https://plan.test/api")!,
                                      appCheckToken: { "token-123" })
        let reply = try await service.plan(PlanRequest(request: "start", buttons: []))

        #expect(reply.say == "ok")
        #expect(PlanStubProtocol.lastAppCheck == "token-123")
    }

    private static let base = URL(string: "https://plan.test/api")!

    /// The stub answers `status` with `reply` for the length of `body`.
    private func stubbed(status: Int = 200, reply: String = #"{"steps":[],"say":"ok"}"#,
                         _ body: () async throws -> Void) async throws {
        URLProtocol.registerClass(PlanStubProtocol.self)
        defer {
            URLProtocol.unregisterClass(PlanStubProtocol.self)
            PlanStubProtocol.status = 200
            PlanStubProtocol.reply = #"{"steps":[],"say":"ok"}"#
        }
        PlanStubProtocol.requests = 0
        PlanStubProtocol.status = status
        PlanStubProtocol.reply = reply
        try await body()
    }

    @Test("a 401 says it was a 401, even though the body decodes")
    func unauthorized() async throws {
        let refused = #"{"steps":[],"say":"Sorry, Contour couldn't verify this app.","error":"unauthorized"}"#
        try await stubbed(status: 401, reply: refused) {
            let service = LivePlanService(baseURL: Self.base, appCheckToken: { "token-123" })
            await #expect(throws: PlanFallback.status(401)) {
                try await service.plan(PlanRequest(request: "start", buttons: []))
            }
        }
    }

    @Test("no token means no request at all, and says why")
    func noToken() async throws {
        struct NoToken: LocalizedError { var errorDescription: String? { "App Check said 403" } }
        try await stubbed {
            let service = LivePlanService(baseURL: Self.base, appCheckToken: { throw NoToken() })
            await #expect(throws: PlanFallback.noToken("App Check said 403")) {
                try await service.plan(PlanRequest(request: "start", buttons: []))
            }
            #expect(PlanStubProtocol.requests == 0)
        }
    }

    @Test("a 200 that isn't a plan is a bad answer")
    func notJSON() async throws {
        try await stubbed(reply: "<html>") {
            let service = LivePlanService(baseURL: Self.base, appCheckToken: { "token-123" })
            await #expect(throws: PlanFallback.badAnswer) {
                try await service.plan(PlanRequest(request: "start", buttons: []))
            }
        }
    }

    @Test("a token that never comes still loses to the time limit")
    func hangingToken() async throws {
        try await stubbed {
            let service = LivePlanService(baseURL: Self.base, appCheckToken: {
                try await Task.sleep(for: .seconds(60))
                return "too late"
            })
            let started = ContinuousClock.now
            let plan = await TaskPlanner(service: service, timeout: .milliseconds(100))
                .plan("start", in: RealPanelLabels.map("hand-labelled microwave-01.jpg"))
            #expect(ContinuousClock.now - started < .seconds(2))
            #expect(plan.fallback == .timedOut)
            #expect(plan.steps.map(\.label) == ["Start/Pause"])
            #expect(PlanStubProtocol.requests == 0)
        }
    }
}

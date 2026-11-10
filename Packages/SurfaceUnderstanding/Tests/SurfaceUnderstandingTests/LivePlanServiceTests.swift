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

    override class func canInit(with request: URLRequest) -> Bool { request.url?.host == "plan.test" }
    override class func canonicalRequest(for request: URLRequest) -> URLRequest { request }

    override func startLoading() {
        Self.lastAppCheck = request.value(forHTTPHeaderField: "X-Firebase-AppCheck")
        let body = Data(#"{"steps":[],"say":"ok"}"#.utf8)
        let response = HTTPURLResponse(url: request.url!, statusCode: 200, httpVersion: nil,
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
}

import Foundation
import Testing
@testable import ContourApp

@MainActor
@Suite("Camera revision identity")
struct CameraStatusRevisionTests {
    @Test("Starting the same capture run cannot cause diagnostics to repeatedly restart")
    func repeatedStartIsIdempotent() {
        let status = CameraStatus()
        let run = UUID()
        status.didStartRun(run)
        let firstRevision = status.revision
        status.error = "Previous failure"
        status.didStartRun(run)
        #expect(status.revision == firstRevision)
        #expect(status.error == nil)
        status.didStartRun(UUID())
        #expect(status.revision == firstRevision + 1)
    }
}

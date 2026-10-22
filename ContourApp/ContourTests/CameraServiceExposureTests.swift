import Testing
@testable import ContourApp

@Suite("Camera exposure control")
struct CameraServiceExposureTests {
    @Test("Before capture starts, only automatic exposure is reported as supported")
    func unconfiguredExposure() async throws {
        let camera = CameraService()
        #expect(try await camera.setExposureBias(0) == nil)
        await #expect(throws: CameraService.CameraError.self) {
            try await camera.setExposureBias(-0.7)
        }
    }

    @Test("A non-finite bias is rejected")
    func nonFiniteBias() async {
        await #expect(throws: CameraService.CameraError.self) {
            try await CameraService().setExposureBias(.nan)
        }
    }
}

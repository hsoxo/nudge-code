import Testing
@testable import NudgeMobile

@Suite("QR scanner")
struct QRCodeScannerTests {
    @Test func scannerErrorsHaveUserVisibleMessages() {
        #expect(QRCodeScannerError.cameraUnavailable.message == "Camera is unavailable")
        #expect(QRCodeScannerError.permissionDenied.message == "Camera permission is required")
        #expect(QRCodeScannerError.configurationFailed.message == "Unable to start QR scanner")
    }
}

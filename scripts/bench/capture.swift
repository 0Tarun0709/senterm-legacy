import AppKit
import ScreenCaptureKit
import CoreMedia
import Darwin

final class Output: NSObject, SCStreamOutput {
    private var last = -1
    func stream(_ stream: SCStream, didOutputSampleBuffer sampleBuffer: CMSampleBuffer, of type: SCStreamOutputType) {
        guard type == .screen, let image = sampleBuffer.imageBuffer else { return }
        CVPixelBufferLockBaseAddress(image, .readOnly)
        defer { CVPixelBufferUnlockBaseAddress(image, .readOnly) }
        guard let ptr = CVPixelBufferGetBaseAddress(image)?.assumingMemoryBound(to: UInt8.self) else { return }
        let pitch = CVPixelBufferGetBytesPerRow(image)
        var hit = [0,0,0,0]
        for y in stride(from: 4, to: CVPixelBufferGetHeight(image), by: 8) {
            for x in stride(from: 4, to: CVPixelBufferGetWidth(image), by: 8) {
                let p = ptr + y*pitch + x*4
                let (r,g,b) = (p[2],p[1],p[0])
                if Int(r) > Int(g)+70 && Int(r) > Int(b)+70 { hit[0] += 1 }
                if Int(g) > Int(r)+70 && Int(g) > Int(b)+70 { hit[1] += 1 }
                if Int(b) > Int(r)+70 && Int(b) > Int(g)+70 { hit[2] += 1 }
                if min(Int(r),Int(b)) > Int(g)+70 { hit[3] += 1 }
            }
        }
        let id = hit.firstIndex(of: hit.max()!)!
        let actual = hit[id] >= 24 ? id : -1
        if actual != last {
            last = actual
            print("\(Date().timeIntervalSince1970) \(actual)")
            fflush(stdout)
        }
    }
}
@main struct Main {
    @MainActor static func main() async throws {
        _ = NSApplication.shared
        guard CGPreflightScreenCaptureAccess() else { exit(3) }
        let pid = Int32(CommandLine.arguments[1])!
        let windows = try await SCShareableContent.excludingDesktopWindows(true, onScreenWindowsOnly: true)
        let candidates = windows.windows.filter { $0.owningApplication?.processID == pid && $0.frame.width > 450 }
        guard let window = candidates.max(by: { $0.frame.width * $0.frame.height < $1.frame.width * $1.frame.height }) else {
            exit(2)
        }
        let cfg = SCStreamConfiguration()
        cfg.width = 480
        cfg.height = Int(480 * window.frame.height / window.frame.width)
        cfg.pixelFormat = kCVPixelFormatType_32BGRA
        cfg.minimumFrameInterval = CMTime(value: 1, timescale: 120)
        cfg.showsCursor = false
        let stream = SCStream(filter: SCContentFilter(desktopIndependentWindow: window), configuration: cfg, delegate: nil)
        let output = Output()
        try stream.addStreamOutput(output, type: .screen, sampleHandlerQueue: .init(label: "capture"))
        try await stream.startCapture()
        print("ready")
        fflush(stdout)
        try await Task.sleep(for: .seconds(90))
        try await stream.stopCapture()
    }
}

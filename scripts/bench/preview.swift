import AppKit
@testable import SenTerm

@main struct PreviewBenchmark {
    @MainActor static func main() {
        let app = NSApplication.shared
        app.setActivationPolicy(.accessory)
        app.finishLaunching()
        let font = NSFont.monospacedSystemFont(ofSize: 13, weight: .regular)
        let width = ceil(("M" as NSString).size(withAttributes: [.font: font]).width)
        let height = ceil(font.ascender - font.descender + font.leading) + 2
        let frame = NSRect(x: 0, y: 0, width: 113 * width + 16, height: 44 * height + 16)
        let pane = GhosttyPreview(previewFrame: frame)!
        let window = NSWindow(contentRect: frame, styleMask: [.titled, .resizable], backing: .buffered, defer: false)
        window.contentView = pane
        window.delegate = pane
        window.center()
        window.orderFront(nil)
        pane.start(directory: FileManager.default.currentDirectoryPath)
        while pane.process.running { RunLoop.main.run(until: Date().addingTimeInterval(0.05)) }
    }
}

import AppKit
import Carbon.HIToolbox
@testable import SenTerm

@main
struct GhosttyWindowProbe {
    @MainActor static func main() {
        let app = NSApplication.shared
        _ = app.setActivationPolicy(.accessory)
        app.finishLaunching()
        let frame = NSRect(x: 0, y: 0, width: 680, height: 320)
        let window = NSWindow(contentRect: frame, styleMask: [.titled, .resizable, .closable], backing: .buffered, defer: false)
        window.isReleasedWhenClosed = false
        let pane = GhosttyPreview(previewFrame: frame)!
        window.contentView = pane
        window.delegate = pane
        window.makeKeyAndOrderFront(nil)
        precondition(window.makeFirstResponder(pane))
        pane.start(directory: "/private/tmp", shell: "/bin/sh")
        defer { pane.stop() }

        func press(_ text: String, key: Int = 0) {
            let event = NSEvent.keyEvent(with: .keyDown, location: .zero, modifierFlags: [], timestamp: 0,
                                         windowNumber: window.windowNumber, context: nil, characters: text,
                                         charactersIgnoringModifiers: text, isARepeat: false, keyCode: UInt16(key))!
            window.sendEvent(event)
        }

        func expect(_ text: String) {
            let deadline = Date().addingTimeInterval(3)
            repeat {
                RunLoop.main.run(until: Date().addingTimeInterval(0.02))
                let image = pane.bitmapImageRepForCachingDisplay(in: pane.bounds)!
                pane.cacheDisplay(in: pane.bounds, to: image)
                if (pane.accessibilityValue() as? String)?.contains(text) == true { return }
            } while Date() < deadline
            fatalError("missing rendered output: \(text); got \(String(describing: pane.accessibilityValue()))")
        }

        press("printf '\\033[31m%s\\033[0m\\n' \"$(pwd)\"")
        press("\r", key: kVK_Return)
        expect("/private/tmp")
        let before = pane.getWindowSize()
        window.setContentSize(NSSize(width: 880, height: 380))
        let after = pane.getWindowSize()
        precondition(after.ws_col > before.ws_col && after.ws_row > before.ws_row)
        press("stty size")
        press("\r", key: kVK_Return)
        expect("\(after.ws_row) \(after.ws_col)")
        precondition(pane.process.running)
        window.close()
        precondition(!pane.process.running)
        print("libghostty window probe passed")
    }
}

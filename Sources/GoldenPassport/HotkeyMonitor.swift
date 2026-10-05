import AppKit
import GoldenPassportCore

/// Fills in the code of account N when ⇧⌘N (N = 0–9) is pressed in another app.
/// Needs the Accessibility permission to observe keys and post the ⌘V.
final class HotkeyMonitor {
    private static let digitKeyCodes: [UInt16: Int] = [
        29: 0, 18: 1, 19: 2, 20: 3, 21: 4, 23: 5, 22: 6, 26: 7, 28: 8, 25: 9,
    ]

    private let store: AccountStore
    private var monitor: Any?

    init(store: AccountStore) {
        self.store = store
    }

    func start(promptForPermission: Bool) {
        guard monitor == nil else { return }
        let options = [kAXTrustedCheckOptionPrompt.takeUnretainedValue() as String: promptForPermission] as CFDictionary
        guard AXIsProcessTrustedWithOptions(options) else { return }
        monitor = NSEvent.addGlobalMonitorForEvents(matching: .keyDown) { [weak self] event in
            self?.handle(event)
        }
    }

    func stop() {
        if let monitor { NSEvent.removeMonitor(monitor) }
        monitor = nil
    }

    private func handle(_ event: NSEvent) {
        let flags = event.modifierFlags.intersection(.deviceIndependentFlagsMask).subtracting([.capsLock, .numericPad, .function])
        guard flags == [.command, .shift],
              let index = Self.digitKeyCodes[event.keyCode] else { return }
        let accounts = store.accounts
        guard index < accounts.count,
              case .success(let code) = AccountStore.code(for: accounts[index], at: Date()).result else { return }
        paste(code)
    }

    private func paste(_ text: String) {
        let pasteboard = NSPasteboard.general
        let previous = pasteboard.string(forType: .string)
        pasteboard.clearContents()
        pasteboard.setString(text, forType: .string)
        let ourChange = pasteboard.changeCount

        postCommandV()

        guard let previous else { return }
        DispatchQueue.main.asyncAfter(deadline: .now() + 1) {
            // Don't clobber something the user copied in the meantime.
            guard pasteboard.changeCount == ourChange else { return }
            pasteboard.clearContents()
            pasteboard.setString(previous, forType: .string)
        }
    }

    private func postCommandV() {
        let source = CGEventSource(stateID: .combinedSessionState)
        let vKey: CGKeyCode = 9
        for keyDown in [true, false] {
            let event = CGEvent(keyboardEventSource: source, virtualKey: vKey, keyDown: keyDown)
            event?.flags = .maskCommand
            event?.post(tap: .cghidEventTap)
        }
    }
}

import AppKit
import Carbon.HIToolbox
import GoldenPassportCore

/// Global hotkeys <modifiers>+N (N = 0–9) that type the code of account N into the
/// frontmost app. Registered with Carbon so the keystroke is consumed (it no longer
/// also reaches the frontmost app); posting the ⌘V needs the Accessibility permission,
/// without it the code is only copied to the pasteboard.
final class HotkeyMonitor {
    private static let digitKeyCodes: [Int] = [
        kVK_ANSI_0, kVK_ANSI_1, kVK_ANSI_2, kVK_ANSI_3, kVK_ANSI_4,
        kVK_ANSI_5, kVK_ANSI_6, kVK_ANSI_7, kVK_ANSI_8, kVK_ANSI_9,
    ]
    private static let signature: OSType = 0x4750_484B // "GPHK"

    private let store: AccountStore
    private var hotKeyRefs: [EventHotKeyRef] = []
    private var handlerRef: EventHandlerRef?
    private(set) var failedDigits: [Int] = []

    init(store: AccountStore) {
        self.store = store
    }

    deinit {
        stop()
    }

    func start(modifiers: HotkeyModifiers) {
        stop()
        installHandlerIfNeeded()
        failedDigits = []
        for (digit, keyCode) in Self.digitKeyCodes.enumerated() {
            var ref: EventHotKeyRef?
            let id = EventHotKeyID(signature: Self.signature, id: UInt32(digit))
            let status = RegisterEventHotKey(UInt32(keyCode), Self.carbonFlags(modifiers), id,
                                             GetApplicationEventTarget(), 0, &ref)
            if status == noErr, let ref {
                hotKeyRefs.append(ref)
            } else {
                failedDigits.append(digit)
            }
        }
    }

    func stop() {
        hotKeyRefs.forEach { UnregisterEventHotKey($0) }
        hotKeyRefs = []
    }

    static func requestAccessibilityIfNeeded() -> Bool {
        let options = [kAXTrustedCheckOptionPrompt.takeUnretainedValue() as String: true] as CFDictionary
        return AXIsProcessTrustedWithOptions(options)
    }

    static func keyEquivalentModifierMask(_ modifiers: HotkeyModifiers) -> NSEvent.ModifierFlags {
        switch modifiers {
        case .controlOptionCommand: return [.control, .option, .command]
        case .shiftCommand: return [.shift, .command]
        case .controlOption: return [.control, .option]
        }
    }

    private static func carbonFlags(_ modifiers: HotkeyModifiers) -> UInt32 {
        switch modifiers {
        case .controlOptionCommand: return UInt32(controlKey | optionKey | cmdKey)
        case .shiftCommand: return UInt32(shiftKey | cmdKey)
        case .controlOption: return UInt32(controlKey | optionKey)
        }
    }

    private func installHandlerIfNeeded() {
        guard handlerRef == nil else { return }
        var spec = EventTypeSpec(eventClass: OSType(kEventClassKeyboard), eventKind: UInt32(kEventHotKeyPressed))
        InstallEventHandler(GetApplicationEventTarget(), { _, event, userData in
            guard let event, let userData else { return OSStatus(eventNotHandledErr) }
            var id = EventHotKeyID()
            let status = GetEventParameter(event, EventParamName(kEventParamDirectObject), EventParamType(typeEventHotKeyID),
                                           nil, MemoryLayout<EventHotKeyID>.size, nil, &id)
            guard status == noErr, id.signature == HotkeyMonitor.signature else { return OSStatus(eventNotHandledErr) }
            let monitor = Unmanaged<HotkeyMonitor>.fromOpaque(userData).takeUnretainedValue()
            monitor.fill(accountAt: Int(id.id))
            return noErr
        }, 1, &spec, Unmanaged.passUnretained(self).toOpaque(), &handlerRef)
    }

    private func fill(accountAt index: Int) {
        let accounts = store.accounts
        guard index < accounts.count,
              case .success(let code) = AccountStore.code(for: accounts[index], at: Date()).result else {
            NSSound.beep()
            return
        }
        let pasteboard = NSPasteboard.general
        let previous = pasteboard.string(forType: .string)
        pasteboard.clearContents()
        pasteboard.setString(code, forType: .string)

        guard AXIsProcessTrusted() else {
            // Can't type into other apps yet: the code stays on the pasteboard. The permission
            // prompt is shown when hotkeys are switched on, not on every keystroke.
            return
        }
        let ourChange = pasteboard.changeCount
        pasteWhenModifiersReleased(deadline: Date().addingTimeInterval(1)) {
            guard let previous else { return }
            DispatchQueue.main.asyncAfter(deadline: .now() + 1) {
                // Don't clobber something the user copied in the meantime.
                guard pasteboard.changeCount == ourChange else { return }
                pasteboard.clearContents()
                pasteboard.setString(previous, forType: .string)
            }
        }
    }

    /// The hotkey fires on key-down while ⌃/⌥/⇧ are still held; pasting then would send
    /// e.g. ⌃⌥⌘V. Wait (briefly) until only ⌘ or nothing is held.
    private func pasteWhenModifiersReleased(deadline: Date, then completion: @escaping () -> Void) {
        let held = CGEventSource.flagsState(.combinedSessionState)
            .intersection([.maskControl, .maskAlternate, .maskShift])
        if !held.isEmpty && Date() < deadline {
            DispatchQueue.main.asyncAfter(deadline: .now() + 0.02) {
                self.pasteWhenModifiersReleased(deadline: deadline, then: completion)
            }
            return
        }
        Self.postCommandV()
        completion()
    }

    private static func postCommandV() {
        let source = CGEventSource(stateID: .privateState)
        let vKey = CGKeyCode(kVK_ANSI_V)
        for keyDown in [true, false] {
            let event = CGEvent(keyboardEventSource: source, virtualKey: vKey, keyDown: keyDown)
            event?.flags = .maskCommand
            event?.post(tap: .cghidEventTap)
        }
    }
}

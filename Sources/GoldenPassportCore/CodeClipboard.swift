import AppKit

/// Puts codes on the pasteboard the way password managers do: marked with the nspasteboard.org
/// identifiers, so clipboard managers and the system's clipboard history leave them out, and
/// removed again once the code has expired, unless something else has been copied since.
/// Only the change count is compared before removing: the pasteboard's contents are never read
/// for that, so it causes no paste permission prompt.
public final class CodeClipboard {
    /// "Treat as confidential": clipboard managers don't record or show it.
    public static let concealedType = NSPasteboard.PasteboardType("org.nspasteboard.ConcealedType")
    /// "On the pasteboard only momentarily": the previous content comes back within seconds.
    public static let transientType = NSPasteboard.PasteboardType("org.nspasteboard.TransientType")

    /// Runs `action` at `date`; calling the returned closure cancels it.
    public typealias Schedule = (_ date: Date, _ action: @escaping () -> Void) -> () -> Void

    private let pasteboard: NSPasteboard
    private let schedule: Schedule
    private var pending: (changeCount: Int, cancel: () -> Void)?

    public init(pasteboard: NSPasteboard = .general, schedule: @escaping Schedule = CodeClipboard.timer) {
        self.pasteboard = pasteboard
        self.schedule = schedule
    }

    /// Copies `code` for the user to paste and removes it at `date`.
    public func copy(_ code: String, until date: Date) {
        write(code, until: date, transient: false)
    }

    /// Puts `code` on the pasteboard to be pasted right away (the hotkeys type it with ⌘V).
    /// The returned closure puts the text that was there before back, unless something else was
    /// copied in the meantime. With no text to put back, the code stays until `date`.
    public func copyForPasting(_ code: String, until date: Date) -> () -> Void {
        let previous = pasteboard.string(forType: .string)
        let previousWasConcealed = pasteboard.types?.contains(Self.concealedType) ?? false
        let changeCount = write(code, until: date, transient: previous != nil)
        return { [weak self] in
            guard let self, let previous, self.pasteboard.changeCount == changeCount else { return }
            self.cancelRemoval()
            self.pasteboard.clearContents()
            self.pasteboard.writeObjects([Self.item(previous, concealed: previousWasConcealed, transient: false)])
        }
    }

    /// Removes the code now if it is still on the pasteboard. Called when the app quits.
    public func removeCodeIfUnchanged() {
        guard let pending else { return }
        cancelRemoval()
        if pasteboard.changeCount == pending.changeCount {
            pasteboard.clearContents()
        }
    }

    @discardableResult
    private func write(_ code: String, until date: Date, transient: Bool) -> Int {
        cancelRemoval()
        pasteboard.clearContents()
        pasteboard.writeObjects([Self.item(code, concealed: true, transient: transient)])
        let changeCount = pasteboard.changeCount
        pending = (changeCount, schedule(date) { [weak self] in self?.removeCodeIfUnchanged() })
        return changeCount
    }

    private func cancelRemoval() {
        pending?.cancel()
        pending = nil
    }

    private static func item(_ text: String, concealed: Bool, transient: Bool) -> NSPasteboardItem {
        let item = NSPasteboardItem()
        item.setString(text, forType: .string)
        // The markers carry no data; their presence is the message.
        if concealed { item.setData(Data(), forType: concealedType) }
        if transient { item.setData(Data(), forType: transientType) }
        return item
    }

    /// A timer on the main run loop. It also fires while a menu is open, and right after
    /// waking up if the Mac slept past `date`.
    public static func timer(at date: Date, action: @escaping () -> Void) -> () -> Void {
        let timer = Timer(fire: date, interval: 0, repeats: false) { _ in action() }
        timer.tolerance = 1
        RunLoop.main.add(timer, forMode: .common)
        return { timer.invalidate() }
    }
}

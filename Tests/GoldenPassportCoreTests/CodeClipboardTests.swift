import AppKit
import Foundation
import Testing
@testable import GoldenPassportCore

/// Stands in for the timer: records when the removal would run and runs it on demand.
final class FakeRemovalSchedule {
    private(set) var date: Date?
    private(set) var cancellations = 0
    private var action: (() -> Void)?

    func schedule(_ date: Date, _ action: @escaping () -> Void) -> () -> Void {
        self.date = date
        self.action = action
        return { [weak self] in self?.cancellations += 1 }
    }

    func fire() {
        action?()
    }
}

/// Every test uses a pasteboard of its own, never the user's clipboard.
final class CodeClipboardTests {
    let pasteboard = NSPasteboard(name: NSPasteboard.Name("GoldenPassportTests.\(UUID().uuidString)"))
    let schedule = FakeRemovalSchedule()
    let expiry = Date(timeIntervalSince1970: 120)
    lazy var clipboard = CodeClipboard(pasteboard: pasteboard, schedule: schedule.schedule)

    deinit {
        pasteboard.releaseGlobally()
    }

    private var types: [NSPasteboard.PasteboardType] {
        pasteboard.types ?? []
    }

    private func copyText(_ text: String, concealed: Bool = false) {
        pasteboard.clearContents()
        let item = NSPasteboardItem()
        item.setString(text, forType: .string)
        if concealed { item.setData(Data(), forType: CodeClipboard.concealedType) }
        pasteboard.writeObjects([item])
    }

    @Test func marksTheCodeAsConcealed() {
        clipboard.copy("123456", until: expiry)
        #expect(pasteboard.string(forType: .string) == "123456")
        #expect(types.contains(CodeClipboard.concealedType))
        #expect(!types.contains(CodeClipboard.transientType))
    }

    @Test func removesTheCodeWhenItExpires() {
        clipboard.copy("123456", until: expiry)
        #expect(schedule.date == expiry)
        schedule.fire()
        #expect(pasteboard.string(forType: .string) == nil)
        #expect(types.isEmpty)
    }

    @Test func leavesWhatWasCopiedLaterAlone() {
        clipboard.copy("123456", until: expiry)
        copyText("copied later")
        schedule.fire()
        #expect(pasteboard.string(forType: .string) == "copied later")
    }

    @Test func aNewCodeReplacesThePendingRemoval() {
        clipboard.copy("123456", until: expiry)
        clipboard.copy("654321", until: expiry.addingTimeInterval(30))
        #expect(schedule.cancellations == 1)
        #expect(schedule.date == expiry.addingTimeInterval(30))
        schedule.fire()
        #expect(pasteboard.string(forType: .string) == nil)
    }

    @Test func removesTheCodeRightAwayOnQuit() {
        clipboard.copy("123456", until: expiry)
        clipboard.removeCodeIfUnchanged()
        #expect(pasteboard.string(forType: .string) == nil)
        #expect(schedule.cancellations == 1)
        copyText("copied after quitting")
        schedule.fire()
        #expect(pasteboard.string(forType: .string) == "copied after quitting")
    }

    @Test func pastingPutsThePreviousTextBack() {
        copyText("draft")
        let restore = clipboard.copyForPasting("123456", until: expiry)
        #expect(pasteboard.string(forType: .string) == "123456")
        #expect(types.contains(CodeClipboard.concealedType))
        #expect(types.contains(CodeClipboard.transientType))
        restore()
        #expect(pasteboard.string(forType: .string) == "draft")
        #expect(!types.contains(CodeClipboard.concealedType))
        #expect(schedule.cancellations == 1)
    }

    @Test func pastingKeepsConcealedTextConcealed() {
        copyText("a password", concealed: true)
        let restore = clipboard.copyForPasting("123456", until: expiry)
        restore()
        #expect(pasteboard.string(forType: .string) == "a password")
        #expect(types.contains(CodeClipboard.concealedType))
    }

    @Test func pastingDoesNotOverwriteALaterCopy() {
        copyText("draft")
        let restore = clipboard.copyForPasting("123456", until: expiry)
        copyText("copied later")
        restore()
        #expect(pasteboard.string(forType: .string) == "copied later")
    }

    @Test func pastingWithNoTextToRestoreLeavesTheCodeUntilItExpires() {
        pasteboard.clearContents()
        let restore = clipboard.copyForPasting("123456", until: expiry)
        #expect(!types.contains(CodeClipboard.transientType))
        restore()
        #expect(pasteboard.string(forType: .string) == "123456")
        schedule.fire()
        #expect(pasteboard.string(forType: .string) == nil)
    }
}

struct CodeValidityTests {
    @Test func accountCodesKnowWhenTheyStopBeingAccepted() {
        let account = Account(name: "a", url: "otpauth://totp/a?secret=MZXW6YTBOI&period=30")
        let code = AccountStore.code(for: account, at: Date(timeIntervalSince1970: 61))
        #expect(code.validUntil == Date(timeIntervalSince1970: 120))
    }

    @Test func invalidAccountsHaveNoCodeToExpire() {
        let account = Account(name: "a", url: "otpauth://totp/a?secret=1")
        #expect(AccountStore.code(for: account, at: Date()).validUntil == nil)
    }
}

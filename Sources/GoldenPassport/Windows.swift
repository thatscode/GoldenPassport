import AppKit
import CoreImage
import GoldenPassportCore
import SwiftUI
import UniformTypeIdentifiers

/// Hosts a SwiftUI view in a reusable floating window for this accessory app.
class HostedWindowController: NSObject, NSWindowDelegate {
    private var window: NSWindow?

    func makeContent(close: @escaping () -> Void) -> AnyView {
        fatalError("subclass must override")
    }

    var title: String { "" }
    var resizable: Bool { false }

    func present() {
        if window == nil {
            let window = NSWindow(contentViewController: NSHostingController(rootView: makeContent { [weak self] in
                self?.window?.close()
            }))
            window.title = title
            window.styleMask = resizable ? [.titled, .closable, .resizable] : [.titled, .closable]
            window.isReleasedWhenClosed = false
            window.delegate = self
            window.center()
            self.window = window
        }
        activateApp()
        window?.makeKeyAndOrderFront(nil)
    }

    func windowWillClose(_ notification: Notification) {
        // Drop the window so the next presentation starts with fresh state.
        DispatchQueue.main.async { self.window = nil }
    }
}

// MARK: - Add account

final class AddAccountWindowController: HostedWindowController {
    private let store: AccountStore
    private let onAdded: () -> Void

    init(store: AccountStore, onAdded: @escaping () -> Void) {
        self.store = store
        self.onAdded = onAdded
    }

    override var title: String { "添加认证" }

    override func makeContent(close: @escaping () -> Void) -> AnyView {
        AnyView(AddAccountView(store: store, onAdded: { [onAdded] in
            onAdded()
            close()
        }, onCancel: close))
    }
}

struct AddAccountView: View {
    let store: AccountStore
    let onAdded: () -> Void
    let onCancel: () -> Void

    @State private var url = ""
    @State private var name = ""
    @State private var nameEdited = false
    @State private var error: String?

    var body: some View {
        VStack(alignment: .leading, spacing: 12) {
            Form {
                TextField("OTPAuth URL：", text: $url, prompt: Text("otpauth://totp/user@host?secret=...&issuer=..."))
                    .onChange(of: url) { newValue in
                        error = nil
                        if !nameEdited {
                            name = (try? OTPAuthURL(string: newValue))?.suggestedName ?? ""
                        }
                    }
                TextField("标识：", text: Binding(get: { name }, set: {
                    name = $0
                    nameEdited = true
                    error = nil
                }), prompt: Text("用于在菜单中识别此账号"))
            }
            if let error {
                Text(error).foregroundStyle(.red).font(.callout)
            }
            HStack {
                Button("从二维码图片识别...", action: pickQRCode)
                Spacer()
                Button("取消", action: onCancel).keyboardShortcut(.cancelAction)
                Button("添加", action: add).keyboardShortcut(.defaultAction)
            }
        }
        .padding(20)
        .frame(width: 560)
    }

    private func add() {
        do {
            try store.add(name: name, url: url)
            onAdded()
        } catch {
            self.error = error.localizedDescription
        }
    }

    private func pickQRCode() {
        let panel = NSOpenPanel()
        panel.allowedContentTypes = [.image]
        panel.allowsMultipleSelection = false
        guard panel.runModal() == .OK, let fileURL = panel.url else { return }
        guard let found = QRCodeReader.otpAuthURLs(in: fileURL).first else {
            error = "图片中没有找到 otpauth:// 二维码。"
            return
        }
        url = found
    }
}

enum QRCodeReader {
    static func otpAuthURLs(in fileURL: URL) -> [String] {
        guard let image = CIImage(contentsOf: fileURL),
              let detector = CIDetector(ofType: CIDetectorTypeQRCode, context: nil,
                                        options: [CIDetectorAccuracy: CIDetectorAccuracyHigh]) else { return [] }
        return detector.features(in: image)
            .compactMap { ($0 as? CIQRCodeFeature)?.messageString }
            .filter { $0.lowercased().hasPrefix("otpauth://") }
    }
}

// MARK: - HTTP port

final class PortConfigWindowController: HostedWindowController {
    private let currentPort: () -> Int
    private let onSave: (Int) -> Void

    init(currentPort: @escaping () -> Int, onSave: @escaping (Int) -> Void) {
        self.currentPort = currentPort
        self.onSave = onSave
    }

    override var title: String { "HTTP 服务端口" }

    override func makeContent(close: @escaping () -> Void) -> AnyView {
        AnyView(PortConfigView(port: String(currentPort()), onSave: { [onSave] port in
            onSave(port)
            close()
        }, onCancel: close))
    }
}

struct PortConfigView: View {
    @State var port: String
    let onSave: (Int) -> Void
    let onCancel: () -> Void
    @State private var error: String?

    var body: some View {
        VStack(alignment: .leading, spacing: 12) {
            TextField("端口：", text: $port)
            if let error {
                Text(error).foregroundStyle(.red).font(.callout)
            }
            HStack {
                Spacer()
                Button("取消", action: onCancel).keyboardShortcut(.cancelAction)
                Button("确定") {
                    guard let value = Int(port.trimmingCharacters(in: .whitespaces)), (1...65535).contains(value) else {
                        error = "端口号必须是 1–65535 之间的整数。"
                        return
                    }
                    onSave(value)
                }.keyboardShortcut(.defaultAction)
            }
        }
        .padding(20)
        .frame(width: 320)
    }
}

import Foundation

/// Everything that can stop an update installed from the app (docs/design/in-app-update.md).
/// Until the old bundle is moved away, any of these leaves the installed app as it was.
public enum UpdateError: Error, Equatable, LocalizedError {
    case download(String)
    case sizeMismatch(expected: Int, actual: Int)
    case digestMismatch
    case appNotFound
    /// The bundle doesn't match this copy; the associated value names the Info.plist field.
    case wrongPackage(String)
    case needsNewerSystem(String)
    case missingArchitecture(String)
    case notNewer
    case signature(String)
    case dataCheck(String)
    case dataCheckTimedOut
    case windowsOpen
    case fileOperation(String)
    case launchFailed(String)

    /// Failures a browser download might get past (a flaky connection, a proxy, a captive portal).
    public var isNetworkProblem: Bool {
        switch self {
        case .download, .sizeMismatch, .digestMismatch: return true
        default: return false
        }
    }

    public var errorDescription: String? {
        switch self {
        case .download(let detail):
            return String(localized: "下载失败：\(detail)")
        case .sizeMismatch(let expected, let actual):
            return String(localized: "下载的文件大小不对（应为 \(expected) 字节，实际 \(actual) 字节），可能被网络拦截了，或者没有下载完整。")
        case .digestMismatch:
            return String(localized: "下载的文件校验值不对，可能已损坏，或者被网络改动过。")
        case .appNotFound:
            return String(localized: "安装包里没有找到 GoldenPassport.app。")
        case .wrongPackage(let field):
            return String(localized: "安装包和当前版本不匹配（\(field)）。")
        case .needsNewerSystem(let version):
            return String(localized: "这个版本需要 macOS \(version) 或更高版本。")
        case .missingArchitecture(let architecture):
            return String(localized: "安装包不支持这台 Mac 的芯片（\(architecture)）。")
        case .notNewer:
            return String(localized: "安装包不比当前版本新。")
        case .signature(let detail):
            return String(localized: "安装包没有通过签名校验：\(detail)")
        case .dataCheck(let detail):
            return String(localized: "新版本读取数据时没有通过检查：\(detail)")
        case .dataCheckTimedOut:
            return String(localized: "新版本读取数据超时。如果出现了钥匙串授权框，请选择「始终允许」后再试一次。")
        case .windowsOpen:
            return String(localized: "请先关闭 GoldenPassport 打开的窗口，再安装更新。")
        case .fileOperation(let detail):
            return String(localized: "文件操作失败：\(detail)")
        case .launchFailed(let detail):
            return String(localized: "无法打开新版本：\(detail)")
        }
    }
}

# 更新日志

[English](CHANGELOG.md) | 简体中文

本 fork 每个版本的主要变化。0.1.0 到 0.1.7 由原项目发布，见[原项目的 Releases](https://github.com/stanzhai/GoldenPassport/releases)。

## 0.2.0（尚未发布）

针对新版 macOS 从头重写，0.1.x 的用户可以直接覆盖升级：还是同一个 App、同一个 Bundle ID，已有的账号会自动迁移。以下对比的是原项目的最后一个版本 0.1.7。升级时请运行发布包里的 `install.sh`，见[安装](README.zh-CN.md#安装)。

### 从头重写

- 改用 Swift Package 构建，不再使用 Xcode 工程和 CocoaPods。原来的 Objective-C 验证码代码、内置的 google-toolbox-for-mac 源码和 Swifter HTTP 服务器都已移除。
- TOTP 基于 CryptoKit 实现，支持 otpauth URL 中的 `algorithm`、`digits`、`period` 参数（SHA1 / SHA256 / SHA512，6–8 位），并通过了 RFC 6238 的标准测试向量。
- 账号改为有序列表存储（`accounts.json`）。原来用的是字典，每次启动顺序都可能变。
- 单元测试覆盖 TOTP、URL 解析、存储、数据迁移、HTTP 接口、检查更新和中英文翻译。

### 新功能

- **英文界面**：0.1.x 的菜单只有中文。新版默认跟随系统语言，也可以在菜单「语言 / Language」里固定为简体中文或英文。
- **管理窗口**（⌘M）：拖动或用上下箭头调整顺序，双击重命名，右键修改 URL 或删除（[#12](https://github.com/stanzhai/GoldenPassport/issues/12)、[#17](https://github.com/stanzhai/GoldenPassport/issues/17)、[#29](https://github.com/stanzhai/GoldenPassport/issues/29)）。
- **全局快捷键可配置**：⌃⌥⌘0–9（新的默认值）、⇧⌘0–9（0.1.x 的方式）、⌃⌥0–9，或者关闭。改为系统级注册，按键不会再同时传给当前 App（[#4](https://github.com/stanzhai/GoldenPassport/issues/4)、[#11](https://github.com/stanzhai/GoldenPassport/issues/11)、[#18](https://github.com/stanzhai/GoldenPassport/issues/18)）。
- **导出 otpauth URL 列表**（`.txt`），可以导入其他验证器 App。导入同时支持这种格式和 `.secrets` 备份文件（[#10](https://github.com/stanzhai/GoldenPassport/issues/10)、[#30](https://github.com/stanzhai/GoldenPassport/issues/30)）。
- **开机自动启动**开关。
- **检查更新**：「检查更新…」向 GitHub 查询有没有新版本，「每天自动检查更新」每天查询一次（默认关闭）。如果新版本会改变数据格式，或者需要先升级到某个中间版本，提示里会在安装前写明。
- 添加账号时，会根据 otpauth URL 里的标签自动填写标识；粘贴的 URL 会自动去掉首尾空白（[#26](https://github.com/stanzhai/GoldenPassport/issues/26)）。
- **带保护的安装脚本**：`install.sh` 会先备份 App 和数据，迁移后逐条核对账号，核对不通过就自动恢复到安装前的 App 和数据。`rollback.sh` 恢复安装前的 App，`cleanup.sh` 在不再需要回退时删除未加密的残留文件。脚本的提示语言和 App 的界面语言一致。
- **回退之后还能再升级回来**：回退期间在 0.1.x 里新增或修改的账号，再次升级时会列出来，由你选择要导入哪些。

### 问题修复

- 添加账号或识别二维码图片时闪退（[#1](https://github.com/stanzhai/GoldenPassport/issues/1)、[#16](https://github.com/stanzhai/GoldenPassport/issues/16)、[#21](https://github.com/stanzhai/GoldenPassport/issues/21)、[#22](https://github.com/stanzhai/GoldenPassport/issues/22)、[#25](https://github.com/stanzhai/GoldenPassport/issues/25)、[#28](https://github.com/stanzhai/GoldenPassport/issues/28)）。
- 输入框里可以正常使用 ⌘V / ⌘C / ⌘A 了（[#9](https://github.com/stanzhai/GoldenPassport/issues/9)）。
- HTTP 页面声明了 UTF-8 编码，中文账号名不再乱码（[#26](https://github.com/stanzhai/GoldenPassport/issues/26)）。
- 重名时会提示，不再静默覆盖已有账号。
- 删除账号前会先确认。
- Bartender 等菜单栏管理工具可以识别 GoldenPassport 的图标了。

### 安全与隐私

- 全新安装时 HTTP 接口默认关闭。它没有访问密码，开启期间，这台 Mac 上以你的身份运行的任何程序都能读取全部验证码。从 0.1.x 升级的用户保持原来的设置。
- GoldenPassport 只在检查更新时联网，而且只在你要求时才检查：点「检查更新…」，或者打开「每天自动检查更新」（默认关闭）。检查时会向 GitHub 的接口查询最新版本；如果比当前版本新，还会下载这个版本附带的 `compat.json` 小文件。请求只以 `GoldenPassport/<版本号>` 标识自己，不带 Cookie，也不带任何账号信息。不会自动下载或安装新版本。
- HTTP 接口只监听 127.0.0.1，并拒绝 `Host` 头不是本机的请求（[#6](https://github.com/stanzhai/GoldenPassport/issues/6)），网页无法通过 DNS 重绑定读取你的验证码。
- 数据文件仅本人可读：数据目录权限为 `0700`，文件为 `0600`。0.1.x 的文件本机所有用户都能读，0.2.0 会收紧已有文件的权限，但不改动文件内容。
- 两种导出格式在导出前都会提示：文件里是未加密的全部密钥。
- 密钥副本可能存在的所有位置，见[数据与安全](README.zh-CN.md#数据与安全)。

### 需要注意的行为变化

| | 0.1.x | 0.2.0 |
|---|---|---|
| 最低系统版本 | 10.10 | **13** |
| 默认快捷键 | ⇧⌘0–9（3/4/5 和系统截图冲突） | **⌃⌥⌘0–9**；仍可在菜单里切换回 ⇧⌘ |
| 自动填入验证码 | 需要辅助功能权限 | 仍然需要，而且升级后要**重新授权** |
| 启动时开启 HTTP 接口 | 默认开启，可以手动关闭 | **全新安装默认关闭**；升级的用户保持 0.1.x 里的设置 |
| 数据文件 | `gp.secrets` | `accounts.json`（首次启动时自动迁移；`gp.secrets` 会保留，但之后不再更新） |
| 账号顺序 | 每次启动都可能变化 | 迁移后按名称排序，之后按你调整的顺序 |

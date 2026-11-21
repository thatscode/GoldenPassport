# 从其他验证器导入：Google Authenticator 迁移二维码

状态：设计已确认（2026-11-22）。第一期只做图片和文本两种方式，不做摄像头扫描。

## 1. 问题

GoldenPassport 现在只能一个个添加账号：粘贴 `otpauth://` 链接，或者选一张二维码图片。从手机上的验证器迁过来的人，要到每个网站重新绑定一遍，或者自己想办法拿到每个账号的密钥。

各家验证器能不能导出（2026-11 调研）：

| 来源 | 能否导出 | 处理 |
|---|---|---|
| Google Authenticator | 能。「转移账号 → 导出账号」生成二维码，内容是 `otpauth-migration://offline?data=…`，每张最多约 10 个账号，多了分成几张 | 本设计 |
| Microsoft Authenticator | 不能。不支持把密钥导出给别的 App，云备份只能恢复到同平台的 Microsoft Authenticator | 做不了，只能到各网站重新绑定 |
| Authy | 不能导出 | 做不了 |
| Ente Auth、Aegis 等 | 能导出一行一个 `otpauth://` 链接的文本 | 现有的「导入…」已经支持 |
| 2FAS、Aegis 的 JSON、Bitwarden Authenticator | 各自的 JSON 格式 | 以后有人需要再做 |

## 2. 目标

- 新的菜单项「从其他验证器导入…」打开一个导入窗口，能读：
  - 二维码图片：选文件（可多选）、拖进窗口、点「粘贴」或按 ⌘V 粘贴剪贴板里的图片；
  - 文本：粘贴 `otpauth-migration://` 或 `otpauth://` 链接，一行一个。
- Google Authenticator 的迁移码分成几张时，可以一张张读进来，窗口显示读到了第几张、还差哪几张，最后一起导入。
- 导入前先预览：每个账号能勾选、改名，并标出已存在、重名、不支持的情况。
- 导入的账号转成标准的 `otpauth://totp/…` 链接保存，和手动添加的账号完全一样。

不做的事：

- 摄像头扫描（第二期再看）。安卓版 Google Authenticator 禁止截图，第一期的办法是用另一台设备拍下二维码，再用 AirDrop 传过来。
- 导出成 Google Authenticator 的迁移码（把账号迁到手机），以及读取其他 App 的 JSON 备份。
- HOTP（按次数计数的验证码）：GoldenPassport 只支持 TOTP，这类账号在预览里标为不支持。
- 不改「添加…」窗口的用法，只在它读到迁移码时转到导入窗口（见第 5 节）。

绝不能出现的情况：

- 导入一个算错了的账号（密钥、算法、位数和原来不一致）。
- 不经确认就覆盖或修改已有的账号。
- 把密钥写进日志，或者在磁盘上留下临时文件。

## 3. 迁移码的格式

`otpauth-migration://offline?data=<base64>`，`data` 是 protobuf 编码的 `MigrationPayload`（Google 没有公开文档，以下是社区实现一致的结构）：

```proto
message MigrationPayload {
  enum Algorithm { ALGORITHM_UNSPECIFIED = 0; SHA1 = 1; SHA256 = 2; SHA512 = 3; MD5 = 4; }
  enum DigitCount { DIGIT_COUNT_UNSPECIFIED = 0; SIX = 1; EIGHT = 2; }
  enum OtpType { OTP_TYPE_UNSPECIFIED = 0; HOTP = 1; TOTP = 2; }
  message OtpParameters {
    bytes secret = 1; string name = 2; string issuer = 3;
    Algorithm algorithm = 4; DigitCount digits = 5; OtpType type = 6; int64 counter = 7;
  }
  repeated OtpParameters otp_parameters = 1;
  int32 version = 2; int32 batch_size = 3; int32 batch_index = 4; int32 batch_id = 5;
}
```

解析规则：

- `data` 可能是标准 base64 或 URL 安全的 base64，可能缺 `=` 填充，都要接受。
- 自己写一个只认 protobuf 线格式的小解析器（varint、定长 64 位、长度前缀、定长 32 位），不引入第三方库；未知字段跳过；长度越界、varint 过长、已废弃的 group 类型一律视为损坏，整张二维码报错，不导入其中任何账号。
- 算法未指定按 SHA1；位数未指定按 6，`EIGHT` 为 8；类型未指定按 TOTP（有的工具生成迁移码时省略这个字段），`HOTP` 标为不支持；数据里没有周期，按 30 秒。
- 密钥为空的条目标为无效。

转成 `otpauth` 链接：

- 标签：`issuer` 非空且 `name` 不是以 `issuer:` 开头时，用 `issuer:name`，否则用 `name`。
- `otpauth://totp/<标签，百分号编码>?secret=<Base32，无填充>&issuer=<issuer>&algorithm=<SHA1|SHA256|SHA512|MD5>&digits=<6|8>&period=30`（`issuer` 为空时省略）。
- 转完再用现有的 `OTPAuthURL` 解析一遍，结果必须和迁移码里的参数一致；建议名称沿用 `OTPAuthURL.suggestedName`。

## 4. 预览和导入的规则

每个读到的账号一行：勾选框、名称（可以改）、发行方和参数摘要、状态。

| 状态 | 条件 | 默认 |
|---|---|---|
| 新账号 | 密钥和名称都没有和已有账号重复 | 勾选 |
| 已存在 | 已有账号里有相同的密钥（同一个密钥、算法、位数、周期） | 不勾选 |
| 改名 | 名称和已有账号或这次读到的其他账号重名，自动改成「名称 (2)」「名称 (3)」… | 勾选 |
| 不支持 | HOTP，或密钥无效 | 不能勾选，显示原因 |

- 同一个账号被重复读到（同一张二维码读了两次，或者同一个链接粘贴了两次）只显示一行。
- 改名后仍然重名、或名称为空时，「导入」按钮不可用，并指出是哪一行。
- 迁移码分批时，按 `batch_id` 记录读到了哪些 `batch_index`。没读全也可以导入，但窗口里写明「共 N 张，还差第 x 张」。
- 导入用现有的 `AccountStore.importAccounts`，一次写入；结束后显示导入了几个账号。

## 5. 界面和入口

- 菜单「认证管理」里，在「导入…」下面加「从其他验证器导入…」。
- 导入窗口（沿用 `HostedWindowController`）：
  - 上方说明：支持 Google Authenticator 的「转移账号」二维码和 `otpauth://` 链接；Microsoft Authenticator 和 Authy 无法导出；安卓上不能截图，可以用另一台设备拍照。
  - 拖放区域，以及「选择图片…」「粘贴」（⌘V）两个按钮。
  - 一行提示读取结果，比如「图片里没有找到二维码」「这张二维码不是验证器账号」。
  - 预览列表，底部「导入 N 个账号」和「取消」。
- 「添加…」窗口的「从二维码图片识别…」读到迁移码时，关掉添加窗口、打开导入窗口并带上读到的内容。
- 读二维码改用 Vision（`VNDetectBarcodesRequest`），比现在的 `CIDetector` 更能识别拍屏的照片和密集的二维码；添加窗口也改用它。一张图里有几个二维码就都读出来。
- 导入窗口算作「打开的窗口」，开着时 App 内更新会提示先关闭（和其他窗口一样）。

## 6. 安全

- 密钥只在内存里处理，不写日志，不写临时文件。
- 从剪贴板粘贴的内容（图片或链接都含有密钥）：导入完成后，如果剪贴板从那以后没变过，就清空它（只比较变更计数，和剪贴板保护的做法一样）。
- 从文件读的图片：导入完成的提示里提醒「导入用的图片里含有密钥，用完请删除」。

## 7. 代码位置

- Core：
  - `Base32.encode`（RFC 4648，大写，无填充）；
  - `ProtobufReader`（线格式读取）；
  - `GoogleAuthenticatorMigration`（解析迁移链接，得到账号和批次信息）；
  - `AuthenticatorImport`（把二维码内容或文本变成候选账号，判断已存在、改名、不支持，跟踪批次）；
  - `QRCodeScanner`（Vision，读 `CGImage` 或图片文件里的所有二维码）。
- App：导入窗口、菜单项、添加窗口的转交、剪贴板清理、中英文文字。
- 文档：README（菜单表、导入说明、各验证器的情况）、CHANGELOG。

## 8. 测试

- `Base32.encode` 用 RFC 4648 的向量，并和 `decode` 往返。
- protobuf：手工构造的字节覆盖每种线格式类型、未知字段、截断、长度越界、过长的 varint、group 类型。
- 迁移码：用测试里自己编码的 payload（字段和社区 `.proto` 一致）覆盖默认值、MD5、8 位、HOTP、空密钥、分批信息、URL 安全 base64 和缺填充；生成的 `otpauth` 链接再解析后，算出的验证码和直接用原始参数算出的一致。
- 候选账号：新账号、已存在（同密钥）、和已有账号重名、批内重名、重复读到同一张二维码、不支持的条目、批次进度。
- 二维码：用 Core Image 生成迁移码和 `otpauth` 链接的二维码图片，`QRCodeScanner` 能读回原文；一张图里两个二维码都能读出；没有二维码的图片返回空。

## 9. 留给实现时决定的

- 窗口的具体布局和尺寸。
- 拖放支持哪些具体的类型（至少要支持 Finder 里的图片文件和截图缩略图）。

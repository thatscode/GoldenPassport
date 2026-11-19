# D3 设计：把密钥存进钥匙串

对应 [兼容策略](../compatibility.md) 第 3.2、3.3 节。状态：第 7 节的决策已确认（2026-11-17，都按推荐），正在实施。

钥匙串部分等 Developer ID 账号到位后发布（原因见第 4 节）。第 8 节的第 1、2 步（存储抽象、钥匙串后端）不依赖账号，已经先做了。

## 1. 问题

现在所有密钥都以明文写在数据目录的 `accounts.json` 里（数据格式 1），只靠文件权限（目录 `0700`、文件 `0600`）保护：

- 以你的身份运行的任何程序都能直接读取，不会有任何提示；
- 数据目录被拷走、被同步工具或云备份带走、出现在未加密的 Time Machine 备份里，密钥就跟着出去了；
- `cleanup.sh` 能删掉旧版文件和安装备份，但 `accounts.json` 本身一直是明文，删不掉也不该删。

## 2. 目标

- 账号数据（名称、顺序、otpauth URL）保存在登录钥匙串里，数据目录里不再写入明文密钥。
- 平时使用不弹任何授权框：菜单、快捷键、HTTP 接口、导出导入照常工作。
- 迁移逐条核对，`install.sh` 照常在核对失败时自动恢复。
- 回退仍然安全：按 3.3，旧版本看到的是升级那一刻的旧文件。
- 钥匙串读不出来时绝不当作空列表：停下来说明情况，不改动任何数据。

不做的事：

- 不防以 GoldenPassport 自己的身份运行的代码，也不防你在授权框里点了「允许」的程序。
- HTTP 接口仍然没有密码，导出文件仍然是明文，这两处的警告保持不变。
- 不通过 iCloud 钥匙串同步，只存在本机。需要的话以后单独做成选项。
- 不在每次查看验证码时要求 Touch ID。需要的话以后单独做成选项。

## 3. 钥匙串能防什么、防不了什么

| 情况 | 现在（`accounts.json`） | 存进钥匙串后 |
|---|---|---|
| 别的程序读取密钥 | 直接读，没有提示 | 系统弹授权框，你拒绝就读不到 |
| 数据目录被拷走、同步，或出现在未加密的 Time Machine 备份里 | 带走全部密钥 | 带不走：钥匙串条目不在数据目录里 |
| HTTP 接口开启时，本机程序读取验证码 | 能读 | 仍然能读 |
| 导出的 `.secrets` / `.txt` | 明文 | 仍然是明文 |
| 升级后、清理前留下的旧文件和安装备份 | 明文 | 仍然是明文，由 `cleanup.sh` 删除 |

## 4. 为什么要等 Developer ID

之前的调研结论（2026-10）：钥匙串按代码签名身份决定哪个 App 可以不经询问读取条目。ad-hoc 签名的身份就是这一次构建本身，每次构建都不一样，所以每次更新后读钥匙串都会弹授权框。Developer ID 签名的身份是「Bundle ID + Team ID」，同一个 Team ID 签名的新版本可以直接读。

因此钥匙串后端要和第一个 Developer ID 签名的版本一起发；在那之前的内测包（ad-hoc 签名）继续用 `accounts.json`。

这也意味着 **Team ID 一旦变化**（例如以后从借用的账号换成自己的账号），新版本对已有条目来说是陌生程序，会弹一次授权框，可能还要求输入登录密码。把所有账号放在一个条目里（5.1），换账号时只弹一次。具体的弹框方式在实现时用探针确认。

## 5. 方案

### 5.1 钥匙串里存什么

一个通用密码条目（generic password）保存整个账号列表：

- service：取自 Info.plist 的新键 `GPKeychainService`。正式版用 `site.stanzhai.GoldenPassport`，开发版用 `site.stanzhai.GoldenPassport.dev`；探针 App 设成别的值，测试时碰不到真实数据。显示名称（label）用「GoldenPassport」，方便在「钥匙串访问」里找到。
- account：固定为 `accounts`。
- 内容：`{"formatVersion": 2, "accounts": [{"id": …, "name": …, "url": …}]}`，与 3.2 第 1 条的格式一致。`url` 仍然原样保存 otpauth URL，导出保持无损。
- 只存本机，不同步到 iCloud。

数据目录里另写一个**不含密钥**的标记文件 `accounts-v2.json`：`{"formatVersion": 2, "storage": "keychain", "service": "…", "migratedFrom": "gp.secrets" | "accounts.json", "migratedAt": "…"}`。全新安装没有 `migratedFrom` 这个键（不写 `null`：脚本用 `plutil -extract … raw` 读取时，`null` 和没有这个键一样会失败，只保留一种写法）。`migratedAt` 是写入标记文件的时间。它的作用：

- 表示已经迁移到格式 2。按 3.2 第 3 条，新文件存在就不再迁移；
- 脚本不用读钥匙串就能知道数据在哪里（`rollback.sh`、`cleanup.sh`）；
- 旧版本根本不读这个文件。

### 5.2 启动时的顺序

1. **有 `accounts-v2.json`**：从钥匙串读取。读不出来（条目不存在、授权被拒绝、钥匙串锁着、内容读不懂、`formatVersion` 比程序支持的高）时停下并提示，不改动任何数据（5.5）。
2. **没有标记文件，有 `accounts.json`**（内测版用户）：从格式 1 迁移。
3. **没有标记文件和 `accounts.json`，有 `gp.secrets`**（0.1.x 用户）：直接从格式 0 迁移，照常记录 I6 基线。
4. **什么都没有**：全新安装，第一次保存时创建钥匙串条目和标记文件。如果钥匙串里已经有这个条目（例如删掉数据目录后重新安装），直接沿用它，并写入标记文件；条目读不懂时停下，不覆盖它。

迁移的写入顺序：先写钥匙串条目，读回来逐条核对，再写标记文件。中途失败时没有标记文件，下次启动会重新迁移，旧文件始终没被改动。

迁移时如果钥匙串里已经有这个条目（例如用 `rollback.sh --restore-data` 恢复数据目录后再升级），先把它另存为 `accounts.replaced-<时间>` 再写入，和数据文件读不懂时改名保留是同一个原则。

### 5.3 旧文件怎么处理

按 3.2 第 2 条，迁移后 `accounts.json` 和 `gp.secrets` 都**原样保留、不再写入**，回退时旧版本还能用。它们都是明文，所以：

- `cleanup.sh` 的删除范围加上 `accounts.json`，删除前先用新版确认钥匙串里的数据读取正常；
- README「数据与安全」和安装说明的含密钥文件表格加上 `accounts.json`；
- `install.sh` 结束时的警告框在从内测版升级时提到 `accounts.json`。

### 5.4 `MigrationCheck` 和脚本

- **`MigrationCheck`**（`--migrate-data`）：迁移来源可能是 `gp.secrets` 或 `accounts.json`，报告里加 `storage=`（`keychain` 或 `file`）和 `source=`；`accounts.json` 里有、钥匙串里没有的账号（按 URL 比较）每个输出一行 `file_only=`，供 `cleanup.sh` 使用。核对规则不变：每个名称和 URL 都要一致。它要读钥匙串，用的是同一个 Developer ID 签名的程序，不会弹框。
- **`install.sh`**：流程不变。安装备份里**没有**钥匙串条目，它不在数据目录里。核对失败时恢复旧 App 和数据目录，迁移时写入的条目留在钥匙串里，下次迁移时按 5.2 另存。
- **`rollback.sh`**：回退到格式 1 或 0 的版本时提醒，旧版本看到的是升级那一刻的数据；在新版里改过的账号存在钥匙串里，旧版本看不到，需要的话回退前先导出（I5）。
- **`cleanup.sh`**：见 5.3。删除 `accounts.json` 前，列出其中有、钥匙串里没有的账号（按 URL 指纹比较），提醒清理后无法找回（决策 4）。

### 5.5 钥匙串读不出来时

和现在 `accounts.json` 读不懂时一样：弹窗说明没有改动任何数据，提供重试、查看帮助和退出。按原因分别说明：

- 授权框里点了「拒绝」：说明原因，可以重试；
- 钥匙串锁着：提示先解锁；
- 条目不存在（例如在「钥匙串访问」里被删了，或者只把数据目录拷到了新电脑）：数据目录里还有 `accounts.json` 或 `gp.secrets` 时，可以选择从它重新迁移，并明确告诉你那是升级前的数据，之后的改动不在里面（决策 5）；没有的话，可以选择从空列表开始，再导入导出文件，或者退出后从备份恢复钥匙串。
- 内容读不懂、来自更新的版本：只提供查看帮助和退出，重试没有意义。

README 的「GoldenPassport 无法读取数据时」一节相应补充。

### 5.6 代码结构

- 存储抽象 `AccountStorage`：读取、保存整个账号列表。`AccountStore` 只负责规则（重名、排序、URL 校验）和内存里的列表。
- 格式 1：`AccountsFile`，也就是现在的 `accounts.json` 读写。
- 格式 2：`KeychainAccountStorage`，使用 Security 框架的 `SecItem*` 函数。
- `AppEnvironment.prepareDataDirectory` 按 5.2 选择存储并迁移。
- **保存失败时，内存里的列表保持不变。** 现在是先改内存、再写文件，写失败时两边不一致：菜单里看得到，重启后就没了。钥匙串写入可能因为授权被拒绝而失败，这一点更重要。

## 6. 考虑过但不采用的做法

| 做法 | 不采用的原因 |
|---|---|
| 每个账号一个钥匙串条目 | 换 Team ID 或重新授权时每个条目弹一次框；还会出现部分条目写入成功、部分失败的中间状态 |
| 钥匙串只存密钥，名称和顺序留在数据目录 | 两处数据要保持一致，崩溃或授权被拒绝时会对不上；账号名称（用了哪些服务）仍然是明文 |
| 加密 `accounts.json`，加密密钥放钥匙串 | 同样是两处数据，还要自己写加密代码；访问控制和直接存钥匙串一样，没有额外好处 |
| 同时继续写 `accounts.json`，方便回退 | 明文副本一直存在，D3 就失去了意义 |
| 在 ad-hoc 签名的内测包里先上钥匙串 | 每次更新都会弹授权框（第 4 节） |
| 数据保护钥匙串（`kSecUseDataProtectionKeychain`） | 需要受限的签名权限（entitlement）和描述文件，用借来的账号配置更麻烦。账号到位后可以再评估 |

## 7. 决策（2026-11-17 确认，都按推荐）

| # | 问题 | 推荐 | 备选 |
|---|---|---|---|
| 1 | D3 跟哪个版本发 | **0.2.0**，按原计划 C1 → D3 → C2 → C3。格式 1 只在内测版里出现过，公开用户从 0.1.x 直接迁到格式 2，以后少维护一个格式。0.2.0 的 `compat.json` 里 `dataFormat` 是 2；按 3.2 第 6 条看的是公开版本，0.1.7 → 0.2.0 已经升了次版本号 | 0.2.0 先用格式 1 发布，D3 放到 0.3.0：账号到位后能早几天发布，但公开用户要迁移两次，`accounts.json` 的回退和改动发现都要按 3.3 完整做一遍 |
| 2 | 钥匙串条目怎么划分 | **一个条目存整个列表**（5.1） | 每个账号一个条目，或者只存密钥（第 6 节） |
| 3 | 迁移后的 `accounts.json` | **按 3.2 原样保留**，由 `cleanup.sh` 删除 | 迁移成功后马上删除：少一份明文，但回退到内测版时就没有数据了 |
| 4 | 回退到内测版后在里面改过的账号 | **只在 `cleanup.sh` 删除 `accounts.json` 前比对并警告**；`rollback.sh` 给出 I5 提醒 | 按 I6 做完整的「列出改动、选择导入」：格式 1 只有内测同事用过，投入和收益不成比例 |
| 5 | 钥匙串条目不存在，但还有旧文件 | **停下，由你选择是否从旧文件重新迁移**，并说明那是升级前的数据 | 自动重新迁移：省一步，但会悄悄丢掉升级后的改动 |

## 8. 实施步骤和工作量

不需要账号，现在可以做：

1. **存储抽象**（约半天）：`AccountStorage` 和 `AccountsFile`，保存失败时内存保持不变，测试用内存里的实现。用户看不到任何变化。**已完成**，见第 11 节。
2. **钥匙串后端和标记文件**，以及它们的单元测试（约 1.5 天）。代码还没有接到 App 里，用户看不到任何变化。**已完成**，见第 11 节。
3. **迁移 0 → 2、1 → 2**，`MigrationCheck` 报告来源并核对（约 1 天）。只有设置了 `GPKeychainService` 的构建才会迁移，ad-hoc 签名的构建默认不设。**已完成**，见第 11 节。

代码也可以先写，但要等 Developer ID 账号（C1 之后）才能验证和发布：

4. **读不出来时的提示和重新迁移**（约 0.5 天）。**已完成**，见第 11 节。
5. **三个脚本、README、安装说明、CHANGELOG 和兼容策略**（约 1 天）。**已完成**，见第 11 节。
6. 用 Developer ID 签名的探针测试首次授权、更新后不弹框、拒绝授权、条目被删，然后发 beta.4 给内测同事（约 1 天）。**已完成**，见第 11 节；不再单独发 beta.4，直接发布 0.2.0 正式版。

合计约 5.5 天，和之前估计的 6–7 天大体一致。

## 9. 测试

单元测试：

1. 从 `gp.secrets` 迁移到格式 2：逐条一致，`gp.secrets` 不变，I6 基线照常记录。
2. 从 `accounts.json` 迁移到格式 2：逐条一致，`accounts.json` 不变。
3. 已有标记文件时不再迁移，重新启动后数据不变。
4. 条目不存在、内容读不懂、`formatVersion` 更高、读取被拒绝：都拒绝启动，不写入任何东西。
5. 迁移时钥匙串里已有条目：先另存，再写入。
6. 保存失败（模拟授权被拒绝）：内存和存储都保持原样。
7. 迁移后，数据目录里新写入的文件（标记文件）中找不到任何密钥或 URL。
8. `--migrate-data` 的报告包含来源和核对结果。

钥匙串后端的测试使用测试专用的 service。读写真实登录钥匙串的测试默认跳过，用 `GP_KEYCHAIN_TESTS=1 make test` 在本机运行：GitHub 的 runner 不一定有可用的登录钥匙串，开发者的 Mac 也不该在没要求时被写入条目。其余逻辑用内存里的条目测试，CI 照常运行。

脚本测试沿用 I6 的做法，用 `GP_*` 环境变量指向临时目录：0.1.x 和内测版两条升级路径各走一遍「升级 → 回退 → 在旧版里改账号 → 再升级 → 清理」。

界面测试用 Developer ID 签名的探针 App，配独立的 Bundle ID、数据目录和 `GPKeychainService`。

## 10. 需要同步修改的文档

实施钥匙串时一起改：`docs/compatibility.md` 第 1 节的表（格式 2、钥匙串条目、标记文件）和第 7 节；两份 README 的「数据与安全」和「GoldenPassport 无法读取数据时」；`docs/install.md` 和 `docs/install.zh-CN.md` 的清理表；CHANGELOG；`compat.json` 的 `dataFormat`。

## 11. 实施记录

- 2026-11-12，第 8 节第 1 步：
  - `AccountStorage`（读取、保存整个列表）和格式 1 的 `AccountsFile`。`AccountStore(directory:)` 的行为不变。
  - 每次修改都先保存，成功后才更新内存。以前保存失败时，没存下来的改动仍会出现在菜单、快捷键和 HTTP 接口里，直到下次启动才消失。
  - 新增 3 个测试：通过任意存储读写（用内存实现）；7 种修改在保存被拒绝时都保持原样；同一批导入里重名的只加第一个。最后这个测试是因为导入改成在副本上去重而补的，先用故意改错的实现确认它会失败。
  - 共 81 个测试通过；release 构建和测试构建都是 0 警告。
- 2026-11-17，第 8 节第 2 步（按决策 2 的推荐，一个条目存整个列表）：
  - `LoginKeychainItem`：登录钥匙串里的通用密码条目，用 `SecItem*` 读写，不用数据保护钥匙串，不同步到 iCloud。返回码归为四类：拒绝授权（`errSecUserCanceled`、`errSecAuthFailed`）、钥匙串锁着（`errSecInteractionNotAllowed`）、条目不存在（读取时返回空）、其他（带错误码）。
  - `KeychainAccountStorage`：格式 2 的内容 `{"formatVersion": 2, "accounts": […]}`。读取时，条目不存在而标记文件存在就报「找不到」，不当作空列表；内容读不懂、`formatVersion` 更高、授权被拒绝、钥匙串锁着都报错，不写入任何东西。保存时先写条目，成功后才在没有标记文件时写入它。
  - `AccountsMarker`：标记文件的读写，权限 `0600`。版本更高时报「来自更新版本」，内容读不懂或 `storage` 不是 `keychain` 时报无法读取，都不会因此重新迁移。
  - 新增 11 个测试（参数化展开后 16 个）：全新安装、重新打开、标记文件里没有密钥和名称（第 9 节第 7 条）、条目丢失、四种无法使用的内容、读取被拒绝或锁着、保存被拒绝（第 9 节第 6 条）、标记文件版本更高或损坏、返回码归类。另有 2 个读写真实登录钥匙串的测试（共 94 个，这 2 个默认跳过），在本机用 `GP_KEYCHAIN_TESTS=1` 运行通过，没有弹框，跑完不留条目。
  - 还没做：Info.plist 的 `GPKeychainService`、`AppEnvironment` 选择存储和迁移（第 3 步）。
- 2026-11-17，第 8 节第 3 步：
  - `AppEnvironment.keychainService` 来自 Info.plist 的 `GPKeychainService`。`build-app.sh` 新增 `SIGN_IDENTITY`（默认 `-`，即 ad-hoc）和 `KEYCHAIN`：用真实证书签名时默认 `KEYCHAIN=1`，写入 `GPKeychainService`（正式版 `site.stanzhai.GoldenPassport`，开发版 `site.stanzhai.GoldenPassport.dev`）；ad-hoc 签名默认 `KEYCHAIN=0`，照常用 `accounts.json`。所以现在的内测包和 CI 构建行为不变。
  - `prepareDataDirectory` 按 5.2 迁移：先看标记文件；没有时依次从 `accounts.json`、`gp.secrets` 迁移，都没有就沿用钥匙串里已有的条目。从 `gp.secrets` 迁移时照常记录 I6 基线、继承 0.1.x 的设置。迁移先把已有条目另存为 `accounts.replaced-<时间>`，写入后读回逐条比较（包括 id），一致才写标记文件；任何一步失败都不写标记文件，旧文件不变。
  - 不用钥匙串的构建（格式 1）看到标记文件时停下，报「数据来自更新版本（数据格式 2）」，不会从 `gp.secrets` 再生成一份 `accounts.json`。
  - `openAccountStore()` 按构建选择存储；`dataFormat` 随之是 1 或 2，「检查更新」用它判断新版本是否转换数据格式。
  - `remigrationSource` 和 `remigrate()` 是给第 4 步的：条目不见了时，由用户选择从 `accounts.json`（没有则 `gp.secrets`）重新迁移；条目还在时什么也不做。从 `gp.secrets` 重新迁移后重新记录基线，以免把已经导入的账号再提示一遍。
  - `MigrationCheck` 报告加 `storage=`、`source=` 和 `file_only=`（决策 4）。
  - 新增 18 个测试。先故意去掉读回比较和格式 1 构建的标记文件检查，确认相应测试会失败（`MigrationCheck` 自己的比较也报出了不一致的账号）。
  - 用真实二进制在本机验证：release 构建加 `KEYCHAIN=1`，把 `GPKeychainService` 改成探针专用的 service，数据目录放两个假账号的 `gp.secrets`。`--migrate-data` 第一次报告 `status=migrated`、`source=gp.secrets`、`consistent=true`，第二次报告 `already-migrated`；数据目录里没有 `accounts.json`，没有弹框。
- 2026-11-17，第 8 节第 4 步：
  - 启动时钥匙串读不出来，弹窗说明原因并写明「没有改动任何数据」：拒绝授权、钥匙串锁着时可以重试；条目不见了时，可以从 `accounts.json`（没有则 `gp.secrets`）重新迁移，没有旧文件时可以从空列表开始；内容读不懂、来自更新的版本时只能查看帮助或退出。从空列表开始会重写标记文件，不再记录迁移来源。
  - 用探针 App 实测（独立的 Bundle ID、数据目录、端口和 service，ad-hoc 签名，`KEYCHAIN=1`，通过辅助功能读取和点击弹窗）：
    - 条目不见、有 `accounts.json`：弹窗文字和按钮正确，点之前钥匙串里没有条目；点「从 accounts.json 重新迁移」后 App 正常启动，条目和标记文件都写好了。
    - 条目不见、没有旧文件（英文界面）：点「Start with an Empty List」后 App 正常启动，条目里是空列表。
    - 拒绝授权：用 `security` 命令创建条目，App 读取时系统弹出授权框。点「拒绝」后出现我们的「没有获得读取钥匙串的授权」弹窗；点「重试」后系统再次询问，再拒绝、退出，什么都没写入。这也验证了第 3 节的说法：别的程序读取时系统会弹授权框（测试中用 `security find-generic-password -w` 读取 App 创建的条目，同样弹出了授权框）。
  - 授权框里点「始终允许」需要输入登录密码，没有测；同一个 Team ID 签名的新版本是否不再弹框，仍然留到第 6 步。
- 2026-11-17，第 8 节第 5 步：
  - `install.sh`：按 `storage=`、`source=` 说明迁移到了钥匙串、来源是哪个文件；`manifest.txt` 加 `accounts_json_sha256`，用钥匙串的构建安装后 `accounts.json` 变了就自动恢复；结束时说明账号在登录钥匙串里，警告框列出仍是明文的 `gp.secrets` / `accounts.json`。
  - `rollback.sh`：按恢复的 App 是否有 `GPKeychainService` 区分；账号已在钥匙串里、恢复的是内测版时，提醒它看到的是迁移那一刻的 `accounts.json`，需要的话先导出（I5），再次升级后内测版里的改动由 `cleanup.sh` 列出；回到 0.1.x 时说明账号仍在钥匙串里；`--restore-data` 时说明钥匙串条目不变，再次安装会另存。
  - `cleanup.sh`：账号在钥匙串里时，把 `accounts.json` 加进删除范围，删除前列出 `file_only=` 的账号（决策 4）；结束语说明账号在登录钥匙串里。用不用钥匙串的构建时行为不变。
  - 文档：两份 README（0.2.0 的变化、安装、回退、清理、数据与安全、钥匙串读不出来时、构建、后续计划）、两份安装说明（按签名的正式版写，账号在钥匙串里）、两份 CHANGELOG、`docs/compatibility.md`（第 1 节加格式 2 和标记文件，第 2 节的保护，3.3 的决策 4 例外，`compat.json` 的 `dataFormat` 改为 2，I4、I5）。
  - 脚本在临时目录里实测（`GP_*` 指向临时目录，新版用临时 service，`GP_NO_LAUNCH=1`）：
    - 内测版 → 钥匙串构建：「已把 2 条记录从 accounts.json 迁移到登录钥匙串，逐条一致」；`rollback.sh` 回到内测版并给出提醒；在 `accounts.json` 里加一个账号后再次安装，报告沿用已有数据；`cleanup.sh --yes` 列出「Added in beta」后删除备份、`gp.secrets`、`accounts.json`、`legacy-baseline.json`，之后数据目录只剩 `accounts-v2.json` 和 `settings.json`，钥匙串读取正常。
    - 0.1.x → 钥匙串构建（英文）：从 `gp.secrets` 迁移；重装报告沿用已有数据。这次迁移时钥匙串里已有上一个场景留下的条目，按 5.2 另存为 `accounts.replaced-<时间>`。
    - 不用钥匙串的构建：安装和清理的输出与以前一致，`accounts.json` 保留。
    - 测试结束后删除了临时目录和测试用的钥匙串条目。
- 2026-11-19，第 8 节第 6 步（Developer ID：`Developer ID Application: Yue Zhuo (928NN87B92)`）：
  - 探针是两个 release 构建，`KEYCHAIN=1`，Bundle ID、数据目录、端口和 service 都是探针专用的，数据目录放两个假账号的 `accounts.json`。两个构建只差 `CFBundleVersion`，用同一个证书签名，所以 Team ID 相同、CDHash 不同，相当于同一个开发者发布的两个版本。
  - 构建 A 运行 `--migrate-data`：`status=migrated`、`source=accounts.json`、`consistent=true`，没有弹框。条目的访问控制里信任的是 A 的指定要求（Bundle ID 加 Team ID `928NN87B92`），不是 CDHash；分区是 `teamid:928NN87B92`。
  - 构建 B（相当于更新后的版本）读同一个条目：`already-migrated`、2 个账号、一致，没有弹框，用时约 0.03 秒。第 4 节说的「同一个 Team ID 签名的新版本可以直接读」成立。
  - 对照：把 B 改成 ad-hoc 签名再读，系统弹出了授权框，说明这个测试能区分两种情况。拒绝授权、条目被删的处理已在第 4 步实测，和签名方式无关。
  - 用 `xcodebuild -exportArchive` 公证时 Xcode 会重新签名，指定要求多了一个 App Store 证书的分支，但仍要求同一个 Bundle ID 和 Team ID，两种签名方式的构建互相满足对方的要求。
  - 测试结束后删除了探针 App、数据目录和钥匙串条目。

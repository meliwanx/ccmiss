# ccmiss

<p align="center">
  <img src="Resources/Brand/ccmiss-logo.png" width="136" height="136" alt="ccmiss 应用 Logo">
</p>

**为 Claude 准备一个看得清、切得动的 macOS 网络环境。**

[English](README.md) · [简体中文](README.zh-CN.md)

环境检测、隐私设置、账号专属 SOCKS5 出口切换，一个轻量原生应用即可完成。ccmiss 将路由、DNS、浏览器 WebRTC 检查和 Claude 出口监测放在一起，让你在开始工作前，知道当前究竟启用了什么。

**添加代理，初始化一次，按账号一键切换。**

## 界面预览

应用界面目前为简体中文，以下截图中的账号资料已打码。

![ccmiss 账号工作区，账号资料已打码](docs/images/account-workspace.png)

*账号工作区：在紧凑界面中查看网络状态、管理账号配置。*

<details>
<summary>展开查看：添加配置与 Claude Code 工具</summary>

**添加 SOCKS5 配置**

![ccmiss 添加 SOCKS5 账号配置，敏感资料已打码](docs/images/add-profile.png)

*将代理链接、账号名称和描述保存在同一份配置中。*

**Claude Code 工具**

![ccmiss Claude Code 工具，用于本地对话备份与安装维护](docs/images/claude-code-tools.png)

*查看本地对话备份，并按需主动执行维护。*

</details>

## 能做什么

| 功能 | 用途 |
| --- | --- |
| 多账号配置 | 保存多个 SOCKS5、名称与描述，明确区分“当前选中”与“实际生效”。 |
| 一键切换与恢复 | 将支持的服务切到所选账号出口，或停用覆盖、恢复原来的系统网络。 |
| Claude 出口监测 | 向 Claude 新建 HTTPS 请求，在侧栏显示实测出口 IP、实际模式和检测时间。 |
| 出口一致性提示 | 实测 Claude IP 与已验证账号出口一致时为绿色，不一致时为红色，未确认时为灰色。 |
| 环境检查 | 检查后台网络授权、隧道冲突、代理就绪状态及浏览器保护状态。 |
| DNS 与 WebRTC 配置 | 配置受管 DNS 路径及支持的浏览器 WebRTC 偏好，保留备份并显示真实状态。 |
| 独立运行 | 使用随构建打包的 Mihomo 内核与 macOS 原生后台服务，不要求安装 Clash。 |
| 可选 Clash 共存 | 利用已运行的 Clash Verge Rev，仅覆盖支持的服务路由。 |
| 无痕检测入口 | 用支持的默认浏览器私密窗口打开 Claude、Cloudflare、DNS 和 WebRTC 检测页面。 |
| Claude Code 工具 | 本地备份与查看对话、为新会话准备可读上下文，并主动执行支持的安装维护。 |

适合需要管理多个账号或代理出口，希望少改配置、看清状态、重复使用同一套初始化流程的用户。

## 日常怎么用

1. **添加账号配置。** 填写名称、可选描述，以及完整 SOCKS5 链接：

   ```text
   socks5://USERNAME:PASSWORD@203.0.113.10:1080
   ```

   这是文档示例，不是可用代理。凭据中的保留字符需要进行百分号编码。

2. **为这台 Mac 初始化一次。** 打开“软件设置”。独立运行时，按 macOS 提示授权后台网络服务；检测到支持的 Clash 共存环境时，则使用共存路径。浏览器保护单独设置，所有账号共用。
3. **启用配置。** ccmiss 先检查候选路径，再应用并验证结果。仅选中左侧账号不会切换网络。
4. **查看侧栏。** 确认当前账号或系统模式，以及最近一次 Claude 实测出口。可手动重测，应用可见时也会定期更新。
5. **切换或恢复。** 选中另一个账号并应用；当前生效账号的主按钮则是“停用并恢复系统网络”。

仅打开应用或保存新配置，不会自动启用一个新的代理。

## 两种运行方式

### 独立运行

ccmiss 管理自己的签名后台服务与 Mihomo 内核。默认仅将 Claude/Anthropic、Cloudflare 自家服务、Stripe/Link 及支持的检测端点经账号代理连接。局域网与其他流量按生成的路由规则处理。可选公网范围会代理更多流量，并拒绝不支持的公网 UDP。

服务保存自己修改的 DNS，并在停用时恢复仍由自己管理的值。接管前检查其他 VPN 冲突和暂不支持的网络条件。成功完成独立配置后，可记住启用意图，在登录且条件允许时尝试恢复。

### 与 Clash Verge Rev 共存

已有支持的 Clash Verge Rev 核心正在运行时，ccmiss 可为它添加限定范围的账号覆盖。支持的服务路由及其 DNS 策略使用账号出口，其他 Clash 设置继续按原配置运行。

切换无需重启 Clash、关闭其 TUN 或清空全部连接。应用修改和撤回前会校验受管覆盖；恢复未确认时保留恢复记录。此集成面向支持的 Clash Verge Rev 布局，不代表兼容所有名为 Clash 的应用。

**切换对新连接生效。** 已有连接可继续使用旧出口直到结束。浏览器扩展、应用单独配置的代理，以及浏览器连接池，也可能与应用探针走不同路径。

## 颜色与 IP 代表什么

侧栏向 `https://claude.ai/cdn-cgi/trace` 新建请求，通过当前 macOS 网络路径获取 Claude 端点观察到的出口 IP，不直接把代理服务器地址当成实测结果。代理服务器地址与最终公网出口可以不同。

| 颜色 | 含义 |
| --- | --- |
| 绿色 | 账号实测出口与已验证出口一致，或系统模式下成功测得当前出口。 |
| 红色 | 账号实测出口与已验证出口不一致。 |
| 灰色 | 正在检测、未能测得，或旧结果已不适用于当前网络状态。 |

颜色表示**连接状态和出口一致性**，不是 IP 信誉评级。ccmiss 不提供 IP 信誉分、黑名单认证或收费 IP 质检接口。DNS 检测显示递归解析器地址，它无需与网站看到的出口 IP 相同。

## 浏览器隐私检查

支持自动配置的 Chromium 浏览器包括 Chrome、Edge 和 Brave。ccmiss 可先备份再修改现有用户配置中的偏好，限制 WebRTC 未经代理的 UDP。仅在浏览器完全退出时写入，必要时由用户授予 macOS 文件访问权限。新增浏览器用户配置后应重新检查，扩展与组织策略仍可能覆盖偏好。

检测按钮使用支持的 Chrome/Chromium、Edge、Brave 或 Firefox 私密启动参数打开外部 `ip.net.coffee` 页面。不支持的浏览器会明确提示，不会偷偷改用普通窗口。无痕窗口不等于独立的网络身份。

## Claude Code 对话与维护

- 创建**全量备份**，或选择**开始、结束时间区间**，结束支持“至今”。
- 在应用中浏览可读对话，或在本机打开对应 Markdown。
- 将最近的可读对话内容准备为**新会话**上下文。先预览，再主动确认启动；启动时上下文会发送给当前 Claude Code 配置选择的服务。
- 确认后删除备份及允许清理的关联文件，显示占用信息，并保护未完成维护所需的恢复资料。
- 主动执行支持的原生安装维护：检查运行中的 Claude 客户端，先备份，再保留恢复资料。不结束现有任务，不自动替换自定义启动器、npm 或 Homebrew 安装。

可读内容迁移不恢复旧会话、消息、设备或登录状态。区间备份不能替代完整安装回滚包。原始备份与恢复副本可能含凭据及旧标识，仅在本机保存，必须作为敏感资料保管。分享任何导出文字前应先查看内容。

## 数据与功能边界

账号元数据、完整代理链接、设置和备份保存在 `~/Library/Application Support/AccountProxySwitcher/`。私有目录仅当前用户可访问，凭据文件权限为 `0600`。**代理凭据是本地明文文件，不使用钥匙串或加密保险箱。** 请保护 macOS 账号及其备份。

网络检测会访问相应服务端点，浏览器检测会访问外部检测网站；与普通请求相同，对方能看到连接的出口 IP。创建、浏览对话备份不会上传对话；在终端开启准备好的新 Claude 会话是另行确认的动作。

这里的账号隔离指**路由配置与代理出口分开管理**。ccmiss 不创建浏览器容器、不隔离 Cookie 或登录会话、不伪装设备，也不清除服务端记录。不保证账号安全或防封，请遵守相关服务条款与地区支持要求。

ccmiss 是独立项目，与 Anthropic、Cloudflare、Stripe 或 Clash Verge Rev 无隶属或官方认可关系；相关名称用于说明兼容目标。安全边界见 [SECURITY.md](SECURITY.md) 与[架构说明](docs/architecture.md)。

## 从源码构建

本仓库提供源码及构建说明，不包含个人运行配置、代理凭据、对话备份、本机交接记录、签名证书或预编译应用包。

当前目标：**Apple Silicon，macOS 13.5 或更新版本**。应用界面目前为简体中文；中英文说明文档不代表应用界面已完成英语适配。

需要 Xcode Command Line Tools、Python 3，以及开发者自己的 Developer ID Application 签名身份。应用和特权后台服务必须使用配置的同一签名团队。准备脚本使用固定依赖版本并校验下载，参见[第三方声明](THIRD_PARTY_NOTICES.md)。

```sh
./Tools/fetch-dependencies.sh

export ACCOUNT_PROXY_SIGN_IDENTITY='Developer ID Application: YOUR NAME (YOUR_TEAM_ID)'
export ACCOUNT_PROXY_TEAM_ID='YOUR_TEAM_ID'

./build.sh
```

依赖保存在 `.deps/darwin-arm64/`。必要时可通过 `ACCOUNT_PROXY_NODE` 指定 Node.js 可执行文件，构建会检查支持的版本与架构。产物为 `dist/ccmiss.app`。

构建不会注册后台服务或切换当前网络。受支持的特权服务流程需要开发者签名；不签名运行源码检查，不等于支持免签安装 TUN。Developer ID 签名与 Apple 公证是两个步骤，构建不会自动向 Apple 提交公证。

体验自己的构建时，将应用放入 `/Applications`，添加自己的代理，再按软件设置完成检查。移除应用或关闭后台服务前，请先在应用内停用网络并确认恢复。

## 源码检查

```sh
python3 Tools/check-public-source.py
./Tools/verify.sh
```

公开源码检查帮助识别误放的本地资料与凭据。验证脚本运行项目的隔离检查，不表示授权接管真实网络或重装 Claude Code。正式分发前，仍应在合适的 Mac 上受控验收特权 TUN、DNS 恢复、登录恢复与 VPN 共存。

| 目录 | 职责 |
| --- | --- |
| `Sources/AccountProxySwitcher/` | SwiftUI 应用、配置存储、环境检查、浏览器偏好、Claude 出口探针与对话工具界面。 |
| `Sources/AccountProxyService/` | 原生特权服务、签名客户端校验、内核归属、DNS 生命周期与恢复。 |
| `Resources/` | 网络编排、Claude Code 工具后端及固定依赖版本元数据。 |
| `Tools/` | 依赖准备、签名构建、公开源码检查与隔离验证。 |

分享日志、Issue 或截图前，请去掉代理链接、账号名称、本地路径、令牌与对话内容。不要提交应用运行数据目录里的文件。

## 许可证

ccmiss 使用 **GPL-3.0-or-later**，见 [LICENSE](LICENSE)。第三方组件保留各自许可证，见 [THIRD_PARTY_NOTICES.md](THIRD_PARTY_NOTICES.md) 及固定版本来源元数据。项目未修改 Mihomo 上游内核源码。

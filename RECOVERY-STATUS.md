# Virt Manager 修复进度

更新：2026-11-07，Asia/Shanghai。

## 本轮结果与证据边界

本轮已完成源码修复、Release 打包、ad-hoc 签名、配置自检、M5 Pro 上真实 Metal 离屏渲染测试，以及现有 Windows 安装的隔离快照启动。Windows 启动可进入 3024×1964 锁屏，SPICE agent 实际连接。原先 SIGABRT 涉及的 Metal 管线现已在本机实际创建并提交 GPU 命令，不能把这个结果等同于所有 Windows 应用/游戏、鼠标跟手或全屏交互均已验收。

Windows WebDAV 文件夹共享尚未实现；本轮按恢复要求明确禁用错误的 Windows 共享入口并移除 9p。此功能不再伪装成可用。

## 原始问题

用户报告画面 `Display output is not active`、退出全屏后窗口变成极窄条、沉浸入口丢失、鼠标捕获异常、剪贴板不稳定。原始崩溃报告为 0.2.0 (2)，Apple M5 Pro/macOS 27.2，在 SPICE GL 回调构造 WoAMetalDisplayView 时 Metal 管线校验触发 SIGABRT。

## 现场保护

- 原有 Git 提交 8fcee33、49710f1 与用户未提交修改均保留，没有 reset/revert。
- 修改前源码快照：`.recovery/20261107-203631/source-snapshot.tar.gz`，同时保留 binary patch 和 manifest。
- 诊断和截图在忽略跟踪的 `.recovery/`；不要提交真实来宾截图或临时包。
- 真实 Windows 位于 Library.plist 注册的外部 .virtvm。测试持有原包执行锁，复制 UEFI/TPM，磁盘使用 QEMU `-snapshot` 临时写层；不保存到原磁盘，不修改原配置。保留 UUID/NVMe 身份；测试关闭网络、音频、USB 自动连接和系统剪贴板集成，不打开前台窗口。
- `.recovery/original-guest-before.json` 记录配置/固件/TPM SHA-256 及原盘元数据，最终核验另见 `.recovery/original-guest-verification.json`（若存在）。

## 已落地修复

### 显示与 Metal

- 删除错误的跨 shader function constant 绑定，改为明确的 shader 函数和逐帧方向 uniform。
- 显示失败走可报告错误/软件 IOSurface 拷贝降级；不会在 Swift 中用强制 try 初始化管线。
- GPU 完成私有纹理复制后才释放 SPICE draw token；失败、旧代次、关闭、丢帧路径均完成 token；关闭通道不发送过期 ACK。
- 失活/遮挡仍保存有效 GL 私有帧；恢复只需重绘，不依赖 Windows 再次发送首帧。
- 软件定时器在 GL 模式保留但跳过工作，GL→软件恢复不再因定时器被销毁而冻结。
- primary 销毁/重建期间保留最后有效画面，收到新有效图像后再切换图层。
- C 桥 drain POLLIN|POLLHUP 的最后 IOSurface ID，处理部分读和 EINTR/EAGAIN，校验尺寸、stride、格式与内存上限；软件 primary 支持 32_xRGB、16_555，损伤矩形使用 64 位裁剪。
- 实际 Windows 快照揭示 UTM macOS IOSurface 行方向与 GL y0top 标志不能直接等同；C 桥按此运行时的 Metal top-left 行约定规范化方向。参考 CocoaSpice 的 macOS 映射方式，shader/软件/诊断截图共用方向规则。
- 扫描输出几何变化才写诊断日志，避免每帧刷屏。

### 输入、全屏、剪贴板

- 绝对/tablet 模式按实际画面宽高比转换坐标，使用系统指针，不调用全局鼠标脱离。
- 相对模式才捕获，并保留亚像素运动余量；模式通知不循环 release/recapture。
- 退出沉浸、失活、失去 responder、窗口隐藏和关闭时释放普通键、修饰键与鼠标按钮，capture=false 幂等清理。
- NSWindow 仅安装一次直接 guest contentView，删除 style/toolbar 切换中手工覆盖根视图尺寸；保存外框、恢复 chrome 后恢复外框，增加最小尺寸/无效尺寸保护和重入保护。
- 绿色按钮、工具栏、⌘⌥Return 使用同一沉浸入口；重建 chrome 后及下一主队列重绑，zoom/toggleFullScreen responder 兜底。⌘⌥⇧Q 退出。
- 当前实现是同一 NSWindow 的 borderless 沉浸，不承诺原生独立 fullscreen Space；旧 README 的矛盾描述已纠正。
- 剪贴板 grab 回调修正 gboolean ABI，仅处理标准 selection、UTF-8、有效长度和匹配请求；空文本、非 ASCII、agent 断开/重连处理已补齐。宿主轮询使用 common runloop，并限制到活动来宾窗口。

### 配置与能力边界

- Windows 不注入 fsdev/9p，拒绝额外参数绕过；旧共享字段按原值保留，不再合并覆盖，也不校验失效的旧目录。
- 网络启动模式保留 NAT、端口转发、外部 QEMU stream Unix socket、断网；修正端口范围、重复绑定、IPv4 和 socket 参数校验。
- 拒绝未经验证且无回滚的运行中网络重配，避免删除现有网卡或意外恢复暂停虚拟机。
- 分辨率在线修改要求 SPICE agent；移除无关的 change vnc 命令；刷新率涉及 EDID 引擎，须关机修改。

## 已执行验证

- `bash scripts/build.sh`：成功生成 `artifacts/Virt Manager.app`，包括所有 UTM 5.0.8 依赖；`codesign --verify --deep --strict` 成功。
- 打包应用 `--self-check`：通过，含旧包迁移、执行锁、配置持久化、Guest Tools ISO、GPU/TPM 启动参数，以及本轮新增旧共享保留、文件系统参数拒绝、四种网络模式/转发校验。
- 打包应用 `--display-self-check`：Apple M5 Pro 上实际 shader 编译、pipeline 创建、离屏 GPU draw/readback、两种方向、IOSurface 软件降级、padding、隐藏窗口复制、过期代次丢弃、完成回调、截图与显示方向一致性通过。
- `Tools/test-spice-bridge.c`：clang -Wall -Wextra -Werror 与 ASan/UBSan 通过；含真实 IOSurface/pipe 的 HUP 最后消息、部分读取、6561 个损伤矩形、32 位/555 软件图像、切换与 token 生命周期、剪贴板协议测试。SPICE 函数在此单元测试内为 stub，不能作为真实来宾功能验收。
- 离屏真实 NSWindow 多轮 chrome/style/geometry/绿色按钮测试通过；没有在该测试复现原先极窄条，因此不声称它证明原先实机故障完全消失。
- 已对 DirectX、Venus 分别执行真实已安装 Windows 的 120 秒隔离快照启动，均收到有效帧并进入锁屏、agent 连接。首次截图发现倒置后已修正运行时方向，复验资料见 `.recovery/windows-upright/` 与对应日志。
- 构建与检查日志：`.recovery/final-package-build.log`、`final-self-check.log`、`final-display-self-check.log`、`bridge-check.log`；实际启动日志 `windows-final-directx.log`、`windows-final-venus.log`、`windows-upright.log`。

## 尚待交互验收

1. 登录 Windows 后交替使用绿色按钮、工具栏与快捷键反复进入退出；切换应用/Space/显示器，检查恢复尺寸、入口与卡键。离屏测试不能替代此步骤。
2. 实际鼠标跟手、拖动、相对模式、窗口缩放后点击对应、持续帧率和启动黑屏时长。没有可靠测量前不承诺延迟改善数值或 120 fps。
3. 登录后用实际应用验证中英文剪贴板双向及焦点切换。诊断启动故意不改系统剪贴板；agent 连接不等同于双向复制已验收。
4. DirectX/Venus 应用、游戏兼容性、音频和物理 USB。进入锁屏仅验证 Windows 桌面显示路径。
5. Windows 文件共享需未来完整实现 SPICE WebDAV server/channel 和客户机客户端后重新启用；当前明确未支持。

不要删除上述验证边界，也不要用编译成功替代真实交互验收。


## 最终复验结果

最新方向修复后完整 120 秒 DirectX 隔离启动退出码为 0。人工读取 `.recovery/windows-upright/windows-119.png` 确认中文日期、时间与锁屏背景均正向显示。有效 3024×1964 帧约在启动后 17.569 秒观察到；这不是黑屏改善量的对照测量。原包配置、固件、TPM 全部 SHA-256 和原磁盘 size/mtime/inode 与测试前相同，核验文件为 `.recovery/original-guest-verification.json`。

交付构建位于 `artifacts/Virt Manager.app`；尚未覆盖 `/Applications/Virt Manager.app`。用户打开旧安装版本不会获得本轮修复。源码修复、打包及上述测试完成，登录后的交互验收仍按上列项目保留，不能将整个产品状态标记为全部已验收。

## 剪贴板故障追踪（2026-11-07 22:00 后）

用户确认双向剪贴板完全无效，Windows vdagent 不保持托盘常驻。剪贴板仍未完成真实来宾验收，不能标记已修好。Windows SPICE 使用 spice-agent/vdservice 服务和登录用户会话中的 vdagent 进程；没有托盘图标本身不证明进程未运行。

本轮发现初始 pasteboard changeCount 会使启动前已有文本不被宣告；已改成首次/agent 重连强制待同步，并避免 capability 更新时反复释放/重抢旧文本。新增实际 clipboard-by-demand 能力检查，显示窗口工具栏提供 agent 未连接、等待能力、通道就绪、宿主文本宣告、Windows 请求、收到 Windows 文本等状态。日志仅记录状态/长度，不记录文本内容。

构建、配置自检、显示自检、ASan/UBSan 桥测试通过，见 .recovery/clipboard-*.log。当前 Applications 安装的 executable 与新 artifacts 构建哈希不同，未自动覆盖安装。新构建位于 artifacts/Virt Manager.app。

Tools/Check-WindowsSpice.ps1 提供 Windows 只读服务/进程/session/virtio serial/崩溃诊断；-RestartAgent 为明确的可选服务重启，需管理员。未在实际 Windows 中执行此脚本，也未观察用户当前登录会话内的服务/进程；需要该证据才能确定 guest service、user agent 或 host 协商中哪一段失败。

后续用户截图证实 vdservice（Session 0）与 vdagent（Session 1）均在运行。恢复工具栏显式安装/可见性后，用户在应用内实际粘贴成功并确认“OK，搞定了”。Win+V 历史为空不等于 SPICE 按需传输失败；纯文本剪贴板现已获用户实际验证。

## 启动 not-active 等待优化（22:37 后）

用户报告仍有约 5–10 秒黑屏/not active 等待。最近来宾 QEMU 日志显示 22:26:01–02 创建 DWM/LogonUI 图形上下文，到 22:26:08 才开始导出桌面资源，存在约 6–7 秒来宾/Neptune 初始化间隔；这还不能独立排除宿主显示交接问题。

发现 main-agent-update 包含多次 capability 更新，但视图每次均立即强制请求分辨率，可能在启动 GPU 接管期间重复 mode-set。现改为共享防抖/去重路径，目标尺寸已实际生效则跳过。未加入隐藏 not-active 字样或伪造画面；不能以保留旧画面冒称缩短启动。新独立构建 artifacts/Virt Manager Startup.app 保留已确认的剪贴板与工具栏修复。构建、配置自检、GPU显示自检及签名通过。实际隔离启动日志见 .recovery/startup-snapshot.log；启动等待改善量仍需对照测量和用户运行验证。

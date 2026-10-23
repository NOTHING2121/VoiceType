# VoiceType 开发进度

## 开发约定

- 每步小提交。
- 每完成一步更新此文件。
- 每次实际语音会话记录延迟指标。
- API key 仅从 `OPENROUTER_API_KEY` 或 Keychain 读取，不写入代码或提交到 Git。

## 步骤 0：仓库初始化（2026-10-23）

已完成：

- 确认当前工作目录为空，且不属于其他 Git 仓库。
- 在当前目录创建 Git 仓库，初始分支为 `main`。
- 添加 `README.md`，记录目标、技术栈、模块边界与开发规则。
- 添加 `.gitignore`，排除构建产物、Xcode 用户状态、本地环境变量文件、密钥文件与工作中间产物。
- 建立本进度日志；本步骤只做仓库初始化，不实现应用功能。

验证范围：检查 Git 暂存内容与初始提交；未创建 Swift / Xcode 工程，因此本步骤不进行应用构建或测试。

语音会话及延迟指标：无。尚未运行语音会话，没有实测延迟数据。

## 步骤 0 修正：仓库位于子目录（2026-10-23）

此前误将父目录初始化为仓库，现已按用户要求移除父目录的 `.git`，将已有初始化文件迁入 `VoiceType/`，并在该子目录重新初始化 `main` 分支。新的仓库根目录为 `/Users/jianwenyang/Desktop/manus interview/VoiceType`；父目录不再是 Git 仓库。旧的初始化提交随外层仓库移除，新仓库创建独立的初始提交。

本次只修正仓库位置，不开展应用开发，也不修改架构说明。用户补充的 macOS 13+、Apple Speech 主链路及可选 OpenRouter 文本润色方向留待明确开始后更新。

验证范围：检查新仓库根目录、提交内容、工作区状态和父目录 `.git` 已移除。未运行语音会话，无延迟实测数据。

## 步骤 1：设计文档（2026-10-23，待用户确认）

已阅读用户新增的 `agent.md`，以其中的 macOS 13+、Apple Speech 端侧主链路和可选 OpenRouter 文本润色作为当前约定。新增 `design.md`，明确八个会话状态的允许转换、混合快捷键与时间边界、逐段延迟预算、识别与文本降级链、插入结果验证、密码框阻断及隐私留存；末尾列出主要风险。README 已同步，移除过时的 OpenRouter 音频识别说明。

设计明确标注需要确认的边界：免提启动单击不因当下无声立即丢弃；300ms 防误触用于结束时的短会话；无法确定目标安全时不自动注入；已提交的外部写入不承诺被 Esc 撤回。延迟数字仅是目标，没有声称实测达标。

验证：运行文档结构／引用／预算一致性检查以及 `git diff --cached --check`。当前不存在 Swift 工程或单元测试，不能运行应用构建、Swift 测试或真实语音测试；这些测试留待设计确认并开始实现后进行。本步提交仅包含本次文档变更，用户新增的 `agent.md` 保持原样，不自动纳入提交。

语音会话与延迟指标：无。本次未打开麦克风、调用润色模型、读取 Keychain 或操作其他应用输入框。等待用户确认后再实现。

## 步骤 1 修订：兼容性优先与剪贴板定时恢复（2026-10-23）

按用户要求更新 `design.md` 第 5.1 节：默认判定安全，只在检测到 `AXSecureTextField` subrole 或 `IsSecureEventInputEnabled() == true` 时安全阻断。AX 查询失败、属性缺失或可编辑性未知不再阻止粘贴；系统权限限制、可确认的目标变化和已写入结果未知仍按各自的技术／交付规则处理。该修订替代上一步“安全未知不自动注入”的初版取舍。

第 5.3 节改为 Cmd+V 发出后等待 500ms，仅当前 `changeCount` 仍是本次写入的版本时恢复原有内容和类型，否则完全不动。不再要求确认消费；恢复计时独立于插入关键路径和会话 HUD，不因会话结束丢失。复制并提示的文本不自动恢复。相关状态转换、权限降级、复制规则、隐私、验收、风险和 README 已同步，保留实际写入结果未知时不重复发送的规则。

验证：运行文档一致性校验和 `git diff --cached --check`，覆盖默认安全表述、两个危险信号、500ms 与版本检查、移除旧消费确认前提。仍未创建应用工程，因此没有 Swift 单测／构建或真实粘贴测试；文档记录自绘密码框漏检、慢应用超过 500ms 才读取及跨进程恢复竞态等剩余风险。

本次仅修订设计，未开始实现、未打开麦克风或操作系统剪贴板。没有语音会话及实测延迟；`agent.md` 保持用户原样，未纳入本步提交。整体设计仍待确认。

## 步骤 1 再修订：服务器同意与切换应用后复制（2026-10-23）

按用户最新补充，识别改为端侧优先；不支持时在 Onboarding／设置说明上传 Apple 的数据、网络依赖和留存边界，取得独立产品同意后才允许服务器路径。隐私模式可强制端侧；设计默认关闭该开关，但服务器同意初始未取得，因此不会擅自上传。隐私模式同时跳过云文本润色，服务器识别与 OpenRouter 润色分别授权。服务器五分钟会话设计为分段续接，延迟指标区分端侧与网络路径。

ZDR 改为默认关闭的尽力偏好，不再是润色前提或无端点时硬失败的理由；账号／key 自身更严格的服务端限制仍保留。应用切换时不取消录音、不追踪窗口／选区、不强行切回或注入新应用；正常完成处理后自动复制，HUD 使用用户指定文案“已复制，按 command+v粘贴”。copy-only 不自动恢复剪贴板，原自动粘贴 500ms 版本匹配恢复规则不变。两个明确危险信号和写入后未知结果规则仍保留。

状态机、权限说明、识别／文本／交付降级、隐私、设置、验收、风险和 README 已同步。`agent.md` 未修改；其中原离线表述由本次后续用户修订补充，不把修改设计视为用户已批准实际数据上传。

验证：文档结构、引用、预算及新策略一致性检查，另跑 `git diff --cached --check`。没有应用工程，未运行 Swift 构建／单测／录音或真实服务器请求。本次只改设计，语音会话与实测延迟均无；整体设计仍待确认后实现。

## 步骤 1 修订：语气词清理由用户选择（2026-10-23）

将“删除孤立语气词”“清理句首口头语”明确设为两个独立的可选增强，默认关闭，不强制删除。Onboarding 展示清理前后示例及误删风险，由用户分别明确选择；不预勾选，跳过或点击继续不视为启用，设置里可分别修改。初始仅做格式清洗，启用模型也不能绕过这些偏好；即使启用，指代、肯定回应、引用与语义不明情况仍保留。

同步 `design.md` 第 4.2 节、偏好留存、验收和 README。运行文档一致性及 Git 差异检查；尚无工程，因此没有实际规则单测、构建或语音会话，不声称延迟达标。只修订设计，等待整体确认后实现；`agent.md` 保持原样。

## 步骤 2：菜单栏工程与测试入口（2026-10-23）

用户已授权按当前设计开始本阶段实现：UI 仅图标和退出，系统功能使用假模块。建立零第三方依赖的 Swift Package，包含 VoiceTypeCore 库、VoiceType 菜单栏 executable 和测试目标。Swift tools 5.9、Swift 5 语言模式、macOS 13 部署目标；SwiftUI MenuBarExtra + AppKit accessory，Info.plist 为 LSUIElement=true。建立系统模块协议、纯数据类型与文本清洗基础，提供可重复的 App 打包脚本。

实际验证：核心库 Debug 编译通过；Release App 构建通过，生成 build/VoiceType.app；plist、bundle 文件及 ad-hoc 签名验证通过。标准测试入口真实运行 1 个安全信号冒烟用例并通过。未启动 GUI，不把源码检查当作真实鼠标菜单验收。

工具链限制：本机只有 Command Line Tools，Swift 6.4、macOS 27.0.1 arm64，没有完整 Xcode／XCTest framework。测试采用工具链自带 Swift Testing，并显式加载已有 TestingMacros 插件；源码保留完整 Xcode／Swift 5.9 下的 XCTest 兼容入口。本机 Testing 运行库最低 macOS 14，产品部署目标仍为 13；当前未在 macOS 13 或 Swift 5.9 实机验证。SwiftPM 专用配置／缓存写入经过执行权限流程，不改全局开发配置、不下载依赖。

语音会话及实测延迟：无。状态机与端到端假流程尚在本阶段后续步骤验证，不把这一个冒烟测试当作全套通过。

## 步骤 3：纯状态机与文本规则回归（2026-10-23）

实现八状态 SessionStateMachine reducer，只接受事件与单调毫秒时间并返回 effect。覆盖手势模式、250／300ms 边界、实际采集起算的五分钟、音频停止确认、500ms 识别冻结、服务器同意与隐私切换、模型650ms／stop+1180ms 截止、应用切换、交付提交点、unknown 不重发、旧 session／op 失效和终态资源门。启动无回调设置1秒有界失败（不是正常启动耗时目标）；分段按任务顺序保存，音频端点去重不丢弃乱序旧段。两个可选删除规则必须显式选择，组合规则修正为幂等。

实际验证：运行 scripts/test.sh，59 个状态机场景、36 个处理／插入竞态场景、15 个文本场景及1个冒烟用例全部通过（Swift Testing 汇总4个测试入口）。这些测试注入时间并手动回投模块结果，不访问真实系统。识别回调在旧任务完成后不可改写已确定内容；已提交后 Esc 不继续降级写入，尚未提交时开隐私改用本地文本。

语音会话及实测延迟：无。此步只验证纯逻辑；系统 fake、协调器及额外端到端场景留在下一步独立提交。

## 步骤 4：假系统协调器与完整回归（2026-10-23）

接入串行 SessionCoordinator、VirtualScheduler、FakeHotkeyMonitor、FakeAudioRecorder、FakeTranscriber、FakeTextProcessor、FakeTextInserter、FakeHUD 和 InMemoryMetrics。启动／处理／准备／写入 effect 执行前再次校验当前会话与操作令牌；写入授权与 fake 写入入口之间无异步间隔。剪贴板仅用内存模型，保存全部 items/types，500ms 版本匹配恢复；恢复任务独立于会话计时器，支持空内容、外部改写、新会话、重叠 paste、copy-only 和恢复失败。

首轮139个回归场景＋1个冒烟用例发现1个真实失败：组合清洗非幂等，已修复。独立只读审查另外发现并修复：尚未提交的润色结果遇到隐私开启应回本地；分段乱序不能用最大 audioEnd 丢掉前段；fake 轮换应结束旧任务且用独立后续脚本；fake copy 成功写入不能回报确定失败。新增14个针对性回归；旧分段在500ms窗口内可等待，完整 final 按任务替换子片段、partial 按任务覆盖，而不是重复追加。

最终实际运行：176个参数化场景＋1个冒烟用例全部通过；Swift Testing 汇总为7个测试入口、1个 suite、0失败，xUnit按入口计数为7而非177。分组：状态机59、处理／插入36、端到端／剪贴板29、文本15、不变量23、独立审查14。包含两组各1000事件的确定性状态转换序列检查。开启覆盖率并导出真实 llvm-cov 报告：reducer 行覆盖98.08%，核心目录行覆盖97.25%，不是100%或形式证明。

每个 fake 会话都会记录内存指标。导出8个明确标注 simulated=true 的示例：AX 停止到验证47ms、paste 69ms、copy-only停止到复制47ms、模型成功147ms、模型超时697ms、partial降级517ms；首字70ms来自预设80ms字幕／10ms声音脚本。以上不是实机性能，也不证明实际Apple识别／OpenRouter／目标应用达标。测试另明确复现超过500ms慢消费可能读到旧剪贴板，这是已知风险，不当作成功插入。未打开真实麦克风、调用网络、读Keychain或修改系统剪贴板。

## 步骤 5：最终打包、验证与结果交付（2026-10-23）

菜单栏入口仅 waveform 图标与中文“退出 VoiceType”，AppKit accessory＋LSUIElement；不接入任何fake或真实语音流程。打包脚本补上Swift manifest局部缓存，并确保两个脚本可执行。重新从最终源码Release构建，通过plist与ad-hoc签名验证；Mach-O arm64最低系统13.0，动态依赖只有系统库，无Testing、私有rpath或构建目录依赖。未启动App GUI，也未做鼠标菜单或macOS13实机验收。

最终源码再次执行带覆盖率全套测试，7入口／177场景／0失败；覆盖率和xUnit重新导出。更新README构建／测试命令、design实现状态和文档校验器，文档一致性、bash语法与Git差异检查通过。用户agent.md散列仍为初始化读取值，保持原样且未纳入提交。

本机交付目录 `../outputs/voicetype/`：`VoiceType.app`、`VoiceType-app.zip`、`VoiceType-test-results.zip`。可直接阅读 [完整测试报告](../outputs/voicetype/test-results/test-report.md)；测试归档包括实际原始输出、原生7入口xUnit、176场景名称清单、真实覆盖率与8条虚拟会话指标。两份zip解包校验通过；交付App再次验证签名。不发布、不安装、不替用户启动、不下载依赖；真实语音会话数量仍为0。
## 步骤 6：真实主链路接入（2026-10-23）
新增 `VoiceTypeSystem` 库，核心库仍不依赖系统框架。真实适配器：`SystemHotkeyMonitor`（被动 NSEvent 监听，`HotkeyInterpreter` 用设备位 0x40 区分右 Option，会话中按通用 Option 位补发漏掉的松键）、`SystemAudioRecorder`（AVAudioEngine 只在会话中开麦，AVAudioConverter 转 16kHz 单声道，RMS 声音检测）、`SpeechTranscriber`（`addsPunctuation`，`requiresOnDeviceRecognition` 跟随冻结策略，partial 驱动 HUD，final 为结果，1110 无语音映射为空 final）、`LocalTextProcessor`（复用已测本地规则；润色未接入，请求即安全降级）、`SystemTextInserter`（AX selectedText 写入后有界读回验证；确定未写入才发一次 Cmd+V；剪贴板多 item／多类型快照，500ms 后 changeCount 仍为写入版本才恢复，连续粘贴沿用最初原内容；最后复制提示；每步重测 `AXSecureTextField` 与 `IsSecureEventInputEnabled()`）、`LiveScheduler`、`SystemEnvironmentProbe`、JSONL `MetricsLog`。
HUD 为 `.nonactivatingPanel` 的 NSPanel 子类，`canBecomeKey/Main` 恒 false、忽略鼠标、`orderFrontRegardless`，显示识别方式、实时字幕和结果文案。reducer 新增只读 `hudMessage`／`liveCaption` 与可配置插入看门狗（默认 180ms 不变，真实链路 500ms，给 AX／paste 读回验证留余量）。菜单：权限状态及系统设置入口、识别语言、隐私模式、Apple 服务器识别同意（开启前弹说明，仅在当前语言不支持端侧或已开启时显示）、取消当前听写、延迟记录、退出。Info.plist 补齐麦克风与语音识别用途说明；ad-hoc 签名改为按 bundle ID 的指定要求，减少重建后重新授权。
实际验证：`scripts/test.sh` 核心 203 个场景（新增 27 个：按键解析、AX 观察判定、语言选择、HUD 文案、看门狗）＋系统适配层 13 个（隔离命名 NSPasteboard 上真实快照／恢复／版本跳过／重叠粘贴、48k 双声道与 44.1k 转 16k、RMS、声音检测、指标脱敏）＋冒烟 1 个全部通过。首轮发现 1 处测试假设错误：重采样器会暂存约 14ms 尾部样本，断言改为“不超过理论值且暂存 <30ms”。Release 构建与 `codesign --verify --deep --strict` 通过。`--hud-selftest` 实测 6 个采样点：HUD 可见 5 次，前台应用始终为原应用，VoiceType 未激活、无 key window，HUD 非 key／main。
偏差与已知限制：被动监听不吞掉 Esc（目标应用也会收到 Esc）；全局监听依赖辅助功能权限而非输入监控；分段轮换无重叠去重；剪贴板快照在主线程同步读取，超大内容或延迟提供的数据可能卡顿；Cmd+V 按 ANSI 键位发送；指标 7 天清理未做。测试中两次经 `open --args` 启动未带上自检参数而进入正常模式，可能在屏幕上弹出过授权请求，进程已结束。
语音会话及实测延迟：0。真实麦克风、Speech、AX 和备忘录插入需要用户授权后实机验收；每次会话会写入 `~/Library/Application Support/VoiceType/metrics.jsonl`。
## 后续里程碑

- [x] 用户授权按 `design.md` 开始菜单栏骨架与假模块测试阶段。
- [x] 创建 Swift 5.9、macOS 13+ 菜单栏应用工程，配置 `LSUIElement`。
- [x] 实现纯逻辑 `SessionStateMachine` 及单元测试。
- [x] 实现系统模块协议、假实现、虚拟调度和端到端回归。
- [x] 完成本阶段App打包与测试报告交付。
- [ ] 实现 Onboarding 页面（权限请求与菜单设置已完成，语气词选择页未做）。
- [x] 实现 `HotkeyMonitor` 按下／松开事件。
- [x] 实现 `AudioRecorder`（16 kHz 单声道）及会话延迟采集。
- [x] 实现 `Transcriber` 端侧流式字幕、最终结果和 HUD。
- [ ] 实现 `TextProcessor` 本地规则与可选文本润色、环境变量／Keychain 密钥读取及超时降级。
- [x] 实现 `TextInserter`：AX → 剪贴板粘贴 → 复制并提示。
- [ ] 用户在备忘录完成实机听写验收，并记录首批真实延迟。
- [ ] 完成设置／历史、端到端验证及实测延迟记录。

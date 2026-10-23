# VoiceType

macOS 菜单栏语音输入项目。目标是在任意应用按快捷键说话，经识别与轻度清洗后插入焦点输入框；当前完成的是**菜单栏骨架、纯状态机、系统 fake 与回归测试**，还不是可实际听写的产品。

## 当前状态

菜单栏 App 仅显示 waveform 图标和“退出 VoiceType”菜单项，通过 SwiftUI `MenuBarExtra` 与 AppKit accessory policy 运行；`Info.plist` 配置 `LSUIElement=true`，无 Dock 图标。App **不连接 fake 流程、不监听全局按键、不请求权限、不打开麦克风、不调用网络／Keychain、不读写真实剪贴板**。

核心有八状态 reducer、串行协调器、可注入系统协议、虚拟调度和脚本化 fake。176 个参数化回归场景加 1 个冒烟用例已实际通过（框架汇总 7 个测试入口）；细节与阶段提交见 [PROGRESS.md](PROGRESS.md)。当前设计见 [design.md](design.md)，用户原始约定 [agent.md](agent.md) 保持原样。

## 构建和测试

```bash
cd "VoiceType"
./scripts/test.sh
./scripts/test.sh --enable-code-coverage --xunit-output .work/voicetype-build/test-results.xml
./scripts/build-app.sh
# 手动体验菜单栏骨架（可选）：
open build/VoiceType.app
```

Swift Package 零第三方依赖；`Package.swift` 使用 tools 5.9、Swift 5 语言模式、macOS 13 部署目标。可用 Xcode 打开 Package.swift，也可通过 Command Line Tools 构建；本项目不依赖手写 Xcode project。`build-app.sh` 生成 `build/VoiceType.app`，做本地 ad-hoc 签名并验证 bundle；当前输出为本机 Apple Silicon arm64，未做分发公证或 Intel 构建。

本次实际环境为 Swift 6.4 / macOS 27.0.1。仅有 Command Line Tools，缺少 XCTest framework，故 `test.sh` 使用工具链自带 Swift Testing，并加载已有 TestingMacros 插件；完整 Xcode／Swift 5.9 下源代码保留 XCTest 入口。当前 Testing 运行库要求 macOS 14+，**这只影响该工具链的测试运行，不改变产品的 macOS 13 部署目标**。尚未在 Swift 5.9 或 macOS 13 实机验证，不把语言模式兼容当成旧系统运行通过。

## 模块划分

| 模块 | 本阶段实现 |
| --- | --- |
| SessionStateMachine | 纯 Swift reducer：状态、会话／操作令牌、手势、截止、取消、安全与降级 |
| SessionCoordinator | 串行执行 effect，写入入口前再次授权，过期 effect 不执行 |
| HotkeyMonitor | 协议和 FakeHotkeyMonitor；模拟独立右 Option、Esc、组合键、失联 |
| AudioRecorder | 协议和 FakeAudioRecorder；模拟启动、停止确认、声音、迟到资源、失败 |
| Transcriber | 协议和 FakeTranscriber；partial／final、独立45秒分段脚本、乱序与降级 |
| TextProcessor | 实际本地格式清洗、显式选择与结构校验；云端润色用 fake |
| TextInserter | 协议和 FakeTextInserter；内存 AX／paste／copy 结果及多类型剪贴板版本恢复 |
| HUD／设置／历史 | FakeHUD、可 Codable 的配置／选择记录、无正文 InMemoryMetrics；真实 UI 与磁盘留存未实现 |

所有 fake 的延迟均由 `VirtualScheduler` 驱动，不使用 sleep。测试中提到的 AX、paste、clipboard 都是内存模拟，不能当作真实 AppKit、浏览器或 Electron 兼容性验证。协调器当前按串行协议运行；将来真实异步 adapter 必须把回调统一投递到同一串行事件入口。

## 已钉住的核心边界

右 Option 249／250ms、短会话299／300ms、免提静默与二次按键、组合键、实际采集起算五分钟、Esc 与写入提交点、启动迟到 close、关麦确认、旧 session／op、final／partial 截止和分段乱序均有回归。启动无回调在1秒失败并清理，该数值是异常等待上限，不是正常 `<100ms` 启动目标。

端侧优先，端侧不支持时只在事先明确同意且非隐私模式下允许服务器策略；模型默认关闭，ZDR 默认关闭且仅是偏好。本地两项可选删除规则默认未选择／关闭，跳过引导不启用；Codable 选择记录已测试，实际 Onboarding UI 尚未实现。

自动交付默认安全，只由两个明确危险信号阻断；应用切换则复制且显示“已复制，按 command+v粘贴”。只有确定未写入才继续 AX → paste → copy；未知结果不重发。paste 后500ms仅版本匹配才恢复，copy-only不恢复。慢消费超过500ms的已知风险有专门测试，不能据此宣称已经解决。

## 后续真实适配器

AVAudioEngine／AVAudioConverter、Apple Speech 权限及端侧能力检查、音频有界缓冲与重叠按词时间戳去重、全局事件监听、安全输入监护、AX selectedText／写后验证、真实 NSPasteboard、HTTP／Keychain，以及 HUD／Onboarding／设置／历史 UI 均留待后续。

OpenRouter 仅作为可选**文本**润色，base URL 为 `https://openrouter.ai/api/v1`。实际密钥未来只从 `OPENROUTER_API_KEY` 或 Keychain 获取，不进入代码、配置仓库、日志或提交；本阶段只用 `hasModelKey` 假能力值，没有读取真实密钥。

每步适用验证、小提交、更新 PROGRESS；真实录音会话仍为0。虚拟指标示例不是 Apple Speech 或模型服务性能，不声称首字 `<500ms`／停止到插入 `<1.5s` 已在实机达标。

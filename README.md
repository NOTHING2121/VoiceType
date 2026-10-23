# VoiceType

macOS 菜单栏语音输入。按住右 Option 说话，HUD 显示实时字幕，松开后经本地规则清洗插入当前焦点输入框。当前阶段已接入**真实主链路**：全局右 Option／Esc 监听 → AVAudioEngine 录音 → Apple Speech 端侧流式识别（带标点）→ 本地清洗 → AX 插入 → 剪贴板粘贴 → 复制提示。OpenRouter 润色仍未接入（默认关闭，开启也会安全降级到本地文本）。

## 当前状态

菜单栏 App（`LSUIElement=true`，无 Dock 图标）启动后依次请求麦克风、语音识别权限，并提示打开辅助功能；菜单显示三项权限状态、识别语言、隐私模式（仅端侧）、Apple 服务器识别同意（仅当前语言不支持端侧时出现，开启前弹出说明）、活动时的“取消当前听写”、打开延迟记录和退出。

HUD 是不激活 App 的 `NSPanel`：`canBecomeKey`／`canBecomeMain` 恒为 false、`.nonactivatingPanel`、忽略鼠标、`orderFrontRegardless`。`--hud-selftest` 自检已实测：显示期间前台应用、VoiceType 激活状态和 key window 都不变。

单测：核心 203 个场景（含 27 个真实链路纯逻辑）、系统适配层 13 个（私有 NSPasteboard 真实快照／恢复、AVAudioConverter、声音检测、指标脱敏）、1 个冒烟用例全部通过。**真实麦克风、Speech、AX 和备忘录插入需要你在本机授权后亲自验收**，自动化测试没有替你点授权或开麦。细节见 [PROGRESS.md](PROGRESS.md)，设计见 [design.md](design.md)，原始约定 [agent.md](agent.md) 保持原样。

## 构建、测试和试用

```bash
cd "VoiceType"
./scripts/test.sh
./scripts/build-app.sh                      # 生成并签名 build/VoiceType.app
build/VoiceType.app/Contents/MacOS/VoiceType --hud-selftest /tmp/hud.json   # 可选：HUD 焦点自检
open build/VoiceType.app
```

首次运行：允许麦克风与语音识别；在“系统设置 › 隐私与安全性 › 辅助功能”打开 VoiceType（全局按键监听和 AX 插入／发送 Cmd+V 都需要）。然后在备忘录里点进一条笔记，按住右 Option 说话、松开即插入；快速单击右 Option 进入免提，再单击结束；Esc 取消。每次会话的延迟写入 `~/Library/Application Support/VoiceType/metrics.jsonl`（只含时间与路径，不含正文）。

无签名证书时，`build-app.sh` 使用 ad-hoc 签名并把指定要求设为 `identifier "com.voicetype.app"`，让重建后系统权限尽量保留（仅限本地开发）。有开发证书可设 `CODESIGN_IDENTITY`。本机环境为 Swift 6.4 / macOS 27.0.1 / 仅 Command Line Tools，测试用 Swift Testing；源代码保留 XCTest 入口与 Swift 5 语言模式，部署目标 macOS 13，尚未在 macOS 13 实机验证。

## 右 Option 没反应时

点开菜单确认三项权限已授权，并查看“快捷键监听”状态。若显示安全输入暂停，离开密码框后重试；若监听失败，点击“重新连接快捷键”。关闭菜单，在普通输入框按右 Option，再查看“已收到右 Option”的次数和“最近提示”。次数增加说明按键已进入应用；最近提示保留启动录音／识别失败的原因。

`~/Library/Application Support/VoiceType/diagnostics.json` 保存当前应用路径、权限、监听状态、右 Option 次数和最近错误，不记录普通按键或听写正文。设备左右标记缺失时，监听器读取右 Option 的物理键状态；重新连接会清空旧按键状态。全局与本地监听都安装成功后才显示监听已启动。

## 模块划分

| 模块 | 本阶段实现 |
| --- | --- |
| SessionStateMachine | 纯 reducer，唯一状态源；新增只读 HUD 文案／实时字幕、可配置插入看门狗（默认 180ms，真实链路 500ms） |
| SessionCoordinator | 串行执行 effect；所有真实回调统一投递到主队列 |
| HotkeyMonitor | `SystemHotkeyMonitor`：被动 NSEvent 全局／本地监听，`HotkeyInterpreter` 纯逻辑区分右 Option（设备位 0x40）、组合键、Esc；会话中按物理 Option 状态补发漏掉的松键 |
| AudioRecorder | `SystemAudioRecorder`：AVAudioEngine 只在会话中开麦，转换为 16kHz 单声道；RMS 声音检测；设备配置变化即停止 |
| Transcriber | `SpeechTranscriber`：`SFSpeechAudioBufferRecognitionRequest`，`addsPunctuation`、`requiresOnDeviceRecognition` 跟随策略，partial 驱动字幕，final 作结果 |
| TextProcessor | `LocalTextProcessor` 复用已测本地规则；模型润色未接入 |
| TextInserter | `SystemTextInserter`：AX `selectedText` 写入 + 有界写后验证 → 多类型剪贴板快照 + Cmd+V + 500ms 版本恢复 → 复制并提示；两个危险信号随时阻断 |
| HUD／设置 | 不抢焦点 HUD 与菜单设置已实现；Onboarding 页面、历史仍未实现 |

## 后续

OpenRouter 文本润色（base URL `https://openrouter.ai/api/v1`，密钥只从 `OPENROUTER_API_KEY` 或 Keychain 读取，不进代码与提交）、Onboarding 页面（含语气词清理选择）、历史、指标 7 天清理、分段边界重叠去重、多应用兼容矩阵与实测延迟仍待完成。

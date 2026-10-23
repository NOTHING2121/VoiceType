# VoiceType

macOS 菜单栏语音输入应用：在任意应用按全局快捷键说话，将语音转换为适合书面表达的文字，插入当前焦点输入框。

## 当前状态

仓库已初始化，[design.md](design.md) 已编写，等待用户确认后才实现。尚未创建 Swift / Xcode 工程，没有实测语音延迟。基础约定见用户提供的 [agent.md](agent.md)，后续用户修订以最新 design.md 为准；开发记录见 [PROGRESS.md](PROGRESS.md)。

## 技术栈与主链路

Swift 5.9，SwiftUI + AppKit，macOS 13+。应用设置 `LSUIElement`，不显示 Dock 图标。

按键 → AVAudioEngine 录音 → Apple Speech 流式识别（带标点）→ 本地规则清洗 → 可选 OpenRouter 文本润色（超时跳过）→ 插入。

优先端侧识别；不支持时在 Onboarding／设置说明音频将发往 Apple，用户明确同意且隐私模式关闭后才允许 Apple 服务器识别。隐私模式强制端侧并跳过云润色；开关默认关闭，但服务器同意初始未取得，不会未经允许上传音频。OpenRouter 默认关闭，只做文本增强，其“优先 ZDR”偏好默认关闭，不是润色的硬性前提。base URL 为 `https://openrouter.ai/api/v1`；key 只读 `OPENROUTER_API_KEY` 或 Keychain，不写入代码、日志或 Git。

## 模块边界

- `HotkeyMonitor`：全局右 Option 按下／松开、Esc 与组合键事件。
- `AudioRecorder`：AVAudioEngine 采集、16kHz 单声道转换和本地声音检测。
- `Transcriber`：SFSpeechRecognizer 字幕与最终识别，端侧优先，仅经事先同意允许服务器路径。
- `TextProcessor`：基础格式清洗加可选增强。“删除孤立语气词”“清理句首口头语”分别默认关闭，Onboarding 展示示例并由用户明确选择，设置中可修改；模型不能绕过选择。隐私模式不调用云模型，ZDR 仅作可选偏好。
- `TextInserter`：默认安全，仅 `AXSecureTextField` 或安全输入为 true 时阻断。正常链为 AX → 未执行／确定未写入时粘贴 → 复制；应用切换则直接复制，HUD 显示“已复制，按 command+v粘贴”，不强行切回应用或发送 Cmd+V。写入结果未知不重发；自动粘贴后 500ms 仅版本匹配时恢复，copy-only 不恢复。
- `SessionStateMachine`：唯一状态源，纯 Swift reducer，可用虚拟时间单测。
- HUD、Onboarding、设置／历史：反馈、授权、配置与留存控制。

## 开发约定

每完成一步跑适用测试、做小提交并更新 `PROGRESS.md`。每次实际语音会话记录延迟指标和处理路径，不伪造未测数据。当前只有文档，设计阶段检查文档一致性和 Git 差异；应用构建、状态机单测、真实录音与插入测试在确认并创建工程后执行。

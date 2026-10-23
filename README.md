# VoiceType

macOS 菜单栏语音输入应用：在任意应用按全局快捷键说话，将语音转换为适合书面表达的文字，插入当前焦点输入框。

## 当前状态

仓库已初始化，[design.md](design.md) 已编写，等待用户确认后才实现。尚未创建 Swift / Xcode 工程，没有实测语音延迟。最新开发约定以用户提供的 [agent.md](agent.md) 为准，开发记录见 [PROGRESS.md](PROGRESS.md)。

## 技术栈与主链路

Swift 5.9，SwiftUI + AppKit，macOS 13+。应用设置 `LSUIElement`，不显示 Dock 图标。

按键 → AVAudioEngine 录音 → Apple Speech 流式识别（带标点）→ 本地规则清洗 → 可选 OpenRouter 文本润色（超时跳过）→ 插入。

主链路强制端侧识别，语言和设备能力须运行时检查；不支持时明确提示，不静默上传音频。OpenRouter 默认关闭，仅作为文本增强，不负责语音识别。其 OpenAI 兼容接口 base URL 为 `https://openrouter.ai/api/v1`；API key 只从 `OPENROUTER_API_KEY` 或 Keychain 读取，不写入代码、日志或 Git。

## 模块边界

- `HotkeyMonitor`：全局右 Option 按下／松开、Esc 与组合键事件。
- `AudioRecorder`：AVAudioEngine 采集、16kHz 单声道转换和本地声音检测。
- `Transcriber`：SFSpeechRecognizer 实时字幕与最终识别，共享一个识别来源。
- `TextProcessor`：确定性的本地清洗，加可关闭／超时跳过的模型润色。
- `TextInserter`：通过安全门后 AX → 确定未写入时粘贴 → 复制并提示；密码框禁止自动注入，结果未知不得自动重发。
- `SessionStateMachine`：唯一状态源，纯 Swift reducer，可用虚拟时间单测。
- HUD、Onboarding、设置／历史：反馈、授权、配置与留存控制。

## 开发约定

每完成一步跑适用测试、做小提交并更新 `PROGRESS.md`。每次实际语音会话记录延迟指标和处理路径，不伪造未测数据。当前只有文档，设计阶段检查文档一致性和 Git 差异；应用构建、状态机单测、真实录音与插入测试在确认并创建工程后执行。

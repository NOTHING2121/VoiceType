# VoiceType — macOS 桌面语音输入
目标：用户在任意应用按全局快捷键说话，产品把语音转成适合书面表达的文字，插入当前焦点输入框。
技术栈：Swift 5.9，SwiftUI + AppKit 菜单栏应用（LSUIElement，无 Dock 图标），macOS 13+。

架构（主链路离线可用，模型只是增强）：
按键 → 录音 → Apple Speech 识别（带标点）→ 本地规则清洗 → [可选] OpenRouter 文本润色（超时跳过）→ 插入

模块边界：
- HotkeyMonitor：全局快捷键按下/松开、Esc
- AudioRecorder：AVAudioEngine 录音
- Transcriber：SFSpeechRecognizer 流式识别（实时字幕 + 最终结果）
- TextProcessor：第一层本地规则清洗；第二层 OpenRouter 润色（可关闭）
- TextInserter：AX 插入 → 剪贴板粘贴 → 复制并提示
- SessionStateMachine：唯一状态源，纯 Swift 逻辑，必须可单测
- HUD 浮窗、Onboarding、设置/历史

规则：
- OpenRouter（OpenAI 兼容，base URL https://openrouter.ai/api/v1），key 从环境变量 OPENROUTER_API_KEY 或 Keychain 读取，绝不写进代码或提交 git。
- 每完成一步：跑测试、git 小提交、更新 PROGRESS.md。
- 每次会话记录延迟指标和走了哪条处理路径。
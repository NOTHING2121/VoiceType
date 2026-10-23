# VoiceType

macOS 菜单栏语音输入应用：在任意应用按全局快捷键说话，将语音转换为适合书面表达的文字，插入当前焦点输入框。

## 当前状态

仓库初始化完成，尚未创建 Xcode 工程或实现功能。开发进度见 [PROGRESS.md](PROGRESS.md)。

## 技术栈与约束

- Swift 5.9，SwiftUI + AppKit。
- 菜单栏应用，设置 `LSUIElement`，不显示 Dock 图标。
- 音频录制：AVAudioEngine，16 kHz 单声道。
- 实时字幕：Apple Speech 本地流式识别，不承担正常路径的最终文本生成。
- 最终文本：通过 OpenRouter 音频模型一次完成识别与润色；失败时降级。
- OpenRouter 使用 OpenAI 兼容接口，base URL 为 `https://openrouter.ai/api/v1`。
- API key 仅从环境变量 `OPENROUTER_API_KEY` 或 macOS Keychain 读取，绝不硬编码或提交到 Git。不得在日志、历史或错误提示中泄露密钥。

## 模块边界

| 模块 | 职责 |
| --- | --- |
| `HotkeyMonitor` | 全局快捷键按下／松开事件 |
| `AudioRecorder` | AVAudioEngine 录音，输出 16 kHz 单声道音频 |
| `LiveTranscriber` | Apple Speech 本地流式识别，仅用于实时字幕 |
| `FinalTranscriber` | OpenRouter 音频模型，一次完成识别与润色；失败时降级 |
| `TextInserter` | 按顺序尝试 AX 插入、剪贴板粘贴、复制并提示 |
| `SessionStateMachine` | 唯一状态源，纯逻辑，可单元测试 |
| HUD / Onboarding / 设置 / 历史 | 浮窗反馈、初次使用引导、配置与会话历史 |

## 开发规则

每步保持小提交；每完成一步更新 `PROGRESS.md`。每次实际语音会话记录延迟指标，未测量的数据不得以估计值替代。

建议按会话记录以下时间点和耗时，在实现阶段统一指标定义：

- 按键按下、录音开始、首个实时字幕。
- 按键松开、录音结束、最终请求发出、最终文本返回。
- 插入完成或降级提示完成。
- 首字幕延迟、最终处理延迟、松键到文字落地延迟。
- 成功／失败／取消状态，以及采用的降级与插入方式。

延迟记录默认不包含原始音频、识别文本或密钥；录音与文本的留存策略需在实现阶段明确。

## 后续工作

首先创建可运行的 macOS 菜单栏工程和纯逻辑状态机测试，再逐步接入权限引导、快捷键、录音、字幕、最终转写与文本插入。模型选择、失败降级细节、最低 macOS 版本、默认快捷键和历史留存策略尚未确定。

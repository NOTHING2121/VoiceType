import CoreGraphics
import Foundation
@testable import VoiceTypeCore
@testable import VoiceTypeSystem

private func key(_ code: CGKeyCode, down: Bool, repeatKey: Bool = false) throws -> CGEvent {
    guard let event = CGEvent(keyboardEventSource: nil, virtualKey: code, keyDown: down) else {
        throw SystemCheckFailure(description: "cannot construct keyboard event")
    }
    event.setIntegerValueField(.keyboardEventAutorepeat, value: repeatKey ? 1 : 0)
    return event
}

// Ordinary parameter (not an autoclosure) so event construction errors propagate cleanly.
private func assertTap(_ returned: Unmanaged<CGEvent>?, passes: Bool) throws {
    try expect((returned != nil) == passes)
}

enum HotkeyTapCases {
    static let all: [SystemCase] = [
        SystemCase("空闲Esc经真实tap适配器透传且不发取消") {
            let monitor = SystemHotkeyMonitor()
            var count = 0; monitor.onEvent = { _ in count += 1 }
            try assertTap(monitor.handleTap(type: .keyDown, event: key(53, down: true)), passes: true)
            try assertTap(monitor.handleTap(type: .keyUp, event: key(53, down: false)), passes: true)
            try expect(count == 0)
        },
        SystemCase("tap消费活动Esc整次按压且只取消一次") {
            let monitor = SystemHotkeyMonitor(); var active = true; var count = 0
            monitor.isSessionActive = { active }
            monitor.onEvent = { event in if case .escape = event { count += 1; active = false } }
            try assertTap(monitor.handleTap(type: .keyDown, event: key(53, down: true)), passes: false)
            try assertTap(monitor.handleTap(type: .keyDown, event: key(53, down: true, repeatKey: true)), passes: false)
            try assertTap(monitor.handleTap(type: .keyUp, event: key(53, down: false)), passes: false)
            try expect(count == 1)
            try assertTap(monitor.handleTap(type: .keyDown, event: key(53, down: true)), passes: true)
        },
        SystemCase("tap不截获普通键或Option组合键") {
            let monitor = SystemHotkeyMonitor(); monitor.isSessionActive = { true }
            var count = 0; monitor.onEvent = { _ in count += 1 }
            for code: CGKeyCode in [0, 9, 36, 58, 61] {
                let event = try key(code, down: true); event.flags = .maskAlternate
                try assertTap(monitor.handleTap(type: .keyDown, event: event), passes: true)
                try assertTap(monitor.handleTap(type: .keyUp, event: key(code, down: false)), passes: true)
            }
            try expect(count == 0)
        },
        SystemCase("tap超时通知取消当前会话且可在之后自动重连") {
            let system = FakeSessionSystem(); system.start()
            let monitor = SystemHotkeyMonitor()
            monitor.onEvent = { system.coordinator.send($0, deferringSideEffects: true) }
            _ = monitor.handleTap(type: .tapDisabledByTimeout, event: try key(0, down: true))
            try expect(system.coordinator.machine.state == .cancelled && monitor.reconnectAutomatically)
            system.finish()
            try expect(system.audio.active.isEmpty && system.inserter.writes.isEmpty && system.metrics.sessions.last?.cancellation == .listenerLost)
            var installed = false; var installs = 0
            for _ in 0..<3 {
                HotkeyConnectionPolicy.refresh(trusted: true, installed: installed, automatically: monitor.reconnectAutomatically,
                                               install: { installs += 1; installed = true }, uninstall: {})
            }
            try expect(installs == 1, "超时之后走App同一安装路径一次，使用fake安装操作")
        },
        SystemCase("系统主动停用tap后不自动重连") {
            let monitor = SystemHotkeyMonitor(); var lost = 0
            monitor.onEvent = { if case .interrupted(.listenerLost) = $0 { lost += 1 } }
            _ = monitor.handleTap(type: .tapDisabledByUserInput, event: try key(0, down: true))
            try expect(lost == 1 && !monitor.reconnectAutomatically && !monitor.installedWhileTrusted)
            var installed = false; var installs = 0
            for _ in 0..<3 {
                HotkeyConnectionPolicy.refresh(trusted: true, installed: installed, automatically: monitor.reconnectAutomatically,
                                               install: { installs += 1; installed = true }, uninstall: {})
            }
            try expect(installs == 0, "停用后刷新不调用安装")
            HotkeyConnectionPolicy.restart(isIdle: true, install: { installs += 1; installed = true })
            try expect(installs == 1 && installed, "用户明确点击后才调用安装")
        },
        SystemCase("卸载清除Esc配对状态且不安装监听") {
            let monitor = SystemHotkeyMonitor(); monitor.isSessionActive = { true }
            try assertTap(monitor.handleTap(type: .keyDown, event: key(53, down: true)), passes: false)
            monitor.uninstall()
            try assertTap(monitor.handleTap(type: .keyUp, event: key(53, down: false)), passes: true)
            try expect(!monitor.installedWhileTrusted)
        },
    ]
}

import Foundation
@testable import VoiceTypeCore

enum EscapeCases {
    static let all: [RegressionCase] = [
        RegressionCase("空闲Esc的按下重复与松开全部透传") {
            var filter = EscapeKeyFilter()
            try check(filter.handle(keyCode: 53, isKeyDown: true, sessionActive: false) == .passThrough)
            try check(filter.handle(keyCode: 53, isKeyDown: true, isRepeat: true, sessionActive: false) == .passThrough)
            try check(filter.handle(keyCode: 53, isKeyDown: false, sessionActive: false) == .passThrough)
        },
        RegressionCase("活动Esc只请求一次取消并吞掉配对松开") {
            var filter = EscapeKeyFilter()
            try check(filter.handle(keyCode: 53, isKeyDown: true, sessionActive: true) == .consume(requestCancellation: true))
            try check(filter.handle(keyCode: 53, isKeyDown: true, isRepeat: true, sessionActive: false) == .consume(requestCancellation: false))
            try check(filter.handle(keyCode: 53, isKeyDown: false, sessionActive: false) == .consume(requestCancellation: false))
            try check(filter.handle(keyCode: 53, isKeyDown: true, sessionActive: false) == .passThrough)
        },
        RegressionCase("取消后重复keydown不二次取消也不泄漏") {
            var filter = EscapeKeyFilter()
            _ = filter.handle(keyCode: 53, isKeyDown: true, sessionActive: true)
            try check(filter.handle(keyCode: 53, isKeyDown: true, sessionActive: false) == .consume(requestCancellation: false))
        },
        RegressionCase("空闲按住Esc后开始听写不抢走此前按压") {
            var filter = EscapeKeyFilter()
            _ = filter.handle(keyCode: 53, isKeyDown: true, sessionActive: false)
            try check(filter.handle(keyCode: 53, isKeyDown: true, isRepeat: true, sessionActive: true) == .passThrough)
            try check(filter.handle(keyCode: 53, isKeyDown: false, sessionActive: true) == .passThrough)
        },
        RegressionCase("无配对Esc松开即使活动也透传") {
            var filter = EscapeKeyFilter()
            try check(filter.handle(keyCode: 53, isKeyDown: false, sessionActive: true) == .passThrough)
        },
        RegressionCase("普通键与Option组合键始终透传且不释放Esc所有权") {
            var filter = EscapeKeyFilter()
            _ = filter.handle(keyCode: 53, isKeyDown: true, sessionActive: true)
            for key: UInt16 in [0, 9, 36, 58, 61] {
                try check(filter.handle(keyCode: key, isKeyDown: true, sessionActive: true) == .passThrough)
                try check(filter.handle(keyCode: key, isKeyDown: false, sessionActive: false) == .passThrough)
            }
            try check(filter.handle(keyCode: 53, isKeyDown: false, sessionActive: false) == .consume(requestCancellation: false))
        },
        RegressionCase("配对松开后下一次听写可再次Esc取消") {
            var filter = EscapeKeyFilter()
            for _ in 0..<2 {
                try check(filter.handle(keyCode: 53, isKeyDown: true, sessionActive: true) == .consume(requestCancellation: true))
                try check(filter.handle(keyCode: 53, isKeyDown: false, sessionActive: false) == .consume(requestCancellation: false))
            }
        },
        RegressionCase("此前已消费的Esc长按不取消新会话") {
            var filter = EscapeKeyFilter()
            _ = filter.handle(keyCode: 53, isKeyDown: true, sessionActive: true)
            try check(filter.handle(keyCode: 53, isKeyDown: true, isRepeat: true, sessionActive: true) == .consume(requestCancellation: false))
        },
        RegressionCase("八状态只在四个活动状态消费新Esc") {
            let states: [SessionState] = [.idle, .recording, .finalizing, .processing, .inserting, .done, .error, .cancelled]
            for state in states {
                var filter = EscapeKeyFilter()
                let active = [.recording, .finalizing, .processing, .inserting].contains(state)
                try check(filter.handle(keyCode: 53, isKeyDown: true, sessionActive: active) == (active ? .consume(requestCancellation: true) : .passThrough), state.rawValue)
            }
        },
        RegressionCase("Esc过滤器与fake协调器串联取消且关麦无插入") {
            let system = FakeSessionSystem(); system.start()
            system.clock.advance(by: 100)
            var filter = EscapeKeyFilter()
            let decision = filter.handle(keyCode: 53, isKeyDown: true, sessionActive: system.coordinator.machine.isActive)
            try check(decision == .consume(requestCancellation: true))
            system.coordinator.send(.escape, deferringSideEffects: true)
            try check(system.coordinator.machine.state == .cancelled, "取消立即对所有模块可见")
            try check(filter.handle(keyCode: 53, isKeyDown: false, sessionActive: system.coordinator.machine.isActive) == .consume(requestCancellation: false))
            system.finish()
            try check(system.audio.active.isEmpty && system.inserter.writes.isEmpty)
            try check(system.metrics.sessions.count == 1 && system.metrics.sessions[0].cancellation == .escape)
        },
        RegressionCase("tap回调只改状态而延迟HUD系统副作用与观察回调") {
            let system = FakeSessionSystem(); system.start()
            let beforeHUD = system.hud.updates.count
            let beforeCancel = system.transcriber.cancelled.count
            var observed = 0
            system.coordinator.onAfterSend = { _ in observed += 1 }
            system.coordinator.send(.escape, deferringSideEffects: true)
            try check(system.coordinator.machine.state == .cancelled)
            try check(system.hud.updates.count == beforeHUD && system.transcriber.cancelled.count == beforeCancel && observed == 0)
            system.clock.advance(by: 0)
            try check(system.hud.updates.count > beforeHUD && system.audio.active.isEmpty && observed > 0)
        },
        RegressionCase("延迟启动紧接Esc会跳过尚未发出的录音识别") {
            let system = FakeSessionSystem()
            system.coordinator.send(.rightOptionDown(eligible: true), deferringSideEffects: true)
            system.coordinator.send(.escape, deferringSideEffects: true)
            try check(system.coordinator.machine.state == .cancelled && system.audio.starts.isEmpty)
            system.finish()
            try check(system.audio.starts.isEmpty && system.transcriber.starts.isEmpty && system.inserter.writes.isEmpty)
        },
        RegressionCase("tap失联取消优先于旧Option松开和迟到final") {
            let system = FakeSessionSystem(); system.start(); system.clock.advance(by: 400)
            system.coordinator.send(.interrupted(.listenerLost), deferringSideEffects: true)
            system.hotkeys.emit(.rightOptionUp)
            system.finish()
            try check(system.coordinator.machine.state == .cancelled && system.audio.active.isEmpty && system.inserter.writes.isEmpty)
            try check(system.metrics.sessions.last?.cancellation == .listenerLost)
        },
        RegressionCase("方案A缺快捷键权限禁止录音而非启动复制流程") {
            var environment = SessionEnvironment(); environment.hotkeyPermission = false
            let system = FakeSessionSystem(environment: environment); system.start(); system.finish()
            try check(system.coordinator.machine.state == .error && system.audio.starts.isEmpty && system.inserter.writes.isEmpty)
            try check(system.metrics.sessions.last?.failure == .permissionMissing)
        },
        RegressionCase("AX粘贴复制的prepare之后撤销授权均禁止提交") {
            for strategy: InsertionStrategy in [.ax, .paste, .copy] {
                var preferences = SessionPreferences(); preferences.allowPaste = strategy != .copy
                let system = FakeSessionSystem(preferences: preferences)
                system.inserter.axAvailable = strategy == .ax
                var environment = SessionEnvironment()
                system.coordinator.insertionPreflight = { environment }
                system.holdAndRelease(); system.clock.advance(to: 436)
                try check(system.coordinator.machine.state == .inserting && system.inserter.writes.isEmpty)
                environment.hotkeyPermission = false
                system.finish()
                try check(system.coordinator.machine.state == .error && system.inserter.writes.isEmpty)
                try check(system.metrics.sessions.last?.failure == .permissionMissing)
            }
        },
        RegressionCase("写入前复查权限正常不改变已成功主链路") {
            let system = FakeSessionSystem(); var preflights = 0
            system.coordinator.insertionPreflight = { preflights += 1; return SessionEnvironment() }
            system.holdAndRelease(); system.finish()
            try check(preflights == 1 && system.coordinator.machine.state == .done && system.inserter.writes.count == 1)
        },
        RegressionCase("已授权未就绪的首次检查执行一次安装") {
            var installed = false; var installs = 0; var removals = 0
            for _ in 0..<3 {
                HotkeyConnectionPolicy.refresh(trusted: true, installed: installed, automatically: true,
                                               install: { installs += 1; installed = true }, uninstall: { removals += 1 })
            }
            try check(installs == 1 && removals == 0)
        },
        RegressionCase("无辅助功能时仅卸载绝不自动安装") {
            var installs = 0; var removals = 0
            HotkeyConnectionPolicy.refresh(trusted: false, installed: true, automatically: true,
                                           install: { installs += 1 }, uninstall: { removals += 1 })
            try check(installs == 0 && removals == 1)
        },
        RegressionCase("系统主动停用后多次刷新不重连显式点击才安装") {
            var installed = false; var installs = 0
            for _ in 0..<3 {
                HotkeyConnectionPolicy.refresh(trusted: true, installed: installed, automatically: false,
                                               install: { installs += 1; installed = true }, uninstall: {})
            }
            try check(installs == 0)
            HotkeyConnectionPolicy.restart(isIdle: true, install: { installs += 1; installed = true })
            try check(installs == 1 && installed)
        },
        RegressionCase("活动会话中点击重连不会重启监听") {
            var installs = 0
            HotkeyConnectionPolicy.restart(isIdle: false, install: { installs += 1 })
            try check(installs == 0)
        },
    ]
}

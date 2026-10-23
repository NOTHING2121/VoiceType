import AppKit
import SwiftUI

@main
struct VoiceTypeApp: App {
    @NSApplicationDelegateAdaptor(VoiceTypeAppDelegate.self) private var appDelegate

    var body: some Scene {
        MenuBarExtra {
            Button("Quit VoiceType") {
                NSApplication.shared.terminate(nil)
            }
        } label: {
            Image(systemName: "waveform")
                .accessibilityLabel("VoiceType")
        }
        .menuBarExtraStyle(.menu)
    }
}

final class VoiceTypeAppDelegate: NSObject, NSApplicationDelegate {
    func applicationDidFinishLaunching(_ notification: Notification) {
        NSApplication.shared.setActivationPolicy(.accessory)
    }
}

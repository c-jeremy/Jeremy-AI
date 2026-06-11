//
//  Polarisapp.swift
//  Jeremy AI
//
//  Created by jeremy on 2026/6/11.
//


import SwiftUI
import EventKit

@main
struct PolarisApp: App {
    private let eventStore = EKEventStore()

    var body: some Scene {
        MenuBarExtra("Polaris", systemImage: "sparkles") {
            SpotlightView()
                .frame(width: 620)
                .onAppear { requestPermissions() }
        }
        .menuBarExtraStyle(.window)
    }

    // App 打开时就把权限弹窗触发出来，别等到用的时候
    private func requestPermissions() {
        // 临时切到foreground，让权限弹窗能正常出现
        NSApp.setActivationPolicy(.regular)
        NSApp.activate(ignoringOtherApps: true)
        
        DispatchQueue.main.asyncAfter(deadline: .now() + 0.3) {
            // 日历权限
            self.eventStore.requestAccess(to: .event) { _, _ in
                // 权限请求完了切回background
                DispatchQueue.main.async {
                    NSApp.setActivationPolicy(.accessory)
                }
            }
            // Notes AppleScript权限
            var err: NSDictionary?
            NSAppleScript(source: "tell application \"Notes\" to name")?.executeAndReturnError(&err)
        }
    }
}





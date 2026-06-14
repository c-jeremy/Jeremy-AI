//
//  Polarisapp.swift
//  Jeremy AI
//
//  Created by jeremy on 2026/6/11.
//

import SwiftUI
import AppKit


// MARK: - App Entry

@main
struct PolarisApp: App {
    @NSApplicationDelegateAdaptor(AppDelegate.self) var appDelegate

    var body: some Scene {
        // 窗口由 AppDelegate 手动管理，这里只保留一个空 Settings 场景让 app 能跑
        Settings { EmptyView() }
    }
}

// MARK: - 自定义 Panel（允许成为 key window，输入框才能获焦）

class FloatingPanel: NSPanel {
    override var canBecomeKey: Bool  { true }
    override var canBecomeMain: Bool { false }
}

// MARK: - App Delegate

class AppDelegate: NSObject, NSApplicationDelegate {
    private var panel: NSPanel?
    private var statusItem: NSStatusItem?
    private var globalMonitor: Any?
    private var localMonitor: Any?

    func applicationDidFinishLaunching(_ notification: Notification) {
        // 设为 accessory：不出现在 Dock，不抢菜单栏，第一次点击不会被激活过程吃掉
        NSApp.setActivationPolicy(.accessory)
        setupStatusItem()
        setupPanel()
        setupHotkey()
    }

    // MARK: Menu Bar 图标

    private func setupStatusItem() {
        statusItem = NSStatusBar.system.statusItem(withLength: NSStatusItem.variableLength)
        if let button = statusItem?.button {
            button.image = NSImage(systemSymbolName: "sparkles", accessibilityDescription: "Polaris")
            button.action = #selector(togglePanel)
            button.target = self
        }
    }

    // MARK: 透明浮动面板

    private func setupPanel() {
        let hosting = NSHostingView(rootView: SpotlightView(onDismiss: { [weak self] in
            self?.hidePanel()
        }))
        hosting.frame = NSRect(x: 0, y: 0, width: 640, height: 60)

        let panel = FloatingPanel(
            contentRect: NSRect(x: 0, y: 0, width: 640, height: 60),
            styleMask:   [.borderless, .fullSizeContentView],
            backing:     .buffered,
            defer:       false
        )
        panel.isOpaque          = false
        panel.backgroundColor   = .clear        // 彻底透明，Liquid Glass 才能折射桌面
        panel.hasShadow         = true
        panel.level             = .floating
        panel.collectionBehavior = [.canJoinAllSpaces, .fullScreenAuxiliary]
        panel.contentView       = hosting
        panel.isMovableByWindowBackground = true

        self.panel = panel
    }

    // MARK: 双击 ⌥ 全局快捷键

    private var lastOptionTapTime: Date?
    private var lastToggleTime: Date = .distantPast

    private func setupHotkey() {
        globalMonitor = NSEvent.addGlobalMonitorForEvents(matching: .flagsChanged) { [weak self] event in
            self?.handleFlagsChanged(event)
        }
        localMonitor = NSEvent.addLocalMonitorForEvents(matching: [.flagsChanged, .keyDown]) { [weak self] event in
            if event.type == .flagsChanged {
                self?.handleFlagsChanged(event)
            }
            if event.type == .keyDown, event.keyCode == 53 { // Escape
                DispatchQueue.main.async { self?.hidePanel() }
                return nil
            }
            return event
        }
    }

    private func handleFlagsChanged(_ event: NSEvent) {
        // 只看 ⌥ 单独按下（没有其他修饰键）
        guard event.modifierFlags.intersection(.deviceIndependentFlagsMask) == .option else {
            return
        }
        let now = Date()
        if let last = lastOptionTapTime, now.timeIntervalSince(last) < 0.35 {
            // 两次间隔 < 350ms，触发
            lastOptionTapTime = nil
            DispatchQueue.main.async { self.togglePanel() }
        } else {
            lastOptionTapTime = now
        }
    }

    // MARK: 显示 / 隐藏

    @objc func togglePanel() {
        let now = Date()
        guard now.timeIntervalSince(lastToggleTime) > 0.5 else { return }
        lastToggleTime = now

        if panel?.isVisible == true {
            hidePanel()
        } else {
            showPanel()
        }
    }

    private func showPanel() {
        guard let panel, let screen = NSScreen.main else { return }

        // 居中偏上，跟 Spotlight 位置类似
        let x = (screen.frame.width  - 640) / 2 + screen.frame.minX
        let y = screen.frame.height * 0.62  + screen.frame.minY
        panel.setFrameOrigin(NSPoint(x: x, y: y))

        panel.alphaValue = 0
        NSApp.activate(ignoringOtherApps: true) // make the app the active application so that it can be triggered
        panel.makeKeyAndOrderFront(nil)

        // 稍微延迟一下再设 first responder，确保 SwiftUI 已经完成布局
        DispatchQueue.main.asyncAfter(deadline: .now() + 0.05) {
            panel.makeFirstResponder(panel.contentView)
        }

        NSAnimationContext.runAnimationGroup { ctx in
            ctx.duration = 0.18
            panel.animator().alphaValue = 1
        }
    }

    func hidePanel() {
        guard let panel else { return }
        NSAnimationContext.runAnimationGroup({ ctx in
            ctx.duration = 0.14
            panel.animator().alphaValue = 0
        }, completionHandler: {
            panel.orderOut(nil)
        })
    }

    func applicationWillTerminate(_ notification: Notification) {
        if let m = globalMonitor { NSEvent.removeMonitor(m) }
        if let m = localMonitor  { NSEvent.removeMonitor(m) }
    }
}

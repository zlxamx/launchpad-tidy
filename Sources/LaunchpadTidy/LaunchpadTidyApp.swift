import SwiftUI
import AppKit
import LaunchpadCore

@main @MainActor struct LaunchpadTidyApp: App {
    @NSApplicationDelegateAdaptor(AppDelegate.self) private var delegate
    @StateObject private var store = Store()
    init() {
        if CommandLine.arguments.contains("--inspect") {
            do {
                let layout = try LaunchpadDatabase.load(LaunchpadDatabase.locate())
                let report: [String: Any] = ["system": ProcessInfo.processInfo.operatingSystemVersionString,
                    "visibleApps": layout.visibleApps.count, "pages": layout.pages.count,
                    "folders": layout.folders.count, "fingerprint": layout.fingerprint, "mode": "read-only"]
                let data = try JSONSerialization.data(withJSONObject: report, options: [.prettyPrinted, .sortedKeys])
                print(String(decoding: data, as: UTF8.self)); exit(0)
            } catch { fputs(error.localizedDescription + "\n", stderr); exit(1) }
        }
    }
    var body: some Scene {
        WindowGroup("启动台整理", id: "compact-main") {
            ContentView().environmentObject(store)
                .frame(minWidth: 560, minHeight: 400)
                .onAppear { delegate.store = store; if store.baseline == nil { store.load() }; NSApp.activate(ignoringOtherApps: true) }
        }
        .defaultSize(width: 680, height: 500)
        .commands {
            CommandGroup(replacing: .newItem) {}
            CommandGroup(after: .windowArrangement) {
                Button("紧凑窗口") {
                    guard let window = NSApp.mainWindow else { return }
                    window.setContentSize(NSSize(width: 680, height: 500))
                }.keyboardShortcut("0", modifiers: [.command, .shift])
            }
            CommandGroup(replacing: .undoRedo) {
                Button("撤销") {
                    if let editor = NSApp.keyWindow?.firstResponder as? NSTextView { editor.undoManager?.undo() }
                    else { store.undo() }
                }.keyboardShortcut("z").disabled(store.busy)
                Button("重做") {
                    if let editor = NSApp.keyWindow?.firstResponder as? NSTextView { editor.undoManager?.redo() }
                    else { store.redo() }
                }.keyboardShortcut("z", modifiers: [.command, .shift]).disabled(store.busy)
            }
            CommandGroup(after: .pasteboard) {
                Button("选择全部") {
                    if let editor = NSApp.keyWindow?.firstResponder as? NSTextView { editor.selectAll(nil) }
                    else { store.selected = Set(store.displayedApps.map(\.id)) }
                }.keyboardShortcut("a").disabled(store.busy)
                Button("搜索应用") { NotificationCenter.default.post(name: .tidyFocusSearch, object: nil) }.keyboardShortcut("f")
            }
        }
    }
}

@MainActor final class AppDelegate: NSObject, NSApplicationDelegate {
    weak var store: Store?
    func applicationShouldTerminate(_ sender: NSApplication) -> NSApplication.TerminateReply {
        if store?.aiWorking == true { store?.cancelAI(); return .terminateNow }
        if store?.busy == true { store?.status = "请等待当前读写完成，再退出软件"; return .terminateCancel }
        if store?.canQuitWithoutLosingDraft == true { return .terminateNow }
        guard store?.hasChanges == true else { return .terminateNow }
        let alert = NSAlert(); alert.messageText = "预览未能自动保存，仍要退出？"; alert.informativeText = "退出后可能丢失当前未应用的改动。"
        alert.addButton(withTitle: "继续整理"); alert.addButton(withTitle: "放弃并退出")
        return alert.runModal() == .alertSecondButtonReturn ? .terminateNow : .terminateCancel
    }
    func applicationShouldTerminateAfterLastWindowClosed(_ sender: NSApplication) -> Bool { true }
}

extension Notification.Name { static let tidyFocusSearch = Notification.Name("LaunchpadTidy.FocusSearch") }

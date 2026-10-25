import SwiftUI
import AppKit

private typealias FlashState = SwiftUI.State<FlashModel>
@main struct FrijaFlashApp: App {
    @FlashState private var model = FlashModel()
    @NSApplicationDelegateAdaptor(FlashDelegate.self) private var delegate
    var body: some Scene {
        Window("Frija Flash", id: "flash") {
            FlashView(model: model).frame(minWidth: 880, minHeight: 730)
                .onAppear {
                    delegate.model = model
                    NSApp.windows.first(where: { $0.title == "Frija Flash" })?.delegate = delegate
                }
        }.defaultSize(width: 980, height: 900)
        .commands {
            CommandGroup(replacing: .appInfo) {
                Button("About Frija Flash") {
                    NSApp.orderFrontStandardAboutPanel(options: [
                        .applicationName: "Frija Flash", .applicationVersion: "0.2.0 Experimental",
                        .credits: NSAttributedString(string: "Native macOS Samsung flashing companion.\nNot affiliated with Samsung or Odin.\nUSB protocol: samloader-odin 2.2.0 by John Wu,\nderived from Heimdall by Benjamin Dobell and Henrik Grimler.\nApache 2.0 / MIT notices are included with this app.\nNo physical-device flash has been validated for this release.")
                    ])
                }
            }
        }
    }
}
final class FlashDelegate: NSObject, NSApplicationDelegate, NSWindowDelegate {
    var model: FlashModel?
    func applicationDidFinishLaunching(_ notification: Notification) {
        NSApp.setActivationPolicy(.regular); NSApp.activate(ignoringOtherApps: true)
    }
    func applicationShouldTerminateAfterLastWindowClosed(_ sender: NSApplication) -> Bool { true }
    func applicationShouldTerminate(_ sender: NSApplication) -> NSApplication.TerminateReply {
        if model?.flashing == true { explain(); return .terminateCancel }
        model?.cancel(); return .terminateNow
    }
    func windowShouldClose(_ sender: NSWindow) -> Bool {
        if model?.flashing == true { explain(); return false }
        model?.cancel(); return true
    }
    private func explain() {
        let alert = NSAlert(); alert.messageText = "A flash is in progress"
        alert.informativeText = "Keep the app open and the USB cable connected until the operation finishes."
        alert.runModal()
    }
}

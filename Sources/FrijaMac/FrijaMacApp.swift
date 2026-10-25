import SwiftUI
import AppKit

// Explicit type alias selects the deployable State property wrapper on SDKs
// that also expose the newer State macro.
private typealias ModelState = SwiftUI.State<AppModel>

@main struct FrijaMacApp: App {
    @ModelState private var model = AppModel()
    @NSApplicationDelegateAdaptor(AppDelegate.self) private var delegate
    var body: some Scene {
        Window("Frija Mac", id: "main") {
            ContentView(model: model)
                .frame(minWidth: 850, minHeight: 690)
        }
        .defaultSize(width: 960, height: 780)
        .windowStyle(.titleBar)
        .commands {
            CommandGroup(replacing: .appInfo) {
                Button("About Frija Mac") {
                    NSApplication.shared.orderFrontStandardAboutPanel(options: [
                        .applicationName: "Frija Mac",
                        .applicationVersion: "0.1.0",
                        .version: "1",
                        .credits: NSAttributedString(string: "Independent native Samsung firmware downloader.\nInspired by Frija; not affiliated with Frija or Samsung.\nProtocol references: GNSF by Vladislav Tislenko (MIT),\nsamloader-rs by John Wu (Apache 2.0).\nLicenses and source are included with this build.")
                    ])
                }
            }
            CommandGroup(after: .newItem) {
                Button("Check Firmware", action: model.check).keyboardShortcut("r").disabled(!model.canCheck)
                Button("Choose Download Folder…", action: model.chooseFolder).keyboardShortcut("o").disabled(model.busy)
            }
        }
    }
}

final class AppDelegate: NSObject, NSApplicationDelegate {
    func applicationDidFinishLaunching(_ notification: Notification) {
        NSApplication.shared.setActivationPolicy(.regular)
        NSApplication.shared.activate(ignoringOtherApps: true)
    }
    func applicationShouldTerminateAfterLastWindowClosed(_ sender: NSApplication) -> Bool { true }
}

import SwiftUI
import FrijaCore

struct ContentView: View {
    @Bindable var model: AppModel
    private let accent = Color(red: 0.19, green: 0.43, blue: 0.87)

    var body: some View {
        HStack(spacing: 0) {
            sidebar.frame(width: 207)
            Divider()
            ScrollView {
                VStack(alignment: .leading, spacing: 23) {
                    header
                    deviceCard
                    if let firmware = model.firmware { firmwareCard(firmware) }
                    destination
                    statusCard
                    if let error = model.error {
                        Label(error, systemImage: "exclamationmark.triangle.fill")
                            .foregroundStyle(.red).font(.callout).textSelection(.enabled)
                            .padding(14).frame(maxWidth: .infinity, alignment: .leading)
                            .background(.red.opacity(0.07), in: RoundedRectangle(cornerRadius: 12))
                    }
                    log
                    Text("Firmware downloads only. Installing firmware requires a separate flashing tool.")
                        .font(.caption).foregroundStyle(.secondary)
                }.padding(30)
            }.background(Color(nsColor: .windowBackgroundColor))
        }
        .tint(accent)
        .onChange(of: model.model) { model.invalidate() }
        .onChange(of: model.region) { model.invalidate() }
        .onChange(of: model.version) { model.invalidate() }
        .onChange(of: model.manual) { model.invalidate() }
    }

    private var sidebar: some View {
        VStack(alignment: .leading, spacing: 24) {
            HStack(spacing: 10) {
                Image(systemName: "arrow.down.square.fill").font(.system(size: 30)).foregroundStyle(accent)
                VStack(alignment: .leading, spacing: 1) {
                    Text("Frija Mac").font(.headline)
                    Text("FIRMWARE UTILITY").font(.system(size: 8, weight: .semibold)).tracking(1.1).foregroundStyle(.secondary)
                }
            }.padding(.top, 15)
            Label("Firmware", systemImage: "shippingbox")
                .font(.system(size: 13, weight: .semibold)).foregroundStyle(accent)
                .padding(10).frame(maxWidth: .infinity, alignment: .leading)
                .background(accent.opacity(0.10), in: RoundedRectangle(cornerRadius: 8))
            VStack(alignment: .leading, spacing: 14) {
                Text("RECENT DEVICES").font(.system(size: 9, weight: .semibold)).tracking(1).foregroundStyle(.secondary)
                if model.recent.isEmpty {
                    Text("Devices you check will appear here.").font(.caption).foregroundStyle(.secondary).lineSpacing(3)
                }
                ForEach(model.recent) { device in
                    Button { model.select(device) } label: {
                        HStack(spacing: 9) {
                            Image(systemName: "iphone.gen3").foregroundStyle(.secondary)
                            VStack(alignment: .leading, spacing: 3) {
                                Text(device.model).font(.system(size: 12, weight: .medium))
                                Text(device.region).font(.system(size: 10)).foregroundStyle(.secondary)
                            }
                            Spacer()
                        }.contentShape(Rectangle())
                    }.buttonStyle(.plain).disabled(model.busy)
                }
            }
            Spacer(minLength: 40)
            VStack(alignment: .leading, spacing: 9) {
                Label("Direct from Samsung", systemImage: "externaldrive.badge.checkmark").font(.caption)
                Text("Independent macOS app\nVersion 0.2.0").font(.system(size: 10)).foregroundStyle(.tertiary).lineSpacing(3)
            }
        }.padding(19).background(.thinMaterial)
    }

    private var header: some View {
        HStack {
            VStack(alignment: .leading, spacing: 6) {
                Text("Samsung firmware").font(.system(size: 27, weight: .bold))
                Text("Find your build. Download it. Ready to go.").font(.callout).foregroundStyle(.secondary)
            }
            Spacer()
            Button("Open Frija Flash") {
                let sibling = Bundle.main.bundleURL.deletingLastPathComponent().appendingPathComponent("Frija Flash.app")
                if FileManager.default.fileExists(atPath: sibling.path) { NSWorkspace.shared.open(sibling) }
                else if let installed = NSWorkspace.shared.urlForApplication(withBundleIdentifier: "local.frijaflash.app") { NSWorkspace.shared.open(installed) }
                else {
                    let alert = NSAlert(); alert.messageText = "Install Frija Flash alongside Frija Mac"
                    alert.informativeText = "Both apps are included in the experimental Mac suite. Extract downloaded firmware before importing its folder into Frija Flash."
                    alert.runModal()
                }
            }
        }
    }

    private var deviceCard: some View {
        VStack(alignment: .leading, spacing: 18) {
            HStack {
                Label("Device details", systemImage: "iphone.gen3").font(.headline)
                Spacer()
                Picker("Lookup mode", selection: $model.manual) {
                    Text("Latest").tag(false)
                    Text("Manual").tag(true)
                }.pickerStyle(.segmented).frame(width: 165).labelsHidden().disabled(model.busy)
            }
            HStack(alignment: .top, spacing: 16) {
                VStack(alignment: .leading, spacing: 7) {
                    Text("Model number").font(.system(size: 12, weight: .medium))
                    TextField("e.g. SM-S928B", text: $model.model).textFieldStyle(.roundedBorder)
                        .accessibilityIdentifier("modelField")
                    Text("Settings → About phone").font(.caption2).foregroundStyle(.secondary)
                }.frame(maxWidth: .infinity)
                VStack(alignment: .leading, spacing: 7) {
                    Text("CSC / region").font(.system(size: 12, weight: .medium))
                    TextField("e.g. EUX", text: $model.region).textFieldStyle(.roundedBorder)
                        .accessibilityIdentifier("regionField")
                    Text("Your device’s sales code").font(.caption2).foregroundStyle(.secondary)
                }.frame(width: 155)
            }.disabled(model.busy)
            if model.manual {
                VStack(alignment: .leading, spacing: 7) {
                    Text("Full firmware version").font(.system(size: 12, weight: .medium))
                    TextField("PDA/CSC/MODEM or PDA/CSC/MODEM/PDA", text: $model.version).textFieldStyle(.roundedBorder)
                        .font(.system(size: 11, design: .monospaced)).disabled(model.busy)
                    Text("Samsung may no longer serve an older build.").font(.caption2).foregroundStyle(.secondary)
                }
            }
            HStack {
                Text("No IMEI or serial number needed.").font(.caption).foregroundStyle(.secondary)
                Spacer()
                Button(action: model.check) {
                    Label(model.checking ? "Checking…" : "Check firmware", systemImage: "magnifyingglass")
                }.buttonStyle(.borderedProminent).disabled(!model.canCheck).keyboardShortcut(.return, modifiers: [])
            }
        }.padding(20).card()
    }

    private func firmwareCard(_ firmware: Firmware) -> some View {
        VStack(alignment: .leading, spacing: 14) {
            HStack {
                Label("Available firmware", systemImage: "checkmark.circle.fill").foregroundStyle(.green).font(.headline)
                Spacer()
                Text(firmware.displaySize).font(.system(size: 12, weight: .medium, design: .monospaced)).foregroundStyle(.secondary)
            }
            VStack(spacing: 10) {
                detail("PDA", firmware.pda)
                detail("CSC", firmware.csc)
                detail("Modem", firmware.modem)
            }
            Divider()
            Text(firmware.filename).font(.system(size: 10, design: .monospaced)).foregroundStyle(.secondary).textSelection(.enabled)
        }.padding(20).card()
    }
    private func detail(_ title: String, _ text: String) -> some View {
        HStack {
            Text(title).font(.caption).foregroundStyle(.secondary).frame(width: 55, alignment: .leading)
            Text(text).font(.system(size: 11, weight: .medium, design: .monospaced)).textSelection(.enabled)
            Spacer(minLength: 0)
        }
    }
    private var destination: some View {
        HStack(spacing: 12) {
            Image(systemName: "folder").font(.title3).foregroundStyle(accent)
            VStack(alignment: .leading, spacing: 3) {
                Text("Download location").font(.system(size: 12, weight: .medium))
                Text(model.destination?.path ?? "Choose a folder when you download")
                    .font(.caption).foregroundStyle(.secondary).lineLimit(1).truncationMode(.middle)
            }
            Spacer()
            Button("Choose…", action: model.chooseFolder).disabled(model.busy)
        }
    }
    private var statusCard: some View {
        VStack(alignment: .leading, spacing: 13) {
            HStack {
                VStack(alignment: .leading, spacing: 5) {
                    Text(model.phaseTitle).font(.system(size: 14, weight: .semibold))
                    Text(model.message).font(.caption).foregroundStyle(.secondary).fixedSize(horizontal: false, vertical: true)
                }
                Spacer(minLength: 14)
                if model.busy {
                    Button(model.checking ? "Cancel" : "Pause", action: model.pause)
                } else if model.output != nil {
                    Button("Show in Finder", action: model.reveal).buttonStyle(.borderedProminent)
                } else {
                    Button(action: model.download) {
                        Label(model.paused ? "Resume download" : "Download", systemImage: "arrow.down")
                    }.buttonStyle(.borderedProminent).disabled(model.firmware == nil)
                }
            }
            if model.checking || model.progress?.phase == .verifying {
                if model.busy { ProgressView().progressViewStyle(.linear) }
            } else if let progress = model.progress {
                ProgressView(value: progress.fraction).progressViewStyle(.linear)
                HStack {
                    Text(progress.phase == .decrypting ? "Decrypting" : "\(ByteCountFormatter.string(fromByteCount: progress.completed, countStyle: .file)) of \(ByteCountFormatter.string(fromByteCount: progress.total, countStyle: .file))")
                    Spacer()
                    Text("\(Int(progress.fraction * 100))%")
                }.font(.caption2).foregroundStyle(.secondary).monospacedDigit()
            } else {
                HStack(spacing: 16) {
                    Label("Resume support", systemImage: "arrow.clockwise")
                    Label("Auto decryption", systemImage: "lock.open")
                    Label("ZIP verification", systemImage: "checkmark.shield")
                }.font(.system(size: 10)).foregroundStyle(.secondary).padding(.top, 2)
            }
        }.padding(20).background(accent.opacity(0.055), in: RoundedRectangle(cornerRadius: 13))
    }
    private var log: some View {
        DisclosureGroup("Activity log", isExpanded: $model.showLog) {
            VStack(alignment: .leading, spacing: 10) {
                Text(model.logs.isEmpty ? "No activity yet." : model.logs.joined(separator: "\n"))
                    .font(.system(size: 10, design: .monospaced)).textSelection(.enabled).frame(maxWidth: .infinity, alignment: .leading)
                Button("Copy log", action: model.copyLog).disabled(model.logs.isEmpty)
            }.padding(.top, 10)
        }.font(.caption).foregroundStyle(.secondary)
    }
}

private extension View {
    func card() -> some View {
        background(Color(nsColor: .controlBackgroundColor), in: RoundedRectangle(cornerRadius: 13))
            .overlay(RoundedRectangle(cornerRadius: 13).strokeBorder(.primary.opacity(0.055)))
    }
}

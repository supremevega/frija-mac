import SwiftUI
import FrijaCore

struct FlashView: View {
    @Bindable var model: FlashModel
    private let accent = Color(red: 0.21, green: 0.44, blue: 0.86)
    var body: some View {
        ScrollView {
            VStack(alignment: .leading, spacing: 20) {
                HStack {
                    Image(systemName: "cable.connector").font(.system(size: 33)).foregroundStyle(accent)
                    VStack(alignment: .leading, spacing: 5) {
                        Text("Frija Flash").font(.system(size: 28, weight: .bold))
                        Text("Native Samsung firmware flashing for Mac").foregroundStyle(.secondary).font(.callout)
                    }
                    Spacer()
                    Text("EXPERIMENTAL").font(.system(size: 10, weight: .semibold)).tracking(1)
                        .foregroundStyle(.orange).padding(9).background(.orange.opacity(0.1), in: Capsule())
                }
                Text("Hardware flashing has not yet been verified on a physical device. Detection and package validation do not write firmware.")
                    .font(.caption).foregroundStyle(.secondary)
                device
                packages
                status
                if let error = model.error {
                    Label(error, systemImage: "exclamationmark.triangle.fill").font(.callout).foregroundStyle(.red)
                        .textSelection(.enabled).padding(14).frame(maxWidth: .infinity, alignment: .leading)
                        .background(.red.opacity(0.07), in: RoundedRectangle(cornerRadius: 12))
                }
                VStack(alignment: .leading, spacing: 9) {
                    HStack {
                        Text("Activity").font(.headline)
                        Spacer()
                        Button("Copy log", action: model.copyLog).disabled(model.logs.isEmpty)
                    }
                    ScrollView {
                        Text(model.logs.isEmpty ? "No activity yet." : model.logs.joined(separator: "\n"))
                            .font(.system(size: 11, design: .monospaced)).textSelection(.enabled)
                            .frame(maxWidth: .infinity, alignment: .leading).padding(12)
                    }.frame(height: 135).background(.quaternary.opacity(0.35), in: RoundedRectangle(cornerRadius: 9))
                }
                Text("Package PIT files are ignored. Partition size checks stay enabled. No NAND erase or forced sales-code command is sent.")
                    .font(.caption2).foregroundStyle(.secondary)
            }.padding(28)
        }.tint(accent)
        .onChange(of: model.targetModel) { model.invalidate() }
        .onChange(of: model.mode) { model.invalidate() }
        .sheet(isPresented: $model.showConfirmation) { confirmation }
    }
    private var device: some View {
        VStack(alignment: .leading, spacing: 15) {
            HStack {
                Label("Connected device", systemImage: "iphone.gen3").font(.headline)
                Spacer()
                Button("Detect device", action: model.detect).disabled(model.busy)
            }
            if let device = model.device {
                HStack(spacing: 30) {
                    field("MODEL", device.model)
                    field("CSC", device.csc.isEmpty ? "Unavailable" : device.csc)
                    field("BOOTLOADER", device.bootloader)
                    Spacer(minLength: 0)
                }
            } else {
                Text("Put the phone in Download Mode, connect it directly by USB, then select Detect device.")
                    .font(.callout).foregroundStyle(.secondary)
            }
            Divider()
            HStack(spacing: 20) {
                VStack(alignment: .leading, spacing: 7) {
                    Text("Flashing mode").font(.caption)
                    Picker("Flashing mode", selection: $model.mode) {
                        ForEach(FlashMode.allCases, id: \.self) { Text($0.title).tag($0) }
                    }.pickerStyle(.segmented).labelsHidden().frame(width: 315)
                }
                VStack(alignment: .leading, spacing: 7) {
                    Text("Firmware target model").font(.caption)
                    TextField("e.g. SM-F776U1", text: $model.targetModel).textFieldStyle(.roundedBorder)
                        .accessibilityIdentifier("flashTargetModel")
                }
            }.disabled(model.busy)
            if model.mode == .conversion {
                Text("For your VZW → XAA workflow, download the corresponding U1 / XAA firmware in Frija Mac. This mode permits the matching U/U1 model pair; device-side restrictions still apply.")
                    .font(.caption).foregroundStyle(.secondary)
            }
        }.padding(20).flashCard()
    }
    private func field(_ title: String, _ value: String) -> some View {
        VStack(alignment: .leading, spacing: 5) {
            Text(title).font(.system(size: 9, weight: .medium)).tracking(0.7).foregroundStyle(.secondary)
            Text(value).font(.system(size: 12, weight: .medium, design: .monospaced)).textSelection(.enabled)
        }
    }
    private var packages: some View {
        VStack(alignment: .leading, spacing: 14) {
            HStack {
                Label("Firmware packages", systemImage: "shippingbox").font(.headline)
                Spacer()
                Button("Import folder…", action: model.importFolder).disabled(model.busy)
            }
            Text("Extract the ZIP downloaded by Frija Mac, then select all four original .tar.md5 files.")
                .font(.caption).foregroundStyle(.secondary)
            ForEach(FlashSlot.allCases, id: \.self) { slot in
                HStack(spacing: 12) {
                    Text(slot.rawValue).font(.system(size: 12, weight: .semibold, design: .monospaced)).frame(width: 40, alignment: .leading)
                    Text(model.files[slot]?.lastPathComponent ?? (slot == .CSC ? "Choose CSC or HOME_CSC package" : "No package selected"))
                        .font(.system(size: 11, design: .monospaced)).lineLimit(1).truncationMode(.middle)
                        .foregroundStyle(model.files[slot] == nil ? .secondary : .primary)
                        .frame(maxWidth: .infinity, alignment: .leading)
                    if model.inspection?.packages.contains(where: { $0.slot == slot }) == true {
                        Image(systemName: "checkmark.circle.fill").foregroundStyle(.green).help("MD5 and archive structure verified")
                    }
                    Button("Choose…") { model.choose(slot) }.disabled(model.busy)
                }.padding(.vertical, 3)
            }
            if let csc = model.files[.CSC] {
                Label(csc.lastPathComponent.hasPrefix("HOME_CSC_") ? "HOME_CSC selected. Data preservation is not guaranteed during a conversion." : "CSC selected. This package may factory-reset the phone and erase user data.",
                      systemImage: "externaldrive.badge.exclamationmark")
                    .font(.caption).foregroundStyle(.orange)
            }
        }.padding(20).flashCard()
    }
    private var status: some View {
        VStack(alignment: .leading, spacing: 12) {
            Text(model.status).font(.system(size: 13, weight: .medium)).textSelection(.enabled)
            if model.busy {
                if let progress = model.progress { ProgressView(value: progress) }
                else { ProgressView().progressViewStyle(.linear) }
                if model.flashing { Text("Keep USB connected. Closing and quitting are disabled while the flash runs.").font(.caption).foregroundStyle(.orange) }
            }
            if model.inspection != nil, let reason = model.eligibilityError, !model.busy {
                Text(reason).font(.caption).foregroundStyle(.secondary)
            }
            HStack {
                Button("Validate packages", action: model.validate).disabled(!model.readyToValidate)
                if model.busy && !model.flashing { Button("Cancel", action: model.cancel) }
                Spacer()
                Button("Review flash…") { model.confirmation = ""; model.showConfirmation = true }
                    .buttonStyle(.borderedProminent).disabled(!model.readyToFlash)
            }
        }.padding(20).background(accent.opacity(0.065), in: RoundedRectangle(cornerRadius: 13))
    }
    private var confirmation: some View {
        VStack(alignment: .leading, spacing: 18) {
            Text("Review before writing firmware").font(.title2.bold())
            Text("\(model.device?.model ?? "") / \(model.device?.csc ?? "") → \(model.targetModel.uppercased())")
                .font(.system(size: 15, weight: .semibold, design: .monospaced))
            Text("Mode: \(model.mode.title)").font(.callout)
            ForEach(FlashSlot.allCases, id: \.self) { slot in
                Text("\(slot.rawValue): \(model.files[slot]?.lastPathComponent ?? "Missing")")
                    .font(.system(size: 11, design: .monospaced)).lineLimit(2)
            }
            Text("Flashing can erase data or leave the phone unbootable if interrupted or incompatible. Back up the phone and keep USB connected. This experimental app has not completed a physical-device flash test.")
                .font(.callout).foregroundStyle(.orange)
            Text("Type \(model.confirmationPhrase) to enable Start flash.").font(.callout)
            TextField(model.confirmationPhrase, text: $model.confirmation).textFieldStyle(.roundedBorder)
                .accessibilityIdentifier("flashConfirmation")
            HStack {
                Button("Cancel") { model.showConfirmation = false }.keyboardShortcut(.cancelAction)
                Spacer()
                Button("Start flash", role: .destructive, action: model.beginFlash)
                    .buttonStyle(.borderedProminent).tint(.red)
                    .disabled(model.confirmation != model.confirmationPhrase || !model.readyToFlash)
            }
        }.padding(28).frame(width: 650)
    }
}
private extension View {
    func flashCard() -> some View {
        background(Color(nsColor: .controlBackgroundColor), in: RoundedRectangle(cornerRadius: 13))
            .overlay(RoundedRectangle(cornerRadius: 13).strokeBorder(.primary.opacity(0.06)))
    }
}

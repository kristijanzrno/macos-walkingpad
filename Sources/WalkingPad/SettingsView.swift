import ServiceManagement
import SwiftUI

struct SettingsView: View {
    var pad: Pad

    @AppStorage(Settings.Key.barLabel) private var barLabel = "speed"
    @AppStorage(Settings.Key.maxSpeed) private var maxSpeed = 6.0
    @AppStorage(Settings.Key.speedStep) private var speedStep = 0.5
    @AppStorage(Settings.Key.startSpeed) private var startSpeed = "2.0"
    @AppStorage(Settings.Key.autoConnect) private var autoConnect = true
    @State private var launchAtLogin = SMAppService.mainApp.status == .enabled

    var body: some View {
        Form {
            Section {
                Picker("Menu bar label while walking", selection: $barLabel) {
                    Text("Speed").tag("speed")
                    Text("Session steps").tag("steps")
                    Text("Today's steps").tag("today")
                    Text("Icon only").tag("icon")
                }
            }

            Section {
                Picker("Maximum speed", selection: $maxSpeed) {
                    ForEach([6.0, 8.0, 10.0], id: \.self) { Text("\(Int($0)) km/h").tag($0) }
                }
                Picker("Speed step", selection: $speedStep) {
                    ForEach([0.1, 0.2, 0.5, 1.0], id: \.self) { Text(String(format: "%.1f km/h", $0)).tag($0) }
                }
                Picker("Speed after starting", selection: $startSpeed) {
                    Text("Keep pad's speed").tag("keep")
                    ForEach(["1.0", "2.0", "3.0", "4.0"], id: \.self) { Text("\($0) km/h").tag($0) }
                }
            } header: {
                Text("Belt")
            } footer: {
                Text("The R1 Pro walks up to 6 km/h; with the handrail raised it runs up to 10 km/h. The start speed is applied once the belt's 3-second countdown finishes.")
                    .foregroundStyle(.secondary)
            }

            Section {
                Toggle("Connect automatically", isOn: $autoConnect)
                    .onChange(of: autoConnect) { pad.settingsChanged() }
                Toggle("Open at login", isOn: $launchAtLogin)
                    .onChange(of: launchAtLogin) { _, on in
                        do {
                            if on { try SMAppService.mainApp.register() } else { try SMAppService.mainApp.unregister() }
                        } catch {
                            launchAtLogin = SMAppService.mainApp.status == .enabled
                        }
                    }
            } header: {
                Text("General")
            } footer: {
                Text("While connected, the KS Fit phone app can't reach the pad. Turn off automatic connection to connect only from the menu bar.")
                    .foregroundStyle(.secondary)
            }

            Section("WalkingPad") {
                LabeledContent("Name", value: pad.deviceName.isEmpty ? "None yet" : pad.deviceName)
                LabeledContent("Status", value: pad.statusText)
                if pad.deviceID != nil {
                    HStack {
                        Spacer()
                        Button("Forget This WalkingPad", role: .destructive) { pad.forget() }
                    }
                }
            }
        }
        .formStyle(.grouped)
        .frame(width: 460)
        .fixedSize(horizontal: false, vertical: true)
    }
}

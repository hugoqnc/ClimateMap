import SwiftUI
import UIKit

struct SettingsScreen: View {
    @Environment(\.dismiss) private var dismiss
    @Environment(\.openURL) private var openURL
    @Bindable var model: HomeModel

    var body: some View {
        NavigationStack {
            List {
                Section {
                    NavigationLink {
                        PowerControlSelectionScreen(model: model)
                    } label: {
                        LabeledContent {
                            Text(selectedPowerSourceName)
                                .foregroundStyle(.secondary)
                                .lineLimit(1)
                        } label: {
                            Label("Power control", systemImage: "power")
                        }
                    }
                } header: {
                    Text("Climate")
                } footer: {
                    Text("Only Power uses the selected Apple Home switch. Temperature, ventilation, modes, and air direction continue through SwitchBot.")
                }

                Section("Apple Home") {
                    LabeledContent {
                        Text(model.appleHomeAccessState.title)
                            .foregroundStyle(.secondary)
                    } label: {
                        Label("Home access", systemImage: model.appleHomeAccessState.symbol)
                    }

                    if model.appleHomeAccessState.isAuthorized {
                        LabeledContent("Available switches") {
                            Text("\(model.appleHomePowerSwitches.count)")
                                .foregroundStyle(.secondary)
                        }
                    } else if model.appleHomeAccessState == .denied
                                || model.appleHomeAccessState == .restricted {
                        Button("Open ClimateMap Settings", systemImage: "gear") {
                            guard let settingsURL = URL(string: UIApplication.openSettingsURLString) else { return }
                            openURL(settingsURL)
                        }
                    }
                }
            }
            .navigationTitle("Settings")
            .navigationBarTitleDisplayMode(.inline)
            .toolbar {
                ToolbarItem(placement: .confirmationAction) {
                    Button("Done") { dismiss() }
                }
            }
        }
    }

    private var selectedPowerSourceName: String {
        model.state.homePowerSwitchName ?? "SwitchBot API"
    }
}

private struct PowerControlSelectionScreen: View {
    @Bindable var model: HomeModel

    var body: some View {
        List {
            Section {
                powerSourceRow(
                    title: "SwitchBot API",
                    subtitle: "No Apple Home override",
                    symbol: "network",
                    isSelected: model.state.homePowerSwitchID == nil
                ) {
                    model.setHomePowerSwitch(nil)
                }
            }

            Section("Apple Home switches") {
                if !model.appleHomeAccessState.isAuthorized {
                    ContentUnavailableView(
                        "Home Access Required",
                        systemImage: model.appleHomeAccessState.symbol,
                        description: Text(model.appleHomeAccessState.title)
                    )
                } else if model.appleHomePowerSwitches.isEmpty {
                    ContentUnavailableView(
                        "No Switches Found",
                        systemImage: "switch.2",
                        description: Text("Add a switch or outlet to Apple Home, then refresh.")
                    )
                } else {
                    ForEach(model.appleHomePowerSwitches) { powerSwitch in
                        powerSourceRow(
                            title: powerSwitch.name,
                            subtitle: switchSubtitle(powerSwitch),
                            symbol: "homekit",
                            isSelected: model.state.homePowerSwitchID == powerSwitch.id,
                            isEnabled: powerSwitch.isReachable
                        ) {
                            model.setHomePowerSwitch(powerSwitch)
                        }
                    }
                }
            }
        }
        .navigationTitle("Power Control")
        .navigationBarTitleDisplayMode(.inline)
        .task { await model.refreshAppleHomePowerSwitches() }
        .refreshable { await model.refreshAppleHomePowerSwitches() }
    }

    private func powerSourceRow(
        title: String,
        subtitle: String,
        symbol: String,
        isSelected: Bool,
        isEnabled: Bool = true,
        action: @escaping () -> Void
    ) -> some View {
        Button(action: action) {
            HStack(spacing: 12) {
                Image(systemName: symbol)
                    .foregroundStyle(isSelected ? Color.accentColor : Color.secondary)
                    .frame(width: 24)

                VStack(alignment: .leading, spacing: 3) {
                    Text(title)
                        .foregroundStyle(.primary)
                    Text(subtitle)
                        .font(.caption)
                        .foregroundStyle(.secondary)
                }

                Spacer()

                if isSelected {
                    Image(systemName: "checkmark")
                        .font(.body.weight(.semibold))
                        .foregroundStyle(Color.accentColor)
                }
            }
            .contentShape(Rectangle())
        }
        .buttonStyle(.plain)
        .disabled(!isEnabled)
        .opacity(isEnabled ? 1 : 0.5)
    }

    private func switchSubtitle(_ powerSwitch: AppleHomePowerSwitch) -> String {
        let state = powerSwitch.isReachable ? (powerSwitch.isOn ? "On" : "Off") : "Unavailable"
        guard let roomName = powerSwitch.roomName, !roomName.isEmpty else { return state }
        return "\(roomName) · \(state)"
    }
}

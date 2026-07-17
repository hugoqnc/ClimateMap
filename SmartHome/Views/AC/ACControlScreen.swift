import SwiftUI

struct ACControlScreen: View {
    @Bindable var model: HomeModel

    var body: some View {
        NavigationStack {
            ScrollView {
                VStack(spacing: 18) {
                    statusHeader

                    VStack(spacing: 0) {
                        TemperatureDial(
                            temperature: model.state.ac.targetTemperature,
                            isDisabled: !temperatureControlsEnabled,
                            isLoading: isAdjustingTemperature
                        ) { target in
                            Task { await model.setTargetTemperature(target) }
                        }
                        .opacity(temperatureControlsEnabled || isAdjustingTemperature ? 1 : 0.46)
                        .padding(.top, 10)

                        Divider().opacity(0.45)

                        HStack(spacing: 12) {
                            VStack(alignment: .leading, spacing: 3) {
                                Text("ROOM TEMPERATURE")
                                    .font(.caption2.weight(.bold))
                                    .tracking(1.2)
                                    .foregroundStyle(.secondary)
                                if linkedMeterIsLoading {
                                    ProgressView()
                                        .controlSize(.small)
                                        .frame(height: 29)
                                } else {
                                    Text("\(model.linkedMeter?.temperature.formatted(.number.precision(.fractionLength(1))) ?? "—")°C")
                                        .font(.title2.weight(.semibold))
                                        .foregroundStyle(roomTemperatureTint)
                                }
                                Text(roomTemperatureContext)
                                    .font(.caption.weight(.medium))
                                    .foregroundStyle(roomTemperatureTint.opacity(0.86))
                            }
                            Spacer(minLength: 8)
                            linkedMeterMenu
                        }
                        .padding(.horizontal, 20)
                        .padding(.vertical, 16)
                    }
                    .smartHomeGlass(cornerRadius: 32)

                    VStack(spacing: 0) {
                        controlToggle(
                            title: "Power",
                            subtitle: model.state.ac.isOn ? "Cooling enabled" : "Appliance off",
                            symbol: "power",
                            tint: .green,
                            isOn: model.state.ac.isOn,
                            isEnabled: !model.isSendingCommand
                        ) { newValue in
                            Task { await model.setPower(newValue) }
                        }

                        controlDivider

                        controlToggle(
                            title: "Silence",
                            subtitle: "Quieter operation",
                            symbol: "speaker.wave.1.fill",
                            tint: .indigo,
                            isOn: model.state.ac.silence,
                            isEnabled: modeControlsEnabled
                        ) { newValue in
                            Task { await model.setSilence(newValue) }
                        }

                        controlDivider

                        controlToggle(
                            title: "Eco",
                            subtitle: "Lower energy use",
                            symbol: "leaf.fill",
                            tint: .green,
                            isOn: model.state.ac.eco,
                            isEnabled: model.state.ac.isOn && !model.isSendingCommand
                        ) { newValue in
                            Task { await model.setEco(newValue) }
                        }
                    }
                    .padding(.horizontal, 14)
                    .padding(.vertical, 7)
                    .smartHomeGlass(cornerRadius: 28)

                    selectionCard(
                        title: "Ventilation",
                        symbol: "wind",
                        selection: fanBinding,
                        values: FanLevel.allCases,
                        label: \FanLevel.title,
                        isEnabled: ventilationControlsEnabled
                    )

                    selectionCard(
                        title: "Oscillation",
                        symbol: "arrow.left.and.right",
                        selection: oscillationBinding,
                        values: OscillationMode.allCases,
                        label: \OscillationMode.title,
                        isEnabled: modeControlsEnabled
                    )

                    if let activity = model.commandActivity {
                        HStack(spacing: 10) {
                            ProgressView()
                                .controlSize(.small)
                            Text(activity)
                        }
                        .font(.footnote.weight(.medium))
                        .foregroundStyle(.secondary)
                        .transition(.opacity.combined(with: .move(edge: .bottom)))
                    }
                }
                .padding(.horizontal, 16)
                .padding(.bottom, 30)
                .animation(.smooth(duration: 0.25), value: model.state.ac.isOn)
                .animation(.smooth(duration: 0.25), value: model.state.ac.eco)
                .animation(.smooth(duration: 0.2), value: model.commandActivity)
            }
            .background {
                LinearGradient(
                    colors: [Color.cyan.opacity(0.12), Color(.systemBackground), Color.indigo.opacity(0.07)],
                    startPoint: .topLeading,
                    endPoint: .bottomTrailing
                )
                .ignoresSafeArea()
            }
            .navigationTitle("Climate")
            .navigationBarTitleDisplayMode(.large)
            .refreshable { await model.refresh() }
        }
    }

    private var temperatureControlsEnabled: Bool {
        model.state.ac.isOn && !model.state.ac.eco && !model.isSendingCommand
    }

    private var modeControlsEnabled: Bool {
        model.state.ac.isOn && !model.state.ac.eco && !model.isSendingCommand
    }

    private var ventilationControlsEnabled: Bool {
        modeControlsEnabled && !model.state.ac.silence
    }

    private var isAdjustingTemperature: Bool {
        model.commandActivity?.hasPrefix("Setting ") == true
    }

    private var statusHeader: some View {
        HStack(spacing: 15) {
            Image(systemName: "snowflake")
                .font(.system(size: 31, weight: .medium))
                .foregroundStyle(model.state.ac.isOn ? .cyan : .secondary)
                .symbolEffect(.rotate, options: .repeating.speed(0.15), isActive: model.state.ac.isOn)
                .frame(width: 58, height: 58)
                .glassEffect(.regular.tint(model.state.ac.isOn ? .cyan.opacity(0.2) : nil), in: .circle)

            VStack(alignment: .leading, spacing: 3) {
                Text(model.state.ac.isOn ? "Cooling" : "Off")
                    .font(.title3.weight(.semibold))
                Text(statusDetail)
                    .font(.subheadline)
                    .foregroundStyle(.secondary)
            }
            Spacer()
        }
    }

    private var statusDetail: String {
        guard model.state.ac.isOn else { return "Climate controls paused" }
        if model.state.ac.eco { return "Eco mode" }
        if model.state.ac.silence {
            return "Silence mode · Target \(model.state.ac.targetTemperature)°"
        }
        return "\(model.state.ac.fanLevel.title) fan · Target \(model.state.ac.targetTemperature)°"
    }

    private var roomTemperatureTint: Color {
        guard !linkedMeterIsLoading else { return .secondary }
        guard let roomTemperature = model.linkedMeter?.temperature else { return .secondary }
        let delta = roomTemperature - Double(model.state.ac.targetTemperature)
        let warmth = min(max((delta + 0.25) / 3.5, 0), 1)
        let cool = (red: 0.20, green: 0.49, blue: 0.76)
        let warm = (red: 0.86, green: 0.43, blue: 0.20)
        return Color(
            red: cool.red + (warm.red - cool.red) * warmth,
            green: cool.green + (warm.green - cool.green) * warmth,
            blue: cool.blue + (warm.blue - cool.blue) * warmth
        )
    }

    private var roomTemperatureContext: String {
        guard !linkedMeterIsLoading else { return "Updating reading…" }
        guard let roomTemperature = model.linkedMeter?.temperature else { return "No reading" }
        let delta = roomTemperature - Double(model.state.ac.targetTemperature)
        if abs(delta) < 0.15 { return "At target" }
        let difference = abs(delta).formatted(.number.precision(.fractionLength(1)))
        return delta > 0 ? "\(difference)° above target" : "\(difference)° below target"
    }

    private var linkedMeterIsLoading: Bool {
        model.readingsAreStale || model.linkedMeter?.isAvailable != true
    }

    private var linkedMeterMenu: some View {
        Menu {
            ForEach(model.meters) { meter in
                Button {
                    model.setLinkedMeter(meter.id)
                } label: {
                    if meter.id == model.state.linkedMeterID {
                        Label(meter.name, systemImage: "checkmark")
                    } else {
                        Text(meter.name)
                    }
                }
            }
        } label: {
            HStack(spacing: 5) {
                Image(systemName: "sensor.fill")
                Text(model.linkedMeter?.name ?? "Select meter")
                    .lineLimit(1)
                Image(systemName: "chevron.up.chevron.down")
                    .font(.caption2.weight(.semibold))
            }
            .font(.caption.weight(.medium))
            .foregroundStyle(.secondary)
            .padding(.horizontal, 10)
            .padding(.vertical, 7)
            .background(.thinMaterial, in: .capsule)
            .overlay {
                Capsule().stroke(.white.opacity(0.24), lineWidth: 0.5)
            }
        }
        .disabled(model.meters.isEmpty)
        .tint(Color.secondary)
        .accessibilityLabel("Linked thermometer")
    }

    private var fanBinding: Binding<FanLevel> {
        Binding(
            get: { model.state.ac.fanLevel },
            set: { value in Task { await model.setFanLevel(value) } }
        )
    }

    private var oscillationBinding: Binding<OscillationMode> {
        Binding(
            get: { model.state.ac.oscillation },
            set: { value in Task { await model.setOscillation(value) } }
        )
    }

    private var controlDivider: some View {
        Divider()
            .padding(.leading, 52)
    }

    private func controlToggle(
        title: String,
        subtitle: String,
        symbol: String,
        tint: Color,
        isOn: Bool,
        isEnabled: Bool,
        action: @escaping @Sendable (Bool) -> Void
    ) -> some View {
        HStack(spacing: 13) {
            Image(systemName: symbol)
                .font(.system(size: 16, weight: .semibold))
                .foregroundStyle(tint)
                .frame(width: 36, height: 36)
                .background(tint.opacity(0.12), in: RoundedRectangle(cornerRadius: 11, style: .continuous))

            VStack(alignment: .leading, spacing: 3) {
                Text(title)
                    .font(.body.weight(.medium))
                Text(subtitle)
                    .font(.caption)
                    .foregroundStyle(.secondary)
            }

            Spacer(minLength: 12)

            Toggle("", isOn: Binding(get: { isOn }, set: action))
                .labelsHidden()
                .tint(tint)
        }
        .frame(minHeight: 61)
        .contentShape(Rectangle())
        .disabled(!isEnabled)
        .opacity(isEnabled ? 1 : 0.42)
    }

    private func selectionCard<Value: Hashable & Identifiable>(
        title: String,
        symbol: String,
        selection: Binding<Value>,
        values: [Value],
        label: KeyPath<Value, String>,
        isEnabled: Bool
    ) -> some View {
        VStack(alignment: .leading, spacing: 14) {
            Label(title, systemImage: symbol)
                .font(.headline)
            Picker(title, selection: selection) {
                ForEach(values) { value in
                    Text(value[keyPath: label]).tag(value)
                }
            }
            .pickerStyle(.segmented)
        }
        .padding(18)
        .smartHomeGlass(cornerRadius: 28)
        .disabled(!isEnabled)
        .opacity(isEnabled ? 1 : 0.42)
    }
}

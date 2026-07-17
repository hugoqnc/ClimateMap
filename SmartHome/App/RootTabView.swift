import SwiftUI

struct RootTabView: View {
    @Environment(\.scenePhase) private var scenePhase

    private enum HomeTab: Hashable {
        case plan
        case climate
    }

    @State private var model = HomeModel()
    @State private var selectedTab: HomeTab
    private let opensClimate: Bool

    init() {
        opensClimate = ProcessInfo.processInfo.arguments.contains("--open-climate")
            || ProcessInfo.processInfo.arguments.contains("--open-ac")
        _selectedTab = State(initialValue: opensClimate ? .climate : .plan)
    }

    var body: some View {
        TabView(selection: $selectedTab) {
            Tab("Plan", systemImage: "map", value: .plan) {
                FloorPlanScreen(model: model)
            }

            Tab("Climate", systemImage: "snowflake", value: .climate) {
                ACControlScreen(model: model)
            }
        }
        .tabViewStyle(.tabBarOnly)
        .onOpenURL { url in
            guard url.scheme == "queinnec-smarthome", url.host == "climate" else { return }
            selectedTab = .climate
        }
        .onChange(of: scenePhase) { _, newPhase in
            if newPhase != .active {
                model.flushPendingClimateWidgetUpdate()
            }
        }
        .task(id: scenePhase) {
            if opensClimate { selectedTab = .climate }
            guard scenePhase == .active else { return }
            model.reloadPersistedState()
            while !Task.isCancelled {
                await model.refreshIfNeeded(maxAge: 60)
                do {
                    try await Task.sleep(for: .seconds(5))
                } catch {
                    return
                }
            }
        }
        .alert("ClimateMap", isPresented: errorBinding) {
            Button("OK", role: .cancel) { model.errorMessage = nil }
            Button("Retry") { Task { await model.refresh() } }
        } message: {
            Text(model.errorMessage ?? "Unknown error")
        }
    }

    private var errorBinding: Binding<Bool> {
        Binding(
            get: { model.errorMessage != nil },
            set: { if !$0 { model.errorMessage = nil } }
        )
    }
}

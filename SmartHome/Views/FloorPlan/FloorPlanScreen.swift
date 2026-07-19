import SwiftUI

struct FloorPlanScreen: View {
    @Bindable var model: HomeModel
    @State private var isEditing = ProcessInfo.processInfo.arguments.contains("--edit-plan")
    @State private var isShowingSettings = false

    var body: some View {
        NavigationStack {
            GeometryReader { proxy in
                let availableWidth = proxy.size.width - 24
                let availableHeight = proxy.size.height - (isEditing ? 88 : 18)
                let planWidth = min(availableWidth, availableHeight * ApartmentFloorPlan.aspectRatio)

                VStack(spacing: isEditing ? 38 : 12) {
                    if isEditing {
                        Label("Drag sensors, then tap Done", systemImage: "hand.draw.fill")
                            .font(.footnote.weight(.semibold))
                            .padding(.horizontal, 14)
                            .padding(.vertical, 9)
                            .glassEffect(.regular.tint(.blue.opacity(0.16)), in: .capsule)
                            .transition(.move(edge: .top).combined(with: .opacity))
                    }

                    FloorPlanCanvas(model: model, isEditing: isEditing)
                        .frame(width: planWidth)
                        .overlay {
                            if model.isRefreshing && model.meters.isEmpty {
                                ProgressView("Reading your home…")
                                    .padding(18)
                                    .glassEffect(in: .rect(cornerRadius: 20))
                            }
                        }
                }
                .frame(maxWidth: .infinity, maxHeight: .infinity, alignment: .top)
                .padding(.top, 4)
                .animation(.smooth(duration: 0.35), value: isEditing)
            }
            .navigationTitle("Plan")
            .navigationBarTitleDisplayMode(.inline)
            .toolbar {
                ToolbarItem(placement: .topBarLeading) {
                    Button("Settings", systemImage: "gearshape") {
                        isShowingSettings = true
                    }
                }

                ToolbarItemGroup(placement: .topBarTrailing) {
                    Button {
                        Task { await model.refresh() }
                    } label: {
                        Image(systemName: "arrow.clockwise")
                            .symbolEffect(
                                .rotate,
                                options: .repeating.speed(0.8),
                                isActive: model.isRefreshing
                            )
                    }
                    .disabled(model.isRefreshing)
                    .accessibilityLabel(model.isRefreshing ? "Refreshing temperatures" : "Refresh temperatures")

                    Button(isEditing ? "Done" : "Edit", systemImage: isEditing ? "checkmark" : "slider.horizontal.3") {
                        if isEditing { model.persistPositions() }
                        isEditing.toggle()
                    }
                }
            }
            .sensoryFeedback(.selection, trigger: isEditing)
            .refreshable { await model.refresh() }
            .sheet(isPresented: $isShowingSettings) {
                SettingsScreen(model: model)
                    .presentationDetents([.medium, .large])
                    .presentationDragIndicator(.visible)
            }
        }
    }
}

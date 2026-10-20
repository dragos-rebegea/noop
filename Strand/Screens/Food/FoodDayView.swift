#if os(iOS)
import SwiftUI
import StrandDesign
import StrandNutrition
import WhoopStore

struct FoodDayView: View {
    @EnvironmentObject var repo: Repository
    @StateObject private var holder = Holder()
    @State private var adding = false

    /// Lazily builds the model once `repo` is available from the environment.
    @MainActor final class Holder: ObservableObject { var model: FoodLogModel? }

    var body: some View {
        let model = holder.model ?? { let m = FoodLogModel(repo: repo); holder.model = m; return m }()
        FoodDayContent(model: model, adding: $adding)
            .task { await model.load() }
    }
}

private struct FoodDayContent: View {
    @ObservedObject var model: FoodLogModel
    @Binding var adding: Bool

    var body: some View {
        List {
            Section {
                StrandCard {
                    VStack(alignment: .leading, spacing: 10) {
                        row("Calories", model.totals.kcal, model.targets.kcal, "kcal")
                        row("Protein", model.totals.protein, model.targets.protein, "g")
                        row("Carbs", model.totals.carbs, model.targets.carbs, "g")
                        row("Fat", model.totals.fat, model.targets.fat, "g")
                    }
                }
                .listRowBackground(Color.clear)
            }
            Section("Today") {
                if model.entries.isEmpty {
                    Text("Nothing logged yet.").font(StrandFont.footnote).foregroundStyle(StrandPalette.textTertiary)
                }
                ForEach(model.entries) { e in
                    HStack {
                        VStack(alignment: .leading) {
                            Text(e.name).font(StrandFont.subhead).foregroundStyle(StrandPalette.textPrimary)
                            Text(Date(timeIntervalSince1970: TimeInterval(e.loggedAt)), style: .time)
                                .font(StrandFont.caption).foregroundStyle(StrandPalette.textTertiary)
                        }
                        Spacer()
                        Text(String(format: NSLocalizedString("%.0f kcal · P %.0f", comment: ""), e.kcal, e.proteinG))
                            .font(StrandFont.captionNumber).foregroundStyle(StrandPalette.textSecondary)
                    }
                }
                .onDelete { idx in
                    let rows = idx.map { model.entries[$0] }
                    Task { for r in rows { await model.delete(r) } }
                }
            }
            if let err = model.errorMessage {
                Text(err).font(StrandFont.footnote).foregroundStyle(StrandPalette.textSecondary)
            }
        }
        .scrollContentBackground(.hidden)
        .background(StrandPalette.surfaceBase)
        .navigationTitle("Food")
        .toolbar {
            ToolbarItem(placement: .primaryAction) {
                Button { adding = true } label: { Image(systemName: "plus.circle.fill") }
            }
        }
        .sheet(isPresented: $adding, onDismiss: { Task { await model.load() } }) {
            FoodAddSheet(model: model)
        }
    }

    private func row(_ label: LocalizedStringKey, _ value: Double, _ target: Double, _ unit: String) -> some View {
        VStack(alignment: .leading, spacing: 4) {
            HStack {
                Text(label).font(StrandFont.subhead).foregroundStyle(StrandPalette.textPrimary)
                Spacer()
                Text(target > 0 ? String(format: "%.0f / %.0f %@", value, target, unit)
                                : String(format: "%.0f %@", value, unit))
                    .font(StrandFont.bodyNumber).foregroundStyle(StrandPalette.textPrimary)
            }
            if target > 0 {
                ProgressView(value: min(value / target, 1)).tint(StrandPalette.accent)
            }
        }
    }
}
#endif

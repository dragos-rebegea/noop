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
    @State private var deletions = 0
    @State private var relogs = 0

    /// Today's entries grouped under meal slots derived from when they were logged.
    private var groups: [(slot: MealSlot, rows: [FoodEntryRow])] {
        let bySlot = Dictionary(grouping: model.entries) {
            MealSlot.slot(for: Date(timeIntervalSince1970: TimeInterval($0.loggedAt)))
        }
        return MealSlot.allCases.compactMap { slot in
            guard let rows = bySlot[slot], !rows.isEmpty else { return nil }
            return (slot, rows.sorted { $0.loggedAt < $1.loggedAt })
        }
    }

    var body: some View {
        List {
            Section {
                StrandCard(tint: StrandPalette.metricRose) {
                    HStack(spacing: NoopMetrics.space4) {
                        MacroRingView(value: model.totals.kcal, target: model.targets.kcal)
                        MacroBarsView(totals: model.totals, targets: model.targets)
                    }
                }
                .listRowBackground(Color.clear)
                .listRowSeparator(.hidden)
                .listRowInsets(EdgeInsets(top: NoopMetrics.space2, leading: NoopMetrics.screenPadding,
                                          bottom: NoopMetrics.space2, trailing: NoopMetrics.screenPadding))
            }
            if model.entries.isEmpty {
                Section {
                    Text("Nothing logged yet. Tap + to photograph a meal, scan a barcode or describe what you ate.")
                        .font(StrandFont.footnote).foregroundStyle(StrandPalette.textTertiary)
                        .listRowBackground(Color.clear)
                }
            }
            ForEach(groups, id: \.slot) { group in
                Section {
                    ForEach(group.rows) { e in
                        row(e)
                            .swipeActions(edge: .trailing, allowsFullSwipe: true) {
                                Button(role: .destructive) {
                                    deletions += 1
                                    Task { await model.delete(e) }
                                } label: { Label(String(localized: "Delete"), systemImage: "trash") }
                            }
                            .swipeActions(edge: .leading, allowsFullSwipe: true) {
                                Button {
                                    Task { if await model.relog(e) { relogs += 1 } }
                                } label: { Label(String(localized: "Log again"), systemImage: "arrow.counterclockwise") }
                                .tint(StrandPalette.accent)
                            }
                    }
                } header: {
                    HStack {
                        Text(group.slot.title)
                        Spacer()
                        Text(String(localized: "\(FoodNumber.string(group.rows.map(\.kcal).reduce(0, +))) kcal"))
                            .monospacedDigit()
                    }
                    .font(StrandFont.overline)
                    .foregroundStyle(StrandPalette.textTertiary)
                }
            }
            if let err = model.errorMessage {
                Text(err).font(StrandFont.footnote).foregroundStyle(StrandPalette.textSecondary)
                    .listRowBackground(Color.clear)
            }
        }
        .scrollContentBackground(.hidden)
        .background(StrandPalette.surfaceBase)
        .animation(StrandMotion.gentle, value: model.entries.map(\.id))
        .sensoryFeedback(.impact(weight: .medium), trigger: deletions)
        .sensoryFeedback(.success, trigger: relogs)
        .navigationTitle("Food")
        .toolbar {
            ToolbarItem(placement: .primaryAction) {
                Button { adding = true } label: { Image(systemName: "plus.circle.fill") }
                    .accessibilityLabel(String(localized: "Add food"))
            }
        }
        .fullScreenCover(isPresented: $adding, onDismiss: { Task { await model.load() } }) {
            FoodAddSheet(model: model)
        }
    }

    private func row(_ e: FoodEntryRow) -> some View {
        VStack(alignment: .leading, spacing: NoopMetrics.space2) {
            HStack(alignment: .firstTextBaseline) {
                VStack(alignment: .leading, spacing: NoopMetrics.spaceHalf) {
                    Text(e.name).font(StrandFont.subhead).foregroundStyle(StrandPalette.textPrimary)
                    HStack(spacing: NoopMetrics.space1) {
                        if let g = e.grams {
                            Text(String(localized: "\(FoodNumber.string(g)) g"))
                        }
                        Text(Date(timeIntervalSince1970: TimeInterval(e.loggedAt)), style: .time)
                    }
                    .font(StrandFont.caption).foregroundStyle(StrandPalette.textTertiary)
                }
                Spacer()
                Text(String(localized: "\(FoodNumber.string(e.kcal)) kcal"))
                    .font(StrandFont.bodyNumber).foregroundStyle(StrandPalette.textPrimary)
            }
            MacroCompositionBar(macros: e.macros)
        }
        .padding(.vertical, NoopMetrics.spaceHalf)
        .accessibilityElement(children: .combine)
        .accessibilityValue(String(localized: "Protein \(FoodNumber.string(e.proteinG)) g, carbs \(FoodNumber.string(e.carbsG)) g, fat \(FoodNumber.string(e.fatG)) g"))
    }
}
#endif

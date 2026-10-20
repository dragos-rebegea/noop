#if os(iOS)
import SwiftUI
import StrandDesign
import StrandNutrition

/// Check-and-adjust screen for Claude's meal estimate. Nothing is saved until Log.
struct FoodPhotoConfirmView: View {
    struct Editable: Identifiable { let id = UUID(); var item: FoodVisionReply.MealItem }

    @State private var items: [Editable]
    let onLog: ([FoodVisionReply.MealItem]) -> Void
    @State private var confirmedImplausible = false
    @State private var addingMissed = false

    init(items: [FoodVisionReply.MealItem], onLog: @escaping ([FoodVisionReply.MealItem]) -> Void) {
        _items = State(initialValue: items.map { Editable(item: $0) })
        self.onLog = onLog
    }

    private var flagged: Bool { items.contains { !Plausibility.issues($0.item.per100g).isEmpty } }
    private var total: Macros { items.map { $0.item.per100g.scaled(grams: $0.item.grams) }.sum() }

    var body: some View {
        List {
            ForEach($items) { $e in
                VStack(alignment: .leading, spacing: 8) {
                    HStack {
                        Text(e.item.name).font(StrandFont.subhead).foregroundStyle(StrandPalette.textPrimary)
                        if e.item.confidence == .low || !Plausibility.issues(e.item.per100g).isEmpty {
                            Image(systemName: "exclamationmark.triangle.fill").foregroundStyle(StrandPalette.accent)
                        }
                        Spacer()
                        Text(String(format: "%.0f g", e.item.grams))
                            .font(StrandFont.bodyNumber).foregroundStyle(StrandPalette.textPrimary)
                    }
                    Slider(value: $e.item.grams, in: 5...max(50, e.item.grams * 3), step: 5).tint(StrandPalette.accent)
                    HStack {
                        NoopButton("-25%", kind: .secondary) { e.item.grams = (e.item.grams * 0.75).rounded() }
                        NoopButton("+25%", kind: .secondary) { e.item.grams = (e.item.grams * 1.25).rounded() }
                        Spacer()
                        let m = e.item.per100g.scaled(grams: e.item.grams)
                        Text(String(format: NSLocalizedString("%.0f kcal · P %.0f", comment: ""), m.kcal, m.protein))
                            .font(StrandFont.captionNumber).foregroundStyle(StrandPalette.textSecondary)
                    }
                }
            }
            .onDelete { items.remove(atOffsets: $0) }
            Section {
                NoopButton("Add a missed item", systemImage: "plus", kind: .secondary) { addingMissed = true }
                Text(String(format: NSLocalizedString("Total: %.0f kcal · P %.0f g · C %.0f g · F %.0f g", comment: ""),
                            total.kcal, total.protein, total.carbs, total.fat))
                    .font(StrandFont.subhead).foregroundStyle(StrandPalette.textPrimary)
                if flagged {
                    Toggle("Some values look unusual. I checked them.", isOn: $confirmedImplausible)
                        .tint(StrandPalette.accent)
                }
                NoopButton("Log", systemImage: "checkmark", kind: .primary) { onLog(items.map(\.item)) }
                    .disabled(items.isEmpty || (flagged && !confirmedImplausible))
            }
        }
        .scrollContentBackground(.hidden)
        .background(StrandPalette.surfaceBase)
        .sheet(isPresented: $addingMissed) {
            // Per-100 g entry plus an amount; becomes one more item in this meal.
            FoodManualEntryView(mode: .per100g(grams: 100)) { name, per100g, grams in
                items.append(Editable(item: .init(name: name, grams: grams ?? 100, per100g: per100g, confidence: .high)))
                addingMissed = false
            }
        }
    }
}
#endif

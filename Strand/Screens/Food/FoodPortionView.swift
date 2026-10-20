#if os(iOS)
import SwiftUI
import StrandDesign
import StrandNutrition

struct FoodPortionView: View {
    let name: String
    let per100g: MacroPer100g
    let servingGrams: Double?
    let lastGrams: Double?
    let onLog: (Double) -> Void
    @State private var grams: Double
    @State private var confirmedImplausible = false

    init(name: String, per100g: MacroPer100g, servingGrams: Double?, lastGrams: Double?,
         onLog: @escaping (Double) -> Void) {
        self.name = name; self.per100g = per100g; self.servingGrams = servingGrams
        self.lastGrams = lastGrams; self.onLog = onLog
        _grams = State(initialValue: lastGrams ?? servingGrams ?? 100)
    }

    private var issues: [PlausibilityIssue] { Plausibility.issues(per100g) }

    var body: some View {
        VStack(alignment: .leading, spacing: 16) {
            Text(name).font(StrandFont.title2).foregroundStyle(StrandPalette.textPrimary)
            Text(String(format: NSLocalizedString("Per 100 g: %.0f kcal · P %.1f · C %.1f · F %.1f", comment: ""),
                        per100g.kcal, per100g.protein, per100g.carbs, per100g.fat))
                .font(StrandFont.footnote).foregroundStyle(StrandPalette.textTertiary)
            HStack {
                Text("Amount").font(StrandFont.subhead).foregroundStyle(StrandPalette.textPrimary)
                Spacer()
                TextField("g", value: $grams, format: .number)
                    .keyboardType(.decimalPad).multilineTextAlignment(.trailing).frame(width: 90)
                Text("g").font(StrandFont.subhead).foregroundStyle(StrandPalette.textSecondary)
            }
            HStack {
                chip(100)
                if let s = servingGrams { chip(s) }
                if let l = lastGrams, l != servingGrams, l != 100 { chip(l) }
            }
            let m = per100g.scaled(grams: grams)
            Text(String(format: NSLocalizedString("%.0f kcal · P %.1f g · C %.1f g · F %.1f g", comment: ""),
                        m.kcal, m.protein, m.carbs, m.fat))
                .font(StrandFont.bodyNumber).foregroundStyle(StrandPalette.textPrimary)
            if !issues.isEmpty {
                Toggle(isOn: $confirmedImplausible) {
                    Text("These values look unusual. Confirm they are right.")
                        .font(StrandFont.footnote).foregroundStyle(StrandPalette.textSecondary)
                }
                .toggleStyle(.switch).tint(StrandPalette.accent)
            }
            NoopButton("Log", systemImage: "checkmark", kind: .primary) { onLog(grams) }
                .disabled(grams <= 0 || (!issues.isEmpty && !confirmedImplausible))
            Spacer()
        }
        .padding(16)
        .background(StrandPalette.surfaceBase)
    }

    private func chip(_ g: Double) -> some View {
        NoopButton(LocalizedStringKey(String(format: "%.0f g", g)), kind: .secondary) { grams = g }
    }
}
#endif

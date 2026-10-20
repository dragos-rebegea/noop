#if os(iOS)
import SwiftUI
import StrandDesign
import StrandNutrition

/// Hand entry in two modes: `.totals` (Quick add: the eaten amount's macros) and `.per100g`
/// (a missed item: values per 100 g plus the amount eaten) and `.product` (a product's values per
/// 100 g only; the amount is chosen on the portion screen that follows). Rejects negative values.
struct FoodManualEntryView: View {
    enum Mode { case totals, per100g(grams: Double), product }

    let mode: Mode
    /// name, values (totals or per 100 g, per mode), grams (only in `.per100g`)
    let onDone: (String, MacroPer100g, Double?) -> Void

    @State private var name = ""
    @State private var kcal: Double?
    @State private var protein: Double?
    @State private var carbs: Double?
    @State private var fat: Double?
    @State private var grams: Double?

    private var isPer100g: Bool { if case .totals = mode { return false } else { return true } }
    private var asksAmount: Bool { if case .per100g = mode { return true } else { return false } }
    private var values: [Double?] { [kcal, protein, carbs, fat] }
    private var valid: Bool {
        values.contains { $0 != nil } && values.allSatisfy { ($0 ?? 0) >= 0 }
            && (!asksAmount || (grams ?? 0) > 0)
    }

    var body: some View {
        Form {
            TextField("Name", text: $name)
            if isPer100g { Text("Values per 100 g").font(StrandFont.footnote).foregroundStyle(StrandPalette.textTertiary) }
            field("Calories (kcal)", $kcal)
            field("Protein (g)", $protein)
            field("Carbs (g)", $carbs)
            field("Fat (g)", $fat)
            if asksAmount { field("Amount eaten (g)", $grams) }
            NoopButton(isPer100g ? "Save" : "Log", systemImage: "checkmark", kind: .primary) {
                onDone(name.isEmpty ? String(localized: "Quick add") : name,
                       MacroPer100g(kcal: kcal ?? 0, protein: protein ?? 0, carbs: carbs ?? 0, fat: fat ?? 0),
                       asksAmount ? grams : nil)
            }
            .disabled(!valid)
        }
        .scrollContentBackground(.hidden)
        .background(StrandPalette.surfaceBase)
        .onAppear { if case .per100g(let g) = mode, grams == nil { grams = g } }
    }

    private func field(_ label: LocalizedStringKey, _ v: Binding<Double?>) -> some View {
        HStack {
            Text(label).font(StrandFont.subhead).foregroundStyle(StrandPalette.textPrimary)
            Spacer()
            TextField("0", value: v, format: .number).keyboardType(.decimalPad)
                .multilineTextAlignment(.trailing).frame(width: 90)
        }
    }
}
#endif

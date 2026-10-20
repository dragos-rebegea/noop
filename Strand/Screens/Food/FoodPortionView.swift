#if os(iOS)
import SwiftUI
import StrandDesign
import StrandNutrition

/// One product (barcode, label read, or a re-log at a new amount): product card, serving chips,
/// a stepper, and the day's "leaves you" line. Nothing is saved until Log.
struct FoodPortionView: View {
    let name: String
    let per100g: MacroPer100g
    let servingGrams: Double?
    let lastGrams: Double?
    var today: Macros = .zero
    var targets: Macros = .zero
    let onLog: (Double) -> Void
    @State private var grams: Double
    @State private var confirmedImplausible = false

    init(name: String, per100g: MacroPer100g, servingGrams: Double?, lastGrams: Double?,
         today: Macros = .zero, targets: Macros = .zero, onLog: @escaping (Double) -> Void) {
        self.name = name; self.per100g = per100g; self.servingGrams = servingGrams
        self.lastGrams = lastGrams; self.today = today; self.targets = targets; self.onLog = onLog
        _grams = State(initialValue: lastGrams ?? servingGrams ?? 100)
    }

    private var issues: [PlausibilityIssue] { Plausibility.issues(per100g) }
    private var macros: Macros { per100g.scaled(grams: grams) }

    var body: some View {
        ScrollView {
            VStack(alignment: .leading, spacing: NoopMetrics.sectionGap) {
                productCard
                amountCard
                if !issues.isEmpty {
                    Toggle(isOn: $confirmedImplausible) {
                        Text("These values look unusual. Confirm they are right.")
                            .font(StrandFont.footnote).foregroundStyle(StrandPalette.textSecondary)
                    }
                    .toggleStyle(.switch).tint(StrandPalette.accent)
                }
            }
            .padding(NoopMetrics.screenPadding)
        }
        .scrollDismissesKeyboard(.interactively)
        .background(StrandPalette.surfaceBase)
        .safeAreaInset(edge: .bottom) {
            NoopButton("Log", systemImage: "checkmark", kind: .primary, fullWidth: true) { onLog(grams) }
                .disabled(grams <= 0 || (!issues.isEmpty && !confirmedImplausible))
                .padding(.horizontal, NoopMetrics.screenPadding)
                .padding(.vertical, NoopMetrics.space3)
                .background(StrandPalette.surfaceBase)
        }
        .strandHaptic(.selection, trigger: grams)
        .foodKeyboardDone()
    }

    private var productCard: some View {
        StrandCard {
            VStack(alignment: .leading, spacing: NoopMetrics.space3) {
                Text(name).font(StrandFont.title2).foregroundStyle(StrandPalette.textPrimary)
                Text(String(format: NSLocalizedString("Per 100 g: %.0f kcal · P %.1f · C %.1f · F %.1f", comment: ""),
                            per100g.kcal, per100g.protein, per100g.carbs, per100g.fat))
                    .font(StrandFont.footnote).foregroundStyle(StrandPalette.textTertiary)
                HStack(alignment: .firstTextBaseline) {
                    Text(String(localized: "\(FoodNumber.string(macros.kcal)) kcal"))
                        .font(StrandFont.title1).foregroundStyle(StrandPalette.textPrimary)
                        .contentTransition(.numericText())
                    Spacer()
                    Text(String(localized: "P \(FoodNumber.string(macros.protein)) g"))
                        .font(StrandFont.bodyNumber).foregroundStyle(StrandPalette.textSecondary)
                }
                MacroCompositionBar(macros: macros)
                if let line = FoodBudgetLine.text(today: today, adding: macros, targets: targets) {
                    Text(line).font(StrandFont.subhead).foregroundStyle(StrandPalette.textSecondary)
                }
            }
        }
    }

    private var amountCard: some View {
        StrandCard {
            VStack(alignment: .leading, spacing: NoopMetrics.space3) {
                Text("Amount").font(StrandFont.overline).foregroundStyle(StrandPalette.textTertiary)
                GramStepper(grams: $grams)
                ScrollView(.horizontal, showsIndicators: false) {
                    HStack(spacing: NoopMetrics.space2) {
                        if let s = servingGrams {
                            FoodChip(String(localized: "1 serving (\(FoodNumber.string(s)) g)"), selected: grams == s) { grams = s }
                        }
                        if let l = lastGrams, l != servingGrams {
                            FoodChip(String(localized: "Last time (\(FoodNumber.string(l)) g)"), selected: grams == l) { grams = l }
                        }
                        FoodChip(String(localized: "100 g"), selected: grams == 100) { grams = 100 }
                    }
                }
            }
        }
    }
}

/// `-  150 g  +` with growing steps (`PortionStep.next`); the number is tappable to type an amount.
struct GramStepper: View {
    @Binding var grams: Double

    var body: some View {
        HStack(spacing: NoopMetrics.space3) {
            stepButton("minus", up: false)
            Spacer(minLength: 0)
            HStack(alignment: .firstTextBaseline, spacing: NoopMetrics.space1) {
                TextField("0", value: $grams, format: .number.precision(.fractionLength(0)))
                    .keyboardType(.numberPad)
                    .multilineTextAlignment(.trailing)
                    .font(StrandFont.title2.monospacedDigit())
                    .foregroundStyle(StrandPalette.textPrimary)
                    .fixedSize()
                Text("g").font(StrandFont.subhead).foregroundStyle(StrandPalette.textSecondary)
            }
            Spacer(minLength: 0)
            stepButton("plus", up: true)
        }
    }

    private func stepButton(_ icon: String, up: Bool) -> some View {
        Button {
            withAnimation(StrandMotion.interactive) { grams = PortionStep.next(grams, up: up) }
        } label: {
            Image(systemName: icon)
                .font(StrandFont.headline)
                .foregroundStyle(StrandPalette.textPrimary)
                .frame(width: NoopMetrics.compactControlSize, height: NoopMetrics.compactControlSize)
                .background(StrandPalette.surfaceInset, in: Circle())
        }
        .buttonStyle(.plain)
        .accessibilityLabel(up ? String(localized: "More") : String(localized: "Less"))
    }
}

extension View {
    /// One keyboard "Done" for a whole screen, so steppers in list rows do not each add one.
    func foodKeyboardDone() -> some View {
        toolbar {
            ToolbarItemGroup(placement: .keyboard) {
                Spacer()
                Button(String(localized: "Done")) {
                    UIApplication.shared.sendAction(#selector(UIResponder.resignFirstResponder),
                                                    to: nil, from: nil, for: nil)
                }
            }
        }
    }
}

/// A small capsule choice used for portion shortcuts and suggestions.
struct FoodChip: View {
    let title: String
    var selected = false
    let action: () -> Void

    init(_ title: String, selected: Bool = false, action: @escaping () -> Void) {
        self.title = title; self.selected = selected; self.action = action
    }

    var body: some View {
        Button(action: action) {
            Text(title)
                .font(StrandFont.subhead)
                .foregroundStyle(selected ? StrandPalette.surfaceBase : StrandPalette.textPrimary)
                .padding(.horizontal, NoopMetrics.space3)
                .padding(.vertical, NoopMetrics.space2)
                .background(selected ? StrandPalette.accent : StrandPalette.surfaceInset, in: Capsule())
        }
        .buttonStyle(.plain)
    }
}
#endif

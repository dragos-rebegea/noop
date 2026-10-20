#if os(iOS)
import SwiftUI
import StrandDesign
import StrandNutrition

/// Number formatting shared by the Food screens: grouped, no decimals.
enum FoodNumber {
    static func string(_ value: Double) -> String {
        let formatter = NumberFormatter()
        formatter.numberStyle = .decimal
        formatter.maximumFractionDigits = 0
        return formatter.string(from: NSNumber(value: value)) ?? String(Int(value.rounded()))
    }
}

/// The macro colours used across Food: protein rose, carbs amber, fat cyan.
enum MacroTint {
    static var protein: Color { StrandPalette.metricRose }
    static var carbs: Color { StrandPalette.metricAmber }
    static var fat: Color { StrandPalette.metricCyan }
}

/// Calorie ring with the eaten amount in the middle; draws in on appear and animates changes.
struct MacroRingView: View {
    let value: Double
    let target: Double
    var diameter: CGFloat = NoopMetrics.tileHeight

    @Environment(\.accessibilityReduceMotion) private var reduceMotion
    @State private var shown: Double = 0

    private var fraction: Double { MacroProgress.fraction(value, target: target) }

    var body: some View {
        ZStack {
            Circle()
                .stroke(StrandPalette.hairline, lineWidth: NoopMetrics.space1)
            Circle()
                .trim(from: 0, to: shown)
                .stroke(StrandPalette.accent,
                        style: StrokeStyle(lineWidth: NoopMetrics.space1, lineCap: .round))
                .rotationEffect(.degrees(-90))
            VStack(spacing: NoopMetrics.spaceHalf) {
                Text(String(localized: "\(FoodNumber.string(value)) /"))
                    .font(StrandFont.headline)
                    .foregroundStyle(MacroProgress.isOver(value, target: target)
                        ? StrandPalette.accent : StrandPalette.textPrimary)
                    .contentTransition(.numericText())
                if target > 0 {
                    Text(String(localized: "of \(FoodNumber.string(target)) kcal"))
                        .font(StrandFont.footnote)
                        .foregroundStyle(StrandPalette.textSecondary)
                } else {
                    Text(String(localized: "kcal"))
                        .font(StrandFont.footnote)
                        .foregroundStyle(StrandPalette.textSecondary)
                }
            }
        }
        .frame(width: diameter, height: diameter)
        .onAppear { withAnimation(StrandMotion.drawIn(reduced: reduceMotion)) { shown = fraction } }
        .onChange(of: fraction) { _, f in
            withAnimation(reduceMotion ? nil : StrandMotion.gentle) { shown = f }
        }
    }
}

/// The three protein / carbs / fat dot-grid columns from the Today card.
struct MacroBarsView: View {
    let totals: Macros
    let targets: Macros

    var body: some View {
        HStack(spacing: NoopMetrics.space3) {
            MacroColumn(name: String(localized: "protein"), icon: "fish.fill",
                        value: totals.protein, target: targets.protein, tint: MacroTint.protein)
            MacroColumn(name: String(localized: "carbs"), icon: "leaf.fill",
                        value: totals.carbs, target: targets.carbs, tint: MacroTint.carbs)
            MacroColumn(name: String(localized: "fat"), icon: "drop.fill",
                        value: totals.fat, target: targets.fat, tint: MacroTint.fat)
        }
        .frame(maxWidth: .infinity)
    }
}

private struct MacroColumn: View {
    let name: String
    let icon: String
    let value: Double
    let target: Double
    let tint: Color

    private let columns = Array(
        repeating: GridItem(.fixed(NoopMetrics.space1), spacing: NoopMetrics.spaceHalf),
        count: 8
    )

    var body: some View {
        VStack(spacing: NoopMetrics.space1) {
            Image(systemName: icon)
                .font(StrandFont.caption)
                .foregroundStyle(tint)
                .accessibilityLabel(name)
            Text(String(localized: "\(FoodNumber.string(value))g"))
                .font(StrandFont.bodyNumber)
                .foregroundStyle(MacroProgress.isOver(value, target: target)
                    ? StrandPalette.accent : StrandPalette.textPrimary)
            LazyVGrid(columns: columns, spacing: NoopMetrics.spaceHalf) {
                let filled = MacroProgress.filledDots(value, target: target, total: 48)
                ForEach(0..<48, id: \.self) { index in
                    Circle()
                        .fill(index < filled ? tint : StrandPalette.hairline)
                        .frame(width: NoopMetrics.space1, height: NoopMetrics.space1)
                }
            }
            if target > 0 {
                Text(String(localized: "of \(FoodNumber.string(target))g"))
                    .font(StrandFont.footnote)
                    .foregroundStyle(StrandPalette.textSecondary)
            }
        }
        .frame(maxWidth: .infinity)
    }
}

/// Three thin protein / carbs / fat bars for one meal. Each bar fills toward the day's target
/// when one is set, otherwise relative to the largest of the three.
struct MacroThinBarsView: View {
    let macros: Macros
    let targets: Macros

    @Environment(\.accessibilityReduceMotion) private var reduceMotion
    @State private var drawn = false

    var body: some View {
        let peak = max(macros.protein, macros.carbs, macros.fat, 1)
        VStack(spacing: NoopMetrics.space2) {
            bar(String(localized: "Protein"), macros.protein, targets.protein, peak, MacroTint.protein)
            bar(String(localized: "Carbs"), macros.carbs, targets.carbs, peak, MacroTint.carbs)
            bar(String(localized: "Fat"), macros.fat, targets.fat, peak, MacroTint.fat)
        }
        .onAppear { withAnimation(StrandMotion.drawIn(reduced: reduceMotion)) { drawn = true } }
    }

    private func bar(_ name: String, _ value: Double, _ target: Double, _ peak: Double, _ tint: Color) -> some View {
        let fraction = target > 0 ? MacroProgress.fraction(value, target: target) : min(value / peak, 1)
        return VStack(alignment: .leading, spacing: NoopMetrics.space1) {
            HStack {
                Text(name).font(StrandFont.caption).foregroundStyle(StrandPalette.textSecondary)
                Spacer()
                Text(String(localized: "\(FoodNumber.string(value)) g"))
                    .font(StrandFont.captionNumber).foregroundStyle(StrandPalette.textPrimary)
            }
            GeometryReader { geo in
                ZStack(alignment: .leading) {
                    Capsule().fill(StrandPalette.hairline)
                    Capsule().fill(tint).frame(width: geo.size.width * (drawn ? fraction : 0))
                }
            }
            .frame(height: NoopMetrics.space1)
        }
        .accessibilityElement(children: .combine)
    }
}

/// A thin bar split by each macro's share of the energy (4 / 4 / 9 kcal per gram).
struct MacroCompositionBar: View {
    let macros: Macros

    var body: some View {
        let p = max(macros.protein, 0) * 4, c = max(macros.carbs, 0) * 4, f = max(macros.fat, 0) * 9
        let sum = p + c + f
        GeometryReader { geo in
            HStack(spacing: NoopMetrics.spaceHalf) {
                if sum > 0 {
                    segment(MacroTint.protein, geo.size.width * p / sum)
                    segment(MacroTint.carbs, geo.size.width * c / sum)
                    segment(MacroTint.fat, geo.size.width * f / sum)
                } else {
                    Capsule().fill(StrandPalette.hairline)
                }
            }
        }
        .frame(height: NoopMetrics.space1)
        .accessibilityHidden(true)
    }

    @ViewBuilder private func segment(_ tint: Color, _ width: CGFloat) -> some View {
        if width > 0 { Capsule().fill(tint).frame(width: max(width - NoopMetrics.spaceHalf, 1)) }
    }
}

/// The calm "leaves you" line under a meal or product: what the day has left after this food.
/// Nil when no calorie target is set.
enum FoodBudgetLine {
    static func text(today: Macros, adding meal: Macros, targets: Macros) -> String? {
        guard targets.kcal > 0 else { return nil }
        let kcalLeft = targets.kcal - today.kcal - meal.kcal
        if kcalLeft < 0 {
            return String(localized: "Puts you \(FoodNumber.string(-kcalLeft)) kcal over today")
        }
        let proteinLeft = targets.protein - today.protein - meal.protein
        if targets.protein > 0, proteinLeft > 0 {
            return String(localized: "Leaves \(FoodNumber.string(kcalLeft)) kcal and \(FoodNumber.string(proteinLeft)) g protein for today")
        }
        return String(localized: "Leaves \(FoodNumber.string(kcalLeft)) kcal for today")
    }
}

/// The section title for a meal slot.
extension MealSlot {
    var title: String {
        switch self {
        case .breakfast: return String(localized: "Breakfast")
        case .lunch: return String(localized: "Lunch")
        case .dinner: return String(localized: "Dinner")
        case .snack: return String(localized: "Snack")
        }
    }
}

/// Soft opacity pulse for redacted placeholder cards while Claude works.
struct FoodShimmer: ViewModifier {
    @Environment(\.accessibilityReduceMotion) private var reduceMotion
    @State private var dim = false

    func body(content: Content) -> some View {
        content
            .redacted(reason: .placeholder)
            .opacity(dim ? 0.45 : 1)
            .onAppear {
                guard !reduceMotion else { return }
                withAnimation(.easeInOut(duration: StrandMotion.durationSlow).repeatForever(autoreverses: true)) {
                    dim = true
                }
            }
            .accessibilityHidden(true)
    }
}

extension View {
    func foodShimmer() -> some View { modifier(FoodShimmer()) }
}
#endif

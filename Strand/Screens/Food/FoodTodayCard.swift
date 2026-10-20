#if os(iOS)
import Combine
import Foundation
import SwiftUI
import StrandDesign
import StrandNutrition
import WhoopStore

/// A self-loading summary of today's logged calories and macronutrients.
struct FoodTodayCard: View {
    @EnvironmentObject private var repo: Repository
    @AppStorage(FoodLogModel.targetKeys.kcal) private var calorieTarget = 0.0
    @AppStorage(FoodLogModel.targetKeys.protein) private var proteinTarget = 0.0
    @AppStorage(FoodLogModel.targetKeys.carbs) private var carbsTarget = 0.0
    @AppStorage(FoodLogModel.targetKeys.fat) private var fatTarget = 0.0
    @State private var totals = Macros.zero

    var body: some View {
        NavigationLink(value: TabRoute.food) {
            StrandCard(tint: StrandPalette.metricRose) {
                VStack(alignment: .leading, spacing: NoopMetrics.cardInnerSpacing) {
                    HStack(spacing: NoopMetrics.space2) {
                        Text(String(localized: "Today's foods"))
                            .font(StrandFont.headline)
                            .foregroundStyle(StrandPalette.textPrimary)
                        Spacer()
                        Image(systemName: "chevron.right")
                            .font(StrandFont.caption)
                            .foregroundStyle(StrandPalette.textTertiary)
                    }

                    HStack(spacing: NoopMetrics.space4) {
                        calorieRing
                        HStack(spacing: NoopMetrics.space3) {
                            MacroColumn(name: String(localized: "protein"), icon: "fish.fill",
                                        value: totals.protein, target: proteinTarget,
                                        tint: StrandPalette.metricRose)
                            MacroColumn(name: String(localized: "carbs"), icon: "leaf.fill",
                                        value: totals.carbs, target: carbsTarget,
                                        tint: StrandPalette.metricAmber)
                            MacroColumn(name: String(localized: "fat"), icon: "drop.fill",
                                        value: totals.fat, target: fatTarget,
                                        tint: StrandPalette.metricCyan)
                        }
                        .frame(maxWidth: .infinity)
                    }
                }
            }
        }
        .buttonStyle(.plain)
        .accessibilityElement(children: .ignore)
        .accessibilityLabel(accessibilitySummary)
        .task { await load() }
        .onReceive(NotificationCenter.default.publisher(for: .foodLogDidChange)) { _ in
            Task { await load() }
        }
    }

    private var calorieRing: some View {
        ZStack {
            Circle()
                .stroke(StrandPalette.hairline, lineWidth: NoopMetrics.space1)
            Circle()
                .trim(from: 0, to: MacroProgress.fraction(totals.kcal, target: calorieTarget))
                .stroke(StrandPalette.accent,
                        style: StrokeStyle(lineWidth: NoopMetrics.space1, lineCap: .round))
                .rotationEffect(.degrees(-90))
            VStack(spacing: NoopMetrics.spaceHalf) {
                Text(String(localized: "\(Self.number(totals.kcal)) /"))
                    .font(StrandFont.headline)
                    .foregroundStyle(MacroProgress.isOver(totals.kcal, target: calorieTarget)
                        ? StrandPalette.accent : StrandPalette.textPrimary)
                if calorieTarget > 0 {
                    Text(String(localized: "of \(Self.number(calorieTarget)) kcal"))
                        .font(StrandFont.footnote)
                        .foregroundStyle(StrandPalette.textSecondary)
                } else {
                    Text(String(localized: "kcal"))
                        .font(StrandFont.footnote)
                        .foregroundStyle(StrandPalette.textSecondary)
                }
            }
        }
        .frame(width: NoopMetrics.tileHeight, height: NoopMetrics.tileHeight)
    }

    private var accessibilitySummary: String {
        let calories: String
        if calorieTarget > 0 {
            calories = String(localized: "\(Self.number(totals.kcal)) of \(Self.number(calorieTarget)) kilocalories")
        } else {
            calories = String(localized: "\(Self.number(totals.kcal)) kilocalories")
        }
        return [
            String(localized: "Today's foods"),
            calories,
            Self.accessibilityMacro(String(localized: "protein"), value: totals.protein, target: proteinTarget),
            Self.accessibilityMacro(String(localized: "carbs"), value: totals.carbs, target: carbsTarget),
            Self.accessibilityMacro(String(localized: "fat"), value: totals.fat, target: fatTarget),
        ].joined(separator: ", ")
    }

    private func load() async {
        guard let store = await repo.storeHandle() else { return }
        let day = FoodDay.key(for: Date())
        guard let rows = try? await store.foodEntries(deviceId: FoodLog.deviceId, day: day) else { return }
        totals = rows.map(\.macros).sum()
    }

    fileprivate static func number(_ value: Double) -> String {
        let formatter = NumberFormatter()
        formatter.numberStyle = .decimal
        formatter.maximumFractionDigits = 0
        return formatter.string(from: NSNumber(value: value)) ?? String(Int(value.rounded()))
    }

    private static func accessibilityMacro(_ name: String, value: Double, target: Double) -> String {
        if target > 0 {
            return String(localized: "\(name) \(number(value)) grams of \(number(target))")
        }
        return String(localized: "\(name) \(number(value)) grams")
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
            Text(String(localized: "\(FoodTodayCard.number(value))g"))
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
                Text(String(localized: "of \(FoodTodayCard.number(target))g"))
                    .font(StrandFont.footnote)
                    .foregroundStyle(StrandPalette.textSecondary)
            }
        }
        .frame(maxWidth: .infinity)
    }
}
#endif

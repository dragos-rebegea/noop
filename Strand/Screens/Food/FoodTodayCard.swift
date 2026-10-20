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
                        MacroRingView(value: totals.kcal, target: calorieTarget)
                        MacroBarsView(totals: totals,
                                      targets: Macros(kcal: calorieTarget, protein: proteinTarget,
                                                      carbs: carbsTarget, fat: fatTarget))
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

    private static func number(_ value: Double) -> String { FoodNumber.string(value) }

    private static func accessibilityMacro(_ name: String, value: Double, target: Double) -> String {
        if target > 0 {
            return String(localized: "\(name) \(number(value)) grams of \(number(target))")
        }
        return String(localized: "\(name) \(number(value)) grams")
    }
}
#endif

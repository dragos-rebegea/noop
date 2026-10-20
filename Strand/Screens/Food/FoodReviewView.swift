#if os(iOS)
import SwiftUI
import UIKit
import StrandDesign
import StrandNutrition

/// Check-and-adjust screen for Claude's meal estimate (photo or description). Shows shimmering
/// placeholder cards while Claude works, then one editable card per item. Nothing is saved
/// until "Log meal".
struct FoodReviewView: View {
    /// What the estimate came from. The photo lives in memory only and is never written.
    enum Header { case photo(UIImage), text(String) }

    struct Editable: Identifiable {
        let id = UUID()
        var item: FoodVisionReply.MealItem
        /// The estimate's own amount, which the 1x chip returns to.
        var baseGrams: Double
    }

    let header: Header
    let loggedAt: Date
    /// Nil while Claude is still working.
    let items: [FoodVisionReply.MealItem]?
    let today: Macros
    let targets: Macros
    let errorMessage: String?
    /// Saves the meal; true on success.
    let log: ([FoodVisionReply.MealItem]) async -> Bool
    let onFinished: () -> Void

    @State private var editables: [Editable] = []
    @State private var loaded = false
    @State private var confirmedImplausible = false
    @State private var addingMissed = false
    @State private var logging = false
    @State private var logged = false
    @State private var deletions = 0
    @Environment(\.accessibilityReduceMotion) private var reduceMotion

    private var flagged: Bool { editables.contains { !Plausibility.issues($0.item.per100g).isEmpty } }
    private var total: Macros { editables.map { $0.item.per100g.scaled(grams: $0.item.grams) }.sum() }
    private var slot: MealSlot { MealSlot.slot(for: loggedAt) }

    var body: some View {
        List {
            Group {
                headerRow
                if items == nil {
                    placeholderSummary
                    ForEach(0..<2, id: \.self) { _ in placeholderItem }
                } else {
                    summaryCard
                    ForEach($editables) { $e in
                        itemCard($e)
                            .swipeActions(edge: .trailing, allowsFullSwipe: true) {
                                Button(role: .destructive) {
                                    withAnimation(StrandMotion.gentle) { editables.removeAll { $0.id == e.id } }
                                    deletions += 1
                                } label: { Label(String(localized: "Delete"), systemImage: "trash") }
                            }
                    }
                    Button { addingMissed = true } label: {
                        Label(String(localized: "Add item"), systemImage: "plus")
                            .font(StrandFont.subhead)
                            .foregroundStyle(StrandPalette.accent)
                    }
                    .buttonStyle(.plain)
                    if flagged {
                        Toggle(isOn: $confirmedImplausible) {
                            Text("Some values look unusual. I checked them.")
                                .font(StrandFont.footnote).foregroundStyle(StrandPalette.textSecondary)
                        }
                        .tint(StrandPalette.accent)
                    }
                    if let errorMessage {
                        Text(errorMessage).font(StrandFont.footnote).foregroundStyle(StrandPalette.statusCritical)
                    }
                }
            }
            .listRowBackground(Color.clear)
            .listRowSeparator(.hidden)
            .listRowInsets(EdgeInsets(top: NoopMetrics.space2, leading: NoopMetrics.screenPadding,
                                      bottom: NoopMetrics.space2, trailing: NoopMetrics.screenPadding))
        }
        .listStyle(.plain)
        .scrollContentBackground(.hidden)
        .scrollDismissesKeyboard(.interactively)
        .background(StrandPalette.surfaceBase)
        .safeAreaInset(edge: .bottom) { logBar }
        .overlay { if logged { successMark } }
        .sensoryFeedback(.success, trigger: logged) { _, now in now }
        .sensoryFeedback(.impact(weight: .light), trigger: deletions)
        .foodKeyboardDone()
        .onAppear(perform: adopt)
        .onChange(of: items) { _, _ in adopt() }
        .sheet(isPresented: $addingMissed) {
            NavigationStack {
                FoodManualEntryView(mode: .per100g(grams: 100)) { name, per100g, grams in
                    let g = grams ?? 100
                    withAnimation(StrandMotion.gentle) {
                        editables.append(Editable(item: .init(name: name, grams: g, per100g: per100g, confidence: .high),
                                                  baseGrams: g))
                    }
                    addingMissed = false
                }
                .navigationTitle(String(localized: "Add item"))
                .navigationBarTitleDisplayMode(.inline)
            }
        }
    }

    /// Takes Claude's items once they arrive (the view is shown before they do).
    private func adopt() {
        guard !loaded, let items else { return }
        loaded = true
        withAnimation(reduceMotion ? nil : StrandMotion.gentle) {
            editables = items.map { Editable(item: $0, baseGrams: $0.grams) }
        }
    }

    // MARK: Header and summary

    private var headerRow: some View {
        HStack(alignment: .top, spacing: NoopMetrics.space3) {
            switch header {
            case .photo(let image):
                Image(uiImage: image)
                    .resizable()
                    .scaledToFill()
                    .frame(width: NoopMetrics.tileHeight, height: NoopMetrics.tileHeight)
                    .clipShape(RoundedRectangle(cornerRadius: NoopMetrics.cardRadius, style: .continuous))
                    .accessibilityLabel(String(localized: "Meal photo"))
            case .text(let text):
                Text(text)
                    .font(StrandFont.subhead)
                    .foregroundStyle(StrandPalette.textPrimary)
                    .lineLimit(4)
                    .padding(NoopMetrics.space3)
                    .background(StrandPalette.surfaceInset,
                                in: RoundedRectangle(cornerRadius: NoopMetrics.cardRadius, style: .continuous))
                    .frame(maxWidth: .infinity, alignment: .leading)
            }
            VStack(alignment: .leading, spacing: NoopMetrics.space1) {
                Text(slot.title).font(StrandFont.title2).foregroundStyle(StrandPalette.textPrimary)
                Text(loggedAt, style: .time).font(StrandFont.subhead).foregroundStyle(StrandPalette.textSecondary)
                if items == nil {
                    Text("Estimating...").font(StrandFont.caption).foregroundStyle(StrandPalette.textTertiary)
                }
            }
            if case .photo = header { Spacer(minLength: 0) }
        }
    }

    private var summaryCard: some View {
        StrandCard {
            VStack(alignment: .leading, spacing: NoopMetrics.space3) {
                HStack(spacing: NoopMetrics.space4) {
                    MacroRingView(value: total.kcal, target: targets.kcal)
                    MacroThinBarsView(macros: total, targets: targets)
                }
                if let line = FoodBudgetLine.text(today: today, adding: total, targets: targets) {
                    Text(line).font(StrandFont.subhead).foregroundStyle(StrandPalette.textSecondary)
                }
            }
        }
    }

    private var placeholderSummary: some View {
        StrandCard {
            HStack(spacing: NoopMetrics.space4) {
                Circle().stroke(StrandPalette.hairline, lineWidth: NoopMetrics.space1)
                    .frame(width: NoopMetrics.tileHeight, height: NoopMetrics.tileHeight)
                MacroThinBarsView(macros: Macros(kcal: 500, protein: 30, carbs: 50, fat: 20), targets: .zero)
            }
        }
        .foodShimmer()
    }

    private var placeholderItem: some View {
        StrandCard {
            VStack(alignment: .leading, spacing: NoopMetrics.space3) {
                Text(verbatim: "Grilled chicken breast").font(StrandFont.headline)
                Text(verbatim: "150 g, 250 kcal, P 40 g").font(StrandFont.subhead)
            }
        }
        .foodShimmer()
    }

    // MARK: Items

    private func itemCard(_ e: Binding<Editable>) -> some View {
        let m = e.wrappedValue.item.per100g.scaled(grams: e.wrappedValue.item.grams)
        let unsure = e.wrappedValue.item.confidence == .low || !Plausibility.issues(e.wrappedValue.item.per100g).isEmpty
        return StrandCard {
            VStack(alignment: .leading, spacing: NoopMetrics.space3) {
                HStack(spacing: NoopMetrics.space2) {
                    TextField(String(localized: "Name"), text: e.item.name)
                        .textFieldStyle(.plain)
                        .font(StrandFont.headline)
                        .foregroundStyle(StrandPalette.textPrimary)
                        .submitLabel(.done)
                    if unsure {
                        Label(String(localized: "Check"), systemImage: "exclamationmark.triangle.fill")
                            .font(StrandFont.caption)
                            .foregroundStyle(StrandPalette.statusWarning)
                            .accessibilityLabel(String(localized: "Estimate may be off. Check this item."))
                    }
                }
                GramStepper(grams: e.item.grams)
                HStack(spacing: NoopMetrics.space2) {
                    portionChip(String(localized: "1/2"), factor: 0.5, e)
                    portionChip(String(localized: "1x"), factor: 1, e)
                    portionChip(String(localized: "2x"), factor: 2, e)
                    Spacer(minLength: 0)
                    VStack(alignment: .trailing, spacing: NoopMetrics.spaceHalf) {
                        Text(String(localized: "\(FoodNumber.string(m.kcal)) kcal"))
                            .font(StrandFont.bodyNumber).foregroundStyle(StrandPalette.textPrimary)
                            .contentTransition(.numericText())
                        Text(String(localized: "P \(FoodNumber.string(m.protein)) g"))
                            .font(StrandFont.captionNumber).foregroundStyle(StrandPalette.textSecondary)
                    }
                }
            }
        }
    }

    private func portionChip(_ title: String, factor: Double, _ e: Binding<Editable>) -> some View {
        let target = PortionStep.scaled(e.wrappedValue.baseGrams, by: factor)
        return FoodChip(title, selected: e.wrappedValue.item.grams == target) {
            withAnimation(StrandMotion.interactive) { e.wrappedValue.item.grams = target }
        }
    }

    // MARK: Log

    private var logBar: some View {
        NoopButton("Log meal", systemImage: "checkmark", kind: .primary, fullWidth: true) {
            guard !logging else { return }
            logging = true
            Task {
                if await log(editables.map(\.item)) {
                    withAnimation(reduceMotion ? nil : StrandMotion.gentle) { logged = true }
                    try? await Task.sleep(nanoseconds: 700_000_000)
                    onFinished()
                } else {
                    logging = false
                }
            }
        }
        .disabled(items == nil || editables.isEmpty || logging || (flagged && !confirmedImplausible))
        .padding(.horizontal, NoopMetrics.screenPadding)
        .padding(.vertical, NoopMetrics.space3)
        .background(StrandPalette.surfaceBase)
    }

    private var successMark: some View {
        ZStack {
            StrandPalette.surfaceBase.opacity(0.85).ignoresSafeArea()
            VStack(spacing: NoopMetrics.space3) {
                Image(systemName: "checkmark.circle.fill")
                    .font(StrandFont.display(64))
                    .foregroundStyle(StrandPalette.accent)
                    .transition(.scale.combined(with: .opacity))
                Text("Logged").font(StrandFont.headline).foregroundStyle(StrandPalette.textPrimary)
            }
        }
        .transition(.opacity)
        .accessibilityElement(children: .combine)
    }
}
#endif

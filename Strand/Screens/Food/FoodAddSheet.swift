#if os(iOS)
import SwiftUI
import PhotosUI
import UIKit
import StrandDesign
import StrandNutrition
import WhoopStore

/// The add-food flow: a camera-first root (`FoodCaptureView`) and the sheets behind it.
/// Nothing is saved before an explicit Log, and every photo or description bound for Anthropic
/// passes one gate: credentials, then the one-time notice.
struct FoodAddSheet: View {
    @ObservedObject var model: FoodLogModel
    @Environment(\.dismiss) private var dismiss
    @AppStorage("food.photoNoticeShown") private var photoNoticeShown = false

    /// What a photo is for: a meal estimate, or reading the nutrition table of a scanned barcode.
    private enum PhotoPurpose: Equatable { case meal, label(barcode: String) }

    /// Every action that sends user-provided content to Anthropic passes through one gate.
    private enum AnthropicAction {
        case capture(PhotoPurpose)
        case library(PhotoPurpose)
        case description
    }

    private enum Step: Identifiable {
        case describe
        case review
        case working(String)
        case portion(FoodProductRow, lastGrams: Double?)
        case notFound(barcode: String, reason: String)
        case manualProduct(barcode: String)
        case quickAdd
        case recentPortion(FoodEntryRow)

        var id: String {
            switch self {
            case .describe: return "describe"
            case .review: return "review"
            case .working(let t): return "working-\(t)"
            case .portion(let p, _): return "portion-\(p.id)"
            case .notFound(let c, _): return "notFound-\(c)"
            case .manualProduct(let c): return "manual-\(c)"
            case .quickAdd: return "quickAdd"
            case .recentPortion(let r): return "recent-\(r.id)"
            }
        }
    }

    @StateObject private var scanner = FoodScannerController()
    @State private var mode: FoodCaptureMode = .meal
    @State private var labelBarcode: String?
    @State private var step: Step?
    @State private var pendingAnthropicAction: AnthropicAction?
    @State private var showAnthropicNotice = false
    @State private var showLibrary = false
    @State private var libraryItem: PhotosPickerItem?
    @State private var libraryPurpose: PhotoPurpose = .meal
    @State private var suggestions: [FoodEntryRow] = []
    @State private var toast: String?
    @State private var toastToken = UUID()
    @State private var successTick = 0
    @State private var warningTick = 0
    /// Identifies the in-flight Claude or lookup request; a result for an older one is dropped.
    @State private var requestToken = UUID()
    /// A photo is being taken or loaded and has not been handed to a step yet.
    @State private var busy = false
    /// A food-log write is in flight; a second Log tap is ignored until it returns.
    @State private var saving = false
    /// Bumped on every deferred presentation and every newly opened step, so a stale deferral
    /// never presents over a newer screen.
    @State private var transitionGen = 0
    /// Why the last save from an open sheet failed, shown inside that sheet.
    @State private var sheetError: String?

    // Review state: the header and Claude's items (nil while working).
    @State private var reviewHeader: FoodReviewView.Header = .text("")
    @State private var reviewItems: [FoodVisionReply.MealItem]?
    @State private var reviewSource = "photo"
    @State private var reviewAt = Date()

    var body: some View {
        FoodCaptureView(
            mode: $mode, scanner: scanner, labelBarcode: labelBarcode, suggestions: suggestions, toast: toast,
            busy: busy,
            onClose: { dismiss() },
            onShutter: shutter,
            onLibrary: { requestAnthropic(.library(libraryPurposeForMode)) },
            onDescribe: { requestAnthropic(.description) },
            onQuickAdd: { step = .quickAdd },
            onRelog: relog,
            onAdjust: { step = .recentPortion($0) })
        .sensoryFeedback(.success, trigger: successTick)
        .sensoryFeedback(.warning, trigger: warningTick)
        .alert("Sent to Anthropic", isPresented: $showAnthropicNotice) {
            Button("Continue") {
                photoNoticeShown = true
                if let action = pendingAnthropicAction { openAnthropic(action) }
            }
            Button("Cancel", role: .cancel) { pendingAnthropicAction = nil }
        } message: {
            Text("To recognise food, read a label, or estimate a typed meal description, NOOP sends the photo or description once to Anthropic with your own API key. Photos are not stored.")
        }
        .photosPicker(isPresented: $showLibrary, selection: $libraryItem, matching: .images)
        .onChange(of: libraryItem) { _, item in
            guard let item else { return }
            libraryItem = nil
            let purpose = libraryPurpose
            let token = UUID()
            requestToken = token
            busy = true
            Task {
                let data = try? await item.loadTransferable(type: Data.self)
                busy = false
                guard requestToken == token, step == nil else { return }
                if let data { process(data, purpose, token: token) }
                else { show(String(localized: "Couldn't open that photo."), warning: true) }
            }
        }
        .sheet(item: $step, onDismiss: {
            // A swipe-dismissed sheet abandons its request; a sheet swapped for the next step does not.
            if step == nil { requestToken = UUID() }
        }) { s in
            sheet(for: s)
                .safeAreaInset(edge: .top) {
                    if let sheetError {
                        Text(sheetError)
                            .font(StrandFont.footnote)
                            .foregroundStyle(StrandPalette.statusCritical)
                            .frame(maxWidth: .infinity, alignment: .leading)
                            .padding(.horizontal, NoopMetrics.screenPadding)
                            .padding(.vertical, NoopMetrics.space2)
                            .background(StrandPalette.surfaceRaised)
                    }
                }
        }
        .onChange(of: step?.id) { _, id in
            sheetError = nil
            if id != nil { transitionGen += 1 }
        }
        // Nothing scans or lights the torch behind a sheet, the notice or the photo picker.
        .onChange(of: coversCamera) { _, covered in covered ? scanner.pause() : scanner.resume() }
        .onAppear { scanner.onBarcode = handleScanned }
        .task { await loadSuggestions() }
    }

    private var coversCamera: Bool { step != nil || showAnthropicNotice || showLibrary }

    private var libraryPurposeForMode: PhotoPurpose {
        if mode == .label, let code = labelBarcode { return .label(barcode: code) }
        return .meal
    }

    // MARK: Gate

    private func requestAnthropic(_ action: AnthropicAction) {
        do { _ = try FoodVisionService.credentials() } catch {
            step = nil
            show(error.localizedDescription, warning: true)
            return
        }
        if photoNoticeShown { openAnthropic(action) }
        else {
            pendingAnthropicAction = action
            afterSheetCloses { showAnthropicNotice = true }
        }
    }

    /// Closes any open sheet first: an alert or picker asked for while a sheet is still up never shows.
    private func afterSheetCloses(_ action: @escaping () -> Void) {
        transitionGen += 1
        let gen = transitionGen
        guard step != nil else { action(); return }
        step = nil
        Task {
            try? await Task.sleep(nanoseconds: 600_000_000)
            guard transitionGen == gen, step == nil else { return }
            action()
        }
    }

    private func openAnthropic(_ action: AnthropicAction) {
        pendingAnthropicAction = nil
        switch action {
        case .capture(let purpose):
            guard !busy else { return }
            let token = UUID()
            requestToken = token
            busy = true
            Task {
                let data = await scanner.capture()
                busy = false
                guard requestToken == token, step == nil else { return }
                guard let data else {
                    show(String(localized: "Couldn't take the photo. Try again."), warning: true)
                    return
                }
                process(data, purpose, token: token)
            }
        case .library(let purpose):
            libraryPurpose = purpose
            afterSheetCloses { showLibrary = true }
        case .description:
            step = .describe
        }
    }

    // MARK: Capture actions

    private func shutter() {
        switch mode {
        case .meal:
            requestAnthropic(.capture(.meal))
        case .label:
            if let code = labelBarcode { requestAnthropic(.capture(.label(barcode: code))) }
            else { show(String(localized: "Scan the product's barcode first, then photograph its nutrition table."), warning: true) }
        case .barcode:
            break
        }
    }

    /// Live barcodes: Barcode mode looks the product up at once; Label mode remembers the code
    /// the nutrition-table photo will be filed under. Ignored while a sheet is open.
    private func handleScanned(_ code: String) {
        guard step == nil, !showAnthropicNotice, !showLibrary, !busy else { return }
        switch mode {
        case .barcode:
            successTick += 1
            let token = UUID()
            requestToken = token
            step = .working(String(localized: "Looking up product..."))
            Task { await handleBarcode(code, token: token) }
        case .label:
            if labelBarcode != code {
                labelBarcode = code
                successTick += 1
            }
        case .meal:
            break
        }
    }

    private func relog(_ r: FoodEntryRow) {
        Task {
            if await model.relog(r) {
                successTick += 1
                show(String(localized: "Logged \(r.name)"))
                await loadSuggestions()
            } else {
                show(model.errorMessage ?? String(localized: "Couldn't save. Try again."), warning: true)
            }
        }
    }

    // MARK: Sheets

    @ViewBuilder private func sheet(for s: Step) -> some View {
        switch s {
        case .describe:
            FoodDescribeView { text in
                startReview(header: .text(text), source: "describe")
                let token = requestToken
                Task { await handleDescription(text, token: token) }
            }
        case .review:
            NavigationStack {
                FoodReviewView(
                    header: reviewHeader, loggedAt: reviewAt, items: reviewItems,
                    today: model.totals, targets: model.targets, errorMessage: model.errorMessage,
                    log: { items in
                        await model.log(items.map {
                            .init(name: $0.name, grams: $0.grams, per100g: $0.per100g, source: reviewSource, productId: nil)
                        })
                    },
                    onFinished: { step = nil; dismiss() })
                .navigationTitle(String(localized: "Review"))
                .navigationBarTitleDisplayMode(.inline)
                .toolbar { cancelItem }
            }
            .interactiveDismissDisabled(reviewItems != nil)
        case .working(let text):
            NavigationStack {
                FoodWorkingView(text: text)
                    .toolbar { cancelItem }
            }
        case .portion(let p, let last):
            NavigationStack {
                FoodPortionView(name: p.name, per100g: p.per100g, servingGrams: p.servingGrams, lastGrams: last,
                                today: model.totals, targets: model.targets) { g in
                    let source = p.origin == "label" ? "label" : (p.origin == "manual" ? "quick" : "barcode")
                    save { await model.log([.init(name: p.name, grams: g, per100g: p.per100g, source: source, productId: p.id)]) }
                }
                .navigationBarTitleDisplayMode(.inline)
                .toolbar { cancelItem }
            }
        case .notFound(let code, let reason):
            NavigationStack {
                VStack(alignment: .leading, spacing: NoopMetrics.sectionGap) {
                    Text(reason).font(StrandFont.title2).foregroundStyle(StrandPalette.textPrimary)
                    Text("Read the nutrition table instead, or type the values from the pack.")
                        .font(StrandFont.subhead).foregroundStyle(StrandPalette.textSecondary)
                    NoopButton("Photograph the nutrition table", systemImage: "camera.fill", kind: .primary, fullWidth: true) {
                        labelBarcode = code
                        if scanner.availability == .ready {
                            step = nil
                            withAnimation(StrandMotion.interactive) { mode = .label }
                        } else {
                            requestAnthropic(.library(.label(barcode: code)))
                        }
                    }
                    NoopButton("Enter per 100 g by hand", systemImage: "square.and.pencil", kind: .secondary, fullWidth: true) {
                        step = .manualProduct(barcode: code)
                    }
                    Spacer()
                }
                .padding(NoopMetrics.screenPadding)
                .background(StrandPalette.surfaceBase)
                .toolbar { cancelItem }
            }
        case .manualProduct(let code):
            NavigationStack {
                // Save only builds and caches the product; the food is logged from the portion screen.
                FoodManualEntryView(mode: .product) { name, per100g, _ in
                    let started = step?.id
                    Task {
                        // Cache under the barcode so the next scan of this product works offline.
                        let row = FoodProductRow(id: code, deviceId: FoodLog.deviceId, name: name, brand: nil,
                                                 kcal100: per100g.kcal, protein100: per100g.protein,
                                                 carbs100: per100g.carbs, fat100: per100g.fat, servingGrams: nil,
                                                 origin: "manual", updatedAt: Int(Date().timeIntervalSince1970))
                        if let store = await model.store() { try? await store.upsertFoodProduct(row) }
                        guard step?.id == started else { return }
                        step = .portion(row, lastGrams: nil)
                    }
                }
                .navigationTitle(String(localized: "Per 100 g"))
                .navigationBarTitleDisplayMode(.inline)
                .toolbar { cancelItem }
            }
        case .quickAdd:
            NavigationStack {
                quickAddForm
                    .navigationTitle(String(localized: "Quick add"))
                    .navigationBarTitleDisplayMode(.inline)
                    .toolbar { cancelItem }
            }
        case .recentPortion(let r):
            NavigationStack {
                Group {
                    if let g = r.grams, g > 0 {
                        let per100 = MacroPer100g(kcal: r.kcal / g * 100, protein: r.proteinG / g * 100,
                                                  carbs: r.carbsG / g * 100, fat: r.fatG / g * 100)
                        FoodPortionView(name: r.name, per100g: per100, servingGrams: nil, lastGrams: g,
                                        today: model.totals, targets: model.targets) { newG in
                            save { await model.relog(r, grams: newG) }
                        }
                    } else {
                        quickAddForm
                    }
                }
                .navigationBarTitleDisplayMode(.inline)
                .toolbar { cancelItem }
            }
        }
    }

    private var quickAddForm: some View {
        FoodManualEntryView(mode: .totals) { name, v, _ in
            save { await model.quickAdd(name: name, macros: Macros(kcal: v.kcal, protein: v.protein,
                                                                   carbs: v.carbs, fat: v.fat)) }
        }
    }

    @ToolbarContentBuilder private var cancelItem: some ToolbarContent {
        ToolbarItem(placement: .cancellationAction) {
            Button(String(localized: "Cancel")) { requestToken = UUID(); step = nil }
        }
    }

    // MARK: Results

    /// Runs one save for the open sheet. Dismisses only when the write succeeded and that sheet is
    /// still the one showing; on failure the sheet stays open with its values and shows why.
    private func save(_ op: @escaping () async -> Bool) {
        guard !saving else { return }
        saving = true
        let started = step?.id
        Task {
            let ok = await op()
            saving = false
            let failure = model.errorMessage ?? String(localized: "Couldn't save. Try again.")
            guard step?.id == started else {
                // The sheet that asked was closed meanwhile: report the outcome over the camera.
                if ok { successTick += 1; show(String(localized: "Logged")) } else { show(failure, warning: true) }
                return
            }
            if ok {
                successTick += 1
                step = nil
                dismiss()
            } else {
                warningTick += 1
                sheetError = failure
            }
        }
    }

    /// A short message over the camera that clears itself.
    private func show(_ text: String, warning: Bool = false) {
        if warning { warningTick += 1 }
        let token = UUID()
        toastToken = token
        toast = text
        Task {
            try? await Task.sleep(nanoseconds: warning ? 3_500_000_000 : 1_600_000_000)
            if toastToken == token { toast = nil }
        }
    }

    private func startReview(header: FoodReviewView.Header, source: String, token: UUID = UUID()) {
        model.errorMessage = nil
        reviewHeader = header
        reviewItems = nil
        reviewSource = source
        reviewAt = Date()
        requestToken = token
        step = .review
    }

    /// Hands a photo to its step. `token` is the request taken before the photo was captured or loaded.
    private func process(_ data: Data, _ purpose: PhotoPurpose, token: UUID) {
        switch purpose {
        case .meal:
            startReview(header: UIImage(data: data).map { .photo($0) } ?? .text(""), source: "photo", token: token)
            Task { await handleMealPhoto(data, token: token) }
        case .label(let barcode):
            requestToken = token
            step = .working(String(localized: "Reading the nutrition table..."))
            Task { await handleLabel(data, barcode: barcode, token: token) }
        }
    }

    private func handleMealPhoto(_ data: Data, token: UUID) async {
        do {
            let items = try await FoodVisionService.analyzeMeal(photo: data)
            guard requestToken == token else { return }
            reviewItems = items
        } catch FoodVisionReply.Failure.nothingRecognised {
            fail(String(localized: "No food recognised in this photo. Try again or use Quick add."), token: token)
        } catch {
            fail(String(localized: "Couldn't read this photo: ") + error.localizedDescription, token: token)
        }
    }

    private func handleLabel(_ data: Data, barcode: String, token: UUID) async {
        do {
            let l = try await FoodVisionService.readLabel(photo: data)
            let row = FoodProductRow(id: barcode, deviceId: FoodLog.deviceId, name: l.name, brand: nil,
                                     kcal100: l.per100g.kcal, protein100: l.per100g.protein,
                                     carbs100: l.per100g.carbs, fat100: l.per100g.fat,
                                     servingGrams: l.servingGrams, origin: "label",
                                     updatedAt: Int(Date().timeIntervalSince1970))
            // An abandoned read writes nothing, not even the product cache.
            guard requestToken == token else { return }
            if let store = await model.store() { try await store.upsertFoodProduct(row) }
            guard requestToken == token else { return }
            labelBarcode = nil
            step = .portion(row, lastGrams: nil)
        } catch FoodVisionReply.Failure.nothingRecognised {
            fail(String(localized: "No nutrition table recognised. Try again closer and in good light."), token: token)
        } catch {
            fail(String(localized: "Couldn't read this photo: ") + error.localizedDescription, token: token)
        }
    }

    private func handleDescription(_ text: String, token: UUID) async {
        do {
            let items = try await FoodVisionService.analyzeDescription(text)
            guard requestToken == token else { return }
            reviewItems = items
        } catch FoodVisionReply.Failure.nothingRecognised {
            fail(String(localized: "No food recognised in this description. Try again or use Quick add."), token: token)
        } catch {
            fail(String(localized: "Couldn't estimate this meal: ") + error.localizedDescription, token: token)
        }
    }

    private func fail(_ text: String, token: UUID) {
        guard requestToken == token else { return }
        step = nil
        show(text, warning: true)
    }

    private func handleBarcode(_ code: String, token: UUID) async {
        guard let store = await model.store() else { fail(String(localized: "Couldn't open the food log."), token: token); return }
        let next: Step
        do {
            switch try await FoodProductLookup.lookup(barcode: code, store: store) {
            case .product(let p):
                next = .portion(p, lastGrams: model.recent.first { $0.productId == p.id }?.grams)
            case .incomplete(let name):
                next = .notFound(barcode: code, reason: String(localized: "\(name) has no complete nutrition data."))
            case .notFound:
                next = .notFound(barcode: code, reason: String(localized: "Product not found."))
            case .lookupDisabled:
                next = .notFound(barcode: code, reason: String(localized: "New product. Online lookup is off (Settings > Food logging)."))
            }
        } catch {
            next = .notFound(barcode: code, reason: String(localized: "Lookup failed. Check your connection."))
        }
        guard requestToken == token else { return }
        step = next
    }

    /// One-tap re-log chips: the last 30 days ranked for this time of day, at most 8.
    private func loadSuggestions() async {
        guard let store = await model.store() else { return }
        let now = Date()
        let calendar = Calendar.current
        // Today plus the 29 calendar days before it: exactly 30 day keys, whatever the DST shifts.
        let start = calendar.date(byAdding: .day, value: -29, to: calendar.startOfDay(for: now)) ?? now
        let from = FoodDay.key(for: start, calendar: calendar)
        guard let rows = try? await store.foodEntries(deviceId: FoodLog.deviceId, from: from,
                                                      to: FoodDay.key(for: now, calendar: calendar))
        else { return }
        let ranked = TimeOfDaySuggestions.rank(
            rows.map { (name: $0.name, productId: $0.productId, loggedAt: Date(timeIntervalSince1970: TimeInterval($0.loggedAt))) },
            now: now, calendar: calendar, limit: 8)
        suggestions = ranked.map { rows[$0] }
    }
}

/// Calm placeholder while a barcode lookup or a label read runs: a shimmering product card.
private struct FoodWorkingView: View {
    let text: String

    var body: some View {
        VStack(alignment: .leading, spacing: NoopMetrics.sectionGap) {
            Text(text).font(StrandFont.subhead).foregroundStyle(StrandPalette.textSecondary)
            StrandCard {
                VStack(alignment: .leading, spacing: NoopMetrics.space3) {
                    Text(verbatim: "Product name here").font(StrandFont.title2)
                    Text(verbatim: "Per 100 g: 000 kcal").font(StrandFont.footnote)
                    Text(verbatim: "000 kcal").font(StrandFont.title1)
                }
            }
            .foodShimmer()
            Spacer()
        }
        .padding(NoopMetrics.screenPadding)
        .frame(maxWidth: .infinity, maxHeight: .infinity, alignment: .topLeading)
        .background(StrandPalette.surfaceBase)
    }
}
#endif

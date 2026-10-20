#if os(iOS)
import SwiftUI
import PhotosUI
import StrandDesign
import StrandNutrition
import WhoopStore

/// Photo / Barcode / Recent / Quick add, and the flows behind them.
struct FoodAddSheet: View {
    @ObservedObject var model: FoodLogModel
    @Environment(\.dismiss) private var dismiss
    @AppStorage("food.photoNoticeShown") private var photoNoticeShown = false

    /// What a photo is for: a meal estimate, or reading the nutrition table of a scanned barcode.
    private enum PhotoPurpose: Equatable { case meal, label(barcode: String) }

    private enum Step: Identifiable {
        case camera(PhotoPurpose)
        case library(PhotoPurpose)
        case scanner
        case working(String)
        case confirm([FoodVisionReply.MealItem])
        case portion(FoodProductRow, lastGrams: Double?)
        case notFound(barcode: String, reason: String)
        case manualProduct(barcode: String)
        case quickAdd
        case recentPortion(FoodEntryRow)

        var id: String {
            switch self {
            case .camera: return "camera"
            case .library: return "library"
            case .scanner: return "scanner"
            case .working(let t): return "working-\(t)"
            case .confirm: return "confirm"
            case .portion(let p, _): return "portion-\(p.id)"
            case .notFound(let c, _): return "notFound-\(c)"
            case .manualProduct(let c): return "manual-\(c)"
            case .quickAdd: return "quickAdd"
            case .recentPortion(let r): return "recent-\(r.id)"
            }
        }
    }

    @State private var step: Step?
    @State private var pendingPhoto: (PhotoPurpose, fromLibrary: Bool)?
    @State private var showPhotoNotice = false
    @State private var libraryItem: PhotosPickerItem?
    @State private var message: String?

    var body: some View {
        NavigationStack {
            VStack(alignment: .leading, spacing: 16) {
                HStack(spacing: 12) {
                    NoopButton("Photo", systemImage: "camera.fill", kind: .primary) { requestPhoto(.meal, fromLibrary: false) }
                    NoopButton("Barcode", systemImage: "barcode.viewfinder", kind: .primary) {
                        if BarcodeScannerView.isSupported { step = .scanner }
                        else { message = String(localized: "Barcode scanning is not available on this device.") }
                    }
                }
                HStack(spacing: 12) {
                    NoopButton("From library", systemImage: "photo.on.rectangle", kind: .secondary) {
                        requestPhoto(.meal, fromLibrary: true)
                    }
                    NoopButton("Quick add", systemImage: "plus", kind: .secondary) { step = .quickAdd }
                }
                if let message {
                    Text(message).font(StrandFont.footnote).foregroundStyle(StrandPalette.textSecondary)
                }
                Text("Recent").font(StrandFont.overline).foregroundStyle(StrandPalette.textTertiary)
                List(model.recent) { r in
                    Button {
                        Task { if await model.relog(r) { dismiss() } else { message = model.errorMessage } }
                    } label: {
                        HStack {
                            Text(r.name).foregroundStyle(StrandPalette.textPrimary)
                            Spacer()
                            Text(r.grams.map { String(format: "%.0f g", $0) } ?? "")
                                .font(StrandFont.captionNumber).foregroundStyle(StrandPalette.textSecondary)
                        }
                    }
                    .contextMenu { Button("Change amount") { step = .recentPortion(r) } }
                }
                .listStyle(.plain)
            }
            .padding(16)
            .background(StrandPalette.surfaceBase)
            .navigationTitle("Add food")
            .navigationBarTitleDisplayMode(.inline)
            .toolbar { ToolbarItem(placement: .cancellationAction) { Button("Close") { dismiss() } } }
            .alert("Photos are sent to Anthropic", isPresented: $showPhotoNotice) {
                Button("Continue") {
                    photoNoticeShown = true
                    if let (purpose, lib) = pendingPhoto { openPhoto(purpose, fromLibrary: lib) }
                }
                Button("Cancel", role: .cancel) { pendingPhoto = nil }
            } message: {
                Text("To recognise food or read a label, NOOP sends the photo once to Anthropic with your own API key. The photo is not stored.")
            }
            .sheet(item: $step) { s in sheet(for: s) }
        }
    }

    /// The single gate for EVERY photo (meal or label, camera or library): credentials, then the
    /// one-time notice, then the picker.
    private func requestPhoto(_ purpose: PhotoPurpose, fromLibrary: Bool) {
        do { _ = try FoodVisionService.credentials() } catch { message = error.localizedDescription; step = nil; return }
        if photoNoticeShown { openPhoto(purpose, fromLibrary: fromLibrary) }
        else { step = nil; pendingPhoto = (purpose, fromLibrary); showPhotoNotice = true }
    }

    private func openPhoto(_ purpose: PhotoPurpose, fromLibrary: Bool) {
        pendingPhoto = nil
        step = fromLibrary ? .library(purpose) : .camera(purpose)
    }

    @ViewBuilder private func sheet(for s: Step) -> some View {
        switch s {
        case .camera(let purpose):
            CameraPicker { data in
                guard let data else { step = nil; return }
                process(data, purpose)
            }
        case .library(let purpose):
            PhotosPicker("Choose a photo", selection: $libraryItem, matching: .images)
                .padding(16)
                .onChange(of: libraryItem) { _, item in
                    guard let item else { return }
                    Task {
                        libraryItem = nil
                        if let data = try? await item.loadTransferable(type: Data.self) { process(data, purpose) }
                        else { message = String(localized: "Couldn't open that photo."); step = nil }
                    }
                }
        case .scanner:
            BarcodeScannerView { code in
                step = .working(String(localized: "Looking up product..."))
                Task { await handleBarcode(code) }
            }
        case .working(let text):
            VStack(spacing: 12) { ProgressView(); Text(text).font(StrandFont.subhead) }
                .frame(maxWidth: .infinity, maxHeight: .infinity).background(StrandPalette.surfaceBase)
        case .confirm(let items):
            FoodPhotoConfirmView(items: items) { final in
                Task {
                    let ok = await model.log(final.map {
                        .init(name: $0.name, grams: $0.grams, per100g: $0.per100g, source: "photo", productId: nil)
                    })
                    finish(ok)
                }
            }
        case .portion(let p, let last):
            FoodPortionView(name: p.name, per100g: p.per100g, servingGrams: p.servingGrams, lastGrams: last) { g in
                Task {
                    let source = p.origin == "label" ? "label" : (p.origin == "manual" ? "quick" : "barcode")
                    finish(await model.log([.init(name: p.name, grams: g, per100g: p.per100g, source: source, productId: p.id)]))
                }
            }
        case .notFound(let code, let reason):
            VStack(alignment: .leading, spacing: 16) {
                Text(reason).font(StrandFont.subhead).foregroundStyle(StrandPalette.textPrimary)
                NoopButton("Photograph the nutrition table", systemImage: "camera.fill", kind: .primary) {
                    requestPhoto(.label(barcode: code), fromLibrary: false)
                }
                NoopButton("Enter per 100 g by hand", systemImage: "square.and.pencil", kind: .secondary) {
                    step = .manualProduct(barcode: code)
                }
                Spacer()
            }
            .padding(16).background(StrandPalette.surfaceBase)
        case .manualProduct(let code):
            FoodManualEntryView(mode: .per100g(grams: 100)) { name, per100g, grams in
                Task {
                    // Cache under the barcode so the next scan of this product works offline.
                    let row = FoodProductRow(id: code, deviceId: FoodLog.deviceId, name: name, brand: nil,
                                             kcal100: per100g.kcal, protein100: per100g.protein,
                                             carbs100: per100g.carbs, fat100: per100g.fat, servingGrams: nil,
                                             origin: "manual", updatedAt: Int(Date().timeIntervalSince1970))
                    if let store = await model.store() { try? await store.upsertFoodProduct(row) }
                    finish(await model.log([.init(name: name, grams: grams ?? 100, per100g: per100g,
                                                  source: "quick", productId: code)]))
                }
            }
        case .quickAdd:
            FoodManualEntryView(mode: .totals) { name, v, _ in
                Task { finish(await model.quickAdd(name: name, macros: Macros(kcal: v.kcal, protein: v.protein,
                                                                              carbs: v.carbs, fat: v.fat))) }
            }
        case .recentPortion(let r):
            if let g = r.grams, g > 0 {
                let per100 = MacroPer100g(kcal: r.kcal / g * 100, protein: r.proteinG / g * 100,
                                          carbs: r.carbsG / g * 100, fat: r.fatG / g * 100)
                FoodPortionView(name: r.name, per100g: per100, servingGrams: nil, lastGrams: g) { newG in
                    Task { finish(await model.relog(r, grams: newG)) }
                }
            } else {
                FoodManualEntryView(mode: .totals) { name, v, _ in
                    Task { finish(await model.quickAdd(name: name, macros: Macros(kcal: v.kcal, protein: v.protein,
                                                                                  carbs: v.carbs, fat: v.fat))) }
                }
            }
        }
    }

    /// Dismiss only when the write succeeded; otherwise show why and stay open.
    private func finish(_ ok: Bool) {
        step = nil
        if ok { dismiss() } else { message = model.errorMessage ?? String(localized: "Couldn't save. Try again.") }
    }

    private func process(_ data: Data, _ purpose: PhotoPurpose) {
        step = .working(String(localized: "Reading photo..."))
        Task { await handlePhoto(data, purpose) }
    }

    private func handlePhoto(_ data: Data, _ purpose: PhotoPurpose) async {
        do {
            switch purpose {
            case .label(let barcode):
                let l = try await FoodVisionService.readLabel(photo: data)
                let row = FoodProductRow(id: barcode, deviceId: FoodLog.deviceId, name: l.name, brand: nil,
                                         kcal100: l.per100g.kcal, protein100: l.per100g.protein,
                                         carbs100: l.per100g.carbs, fat100: l.per100g.fat,
                                         servingGrams: l.servingGrams, origin: "label",
                                         updatedAt: Int(Date().timeIntervalSince1970))
                if let store = await model.store() { try await store.upsertFoodProduct(row) }
                step = .portion(row, lastGrams: nil)
            case .meal:
                step = .confirm(try await FoodVisionService.analyzeMeal(photo: data))
            }
        } catch FoodVisionReply.Failure.nothingRecognised {
            message = String(localized: "No food recognised in this photo. Try again or use Quick add.")
            step = nil
        } catch {
            message = String(localized: "Couldn't read this photo: ") + error.localizedDescription
            step = nil
        }
    }

    private func handleBarcode(_ code: String) async {
        guard let store = await model.store() else { step = nil; return }
        do {
            switch try await FoodProductLookup.lookup(barcode: code, store: store) {
            case .product(let p):
                let last = model.recent.first { $0.productId == p.id }?.grams
                step = .portion(p, lastGrams: last)
            case .incomplete(let name):
                step = .notFound(barcode: code, reason: String(localized: "\(name) has no complete nutrition data."))
            case .notFound:
                step = .notFound(barcode: code, reason: String(localized: "Product not found."))
            case .lookupDisabled:
                step = .notFound(barcode: code, reason: String(localized: "New product. Online lookup is off (Settings > Food logging)."))
            }
        } catch {
            step = .notFound(barcode: code, reason: String(localized: "Lookup failed. Check your connection."))
        }
    }
}
#endif

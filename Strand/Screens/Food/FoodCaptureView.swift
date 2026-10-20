#if os(iOS)
import AVFoundation
import SwiftUI
import UIKit
import VisionKit
import StrandDesign
import StrandNutrition
import WhoopStore

/// What the one camera surface is doing: photographing a meal, reading a barcode live, or
/// photographing a nutrition table for a scanned barcode.
enum FoodCaptureMode: CaseIterable, Hashable {
    case meal, barcode, label

    var title: String {
        switch self {
        case .meal: return String(localized: "Meal")
        case .barcode: return String(localized: "Barcode")
        case .label: return String(localized: "Label")
        }
    }
}

/// Owns the live `DataScannerViewController`: availability, photo capture, torch and barcodes.
@MainActor
final class FoodScannerController: ObservableObject {
    enum Availability: Equatable { case ready, needsPermission, denied, unsupported }

    @Published private(set) var availability: Availability
    @Published private(set) var torchOn = false
    /// Called for every newly recognised EAN/UPC barcode; the owner decides what it means.
    var onBarcode: ((String) -> Void)?
    fileprivate weak var scanner: DataScannerViewController?

    init() { availability = Self.currentAvailability() }

    var hasTorch: Bool { AVCaptureDevice.default(for: .video)?.hasTorch ?? false }

    static func currentAvailability() -> Availability {
        guard DataScannerViewController.isSupported else { return .unsupported }
        switch AVCaptureDevice.authorizationStatus(for: .video) {
        case .notDetermined: return .needsPermission
        case .denied, .restricted: return .denied
        default: return DataScannerViewController.isAvailable ? .ready : .denied
        }
    }

    /// Shows the system camera prompt once, then settles on ready or denied.
    func prepare() async {
        if availability == .needsPermission {
            _ = await AVCaptureDevice.requestAccess(for: .video)
        }
        availability = Self.currentAvailability()
    }

    /// A still from the live scanner as JPEG, kept in memory only.
    func capture() async -> Data? {
        guard let scanner else { return nil }
        do { return try await scanner.capturePhoto().jpegData(compressionQuality: 0.9) } catch { return nil }
    }

    func toggleTorch() {
        guard let device = AVCaptureDevice.default(for: .video), device.hasTorch else { return }
        do {
            try device.lockForConfiguration()
            device.torchMode = torchOn ? .off : .on
            device.unlockForConfiguration()
            torchOn.toggle()
        } catch {}
    }

    fileprivate func attach(_ vc: DataScannerViewController) {
        scanner = vc
        try? vc.startScanning()
    }

    fileprivate func detach() {
        if torchOn { toggleTorch() }
        scanner?.stopScanning()
        scanner = nil
    }
}

/// The full-screen scanner surface.
private struct FoodScannerSurface: UIViewControllerRepresentable {
    let controller: FoodScannerController

    func makeCoordinator() -> Coordinator { Coordinator(controller: controller) }

    func makeUIViewController(context: Context) -> DataScannerViewController {
        let vc = DataScannerViewController(
            recognizedDataTypes: [.barcode(symbologies: [.ean13, .ean8, .upce])],
            qualityLevel: .balanced, recognizesMultipleItems: false,
            isHighFrameRateTrackingEnabled: false, isHighlightingEnabled: true)
        vc.delegate = context.coordinator
        controller.attach(vc)
        return vc
    }

    func updateUIViewController(_ vc: DataScannerViewController, context: Context) {}

    static func dismantleUIViewController(_ vc: DataScannerViewController, coordinator: Coordinator) {
        coordinator.controller.detach()
    }

    @MainActor
    final class Coordinator: NSObject, DataScannerViewControllerDelegate {
        let controller: FoodScannerController
        init(controller: FoodScannerController) { self.controller = controller }

        func dataScanner(_ s: DataScannerViewController, didAdd items: [RecognizedItem], allItems: [RecognizedItem]) {
            for case .barcode(let b) in items {
                if let code = b.payloadStringValue, !code.isEmpty {
                    controller.onBarcode?(code)
                    return
                }
            }
        }
    }
}

/// The root of the add-food flow: one camera with Meal / Barcode / Label modes, one-tap re-log
/// chips, and Library / Describe / Quick add. Falls back to a calm screen without a camera.
struct FoodCaptureView: View {
    @Binding var mode: FoodCaptureMode
    @ObservedObject var scanner: FoodScannerController
    /// The barcode a Label photo will be filed under, once one has been scanned.
    let labelBarcode: String?
    let suggestions: [FoodEntryRow]
    /// A transient confirmation ("Logged") or an explanation of what went wrong.
    let toast: String?
    let onClose: () -> Void
    let onShutter: () -> Void
    let onLibrary: () -> Void
    let onDescribe: () -> Void
    let onQuickAdd: () -> Void
    let onRelog: (FoodEntryRow) -> Void
    let onAdjust: (FoodEntryRow) -> Void

    @Environment(\.openURL) private var openURL

    var body: some View {
        Group {
            if scanner.availability == .ready {
                cameraLayout
            } else {
                fallbackLayout
            }
        }
        .overlay(alignment: .top) { toastView }
        .animation(StrandMotion.gentle, value: toast)
        .task { await scanner.prepare() }
    }

    // MARK: Camera

    private var cameraLayout: some View {
        ZStack {
            FoodScannerSurface(controller: scanner)
                .ignoresSafeArea()
            VStack(spacing: NoopMetrics.space3) {
                topBar
                Spacer()
                hint
                suggestionRow
                modeSwitcher
                bottomControls
            }
            .padding(.bottom, NoopMetrics.space2)
        }
        .background(StrandPalette.surfaceBase.ignoresSafeArea())
        .environment(\.colorScheme, .dark)
    }

    private var topBar: some View {
        HStack(spacing: NoopMetrics.space3) {
            circleButton("xmark", label: String(localized: "Close"), action: onClose)
            Spacer()
            if scanner.hasTorch {
                circleButton(scanner.torchOn ? "flashlight.on.fill" : "flashlight.off.fill",
                             label: String(localized: "Torch")) { scanner.toggleTorch() }
                    .sensoryFeedback(.selection, trigger: scanner.torchOn)
            }
            Button(action: onDescribe) {
                Label(String(localized: "Describe"), systemImage: "text.bubble")
                    .font(StrandFont.subhead)
                    .foregroundStyle(StrandPalette.onDarkPrimary)
                    .padding(.horizontal, NoopMetrics.space3)
                    .frame(height: NoopMetrics.compactControlSize + NoopMetrics.space2)
                    .background(.ultraThinMaterial, in: Capsule())
            }
            .buttonStyle(.plain)
        }
        .padding(.horizontal, NoopMetrics.screenPadding)
        .padding(.top, NoopMetrics.space2)
    }

    private var hint: some View {
        Text(hintText)
            .font(StrandFont.footnote)
            .foregroundStyle(StrandPalette.onDarkPrimary)
            .multilineTextAlignment(.center)
            .padding(.horizontal, NoopMetrics.space3)
            .padding(.vertical, NoopMetrics.space2)
            .background(.ultraThinMaterial, in: Capsule())
            .padding(.horizontal, NoopMetrics.screenPadding)
            .id(hintText)
            .transition(.opacity)
    }

    private var hintText: String {
        switch mode {
        case .meal: return String(localized: "Frame your plate, then tap the shutter.")
        case .barcode: return String(localized: "Point at a barcode.")
        case .label:
            if let labelBarcode {
                return String(localized: "Barcode \(labelBarcode) found. Now photograph the nutrition table.")
            }
            return String(localized: "Scan the barcode first, then photograph the nutrition table.")
        }
    }

    private var modeSwitcher: some View {
        HStack(spacing: NoopMetrics.space1) {
            ForEach(FoodCaptureMode.allCases, id: \.self) { m in
                Button { withAnimation(StrandMotion.interactive) { mode = m } } label: {
                    Text(m.title)
                        .font(StrandFont.subhead)
                        .foregroundStyle(mode == m ? StrandPalette.surfaceBase : StrandPalette.onDarkPrimary)
                        .padding(.horizontal, NoopMetrics.space4)
                        .padding(.vertical, NoopMetrics.space2)
                        .background {
                            if mode == m { Capsule().fill(StrandPalette.onDarkPrimary) }
                        }
                }
                .buttonStyle(.plain)
                .accessibilityAddTraits(mode == m ? .isSelected : [])
            }
        }
        .padding(NoopMetrics.space1)
        .background(.ultraThinMaterial, in: Capsule())
        .sensoryFeedback(.selection, trigger: mode)
    }

    private var bottomControls: some View {
        HStack {
            circleButton("photo.on.rectangle", label: String(localized: "Library"), large: true, action: onLibrary)
            Spacer()
            shutter
            Spacer()
            circleButton("square.and.pencil", label: String(localized: "Quick add"), large: true, action: onQuickAdd)
        }
        .padding(.horizontal, NoopMetrics.space8)
        // Horizontal swipes anywhere on the controls change mode.
        .contentShape(Rectangle())
        .gesture(DragGesture(minimumDistance: NoopMetrics.space6).onEnded { v in
            guard abs(v.translation.width) > abs(v.translation.height) else { return }
            let all = FoodCaptureMode.allCases
            guard let i = all.firstIndex(of: mode) else { return }
            let next = v.translation.width < 0 ? min(i + 1, all.count - 1) : max(i - 1, 0)
            withAnimation(StrandMotion.interactive) { mode = all[next] }
        })
    }

    private var shutterSize: CGFloat { NoopMetrics.tileHeight * 0.75 }

    private var shutter: some View {
        ZStack {
            if mode != .barcode {
                Button(action: onShutter) {
                    ZStack {
                        Circle().stroke(StrandPalette.onDarkPrimary, lineWidth: NoopMetrics.space1)
                        Circle().fill(StrandPalette.onDarkPrimary).padding(NoopMetrics.space2)
                    }
                }
                .buttonStyle(StrandPressableButtonStyle(cornerRadius: shutterSize / 2, scale: 0.92))
                .accessibilityLabel(mode == .meal ? String(localized: "Photograph meal")
                                                  : String(localized: "Photograph nutrition table"))
                .transition(.scale.combined(with: .opacity))
            }
        }
        .frame(width: shutterSize, height: shutterSize)
        .animation(StrandMotion.gentle, value: mode)
    }

    private func circleButton(_ icon: String, label: String, large: Bool = false,
                              action: @escaping () -> Void) -> some View {
        let size = large ? NoopMetrics.compactControlSize + NoopMetrics.space4 : NoopMetrics.compactControlSize + NoopMetrics.space2
        return Button(action: action) {
            Image(systemName: icon)
                .font(large ? StrandFont.title2 : StrandFont.headline)
                .foregroundStyle(StrandPalette.onDarkPrimary)
                .frame(width: size, height: size)
                .background(.ultraThinMaterial, in: Circle())
        }
        .buttonStyle(.plain)
        .accessibilityLabel(label)
    }

    // MARK: Suggestions

    @ViewBuilder private var suggestionRow: some View {
        if !suggestions.isEmpty {
            ScrollView(.horizontal, showsIndicators: false) {
                HStack(spacing: NoopMetrics.space2) {
                    ForEach(suggestions) { r in suggestionChip(r) }
                }
                .padding(.horizontal, NoopMetrics.screenPadding)
            }
        }
    }

    private func suggestionChip(_ r: FoodEntryRow) -> some View {
        HStack(spacing: NoopMetrics.space1) {
            Image(systemName: "arrow.counterclockwise").font(StrandFont.caption)
            Text(r.name).font(StrandFont.subhead).lineLimit(1)
            Text(String(localized: "\(FoodNumber.string(r.kcal)) kcal"))
                .font(StrandFont.captionNumber)
                .foregroundStyle(StrandPalette.textSecondary)
        }
        .foregroundStyle(StrandPalette.textPrimary)
        .padding(.horizontal, NoopMetrics.space3)
        .padding(.vertical, NoopMetrics.space2)
        .background(.ultraThinMaterial, in: Capsule())
        .contentShape(Capsule())
        .onTapGesture { onRelog(r) }
        .onLongPressGesture { onAdjust(r) }
        .accessibilityElement(children: .combine)
        .accessibilityAddTraits(.isButton)
        .accessibilityHint(String(localized: "Logs this again now. Touch and hold to change the amount."))
        .accessibilityAction(named: String(localized: "Change amount")) { onAdjust(r) }
    }

    // MARK: Fallback

    private var fallbackLayout: some View {
        VStack(spacing: NoopMetrics.sectionGap) {
            HStack {
                Button(String(localized: "Close"), action: onClose)
                    .font(StrandFont.body)
                    .foregroundStyle(StrandPalette.accent)
                Spacer()
            }
            .padding(.horizontal, NoopMetrics.screenPadding)
            .padding(.top, NoopMetrics.space2)

            Spacer(minLength: 0)
            VStack(spacing: NoopMetrics.space3) {
                Image(systemName: "camera.metering.unknown")
                    .font(StrandFont.display(48))
                    .foregroundStyle(StrandPalette.textTertiary)
                Text(fallbackTitle)
                    .font(StrandFont.title2)
                    .foregroundStyle(StrandPalette.textPrimary)
                    .multilineTextAlignment(.center)
                Text(fallbackBody)
                    .font(StrandFont.subhead)
                    .foregroundStyle(StrandPalette.textSecondary)
                    .multilineTextAlignment(.center)
                if scanner.availability == .denied {
                    Button(String(localized: "Allow camera in Settings")) {
                        if let url = URL(string: UIApplication.openSettingsURLString) { openURL(url) }
                    }
                    .font(StrandFont.subhead)
                    .foregroundStyle(StrandPalette.accent)
                }
            }
            .padding(.horizontal, NoopMetrics.space8)
            Spacer(minLength: 0)

            if !suggestions.isEmpty {
                VStack(alignment: .leading, spacing: NoopMetrics.space2) {
                    Text("Log again")
                        .font(StrandFont.overline)
                        .foregroundStyle(StrandPalette.textTertiary)
                        .padding(.horizontal, NoopMetrics.screenPadding)
                    suggestionRow
                }
            }
            VStack(spacing: NoopMetrics.space3) {
                NoopButton("Choose a photo", systemImage: "photo.on.rectangle", kind: .primary, fullWidth: true,
                           action: onLibrary)
                HStack(spacing: NoopMetrics.space3) {
                    NoopButton("Describe", systemImage: "text.bubble", kind: .secondary, fullWidth: true,
                               action: onDescribe)
                    NoopButton("Quick add", systemImage: "square.and.pencil", kind: .secondary, fullWidth: true,
                               action: onQuickAdd)
                }
            }
            .padding(.horizontal, NoopMetrics.screenPadding)
            .padding(.bottom, NoopMetrics.space4)
        }
        .background(StrandPalette.surfaceBase.ignoresSafeArea())
    }

    private var fallbackTitle: String {
        switch scanner.availability {
        case .denied: return String(localized: "Camera access is off")
        case .needsPermission: return String(localized: "Waiting for camera access")
        default: return String(localized: "No camera here")
        }
    }

    private var fallbackBody: String {
        switch scanner.availability {
        case .denied:
            return String(localized: "Turn on camera access to photograph meals and scan barcodes. You can still log from a photo, a description or by hand.")
        default:
            return String(localized: "This device can't scan with the camera. You can still log from a photo, a description or by hand.")
        }
    }

    // MARK: Toast

    @ViewBuilder private var toastView: some View {
        if let toast {
            Text(toast)
                .font(StrandFont.subhead)
                .foregroundStyle(StrandPalette.textPrimary)
                .multilineTextAlignment(.center)
                .padding(.horizontal, NoopMetrics.space4)
                .padding(.vertical, NoopMetrics.space2)
                .background(.regularMaterial, in: Capsule())
                .padding(.top, NoopMetrics.space10 + NoopMetrics.space4)
                .padding(.horizontal, NoopMetrics.screenPadding)
                .transition(.move(edge: .top).combined(with: .opacity))
                .accessibilityAddTraits(.updatesFrequently)
        }
    }
}
#endif

import SwiftUI
import StrandDesign

/// The bike training controls (FTP, target intensity band, fuelling reminders). Embedded in the
/// Settings "Bike training" card and in the sheet the live bike layout opens from "Set FTP".
struct BikeTrainingSettingsFields: View {
    @AppStorage(BikeTrainingPrefs.ftpKey) private var ftpW = 0
    @AppStorage(BikeTrainingPrefs.targetIFLowKey) private var ifLow = BikeTrainingPrefs.defaultTargetIFLow
    @AppStorage(BikeTrainingPrefs.targetIFHighKey) private var ifHigh = BikeTrainingPrefs.defaultTargetIFHigh
    @AppStorage(BikeTrainingPrefs.fuelIntervalKey) private var fuelInterval = BikeTrainingPrefs.defaultFuelIntervalMin
    @AppStorage(BikeTrainingPrefs.carbsPerHourKey) private var carbsPerHour = BikeTrainingPrefs.defaultCarbsPerHour

    var body: some View {
        VStack(alignment: .leading, spacing: NoopMetrics.space3) {
            HStack {
                VStack(alignment: .leading, spacing: NoopMetrics.spaceHalf) {
                    Text("FTP (W)").font(StrandFont.subhead).foregroundStyle(StrandPalette.textPrimary)
                    Text("Functional threshold power. Run the guided FTP test to measure it.")
                        .font(StrandFont.footnote).foregroundStyle(StrandPalette.textTertiary)
                        .fixedSize(horizontal: false, vertical: true)
                }
                Spacer()
                TextField("0", value: $ftpW, format: .number)
                    #if os(iOS)
                    .keyboardType(.numberPad)
                    #endif
                    .multilineTextAlignment(.trailing)
                    .font(StrandFont.bodyNumber)
                    .frame(width: 80)
            }
            Divider().overlay(StrandPalette.hairline)
            Stepper(value: $ifLow, in: 0.40...1.20, step: 0.01) {
                row("Target IF low", String(format: "%.2f", ifLow))
            }
            Stepper(value: $ifHigh, in: 0.40...1.20, step: 0.01) {
                row("Target IF high", String(format: "%.2f", ifHigh))
            }
            if let watts = BikeTrainingPrefs.targetWatts(ftp: BikeTrainingPrefs.ftpRange.contains(ftpW) ? ftpW : nil,
                                                        band: BikeTrainingPrefs.targetIF()) {
                Text("Target band: \(Int(watts.lowerBound.rounded())) to \(Int(watts.upperBound.rounded())) W")
                    .font(StrandFont.footnote).foregroundStyle(StrandPalette.textSecondary)
            }
            Divider().overlay(StrandPalette.hairline)
            Stepper(value: $fuelInterval, in: 0...60, step: 5) {
                row("Fuel reminder", fuelInterval == 0 ? String(localized: "Off")
                                                       : String(localized: "Every \(fuelInterval) min"))
            }
            Stepper(value: $carbsPerHour, in: 0...150, step: 10) {
                row("Carbs per hour", "\(carbsPerHour) g")
            }
        }
    }

    private func row(_ label: LocalizedStringKey, _ value: String) -> some View {
        HStack {
            Text(label).font(StrandFont.subhead).foregroundStyle(StrandPalette.textPrimary)
            Spacer()
            Text(value).font(StrandFont.bodyNumber).foregroundStyle(StrandPalette.textSecondary)
        }
    }
}

/// The bike training controls as a standalone sheet (opened from the live bike layout).
struct BikeTrainingSettingsSheet: View {
    @Environment(\.dismiss) private var dismiss

    var body: some View {
        NavigationStack {
            ScrollView {
                StrandCard(padding: NoopMetrics.space5) {
                    BikeTrainingSettingsFields()
                }
                .padding(NoopMetrics.space4)
            }
            .background(StrandPalette.surfaceBase)
            .navigationTitle("Bike training")
            .toolbar {
                ToolbarItem(placement: .confirmationAction) {
                    Button("Done") { dismiss() }
                }
            }
        }
    }
}

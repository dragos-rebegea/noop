import SwiftUI
import StrandDesign
import StrandAnalytics
import WhoopProtocol
import WhoopStore

/// The TrainingPeaks-style power summary on the workout detail screen for an indoor-bike ride: power
/// figures, aerobic decoupling, time in power zones, best powers, laps and an FTP estimate. Every figure
/// is computed at display time from the stored samples through `RideSummary` / `LapStats`, the same
/// resolvers the live bike layout uses, against the FTP stored with the ride (or the current FTP, said
/// so in a caption, when the ride predates one).
struct RideSummarySection: View {
    let machine: WorkoutMachineRow
    let samples: [MachineSample]
    let hr: [PowerHRPoint]
    let laps: [MachineLap]
    /// The rider's weight in kg when they have set one (W/kg is hidden otherwise).
    let weightKg: Double?
    /// Machine distance to show, nil when the workout row already shows the same distance.
    let machineDistance: String?

    @AppStorage(BikeTrainingPrefs.ftpKey) private var currentFTPRaw = 0
    @State private var confirmFTP = false

    private var currentFTP: Int? { BikeTrainingPrefs.ftpRange.contains(currentFTPRaw) ? currentFTPRaw : nil }
    private var ftp: Int? { machine.ftpW ?? currentFTP }

    var body: some View {
        let summary = RideSummary(samples: samples, hr: hr, ftp: ftp)
        VStack(alignment: .leading, spacing: NoopMetrics.sectionSpacing) {
            powerTiles(summary)
            decouplingCard(summary)
            zonesCard(summary)
            bestPowersCard(summary)
            lapsCard
            ftpEstimateCard
        }
    }

    // MARK: - Power figures

    private func powerTiles(_ s: RideSummary) -> some View {
        VStack(alignment: .leading, spacing: NoopMetrics.gap) {
            SectionHeader("Ride summary", overline: "Power", trailing: machine.machineName)
            LazyVGrid(columns: [GridItem(.adaptive(minimum: 104), spacing: NoopMetrics.gap)],
                      alignment: .leading, spacing: NoopMetrics.gap) {
                tile("Avg power", s.avgPowerW.map(Self.watts), "W")
                tile("Max power", s.maxPowerW.map { "\($0)" }, "W")
                tile("Normalized power", s.normalizedPowerW.map(Self.watts), "W")
                tile("Intensity factor", s.intensityFactor.map { String(format: "%.2f", $0) }, nil)
                tile("TSS", s.tss.map { "\(Int($0.rounded()))" }, nil)
                tile("Variability index", s.variabilityIndex.map { String(format: "%.2f", $0) }, nil)
                tile("Work", "\(Int(s.kilojoules.rounded()))", "kJ", accent: StrandPalette.metricAmber)
                if let cadence = s.avgCadence {
                    tile("Avg cadence", "\(Int(cadence.rounded()))", String(localized: "rpm"),
                         accent: StrandPalette.metricCyan)
                }
                if let weightKg, weightKg > 0, let avg = s.avgPowerW {
                    tile("Avg W/kg", String(format: "%.2f", avg / weightKg), nil)
                }
                if let machineDistance {
                    tile("Machine distance", machineDistance, String(localized: "reported by machine"),
                         accent: StrandPalette.metricCyan)
                }
                if let energy = machine.energyKcal {
                    tile("Machine calories", "\(energy)", "kcal", accent: StrandPalette.metricAmber)
                }
            }
            if machine.ftpW == nil, let currentFTP {
                caption(String(localized: "IF, TSS and zones use your current FTP (\(currentFTP) W): none was set when this ride was recorded."))
            } else if ftp == nil {
                caption(String(localized: "Set your FTP in Settings, Bike training, to see IF, TSS and power zones."))
            } else if let ftp {
                caption(String(localized: "Against an FTP of \(ftp) W."))
            }
        }
    }

    private func tile(_ label: LocalizedStringKey, _ value: String?, _ caption: String?,
                      accent: Color = StrandPalette.effortColor) -> some View {
        StatTile(label: label, value: value ?? "-", caption: caption, accent: accent)
    }

    private func caption(_ text: String) -> some View {
        Text(text)
            .font(StrandFont.footnote)
            .foregroundStyle(StrandPalette.textTertiary)
            .fixedSize(horizontal: false, vertical: true)
    }

    // MARK: - Decoupling

    @ViewBuilder private func decouplingCard(_ s: RideSummary) -> some View {
        NoopCard(tint: StrandPalette.effortColor) {
            HStack(alignment: .center, spacing: NoopMetrics.space4) {
                VStack(alignment: .leading, spacing: NoopMetrics.space1) {
                    Text("Aerobic decoupling").strandOverline()
                    if let pct = s.decouplingPct {
                        let verdict = DecouplingVerdict(percent: pct)
                        Text(verbatim: BikeFormat.percent1(pct))
                            .font(StrandFont.number(34)).monospacedDigit()
                            .foregroundStyle(LiveBikeDashboard.driftColor(verdict))
                        Text(Self.verdictText(verdict))
                            .font(StrandFont.subhead)
                            .foregroundStyle(StrandPalette.textPrimary)
                    } else {
                        Text("Needs at least 30 minutes with power and heart rate.")
                            .font(StrandFont.subhead)
                            .foregroundStyle(StrandPalette.textSecondary)
                    }
                }
                Spacer(minLength: 0)
            }
            .frame(maxWidth: .infinity, alignment: .leading)
        }
        caption(String(localized: "Power to heart rate in the second half against the first, after a 10 minute warm-up. Under 5 percent means your aerobic base held."))
    }

    static func verdictText(_ v: DecouplingVerdict) -> String {
        switch v {
        case .solid: return String(localized: "Aerobic base solid")
        case .someDrift: return String(localized: "Some drift")
        case .significant: return String(localized: "Significant drift")
        }
    }

    // MARK: - Power zones

    @ViewBuilder private func zonesCard(_ s: RideSummary) -> some View {
        let total = s.zoneSeconds.reduce(0, +)
        if ftp != nil, total > 0 {
            VStack(alignment: .leading, spacing: NoopMetrics.gap) {
                SectionHeader("Power zones", overline: "Time in zone")
                NoopCard(tint: StrandPalette.effortColor) {
                    VStack(alignment: .leading, spacing: NoopMetrics.space3) {
                        ForEach(PowerZone.allCases, id: \.rawValue) { zone in
                            zoneRow(zone, seconds: s.zoneSeconds[zone.rawValue - 1], total: total)
                        }
                    }
                }
            }
        }
    }

    private func zoneRow(_ zone: PowerZone, seconds: Int, total: Int) -> some View {
        let fraction = Double(seconds) / Double(max(total, 1))
        let color = StrandPalette.powerZoneColor(zone.rawValue)
        return VStack(alignment: .leading, spacing: NoopMetrics.space1) {
            HStack {
                RoundedRectangle(cornerRadius: 2, style: .continuous)
                    .fill(color).frame(width: 9, height: 9)
                Text(verbatim: BikeFormat.zoneTag(zone.rawValue, PowerZoneLabel.name(zone)))
                    .font(StrandFont.subhead).foregroundStyle(StrandPalette.textPrimary)
                Spacer(minLength: 0)
                Text(ActiveWorkoutClock.clock(seconds))
                    .font(StrandFont.captionNumber).foregroundStyle(StrandPalette.textSecondary)
                Text("\(Int((fraction * 100).rounded()))%")
                    .font(StrandFont.captionNumber).foregroundStyle(StrandPalette.textPrimary)
                    .frame(width: 40, alignment: .trailing)
            }
            GeometryReader { geo in
                ZStack(alignment: .leading) {
                    Capsule().fill(StrandPalette.surfaceInset)
                    Capsule().fill(color).frame(width: max(0, CGFloat(fraction) * geo.size.width))
                }
            }
            .frame(height: 8)
        }
        .accessibilityElement(children: .combine)
    }

    // MARK: - Best powers

    @ViewBuilder private func bestPowersCard(_ s: RideSummary) -> some View {
        if !s.bestPowers.isEmpty {
            VStack(alignment: .leading, spacing: NoopMetrics.gap) {
                SectionHeader("Best power", overline: "Power curve")
                NoopCard(tint: StrandPalette.effortColor) {
                    HStack(spacing: 0) {
                        ForEach(PowerMetrics.summaryWindows, id: \.self) { window in
                            VStack(spacing: NoopMetrics.space1) {
                                Text(Self.windowLabel(window)).strandOverline()
                                Text(s.bestPowers[window].map(Self.watts) ?? "-")
                                    .font(StrandFont.number(22)).monospacedDigit()
                                    .foregroundStyle(s.bestPowers[window] == nil
                                                     ? StrandPalette.textTertiary : StrandPalette.textPrimary)
                                    .lineLimit(1).minimumScaleFactor(0.6)
                                if let weightKg, weightKg > 0, let w = s.bestPowers[window] {
                                    Text(verbatim: BikeFormat.wattsPerKg(w / weightKg))
                                        .font(StrandFont.caption).foregroundStyle(StrandPalette.textTertiary)
                                        .lineLimit(1).minimumScaleFactor(0.7)
                                }
                            }
                            .frame(maxWidth: .infinity)
                        }
                    }
                }
            }
        }
    }

    static func windowLabel(_ seconds: Int) -> String {
        seconds < 60 ? "\(seconds)s" : "\(seconds / 60)m"
    }

    // MARK: - Laps

    @ViewBuilder private var lapsCard: some View {
        if !laps.isEmpty {
            let stats = LapStats.compute(laps: laps, samples: samples, hr: hr)
            VStack(alignment: .leading, spacing: NoopMetrics.gap) {
                SectionHeader("Laps", trailing: "\(laps.count)")
                NoopCard {
                    VStack(spacing: NoopMetrics.space2) {
                        lapRow(["#", String(localized: "Time"), String(localized: "Avg W"), "NP",
                                String(localized: "HR"), String(localized: "Cad")], header: true)
                        ForEach(stats, id: \.lap.index) { lap in
                            Divider().overlay(StrandPalette.hairline)
                            lapRow(["\(lap.lap.index)",
                                    ActiveWorkoutClock.clock(lap.lap.durationS),
                                    lap.avgPowerW.map(Self.watts) ?? "-",
                                    lap.normalizedPowerW.map(Self.watts) ?? "-",
                                    lap.avgHR.map { "\(Int($0.rounded()))" } ?? "-",
                                    lap.avgCadence.map { "\(Int($0.rounded()))" } ?? "-"], header: false)
                        }
                    }
                }
            }
        }
    }

    private func lapRow(_ cells: [String], header: Bool) -> some View {
        HStack(spacing: NoopMetrics.space2) {
            ForEach(Array(cells.enumerated()), id: \.offset) { index, cell in
                Text(cell)
                    .font(header ? StrandFont.overline : StrandFont.captionNumber)
                    .foregroundStyle(header ? StrandPalette.textSecondary : StrandPalette.textPrimary)
                    .lineLimit(1).minimumScaleFactor(0.7)
                    .frame(maxWidth: index == 0 ? 24 : .infinity, alignment: index == 0 ? .leading : .trailing)
            }
        }
    }

    // MARK: - FTP estimate

    @ViewBuilder private var ftpEstimateCard: some View {
        let estimate = PowerMetrics.ftpEstimate(samples)
        if let estimate, BikeTrainingPrefs.suggestsFTPUpdate(estimate: estimate, current: currentFTP) {
            NoopCard(tint: StrandPalette.accent) {
                HStack(spacing: NoopMetrics.space3) {
                    VStack(alignment: .leading, spacing: NoopMetrics.space1) {
                        Text("Estimated FTP: \(estimate) W")
                            .font(StrandFont.headline).foregroundStyle(StrandPalette.textPrimary)
                        Text("95 percent of your best 20 minutes on this ride.")
                            .font(StrandFont.footnote).foregroundStyle(StrandPalette.textSecondary)
                    }
                    Spacer(minLength: 0)
                    Button("Update FTP") { confirmFTP = true }
                        .font(StrandFont.subhead)
                        .foregroundStyle(StrandPalette.accent)
                        .buttonStyle(.plain)
                }
            }
            .confirmationDialog("Set your FTP to \(estimate) W?", isPresented: $confirmFTP,
                                titleVisibility: .visible) {
                Button("Update FTP") { BikeTrainingPrefs.setFTP(estimate) }
                Button("Cancel", role: .cancel) { }
            } message: {
                if let currentFTP {
                    Text("Your current FTP is \(currentFTP) W. Rides already saved keep the FTP they were recorded with.")
                } else {
                    Text("Rides already saved keep the FTP they were recorded with.")
                }
            }
        }
    }

    static func watts(_ v: Double) -> String { "\(Int(v.rounded()))" }
}

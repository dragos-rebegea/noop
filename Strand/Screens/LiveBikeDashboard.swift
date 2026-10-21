import SwiftUI
import StrandDesign
import StrandAnalytics
import WhoopProtocol

/// Localized names for the Coggan power zones, shared by the live bike layout and the ride summary.
enum PowerZoneLabel {
    static func name(_ zone: PowerZone) -> String {
        switch zone {
        case .z1: return String(localized: "Active recovery")
        case .z2: return String(localized: "Endurance")
        case .z3: return String(localized: "Tempo")
        case .z4: return String(localized: "Threshold")
        case .z5: return String(localized: "VO2max")
        case .z6: return String(localized: "Anaerobic")
        case .z7: return String(localized: "Neuromuscular")
        }
    }
}

/// Where the 3 second power sits against the target intensity band.
enum TargetBandPosition: Equatable {
    case below, inside, above

    static func resolve(watts: Double, band: ClosedRange<Double>) -> TargetBandPosition {
        if watts < band.lowerBound { return .below }
        if watts > band.upperBound { return .above }
        return .inside
    }
}

/// The riding-first live layout for an indoor-bike companion ride: 3 second power as the hero, the
/// target band, ride power figures, heart rate, laps and fuelling. Every ride figure comes from ONE
/// `RideSummary` over the recorded per-second samples (the same resolver the ride summary uses), so
/// the live screen and the saved ride cannot disagree. It reads only `AppModel` (which publishes the
/// samples once a second), never `LiveState`, so BLE packets do not re-render it.
struct LiveBikeDashboard: View {
    @EnvironmentObject private var model: AppModel

    @AppStorage(BikeTrainingPrefs.ftpKey) private var ftpRaw = 0
    @AppStorage(BikeTrainingPrefs.targetIFLowKey) private var ifLow = BikeTrainingPrefs.defaultTargetIFLow
    @AppStorage(BikeTrainingPrefs.targetIFHighKey) private var ifHigh = BikeTrainingPrefs.defaultTargetIFHigh
    @AppStorage(BikeTrainingPrefs.fuelIntervalKey) private var fuelInterval = BikeTrainingPrefs.defaultFuelIntervalMin
    @AppStorage(BikeTrainingPrefs.carbsPerHourKey) private var carbsPerHour = BikeTrainingPrefs.defaultCarbsPerHour
    @AppStorage(UnitPrefs.effortScaleKey) private var effortScaleRaw = EffortScale.hundred.rawValue
    @AppStorage(UnitPrefs.systemKey) private var unitSystemRaw = UnitSystem.metric.rawValue
    @AppStorage(UnitPrefs.distanceSystemKey) private var distanceSystemRaw = ""

    @State private var showSettings = false

    private var ftp: Int? { BikeTrainingPrefs.ftpRange.contains(ftpRaw) ? ftpRaw : nil }
    private var distanceUnitSystem: UnitSystem {
        UnitPrefs.resolveDistance(system: UnitSystem(rawValue: unitSystemRaw) ?? .metric,
                                  override: distanceSystemRaw)
    }

    var body: some View {
        if let w = model.activeWorkout {
            let startSec = Int(w.start.timeIntervalSince1970)
            let summary = RideSummary(samples: w.machineSamples,
                                      hr: RideSummary.hrPoints(w.samples, startSec: startSec), ftp: ftp)
            let nowT = Int(Date().timeIntervalSince(w.start))
            let power3s = w.isPaused ? nil : PowerMetrics.threeSecondPower(w.machineSamples, at: nowT)
            VStack(alignment: .leading, spacing: NoopMetrics.sectionSpacing) {
                chips(w, summary: summary)
                if w.fuelReminderPending { fuelBanner }
                powerHero(power3s)
                rideTiles(summary)
                lapCard(w)
                machineTiles(w, summary: summary)
            }
            .sheet(isPresented: $showSettings) { BikeTrainingSettingsSheet() }
        }
    }

    // MARK: - Chips (status, effort, HR drift)

    private func chips(_ w: AppModel.ActiveWorkout, summary: RideSummary) -> some View {
        let effortScale = UnitPrefs.resolveEffortScale(effortScaleRaw)
        return HStack(spacing: NoopMetrics.space2) {
            chip(w.isPaused ? String(localized: "Paused") : String(localized: "Recording"),
                 tint: StrandPalette.metricRose, dot: true)
            chip("\(String(localized: "Effort")) \(UnitFormatter.effortDisplay(w.liveStrain, scale: effortScale))",
                 tint: StrandPalette.effortColor)
            if let drift = summary.decouplingPct {
                chip(String(localized: "HR drift \(String(format: "%.1f", drift))%"),
                     tint: Self.driftColor(DecouplingVerdict(percent: drift)))
            }
            Spacer(minLength: 0)
        }
    }

    private func chip(_ text: String, tint: Color, dot: Bool = false) -> some View {
        HStack(spacing: NoopMetrics.space1) {
            if dot { Circle().fill(tint).frame(width: 7, height: 7) }
            Text(text)
                .textCase(.uppercase)
                .font(StrandFont.overline).tracking(StrandFont.overlineTracking)
                .foregroundStyle(tint)
                .lineLimit(1)
        }
        .padding(.horizontal, NoopMetrics.space2)
        .padding(.vertical, NoopMetrics.space1)
        .background(NoopPanelSurface(tint: tint, cornerRadius: 14))
        .clipShape(Capsule())
    }

    static func driftColor(_ verdict: DecouplingVerdict) -> Color {
        switch verdict {
        case .solid: return StrandPalette.statusPositive
        case .someDrift: return StrandPalette.statusWarning
        case .significant: return StrandPalette.statusCritical
        }
    }

    // MARK: - Fuelling

    private var fuelBanner: some View {
        let grams = BikeTrainingPrefs.carbsPerReminder(carbsPerHour: carbsPerHour, intervalMin: fuelInterval)
        return NoopCard(padding: NoopMetrics.cardInnerPadding, tint: StrandPalette.metricAmber) {
            HStack(spacing: NoopMetrics.space3) {
                Image(systemName: "fork.knife")
                    .font(StrandFont.title2)
                    .foregroundStyle(StrandPalette.metricAmber)
                    .accessibilityHidden(true)
                VStack(alignment: .leading, spacing: NoopMetrics.spaceHalf) {
                    Text("Fuel: \(grams) g carbs")
                        .font(StrandFont.headline)
                        .foregroundStyle(StrandPalette.textPrimary)
                    Text("Every \(fuelInterval) min at \(carbsPerHour) g per hour")
                        .font(StrandFont.footnote)
                        .foregroundStyle(StrandPalette.textSecondary)
                }
                Spacer(minLength: 0)
                Button { model.dismissFuelReminder() } label: {
                    Text("Done")
                        .font(StrandFont.headline)
                        .foregroundStyle(StrandPalette.metricAmber)
                        .padding(.horizontal, NoopMetrics.space3)
                        .frame(minHeight: NoopMetrics.controlHeight)
                }
                .buttonStyle(.plain)
            }
        }
    }

    // MARK: - Power hero + target band

    private func powerHero(_ power3s: Double?) -> some View {
        let zone = power3s.flatMap { PowerMetrics.powerZone(for: $0, ftp: ftp) }
        let tint = zone.map { StrandPalette.powerZoneColor($0.rawValue) } ?? StrandPalette.effortColor
        let band = BikeTrainingPrefs.targetWatts(ftp: ftp, band: BikeTrainingPrefs.targetIF())
        return NoopCard(padding: NoopMetrics.cardInnerPadding, tint: tint) {
            VStack(alignment: .leading, spacing: NoopMetrics.space3) {
                HStack {
                    Text("POWER 3S")
                        .font(StrandFont.overline).tracking(StrandFont.overlineTracking)
                        .foregroundStyle(StrandPalette.textSecondary)
                    Spacer(minLength: 0)
                    if let zone {
                        Text("Z\(zone.rawValue) \(PowerZoneLabel.name(zone))")
                            .textCase(.uppercase)
                            .font(StrandFont.overline).tracking(StrandFont.overlineTracking)
                            .foregroundStyle(tint)
                            .padding(.horizontal, NoopMetrics.space2)
                            .padding(.vertical, NoopMetrics.space1)
                            .background(tint.opacity(0.14), in: Capsule())
                    }
                }
                HStack(alignment: .firstTextBaseline, spacing: NoopMetrics.space2) {
                    Text(power3s.map { "\(Int($0.rounded()))" } ?? "-")
                        .font(StrandFont.rounded(112, weight: .bold)).monospacedDigit()
                        .foregroundStyle(tint)
                        .contentTransition(.numericText())
                        .lineLimit(1).minimumScaleFactor(0.5)
                    Text("W")
                        .font(StrandFont.title1)
                        .foregroundStyle(StrandPalette.textSecondary)
                    Spacer(minLength: 0)
                    if let power3s, let pct = PowerMetrics.percentFTP(power3s, ftp: ftp) {
                        VStack(alignment: .trailing, spacing: 0) {
                            Text("\(Int(pct.rounded()))%")
                                .font(StrandFont.number(34)).monospacedDigit()
                                .foregroundStyle(StrandPalette.textPrimary)
                            Text("of FTP")
                                .font(StrandFont.caption)
                                .foregroundStyle(StrandPalette.textSecondary)
                        }
                    }
                }
                .frame(maxWidth: .infinity, alignment: .leading)
                .accessibilityElement(children: .combine)
                .accessibilityLabel(Text("Power"))
                .accessibilityValue(Text(power3s.map { "\(Int($0.rounded())) W" } ?? String(localized: "No reading")))
                if let band {
                    TargetBandBar(band: band, watts: power3s, ftp: ftp ?? 0)
                } else {
                    Button { showSettings = true } label: {
                        Label("Set FTP for zones and a target band", systemImage: "slider.horizontal.3")
                            .font(StrandFont.subhead)
                            .foregroundStyle(StrandPalette.effortColor)
                            .frame(minHeight: NoopMetrics.controlHeight)
                    }
                    .buttonStyle(.plain)
                }
            }
        }
    }

    // MARK: - Ride tiles (avg, NP, IF, HR)

    private func rideTiles(_ s: RideSummary) -> some View {
        let zoneSet = model.profile.hrZoneSet
        let hrZone = model.bpm.map { zoneSet.zoneNumber(forBPM: Double($0)) } ?? 0
        return NoopCard(padding: NoopMetrics.cardInnerPadding) {
            HStack(spacing: 0) {
                BikeTile(title: String(localized: "AVG W"), value: s.avgPowerW.map { "\(Int($0.rounded()))" })
                tileDivider
                BikeTile(title: "NP", value: s.normalizedPowerW.map { "\(Int($0.rounded()))" })
                tileDivider
                BikeTile(title: "IF", value: s.intensityFactor.map { String(format: "%.2f", $0) })
                tileDivider
                BikeTile(title: String(localized: "HR"), value: model.bpm.map { "\($0)" },
                         tint: hrZone >= 1 ? StrandPalette.hrZoneColor(hrZone) : StrandPalette.metricRose,
                         badge: hrZone >= 1 ? "Z\(hrZone)" : nil)
            }
        }
    }

    // MARK: - Laps

    private func lapCard(_ w: AppModel.ActiveWorkout) -> some View {
        let openStart = w.laps.last?.endT ?? 0
        let current = w.machineSamples.filter { $0.t >= openStart }
        let previous = w.laps.last.map { $0.samples(from: w.machineSamples) }
        return NoopCard(padding: NoopMetrics.cardInnerPadding) {
            HStack(alignment: .center, spacing: NoopMetrics.space4) {
                VStack(alignment: .leading, spacing: NoopMetrics.space1) {
                    Text("LAP \(w.laps.count + 1)")
                        .font(StrandFont.overline).tracking(StrandFont.overlineTracking)
                        .foregroundStyle(StrandPalette.textSecondary)
                    TimelineView(.periodic(from: .now, by: 1)) { _ in
                        Text(ActiveWorkoutClock.clock(max(0, Int(Date().timeIntervalSince(w.start)) - openStart)))
                            .font(StrandFont.number(30)).monospacedDigit()
                            .foregroundStyle(StrandPalette.textPrimary)
                            .lineLimit(1).minimumScaleFactor(0.6)
                    }
                }
                Spacer(minLength: 0)
                lapFigure(String(localized: "LAP AVG"), PowerMetrics.averagePower(current))
                if let previous {
                    lapFigure(String(localized: "LAST LAP"), PowerMetrics.averagePower(previous),
                              tint: StrandPalette.textSecondary)
                }
            }
        }
    }

    private func lapFigure(_ title: String, _ watts: Double?, tint: Color = StrandPalette.textPrimary) -> some View {
        VStack(alignment: .trailing, spacing: NoopMetrics.space1) {
            Text(title)
                .font(StrandFont.overline).tracking(StrandFont.overlineTracking)
                .foregroundStyle(StrandPalette.textSecondary)
            Text(watts.map { "\(Int($0.rounded())) W" } ?? "-")
                .font(StrandFont.number(26)).monospacedDigit()
                .foregroundStyle(tint)
                .lineLimit(1).minimumScaleFactor(0.6)
        }
    }

    // MARK: - Machine tiles (cadence, speed, distance, kJ)

    private func machineTiles(_ w: AppModel.ActiveWorkout, summary: RideSummary) -> some View {
        let reading = w.lastMachineReading
        let cadence = w.machineSamples.last?.cadence ?? reading?.cadence
        let speed = UnitFormatter.speedFromKilometersPerHour(reading?.speedKmh, system: distanceUnitSystem)
        let distance = w.machineTotals.distanceM.total.map {
            UnitFormatter.distanceFromMeters(Double($0), system: distanceUnitSystem)
        }
        return NoopCard(padding: NoopMetrics.cardInnerPadding) {
            HStack(spacing: 0) {
                BikeTile(title: String(localized: "CADENCE"), value: cadence.map { "\(Int($0.rounded()))" },
                         unit: "rpm", size: 24)
                tileDivider
                BikeTile(title: String(localized: "SPEED"), value: speed, size: 24)
                tileDivider
                BikeTile(title: String(localized: "Distance").uppercased(), value: distance, size: 24)
                tileDivider
                BikeTile(title: "KJ", value: "\(Int(summary.kilojoules.rounded()))", size: 24)
            }
        }
    }

    private var tileDivider: some View {
        Rectangle().fill(StrandPalette.hairline).frame(width: 1, height: 44)
    }
}

/// One glanceable figure: overline title, large monospaced value, optional unit and badge.
private struct BikeTile: View {
    let title: String
    let value: String?
    var unit: String? = nil
    var tint: Color = StrandPalette.textPrimary
    var badge: String? = nil
    var size: CGFloat = 30

    var body: some View {
        VStack(spacing: NoopMetrics.space1) {
            Text(title)
                .font(StrandFont.overline).tracking(StrandFont.overlineTracking)
                .foregroundStyle(StrandPalette.textSecondary)
                .lineLimit(1).minimumScaleFactor(0.7)
            Text(value ?? "-")
                .font(StrandFont.number(size)).monospacedDigit()
                .foregroundStyle(value == nil ? StrandPalette.textTertiary : tint)
                .lineLimit(1).minimumScaleFactor(0.5)
            if let badge {
                Text(badge)
                    .font(StrandFont.captionNumber)
                    .foregroundStyle(tint)
                    .padding(.horizontal, NoopMetrics.space1 + 2)
                    .background(tint.opacity(0.14), in: Capsule())
            } else if let unit {
                Text(unit)
                    .font(StrandFont.caption)
                    .foregroundStyle(StrandPalette.textTertiary)
            }
        }
        .frame(maxWidth: .infinity)
        .accessibilityElement(children: .combine)
    }
}

/// Horizontal target band in watts with a marker for the current power: neutral inside the band,
/// amber above it, muted below it.
private struct TargetBandBar: View {
    let band: ClosedRange<Double>
    let watts: Double?
    let ftp: Int

    var body: some View {
        // The scale runs from 40 % to 130 % of FTP, wide enough to show where the rider sits either side.
        let lo = Double(ftp) * 0.4
        let hi = max(Double(ftp) * 1.3, band.upperBound * 1.1)
        let position = watts.map { TargetBandPosition.resolve(watts: $0, band: band) }
        let markerColor: Color = {
            switch position {
            case .above: return StrandPalette.statusWarning
            case .below: return StrandPalette.textTertiary
            case .inside: return StrandPalette.textPrimary
            case nil: return StrandPalette.textTertiary
            }
        }()
        VStack(alignment: .leading, spacing: NoopMetrics.space1) {
            HStack {
                Text("TARGET \(Int(band.lowerBound.rounded()))-\(Int(band.upperBound.rounded())) W")
                    .font(StrandFont.overline).tracking(StrandFont.overlineTracking)
                    .foregroundStyle(StrandPalette.textSecondary)
                Spacer(minLength: 0)
                switch position {
                case .above: Text("Above target").font(StrandFont.captionNumber).foregroundStyle(markerColor)
                case .below: Text("Below target").font(StrandFont.captionNumber).foregroundStyle(markerColor)
                case .inside: Text("On target").font(StrandFont.captionNumber).foregroundStyle(StrandPalette.statusPositive)
                case nil: EmptyView()
                }
            }
            GeometryReader { geo in
                let width = geo.size.width
                let x: (Double) -> CGFloat = { v in CGFloat((min(max(v, lo), hi) - lo) / (hi - lo)) * width }
                ZStack(alignment: .leading) {
                    Capsule().fill(StrandPalette.surfaceInset)
                    Capsule()
                        .fill(StrandPalette.statusPositive.opacity(0.35))
                        .frame(width: max(4, x(band.upperBound) - x(band.lowerBound)))
                        .offset(x: x(band.lowerBound))
                    if let watts {
                        RoundedRectangle(cornerRadius: 2)
                            .fill(markerColor)
                            .frame(width: 4, height: 22)
                            .offset(x: x(watts) - 2)
                    }
                }
                .frame(height: 22)
            }
            .frame(height: 22)
            .accessibilityHidden(true)
        }
    }
}

# Bike Training (Ironman) Implementation Plan

> **For agentic workers:** implement task by task, TDD for everything pure, one commit per task. iOS first (personal build); Android twin before any upstream PR. Builds on branch feat/ftms-companion (FTMS companion, `workoutMachine` table v49, `MachineSample` / `MachineSummary` / `MachineTotals` in WhoopProtocol).

**Goal:** turn the BikeErg workout into an Ironman-grade power training tool: a riding-first live screen (3 s power, avg W, NP, IF, %FTP, power zone, target band, laps, fuelling reminders, live HR drift), a TrainingPeaks-style ride summary (NP, IF, TSS, VI, kJ, decoupling, power zones, best powers, laps), and a guided 20-minute FTP test.

**Approved by the user 2026-10-21:** phases 1 + 2 of the proposal, plus the guided FTP test.

## Reference formulas (pin these in tests)

All inputs are the per-second machine samples (`MachineSample.t` = wall-clock seconds from workout start; paused seconds have no sample). Treat a missing second as a gap, not as zero power, except where noted.

- **3 s power:** mean of power over the samples with `t` in the last 3 seconds.
- **Average power:** mean of present power samples (existing `MachineSummary` behaviour). Also report **average power including zeros** is NOT needed.
- **Normalized Power (Coggan):** 30 s rolling mean of 1 s power, raise each rolling value to the 4th power, mean, 4th root. Requires at least 30 samples; nil otherwise. Gaps: compute the rolling mean over the samples present in each 30 s window (skip windows with fewer than 15 samples).
- **IF** = NP / FTP. **TSS** = (durationSec x NP x IF) / (FTP x 3600) x 100, where durationSec = count of power samples (moving seconds). **VI** = NP / avgPower. **kJ** = sum(power W x 1 s) / 1000.
- **Power zones (Coggan, % FTP):** Z1 Active recovery <= 55, Z2 Endurance 56-75, Z3 Tempo 76-90, Z4 Threshold 91-105, Z5 VO2max 106-120, Z6 Anaerobic 121-150, Z7 Neuromuscular > 150. Boundaries: a value belongs to the highest zone whose lower bound it reaches (55.0% is Z1, 55.5% is Z2: use `pct > 55` for Z2 etc.).
- **Best power (power curve):** best rolling mean over contiguous windows of 5 s, 60 s, 300 s, 1200 s, 3600 s (nil when the ride is shorter).
- **Aerobic decoupling (Pw:HR, Friel):** drop the first 10 minutes (warm-up), split the remainder into two equal halves by time, ratio = avgPower / avgHR per half, decoupling % = (ratio1 - ratio2) / ratio1 x 100. Needs >= 20 minutes after the warm-up and HR in both halves; nil otherwise. Verdict: < 5 % "Aerobic base solid", 5-10 % "Some drift", > 10 % "Significant drift".
- **Live HR drift** uses the same function on the data so far (shown only once eligible).
- **FTP estimate:** 0.95 x best 20 min power (1200 s window). In the guided test, use the mean power of the 20 min test step itself.

## Data model

- `FTP` and settings in UserDefaults (keys `bike.ftpW` Int, `bike.targetIFLow` Double default 0.65, `bike.targetIFHigh` Double default 0.72, `bike.fuelIntervalMin` Int default 20 (0 = off), `bike.carbsPerHour` Int default 80). Rider weight comes from the existing profile weight if present (W/kg shown only when known).
- Migration **v50** (never edit v49, it is installed on the user's phone): `ALTER TABLE workoutMachine ADD COLUMN lapsJSON TEXT` and `ADD COLUMN ftpW INTEGER`. `ftpW` = FTP in force when the ride was recorded, so historical IF/TSS do not change when FTP is updated later. Update both schema oracle copies (byte-identical, `ios_only`). Migration + round-trip tests.
- Laps: `[MachineLap]` Codable `{index, startT, endT}`; per-lap stats computed at display time from samples (single source of truth: never store derived per-lap numbers). Lap marks also persist in the active-workout UserDefaults snapshot so relaunch rehydration keeps them.
- All summary metrics in the detail view are computed at display time from `samplesJSON` + HR series + stored `ftpW` (one resolver, used by both the live and detail screens where they show the same metric).

## Tasks

### Task 1: PowerMetrics pure library (Packages/StrandAnalytics)
`PowerMetrics.swift`: threeSecondPower, averagePower, normalizedPower, intensityFactor, tss, variabilityIndex, kilojoules, powerZone(for:ftp:) + `PowerZone` enum with names, timeInPowerZones, bestPowers(windows:), decoupling(power:hr:warmupSec:), ftpEstimate. Inputs: `[(t: Int, powerW: Int?)]`-style plain structs (do not depend on WhoopProtocol if StrandAnalytics does not already; if it does, use `MachineSample`). Tests with hand-computed vectors: constant power (NP == avg), alternating 100/300 W blocks (NP > avg, exact value), gaps, < 30 samples, zone boundaries, best-power windows, decoupling with a known drift, ineligible decoupling, TSS = 100 for 1 h at FTP.

### Task 2: Settings + v50 migration + lap storage
Bike training section in Settings (iOS): FTP (numeric field, W), target IF range, fuelling interval and carbs/hour. v50 migration, `WorkoutMachineRow` gains `laps` and `ftpW`, store API updated, AppModel saves laps + current FTP at `endWorkout`. Tests.

### Task 3: Live bike screen
When the active workout has a companion machine with power (`live.machineState == .live` and a power reading seen), `LiveWorkoutView` switches to a bike layout; otherwise the existing layout is unchanged.
- Hero: 3 s power (large), coloured by power zone, with "% FTP" and zone name under it (when FTP set; without FTP show "Set FTP" link to the Settings section).
- Target band: horizontal bar for the target IF range in watts (FTP x low ... FTP x high) with a marker for 3 s power; marker colour neutral inside, amber above, muted below.
- Row 2 tiles: AVG W, NP, IF (NP/FTP, after 30 s), HR bpm with HR zone chip.
- Row 3 tiles: cadence, speed, distance, kJ. Machine calories and machine time move out of the live screen (still saved).
- Effort becomes a compact chip in the header on the bike layout (not the big hero).
- Lap button in the bottom control bar (bike layout only): marks a lap; the screen shows the current lap's time and avg W and the previous lap's avg W.
- Fuelling: when `bike.fuelIntervalMin > 0`, every interval buzz (existing haptic path, respecting the haptic prefs) and show a dismissible banner "Fuel: N g carbs" where N = carbsPerHour x interval / 60.
- Live HR drift chip once eligible.
- Fix the bottom control bar elapsed timer truncation ("4:..." in the user's screenshot): the timer must render H:MM:SS / MM:SS fully at all sizes (monospaced digits, no truncation, scale down if needed).
- Keep the screen awake during an active workout via `Platform.keepAwake` (check whether it already is; if so, leave it).
- Isolation: keep the existing leaf-view pattern so per-second updates do not re-render the whole screen.

### Task 4: Ride summary on the workout detail screen
Power section (only when a `workoutMachine` row exists): avg W, max W, NP, IF, TSS, VI, kJ, avg cadence, W/kg (if weight known); decoupling % + verdict; time in power zones (bar list, same visual language as HR zones) next to the existing HR zones; best powers table (5 s, 1 min, 5 min, 20 min, 60 min); laps table (lap, time, avg W, NP, avg HR, cadence). If the ride has a valid 20 min best and FTP differs by more than 3 %, show "Estimated FTP: X W" with an "Update FTP" button (confirmation required). When `ftpW` is nil (ride recorded before FTP was set), IF/TSS/zones use the current FTP and say so in a caption.

### Task 5: Guided FTP test
A start option for an indoor bike workout: "FTP test (20 min)". Fixed script as a pure, tested step list (`GuidedSession` in StrandAnalytics or app Data): warm-up 10 min easy, 3 x (1 min hard, 1 min easy), 5 min easy, 20 min all-out TEST, 10 min cool-down. On the bike layout show the current step name, its countdown, and next step; buzz at each step change. During TEST show the running 20 min avg W. At the end of the TEST step (or at End), compute FTP = 0.95 x TEST mean power and present "New FTP: X W (was Y)" with Save / Not now. The workout is saved normally (sport "Indoor cycle", notes "FTP test"). Steps are advisory only: NOOP never writes to the machine (the user sets resistance on the PM5).

### Task 6: Docs + gates
docs/FEATURES.md entry. All new strings in Localizable.xcstrings with translations for every locale it carries (`python3 Tools/i18n_audit.py --ci main`). `python3 Tools/doc_comment_lint.py`. No em/en dashes. Design tokens only (StrandPalette / StrandFont / NoopMetrics); add power-zone colours as tokens in StrandDesign if none fit, not literals.

## Verification
- Package tests for StrandAnalytics, WhoopProtocol, WhoopStore.
- iOS build (`xcodebuild -scheme NOOPiOS -destination 'generic/platform=iOS' -allowProvisioningUpdates -derivedDataPath "$TMPDIR/noop-dd" build`) and macOS StrandTests for touched classes.
- Hardware: user rides the BikeErg: bike layout, target band, laps, fuelling buzz, timer; then the FTP test and the summary.

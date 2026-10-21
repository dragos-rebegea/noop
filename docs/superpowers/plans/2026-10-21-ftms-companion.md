# FTMS Companion (BikeErg alongside WHOOP) Implementation Plan

> **For agentic workers:** implement task by task, TDD where the code is testable without CoreBluetooth, commit after each task. iOS first; Android twin is a follow-up before any upstream PR.

**Goal:** a paired FTMS gym machine (Concept2 BikeErg PM5, or any FTMS indoor bike / rower / cross-trainer / treadmill) connects as a COMPANION during a workout while the WHOOP stays connected as the HR source. The live workout screen shows the machine's metrics and the saved workout keeps them.

**Architecture:** a new companion slot in `SourceCoordinator`, separate from the single active-device slot, that never calls `stopWhoop()` and never writes `LiveState.connected` / `heartRate`. `FTMSSource` gains a companion mode that maps readings into new `LiveState` machine fields. `AppModel` accumulates per-second machine samples alongside HR samples and persists a summary + series in a new `workoutMachine` table (migration v49). `WorkoutDetailView` renders it.

**Tech stack:** Swift, CoreBluetooth (read-only notifications), GRDB, SwiftUI with StrandDesign tokens.

## Design decisions (approved by the user 2026-10-21)

1. **Pairing.** Existing Add device -> Gym equipment flow. The final prompt gains a third choice, "Use alongside WHOOP" (next to "Not now" / "Make active"), which registers the device and marks it as the companion. Persist the companion device id in UserDefaults (`ftms.companionDeviceId`); at most one companion. DevicesView row for that device shows a "Companion" badge and a toggle/remove action to stop using it as companion. Unpairing the device clears the companion id.
2. **Connect only during a workout.** When `startWorkout` runs and a companion is set AND the per-workout toggle is on, the coordinator connects the companion; `endWorkout` (and discard/cancel paths, and rehydrate-on-relaunch end paths) disconnects it. Rationale: the PM5 accepts one Bluetooth app at a time, so ErgData stays usable between workouts. The workout start UI (where the sport is picked, see `WorkoutSelectionScreen.swift` / the start sheet) shows a "Use <machine name>" toggle only when a companion is set. Default ON when the sport is not `isDistanceSport`; remember the last choice per sport in UserDefaults. `startWorkout` gets a `useCompanion: Bool` parameter (default false so existing callers keep behaviour) or reads the stored choice; pick whichever keeps call sites cleanest.
3. **Live screen.** A new leaf view `MachineRowIfPresent` in `LiveWorkoutView.swift` (same isolation pattern as `SensorRowIfPresent`: own `@EnvironmentObject live`, its own stagger index after the sensor row). States: connecting ("Connecting to <name>..."), live (tiles: POWER W, CADENCE rpm/spm, SPEED per distance unit pref, DISTANCE per unit pref, machine CALORIES, machine TIME), disconnected ("<name> disconnected" with no stale numbers). Only fields the machine sent render. Hidden entirely when no companion is in use for this workout.
4. **LiveState.** Add `machineState: MachineLinkState` (`.off / .connecting / .live / .disconnected`), `machineName: String?`, and `machineReading: FTMSReading?`. Clear the reading on disconnect/stop. Do NOT reuse the `sensor*` fields (those belong to StandardHRSource RSC/CSC/CPS and are cleared by it).
5. **FTMSSource companion mode.** Add a mode (e.g. `role: .activeDevice / .companion / .scanPreview`, replacing or wrapping `feedsLive`) so that in companion mode it writes only the machine fields above, never `live.connected`, never `live.heartRate`. Fix `stop()` / disconnect so a companion never flips `live.connected`. Keep the scan-preview and active-device behaviour byte-identical. Auto-reconnect while the workout is active if the link drops (reuse the existing pending-connect path; bounded retry with backoff, no tight loop).
6. **Recording.** In the existing once-per-second sample capture (`captureWorkoutSample`, AppModel ~L1085), when the machine is live, append a machine sample `{t, powerW?, cadence?}` to the active workout. Persist machine samples in the same UserDefaults active-workout snapshot so relaunch rehydration keeps them (`ActiveWorkoutPersistenceTests` pattern). Pure aggregation helper in a package (e.g. `Packages/StrandAnalytics` or a new small file in `WhoopProtocol` beside `FTMSDecode`): `MachineSummary.from(samples:, lastReading:)` -> avgPowerW (mean of present power samples, paused periods excluded the same way HR is), maxPowerW, avgCadence, distanceM (machine total distance from last reading), machineEnergyKcal (last reading), elapsed. Unit-tested.
7. **Storage.** Migration `v49-workout-machine` in `Packages/WhoopStore/Sources/WhoopStore/Database.swift`: table `workoutMachine` (deviceId TEXT NOT NULL, startTs INTEGER NOT NULL, machineKind TEXT NOT NULL, machineName TEXT, avgPowerW REAL, maxPowerW INTEGER, avgCadence REAL, distanceM INTEGER, energyKcal INTEGER, elapsedS INTEGER, samplesJSON TEXT NOT NULL, PRIMARY KEY(deviceId, startTs)). Key it the same way the saved `WorkoutRow` is identified (check the workout table's key; match it). Store API on the `WhoopStore` actor: `upsertWorkoutMachine`, `workoutMachine(deviceId:startTs:)`, delete alongside workout deletion if a workout-delete path exists. Add `workoutMachine` to `DeviceRegistryStore.deviceScopedTables`. Add it to BOTH schema oracle JSON copies (iOS + Android, byte-identical) marked `ios_only`, the same way the v48 food tables were added. Migration test + store round-trip test.
8. **Distance and calories.** If the workout has no GPS route distance and the machine reported distance, save `WorkoutRow.distanceM` = machine distance. Calories and Effort stay HR-based (unchanged); the machine energy is stored and shown only as "Machine calories".
9. **Detail screen.** `WorkoutDetailView.load()` reads `workoutMachine` for the workout. Tiles: Avg power, Max power, Avg cadence, Machine distance (if not already shown), Machine calories. A power chart (and cadence, if cheap) from `samplesJSON` using the same chart style/tokens as the HR chart.
10. **Safety.** Read-only: subscribe to machine-data notifications only. Never write the FTMS Control Point (0x2AD9) or any characteristic. No hardcoded frame bytes in app code. Nothing leaves the device.

## Tasks

### Task 1: MachineSummary pure helper + tests
- Create the helper and `MachineSample` (Codable, `t` seconds since workout start, `powerW: Int?`, `cadence: Double?`) in a package with tests (no CoreBluetooth). Cover: empty samples, power gaps, negative power ignored, max, cadence mean, distance/energy from last reading, paused-time exclusion if the HR path excludes it.
- Commit.

### Task 2: workoutMachine migration + store API + oracle
- v49 migration, row type, store calls, deviceScopedTables, both schema oracle copies (byte-identical, `ios_only`). Tests in `Packages/WhoopStore/Tests`.
- Run `swift test` in WhoopStore (with `CLANG_MODULE_CACHE_PATH=/tmp/noop-clang-module-cache swift test --disable-sandbox --skip-update`).
- Commit.

### Task 3: LiveState machine fields + FTMSSource companion role
- Fields from decision 4, role from decision 5, reconnect behaviour. Keep active-device and scan-preview paths unchanged.
- Commit.

### Task 4: SourceCoordinator companion slot + AppModel wiring
- `startCompanion()` / `stopCompanion()` that never call `stopWhoop()` and are independent of `activeDeviceId`. Companion id storage. Hook into `startWorkout`, `endWorkout`, discard, and rehydrate paths. If the user makes the companion device the ACTIVE device, drop the companion role first (never two FTMSSources on one peripheral).
- A StrandTests test that building a coordinator with a companion and starting/stopping it never invokes the `stopWhoop` closure (follow `ExperimentalDriversTests.swift` coordinator construction).
- Commit.

### Task 5: Recording + persistence
- Machine samples in `ActiveWorkout` + its UserDefaults snapshot, captured once per second; summary + upsert at `endWorkout`; distance fallback (decision 8). Extend `ActiveWorkoutPersistenceTests` for the machine samples round trip.
- Commit.

### Task 6: Pairing UI + workout start toggle
- Wizard third choice, DevicesView badge + remove-companion, per-sport toggle in the start flow.
- Commit.

### Task 7: Live panel + detail screen
- `MachineRowIfPresent` and the detail tiles + chart.
- Commit.

### Task 8: Docs + gates
- `docs/FEATURES.md` (short entry), `docs/PRIVACY_SECURITY.md` only if it lists BLE peripherals (local Bluetooth, read-only).
- Every new user-facing string must be added to the xcstrings catalogue WITH translations for every locale the catalogue already carries (`python3 Tools/i18n_audit.py --ci main` must pass, and `Tools/test_home_i18n.py` if touched files are covered).
- `python3 Tools/doc_comment_lint.py` must pass (insert new declarations above a neighbour's doc block, never between a doc block and its declaration).
- No em/en dashes anywhere in new text. No device or team ids in files.
- Commit.

## Verification
- Package tests (WhoopProtocol / StrandAnalytics / WhoopStore, whichever were touched) green.
- The chair runs: `xcodegen generate`, the iOS signed build, the macOS `Strand` build, and the relevant `StrandTests` (`xcodebuild test -scheme Strand -destination 'platform=macOS' CODE_SIGNING_ALLOWED=NO -only-testing:...`).
- Hardware: user rides a BikeErg session with WHOOP connected; confirm WHOOP stays connected, the panel fills, and the saved workout shows power and distance.

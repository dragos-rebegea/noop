# Macro Logger (iOS v1) Implementation Plan

> **For agentic workers:** REQUIRED SUB-SKILL: Use superpowers:subagent-driven-development (recommended) or superpowers:executing-plans to implement this plan task-by-task. Steps use checkbox (`- [ ]`) syntax for tracking.

**Goal:** Log daily calories/protein/carbs/fat on iOS via meal photo (Claude), barcode (Open Food Facts + local cache), Recent re-log and Quick add, against fixed daily targets, with totals feeding the existing `metricSeries` nutrition keys.

**Architecture:** A new pure package `StrandNutrition` holds value types, portion math, the plausibility rule and the two JSON decoders (Open Food Facts, Claude replies), all covered by `swift test`. `WhoopStore` gains migration `v48-food-log` (`foodEntry`, `foodProduct`) and CRUD that recomputes a day's totals into `metricSeries` under `deviceId = "noop-food"` in the same transaction. The app layer adds an Anthropic vision call with JSON-schema structured output, a cache-first product lookup, and iOS-only SwiftUI screens reached from the More tab.

**Tech Stack:** Swift 5.9 packages, GRDB 6.29.3, XCTest, SwiftUI (iOS 17), VisionKit `DataScannerViewController`, ImageIO, Anthropic Messages API (`output_config.format` json_schema), Open Food Facts API v2.

**Spec:** `docs/superpowers/specs/2026-10-20-macro-logger-design.md`

**Repo rules that apply to every task** (from `AGENTS.md`):
- No em/en dashes anywhere (user rule). Use hyphens.
- UI uses only `StrandPalette` / `StrandFont` / `StrandCard` / `NoopButton`. No hardcoded colors, fonts or spacing literals beyond the padding values existing screens use.
- Never edit an existing migration. `Strand.xcodeproj/` is generated: run `xcodegen generate`, never hand-edit or commit it.
- `doc_comment_lint`: insert new declarations above a neighbour's doc block, never between a doc block and its declaration.
- Commits: no AI co-author trailer (user rule).

---

## File map

| File | Status | Responsibility |
|---|---|---|
| `Packages/StrandNutrition/Package.swift` | Create | Pure package manifest (Foundation only). |
| `Packages/StrandNutrition/Sources/StrandNutrition/Macros.swift` | Create | `Macros`, `MacroPer100g`, scaling, summing. |
| `Packages/StrandNutrition/Sources/StrandNutrition/Plausibility.swift` | Create | Implausible-values rule. |
| `Packages/StrandNutrition/Sources/StrandNutrition/FoodDay.swift` | Create | Local calendar day key `yyyy-MM-dd`. |
| `Packages/StrandNutrition/Sources/StrandNutrition/OpenFoodFacts.swift` | Create | OFF v2 response decoding. |
| `Packages/StrandNutrition/Sources/StrandNutrition/FoodVisionReply.swift` | Create | Claude reply decoding + the two JSON schemas + prompts. |
| `Packages/StrandNutrition/Tests/StrandNutritionTests/*.swift` | Create | Unit tests for all of the above. |
| `Packages/WhoopStore/Package.swift` | Modify | Depend on `StrandNutrition`. |
| `Packages/WhoopStore/Sources/WhoopStore/Database.swift` | Modify | Register `v48-food-log` before `return migrator`. |
| `Packages/WhoopStore/Sources/WhoopStore/FoodLogStore.swift` | Create | Rows, CRUD, recent, day-total recompute. |
| `Packages/WhoopStore/Sources/WhoopStore/DeviceRegistryStore.swift` | Modify | Add the two tables to `deviceScopedTables`. |
| `Packages/WhoopStore/Tests/WhoopStoreTests/FoodLogStoreTests.swift` | Create | Migration + CRUD + totals tests. |
| `Packages/WhoopStore/Tests/WhoopStoreTests/Resources/schema_oracle.json` and `android/app/src/test/resources/schema_oracle.json` | Modify | Add `v48-food-log` and the two `ios_only` tables (byte-identical copies). |
| `project.yml` | Modify | Package entry, target deps, `NSCameraUsageDescription`. |
| `StrandiOS/Resources/Info.plist` | Modify | Camera usage string (kept in sync with project.yml). |
| `.github/workflows/swift-packages.yml` | Modify | Add `StrandNutrition` to the matrix. |
| `Strand/AI/AnthropicVision.swift` | Create | Build/parse one image + structured-output request. |
| `Strand/Data/FoodVisionService.swift` | Create | Provider/key/model resolution; `analyzeMeal`, `readLabel`. |
| `Strand/Data/FoodImage.swift` | Create | Downscale to 1024 px JPEG via ImageIO. |
| `Strand/Data/FoodProductLookup.swift` | Create | Cache-first barcode lookup, OFF fetch, settings keys. |
| `Strand/Data/FoodLogModel.swift` | Create | `@MainActor` view model for the Food screens. |
| `Strand/Screens/Food/*.swift` | Create | iOS-only screens (wrapped in `#if os(iOS)`). |
| `Strand/AI/AICoach.swift` | Modify | Food-log summary block in the coach context (consent-gated). |
| `Strand/Data/MetricCatalog.swift` | Modify | Four `noop-food` nutrition descriptors so logged totals reach Compare/Explore. |
| `Strand/Data/DeviceRegistry.swift` (or the Settings delete flow) | Modify | "Delete all food data" purging `deviceId = noop-food`. |
| `StrandiOS/App/RootTabView.swift` | Modify | `MoreDestination.food` + `MoreRow`. |
| `Strand/Screens/SettingsView.swift` | Modify | Food logging section (iOS only). |
| `StrandTests/AnthropicVisionTests.swift` | Create | Request shape + reply extraction tests. |
| `docs/PRIVACY_SECURITY.md`, `docs/FEATURES.md` | Modify | Disclose the new network path; document the feature. |

---

### Task 1: Scaffold `StrandNutrition` with `Macros` and scaling

**Files:**
- Create: `Packages/StrandNutrition/Package.swift`
- Create: `Packages/StrandNutrition/Sources/StrandNutrition/Macros.swift`
- Test: `Packages/StrandNutrition/Tests/StrandNutritionTests/MacrosTests.swift`

- [ ] **Step 1: Create the manifest**

```swift
// swift-tools-version:5.9
import PackageDescription

// Pure nutrition logic for the macro logger: value types, portion math, the plausibility rule and
// the Open Food Facts / Claude reply decoders. Foundation only, so it builds and tests on Linux.
let package = Package(
    name: "StrandNutrition",
    platforms: [.macOS(.v13), .iOS(.v16)],   // no watchOS floor: WhoopStore (its consumer) declares none
    products: [.library(name: "StrandNutrition", targets: ["StrandNutrition"])],
    targets: [
        .target(name: "StrandNutrition"),
        .testTarget(name: "StrandNutritionTests", dependencies: ["StrandNutrition"]),
    ]
)
```

- [ ] **Step 2: Write the failing test**

```swift
import XCTest
@testable import StrandNutrition

final class MacrosTests: XCTestCase {
    func testScaledByGrams() {
        let oats = MacroPer100g(kcal: 389, protein: 16.9, carbs: 66.3, fat: 6.9)
        let m = oats.scaled(grams: 50)
        XCTAssertEqual(m.kcal, 194.5, accuracy: 1e-9)
        XCTAssertEqual(m.protein, 8.45, accuracy: 1e-9)
        XCTAssertEqual(m.carbs, 33.15, accuracy: 1e-9)
        XCTAssertEqual(m.fat, 3.45, accuracy: 1e-9)
    }

    func testZeroGramsIsZero() {
        XCTAssertEqual(MacroPer100g(kcal: 100, protein: 1, carbs: 2, fat: 3).scaled(grams: 0), .zero)
    }

    func testSum() {
        let a = Macros(kcal: 100, protein: 10, carbs: 5, fat: 2)
        let b = Macros(kcal: 50, protein: 1, carbs: 10, fat: 1)
        XCTAssertEqual([a, b].sum(), Macros(kcal: 150, protein: 11, carbs: 15, fat: 3))
        XCTAssertEqual([Macros]().sum(), .zero)
    }
}
```

- [ ] **Step 3: Run test to verify it fails**

Run: `cd Packages/StrandNutrition && swift test`
Expected: FAIL, compile error `cannot find 'MacroPer100g' in scope`.

- [ ] **Step 4: Write minimal implementation**

`Macros.swift`:

```swift
import Foundation

/// Absolute energy and macronutrients for an eaten amount (kcal and grams).
public struct Macros: Equatable, Codable, Sendable {
    public var kcal: Double
    public var protein: Double
    public var carbs: Double
    public var fat: Double

    public init(kcal: Double, protein: Double, carbs: Double, fat: Double) {
        self.kcal = kcal
        self.protein = protein
        self.carbs = carbs
        self.fat = fat
    }

    public static let zero = Macros(kcal: 0, protein: 0, carbs: 0, fat: 0)

    public static func + (l: Macros, r: Macros) -> Macros {
        Macros(kcal: l.kcal + r.kcal, protein: l.protein + r.protein,
               carbs: l.carbs + r.carbs, fat: l.fat + r.fat)
    }
}

/// Energy and macronutrients per 100 g of a food, the unit product databases and labels use.
public struct MacroPer100g: Equatable, Codable, Sendable {
    public var kcal: Double
    public var protein: Double
    public var carbs: Double
    public var fat: Double

    public init(kcal: Double, protein: Double, carbs: Double, fat: Double) {
        self.kcal = kcal
        self.protein = protein
        self.carbs = carbs
        self.fat = fat
    }

    /// Macros for `grams` of this food.
    public func scaled(grams: Double) -> Macros {
        let f = grams / 100
        return Macros(kcal: kcal * f, protein: protein * f, carbs: carbs * f, fat: fat * f)
    }
}

extension Sequence where Element == Macros {
    /// Component-wise total; `.zero` for an empty sequence.
    public func sum() -> Macros { reduce(.zero, +) }
}
```

- [ ] **Step 5: Run test to verify it passes**

Run: `cd Packages/StrandNutrition && swift test`
Expected: PASS (3 tests).

- [ ] **Step 6: Commit**

```bash
git add Packages/StrandNutrition
git commit -m "feat(nutrition): StrandNutrition package with macro scaling"
```

---

### Task 2: Plausibility rule

**Files:**
- Create: `Packages/StrandNutrition/Sources/StrandNutrition/Plausibility.swift`
- Test: `Packages/StrandNutrition/Tests/StrandNutritionTests/PlausibilityTests.swift`

- [ ] **Step 1: Write the failing test**

```swift
import XCTest
@testable import StrandNutrition

final class PlausibilityTests: XCTestCase {
    func testRealFoodsPass() {
        // Oats, chicken breast, olive oil, cucumber (low-kcal edge: 40 kcal floor).
        XCTAssertEqual(Plausibility.issues(MacroPer100g(kcal: 389, protein: 16.9, carbs: 66.3, fat: 6.9)), [])
        XCTAssertEqual(Plausibility.issues(MacroPer100g(kcal: 165, protein: 31, carbs: 0, fat: 3.6)), [])
        XCTAssertEqual(Plausibility.issues(MacroPer100g(kcal: 884, protein: 0, carbs: 0, fat: 100)), [])
        XCTAssertEqual(Plausibility.issues(MacroPer100g(kcal: 15, protein: 0.7, carbs: 3.6, fat: 0.1)), [])
    }

    func testNegative() {
        XCTAssertEqual(Plausibility.issues(MacroPer100g(kcal: 100, protein: -1, carbs: 20, fat: 1)),
                       [.negativeValue])
    }

    func testMassOver100() {
        let issues = Plausibility.issues(MacroPer100g(kcal: 600, protein: 60, carbs: 50, fat: 10))
        XCTAssertTrue(issues.contains(.macroMassOver100))
    }

    func testEnergyMismatch() {
        // Macros imply 4*20 + 4*10 + 9*5 = 165 kcal; 400 is far outside max(40, 0.25 * 400).
        XCTAssertEqual(Plausibility.issues(MacroPer100g(kcal: 400, protein: 20, carbs: 10, fat: 5)),
                       [.energyMismatch(expectedKcal: 165)])
    }

    func testEnergyWithinTolerancePasses() {
        // Implied 165, stated 200: diff 35 <= max(40, 50).
        XCTAssertEqual(Plausibility.issues(MacroPer100g(kcal: 200, protein: 20, carbs: 10, fat: 5)), [])
    }
}
```

- [ ] **Step 2: Run test to verify it fails**

Run: `cd Packages/StrandNutrition && swift test --filter PlausibilityTests`
Expected: FAIL, `cannot find 'Plausibility' in scope`.

- [ ] **Step 3: Write minimal implementation**

```swift
import Foundation

/// Why a per-100 g value set looks wrong. Flagged values need explicit confirmation before saving.
public enum PlausibilityIssue: Equatable, Sendable {
    case negativeValue
    case macroMassOver100
    case energyMismatch(expectedKcal: Double)
}

/// Sanity checks for per-100 g values from a photo estimate, a label read or a product database.
public enum Plausibility {
    public static func issues(_ v: MacroPer100g) -> [PlausibilityIssue] {
        var out: [PlausibilityIssue] = []
        if v.kcal < 0 || v.protein < 0 || v.carbs < 0 || v.fat < 0 { out.append(.negativeValue) }
        if v.protein + v.carbs + v.fat > 100 { out.append(.macroMassOver100) }
        let expected = 4 * v.protein + 4 * v.carbs + 9 * v.fat
        if abs(v.kcal - expected) > max(40, 0.25 * v.kcal) {
            out.append(.energyMismatch(expectedKcal: expected))
        }
        return out
    }
}
```

- [ ] **Step 4: Run test to verify it passes**

Run: `cd Packages/StrandNutrition && swift test --filter PlausibilityTests`
Expected: PASS (5 tests).

- [ ] **Step 5: Commit**

```bash
git add Packages/StrandNutrition
git commit -m "feat(nutrition): plausibility rule for per-100g values"
```

---

### Task 3: Food day key

**Files:**
- Create: `Packages/StrandNutrition/Sources/StrandNutrition/FoodDay.swift`
- Test: `Packages/StrandNutrition/Tests/StrandNutritionTests/FoodDayTests.swift`

- [ ] **Step 1: Write the failing test**

```swift
import XCTest
@testable import StrandNutrition

final class FoodDayTests: XCTestCase {
    func testLocalCalendarDay() {
        var cal = Calendar(identifier: .gregorian)
        cal.timeZone = TimeZone(identifier: "Europe/Bucharest")!
        // 2026-10-20 23:30 local (UTC+3 in October) is still the 20th, not the next wake day.
        let d = cal.date(from: DateComponents(year: 2026, month: 10, day: 20, hour: 23, minute: 30))!
        XCTAssertEqual(FoodDay.key(for: d, calendar: cal), "2026-10-20")
        let early = cal.date(from: DateComponents(year: 2026, month: 10, day: 21, hour: 0, minute: 5))!
        XCTAssertEqual(FoodDay.key(for: early, calendar: cal), "2026-10-21")
    }
}
```

- [ ] **Step 2: Run test to verify it fails**

Run: `cd Packages/StrandNutrition && swift test --filter FoodDayTests`
Expected: FAIL, `cannot find 'FoodDay' in scope`.

- [ ] **Step 3: Write minimal implementation**

```swift
import Foundation

/// Food belongs to the local calendar day it was eaten (not the sleep wake-day convention).
public enum FoodDay {
    public static func key(for date: Date, calendar: Calendar = .current) -> String {
        let c = calendar.dateComponents([.year, .month, .day], from: date)
        return String(format: "%04d-%02d-%02d", c.year ?? 0, c.month ?? 0, c.day ?? 0)
    }
}
```

- [ ] **Step 4: Run test to verify it passes**

Run: `cd Packages/StrandNutrition && swift test --filter FoodDayTests`
Expected: PASS.

- [ ] **Step 5: Commit**

```bash
git add Packages/StrandNutrition
git commit -m "feat(nutrition): local calendar day key for food entries"
```

---

### Task 4: Open Food Facts decoder

**Files:**
- Create: `Packages/StrandNutrition/Sources/StrandNutrition/OpenFoodFacts.swift`
- Test: `Packages/StrandNutrition/Tests/StrandNutritionTests/OpenFoodFactsTests.swift`

OFF v2 shape: `{"code":"...","status":1,"product":{"product_name":..., "brands":..., "serving_quantity": <number or string>, "nutriments":{"energy-kcal_100g":..., "energy_100g": <kJ>, "proteins_100g":..., "carbohydrates_100g":..., "fat_100g":...}}}`. Not found: `"status":0`. Nutriment values may be numbers or numeric strings.

- [ ] **Step 1: Write the failing test**

```swift
import XCTest
@testable import StrandNutrition

final class OpenFoodFactsTests: XCTestCase {
    private func decode(_ json: String) throws -> OpenFoodFacts.Result {
        try OpenFoodFacts.decode(Data(json.utf8))
    }

    func testCompleteProduct() throws {
        let r = try decode("""
        {"code":"5941234567890","status":1,"product":{"product_name":"Fulgi de ovaz","brands":"Acme",
         "serving_quantity":"40","nutriments":{"energy-kcal_100g":372,"proteins_100g":13.5,
         "carbohydrates_100g":58.7,"fat_100g":7}}}
        """)
        guard case .found(let p) = r else { return XCTFail("expected found") }
        XCTAssertEqual(p.name, "Fulgi de ovaz")
        XCTAssertEqual(p.brand, "Acme")
        XCTAssertEqual(p.servingGrams, 40)
        XCTAssertEqual(p.per100g, MacroPer100g(kcal: 372, protein: 13.5, carbs: 58.7, fat: 7))
    }

    func testKilojoulesOnlyConverted() throws {
        let r = try decode("""
        {"status":1,"product":{"product_name":"X","nutriments":{"energy_100g":"1046",
         "proteins_100g":"10","carbohydrates_100g":"40","fat_100g":"2"}}}
        """)
        guard case .found(let p) = r else { return XCTFail("expected found") }
        XCTAssertEqual(p.per100g?.kcal ?? 0, 1046 / 4.184, accuracy: 1e-6)
        XCTAssertNil(p.brand)
        XCTAssertNil(p.servingGrams)
    }

    func testMissingMacrosGivesNilPer100g() throws {
        let r = try decode("""
        {"status":1,"product":{"product_name":"Y","nutriments":{"energy-kcal_100g":100,"fat_100g":1}}}
        """)
        guard case .found(let p) = r else { return XCTFail("expected found") }
        XCTAssertNil(p.per100g)
    }

    func testNotFound() throws {
        XCTAssertEqual(try decode(#"{"code":"1","status":0,"status_verbose":"product not found"}"#), .notFound)
    }

    func testGarbageThrows() {
        XCTAssertThrowsError(try decode("<html>"))
    }
}
```

- [ ] **Step 2: Run test to verify it fails**

Run: `cd Packages/StrandNutrition && swift test --filter OpenFoodFactsTests`
Expected: FAIL, `cannot find 'OpenFoodFacts' in scope`.

- [ ] **Step 3: Write minimal implementation**

```swift
import Foundation

/// Decoding for the Open Food Facts product API v2 (`/api/v2/product/<code>.json`).
public enum OpenFoodFacts {
    public struct Product: Equatable, Sendable {
        public var name: String
        public var brand: String?
        public var servingGrams: Double?
        /// nil unless protein, carbs, fat and an energy value are all present.
        public var per100g: MacroPer100g?
    }

    public enum Result: Equatable, Sendable {
        case found(Product)
        case notFound
    }

    public struct DecodeError: Error {}

    /// Fields requested with `?fields=` so the response stays small.
    public static let fields = "product_name,brands,serving_quantity,nutriments"

    public static func decode(_ data: Data) throws -> Result {
        guard let root = try JSONSerialization.jsonObject(with: data) as? [String: Any] else {
            throw DecodeError()
        }
        guard number(root["status"]) == 1, let product = root["product"] as? [String: Any] else {
            return .notFound
        }
        let name = (product["product_name"] as? String)?.trimmingCharacters(in: .whitespaces)
        let brand = (product["brands"] as? String)?
            .split(separator: ",").first.map { $0.trimmingCharacters(in: .whitespaces) }
        let n = product["nutriments"] as? [String: Any] ?? [:]
        var per100g: MacroPer100g?
        let kcal = number(n["energy-kcal_100g"]) ?? number(n["energy_100g"]).map { $0 / 4.184 }
        if let kcal, let p = number(n["proteins_100g"]), let c = number(n["carbohydrates_100g"]),
           let f = number(n["fat_100g"]) {
            per100g = MacroPer100g(kcal: kcal, protein: p, carbs: c, fat: f)
        }
        return .found(Product(
            name: (name?.isEmpty == false ? name : nil) ?? "Unnamed product",
            brand: (brand?.isEmpty == false) ? brand : nil,
            servingGrams: number(product["serving_quantity"]).flatMap { $0 > 0 ? $0 : nil },
            per100g: per100g))
    }

    /// OFF mixes numbers and numeric strings for the same field.
    static func number(_ v: Any?) -> Double? {
        if let d = v as? Double { return d }
        if let i = v as? Int { return Double(i) }
        if let s = v as? String { return Double(s.trimmingCharacters(in: .whitespaces)) }
        return nil
    }
}
```

- [ ] **Step 4: Run test to verify it passes**

Run: `cd Packages/StrandNutrition && swift test --filter OpenFoodFactsTests`
Expected: PASS (5 tests). Note: `JSONSerialization` returns `NSNumber`; `as? Double` succeeds for integral values on Apple platforms and corelibs, and the `Int` branch covers the rest.

- [ ] **Step 5: Commit**

```bash
git add Packages/StrandNutrition
git commit -m "feat(nutrition): Open Food Facts v2 product decoder"
```

---

### Task 5: Claude reply decoders, schemas and prompts

**Files:**
- Create: `Packages/StrandNutrition/Sources/StrandNutrition/FoodVisionReply.swift`
- Test: `Packages/StrandNutrition/Tests/StrandNutritionTests/FoodVisionReplyTests.swift`

- [ ] **Step 1: Write the failing test**

```swift
import XCTest
@testable import StrandNutrition

final class FoodVisionReplyTests: XCTestCase {
    func testMealValid() throws {
        let items = try FoodVisionReply.decodeMeal(Data("""
        {"items":[{"name":"Grilled chicken breast","grams":150,"kcal100":165,"protein100":31,
          "carbs100":0,"fat100":3.6,"confidence":"high"},
         {"name":"White rice","grams":200,"kcal100":130,"protein100":2.7,"carbs100":28,
          "fat100":0.3,"confidence":"medium"}]}
        """.utf8))
        XCTAssertEqual(items.count, 2)
        XCTAssertEqual(items[0].name, "Grilled chicken breast")
        XCTAssertEqual(items[0].grams, 150)
        XCTAssertEqual(items[0].per100g, MacroPer100g(kcal: 165, protein: 31, carbs: 0, fat: 3.6))
        XCTAssertEqual(items[1].confidence, .medium)
    }

    func testMealEmptyThrowsNothingFound() {
        XCTAssertThrowsError(try FoodVisionReply.decodeMeal(Data(#"{"items":[]}"#.utf8))) {
            XCTAssertEqual($0 as? FoodVisionReply.Failure, .nothingRecognised)
        }
    }

    func testMealMalformedThrows() {
        XCTAssertThrowsError(try FoodVisionReply.decodeMeal(Data(#"{"items":[{"name":"x"}]}"#.utf8))) {
            XCTAssertEqual($0 as? FoodVisionReply.Failure, .malformed)
        }
    }

    func testMealDropsNonPositiveGrams() throws {
        let items = try FoodVisionReply.decodeMeal(Data("""
        {"items":[{"name":"a","grams":0,"kcal100":1,"protein100":0,"carbs100":0,"fat100":0,"confidence":"low"},
                  {"name":"b","grams":10,"kcal100":1,"protein100":0,"carbs100":0,"fat100":0,"confidence":"low"}]}
        """.utf8))
        XCTAssertEqual(items.map(\.name), ["b"])
    }

    func testLabelValid() throws {
        let l = try FoodVisionReply.decodeLabel(Data("""
        {"name":"Greek yogurt 2%","kcal100":73,"protein100":10,"carbs100":3.6,"fat100":2,"servingGrams":null}
        """.utf8))
        XCTAssertEqual(l.name, "Greek yogurt 2%")
        XCTAssertEqual(l.per100g, MacroPer100g(kcal: 73, protein: 10, carbs: 3.6, fat: 2))
        XCTAssertNil(l.servingGrams)
    }

    func testSchemasAreValidJSON() throws {
        XCTAssertNoThrow(try JSONSerialization.jsonObject(with: Data(FoodVisionReply.mealSchemaJSON.utf8)))
        XCTAssertNoThrow(try JSONSerialization.jsonObject(with: Data(FoodVisionReply.labelSchemaJSON.utf8)))
    }
}
```

- [ ] **Step 2: Run test to verify it fails**

Run: `cd Packages/StrandNutrition && swift test --filter FoodVisionReplyTests`
Expected: FAIL, `cannot find 'FoodVisionReply' in scope`.

- [ ] **Step 3: Write minimal implementation**

```swift
import Foundation

/// The two structured-output contracts for photo logging, their prompts and their decoders.
/// The app sends the schema as `output_config.format`; these decoders accept only that shape.
public enum FoodVisionReply {
    public enum Confidence: String, Codable, Sendable { case low, medium, high }

    public struct MealItem: Equatable, Sendable {
        public init(name: String, grams: Double, per100g: MacroPer100g, confidence: Confidence) {
            self.name = name; self.grams = grams; self.per100g = per100g; self.confidence = confidence
        }
        public var name: String
        public var grams: Double
        public var per100g: MacroPer100g
        public var confidence: Confidence
    }

    public struct Label: Equatable, Sendable {
        public var name: String
        public var per100g: MacroPer100g
        public var servingGrams: Double?
    }

    public enum Failure: Error, Equatable { case malformed, nothingRecognised }

    public static let mealPrompt = """
    Identify each distinct food or drink in this photo. For each, estimate the eaten portion in grams \
    and give typical energy and macronutrients per 100 g. Use common names. If the photo contains no \
    food, return an empty items list.
    """

    public static let labelPrompt = """
    Read the nutrition facts table in this photo. Return the product name if visible (otherwise a short \
    description), energy in kcal and protein, carbohydrate and fat in grams, all per 100 g. If the table \
    only gives per-serving values, convert them to per 100 g using the stated serving size. Return the \
    serving size in grams if stated, otherwise null.
    """

    public static let mealSchemaJSON = """
    {"type":"object","additionalProperties":false,"required":["items"],"properties":{"items":{"type":"array",\
    "items":{"type":"object","additionalProperties":false,\
    "required":["name","grams","kcal100","protein100","carbs100","fat100","confidence"],\
    "properties":{"name":{"type":"string"},"grams":{"type":"number"},"kcal100":{"type":"number"},\
    "protein100":{"type":"number"},"carbs100":{"type":"number"},"fat100":{"type":"number"},\
    "confidence":{"type":"string","enum":["low","medium","high"]}}}}}}
    """

    public static let labelSchemaJSON = """
    {"type":"object","additionalProperties":false,\
    "required":["name","kcal100","protein100","carbs100","fat100","servingGrams"],\
    "properties":{"name":{"type":"string"},"kcal100":{"type":"number"},"protein100":{"type":"number"},\
    "carbs100":{"type":"number"},"fat100":{"type":"number"},"servingGrams":{"type":["number","null"]}}}
    """

    private struct WireItem: Decodable {
        let name: String, grams: Double, kcal100: Double, protein100: Double
        let carbs100: Double, fat100: Double, confidence: Confidence
    }
    private struct WireMeal: Decodable { let items: [WireItem] }
    private struct WireLabel: Decodable {
        let name: String, kcal100: Double, protein100: Double, carbs100: Double, fat100: Double
        let servingGrams: Double?
    }

    public static func decodeMeal(_ data: Data) throws -> [MealItem] {
        guard let wire = try? JSONDecoder().decode(WireMeal.self, from: data) else { throw Failure.malformed }
        let items = wire.items.filter { $0.grams > 0 }.map {
            MealItem(name: $0.name, grams: $0.grams,
                     per100g: MacroPer100g(kcal: $0.kcal100, protein: $0.protein100,
                                           carbs: $0.carbs100, fat: $0.fat100),
                     confidence: $0.confidence)
        }
        guard !items.isEmpty else { throw Failure.nothingRecognised }
        return items
    }

    public static func decodeLabel(_ data: Data) throws -> Label {
        guard let w = try? JSONDecoder().decode(WireLabel.self, from: data) else { throw Failure.malformed }
        return Label(name: w.name,
                     per100g: MacroPer100g(kcal: w.kcal100, protein: w.protein100, carbs: w.carbs100, fat: w.fat100),
                     servingGrams: w.servingGrams.flatMap { $0 > 0 ? $0 : nil })
    }
}
```

- [ ] **Step 4: Run test to verify it passes**

Run: `cd Packages/StrandNutrition && swift test`
Expected: PASS (all StrandNutrition tests, 20 total).

- [ ] **Step 5: Commit**

```bash
git add Packages/StrandNutrition
git commit -m "feat(nutrition): Claude meal/label reply schemas and decoders"
```

---

### Task 6: Wire the package into WhoopStore, the Xcode project and CI

**Files:**
- Modify: `Packages/WhoopStore/Package.swift`
- Modify: `project.yml` (packages block ~line 43; Mac app deps ~152-160; iOS app deps ~358-365)
- Modify: `.github/workflows/swift-packages.yml` (matrix)

- [ ] **Step 1: WhoopStore depends on StrandNutrition**

In `Packages/WhoopStore/Package.swift`, add to `dependencies:` after `.package(path: "../OuraProtocol"),`:

```swift
        .package(path: "../StrandNutrition"),
```

and change the `WhoopStore` target dependencies to:

```swift
          .target(name: "WhoopStore", dependencies: ["WhoopProtocol", "OuraProtocol", "StrandNutrition",
                  .product(name: "GRDB", package: "GRDB.swift")]),
```

- [ ] **Step 2: project.yml package entry and target deps**

Under `packages:` (next to `StrandAnalytics:`), add:

```yaml
  StrandNutrition:
    path: Packages/StrandNutrition
```

In both the Mac app target and the iOS app target `dependencies:` lists, after `- package: StrandAnalytics`, add:

```yaml
      - package: StrandNutrition
```

- [ ] **Step 3: CI matrix**

In `.github/workflows/swift-packages.yml`, add `- StrandNutrition` after `- StrandAnalytics` in `matrix.package`.

- [ ] **Step 4: Verify**

Run: `cd Packages/WhoopStore && swift build && cd ../.. && xcodegen generate`
Expected: `Build complete!` and `Created project at .../Strand.xcodeproj`.

- [ ] **Step 5: Commit**

```bash
git add Packages/WhoopStore/Package.swift project.yml .github/workflows/swift-packages.yml
git commit -m "build: wire StrandNutrition into WhoopStore, app targets and CI"
```

---

### Task 7: Migration `v48-food-log`

**Files:**
- Modify: `Packages/WhoopStore/Sources/WhoopStore/Database.swift` (insert before `return migrator`, after the `v47-rr-whoop5-fill` block)
- Modify: `Packages/WhoopStore/Sources/WhoopStore/DeviceRegistryStore.swift:134-170` (`deviceScopedTables`)
- Modify: both `schema_oracle.json` copies
- Test: `Packages/WhoopStore/Tests/WhoopStoreTests/FoodLogStoreTests.swift`

- [ ] **Step 1: Write the failing test**

```swift
import XCTest
import GRDB
@testable import WhoopStore

final class FoodLogStoreTests: XCTestCase {
    func testV48CreatesFoodTables() async throws {
        let store = try await WhoopStore.inMemory()
        let tables = try await store.tableNames()
        XCTAssertTrue(tables.contains("foodEntry"))
        XCTAssertTrue(tables.contains("foodProduct"))
        XCTAssertEqual(try await store.columnNamesForTest(table: "foodEntry"),
                       ["id", "deviceId", "day", "loggedAt", "name", "grams", "kcal", "proteinG",
                        "carbsG", "fatG", "source", "productId"])
        XCTAssertEqual(try await store.columnNamesForTest(table: "foodProduct"),
                       ["id", "deviceId", "name", "brand", "kcal100", "protein100", "carbs100", "fat100",
                        "servingGrams", "origin", "updatedAt"])
        XCTAssertTrue(DeviceRegistryStore.deviceScopedTables.contains("foodEntry"))
        XCTAssertTrue(DeviceRegistryStore.deviceScopedTables.contains("foodProduct"))
    }
}
```

(If `deviceScopedTables` is `private`, check its access level first; it is `static let` in `DeviceRegistryStore`, internal, so `@testable` sees it. If `columnNamesForTest` returns a `Set`, compare against a `Set`.)

- [ ] **Step 2: Run test to verify it fails**

Run: `cd Packages/WhoopStore && swift test --filter FoodLogStoreTests`
Expected: FAIL, `foodEntry` not in tables.

- [ ] **Step 3: Add the migration**

Insert directly after the closing `}` of `migrator.registerMigration("v47-rr-whoop5-fill") { ... }` and before `return migrator`:

```swift
        // v48: macro logger (iOS v1). One row per logged food item plus a local product cache
        // (barcode lookups and Claude-read labels) so a re-scan works offline. Every table carries
        // `deviceId` (the fixed "noop-food" owner) so DeviceRegistryStore.deviceScopedTables clears it.
        // Timestamps are unix seconds; ids are client-generated TEXT. Pinned ios_only in
        // schema_oracle.json until the Android port lands.
        migrator.registerMigration("v48-food-log") { db in
            try db.create(table: "foodEntry", options: [.ifNotExists]) { t in
                t.column("id", .text).primaryKey()
                t.column("deviceId", .text).notNull()
                t.column("day", .text).notNull()          // local calendar day yyyy-MM-dd
                t.column("loggedAt", .integer).notNull()  // unix seconds
                t.column("name", .text).notNull()
                t.column("grams", .double)                // NULL for Quick add totals
                t.column("kcal", .double).notNull()
                t.column("proteinG", .double).notNull()
                t.column("carbsG", .double).notNull()
                t.column("fatG", .double).notNull()
                t.column("source", .text).notNull()       // photo / barcode / recent / quick / label
                t.column("productId", .text)
            }
            try db.create(index: "idx_foodEntry_day", on: "foodEntry",
                          columns: ["deviceId", "day"], options: [.ifNotExists])
            try db.create(table: "foodProduct", options: [.ifNotExists]) { t in
                t.column("id", .text).primaryKey()        // barcode, or custom:<uuid>
                t.column("deviceId", .text).notNull()
                t.column("name", .text).notNull()
                t.column("brand", .text)
                t.column("kcal100", .double).notNull()
                t.column("protein100", .double).notNull()
                t.column("carbs100", .double).notNull()
                t.column("fat100", .double).notNull()
                t.column("servingGrams", .double)
                t.column("origin", .text).notNull()       // off / label / manual
                t.column("updatedAt", .integer).notNull() // unix seconds
            }
        }
```

- [ ] **Step 4: Add to `deviceScopedTables`**

In `DeviceRegistryStore.swift`, on the line containing `"liftExercise", "liftProgram", "liftProgramItem", "liftSession", "liftSet",` append `"foodEntry", "foodProduct",` (same line or the next line, matching the array's formatting).

- [ ] **Step 5: Update the schema oracle (both copies, byte-identical)**

Run this once from the repo root; it edits the iOS copy and copies it over the Android one:

```bash
python3 - <<'EOF'
import json, collections
p = "Packages/WhoopStore/Tests/WhoopStoreTests/Resources/schema_oracle.json"
d = json.load(open(p), object_pairs_hook=collections.OrderedDict)
d["grdbMigrations"].append("v48-food-log")
def col(n, a, nn): return {"name": n, "affinity": a, "notNull": nn, "default": None}
reason = "Macro logger (GRDB v48). iOS-only until the Android port; Android has no Room table yet."
d["tables"]["foodEntry"] = {"platform": "ios_only", "reason": reason, "columns": [
    col("id","TEXT",False), col("deviceId","TEXT",True), col("day","TEXT",True), col("loggedAt","INTEGER",True),
    col("name","TEXT",True), col("grams","REAL",False), col("kcal","REAL",True), col("proteinG","REAL",True),
    col("carbsG","REAL",True), col("fatG","REAL",True), col("source","TEXT",True), col("productId","TEXT",False)],
    "primaryKey": ["id"], "indices": []}
d["tables"]["foodProduct"] = {"platform": "ios_only", "reason": reason, "columns": [
    col("id","TEXT",False), col("deviceId","TEXT",True), col("name","TEXT",True), col("brand","TEXT",False),
    col("kcal100","REAL",True), col("protein100","REAL",True), col("carbs100","REAL",True), col("fat100","REAL",True),
    col("servingGrams","REAL",False), col("origin","TEXT",True), col("updatedAt","INTEGER",True)],
    "primaryKey": ["id"], "indices": []}
json.dump(d, open(p, "w"), indent=2, ensure_ascii=False)
open(p, "a").write("\n")
EOF
cp Packages/WhoopStore/Tests/WhoopStoreTests/Resources/schema_oracle.json android/app/src/test/resources/schema_oracle.json
git diff --stat
```

Then check the diff is only the additions. If `json.dump` reformatted unrelated lines (indent or key order differs from the original), revert and instead hand-insert the two table objects and the migration name matching the file's existing formatting. Then open an existing table with an index (search `"indices": [{`) and add the `idx_foodEntry_day` index to `foodEntry.indices` in the same shape.

- [ ] **Step 6: Run tests**

Run: `cd Packages/WhoopStore && swift test --filter "FoodLogStoreTests|SchemaOracleTests|MigrationTests"`
Expected: PASS. If `SchemaOracleTests` fails, its message names the exact mismatch (affinity, notNull, index shape); fix the oracle entry, re-copy to the Android path, re-run.

- [ ] **Step 7: Commit**

```bash
git add Packages/WhoopStore android/app/src/test/resources/schema_oracle.json
git commit -m "feat(store): v48-food-log migration (foodEntry, foodProduct)"
```

---

### Task 8: Food log CRUD and day totals

**Files:**
- Create: `Packages/WhoopStore/Sources/WhoopStore/FoodLogStore.swift`
- Test: `Packages/WhoopStore/Tests/WhoopStoreTests/FoodLogStoreTests.swift` (append)

- [ ] **Step 1: Write the failing tests** (append inside `FoodLogStoreTests`)

```swift
    private func entry(_ id: String, day: String = "2026-10-20", at: Int = 1_000, name: String = "Oats",
                       kcal: Double = 200, p: Double = 10, c: Double = 30, f: Double = 4,
                       productId: String? = nil, grams: Double? = 50) -> FoodEntryRow {
        FoodEntryRow(id: id, deviceId: FoodLog.deviceId, day: day, loggedAt: at, name: name, grams: grams,
                     kcal: kcal, proteinG: p, carbsG: c, fatG: f, source: "quick", productId: productId)
    }

    private func totals(_ store: WhoopStore, _ day: String) async throws -> [String: Double] {
        var out: [String: Double] = [:]
        for k in FoodLog.metricKeys {
            out[k] = try await store.metricSeries(deviceId: FoodLog.deviceId, key: k, from: day, to: day).first?.value
        }
        return out
    }

    func testInsertRecomputesDayTotals() async throws {
        let store = try await WhoopStore.inMemory()
        try await store.insertFoodEntries([entry("a"), entry("b", kcal: 100, p: 5, c: 10, f: 1)])
        let t = try await totals(store, "2026-10-20")
        XCTAssertEqual(t["calories_in"], 300)
        XCTAssertEqual(t["protein_g"], 15)
        XCTAssertEqual(t["carbs_g"], 40)
        XCTAssertEqual(t["fat_g"], 5)
        XCTAssertEqual(try await store.foodEntries(deviceId: FoodLog.deviceId, day: "2026-10-20").map(\.id), ["a", "b"])
    }

    func testUpdateAndDeleteKeepTotalsRight() async throws {
        let store = try await WhoopStore.inMemory()
        try await store.insertFoodEntries([entry("a"), entry("b", kcal: 100)])
        var a = entry("a"); a.kcal = 50
        try await store.updateFoodEntry(a)
        XCTAssertEqual(try await totals(store, "2026-10-20")["calories_in"], 150)
        XCTAssertTrue(try await store.deleteFoodEntry(id: "b"))
        XCTAssertEqual(try await totals(store, "2026-10-20")["calories_in"], 50)
    }

    func testDeletingLastEntryRemovesDayRows() async throws {
        let store = try await WhoopStore.inMemory()
        try await store.insertFoodEntries([entry("a")])
        XCTAssertTrue(try await store.deleteFoodEntry(id: "a"))
        let t = try await totals(store, "2026-10-20")
        XCTAssertTrue(t.values.isEmpty)
        XCTAssertFalse(try await store.deleteFoodEntry(id: "a"))
    }

    func testNutritionCsvRowsUntouched() async throws {
        let store = try await WhoopStore.inMemory()
        try await store.upsertMetricSeries([MetricPoint(day: "2026-10-20", key: "calories_in", value: 2000)],
                                           deviceId: "nutrition-csv")
        try await store.insertFoodEntries([entry("a")])
        _ = try await store.deleteFoodEntry(id: "a")
        let csv = try await store.metricSeries(deviceId: "nutrition-csv", key: "calories_in",
                                               from: "2026-10-20", to: "2026-10-20")
        XCTAssertEqual(csv.first?.value, 2000)
    }

    func testRecentGroupsByNameAndProductOrderedByCount() async throws {
        let store = try await WhoopStore.inMemory()
        try await store.insertFoodEntries([
            entry("1", at: 100, name: "Oats", grams: 40),
            entry("2", at: 200, name: "Banana", grams: 120),
            entry("3", at: 300, name: "Oats", grams: 60),
        ])
        let recent = try await store.recentFoods(deviceId: FoodLog.deviceId, sinceTs: 0, limit: 10)
        XCTAssertEqual(recent.map(\.name), ["Oats", "Banana"])
        XCTAssertEqual(recent.first?.grams, 60) // most recent amount wins
    }

    func testRejectsNegativeOrNonFinite() async throws {
        let store = try await WhoopStore.inMemory()
        do { try await store.insertFoodEntries([entry("a", kcal: -1)]); XCTFail("expected throw") }
        catch is FoodLog.InvalidEntry {}
        do { try await store.insertFoodEntries([entry("b", p: .nan)]); XCTFail("expected throw") }
        catch is FoodLog.InvalidEntry {}
        XCTAssertTrue(try await store.foodEntries(deviceId: FoodLog.deviceId, day: "2026-10-20").isEmpty)
    }

    func testProductUpsertAndFetch() async throws {
        let store = try await WhoopStore.inMemory()
        let p = FoodProductRow(id: "5941234567890", deviceId: FoodLog.deviceId, name: "Oats", brand: nil,
                               kcal100: 372, protein100: 13.5, carbs100: 58.7, fat100: 7, servingGrams: 40,
                               origin: "off", updatedAt: 1)
        try await store.upsertFoodProduct(p)
        XCTAssertEqual(try await store.foodProduct(id: "5941234567890"), p)
        var q = p; q.kcal100 = 380; q.updatedAt = 2
        try await store.upsertFoodProduct(q)
        XCTAssertEqual(try await store.foodProduct(id: "5941234567890")?.kcal100, 380)
        XCTAssertNil(try await store.foodProduct(id: "missing"))
    }
```

- [ ] **Step 2: Run tests to verify they fail**

Run: `cd Packages/WhoopStore && swift test --filter FoodLogStoreTests`
Expected: FAIL, `cannot find 'FoodEntryRow' in scope`.

- [ ] **Step 3: Implement `FoodLogStore.swift`**

```swift
import Foundation
import GRDB
import StrandNutrition

/// Constants for the macro logger's storage.
public enum FoodLog {
    /// Fixed owner for food rows and their metricSeries totals, like the journal's "noop-journal":
    /// food is not tied to whichever strap is active.
    public static let deviceId = "noop-food"
    /// The existing nutrition metric keys (NutritionCsvImport), so Compare/Explore pick totals up.
    public static let metricKeys = ["calories_in", "protein_g", "carbs_g", "fat_g"]

    /// Finite and non-negative in every component. The store rejects anything else.
    public static func isValid(_ m: Macros) -> Bool {
        [m.kcal, m.protein, m.carbs, m.fat].allSatisfy { $0.isFinite && $0 >= 0 }
    }

    public struct InvalidEntry: Error {}
}

public struct FoodEntryRow: Equatable, Codable, Sendable, Identifiable {
    public var id: String
    public var deviceId: String
    public var day: String
    public var loggedAt: Int
    public var name: String
    public var grams: Double?
    public var kcal: Double
    public var proteinG: Double
    public var carbsG: Double
    public var fatG: Double
    public var source: String
    public var productId: String?

    public init(id: String, deviceId: String, day: String, loggedAt: Int, name: String, grams: Double?,
                kcal: Double, proteinG: Double, carbsG: Double, fatG: Double, source: String, productId: String?) {
        self.id = id; self.deviceId = deviceId; self.day = day; self.loggedAt = loggedAt; self.name = name
        self.grams = grams; self.kcal = kcal; self.proteinG = proteinG; self.carbsG = carbsG; self.fatG = fatG
        self.source = source; self.productId = productId
    }

    public var macros: Macros { Macros(kcal: kcal, protein: proteinG, carbs: carbsG, fat: fatG) }

    static func decode(_ row: Row) -> FoodEntryRow {
        FoodEntryRow(id: row["id"], deviceId: row["deviceId"], day: row["day"], loggedAt: row["loggedAt"],
                     name: row["name"], grams: row["grams"], kcal: row["kcal"], proteinG: row["proteinG"],
                     carbsG: row["carbsG"], fatG: row["fatG"], source: row["source"], productId: row["productId"])
    }
}

public struct FoodProductRow: Equatable, Codable, Sendable, Identifiable {
    public var id: String
    public var deviceId: String
    public var name: String
    public var brand: String?
    public var kcal100: Double
    public var protein100: Double
    public var carbs100: Double
    public var fat100: Double
    public var servingGrams: Double?
    public var origin: String
    public var updatedAt: Int

    public init(id: String, deviceId: String, name: String, brand: String?, kcal100: Double, protein100: Double,
                carbs100: Double, fat100: Double, servingGrams: Double?, origin: String, updatedAt: Int) {
        self.id = id; self.deviceId = deviceId; self.name = name; self.brand = brand; self.kcal100 = kcal100
        self.protein100 = protein100; self.carbs100 = carbs100; self.fat100 = fat100
        self.servingGrams = servingGrams; self.origin = origin; self.updatedAt = updatedAt
    }

    public var per100g: MacroPer100g {
        MacroPer100g(kcal: kcal100, protein: protein100, carbs: carbs100, fat: fat100)
    }

    static func decode(_ row: Row) -> FoodProductRow {
        FoodProductRow(id: row["id"], deviceId: row["deviceId"], name: row["name"], brand: row["brand"],
                       kcal100: row["kcal100"], protein100: row["protein100"], carbs100: row["carbs100"],
                       fat100: row["fat100"], servingGrams: row["servingGrams"], origin: row["origin"],
                       updatedAt: row["updatedAt"])
    }
}

extension WhoopStore {
    /// Inserts entries and recomputes the totals of every day they touch, in one transaction.
    public func insertFoodEntries(_ rows: [FoodEntryRow]) async throws {
        guard !rows.isEmpty else { return }
        guard rows.allSatisfy({ FoodLog.isValid($0.macros) }) else { throw FoodLog.InvalidEntry() }
        try syncWrite { db in
            for r in rows { try Self.writeFoodEntry(r, in: db) }
            for ref in Set(rows.map { FoodDayRef(deviceId: $0.deviceId, day: $0.day) }) {
                try Self.recomputeFoodDay(deviceId: ref.deviceId, day: ref.day, in: db)
            }
        }
    }

    /// Replaces an existing entry; recomputes both its old and new day.
    public func updateFoodEntry(_ r: FoodEntryRow) async throws {
        guard FoodLog.isValid(r.macros) else { throw FoodLog.InvalidEntry() }
        try syncWrite { db in
            let oldDay = try String.fetchOne(db, sql: "SELECT day FROM foodEntry WHERE id = ?", arguments: [r.id])
            try Self.writeFoodEntry(r, in: db)
            try Self.recomputeFoodDay(deviceId: r.deviceId, day: r.day, in: db)
            if let oldDay, oldDay != r.day {
                try Self.recomputeFoodDay(deviceId: r.deviceId, day: oldDay, in: db)
            }
        }
    }

    /// Deletes one entry; returns false when it did not exist.
    @discardableResult
    public func deleteFoodEntry(id: String) async throws -> Bool {
        try syncWrite { db in
            guard let row = try Row.fetchOne(db, sql: "SELECT deviceId, day FROM foodEntry WHERE id = ?",
                                             arguments: [id]) else { return false }
            try db.execute(sql: "DELETE FROM foodEntry WHERE id = ?", arguments: [id])
            try Self.recomputeFoodDay(deviceId: row["deviceId"], day: row["day"], in: db)
            return true
        }
    }

    public func foodEntries(deviceId: String, day: String) async throws -> [FoodEntryRow] {
        try syncRead { db in
            try Row.fetchAll(db, sql: """
                SELECT * FROM foodEntry WHERE deviceId = ? AND day = ? ORDER BY loggedAt, id
                """, arguments: [deviceId, day]).map(FoodEntryRow.decode)
        }
    }

    /// Distinct foods (name + productId) logged since `sinceTs`, most frequent first, then most recent.
    /// Each result is that food's most recent entry, so its grams are the last amount used.
    public func recentFoods(deviceId: String, sinceTs: Int, limit: Int) async throws -> [FoodEntryRow] {
        let rows = try syncRead { db in
            try Row.fetchAll(db, sql: """
                SELECT * FROM foodEntry WHERE deviceId = ? AND loggedAt >= ? ORDER BY loggedAt DESC
                """, arguments: [deviceId, sinceTs]).map(FoodEntryRow.decode)
        }
        var latest: [String: FoodEntryRow] = [:]
        var count: [String: Int] = [:]
        for r in rows {
            let k = r.name.lowercased() + "|" + (r.productId ?? "")
            count[k, default: 0] += 1
            if latest[k] == nil { latest[k] = r }
        }
        return latest.sorted {
            let (ca, cb) = (count[$0.key]!, count[$1.key]!)
            return ca != cb ? ca > cb : $0.value.loggedAt > $1.value.loggedAt
        }.prefix(limit).map(\.value)
    }

    public func upsertFoodProduct(_ p: FoodProductRow) async throws {
        try syncWrite { db in
            try db.execute(sql: """
                INSERT INTO foodProduct (id, deviceId, name, brand, kcal100, protein100, carbs100, fat100,
                                         servingGrams, origin, updatedAt)
                VALUES (?, ?, ?, ?, ?, ?, ?, ?, ?, ?, ?)
                ON CONFLICT(id) DO UPDATE SET
                    deviceId = excluded.deviceId, name = excluded.name, brand = excluded.brand,
                    kcal100 = excluded.kcal100, protein100 = excluded.protein100, carbs100 = excluded.carbs100,
                    fat100 = excluded.fat100, servingGrams = excluded.servingGrams, origin = excluded.origin,
                    updatedAt = excluded.updatedAt
                """, arguments: [p.id, p.deviceId, p.name, p.brand, p.kcal100, p.protein100, p.carbs100,
                                 p.fat100, p.servingGrams, p.origin, p.updatedAt])
        }
    }

    public func foodProduct(id: String) async throws -> FoodProductRow? {
        try syncRead { db in
            try Row.fetchOne(db, sql: "SELECT * FROM foodProduct WHERE id = ?", arguments: [id])
                .map(FoodProductRow.decode)
        }
    }

    private struct FoodDayRef: Hashable { let deviceId: String; let day: String }

    static func writeFoodEntry(_ r: FoodEntryRow, in db: Database) throws {
        try db.execute(sql: """
            INSERT OR REPLACE INTO foodEntry
                (id, deviceId, day, loggedAt, name, grams, kcal, proteinG, carbsG, fatG, source, productId)
            VALUES (?, ?, ?, ?, ?, ?, ?, ?, ?, ?, ?, ?)
            """, arguments: [r.id, r.deviceId, r.day, r.loggedAt, r.name, r.grams, r.kcal, r.proteinG,
                             r.carbsG, r.fatG, r.source, r.productId])
    }

    /// Rewrites the day's four metricSeries totals under `deviceId`, or removes them when the day is empty.
    static func recomputeFoodDay(deviceId: String, day: String, in db: Database) throws {
        let entries = try Row.fetchAll(db, sql: "SELECT * FROM foodEntry WHERE deviceId = ? AND day = ?",
                                       arguments: [deviceId, day]).map(FoodEntryRow.decode)
        if entries.isEmpty {
            for key in FoodLog.metricKeys {
                try db.execute(sql: "DELETE FROM metricSeries WHERE deviceId = ? AND day = ? AND key = ?",
                               arguments: [deviceId, day, key])
            }
            return
        }
        let t = entries.map(\.macros).sum()
        let values = [t.kcal, t.protein, t.carbs, t.fat]
        let points = zip(FoodLog.metricKeys, values).map { MetricPoint(day: day, key: $0.0, value: $0.1) }
        _ = try upsertMetricSeries(points, deviceId: deviceId, in: db)
    }
}
```

- [ ] **Step 4: Run tests to verify they pass**

Run: `cd Packages/WhoopStore && swift test --filter FoodLogStoreTests`
Expected: PASS (8 tests). Then the full suite: `swift test` (expected: all pass, no regressions).

- [ ] **Step 5: Commit**

```bash
git add Packages/WhoopStore
git commit -m "feat(store): food log CRUD with metricSeries day totals"
```

---

### Task 9: Anthropic vision request (image + structured output)

**Files:**
- Create: `Strand/AI/AnthropicVision.swift`
- Test: `StrandTests/AnthropicVisionTests.swift` (runs under `xcodebuild test`, macOS `Strand` scheme)

- [ ] **Step 1: Write the failing test**

```swift
import XCTest
@testable import Strand

final class AnthropicVisionTests: XCTestCase {
    func testRequestShape() throws {
        let req = try AnthropicVision.makeRequest(key: "k", model: "claude-sonnet-5-5", prompt: "P",
                                                  jpeg: Data([1, 2, 3]), schemaJSON: #"{"type":"object"}"#)
        XCTAssertEqual(req.url?.absoluteString, "https://api.anthropic.com/v1/messages")
        XCTAssertEqual(req.value(forHTTPHeaderField: "x-api-key"), "k")
        XCTAssertEqual(req.value(forHTTPHeaderField: "anthropic-version"), "2023-06-01")
        let body = try JSONSerialization.jsonObject(with: req.httpBody!) as! [String: Any]
        XCTAssertEqual(body["model"] as? String, "claude-sonnet-5-5")
        let content = ((body["messages"] as! [[String: Any]])[0]["content"]) as! [[String: Any]]
        XCTAssertEqual(content[0]["type"] as? String, "image")
        let source = content[0]["source"] as! [String: Any]
        XCTAssertEqual(source["media_type"] as? String, "image/jpeg")
        XCTAssertEqual(source["data"] as? String, Data([1, 2, 3]).base64EncodedString())
        XCTAssertEqual(content[1]["text"] as? String, "P")
        let format = (body["output_config"] as! [String: Any])["format"] as! [String: Any]
        XCTAssertEqual(format["type"] as? String, "json_schema")
        XCTAssertNotNil(format["schema"] as? [String: Any])
    }

    func testExtractText() throws {
        let ok = Data(#"{"stop_reason":"end_turn","content":[{"type":"text","text":"{\"items\":[]}"}]}"#.utf8)
        XCTAssertEqual(try AnthropicVision.extractJSON(ok), Data(#"{"items":[]}"#.utf8))
        let refused = Data(#"{"stop_reason":"refusal","content":[]}"#.utf8)
        XCTAssertThrowsError(try AnthropicVision.extractJSON(refused))
    }
}
```

The app module is pinned to `Strand` (project.yml ~line 141), so the import is `@testable import Strand`. Check that `StrandTests` sources are picked up by directory (no project.yml edit needed if the target uses `sources: StrandTests`).

- [ ] **Step 2: Run test to verify it fails**

Run: `xcodegen generate && xcodebuild -project Strand.xcodeproj -scheme Strand -destination 'platform=macOS' CODE_SIGNING_ALLOWED=NO test -only-testing:StrandTests/AnthropicVisionTests 2>&1 | tail -20`
Expected: FAIL, `cannot find 'AnthropicVision' in scope`.

- [ ] **Step 3: Implement**

```swift
import Foundation

/// One-shot Anthropic Messages call with an image and a JSON-schema structured output, used by
/// food photo and nutrition-label logging. Kept apart from the streaming chat client, which only
/// carries text content.
enum AnthropicVision {
    struct Failure: LocalizedError {
        let message: String
        var errorDescription: String? { message }
    }

    static func makeRequest(key: String, model: String, prompt: String, jpeg: Data,
                            schemaJSON: String) throws -> URLRequest {
        let schema = try JSONSerialization.jsonObject(with: Data(schemaJSON.utf8))
        let body: [String: Any] = [
            "model": model,
            "max_tokens": 2048,
            "messages": [[
                "role": "user",
                "content": [
                    ["type": "image",
                     "source": ["type": "base64", "media_type": "image/jpeg", "data": jpeg.base64EncodedString()]],
                    ["type": "text", "text": prompt],
                ],
            ]],
            "output_config": ["format": ["type": "json_schema", "schema": schema]],
        ]
        var req = URLRequest(url: AIProvider.anthropic.endpoint)
        req.httpMethod = "POST"
        req.timeoutInterval = 60
        req.setValue(key, forHTTPHeaderField: "x-api-key")
        req.setValue("2023-06-01", forHTTPHeaderField: "anthropic-version")
        req.setValue("application/json", forHTTPHeaderField: "content-type")
        req.httpBody = try JSONSerialization.data(withJSONObject: body)
        return req
    }

    /// The structured-output JSON text of a successful response.
    static func extractJSON(_ data: Data) throws -> Data {
        guard let root = try JSONSerialization.jsonObject(with: data) as? [String: Any] else {
            throw Failure(message: "Unexpected response")
        }
        if (root["stop_reason"] as? String) == "refusal" { throw Failure(message: "The model declined this photo") }
        let blocks = root["content"] as? [[String: Any]] ?? []
        guard let text = blocks.first(where: { $0["type"] as? String == "text" })?["text"] as? String else {
            throw Failure(message: "Empty response")
        }
        return Data(text.utf8)
    }

    static func run(key: String, model: String, prompt: String, jpeg: Data, schemaJSON: String,
                    session: URLSession = .shared) async throws -> Data {
        let req = try makeRequest(key: key, model: model, prompt: prompt, jpeg: jpeg, schemaJSON: schemaJSON)
        let (data, resp) = try await session.data(for: req)
        let status = (resp as? HTTPURLResponse)?.statusCode ?? 0
        guard (200..<300).contains(status) else {
            let msg = ((try? JSONSerialization.jsonObject(with: data)) as? [String: Any])
                .flatMap { ($0["error"] as? [String: Any])?["message"] as? String }
            throw Failure(message: msg ?? "Request failed (HTTP \(status))")
        }
        return try extractJSON(data)
    }
}
```

- [ ] **Step 4: Run test to verify it passes**

Run: same `xcodebuild ... test -only-testing:StrandTests/AnthropicVisionTests` command.
Expected: `** TEST SUCCEEDED **`.

- [ ] **Step 5: Commit**

```bash
git add Strand/AI/AnthropicVision.swift StrandTests/AnthropicVisionTests.swift
git commit -m "feat(ai): Anthropic image request with JSON-schema output"
```

---

### Task 10: Image downscale, vision service, product lookup

**Files:**
- Create: `Strand/Data/FoodImage.swift`
- Create: `Strand/Data/FoodVisionService.swift`
- Create: `Strand/Data/FoodProductLookup.swift`

- [ ] **Step 1: `FoodImage.swift`**

```swift
import Foundation
import ImageIO
import UniformTypeIdentifiers

/// Shrinks a photo to at most `maxPixel` on its long edge and re-encodes it as JPEG, so a food photo
/// sent for recognition stays small. Cross-platform (ImageIO), no UIKit.
enum FoodImage {
    static func jpegForUpload(_ data: Data, maxPixel: Int = 1024, quality: Double = 0.8) -> Data? {
        guard let src = CGImageSourceCreateWithData(data as CFData, nil) else { return nil }
        let opts: [CFString: Any] = [
            kCGImageSourceCreateThumbnailFromImageAlways: true,
            kCGImageSourceCreateThumbnailWithTransform: true,
            kCGImageSourceThumbnailMaxPixelSize: maxPixel,
        ]
        guard let cg = CGImageSourceCreateThumbnailAtIndex(src, 0, opts as CFDictionary) else { return nil }
        let out = NSMutableData()
        guard let dest = CGImageDestinationCreateWithData(out, UTType.jpeg.identifier as CFString, 1, nil) else {
            return nil
        }
        CGImageDestinationAddImage(dest, cg, [kCGImageDestinationLossyCompressionQuality: quality] as CFDictionary)
        return CGImageDestinationFinalize(dest) ? out as Data : nil
    }
}
```

- [ ] **Step 2: `FoodVisionService.swift`**

```swift
import Foundation
import StrandNutrition

/// Photo-based food recognition through the user's own Anthropic key (the Coach provider).
/// Only runs on an explicit user tap; the image is sent once and never stored.
enum FoodVisionService {
    enum Unavailable: LocalizedError {
        case notAnthropic, noKey
        var errorDescription: String? {
            switch self {
            case .notAnthropic: return String(localized: "Photo logging needs the Anthropic provider. Set it up in Coach.")
            case .noKey: return String(localized: "Add your Anthropic API key in Coach to use photo logging.")
            }
        }
    }

    /// Key and model when the configured Coach provider is Anthropic and its key is present.
    static func credentials() throws -> (key: String, model: String) {
        let provider = UserDefaults.standard.string(forKey: "ai.provider").flatMap(AIProvider.init(rawValue:))
        guard provider == .anthropic, AIKeyStore.ownerProvider == AIProvider.anthropic.rawValue else {
            throw Unavailable.notAnthropic
        }
        guard let key = AIKeyStore.read(), !key.isEmpty else { throw Unavailable.noKey }
        let chosen = UserDefaults.standard.string(forKey: "ai.model") ?? AIProvider.anthropic.defaultModel
        // Structured outputs are not supported on Claude 3.x models (still offered in the Coach picker),
        // so fall back to the provider default for photo logging rather than failing every request.
        let model = chosen.hasPrefix("claude-3") ? AIProvider.anthropic.defaultModel : chosen
        return (key, model)
    }

    static var isAvailable: Bool { (try? credentials()) != nil }

    static func analyzeMeal(photo: Data) async throws -> [FoodVisionReply.MealItem] {
        let (key, model) = try credentials()
        guard let jpeg = FoodImage.jpegForUpload(photo) else { throw FoodVisionReply.Failure.malformed }
        let json = try await AnthropicVision.run(key: key, model: model, prompt: FoodVisionReply.mealPrompt,
                                                 jpeg: jpeg, schemaJSON: FoodVisionReply.mealSchemaJSON)
        return try FoodVisionReply.decodeMeal(json)
    }

    static func readLabel(photo: Data) async throws -> FoodVisionReply.Label {
        let (key, model) = try credentials()
        guard let jpeg = FoodImage.jpegForUpload(photo) else { throw FoodVisionReply.Failure.malformed }
        let json = try await AnthropicVision.run(key: key, model: model, prompt: FoodVisionReply.labelPrompt,
                                                 jpeg: jpeg, schemaJSON: FoodVisionReply.labelSchemaJSON)
        return try FoodVisionReply.decodeLabel(json)
    }
}
```

Before writing, confirm the UserDefaults keys and `AIKeyStore` names: `grep -n '"ai.provider"\|"ai.model"\|static var ownerProvider\|static func read' Strand/AI/AICoach.swift`. Use the exact strings found.

- [ ] **Step 3: `FoodProductLookup.swift`**

```swift
import Foundation
import StrandNutrition
import WhoopStore

/// Barcode to product: local cache first, then (only when the user enabled it) Open Food Facts.
/// Only the barcode number leaves the device. Disclosed in PRIVACY_SECURITY.md section 1.1.
enum FoodProductLookup {
    /// Settings toggle, default off.
    static let offEnabledKey = "food.offLookupEnabled"
    static var offEnabled: Bool { UserDefaults.standard.bool(forKey: offEnabledKey) }

    enum Outcome: Equatable {
        case product(FoodProductRow)       // usable: cached or freshly fetched with all macros
        case incomplete(name: String)      // found on OFF but missing macros
        case notFound
        case lookupDisabled
    }

    struct LookupFailed: Error { let status: Int }

    static func lookup(barcode: String, store: WhoopStore, session: URLSession = .shared) async throws -> Outcome {
        if let cached = try await store.foodProduct(id: barcode) { return .product(cached) }
        guard offEnabled else { return .lookupDisabled }
        var comps = URLComponents(string: "https://world.openfoodfacts.org/api/v2/product/\(barcode).json")!
        comps.queryItems = [URLQueryItem(name: "fields", value: OpenFoodFacts.fields)]
        var req = URLRequest(url: comps.url!)
        req.timeoutInterval = 15
        req.setValue("NOOP-iOS/1.0 (personal macro logger)", forHTTPHeaderField: "User-Agent")
        let (data, resp) = try await session.data(for: req)
        let status = (resp as? HTTPURLResponse)?.statusCode ?? 0
        if status == 404 { return .notFound }
        guard (200..<300).contains(status) else { throw LookupFailed(status: status) }
        switch try OpenFoodFacts.decode(data) {
        case .notFound:
            return .notFound
        case .found(let p):
            guard let m = p.per100g else { return .incomplete(name: p.name) }
            let row = FoodProductRow(id: barcode, deviceId: FoodLog.deviceId, name: p.name, brand: p.brand,
                                     kcal100: m.kcal, protein100: m.protein, carbs100: m.carbs, fat100: m.fat,
                                     servingGrams: p.servingGrams, origin: "off",
                                     updatedAt: Int(Date().timeIntervalSince1970))
            try await store.upsertFoodProduct(row)
            return .product(row)
        }
    }
}
```

- [ ] **Step 4: Build both app targets**

Run: `xcodegen generate && xcodebuild -project Strand.xcodeproj -scheme Strand -destination 'platform=macOS' CODE_SIGNING_ALLOWED=NO build -quiet && xcodebuild -project Strand.xcodeproj -scheme NOOPiOS -destination 'generic/platform=iOS' CODE_SIGNING_ALLOWED=NO build -quiet`
Expected: both succeed (no output from `-quiet` besides warnings).

- [ ] **Step 5: Commit**

```bash
git add Strand/Data/FoodImage.swift Strand/Data/FoodVisionService.swift Strand/Data/FoodProductLookup.swift
git commit -m "feat(food): vision service, image downscale, cache-first barcode lookup"
```

---

### Task 11: Food view model

**Files:**
- Create: `Strand/Data/FoodLogModel.swift`

- [ ] **Step 1: Implement**

```swift
import Foundation
import StrandNutrition
import WhoopStore

/// State for the Food screens: today's entries, totals, targets and recent foods.
@MainActor
final class FoodLogModel: ObservableObject {
    static let targetKeys = (kcal: "food.target.kcal", protein: "food.target.proteinG",
                             carbs: "food.target.carbsG", fat: "food.target.fatG")

    /// The day being shown. Recomputed on every load and before every write, so a screen left open
    /// across midnight never files new food under yesterday.
    @Published private(set) var day: String = FoodDay.key(for: Date())
    @Published private(set) var entries: [FoodEntryRow] = []
    @Published private(set) var recent: [FoodEntryRow] = []
    @Published var errorMessage: String?

    var totals: Macros { entries.map(\.macros).sum() }

    var targets: Macros {
        let d = UserDefaults.standard
        return Macros(kcal: d.double(forKey: Self.targetKeys.kcal), protein: d.double(forKey: Self.targetKeys.protein),
                      carbs: d.double(forKey: Self.targetKeys.carbs), fat: d.double(forKey: Self.targetKeys.fat))
    }

    private let repo: Repository
    init(repo: Repository) { self.repo = repo }

    func load() async {
        day = FoodDay.key(for: Date())
        guard let store = await repo.storeHandle() else { return }
        do {
            entries = try await store.foodEntries(deviceId: FoodLog.deviceId, day: day)
            let since = Int(Date().timeIntervalSince1970) - 30 * 86_400
            recent = try await store.recentFoods(deviceId: FoodLog.deviceId, sinceTs: since, limit: 30)
        } catch { errorMessage = error.localizedDescription }
    }

    /// One item to log at `grams` of a per-100 g food.
    struct Pending { var name: String; var grams: Double; var per100g: MacroPer100g; var source: String; var productId: String? }

    /// Logs all items in ONE transaction. Returns false (and sets `errorMessage`) when nothing was
    /// saved, so callers dismiss only on success and a multi-item photo never half-saves.
    @discardableResult
    func log(_ items: [Pending]) async -> Bool {
        let now = Date()
        let rows = items.map { i -> FoodEntryRow in
            let m = i.per100g.scaled(grams: i.grams)
            return FoodEntryRow(id: UUID().uuidString, deviceId: FoodLog.deviceId, day: FoodDay.key(for: now),
                                loggedAt: Int(now.timeIntervalSince1970), name: i.name, grams: i.grams,
                                kcal: m.kcal, proteinG: m.protein, carbsG: m.carbs, fatG: m.fat,
                                source: i.source, productId: i.productId)
        }
        return await insert(rows)
    }

    /// Quick add: totals typed by hand.
    @discardableResult
    func quickAdd(name: String, macros m: Macros) async -> Bool {
        let now = Date()
        return await insert([FoodEntryRow(id: UUID().uuidString, deviceId: FoodLog.deviceId, day: FoodDay.key(for: now),
                                          loggedAt: Int(now.timeIntervalSince1970), name: name, grams: nil,
                                          kcal: m.kcal, proteinG: m.protein, carbsG: m.carbs, fatG: m.fat,
                                          source: "quick", productId: nil)])
    }

    /// Re-logs a recent entry, optionally at a new amount (scales its macros linearly).
    @discardableResult
    func relog(_ r: FoodEntryRow, grams: Double? = nil) async -> Bool {
        var m = r.macros
        if let g = grams, let old = r.grams, old > 0 {
            let f = g / old
            m = Macros(kcal: m.kcal * f, protein: m.protein * f, carbs: m.carbs * f, fat: m.fat * f)
        }
        let now = Date()
        return await insert([FoodEntryRow(id: UUID().uuidString, deviceId: FoodLog.deviceId, day: FoodDay.key(for: now),
                                          loggedAt: Int(now.timeIntervalSince1970), name: r.name, grams: grams ?? r.grams,
                                          kcal: m.kcal, proteinG: m.protein, carbsG: m.carbs, fatG: m.fat,
                                          source: "recent", productId: r.productId)])
    }

    func delete(_ r: FoodEntryRow) async {
        guard let store = await repo.storeHandle() else { return }
        do { _ = try await store.deleteFoodEntry(id: r.id) } catch { errorMessage = error.localizedDescription }
        await load()
    }

    func store() async -> WhoopStore? { await repo.storeHandle() }

    private func insert(_ rows: [FoodEntryRow]) async -> Bool {
        guard rows.allSatisfy({ FoodLog.isValid($0.macros) && ($0.grams ?? 1) > 0 }) else {
            errorMessage = String(localized: "Values must be zero or more.")
            return false
        }
        guard let store = await repo.storeHandle() else { return false }
        do {
            try await store.insertFoodEntries(rows)
            errorMessage = nil
            await load()
            return true
        } catch {
            errorMessage = error.localizedDescription
            return false
        }
    }
}
```

- [ ] **Step 2: Build**

Run: the two `xcodebuild ... build -quiet` commands from Task 10 Step 4.
Expected: both succeed.

- [ ] **Step 3: Commit**

```bash
git add Strand/Data/FoodLogModel.swift
git commit -m "feat(food): FoodLogModel view model"
```

---

### Task 12: Camera permission string

**Files:**
- Modify: `project.yml` (iOS target `info.properties`, next to `NSMicrophoneUsageDescription` ~line 312)
- Modify: `StrandiOS/Resources/Info.plist` (next to `NSMicrophoneUsageDescription` ~line 72)

- [ ] **Step 1: project.yml**

Add above `NSMicrophoneUsageDescription:` (same indentation):

```yaml
        NSCameraUsageDescription: "NOOP uses the camera to scan food barcodes and, when you choose, to photograph a meal or nutrition label for macro logging. Photos are not stored."
```

- [ ] **Step 2: Info.plist**

Add above `<key>NSMicrophoneUsageDescription</key>`:

```xml
	<key>NSCameraUsageDescription</key>
	<string>NOOP uses the camera to scan food barcodes and, when you choose, to photograph a meal or nutrition label for macro logging. Photos are not stored.</string>
```

- [ ] **Step 3: Verify they agree**

Run: `xcodegen generate && git diff --stat StrandiOS/Resources/Info.plist`
Expected: only the two added lines (xcodegen rewrites the plist from `properties`; if it reorders other keys, keep its output).

- [ ] **Step 4: Commit**

```bash
git add project.yml StrandiOS/Resources/Info.plist
git commit -m "feat(ios): camera usage description for food logging"
```

---

### Task 13: iOS screens

All files in this task start with `#if os(iOS)` and end with `#endif`, so the shared `Strand/` folder still compiles for macOS. Use only StrandDesign tokens. Style reference: `Strand/Screens/StressCheckInCard.swift`.

**Files:**
- Create: `Strand/Screens/Food/FoodDayView.swift`
- Create: `Strand/Screens/Food/FoodAddSheet.swift`
- Create: `Strand/Screens/Food/FoodPhotoConfirmView.swift`
- Create: `Strand/Screens/Food/FoodPortionView.swift`
- Create: `Strand/Screens/Food/FoodManualEntryView.swift`
- Create: `Strand/Screens/Food/BarcodeScannerView.swift`
- Create: `Strand/Screens/Food/CameraPicker.swift`

- [ ] **Step 1: `CameraPicker.swift`** (UIKit camera wrapper returning JPEG data)

```swift
#if os(iOS)
import SwiftUI
import UIKit

/// Minimal camera capture: returns the shot as JPEG data, or nil on cancel.
struct CameraPicker: UIViewControllerRepresentable {
    let onFinish: (Data?) -> Void

    func makeCoordinator() -> Coordinator { Coordinator(onFinish: onFinish) }

    func makeUIViewController(context: Context) -> UIImagePickerController {
        let p = UIImagePickerController()
        p.sourceType = UIImagePickerController.isSourceTypeAvailable(.camera) ? .camera : .photoLibrary
        p.delegate = context.coordinator
        return p
    }

    func updateUIViewController(_ vc: UIImagePickerController, context: Context) {}

    final class Coordinator: NSObject, UIImagePickerControllerDelegate, UINavigationControllerDelegate {
        let onFinish: (Data?) -> Void
        init(onFinish: @escaping (Data?) -> Void) { self.onFinish = onFinish }

        func imagePickerController(_ picker: UIImagePickerController,
                                   didFinishPickingMediaWithInfo info: [UIImagePickerController.InfoKey: Any]) {
            onFinish((info[.originalImage] as? UIImage)?.jpegData(compressionQuality: 0.9))
        }

        func imagePickerControllerDidCancel(_ picker: UIImagePickerController) { onFinish(nil) }
    }
}
#endif
```

- [ ] **Step 2: `BarcodeScannerView.swift`** (VisionKit)

```swift
#if os(iOS)
import SwiftUI
import VisionKit

/// Live barcode scanner; reports the first EAN/UPC payload once.
struct BarcodeScannerView: UIViewControllerRepresentable {
    let onCode: (String) -> Void

    static var isSupported: Bool { DataScannerViewController.isSupported && DataScannerViewController.isAvailable }

    func makeCoordinator() -> Coordinator { Coordinator(onCode: onCode) }

    func makeUIViewController(context: Context) -> DataScannerViewController {
        let vc = DataScannerViewController(
            recognizedDataTypes: [.barcode(symbologies: [.ean13, .ean8, .upce])],
            qualityLevel: .balanced, isHighlightingEnabled: true)
        vc.delegate = context.coordinator
        try? vc.startScanning()
        return vc
    }

    func updateUIViewController(_ vc: DataScannerViewController, context: Context) {}

    final class Coordinator: NSObject, DataScannerViewControllerDelegate {
        let onCode: (String) -> Void
        private var done = false
        init(onCode: @escaping (String) -> Void) { self.onCode = onCode }

        func dataScanner(_ s: DataScannerViewController, didAdd items: [RecognizedItem], allItems: [RecognizedItem]) {
            guard !done else { return }
            for case .barcode(let b) in items {
                if let code = b.payloadStringValue, !code.isEmpty {
                    done = true
                    s.stopScanning()
                    onCode(code)
                    return
                }
            }
        }
    }
}
#endif
```

(UPC-A arrives as EAN-13 with a leading zero on iOS, so `.ean13` covers it.)

- [ ] **Step 3: `FoodPortionView.swift`** (grams for one per-100 g food; used by barcode, label and long-press recent)

```swift
#if os(iOS)
import SwiftUI
import StrandDesign
import StrandNutrition

struct FoodPortionView: View {
    let name: String
    let per100g: MacroPer100g
    let servingGrams: Double?
    let lastGrams: Double?
    let onLog: (Double) -> Void
    @State private var grams: Double
    @State private var confirmedImplausible = false

    init(name: String, per100g: MacroPer100g, servingGrams: Double?, lastGrams: Double?,
         onLog: @escaping (Double) -> Void) {
        self.name = name; self.per100g = per100g; self.servingGrams = servingGrams
        self.lastGrams = lastGrams; self.onLog = onLog
        _grams = State(initialValue: lastGrams ?? servingGrams ?? 100)
    }

    private var issues: [PlausibilityIssue] { Plausibility.issues(per100g) }

    var body: some View {
        VStack(alignment: .leading, spacing: 16) {
            Text(name).font(StrandFont.title2).foregroundStyle(StrandPalette.textPrimary)
            Text(String(format: NSLocalizedString("Per 100 g: %.0f kcal · P %.1f · C %.1f · F %.1f", comment: ""),
                        per100g.kcal, per100g.protein, per100g.carbs, per100g.fat))
                .font(StrandFont.footnote).foregroundStyle(StrandPalette.textTertiary)
            HStack {
                Text("Amount").font(StrandFont.subhead).foregroundStyle(StrandPalette.textPrimary)
                Spacer()
                TextField("g", value: $grams, format: .number)
                    .keyboardType(.decimalPad).multilineTextAlignment(.trailing).frame(width: 90)
                Text("g").font(StrandFont.subhead).foregroundStyle(StrandPalette.textSecondary)
            }
            HStack {
                chip(100)
                if let s = servingGrams { chip(s) }
                if let l = lastGrams, l != servingGrams, l != 100 { chip(l) }
            }
            let m = per100g.scaled(grams: grams)
            Text(String(format: NSLocalizedString("%.0f kcal · P %.1f g · C %.1f g · F %.1f g", comment: ""),
                        m.kcal, m.protein, m.carbs, m.fat))
                .font(StrandFont.bodyNumber).foregroundStyle(StrandPalette.textPrimary)
            if !issues.isEmpty {
                Toggle(isOn: $confirmedImplausible) {
                    Text("These values look unusual. Confirm they are right.")
                        .font(StrandFont.footnote).foregroundStyle(StrandPalette.textSecondary)
                }
                .toggleStyle(.switch).tint(StrandPalette.accent)
            }
            NoopButton("Log", systemImage: "checkmark", kind: .primary) { onLog(grams) }
                .disabled(grams <= 0 || (!issues.isEmpty && !confirmedImplausible))
            Spacer()
        }
        .padding(16)
        .background(StrandPalette.surfaceBase)
    }

    private func chip(_ g: Double) -> some View {
        NoopButton(String(format: "%.0f g", g), kind: .secondary) { grams = g }
    }
}
#endif
```

Check `NoopButton`'s initializer in `Packages/StrandDesign/Sources/StrandDesign/NoopButton.swift:166` before using it without `systemImage:`; if `systemImage` is required, pass `systemImage: "scalemass"` for chips.

- [ ] **Step 4: `FoodPhotoConfirmView.swift`**

```swift
#if os(iOS)
import SwiftUI
import StrandDesign
import StrandNutrition

/// Check-and-adjust screen for Claude's meal estimate. Nothing is saved until Log.
struct FoodPhotoConfirmView: View {
    struct Editable: Identifiable { let id = UUID(); var item: FoodVisionReply.MealItem }

    @State private var items: [Editable]
    let onLog: ([FoodVisionReply.MealItem]) -> Void
    @State private var confirmedImplausible = false
    @State private var addingMissed = false

    init(items: [FoodVisionReply.MealItem], onLog: @escaping ([FoodVisionReply.MealItem]) -> Void) {
        _items = State(initialValue: items.map { Editable(item: $0) })
        self.onLog = onLog
    }

    private var flagged: Bool { items.contains { !Plausibility.issues($0.item.per100g).isEmpty } }
    private var total: Macros { items.map { $0.item.per100g.scaled(grams: $0.item.grams) }.sum() }

    var body: some View {
        List {
            ForEach($items) { $e in
                VStack(alignment: .leading, spacing: 8) {
                    HStack {
                        Text(e.item.name).font(StrandFont.subhead).foregroundStyle(StrandPalette.textPrimary)
                        if e.item.confidence == .low || !Plausibility.issues(e.item.per100g).isEmpty {
                            Image(systemName: "exclamationmark.triangle.fill").foregroundStyle(StrandPalette.accent)
                        }
                        Spacer()
                        Text(String(format: "%.0f g", e.item.grams))
                            .font(StrandFont.bodyNumber).foregroundStyle(StrandPalette.textPrimary)
                    }
                    Slider(value: $e.item.grams, in: 5...max(50, e.item.grams * 3), step: 5).tint(StrandPalette.accent)
                    HStack {
                        NoopButton("-25%", kind: .secondary) { e.item.grams = (e.item.grams * 0.75).rounded() }
                        NoopButton("+25%", kind: .secondary) { e.item.grams = (e.item.grams * 1.25).rounded() }
                        Spacer()
                        let m = e.item.per100g.scaled(grams: e.item.grams)
                        Text(String(format: NSLocalizedString("%.0f kcal · P %.0f", comment: ""), m.kcal, m.protein))
                            .font(StrandFont.captionNumber).foregroundStyle(StrandPalette.textSecondary)
                    }
                }
            }
            .onDelete { items.remove(atOffsets: $0) }
            Section {
                NoopButton("Add a missed item", systemImage: "plus", kind: .secondary) { addingMissed = true }
                Text(String(format: NSLocalizedString("Total: %.0f kcal · P %.0f g · C %.0f g · F %.0f g", comment: ""),
                            total.kcal, total.protein, total.carbs, total.fat))
                    .font(StrandFont.subhead).foregroundStyle(StrandPalette.textPrimary)
                if flagged {
                    Toggle("Some values look unusual. I checked them.", isOn: $confirmedImplausible)
                        .tint(StrandPalette.accent)
                }
                NoopButton("Log", systemImage: "checkmark", kind: .primary) { onLog(items.map(\.item)) }
                    .disabled(items.isEmpty || (flagged && !confirmedImplausible))
            }
        }
        .scrollContentBackground(.hidden)
        .background(StrandPalette.surfaceBase)
        .sheet(isPresented: $addingMissed) {
            // Per-100 g entry plus an amount; becomes one more item in this meal.
            FoodManualEntryView(mode: .per100g(grams: 100)) { name, per100g, grams in
                items.append(Editable(item: .init(name: name, grams: grams ?? 100, per100g: per100g, confidence: .high)))
                addingMissed = false
            }
        }
    }
}
#endif
```

- [ ] **Step 5: `FoodManualEntryView.swift`** (Quick add totals, and per-100 g entry for products and missed items)

```swift
#if os(iOS)
import SwiftUI
import StrandDesign
import StrandNutrition

/// Hand entry in two modes: `.totals` (Quick add: the eaten amount's macros) and `.per100g`
/// (a product or missed item: values per 100 g plus the amount eaten). Rejects negative values.
struct FoodManualEntryView: View {
    enum Mode { case totals, per100g(grams: Double) }

    let mode: Mode
    /// name, values (totals or per 100 g, per mode), grams (nil in `.totals`)
    let onDone: (String, MacroPer100g, Double?) -> Void

    @State private var name = ""
    @State private var kcal: Double?
    @State private var protein: Double?
    @State private var carbs: Double?
    @State private var fat: Double?
    @State private var grams: Double?

    private var isPer100g: Bool { if case .per100g = mode { return true } else { return false } }
    private var values: [Double?] { [kcal, protein, carbs, fat] }
    private var valid: Bool {
        values.contains { $0 != nil } && values.allSatisfy { ($0 ?? 0) >= 0 }
            && (!isPer100g || (grams ?? 0) > 0)
    }

    var body: some View {
        Form {
            TextField("Name", text: $name)
            if isPer100g { Text("Values per 100 g").font(StrandFont.footnote).foregroundStyle(StrandPalette.textTertiary) }
            field("Calories (kcal)", $kcal)
            field("Protein (g)", $protein)
            field("Carbs (g)", $carbs)
            field("Fat (g)", $fat)
            if isPer100g { field("Amount eaten (g)", $grams) }
            NoopButton(isPer100g ? "Save" : "Log", systemImage: "checkmark", kind: .primary) {
                onDone(name.isEmpty ? String(localized: "Quick add") : name,
                       MacroPer100g(kcal: kcal ?? 0, protein: protein ?? 0, carbs: carbs ?? 0, fat: fat ?? 0),
                       isPer100g ? grams : nil)
            }
            .disabled(!valid)
        }
        .scrollContentBackground(.hidden)
        .background(StrandPalette.surfaceBase)
        .onAppear { if case .per100g(let g) = mode, grams == nil { grams = g } }
    }

    private func field(_ label: LocalizedStringKey, _ v: Binding<Double?>) -> some View {
        HStack {
            Text(label).font(StrandFont.subhead).foregroundStyle(StrandPalette.textPrimary)
            Spacer()
            TextField("0", value: v, format: .number).keyboardType(.decimalPad)
                .multilineTextAlignment(.trailing).frame(width: 90)
        }
    }
}
#endif
```

- [ ] **Step 6: `FoodAddSheet.swift`** (the four-button entry point and all the flow wiring)

```swift
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
```

`Step.id` is distinct per step, so `.sheet(item:)` swaps content when the step changes. `PhotosPicker` needs no usage string (it runs out of process).

- [ ] **Step 7: `FoodDayView.swift`** (the screen reached from More)

```swift
#if os(iOS)
import SwiftUI
import StrandDesign
import StrandNutrition
import WhoopStore

struct FoodDayView: View {
    @EnvironmentObject var repo: Repository
    @StateObject private var holder = Holder()
    @State private var adding = false

    /// Lazily builds the model once `repo` is available from the environment.
    @MainActor final class Holder: ObservableObject { var model: FoodLogModel? }

    var body: some View {
        let model = holder.model ?? { let m = FoodLogModel(repo: repo); holder.model = m; return m }()
        FoodDayContent(model: model, adding: $adding)
            .task { await model.load() }
    }
}

private struct FoodDayContent: View {
    @ObservedObject var model: FoodLogModel
    @Binding var adding: Bool

    var body: some View {
        List {
            Section {
                StrandCard {
                    VStack(alignment: .leading, spacing: 10) {
                        row("Calories", model.totals.kcal, model.targets.kcal, "kcal")
                        row("Protein", model.totals.protein, model.targets.protein, "g")
                        row("Carbs", model.totals.carbs, model.targets.carbs, "g")
                        row("Fat", model.totals.fat, model.targets.fat, "g")
                    }
                }
                .listRowBackground(Color.clear)
            }
            Section("Today") {
                if model.entries.isEmpty {
                    Text("Nothing logged yet.").font(StrandFont.footnote).foregroundStyle(StrandPalette.textTertiary)
                }
                ForEach(model.entries) { e in
                    HStack {
                        VStack(alignment: .leading) {
                            Text(e.name).font(StrandFont.subhead).foregroundStyle(StrandPalette.textPrimary)
                            Text(Date(timeIntervalSince1970: TimeInterval(e.loggedAt)), style: .time)
                                .font(StrandFont.caption).foregroundStyle(StrandPalette.textTertiary)
                        }
                        Spacer()
                        Text(String(format: NSLocalizedString("%.0f kcal · P %.0f", comment: ""), e.kcal, e.proteinG))
                            .font(StrandFont.captionNumber).foregroundStyle(StrandPalette.textSecondary)
                    }
                }
                .onDelete { idx in
                    let rows = idx.map { model.entries[$0] }
                    Task { for r in rows { await model.delete(r) } }
                }
            }
            if let err = model.errorMessage {
                Text(err).font(StrandFont.footnote).foregroundStyle(StrandPalette.textSecondary)
            }
        }
        .scrollContentBackground(.hidden)
        .background(StrandPalette.surfaceBase)
        .navigationTitle("Food")
        .toolbar {
            ToolbarItem(placement: .primaryAction) {
                Button { adding = true } label: { Image(systemName: "plus.circle.fill") }
            }
        }
        .sheet(isPresented: $adding, onDismiss: { Task { await model.load() } }) {
            FoodAddSheet(model: model)
        }
    }

    private func row(_ label: LocalizedStringKey, _ value: Double, _ target: Double, _ unit: String) -> some View {
        VStack(alignment: .leading, spacing: 4) {
            HStack {
                Text(label).font(StrandFont.subhead).foregroundStyle(StrandPalette.textPrimary)
                Spacer()
                Text(target > 0 ? String(format: "%.0f / %.0f %@", value, target, unit)
                                : String(format: "%.0f %@", value, unit))
                    .font(StrandFont.bodyNumber).foregroundStyle(StrandPalette.textPrimary)
            }
            if target > 0 {
                ProgressView(value: min(value / target, 1)).tint(StrandPalette.accent)
            }
        }
    }
}
#endif
```

If assigning `holder.model` inside `body` triggers a "Publishing changes from within view updates" warning, move model creation into `.task` (`if holder.model == nil { holder.model = FoodLogModel(repo: repo) }`) and render `ProgressView()` until it exists.

- [ ] **Step 8: Build iOS and macOS**

Run: `xcodegen generate && xcodebuild -project Strand.xcodeproj -scheme NOOPiOS -destination 'generic/platform=iOS' CODE_SIGNING_ALLOWED=NO build -quiet && xcodebuild -project Strand.xcodeproj -scheme Strand -destination 'platform=macOS' CODE_SIGNING_ALLOWED=NO build -quiet`
Expected: both succeed. Fix compile errors against the real StrandDesign signatures (`NoopButton`, `StrandCard`, font names) by reading `Packages/StrandDesign/Sources/StrandDesign/`.

- [ ] **Step 9: Commit**

```bash
git add Strand/Screens/Food
git commit -m "feat(food): iOS food day view, add sheet, photo confirm, barcode and portion screens"
```

---

### Task 14: Navigation and Settings

**Files:**
- Modify: `StrandiOS/App/RootTabView.swift` (`moreSection("Body")` ~line 477; `MoreDestination` ~line 600)
- Modify: `Strand/Screens/SettingsView.swift`

- [ ] **Step 1: More row and destination**

After `MoreRow("Lift Log", "dumbbell.fill", .liftLog)` add:

```swift
                    MoreRow("Food", "fork.knife", .food)
```

In `MoreDestination`, add `food` to the case list containing `liftLog`, and in the `destination` switch after `case .liftLog:` add:

```swift
        case .food:            FoodDayView()
```

- [ ] **Step 2: Settings section (iOS only)**

In `SettingsView.swift`, add the storage next to the other `@AppStorage` declarations (lines ~45-68):

```swift
    @AppStorage(FoodProductLookup.offEnabledKey) private var foodLookupEnabled = false
    @AppStorage(FoodLogModel.targetKeys.kcal) private var foodTargetKcal = 0.0
    @AppStorage(FoodLogModel.targetKeys.protein) private var foodTargetProtein = 0.0
    @AppStorage(FoodLogModel.targetKeys.carbs) private var foodTargetCarbs = 0.0
    @AppStorage(FoodLogModel.targetKeys.fat) private var foodTargetFat = 0.0
```

Add a computed section property next to `appearanceCard` (insert after the previous property's closing brace, not between a doc comment and its declaration):

```swift
    #if os(iOS)
    private var foodLoggingCard: some View {
        SettingsSection(icon: "fork.knife", title: "Food logging",
                        blurb: "Daily macro targets and barcode lookup. Everything is stored on this iPhone.") {
            VStack(alignment: .leading, spacing: 12) {
                Toggle(isOn: $foodLookupEnabled) {
                    VStack(alignment: .leading, spacing: 2) {
                        Text("Look up barcodes on Open Food Facts")
                            .font(StrandFont.subhead).foregroundStyle(StrandPalette.textPrimary)
                        Text("Sends only the barcode number of a product you haven't scanned before. Off by default.")
                            .font(StrandFont.footnote).foregroundStyle(StrandPalette.textTertiary)
                    }
                }
                .toggleStyle(.switch).tint(StrandPalette.accent)
                Divider().overlay(StrandPalette.hairline)
                targetField("Calories (kcal)", $foodTargetKcal)
                targetField("Protein (g)", $foodTargetProtein)
                targetField("Carbs (g)", $foodTargetCarbs)
                targetField("Fat (g)", $foodTargetFat)
            }
        }
    }

    private func targetField(_ label: LocalizedStringKey, _ value: Binding<Double>) -> some View {
        HStack {
            Text(label).font(StrandFont.subhead).foregroundStyle(StrandPalette.textPrimary)
            Spacer()
            TextField("0", value: value, format: .number)
                .keyboardType(.numberPad).multilineTextAlignment(.trailing).frame(width: 90)
        }
    }
    #endif
```

Then find where the section cards are listed in `body` (search for `appearanceCard` usage) and add, at a sensible position near the AI Coach card:

```swift
                #if os(iOS)
                foodLoggingCard
                #endif
```

Check `SettingsSection`'s initializer labels first (`grep -n "struct SettingsSection" -A12 Strand/Screens/*.swift`) and match them exactly.

- [ ] **Step 3: Build both**

Run: the two `xcodebuild ... build -quiet` commands from Task 13 Step 8.
Expected: both succeed.

- [ ] **Step 4: Commit**

```bash
git add StrandiOS/App/RootTabView.swift Strand/Screens/SettingsView.swift
git commit -m "feat(food): More > Food entry and Food logging settings"
```

---

### Task 14b: Show logged totals in Compare/Explore, and "Delete all food data"

Independent plan review found that `MetricCatalog` declares the nutrition keys only under `nutrition-csv`
(`Strand/Data/MetricCatalog.swift:186-189`) and Compare reads each descriptor's exact source, so totals under
`noop-food` would be invisible. It also found that `deleteAllData(deviceId:)` is only ever called for a
registered device or Apple Health, so adding the tables to `deviceScopedTables` alone never clears food data.

**Files:**
- Modify: `Strand/Data/MetricCatalog.swift` (`sourceLabel` switch ~line 22; nutrition block ~line 186)
- Modify: `Strand/Screens/SettingsView.swift` (the `foodLoggingCard` from Task 14)
- Test: `StrandTests/FoodCatalogTests.swift`

- [ ] **Step 1: Write the failing test**

```swift
import XCTest
@testable import Strand

final class FoodCatalogTests: XCTestCase {
    func testFoodLogTotalsAreInTheCatalog() {
        for key in ["calories_in", "protein_g", "carbs_g", "fat_g"] {
            let d = MetricCatalog.all.first { $0.key == key && $0.source == "noop-food" }
            XCTAssertNotNil(d, "\(key) has no noop-food descriptor, so logged totals never reach Compare/Explore")
            XCTAssertEqual(d?.sourceLabel, String(localized: "Food log"))
        }
    }

    func testCatalogIdsStayUnique() {
        let ids = MetricCatalog.all.map(\.id)
        XCTAssertEqual(ids.count, Set(ids).count)
    }
}
```

- [ ] **Step 2: Run to verify it fails**

Run: `xcodegen generate && xcodebuild -project Strand.xcodeproj -scheme Strand -destination 'platform=macOS' CODE_SIGNING_ALLOWED=NO test -only-testing:StrandTests/FoodCatalogTests 2>&1 | tail -5`
Expected: FAIL in `testFoodLogTotalsAreInTheCatalog`.

- [ ] **Step 3: Add the descriptors and the label**

In `sourceLabel`, after `case "nutrition-csv": return String(localized: "Nutrition")`, add:

```swift
        case "noop-food":    return String(localized: "Food log")
```

After the `d("fat_g", ... "nutrition-csv" ...)` line, add (ids are `source:key`, so these sit beside the CSV ones the
same way `noop-mood` metrics do):

```swift
        // ── Nutrition logged in-app (macro logger, metricSeries deviceId "noop-food")
        d("calories_in", String(localized: "Calories In"), "Nutrition", "kcal", "noop-food", "fork.knife", 0, nil),
        d("protein_g", String(localized: "Protein"), "Nutrition", "g", "noop-food", "p.circle", 0, nil),
        d("carbs_g", String(localized: "Carbs"), "Nutrition", "g", "noop-food", "c.circle", 0, nil),
        d("fat_g", String(localized: "Fat"), "Nutrition", "g", "noop-food", "f.circle", 0, nil),
```

Then check every place that resolves a metric by key alone (`grep -rn 'first(where: { $0.key ==' Strand StrandiOS`).
Where a lookup by bare key could now return the `noop-food` descriptor instead of the CSV one, make sure that is
acceptable (both carry the same title and unit); if a call site needs the CSV one specifically, add the `source`
condition there.

- [ ] **Step 4: "Delete all food data" in Settings**

In `foodLoggingCard`, after the target fields, add a destructive button behind a confirmation. Use the same store
access the rest of `SettingsView` uses (check for `@EnvironmentObject var repo: Repository` at the top of the file;
add it if absent):

```swift
                Divider().overlay(StrandPalette.hairline)
                Button(role: .destructive) { confirmFoodDelete = true } label: {
                    Text("Delete all food data").font(StrandFont.subhead)
                }
                .confirmationDialog("Delete all logged food, saved products and food totals?",
                                    isPresented: $confirmFoodDelete, titleVisibility: .visible) {
                    Button("Delete", role: .destructive) {
                        Task {
                            guard let store = await repo.storeHandle() else { return }
                            try? await store.deleteAllData(deviceId: FoodLog.deviceId)
                        }
                    }
                }
```

with `@State private var confirmFoodDelete = false` beside the other state. `deleteAllData(deviceId:)` clears every
table in `deviceScopedTables` for that id, which now includes `foodEntry`, `foodProduct` and the `noop-food`
`metricSeries` rows. Add a store test in `FoodLogStoreTests`:

```swift
    func testDeleteAllDataClearsFood() async throws {
        let store = try await WhoopStore.inMemory()
        try await store.insertFoodEntries([entry("a")])
        try await store.upsertFoodProduct(FoodProductRow(id: "1", deviceId: FoodLog.deviceId, name: "x", brand: nil,
            kcal100: 1, protein100: 0, carbs100: 0, fat100: 0, servingGrams: nil, origin: "manual", updatedAt: 1))
        try await store.deleteAllData(deviceId: FoodLog.deviceId)
        XCTAssertTrue(try await store.foodEntries(deviceId: FoodLog.deviceId, day: "2026-10-20").isEmpty)
        XCTAssertNil(try await store.foodProduct(id: "1"))
        XCTAssertTrue(try await store.metricSeries(deviceId: FoodLog.deviceId, key: "calories_in",
                                                   from: "2026-10-20", to: "2026-10-20").isEmpty)
    }
```

(Check the actor-side name with `grep -n "func deleteAllData" Packages/WhoopStore/Sources/WhoopStore/*.swift`;
`Strand/Data/DeviceRegistry.swift:96` calls `store.deleteAllData(deviceId:)`.)

- [ ] **Step 5: Run tests and build**

Run: `cd Packages/WhoopStore && swift test --filter FoodLogStoreTests && cd ../.. && xcodebuild -project Strand.xcodeproj -scheme Strand -destination 'platform=macOS' CODE_SIGNING_ALLOWED=NO test -only-testing:StrandTests/FoodCatalogTests 2>&1 | tail -3 && xcodebuild -project Strand.xcodeproj -scheme NOOPiOS -destination 'generic/platform=iOS' CODE_SIGNING_ALLOWED=NO build -quiet`
Expected: all pass, iOS build succeeds.

- [ ] **Step 6: Commit**

```bash
git add Strand/Data/MetricCatalog.swift Strand/Screens/SettingsView.swift StrandTests/FoodCatalogTests.swift Packages/WhoopStore/Tests
git commit -m "feat(food): logged totals in Compare/Explore; delete all food data"
```

---

### Task 14c: Coach reads the food log

Coach only receives health data when the user has turned on its data consent (`dataConsent`, key `ai.dataConsent`);
`buildFullContext()` in `Strand/AI/AICoach.swift` (~line 956) is only reached with consent on and already appends
summary lines (workouts, stress). The food log joins that same channel: a short text summary, never photos.

**Files:**
- Modify: `Strand/AI/AICoach.swift` (`buildFullContext()` ~line 956; add the block and its formatter next to `stressIndexLine()`)
- Modify: `Packages/WhoopStore/Sources/WhoopStore/FoodLogStore.swift` (a range read for daily totals)
- Test: `StrandTests/AICoachFoodContextTests.swift`, `Packages/WhoopStore/Tests/WhoopStoreTests/FoodLogStoreTests.swift`

- [ ] **Step 1: Store range read (failing test first)**

Append to `FoodLogStoreTests`:

```swift
    func testFoodEntriesInRange() async throws {
        let store = try await WhoopStore.inMemory()
        try await store.insertFoodEntries([entry("a", day: "2026-10-18"), entry("b", day: "2026-10-20"),
                                           entry("c", day: "2026-10-21")])
        let rows = try await store.foodEntries(deviceId: FoodLog.deviceId, from: "2026-10-18", to: "2026-10-20")
        XCTAssertEqual(rows.map(\.id), ["a", "b"])
    }
```

Run: `cd Packages/WhoopStore && swift test --filter FoodLogStoreTests` (expected: FAIL, no such overload). Then add to
the `WhoopStore` extension in `FoodLogStore.swift`, directly after `foodEntries(deviceId:day:)`:

```swift
    /// Entries for an inclusive `yyyy-MM-dd` day range, oldest first.
    public func foodEntries(deviceId: String, from: String, to: String) async throws -> [FoodEntryRow] {
        try syncRead { db in
            try Row.fetchAll(db, sql: """
                SELECT * FROM foodEntry WHERE deviceId = ? AND day >= ? AND day <= ? ORDER BY day, loggedAt, id
                """, arguments: [deviceId, from, to]).map(FoodEntryRow.decode)
        }
    }
```

Re-run: PASS.

- [ ] **Step 2: Formatter test**

```swift
import XCTest
import StrandNutrition
import WhoopStore
@testable import Strand

final class AICoachFoodContextTests: XCTestCase {
    private func row(_ day: String, _ name: String, _ grams: Double?, _ k: Double, _ p: Double, _ c: Double, _ f: Double,
                     at: Int = 0) -> FoodEntryRow {
        FoodEntryRow(id: UUID().uuidString, deviceId: FoodLog.deviceId, day: day, loggedAt: at, name: name, grams: grams,
                     kcal: k, proteinG: p, carbsG: c, fatG: f, source: "quick", productId: nil)
    }

    func testNilWhenNothingLogged() {
        XCTAssertNil(AICoachEngine.foodLogSummary(entries: [], today: "2026-10-20",
                                                  targets: Macros(kcal: 0, protein: 0, carbs: 0, fat: 0)))
    }

    func testTodayItemsTotalsTargetsAndHistory() {
        let entries = [
            row("2026-10-18", "Oats", 80, 300, 10, 50, 5),
            row("2026-10-20", "Chicken breast", 150, 248, 46.5, 0, 5.4, at: 1_760_950_800),
            row("2026-10-20", "Rice", 200, 260, 5.4, 56, 0.6, at: 1_760_951_000),
        ]
        let s = AICoachEngine.foodLogSummary(entries: entries, today: "2026-10-20",
                                             targets: Macros(kcal: 2400, protein: 180, carbs: 250, fat: 70))!
        XCTAssertTrue(s.hasPrefix("Food log (logged in NOOP):"))
        XCTAssertTrue(s.contains("Today so far: 508 kcal, protein 52 g, carbs 56 g, fat 6 g"))
        XCTAssertTrue(s.contains("Daily targets: 2400 kcal, protein 180 g, carbs 250 g, fat 70 g"))
        XCTAssertTrue(s.contains("Chicken breast 150 g"))
        XCTAssertTrue(s.contains("2026-10-18: 300 kcal, P 10, C 50, F 5"))
        XCTAssertFalse(s.contains("2026-10-19"))   // days with nothing logged are left out, not shown as zero
    }

    func testTargetsOmittedWhenUnset() {
        let s = AICoachEngine.foodLogSummary(entries: [row("2026-10-20", "Apple", 150, 78, 0.4, 21, 0.3)],
                                             today: "2026-10-20", targets: Macros(kcal: 0, protein: 0, carbs: 0, fat: 0))!
        XCTAssertFalse(s.contains("Daily targets"))
    }
}
```

Run: `xcodegen generate && xcodebuild -project Strand.xcodeproj -scheme Strand -destination 'platform=macOS' CODE_SIGNING_ALLOWED=NO test -only-testing:StrandTests/AICoachFoodContextTests 2>&1 | tail -5`
Expected: FAIL, `foodLogSummary` not found.

- [ ] **Step 3: Implement the formatter and the block**

Add `import StrandNutrition` to `AICoach.swift` if absent. Insert after the closing brace of `stressIndexSummary(si:)`
(not between a doc comment and its declaration):

```swift
    /// The food-log block for the coach context: today's items, today's totals vs the user's targets, and
    /// the daily totals of the previous days that have entries. Text only, under the same `dataConsent`
    /// gate as the other summaries. nil when nothing is logged in the window, so the block is absent.
    func foodLogBlock(days: Int = 7) async -> String? {
        guard let store = await repo.storeHandle() else { return nil }
        let today = FoodDay.key(for: Date())
        let from = FoodDay.key(for: Calendar.current.date(byAdding: .day, value: -(days - 1), to: Date()) ?? Date())
        let entries = (try? await store.foodEntries(deviceId: FoodLog.deviceId, from: from, to: today)) ?? []
        let d = UserDefaults.standard
        let targets = Macros(kcal: d.double(forKey: FoodLogModel.targetKeys.kcal),
                             protein: d.double(forKey: FoodLogModel.targetKeys.protein),
                             carbs: d.double(forKey: FoodLogModel.targetKeys.carbs),
                             fat: d.double(forKey: FoodLogModel.targetKeys.fat))
        return Self.foodLogSummary(entries: entries, today: today, targets: targets)
    }

    /// Pure formatter for the food-log block, unit-testable without a store.
    static func foodLogSummary(entries: [FoodEntryRow], today: String, targets: Macros) -> String? {
        guard !entries.isEmpty else { return nil }
        func line(_ m: Macros) -> String {
            String(format: "%.0f kcal, protein %.0f g, carbs %.0f g, fat %.0f g", m.kcal, m.protein, m.carbs, m.fat)
        }
        var out = ["Food log (logged in NOOP):"]
        let todays = entries.filter { $0.day == today }.sorted { $0.loggedAt < $1.loggedAt }
        out.append("Today so far: " + line(todays.map(\.macros).sum()))
        if targets.kcal > 0 || targets.protein > 0 || targets.carbs > 0 || targets.fat > 0 {
            out.append("Daily targets: " + line(targets))
        }
        if !todays.isEmpty {
            let items = todays.map { e in e.grams.map { "\(e.name) \(Int($0.rounded())) g" } ?? e.name }
            out.append("Today's items: " + items.joined(separator: "; "))
        }
        let earlier = Dictionary(grouping: entries.filter { $0.day < today }, by: \.day).sorted { $0.key < $1.key }
        if !earlier.isEmpty {
            out.append("Previous days (only days with entries):")
            for (day, rows) in earlier {
                let m = rows.map(\.macros).sum()
                out.append(String(format: "%@: %.0f kcal, P %.0f, C %.0f, F %.0f", day, m.kcal, m.protein, m.carbs, m.fat))
            }
        }
        return out.joined(separator: "\n")
    }
```

In `buildFullContext()`, after the `stressIndexLine()` line, add:

```swift
        if let food = await foodLogBlock() { ctx += "\n\n" + food }
```

`FoodLogModel` lives in `Strand/Data` and is compiled for macOS too (only the screens are iOS-only), so this
compiles on both targets.

- [ ] **Step 4: Run tests and build both targets**

Run: `cd Packages/WhoopStore && swift test --filter FoodLogStoreTests && cd ../.. && xcodebuild -project Strand.xcodeproj -scheme Strand -destination 'platform=macOS' CODE_SIGNING_ALLOWED=NO test -only-testing:StrandTests/AICoachFoodContextTests 2>&1 | tail -3 && xcodebuild -project Strand.xcodeproj -scheme NOOPiOS -destination 'generic/platform=iOS' CODE_SIGNING_ALLOWED=NO build -quiet`
Expected: all pass, iOS builds.

- [ ] **Step 5: Privacy doc note** (folded into Task 15's AI Coach row edit)

The AI Coach row's "What is sent" cell also gains: `; with data consent on, a text summary of the food log (today's items and totals, targets, the previous 6 days' totals)`.

- [ ] **Step 6: Commit**

```bash
git add Strand/AI/AICoach.swift StrandTests/AICoachFoodContextTests.swift Packages/WhoopStore
git commit -m "feat(food): coach context includes the food log summary"
```

---

### Task 15: Docs, translation and lint gates

**Files:**
- Modify: `docs/PRIVACY_SECURITY.md` (section 1.1 table ~line 54-59, plus a new 1.1e subsection after 1.1d)
- Modify: `docs/FEATURES.md` (after the Nutrition (CSV) section ~line 405)

- [ ] **Step 1: Privacy table row** (add after the "Self-hosted push" row)

```markdown
| Food barcode lookup / iOS (§1.1e) | **Off by default**; runs when the user scans a barcode not already in the on-device product cache | The barcode number and a fixed `User-Agent`; no health data, no identifiers | `world.openfoodfacts.org` |
```

Also append to the AI Coach row's "What is sent" cell: `; a meal or nutrition-label photo when the user taps Photo in Food logging (Anthropic provider only, sent once, not stored)`.

- [ ] **Step 2: Subsection 1.1e** (after the 1.1d subsection)

```markdown
#### 1.1e Food barcode lookup (iOS)

Settings > Food logging > "Look up barcodes on Open Food Facts" (default off). When on, scanning a
barcode that is not in the local `foodProduct` cache sends one `GET` to
`https://world.openfoodfacts.org/api/v2/product/<barcode>.json` requesting only the name, brand,
serving size and nutriment fields. The result is cached on the device; later scans of the same
product make no request. Turning the switch off stops new lookups; cached products keep working.
Food photos are not part of this path: they go only to the user's configured Anthropic provider,
only when the user taps Photo, and are never written to disk.
```

- [ ] **Step 3: FEATURES.md**

```markdown
### Food (macro logging, iOS)
Log calories, protein, carbs and fat against daily targets from **More > Food**. Add food by
**Photo** (Claude estimates the items and portions with your own Anthropic key; you check them
before saving), **Barcode** (on-device scan; optional Open Food Facts lookup, cached on the phone),
**Recent** (one tap to log again) or **Quick add**. Daily totals feed the same nutrition metrics as
the CSV import, so Compare and Explore chart them. Photos are never stored.
```

- [ ] **Step 4: Translation gate**

Run: `python3 Tools/i18n_audit.py --ci main`
Expected: either PASS, or a list of new user-facing strings. For each listed string, add an entry to `Strand/Resources/Localizable.xcstrings` in the same shape as neighbouring entries (copy an existing entry that has only an English value and `"extractionState"` matching the audit's expectation), then re-run until it passes. If the audit demands translations for every shipped locale, run `python3 Tools/i18n_audit.py --platform ios --full` to see the required locales and follow the instructions in the audit's own output.

- [ ] **Step 5: Doc comment lint and Python tool suites**

Run: `python3 Tools/doc_comment_lint.py && python3 -m unittest discover Tools 2>&1 | tail -5`
Expected: lint clean; unittest `OK`. If `doc_comment_lint` names lines you did not touch, look at the declarations you inserted (AGENTS.md: the failure prints against other sites) and move your insertion above the neighbour's doc block.

- [ ] **Step 6: Commit**

```bash
git add docs/PRIVACY_SECURITY.md docs/FEATURES.md Strand/Resources/Localizable.xcstrings
git commit -m "docs(food): disclose barcode lookup path and document food logging"
```

---

### Task 16: Full verification and device install

- [ ] **Step 1: Package suites**

Run: `for p in StrandNutrition WhoopStore StrandAnalytics StrandImport; do (cd Packages/$p && swift test 2>&1 | tail -2); done`
Expected: every suite ends with `Test Suite 'All tests' passed` (or swift-testing equivalent).

- [ ] **Step 2: App tests (macOS) and iOS build**

Run: `xcodegen generate && xcodebuild -project Strand.xcodeproj -scheme Strand -destination 'platform=macOS' CODE_SIGNING_ALLOWED=NO test 2>&1 | tail -3 && xcodebuild -project Strand.xcodeproj -scheme NOOPiOS -destination 'generic/platform=iOS' CODE_SIGNING_ALLOWED=NO build -quiet`
Expected: `** TEST SUCCEEDED **`, iOS build succeeds.

- [ ] **Step 3: Signed build and install** (uses the gitignored `Config/BundleIdSecrets.xcconfig` for team and bundle prefix)

```bash
xcodebuild -project Strand.xcodeproj -scheme NOOPiOS -destination 'generic/platform=iOS' \
  -allowProvisioningUpdates -derivedDataPath "$TMPDIR/noop-dd" build -quiet
xcrun devicectl device install app --device <DEVICE_ID from `xcrun devicectl list devices`> \
  "$TMPDIR/noop-dd/Build/Products/Debug-iphoneos/NOOP.app"
```

Expected: `App installed: bundleID: <BUNDLE_ID_PREFIX>.noop`. The camera permission may need re-provisioning; `-allowProvisioningUpdates` handles it.

- [ ] **Step 4: On-device checks (user)**

1. Settings > Food logging: set targets; turn on Open Food Facts lookup.
2. More > Food > + > Photo: photograph a meal; adjust a portion; Log. Totals and the timeline update.
3. Barcode: scan a supermarket product found on OFF; Log 1 serving.
4. Barcode: scan a product not on OFF (or turn lookup off and scan a new one); photograph its nutrition table; Log.
5. Recent: tap the first food to log it again; long-press to change the amount.
6. Compare: pick "Protein" (Food log) and confirm today's value appears.
7. Coach (with data consent on): ask "how much protein have I eaten today?" and check it uses the logged numbers.
8. Settings > Food logging > Delete all food data: the Food screen and Compare are empty afterwards.

- [ ] **Step 5: Final commit if anything changed during verification**

```bash
git status --short
git add -A && git commit -m "fix(food): adjustments from device verification"
```

(Only if Step 4 surfaced fixes. Never `git add -A` with untracked secrets: confirm `Config/BundleIdSecrets.xcconfig` is gitignored first with `git check-ignore Config/BundleIdSecrets.xcconfig`.)

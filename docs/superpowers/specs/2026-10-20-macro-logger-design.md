# Macro logger (iOS, v1) - design

Status: approved in brainstorming, 2026-10-20. Personal build first, structured so it can become an
upstream PR later (issue-first per `AGENTS.md`).

## Goal

Track daily calories, protein, carbs and fat with the least possible friction: snap a photo of a
meal, scan a barcode, re-log a recent food, or type macros directly. Logged totals land in the same
daily nutrition series the CSV import already feeds, so Compare, Explore and Coach use them unchanged.

## Decisions

| Topic | Decision |
|---|---|
| Delivery | Personal build first; upstream-compatible structure (opt-in network, disclosed paths, versioned migration, pure tested core). |
| Platforms | iOS first. macOS must keep compiling (shared files). Android deferred; data shape is port-ready. |
| Meal photos | Claude via the user's own Anthropic API key (the Coach provider). Opt-in. Confirm/adjust screen before anything is saved. Photo is never stored. |
| Barcodes | On-device scan (VisionKit). Product lookup on Open Food Facts (barcode number only), opt-in. Products cached locally; cached products work offline. Fallback: Claude reads a photo of the nutrition table. |
| Targets | Fixed daily targets set by the user (kcal, protein g, carbs g, fat g). |
| Log structure | Flat timeline of timestamped entries. Add sheet: Photo, Barcode, Recent, Quick add. No meal sections, no saved combinations in v1. |

## Architecture

### Units

| Unit | Location | Responsibility | Depends on |
|---|---|---|---|
| `StrandNutrition` (new pure package) | `Packages/StrandNutrition` | Value types (`FoodEntry`, `FoodProduct`, `MacroPer100g`, `DailyMacroTotals`, `MacroTargets`), portion scaling, day aggregation, plausibility check, Open Food Facts JSON decoding, Claude photo-reply JSON decoding. No GRDB, no network, no UIKit. | Foundation only |
| Store | `Packages/WhoopStore` | Migration `v48-food-log` creating `foodEntry` and `foodProduct`; CRUD; recompute of a day's totals into `metricSeries`. | GRDB, `StrandNutrition` |
| Vision AI | `Strand/AI` | Image input + JSON-schema structured output on the Anthropic provider; a `FoodVisionService` with two calls: `analyzeMeal(image)` and `readNutritionLabel(image)`. | AI provider layer, `StrandNutrition` |
| Product lookup | `Strand/Data/FoodProductLookup.swift` | Cache-first lookup; Open Food Facts fetch when enabled; writes results to `foodProduct`. | Store, `StrandNutrition`, URLSession |
| UI | `Strand/Screens/Food/` | Food day view, add sheet, photo confirm screen, barcode scanner, portion screen, quick add, targets editor. iOS entry point in `RootTabView` (More > Body, route `.food`). Screens wrapped in `#if os(iOS)`. | All of the above, `StrandDesign` tokens only |

`StrandNutrition` is a new package so the parsers and math are covered by `swift test` in
`swift-packages.yml` with no app, no network and no strap.

### Data model

`foodEntry` (one row per logged item):

| Column | Type | Notes |
|---|---|---|
| `id` | TEXT PK | UUID string |
| `deviceId` | TEXT | Fixed owner `noop-food` (repo rule: every table carries `deviceId` so delete-all clears it) |
| `day` | TEXT | Local calendar day `yyyy-MM-dd` the entry was eaten (not the wake-day convention; food belongs to the day it was eaten) |
| `loggedAt` | INTEGER | Unix seconds |
| `name` | TEXT | |
| `grams` | REAL | Portion eaten; NULL for Quick add entries entered as totals |
| `kcal`, `proteinG`, `carbsG`, `fatG` | REAL | Totals for this entry (already scaled) |
| `source` | TEXT | `photo` / `barcode` / `recent` / `quick` / `label` |
| `productId` | TEXT NULL | FK-like reference to `foodProduct.id` when from a product |

`foodProduct` (cache of known products and recognised foods):

| Column | Type | Notes |
|---|---|---|
| `id` | TEXT PK | Barcode for scanned products; `custom:<uuid>` otherwise |
| `deviceId` | TEXT | Fixed owner `noop-food` |
| `name`, `brand` | TEXT | brand nullable |
| `kcal100`, `protein100`, `carbs100`, `fat100` | REAL | Per 100 g |
| `servingGrams` | REAL NULL | Package serving size when known |
| `origin` | TEXT | `off` (Open Food Facts) / `label` (Claude-read table) / `manual` |
| `updatedAt` | INTEGER | Unix seconds |

Daily totals: after every insert, update or delete of a `foodEntry`, the store recomputes that day
and upserts `metricSeries` rows under `deviceId = "noop-food"` with the existing keys `calories_in`,
`protein_g`, `carbs_g`, `fat_g`. When a day has no entries left, its four `noop-food` rows are
deleted. The `nutrition-csv` source is never touched. Where both sources have a day, the metric
catalog shows each source distinctly, as it does for other multi-source metrics today.

Targets are four numbers in `UserDefaults` (`food.target.kcal`, `.proteinG`, `.carbsG`, `.fatG`).
Adding them to the `.noopbak` whitelist is part of the upstream PR, not v1.

Recent: distinct `(name, productId)` from `foodEntry` over the last 30 days, ordered by count then
recency, carrying the most recent grams.

## Flows

### Photo

1. Photo button opens the camera (or photo library).
2. Image downscaled to max 1024 px long edge, JPEG, sent once to the Anthropic Messages API with a
   JSON-schema structured output: `items: [{name, grams, kcal100, protein100, carbs100, fat100,
   confidence: low|medium|high}]`. The model is the one selected in Coach.
3. Confirm screen: per item a grams control (slider, -25% / +25%), live macro totals, delete, add a
   missed item (Quick add inline). Low-confidence and implausible items are flagged.
4. Log writes one `foodEntry` per remaining item (`source = photo`) and recomputes the day.
5. The image is not written to disk or the database.

### Barcode

1. Barcode button opens a VisionKit `DataScannerViewController` (EAN-13, EAN-8, UPC-A, UPC-E).
2. Cache hit in `foodProduct` opens the portion screen immediately, offline.
3. Cache miss and lookup enabled: `GET https://world.openfoodfacts.org/api/v2/product/<code>.json`
   with a `fields` filter for name, brand, serving size and the four per-100 g nutriments, and a
   descriptive `User-Agent` as Open Food Facts requests. Only the barcode leaves the device. A hit
   with all four macros is cached (`origin = off`).
4. Portion screen: per-100 g values, grams field, chips for 100 g, the package serving (if known)
   and the last amount used. Log writes a `foodEntry` (`source = barcode`).

### Recent and Quick add

- Recent: tap re-logs with the same grams; long-press opens the portion screen first.
- Quick add: name plus kcal, protein, carbs, fat as totals (`source = quick`, `grams = NULL`).

### Nutrition-table fallback

Offered when a barcode is not found, is found without all four macros, or lookup is off. Claude reads
a photo of the table into per-100 g values (structured output); the user confirms; the product is
cached with `origin = label` under the scanned barcode.

## Error handling

| Situation | Behaviour |
|---|---|
| No Anthropic key configured | Photo and label paths explain how to connect a provider in Coach. Barcode (cache/OFF), Recent and Quick add work. |
| Selected provider is not Anthropic | Same as above, naming that photo logging needs the Anthropic provider in v1. |
| Lookup disabled | Cached products work; new codes offer label photo or manual entry. |
| Offline | Cached products and Recent work; Photo and new barcodes show an offline message and offer Quick add. |
| Product not found / incomplete | Offer label photo or manual entry; result cached under the barcode. |
| Claude reply malformed, empty or refused | "Couldn't read this photo" with Retry and Quick add. Nothing logged automatically. |
| Implausible values | Flag and require explicit confirmation. Rule (in `StrandNutrition`): per 100 g, protein + carbs + fat > 100 g, or any value negative, or `abs(kcal - (4p + 4c + 9f)) > max(40, 0.25 * kcal)`. |
| HTTP/network errors | Surfaced as a short message; never retried silently in the background. |

## Settings and privacy

- New Settings section **Food logging**: "Look up barcodes on Open Food Facts" (default off) and the
  targets editor. Photo logging has no separate switch: it only runs when the user taps Photo with an
  Anthropic provider configured, and the first use shows a one-time notice that the photo is sent to
  Anthropic.
- `NSCameraUsageDescription` added for the iOS target in `project.yml` / Info.plist.
- `docs/PRIVACY_SECURITY.md` §1.1: new row "Food barcode lookup / iOS" (default off; trigger: scan of
  an uncached code; sends the barcode number; destination `world.openfoodfacts.org`) with its own
  subsection; the AI Coach row notes that food and label photos are sent to the chosen provider when
  the user taps Photo.
- `docs/FEATURES.md`: Food section.

## Testing

| Area | Method |
|---|---|
| Portion scaling, day aggregation, plausibility rule | `swift test` in `StrandNutrition` with literal fixtures. |
| Open Food Facts decoding | Fixture JSON: complete product, missing macros, per-serving only, not found (`status: 0`). |
| Claude reply decoding | Fixture JSON: valid, malformed, empty items, implausible values. |
| Store | `WhoopStore` tests: `v48-food-log` creates both tables and leaves existing tables intact; insert/edit/delete keep `noop-food` totals correct; deleting the last entry removes the day's rows; `nutrition-csv` rows untouched. |
| App | `xcodebuild` for `NOOPiOS` and `Strand` (macOS), then install on device. |
| On device (user) | One meal photo, one barcode found on OFF, one not found with label fallback, one Recent re-log. |

## Out of scope (v1)

Android port; activity-adjusted targets; meal sections and saved combinations; micronutrients;
Apple Health dietary writeback; storing photos; text food search; weight-goal targets; OpenAI and
Gemini vision for food (Anthropic only in v1); `.noopbak` whitelist entries for targets.

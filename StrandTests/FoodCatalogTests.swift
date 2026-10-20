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

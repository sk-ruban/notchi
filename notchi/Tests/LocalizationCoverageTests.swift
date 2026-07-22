import XCTest

final class LocalizationCoverageTests: XCTestCase {
    // Keys copied verbatim from Localizable.xcstrings — note the ASCII "..." in "Working...".
    private let sampleKeys = [
        "Launch at Login", "Working...", "Check for Updates", "Sessions", "Plan Mode",
        // Clusters found during render-check that auto-extraction missed (empty-state, cost, services):
        "Waiting for activity", "Today", "Top model", "Stale data", "Network error, retrying in %llds",
        "Expand on Hover",
    ]
    private let targetLocales = ["ja", "zh-Hans", "zh-Hant"]

    func testSampledKeysAreTranslatedInEachLocale() throws {
        for locale in targetLocales {
            let path = try XCTUnwrap(
                Bundle.main.path(forResource: locale, ofType: "lproj"),
                "Missing \(locale).lproj in app bundle"
            )
            let bundle = try XCTUnwrap(Bundle(path: path))
            for key in sampleKeys {
                let value = bundle.localizedString(forKey: key, value: key, table: nil)
                XCTAssertNotEqual(value, key, "\(locale) is missing a translation for \"\(key)\"")
            }
        }
    }

    func testIntInterpolationResolvesThroughStringLocalized() throws {
        let path = try XCTUnwrap(Bundle.main.path(forResource: "ja", ofType: "lproj"))
        let ja = try XCTUnwrap(Bundle(path: path))
        let resolved = String(localized: "Network error, retrying in \(60)s", bundle: ja)
        XCTAssertEqual(resolved, "ネットワークエラー。60秒後に再試行します")
    }
}

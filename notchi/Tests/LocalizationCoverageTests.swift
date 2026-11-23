import XCTest
@testable import notchi

final class LocalizationCoverageTests: XCTestCase {
    // Keys copied verbatim from Localizable.xcstrings — note the ASCII "..." in "Working...".
    private let sampleKeys = [
        "Launch at Login", "Working...", "Check for Updates", "Sessions", "Plan Mode",
        // Clusters found during render-check that auto-extraction missed (empty-state, cost, services):
        "Waiting for activity", "Today", "Top model", "Stale data", "Network error, retrying in %llds",
        "Expand on Hover",
        // Hand-edited into the catalog outside Xcode, so verify they survive the .lproj round-trip:
        "Report an Issue", "Sponsor", "Auto", "Devin Mascot", "Daily",
        "Start Claude Code, Codex or Devin to begin tracking",
        "%@ plan", "No daily or weekly quota",
        // Shown in code paths that used to bypass the catalog:
        "Permission Request", "Yes", "Yes, and don't ask again", "No", "%@ wants to proceed", "Tool",
        "Reading %@", "Writing %@", "Editing %@", "Searching: %@", "Finding: %@",
        "Type a custom answer", "Try again", "Custom Sound", "Claude Usage", "Space", "Key %lld",
        "Neutral", "Happy", "Elated", "Sad", "Sob", "%@ API returned HTTP %lld: %@", "Token expired.",
    ]
    private let targetLocales = ["ja", "zh-Hans", "zh-Hant", "ko", "vi"]

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

    // The day title drops its date in translations on purpose; see its catalog comment.
    private static let keysAllowedToDropPlaceholders: Set<String> = ["cost.dayTokensTitle"]

    func testEveryCatalogKeyIsTranslatedInEachLocaleWithTheSamePlaceholders() throws {
        let catalogURL = URL(fileURLWithPath: #filePath)
            .deletingLastPathComponent()
            .deletingLastPathComponent()
            .appendingPathComponent("notchi/Localizable.xcstrings")
        let catalog = try JSONDecoder().decode(StringCatalog.self, from: Data(contentsOf: catalogURL))
        var problems: [String] = []

        for (key, entry) in catalog.strings where entry.shouldTranslate != false {
            let sourceValue = entry.localizations?["en"]?.stringUnit?.value ?? key
            for locale in targetLocales {
                let units = entry.localizations?[locale]?.allStringUnits ?? []
                guard !units.isEmpty, units.allSatisfy({ $0.state == "translated" }) else {
                    problems.append("\(locale) has no translation for \"\(key)\"")
                    continue
                }
                for unit in units where !Self.keysAllowedToDropPlaceholders.contains(key)
                    && Self.placeholders(in: unit.value) != Self.placeholders(in: sourceValue) {
                    problems.append("\(locale) changes the placeholders of \"\(key)\": \"\(unit.value)\"")
                }
            }
        }

        XCTAssertEqual(problems.sorted(), [])
    }

    func testEnglishModelCountUsesTheSingularForOneModel() throws {
        let english = try localeBundle("en")

        XCTAssertEqual(String(localized: "Found \(1) models at this endpoint.", bundle: english), "Found 1 model at this endpoint.")
    }

    /// The argument kinds in argument order: a translation may reorder numbered placeholders like `%2$@`.
    private static func placeholders(in value: String) -> [String] {
        let matches = value.matches(of: /%(?:(\d+)\$)?(lld|llu|ld|lu|lf|d|u|@|\.\d+f|f)/)
        let isNumbered = matches.contains { $0.output.1 != nil }
        let ordered = isNumbered ? matches.sorted { Int($0.output.1 ?? "") ?? 0 < Int($1.output.1 ?? "") ?? 0 } : matches
        return ordered.map { String($0.output.2) }
    }

    private struct StringCatalog: Decodable {
        let strings: [String: Entry]

        struct Entry: Decodable {
            let shouldTranslate: Bool?
            let localizations: [String: Localization]?
        }

        struct Localization: Decodable {
            let stringUnit: StringUnit?
            /// Plural and device variations, e.g. `["plural": ["one": …, "other": …]]`.
            let variations: [String: [String: Localization]]?

            var allStringUnits: [StringUnit] {
                (stringUnit.map { [$0] } ?? [])
                    + (variations ?? [:]).values.flatMap { $0.values.flatMap(\.allStringUnits) }
            }
        }

        struct StringUnit: Decodable {
            let state: String
            let value: String
        }
    }

    func testTokenCountKeepsItsPlaceholderInEveryLanguage() throws {
        for locale in targetLocales {
            let tokenCount = try localeBundle(locale).localizedString(forKey: "%@ toks", value: nil, table: nil)

            XCTAssertTrue(tokenCount.contains("%@"), "\(locale) dropped the token count from \"%@ toks\"")
        }
    }

    func testHoveredDayTokenTitleShowsTheDateInEnglishAndOmitsItInTranslations() throws {
        let dayLabel = "Dec 28"
        let expectedTitles = [
            "en": "Dec 28 toks",
            "ja": "トークン",
            "ko": "토큰",
            "vi": "Token",
            "zh-Hans": "词元",
            "zh-Hant": "Token",
        ]

        for (locale, expectedTitle) in expectedTitles {
            let title = CostDashboardView.dayTokensTitle(dayLabel: dayLabel, bundle: try localeBundle(locale))

            XCTAssertEqual(title, expectedTitle, locale)
        }
    }

    private func localeBundle(_ locale: String) throws -> Bundle {
        let path = try XCTUnwrap(Bundle.main.path(forResource: locale, ofType: "lproj"), "Missing \(locale).lproj")
        return try XCTUnwrap(Bundle(path: path))
    }

    func testIntInterpolationResolvesThroughStringLocalized() throws {
        let path = try XCTUnwrap(Bundle.main.path(forResource: "ja", ofType: "lproj"))
        let ja = try XCTUnwrap(Bundle(path: path))
        let resolved = String(localized: "Network error, retrying in \(60)s", bundle: ja)
        XCTAssertEqual(resolved, "ネットワークエラー。60秒後に再試行します")
    }
}

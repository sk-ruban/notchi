import XCTest
@testable import notchi

final class UsageDisplayTests: XCTestCase {
    private let futureReset = Date(timeIntervalSince1970: 4_102_444_800)

    func testFormattedResetTimeUsesMinutesUnderAnHour() {
        let usage = QuotaPeriod(utilization: 10, resetDate: Date(timeIntervalSinceNow: 30 * 60 + 30))
        XCTAssertEqual(usage.formattedResetTime, "30m")
    }

    func testFormattedResetTimeUsesHoursAndMinutesUnder48Hours() {
        let usage = QuotaPeriod(utilization: 10, resetDate: Date(timeIntervalSinceNow: 5 * 3600 + 30 * 60 + 30))
        XCTAssertEqual(usage.formattedResetTime, "5h 30m")
    }

    func testFormattedResetTimeUsesDaysAndHoursAtOrAbove48Hours() {
        let usage = QuotaPeriod(utilization: 10, resetDate: Date(timeIntervalSinceNow: 50 * 3600 + 5 * 60))
        XCTAssertEqual(usage.formattedResetTime, "2d 2h")
    }

    func testFormattedResetTimeOmitsHoursAtExactDayBoundary() {
        let usage = QuotaPeriod(utilization: 10, resetDate: Date(timeIntervalSinceNow: 72 * 3600 + 5 * 60))
        XCTAssertEqual(usage.formattedResetTime, "3d")
    }

    func testPeriodDisplayReturnsNilWhenNoUsage() {
        XCTAssertNil(UsageMetrics.periodDisplay(title: "Session", usage: nil))
    }

    func testPeriodDisplayIncludesResetTextWhenResetInFuture() {
        let usage = QuotaPeriod(utilization: 58, resetDate: futureReset)

        let display = UsageMetrics.periodDisplay(title: "Weekly", usage: usage)

        XCTAssertEqual(display?.title, "Weekly")
        XCTAssertEqual(display?.percentUsed, 58)
        XCTAssertEqual(display?.resetText?.hasPrefix("resets in "), true)
    }

    func testPeriodDisplayOmitsResetTextWhenExpired() {
        let usage = QuotaPeriod(utilization: 90, resetDate: Date(timeIntervalSince1970: 1_000))

        let display = UsageMetrics.periodDisplay(title: "Session", usage: usage)

        XCTAssertEqual(display?.percentUsed, 90)
        XCTAssertNil(display?.resetText)
    }

    func testPeriodDisplayClampsUtilizationAboveQuota() {
        let usage = QuotaPeriod(utilization: 137, resetDate: futureReset)

        XCTAssertEqual(UsageMetrics.periodDisplay(title: "Session", usage: usage)?.percentUsed, 100)
    }

    func testPeriodDisplayDefaultsToFreshAndCarriesStaleFlag() {
        let usage = QuotaPeriod(utilization: 20, resetDate: futureReset)

        XCTAssertEqual(UsageMetrics.periodDisplay(title: "Weekly", usage: usage)?.isStale, false)
        XCTAssertEqual(UsageMetrics.periodDisplay(title: "Weekly", usage: usage, isStale: true)?.isStale, true)
    }

    func testExtraUsageDisplayReturnsNilWhenDisabled() {
        let extra = ExtraUsage(isEnabled: false, monthlyLimit: 20, usedCredits: 4.2, utilization: nil)
        XCTAssertNil(UsageMetrics.extraUsageDisplay(extra))
    }

    func testExtraUsageDisplayReturnsNilWhenLimitMissing() {
        let extra = ExtraUsage(isEnabled: true, monthlyLimit: nil, usedCredits: 4.2, utilization: nil)
        XCTAssertNil(UsageMetrics.extraUsageDisplay(extra))
    }

    func testExtraUsageDisplayComputesPercentUsed() {
        let extra = ExtraUsage(isEnabled: true, monthlyLimit: 20, usedCredits: 5, utilization: nil)

        let display = UsageMetrics.extraUsageDisplay(extra)

        XCTAssertEqual(display?.usedCredits, 5)
        XCTAssertEqual(display?.monthlyLimit, 20)
        XCTAssertEqual(display?.percentUsed, 25)
    }

    func testClaudeHasDataTrueWhenAnyPeriodOrExtraUsagePresent() {
        let usage = QuotaPeriod(utilization: 10, resetDate: futureReset)
        let extra = ExtraUsage(isEnabled: true, monthlyLimit: 20, usedCredits: 5, utilization: nil)

        XCTAssertTrue(UsageMetrics.claudeHasData(usage: usage, weeklyUsage: nil, modelUsage: nil, extraUsage: nil))
        XCTAssertTrue(UsageMetrics.claudeHasData(usage: nil, weeklyUsage: usage, modelUsage: nil, extraUsage: nil))
        XCTAssertTrue(UsageMetrics.claudeHasData(usage: nil, weeklyUsage: nil, modelUsage: nil, extraUsage: extra))
    }

    func testClaudeHasDataTrueForModelOnlyData() {
        let model = QuotaPeriod(utilization: 0, resetDate: nil)
        XCTAssertTrue(UsageMetrics.claudeHasData(usage: nil, weeklyUsage: nil, modelUsage: model, extraUsage: nil))
    }

    func testClaudeHasDataFalseWhenNoUsableData() {
        let disabledExtra = ExtraUsage(isEnabled: false, monthlyLimit: 20, usedCredits: 5, utilization: nil)
        XCTAssertFalse(UsageMetrics.claudeHasData(usage: nil, weeklyUsage: nil, modelUsage: nil, extraUsage: disabledExtra))
    }

    func testCodexHasDataReflectsPeriodPresence() {
        let usage = QuotaPeriod(utilization: 10, resetDate: futureReset)
        XCTAssertTrue(UsageMetrics.codexHasData(usage: usage, weeklyUsage: nil))
        XCTAssertTrue(UsageMetrics.codexHasData(usage: nil, weeklyUsage: usage))
        XCTAssertFalse(UsageMetrics.codexHasData(usage: nil, weeklyUsage: nil))
    }

    func testCurrencyFormatsWholeAndFractionalAmounts() {
        XCTAssertEqual(ExtraUsageRowView.currency(20), "$20")
        XCTAssertEqual(ExtraUsageRowView.currency(4.2), "$4.20")
    }

    func testTokenFormatterUsesCompactSuffixes() {
        XCTAssertEqual(CostStatFormatter.tokens(4_300_000_000), "4.3B")
        XCTAssertEqual(CostStatFormatter.tokens(221_000_000), "221M")
        XCTAssertEqual(CostStatFormatter.tokens(950), "950")
    }

    func testUsdFormatterTwoDecimalsWithThousands() {
        XCTAssertEqual(CostStatFormatter.usd(3638.66), "$3,638.66")
        XCTAssertEqual(CostStatFormatter.usd(174.41), "$174.41")
    }

    func testGptNamesLongerThanBaselineDropThePrefix() {
        XCTAssertEqual(CostStatFormatter.modelName("gpt-5.6-sol"), "5.6-sol")
        XCTAssertEqual(CostStatFormatter.modelName("gpt-5.5-pro"), "5.5-pro")
        XCTAssertEqual(CostStatFormatter.modelName("gpt-5-codex"), "5-codex")
    }

    func testShortGptNamesKeepThePrefix() {
        XCTAssertEqual(CostStatFormatter.modelName("gpt-5.5"), "GPT-5.5")
        XCTAssertEqual(CostStatFormatter.modelName("gpt-5.4"), "GPT-5.4")
        XCTAssertEqual(CostStatFormatter.modelName("gpt-5"), "GPT-5")
    }

    func testClaudeNamesAreUnaffectedByGptShortening() {
        XCTAssertEqual(CostStatFormatter.modelName("claude-opus-4-8"), "Opus 4.8")
        XCTAssertEqual(CostStatFormatter.modelName("claude-fable-5"), "Fable 5")
    }
}

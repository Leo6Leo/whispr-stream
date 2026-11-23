import XCTest
@testable import WhisprStream

final class SoundThemeTests: XCTestCase {
    func testRoundTripsEveryStorageFormat() {
        let themes: [SoundTheme] = [
            .pair(.openResolve),
            .systemDefault,
            .system("Funk"),
        ]
        for theme in themes {
            XCTAssertEqual(SoundTheme(storageValue: theme.storageValue), theme)
        }
    }

    func testBareAlertNameIsPrePairsLegacy() {
        XCTAssertEqual(SoundTheme(storageValue: "Funk"), .system("Funk"))
    }

    func testRejectsEmptyAndUnknownPairValues() {
        XCTAssertNil(SoundTheme(storageValue: ""))
        XCTAssertNil(SoundTheme(storageValue: "pair:NoSuchPair"))
    }
}

import XCTest
@testable import jiraBar

final class RefreshDebouncerTests: XCTestCase {

    func testBurstOfPokesFiresOnce() {
        let fired = expectation(description: "action fired")
        var count = 0
        let debouncer = RefreshDebouncer(interval: 0.1) {
            count += 1
            fired.fulfill()
        }

        for _ in 0..<5 { debouncer.poke() }

        wait(for: [fired], timeout: 2.0)
        // Linger past another full interval to catch a straggler firing after the first.
        let settle = expectation(description: "settle")
        DispatchQueue.main.asyncAfter(deadline: .now() + 0.3) { settle.fulfill() }
        wait(for: [settle], timeout: 2.0)
        XCTAssertEqual(count, 1, "a rapid burst must coalesce into a single action")
    }

    func testPokesSpacedBeyondTheIntervalEachFire() {
        let fired = expectation(description: "action fired twice")
        fired.expectedFulfillmentCount = 2
        var count = 0
        let debouncer = RefreshDebouncer(interval: 0.05) {
            count += 1
            fired.fulfill()
        }

        debouncer.poke()
        DispatchQueue.main.asyncAfter(deadline: .now() + 0.2) { debouncer.poke() }

        wait(for: [fired], timeout: 2.0)
        XCTAssertEqual(count, 2, "separate events past the fuse are separate refreshes")
    }

    /// Pins the re-arm pattern AppDelegate relies on: when a refresh is already in flight, the
    /// action pokes the debouncer again from inside itself instead of dropping the request.
    func testPokeFromInsideTheFiredActionSchedulesAnotherFire() {
        let fired = expectation(description: "action fired twice")
        fired.expectedFulfillmentCount = 2
        var count = 0
        var debouncer: RefreshDebouncer!
        debouncer = RefreshDebouncer(interval: 0.05) {
            count += 1
            if count == 1 { debouncer.poke() }
            fired.fulfill()
        }

        debouncer.poke()

        wait(for: [fired], timeout: 2.0)
        XCTAssertEqual(count, 2, "a poke from inside the action must re-arm the fuse")
    }
}

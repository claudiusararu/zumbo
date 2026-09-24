import Foundation
import XCTest
@testable import VesperEngine

/// `catchingObjCException` must turn a raise into a Swift error. Without it
/// an AVFAudio raise (the tap format mismatch after AirPods connected) killed
/// the app.
final class ObjCExceptionTests: XCTestCase {
    func testRaiseBecomesSwiftError() {
        XCTAssertThrowsError(try catchingObjCException {
            NSException(name: .invalidArgumentException, reason: "boom").raise()
        }) { error in
            let caught = error as? ObjCExceptionError
            XCTAssertEqual(caught?.name, NSExceptionName.invalidArgumentException.rawValue)
            XCTAssertEqual(caught?.reason, "boom")
        }
    }

    func testBodyWithoutRaiseRuns() throws {
        var ran = false
        try catchingObjCException { ran = true }
        XCTAssertTrue(ran)
    }
}

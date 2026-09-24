import Foundation
import ObjCExceptionCatcher

/// An Objective-C exception caught by `catchingObjCException`, as a Swift
/// error.
public struct ObjCExceptionError: LocalizedError {
    public let name: String
    public let reason: String

    public var errorDescription: String? { "\(name): \(reason)" }
}

/// Runs `body` and turns an Objective-C exception it raises into a thrown
/// `ObjCExceptionError`. AVFAudio reports some failures this way (a tap whose
/// format no longer matches the microphone, a player started on a stopped
/// engine). Left alone, the exception unwinds through Swift frames and the
/// app dies moments later somewhere unrelated. Keep `body` to the one call
/// that can raise.
public func catchingObjCException(_ body: () -> Void) throws {
    if let exception = ObjCTry(body) {
        throw ObjCExceptionError(name: exception.name.rawValue, reason: exception.reason ?? "")
    }
}

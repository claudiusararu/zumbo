#import <Foundation/Foundation.h>

NS_ASSUME_NONNULL_BEGIN

/// Runs `block` and returns the Objective-C exception it raised, or nil.
/// Swift cannot catch an NSException, and one unwinding through Swift frames
/// leaves the runtime corrupted, so AVFAudio calls that can raise go through
/// this (see `catchingObjCException` in VesperEngine).
FOUNDATION_EXPORT NSException *_Nullable ObjCTry(NS_NOESCAPE void (^block)(void));

NS_ASSUME_NONNULL_END

import Foundation
import CoreGraphics
import ObjectiveC

/// Private-API wrappers. Both are best-effort: if a symbol vanishes in a
/// future macOS, the wrapper reports failure once and the mapping goes dead
/// without touching anything else.

enum DisplayBrightness {
    private typealias SetBrightnessFn = @convention(c) (CGDirectDisplayID, Float) -> Int32
    private static let setBrightness: SetBrightnessFn? = {
        guard let handle = dlopen("/System/Library/PrivateFrameworks/DisplayServices.framework/DisplayServices", RTLD_LAZY),
              let symbol = dlsym(handle, "DisplayServicesSetBrightness") else {
            return nil
        }
        return unsafeBitCast(symbol, to: SetBrightnessFn.self)
    }()
    private static var warned = false

    @discardableResult
    static func set(_ value: Float) -> Bool {
        guard let fn = setBrightness else {
            if !warned {
                warned = true
                Log.error("DisplayServices unavailable — displayBrightness mapping disabled")
            }
            return false
        }
        return fn(CGMainDisplayID(), min(max(value, 0), 1)) == 0
    }
}

enum NightShift {
    private typealias SetStrengthFn = @convention(c) (AnyObject, Selector, Float, Bool) -> Bool
    private typealias SetEnabledFn = @convention(c) (AnyObject, Selector, Bool) -> Bool

    private static let client: AnyObject? = {
        guard dlopen("/System/Library/PrivateFrameworks/CoreBrightness.framework/CoreBrightness", RTLD_LAZY) != nil,
              let cls = NSClassFromString("CBBlueLightClient") as? NSObject.Type else {
            return nil
        }
        return cls.init()
    }()
    private static var warned = false

    @discardableResult
    static func setStrength(_ value: Float) -> Bool {
        guard let client else {
            if !warned {
                warned = true
                Log.error("CoreBrightness unavailable — nightShiftWarmth mapping disabled")
            }
            return false
        }
        let clamped = min(max(value, 0), 1)
        let setEnabledSel = NSSelectorFromString("setEnabled:")
        let setStrengthSel = NSSelectorFromString("setStrength:commit:")
        guard client.responds(to: setEnabledSel), client.responds(to: setStrengthSel),
              let enabledMethod = class_getMethodImplementation(type(of: client), setEnabledSel),
              let strengthMethod = class_getMethodImplementation(type(of: client), setStrengthSel) else {
            return false
        }
        let setEnabled = unsafeBitCast(enabledMethod, to: SetEnabledFn.self)
        let setStrength = unsafeBitCast(strengthMethod, to: SetStrengthFn.self)
        _ = setEnabled(client, setEnabledSel, clamped > 0.01)
        return setStrength(client, setStrengthSel, clamped, true)
    }
}

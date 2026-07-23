import Foundation
import AppKit

enum ContextRouter {
    static func frontmostBundleID() -> String? {
        NSWorkspace.shared.frontmostApplication?.bundleIdentifier
    }

    /// Key for a context-aware action given the frontmost app, or nil for
    /// no-op. Apps must be listed explicitly in contextKeys — sending Escape
    /// to a random frontmost app is worse than doing nothing.
    static func key(for action: String, config: Config, bundleID: String?) -> KeySpec? {
        guard let bundleID else { return nil }
        return config.contextKeys[action]?[bundleID]
    }
}

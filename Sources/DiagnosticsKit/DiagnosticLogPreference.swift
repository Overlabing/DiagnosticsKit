import Foundation
import Preferences

/// The switch of the app's diagnostic log: off by default, stored under the app's key (`1`/`0`; `defaults write … -bool
/// YES` reads the same). A Debug build forces it on with an environment variable the app names; the switch then shows
/// on and cannot be turned off.
public struct DiagnosticLogPreference: Sendable {
    private let flag: FlagPreference

    public init(
        key: String, forcingVariable: String, store: any KeyValueStore, environment: [String: String], isDebugBuild: Bool
    ) {
        flag = FlagPreference(
            key: key, store: store, forcingVariable: forcingVariable, environment: environment, isDebugBuild: isDebugBuild)
    }

    public var key: String { flag.key }

    /// Forced on by the DEBUG environment.
    public var isForced: Bool { flag.isForced }
    public var isEnabled: Bool { flag.isEnabled }

    public func set(_ enabled: Bool) { flag.set(enabled) }
}

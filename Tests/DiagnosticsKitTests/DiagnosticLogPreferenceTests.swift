import Preferences
import Testing

@testable import DiagnosticsKit

/// The diagnostic log is opt-in, off by default, forced on only by the Debug environment.
struct DiagnosticLogPreferenceTests {
    private func preference(
        _ store: InMemoryKeyValueStore, environment: [String: String] = [:], isDebugBuild: Bool
    ) -> DiagnosticLogPreference {
        DiagnosticLogPreference(
            key: "AppDiagnosticLog", forcingVariable: "APP_DEBUG_DIAGNOSTIC_LOG", store: store, environment: environment,
            isDebugBuild: isDebugBuild)
    }

    @Test func offByDefaultThenWhatTheUserChose() {
        let store = InMemoryKeyValueStore()
        let preference = preference(store, isDebugBuild: true)
        #expect(!preference.isEnabled)
        preference.set(true)
        #expect(preference.isEnabled)
        #expect(store.string(forKey: "AppDiagnosticLog") == "1")
        preference.set(false)
        #expect(!preference.isEnabled)
    }

    @Test func readsABooleanWrittenByDefaults() {
        let store = InMemoryKeyValueStore()
        store.setString("YES", forKey: preference(store, isDebugBuild: false).key)
        #expect(preference(store, isDebugBuild: false).isEnabled)
    }

    @Test func debugEnvironmentForcesItOnInDebugOnly() {
        let environment = ["APP_DEBUG_DIAGNOSTIC_LOG": "1"]
        let debug = preference(InMemoryKeyValueStore(), environment: environment, isDebugBuild: true)
        #expect(debug.isForced && debug.isEnabled)
        debug.set(false)
        #expect(debug.isEnabled)
        let release = preference(InMemoryKeyValueStore(), environment: environment, isDebugBuild: false)
        #expect(!release.isForced && !release.isEnabled)
    }
}

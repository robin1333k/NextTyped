import Foundation
import Testing
import NextTypedCore

@Suite struct AppSettingsStoreLanguageTests {
    private func freshStore() -> (AppSettingsStore, UserDefaults, String) {
        let name = "AppSettingsStoreLanguageTests-\(UUID().uuidString)"
        let defaults = UserDefaults(suiteName: name)!
        return (AppSettingsStore(defaults: defaults), defaults, name)
    }

    @Test func switchingGermanOffStoresDeAndSwitchingOnRemovesTheKey() {
        let (store, defaults, name) = freshStore()
        defer { defaults.removePersistentDomain(forName: name) }
        #expect(defaults.object(forKey: "disabledLanguages") == nil)

        store.setLanguageDisabled(.tag("de"), true)
        #expect(defaults.stringArray(forKey: "disabledLanguages") == ["de"])

        store.setLanguageDisabled(.tag("de"), false)
        #expect(defaults.object(forKey: "disabledLanguages") == nil)
    }

    @Test func allOthersIsStoredAsStarBesideATag() {
        let (store, defaults, name) = freshStore()
        defer { defaults.removePersistentDomain(forName: name) }
        store.setLanguageDisabled(.allOthers, true)
        store.setLanguageDisabled(.tag("en"), true)
        #expect(Set(defaults.stringArray(forKey: "disabledLanguages") ?? []) == ["*", "en"])
    }
}

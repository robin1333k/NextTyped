import Testing
@testable import NextTypedCore

@Suite("AccessibilityPermissionName")
struct AccessibilityPermissionNameTests {
    @Test("macOS 26 and older call the list Accessibility")
    func olderSystemsSayAccessibility() {
        #expect(AccessibilityPermissionName.listTitle(osMajorVersion: 26) == "Accessibility")
        #expect(AccessibilityPermissionName.listTitle(osMajorVersion: 14) == "Accessibility")
    }

    @Test("macOS 27 titles the list Device Control and Data Access")
    func macOS27UsesNewTitle() {
        #expect(AccessibilityPermissionName.listTitle(osMajorVersion: 27) == "Device Control and Data Access")
        #expect(AccessibilityPermissionName.listTitle(osMajorVersion: 28) == "Device Control and Data Access")
    }

    @Test("the hint names the list the user has to find")
    func hintNamesTheList() {
        #expect(AccessibilityPermissionName.findHint(osMajorVersion: 26)
                == "In System Settings, open Privacy & Security and choose Accessibility.")
        #expect(AccessibilityPermissionName.findHint(osMajorVersion: 27)
                == "In System Settings, open Privacy & Security and choose Device Control and Data Access.")
    }
}

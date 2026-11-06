import Testing
@testable import NextTypedCore

@Suite("MoveToApplicationsPolicy")
struct MoveToApplicationsPolicyTests {
    typealias P = MoveToApplicationsPolicy

    @Test(arguments: [P.BundleLocation.diskImage, .downloads, .translocated])
    func offersFromInstallLocations(location: P.BundleLocation) {
        #expect(P.decide(location: location, harnessActive: false, declined: false) == .offer(from: location))
    }

    @Test func skipsInApplications() {
        #expect(P.decide(location: .applications, harnessActive: false, declined: false) == .skip(reason: .inApplications))
    }

    @Test func skipsDeveloperBuild() {
        #expect(P.decide(location: .developer, harnessActive: false, declined: false) == .skip(reason: .developer))
    }

    @Test func skipsOtherLocation() {
        #expect(P.decide(location: .other, harnessActive: false, declined: false) == .skip(reason: .otherLocation))
    }

    @Test(arguments: P.BundleLocation.allCases)
    func harnessWinsEverywhere(location: P.BundleLocation) {
        #expect(P.decide(location: location, harnessActive: true, declined: false) == .skip(reason: .harness))
    }

    @Test func declinedSuppressesTheOffer() {
        #expect(P.decide(location: .diskImage, harnessActive: false, declined: true) == .skip(reason: .declined))
    }

    @Test func logLinesNameCategoriesOnly() {
        #expect(P.Decision.offer(from: .diskImage).logLine == "[install]: offer from=diskImage")
        #expect(P.Decision.skip(reason: .inApplications).logLine == "[install]: skip reason=in-applications")
        #expect(P.Decision.skip(reason: .harness).logLine == "[install]: skip reason=harness")
    }

    @Test(arguments: [
        ("/Volumes/NextTyped/NextTyped.app", P.BundleLocation.diskImage),
        ("/private/var/folders/xx/T/AppTranslocation/ABC/d/NextTyped.app", .translocated),
        ("/Users/r/Downloads/NextTyped.app", .downloads),
        ("/Applications/NextTyped.app", .applications),
        ("/Users/r/Applications/NextTyped.app", .applications),
        ("/Users/r/Library/Developer/Xcode/DerivedData/AC-abc/Build/Products/Debug/NextTyped.app", .developer),
        ("/Users/r/Projects/NextTyped/build/Debug/NextTyped.app", .developer),
        ("/Users/r/Library/Caches/NextTyped/derived/slot1/Build/Products/Debug/NextTyped.app", .developer),
        ("/Users/r/Desktop/NextTyped.app", .other),
        ("/Volumes/Extern/Dev/NextTyped/build/Debug/NextTyped.app", .developer),
        ("/Volumes/Extern/.worktrees/x/NextTyped.app", .developer),
    ])
    func classifiesPaths(path: String, expected: P.BundleLocation) {
        #expect(P.classify(bundlePath: path, home: "/Users/r") == expected)
    }

    @Test func trashesTheDownloadsCopy() {
        #expect(P.disposal(originClass: .downloads, originPath: "/Users/r/Downloads/NextTyped.app", volumeIsDiskImage: false) == .trash)
    }

    @Test func ejectsTheVolumeOfADiskImageCopy() {
        #expect(P.disposal(originClass: .diskImage, originPath: "/Volumes/NextTyped 1/NextTyped.app", volumeIsDiskImage: true)
            == .eject(volume: "/Volumes/NextTyped 1"))
    }

    @Test(arguments: [P.BundleLocation.translocated, .applications, .developer, .other])
    func leavesEverythingElse(location: P.BundleLocation) {
        #expect(P.disposal(originClass: location, originPath: "/x/NextTyped.app", volumeIsDiskImage: true) == .leave)
    }

    @Test func fallsBackToHomeApplicationsWhenSystemIsNotWritable() {
        #expect(P.targetDirectory(system: "/Applications", systemWritable: false, home: "/Users/r") == "/Users/r/Applications")
        #expect(P.targetDirectory(system: "/Applications", systemWritable: true, home: "/Users/r") == "/Applications")
    }

    @Test func usesTheGivenSystemPathWhenItIsWritable() {
        #expect(P.targetDirectory(system: "/tmp/sysapps", systemWritable: true, home: "/Users/r") == "/tmp/sysapps")
        #expect(P.targetDirectory(system: "/tmp/sysapps", systemWritable: false, home: "/Users/r") == "/Users/r/Applications")
    }

    @Test func neverEjectsAnExternalDrive() {
        #expect(P.disposal(originClass: .diskImage, originPath: "/Volumes/Extern/NextTyped.app", volumeIsDiskImage: false) == .leave)
    }

    @Test func doesNotCopyOverAnOriginalThatIsAlreadyInApplications() {
        // A quarantined app moved to /Applications by mv or an unzip tool still runs translocated.
        #expect(P.installStep(originClass: .applications, originPath: "/Applications/NextTyped.app",
                              targetPath: "/Applications/NextTyped.app") == .relaunchInPlace)
        #expect(P.installStep(originClass: .applications, originPath: "/Users/r/Applications/NextTyped.app",
                              targetPath: "/Applications/NextTyped.app") == .relaunchInPlace)
        #expect(P.installStep(originClass: .other, originPath: "/Applications/NextTyped.app",
                              targetPath: "/Applications/NextTyped.app") == .relaunchInPlace)
    }

    @Test func copiesFromDownloadsAndDiskImages() {
        #expect(P.installStep(originClass: .downloads, originPath: "/Users/r/Downloads/NextTyped.app",
                              targetPath: "/Applications/NextTyped.app") == .copy)
        #expect(P.installStep(originClass: .diskImage, originPath: "/Volumes/AC/NextTyped.app",
                              targetPath: "/Applications/NextTyped.app") == .copy)
    }
}

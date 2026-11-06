import Testing
@testable import NextTypedCore

/// The stored strings are pinned as literals: Handy's generated TypeScript type drifted from its
/// stored strings (`min_2` against `min2`), and this suite stops the same drift here.
@Suite struct ModelUnloadSettingTests {

    private func parse(_ s: String?, debug: Bool = true) -> ModelUnloadSetting {
        ModelUnloadSetting(storedValue: s, allowDebugValues: debug)
    }

    @Test func eachStoredStringParsesToItsCase() {
        #expect(parse("automatic") == .automatic)
        #expect(parse("min2") == .min2)
        #expect(parse("min5") == .min5)
        #expect(parse("min15") == .min15)
        #expect(parse("hour1") == .hour1)
        #expect(parse("never") == .never)
        #expect(parse("sec15") == .sec15)
    }

    @Test func rawValuesArePinned() {
        #expect(ModelUnloadSetting.automatic.rawValue == "automatic")
        #expect(ModelUnloadSetting.min2.rawValue == "min2")
        #expect(ModelUnloadSetting.min5.rawValue == "min5")
        #expect(ModelUnloadSetting.min15.rawValue == "min15")
        #expect(ModelUnloadSetting.hour1.rawValue == "hour1")
        #expect(ModelUnloadSetting.never.rawValue == "never")
        #expect(ModelUnloadSetting.sec15.rawValue == "sec15")
    }

    @Test func missingOrUnknownReadsAsAutomatic() {
        #expect(parse(nil) == .automatic)
        #expect(parse("") == .automatic)
        #expect(parse("min3") == .automatic)
    }

    @Test func debugValueReadsAsAutomaticInRelease() {
        #expect(parse("sec15", debug: false) == .automatic)
        #expect(parse("sec15", debug: true) == .sec15)
    }

    @Test func mapsToTheResidencyRule() {
        #expect(ModelUnloadSetting.automatic.rule == .whenAway(absenceSeconds: 150))
        #expect(ModelUnloadSetting.min2.rule == .afterIdle(seconds: 120))
        #expect(ModelUnloadSetting.min5.rule == .afterIdle(seconds: 300))
        #expect(ModelUnloadSetting.min15.rule == .afterIdle(seconds: 900))
        #expect(ModelUnloadSetting.hour1.rule == .afterIdle(seconds: 3600))
        #expect(ModelUnloadSetting.sec15.rule == .afterIdle(seconds: 15))
        #expect(ModelUnloadSetting.never.rule == .never)
    }

    @Test func pickerListHidesTheDebugValueInRelease() {
        #expect(ModelUnloadSetting.pickerCases(allowDebugValues: false)
                == [.automatic, .min2, .min5, .min15, .hour1, .never])
        #expect(ModelUnloadSetting.pickerCases(allowDebugValues: true).last == .sec15)
    }

    @Test func shippingModelMemoryFigures() {
        let b4 = ShippingModel.memoryFigures(localDirectory: "Models/Qwen3.5-4B-Base-MLX-6bit")
        #expect(b4.loaded == "3.4 GB" && b4.unloaded == "140 MB")
        let hub = ShippingModel.memoryFigures(localDirectory: nil)
        #expect(hub.loaded == "3.4 GB" && hub.unloaded == "140 MB")
        let b2 = ShippingModel.memoryFigures(localDirectory: "/Users/x/Models/Qwen3.5-2B-Base-MLX-6bit")
        #expect(b2.loaded == "1.6 GB" && b2.unloaded == "140 MB")
    }
}

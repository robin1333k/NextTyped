import Testing
@testable import NextTypedCore

@Suite struct WritingDirectionTests {
    @Test func hebrewParagraphIsRightToLeft() {
        #expect(WritingDirection.paragraphContainsRightToLeft(before: "שלום עולם", after: ""))
    }

    @Test func arabicParagraphIsRightToLeft() {
        #expect(WritingDirection.paragraphContainsRightToLeft(before: "مرحبا بالعالم", after: ""))
    }

    @Test func oneHebrewWordInAGermanParagraphCounts() {
        #expect(WritingDirection.paragraphContainsRightToLeft(before: "Der Hund שלום", after: ""))
    }

    @Test func rightToLeftTextAfterTheCaretCounts() {
        #expect(WritingDirection.paragraphContainsRightToLeft(before: "Der Hund ", after: "שלום"))
    }

    @Test func germanParagraphAfterAHebrewParagraphIsLeftToRight() {
        #expect(!WritingDirection.paragraphContainsRightToLeft(before: "שלום\nDer Hund", after: ""))
    }

    @Test func germanParagraphAfterHebrewWithCRLFIsLeftToRight() {
        #expect(!WritingDirection.paragraphContainsRightToLeft(before: "שלום\r\nDer Hund", after: ""))
    }

    @Test func germanParagraphAfterHebrewWithCRIsLeftToRight() {
        #expect(!WritingDirection.paragraphContainsRightToLeft(before: "שלום\rDer Hund", after: ""))
    }

    @Test func germanParagraphAfterHebrewWithParagraphSeparatorIsLeftToRight() {
        #expect(!WritingDirection.paragraphContainsRightToLeft(before: "שלום\u{2029}Der Hund", after: ""))
    }

    @Test func hebrewAfterCRLFBelowTheCaretParagraphIsIgnored() {
        #expect(!WritingDirection.paragraphContainsRightToLeft(before: "Der Hund", after: "\r\nשלום"))
    }

    @Test func hebrewParagraphBelowTheCaretParagraphIsIgnored() {
        #expect(!WritingDirection.paragraphContainsRightToLeft(before: "Der Hund", after: "\nשלום"))
    }

    @Test func digitsPunctuationAndLatinAreNeutral() {
        #expect(!WritingDirection.paragraphContainsRightToLeft(before: "123, 456", after: ""))
        #expect(!WritingDirection.paragraphContainsRightToLeft(before: "The dog runs. Der Hund läuft!", after: ""))
        #expect(!WritingDirection.paragraphContainsRightToLeft(before: "", after: ""))
    }

    @Test func otherStrongRightToLeftBlocksCount() {
        #expect(WritingDirection.paragraphContainsRightToLeft(before: "ܐ", after: ""))        // Syriac U+0710
        #expect(WritingDirection.paragraphContainsRightToLeft(before: "ހ", after: ""))        // Thaana U+0780
        #expect(WritingDirection.paragraphContainsRightToLeft(before: "ߊ", after: ""))        // NKo U+07CA
        #expect(WritingDirection.paragraphContainsRightToLeft(before: "ﬡ", after: ""))        // Hebrew presentation form U+FB21
        #expect(WritingDirection.paragraphContainsRightToLeft(before: "ﻻ", after: ""))        // Arabic form B U+FEFB
        #expect(WritingDirection.paragraphContainsRightToLeft(before: "ݐ", after: ""))        // Arabic supplement U+0750
        #expect(WritingDirection.paragraphContainsRightToLeft(before: "ࢠ", after: ""))        // Arabic extended-A U+08A0
    }

    @Test func blockEdgesAreExact() {
        #expect(!WritingDirection.paragraphContainsRightToLeft(before: "\u{058F}", after: ""))
        #expect(WritingDirection.paragraphContainsRightToLeft(before: "\u{0590}", after: ""))
        #expect(!WritingDirection.paragraphContainsRightToLeft(before: "\u{0800}", after: ""))
        #expect(!WritingDirection.paragraphContainsRightToLeft(before: "\u{FB1C}", after: ""))
        #expect(!WritingDirection.paragraphContainsRightToLeft(before: "\u{FE00}", after: ""))
        #expect(WritingDirection.paragraphContainsRightToLeft(before: "\u{FE70}", after: ""))
        #expect(!WritingDirection.paragraphContainsRightToLeft(before: "\u{FF00}", after: ""))
    }
}

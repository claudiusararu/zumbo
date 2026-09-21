import XCTest
@testable import VesperEngine

final class RulesTests: XCTestCase {
    /// Fragment-level tests: the terminal mark is exercised separately.
    private func rules(vocabulary: [VocabTerm] = [], config: RulesConfig = RulesConfig()) -> RulesEngine {
        var cfg = config
        cfg.endPunctuation = false
        return RulesEngine(vocabulary: vocabulary, config: cfg)
    }

    // MARK: - Clean speech: false starts

    func testFalseStartWithTrailingFiller() {
        // The exact sentence from NOTES.md's raw-Parakeet observations.
        let out = rules().apply("I'd like them to I'd like it to be uh on by default")
        XCTAssertEqual(out, "I'd like it to be on by default")
    }

    func testFalseStartThreeWordPrefix() {
        let out = rules().apply("I was going to say I was going to leave early")
        XCTAssertEqual(out, "I was going to leave early")
    }

    func testFalseStartRequiresExactRepeat() {
        // "I want to" vs "I need to" never repeats verbatim - nothing trimmed.
        let out = rules().apply("I want to go home and I need to sleep")
        XCTAssertEqual(out, "I want to go home and I need to sleep")
    }

    func testFalseStartTwoSentencesEachTrimmedIndependently() {
        // The second sentence's repeated prefix happens to recur in lowercase
        // ("he said"), so the trimmed result keeps that literal casing.
        let out = rules().apply("I'd like to I'd like to go. He said he said no.")
        XCTAssertEqual(out, "I'd like to go. he said no.")
    }

    // MARK: - Clean speech: repeats

    func testCollapseImmediateRepeat() {
        XCTAssertEqual(rules().apply("the the weather is nice"), "the weather is nice")
    }

    func testCollapseTripleRepeat() {
        XCTAssertEqual(rules().apply("it it it works"), "it works")
    }

    func testCollapseRepeatIsCaseInsensitive() {
        XCTAssertEqual(rules().apply("The the weather is nice"), "The weather is nice")
    }

    // MARK: - Clean speech: fillers

    func testRemovesSimpleFillers() {
        XCTAssertEqual(rules().apply("uh so it works um just fine"), "so it works just fine")
    }

    func testRemovesStandaloneLike() {
        XCTAssertEqual(rules().apply("so like it was really fast"), "so it was really fast")
    }

    func testKeepsLikeAsVerbAfterContraction() {
        XCTAssertEqual(rules().apply("I'd like it to be ready"), "I'd like it to be ready")
    }

    func testKeepsLikeAsVerbAfterPronoun() {
        XCTAssertEqual(rules().apply("I like it a lot"), "I like it a lot")
    }

    // MARK: - Clean speech group off (verbatim)

    func testCleanSpeechGroupOffIsVerbatim() {
        let out = rules(config: RulesConfig(cleanSpeech: false)).apply("uh the the plan is uh solid")
        XCTAssertEqual(out, "uh the the plan is uh solid")
    }

    // MARK: - Contractions (off by default)

    func testContractionsOffByDefault() {
        XCTAssertEqual(rules().apply("I gotta go now"), "I gotta go now")
    }

    func testContractionsExpandGotta() {
        let out = rules(config: RulesConfig(contractions: true)).apply("I gotta go now")
        XCTAssertEqual(out, "I got to go now")
    }

    func testContractionsExpandWannaGonnaKinda() {
        let cfg = RulesConfig(contractions: true)
        XCTAssertEqual(rules(config: cfg).apply("I wanna leave"), "I want to leave")
        XCTAssertEqual(rules(config: cfg).apply("It's gonna rain"), "It's going to rain")
        XCTAssertEqual(rules(config: cfg).apply("It's kinda late"), "It's kind of late")
    }

    func testContractionsPreserveCapitalization() {
        let out = rules(config: RulesConfig(contractions: true)).apply("Gotta run")
        XCTAssertEqual(out, "Got to run")
    }

    // MARK: - Numbers

    // MARK: - Numbers: a lone number word is usually not a quantity

    func testLoneOneAsPronounStays() {
        XCTAssertEqual(rules().apply("a custom one"), "a custom one")
        XCTAssertEqual(rules().apply("the other one"), "the other one")
        XCTAssertEqual(rules().apply("this one"), "this one")
        XCTAssertEqual(rules().apply("I have one"), "I have one")
    }

    func testOneOfThemStays() {
        XCTAssertEqual(rules().apply("one of them"), "one of them")
        XCTAssertEqual(rules().apply("no one saw it"), "no one saw it")
        XCTAssertEqual(rules().apply("someone or anyone"), "someone or anyone")
    }

    func testIdiomaticOneStays() {
        XCTAssertEqual(rules().apply("one day I'm going to"), "one day I'm going to")
        XCTAssertEqual(rules().apply("one second"), "one second")
        XCTAssertEqual(rules().apply("chapter one"), "chapter one")
    }

    func testSingleNumberBeforeMeasureNounConverts() {
        XCTAssertEqual(rules().apply("wait two seconds"), "wait 2 seconds")
        XCTAssertEqual(rules().apply("two days"), "2 days")
        XCTAssertEqual(rules().apply("five minutes"), "5 minutes")
    }

    func testSingleNumberWithoutMeasureNounStays() {
        XCTAssertEqual(rules().apply("two of us"), "two of us")
        XCTAssertEqual(rules().apply("for two"), "for two")
        XCTAssertEqual(rules().apply("one or two"), "one or two")
    }

    func testChainsAndDecimalsStillConvert() {
        XCTAssertEqual(rules().apply("one hundred"), "100")
        XCTAssertEqual(rules().apply("one point five"), "1.5")
        XCTAssertEqual(rules().apply("one hundred dollars"), "$100")
    }

    func testIndexNounConverts() {
        XCTAssertEqual(rules().apply("version two"), "version 2")
        XCTAssertEqual(rules().apply("step one"), "step 1")
        XCTAssertEqual(rules().apply("page three"), "page 3")
    }

    func testTwoHundred() {
        XCTAssertEqual(rules().apply("I need two hundred units"), "I need 200 units")
    }

    func testTwelveThousand() {
        XCTAssertEqual(rules().apply("The budget is twelve thousand total"), "The budget is 12000 total")
    }

    func testDecimalPoint() {
        XCTAssertEqual(rules().apply("The version is three point five"), "The version is 3.5")
    }

    func testCompoundHundredsAndTens() {
        XCTAssertEqual(rules().apply("There are twenty three apples"), "There are 23 apples")
    }

    func testDoesNotTouchUnrelatedWords() {
        XCTAssertEqual(rules().apply("I have two dogs and three cats"), "I have 2 dogs and 3 cats")
    }

    // MARK: - Currency

    func testBucksAndEuros() {
        // The NOTES.md test sentence.
        let out = rules().apply("Two hundred bucks versus two hundred Euros")
        XCTAssertEqual(out, "$200 versus \u{20AC}200")
    }

    func testDollarsWord() {
        XCTAssertEqual(rules().apply("It costs twelve thousand dollars"), "It costs $12000")
    }

    func testPounds() {
        XCTAssertEqual(rules().apply("It costs ten pounds"), "It costs \u{00A3}10")
    }

    func testPercent() {
        XCTAssertEqual(rules().apply("fifty percent done"), "50% done")
    }

    func testDecimalPercent() {
        XCTAssertEqual(rules().apply("three point five percent growth"), "3.5% growth")
    }

    // MARK: - Spoken punctuation

    func testDashDashForce() {
        // The NOTES.md test sentence.
        XCTAssertEqual(rules().apply("dash dash force"), "--force")
    }

    func testDashDashGenericFlag() {
        XCTAssertEqual(rules().apply("run it with dash dash verbose"), "run it with --verbose")
    }

    func testColonBeforeNumber() {
        // The NOTES.md test sentence.
        XCTAssertEqual(rules().apply("localhost colon 3000"), "localhost:3000")
    }

    func testColonBeforeWordIsUntouched() {
        XCTAssertEqual(rules().apply("note colon this is important"), "note colon this is important")
    }

    func testNewLine() {
        XCTAssertEqual(rules().apply("first line new line second line"), "first line \n second line")
    }

    func testOpenAndCloseParen() {
        XCTAssertEqual(rules().apply("call it open paren x close paren"), "call it ( x )")
    }

    // MARK: - Dictionary (Replacer) integration

    func testDictionaryAliasReplacement() {
        // The NOTES.md test sentence: "type sense" with a dictionary entry Typesense.
        let vocab = [VocabTerm(text: "Typesense", aliases: ["type sense"])]
        let out = rules(vocabulary: vocab).apply("I used type sense for search")
        XCTAssertEqual(out, "I used Typesense for search")
    }

    func testDictionaryRunsBeforeSpokenPunctuation() {
        // A dictionary alias for "--force" wins outright, with no leftover space
        // the generic dash-dash rule would otherwise need to close.
        let vocab = [VocabTerm(text: "--force", aliases: ["dash dash force"])]
        let out = rules(vocabulary: vocab).apply("git push dash dash force")
        XCTAssertEqual(out, "git push --force")
    }

    // MARK: - allOff verbatim mode

    func testAllOffConfigIsVerbatimExceptDictionary() {
        let vocab = [VocabTerm(text: "Typesense", aliases: ["type sense"])]
        let out = rules(vocabulary: vocab, config: .allOff).apply("uh gotta use type sense for two hundred bucks")
        XCTAssertEqual(out, "uh gotta use Typesense for two hundred bucks")
    }

    // MARK: - Combined pipeline

    func testCombinedFalseStartFillerAndNumbers() {
        let out = rules().apply("uh I need I need two hundred dollars uh today")
        XCTAssertEqual(out, "I need $200 today")
    }

    // MARK: end punctuation

    func testEndPunctuationAppendsPeriod() {
        XCTAssertEqual(EndPunctuationRule.apply("Yeah it seems to be working better now"), "Yeah it seems to be working better now.")
    }

    func testEndPunctuationAppendsQuestionMark() {
        XCTAssertEqual(EndPunctuationRule.apply("Why is the build failing"), "Why is the build failing?")
    }

    func testEndPunctuationLeavesExistingMark() {
        XCTAssertEqual(EndPunctuationRule.apply("Done!"), "Done!")
        XCTAssertEqual(EndPunctuationRule.apply("First line\n"), "First line\n")
    }

    func testEndPunctuationLeavesSingleCodeToken() {
        XCTAssertEqual(EndPunctuationRule.apply("--force"), "--force")
        XCTAssertEqual(EndPunctuationRule.apply("package.json"), "package.json")
        XCTAssertEqual(EndPunctuationRule.apply("kubectl"), "kubectl.")
    }

    func testEndPunctuationInsideClosingQuote() {
        XCTAssertEqual(EndPunctuationRule.apply("He said \"ship it\""), "He said \"ship it.\"")
    }

    // MARK: hyphenated number words

    func testHyphenatedCompoundsConvert() {
        XCTAssertEqual(rules().apply("ninety-nine point nine percent"), "99.9%")
        XCTAssertEqual(rules().apply("twenty-five dollars"), "$25")
        XCTAssertEqual(rules().apply("it was ninety-nine percent correct"), "it was 99% correct")
    }
}

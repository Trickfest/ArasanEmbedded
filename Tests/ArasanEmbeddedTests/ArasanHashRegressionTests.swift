import CArasanEmbeddedTestSupport
import Testing

@Suite("Arasan Hash Regression")
struct ArasanHashRegressionTests {
    @Test
    func legalMateScoreHashConversionReachesPositiveMateBound() {
        let mate = AEMateScoreForTesting()

        #expect(AEHashScoreToHashValueForTesting(mate - 1, 2) == mate)
        #expect(AEHashScoreToHashValueForTesting(mate - 2, 3) == mate)
    }

    @Test
    func legalMateScoreHashConversionReachesNegativeMateBound() {
        let mate = AEMateScoreForTesting()

        #expect(AEHashScoreToHashValueForTesting((-mate) + 1, 2) == -mate)
        #expect(AEHashScoreToHashValueForTesting((-mate) + 2, 3) == -mate)
    }

    @Test
    func nonMateAndInvalidScoresArePreserved() {
        let mateRange = AEMateRangeForTesting()
        let invalid = AEInvalidScoreForTesting()

        #expect(AEHashScoreToHashValueForTesting(125, 4) == 125)
        #expect(AEHashScoreToHashValueForTesting(mateRange - 1, 4) == mateRange - 1)
        #expect(AEHashScoreToHashValueForTesting(-(mateRange - 1), 4) == -(mateRange - 1))
        #expect(AEHashScoreToHashValueForTesting(invalid, 4) == invalid)
    }
}

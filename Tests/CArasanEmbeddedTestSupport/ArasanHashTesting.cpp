#include "ArasanHashTesting.h"
#include "constant.h"
#include "hash.h"

int AEHashScoreToHashValueForTesting(int score, int ply) {
    return HashEntry::scoreToHashValue(static_cast<score_t>(score), ply);
}

int AEMateScoreForTesting(void) {
    return Constants::MATE;
}

int AEMateRangeForTesting(void) {
    return Constants::MATE_RANGE;
}

int AEInvalidScoreForTesting(void) {
    return Constants::INVALID_SCORE;
}

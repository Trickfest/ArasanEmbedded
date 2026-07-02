#ifndef ARASAN_HASH_TESTING_H
#define ARASAN_HASH_TESTING_H

#ifdef __cplusplus
extern "C" {
#endif

int AEHashScoreToHashValueForTesting(int score, int ply);
int AEMateScoreForTesting(void);
int AEMateRangeForTesting(void);
int AEInvalidScoreForTesting(void);

#ifdef __cplusplus
}
#endif

#endif

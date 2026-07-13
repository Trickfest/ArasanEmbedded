#ifndef ARASAN_BRIDGE_TESTING_H
#define ARASAN_BRIDGE_TESTING_H

#include <stdbool.h>

#ifdef __cplusplus
extern "C" {
#endif

bool AEOutputFlushPreservesLineForTesting(void);
bool AEConcurrentOutputPreservesSubmissionOrderForTesting(void);
bool AEStandardStreamsRestoreForTesting(void);
bool AEEmbeddedGlobalsAllocatedForTesting(void);
unsigned long long AECurrentHashBytesForTesting(void);
int AECurrentThreadCountForTesting(void);
bool AECurrentPositionLearningForTesting(void);

#ifdef __cplusplus
}
#endif

#endif

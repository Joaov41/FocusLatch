#ifndef MultitouchBridge_h
#define MultitouchBridge_h

#include <stdbool.h>

enum {
    MTGestureTypeThreeFingerTap = 1,
    MTGestureTypeThreeFingerPress = 2,
};

typedef void (*MTGestureCallback)(void *context, int gestureType);

bool MTBridgeStart(void *context, MTGestureCallback callback);
void MTBridgeStop(void);

#endif

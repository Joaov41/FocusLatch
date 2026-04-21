#include "MultitouchBridge.h"

#include <CoreFoundation/CoreFoundation.h>
#include <dispatch/dispatch.h>
#include <dlfcn.h>
#include <stdbool.h>
#include <stdlib.h>

typedef struct {
    float x;
    float y;
} MTPoint;

typedef struct {
    MTPoint position;
    MTPoint velocity;
} MTVector;

typedef struct {
    int frame;
    double timestamp;
    int identifier;
    int state;
    int unknown1;
    int unknown2;
    MTVector normalized;
    float size;
    int unknown3;
    float angle;
    float majorAxis;
    float minorAxis;
    MTVector absolute;
    int unknown4;
    int unknown5;
    float density;
} Finger;

typedef void *MTDeviceRef;
typedef int (*MTContactCallbackFunction)(MTDeviceRef device, Finger *data, int fingerCount, double timestamp, int frame);

typedef CFArrayRef (*MTDeviceCreateListFunction)(void);
typedef void (*MTRegisterContactFrameCallbackFunction)(MTDeviceRef device, MTContactCallbackFunction callback);
typedef void (*MTUnregisterContactFrameCallbackFunction)(MTDeviceRef device, MTContactCallbackFunction callback);
typedef void (*MTDeviceStartFunction)(MTDeviceRef device, int frame);
typedef void (*MTDeviceStopFunction)(MTDeviceRef device);

typedef struct {
    MTDeviceCreateListFunction createList;
    MTRegisterContactFrameCallbackFunction registerCallback;
    MTUnregisterContactFrameCallbackFunction unregisterCallback;
    MTDeviceStartFunction start;
    MTDeviceStopFunction stop;
} MultitouchAPI;

typedef struct {
    void *context;
    MTGestureCallback callback;
    int gestureType;
} CallbackPayload;

static const char *kMultitouchFrameworkPath = "/System/Library/PrivateFrameworks/MultitouchSupport.framework/MultitouchSupport";
static const double kTapDurationLimit = 0.30;
static const double kPressDurationThreshold = 0.35;
static const float kMovementThresholdSquared = 0.0100f;

static void *gFrameworkHandle = NULL;
static MultitouchAPI gAPI = {0};
static CFArrayRef gDevices = NULL;
static void *gContext = NULL;
static MTGestureCallback gGestureCallback = NULL;
static bool gGestureInProgress = false;
static bool gGestureMovedTooFar = false;
static bool gPressDelivered = false;
static bool gTapDelivered = false;
static double gGestureStartTimestamp = 0.0;
static MTPoint gGestureStartCentroid = {0.0f, 0.0f};

static MTPoint centroidForTouches(Finger *data, int fingerCount) {
    MTPoint centroid = {0.0f, 0.0f};

    if (fingerCount <= 0) {
        return centroid;
    }

    for (int index = 0; index < fingerCount; index += 1) {
        centroid.x += data[index].normalized.position.x;
        centroid.y += data[index].normalized.position.y;
    }

    centroid.x /= fingerCount;
    centroid.y /= fingerCount;
    return centroid;
}

static void resetGestureState(void) {
    gGestureInProgress = false;
    gGestureMovedTooFar = false;
    gPressDelivered = false;
    gTapDelivered = false;
    gGestureStartTimestamp = 0.0;
    gGestureStartCentroid = (MTPoint){0.0f, 0.0f};
}

static void deliverGestureOnMainThread(void *payloadPointer) {
    CallbackPayload *payload = (CallbackPayload *)payloadPointer;

    if (payload != NULL && payload->callback != NULL) {
        payload->callback(payload->context, payload->gestureType);
    }

    free(payload);
}

static void dispatchGesture(int gestureType) {
    if (gGestureCallback == NULL) {
        return;
    }

    CallbackPayload *payload = (CallbackPayload *)malloc(sizeof(CallbackPayload));
    if (payload == NULL) {
        return;
    }

    payload->context = gContext;
    payload->callback = gGestureCallback;
    payload->gestureType = gestureType;
    dispatch_async_f(dispatch_get_main_queue(), payload, deliverGestureOnMainThread);
}

static bool loadAPI(void) {
    if (gFrameworkHandle != NULL) {
        return true;
    }

    gFrameworkHandle = dlopen(kMultitouchFrameworkPath, RTLD_NOW);
    if (gFrameworkHandle == NULL) {
        return false;
    }

    gAPI.createList = (MTDeviceCreateListFunction)dlsym(gFrameworkHandle, "MTDeviceCreateList");
    gAPI.registerCallback = (MTRegisterContactFrameCallbackFunction)dlsym(gFrameworkHandle, "MTRegisterContactFrameCallback");
    gAPI.unregisterCallback = (MTUnregisterContactFrameCallbackFunction)dlsym(gFrameworkHandle, "MTUnregisterContactFrameCallback");
    gAPI.start = (MTDeviceStartFunction)dlsym(gFrameworkHandle, "MTDeviceStart");
    gAPI.stop = (MTDeviceStopFunction)dlsym(gFrameworkHandle, "MTDeviceStop");

    if (gAPI.createList == NULL || gAPI.registerCallback == NULL || gAPI.unregisterCallback == NULL ||
        gAPI.start == NULL || gAPI.stop == NULL) {
        dlclose(gFrameworkHandle);
        gFrameworkHandle = NULL;
        gAPI = (MultitouchAPI){0};
        return false;
    }

    return true;
}

static int contactFrameCallback(MTDeviceRef device, Finger *data, int fingerCount, double timestamp, int frame) {
    (void)device;
    (void)frame;

    if (fingerCount == 3) {
        MTPoint centroid = centroidForTouches(data, fingerCount);

        if (!gGestureInProgress) {
            gGestureInProgress = true;
            gGestureMovedTooFar = false;
            gPressDelivered = false;
            gTapDelivered = false;
            gGestureStartTimestamp = timestamp;
            gGestureStartCentroid = centroid;
            return 0;
        }

        float deltaX = centroid.x - gGestureStartCentroid.x;
        float deltaY = centroid.y - gGestureStartCentroid.y;
        float movementSquared = (deltaX * deltaX) + (deltaY * deltaY);

        if (movementSquared > kMovementThresholdSquared) {
            gGestureMovedTooFar = true;
        }

        if (!gPressDelivered &&
            !gGestureMovedTooFar &&
            (timestamp - gGestureStartTimestamp) >= kPressDurationThreshold) {
            dispatchGesture(MTGestureTypeThreeFingerPress);
            gPressDelivered = true;
        }

        return 0;
    }

    if (fingerCount > 3) {
        resetGestureState();
        return 0;
    }

    if (gGestureInProgress && fingerCount < 3) {
        if (!gTapDelivered &&
            !gPressDelivered &&
            !gGestureMovedTooFar &&
            (timestamp - gGestureStartTimestamp) <= kTapDurationLimit) {
            dispatchGesture(MTGestureTypeThreeFingerTap);
            gTapDelivered = true;
        }

        if (fingerCount == 0) {
            resetGestureState();
        }
    }

    return 0;
}

bool MTBridgeStart(void *context, MTGestureCallback callback) {
    MTBridgeStop();

    if (!loadAPI()) {
        return false;
    }

    gDevices = gAPI.createList();
    if (gDevices == NULL || CFArrayGetCount(gDevices) == 0) {
        if (gDevices != NULL) {
            CFRelease(gDevices);
            gDevices = NULL;
        }
        return false;
    }

    gContext = context;
    gGestureCallback = callback;
    resetGestureState();

    CFIndex count = CFArrayGetCount(gDevices);
    for (CFIndex index = 0; index < count; index += 1) {
        MTDeviceRef device = (MTDeviceRef)CFArrayGetValueAtIndex(gDevices, index);
        gAPI.registerCallback(device, contactFrameCallback);
        gAPI.start(device, 0);
    }

    return true;
}

void MTBridgeStop(void) {
    if (gDevices != NULL) {
        CFIndex count = CFArrayGetCount(gDevices);
        for (CFIndex index = 0; index < count; index += 1) {
            MTDeviceRef device = (MTDeviceRef)CFArrayGetValueAtIndex(gDevices, index);
            gAPI.unregisterCallback(device, contactFrameCallback);
            gAPI.stop(device);
        }

        CFRelease(gDevices);
        gDevices = NULL;
    }

    gContext = NULL;
    gGestureCallback = NULL;
    resetGestureState();
}

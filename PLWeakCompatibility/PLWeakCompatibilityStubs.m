//
//  PLWeakCompatibilityStubs.m
//  PLWeakCompatibility
//
//  Created by Michael Ash on 3/28/12.
//  Copyright (c) 2012 __MyCompanyName__. All rights reserved.
//

#import "PLWeakCompatibilityStubs.h"

#import <dlfcn.h>
#import <pthread.h>


// Runtime (or ARC compatibility) prototypes we use here.
__unsafe_unretained id objc_autorelease(__unsafe_unretained id obj);
__unsafe_unretained id objc_retain(__unsafe_unretained id obj);

// Primitive functions used to implement all weak stubs
static __unsafe_unretained id PLLoadWeakRetained(__unsafe_unretained id *location);
static void PLRegisterWeak(__unsafe_unretained id *location, __unsafe_unretained id obj);
static void PLUnregisterWeak(__unsafe_unretained id *location, __unsafe_unretained id obj);

// Convenience for falling through to the system implementation.
static BOOL fallthroughEnabled = YES;

#define NEXT(name, ...) do { \
        static dispatch_once_t fptrOnce; \
        static __typeof__(&name) fptr; \
        dispatch_once(&fptrOnce, ^{ fptr = dlsym(RTLD_NEXT, #name); });\
            if (fallthroughEnabled && fptr != NULL) \
                return fptr(__VA_ARGS__); \
        } while(0)

void PLWeakCompatibilitySetFallthroughEnabled(BOOL enabled) {
    fallthroughEnabled = enabled;
}

////////////////////
#pragma mark Stubs
////////////////////

__unsafe_unretained id objc_loadWeakRetained(__unsafe_unretained id *location) {
    NEXT(objc_loadWeakRetained, location);
    
    return PLLoadWeakRetained(location);
}

__unsafe_unretained id objc_initWeak(__unsafe_unretained id *addr, __unsafe_unretained id val) {
    NEXT(objc_initWeak, addr, val);
    *addr = NULL;
    return objc_storeWeak(addr, val);
}

void objc_destroyWeak(__unsafe_unretained id *addr) {
    NEXT(objc_destroyWeak, addr);
    objc_storeWeak(addr, NULL);
}

void objc_copyWeak(__unsafe_unretained id *to, __unsafe_unretained id *from) {
    NEXT(objc_copyWeak, to, from);
    objc_initWeak(to, objc_loadWeak(from));
}

void objc_moveWeak(__unsafe_unretained id *to, __unsafe_unretained id *from) {
    NEXT(objc_moveWeak, to, from);
    objc_copyWeak(to, from);
    objc_destroyWeak(from);
}

__unsafe_unretained id objc_loadWeak(__unsafe_unretained id *location) {
    NEXT(objc_loadWeak, location);
    return objc_autorelease(objc_loadWeakRetained(location));
}

__unsafe_unretained id objc_storeWeak(__unsafe_unretained id *location, __unsafe_unretained id obj) {
    NEXT(objc_storeWeak, location, obj);

    PLUnregisterWeak(location, obj);

    *location = obj;

    if (obj != nil)
        PLRegisterWeak(location, obj);

    return obj;
}


////////////////////
#pragma mark Internal Globals and Prototypes
////////////////////

// This mutex protects all shared state
static pthread_mutex_t gWeakMutex;

// A map from objects to CFMutableSets containing weak addresses
static CFMutableDictionaryRef gObjectToAddressesMap;

// Ensure everything is properly initialized
static void WeakInit(void);

// Make sure the object's class is properly swizzled to clear weak refs on deallocation
static void EnsureDeallocationTrigger(__unsafe_unretained id obj);


////////////////////
#pragma mark Primitive Functions
////////////////////

static __unsafe_unretained id PLLoadWeakRetained(__unsafe_unretained id *location) {
    WeakInit();

    __unsafe_unretained id obj;
    pthread_mutex_lock(&gWeakMutex); {
        obj = *location;
        objc_retain(obj);
    }
    pthread_mutex_unlock(&gWeakMutex);

    return obj;
}

static void PLRegisterWeak(__unsafe_unretained id *location, __unsafe_unretained id obj) {
    WeakInit();

    pthread_mutex_lock(&gWeakMutex); {
        const void *key = (__bridge const void *)obj;
        CFMutableSetRef addresses = (CFMutableSetRef)CFDictionaryGetValue(gObjectToAddressesMap, key);
        if (addresses == NULL) {
            addresses = CFSetCreateMutable(NULL, 0, NULL);
            CFDictionarySetValue(gObjectToAddressesMap, key, addresses);
            CFRelease(addresses);
        }

        CFSetAddValue(addresses, location);

        EnsureDeallocationTrigger(obj);
    } pthread_mutex_unlock(&gWeakMutex);
}

static void PLUnregisterWeak(__unsafe_unretained id *location, __unsafe_unretained id obj) {
    WeakInit();

    pthread_mutex_lock(&gWeakMutex); {
        CFMutableSetRef addresses = (CFMutableSetRef)CFDictionaryGetValue(gObjectToAddressesMap, (__bridge const void *)*location);
        if (addresses != NULL)
            CFSetRemoveValue(addresses, location);
    } pthread_mutex_unlock(&gWeakMutex);
}


////////////////////
#pragma mark Internal Functions
////////////////////

static void WeakInit(void) {
    static dispatch_once_t pred;
    dispatch_once(&pred, ^{
        pthread_mutex_init(&gWeakMutex, NULL);

        gObjectToAddressesMap = CFDictionaryCreateMutable(NULL, 0, NULL, &kCFTypeDictionaryValueCallBacks);
    });
}

static void EnsureDeallocationTrigger(__unsafe_unretained id obj) {

}
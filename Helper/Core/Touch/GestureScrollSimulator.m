//
// --------------------------------------------------------------------------
// GestureScrollSimulator.m
// Created for Mac Mouse Fix (https://github.com/noah-nuebling/mac-mouse-fix)
// Created by Noah Nuebling in 2020
// Licensed under the MMF License (https://github.com/noah-nuebling/mac-mouse-fix/blob/master/LICENSE)
// --------------------------------------------------------------------------
//

#import "GestureScrollSimulator.h"
#import <QuartzCore/QuartzCore.h>
#import <Cocoa/Cocoa.h>
#import "TouchSimulator.h"
#import "HelperUtility.h"
#import "SharedUtility.h"
#import "VectorSubPixelator.h"
#import "ModificationUtility.h"
#import "Mac_Mouse_Fix_Helper-Swift.h"
#import "WannabePrefixHeader.h"

/**
 This generates fliud scroll events containing gesture data similar to the Apple Trackpad or Apple Magic Mouse driver.
 The events that this generates don't exactly match the ones generated by the Apple Drivers. Most notably they don't contain any raw touch  information. But in most situations, they will work exactly like scrolling on an Apple Trackpad or Magic Mouse

Also see:
 - GestureScrollSimulatorOld.m - an older implementation which tried to emulate the Apple drivers more closely. See the notes in GestureScrollSimulatorOld.m for more info.
 - TouchExtractor-twoFingerSwipe.xcproj for the code we used to figure this out and more relevant notes.
 - Notes in other places I can't think of
 */


@implementation GestureScrollSimulator

#pragma mark - Vars and init

static VectorSubPixelator *_scrollLinePixelator;

static TouchAnimator *_momentumAnimator;

static dispatch_queue_t _momentumQueue;
/// ^ This class doesn't only act as an output module (aka event sender) but also as an output driver for momentumScroll events. For its role as a driver, it needs a dispatchQueue. Consider factoring the autoMomentumScroll stuff out of this class for clear separation.

+ (void)initialize
{
    if (self == [GestureScrollSimulator class]) {
        
        /// Init dispatch queue
        
        dispatch_queue_attr_t attr = dispatch_queue_attr_make_with_qos_class(DISPATCH_QUEUE_SERIAL, QOS_CLASS_USER_INTERACTIVE, -1);
        _momentumQueue = dispatch_queue_create("com.nuebling.mac-mouse-fix.gesture-scroll", attr);
        
        /// Init Pixelators
        
        _scrollLinePixelator = [VectorSubPixelator biasedPixelator]; /// I think biased is only beneficial on linePixelator. Too lazy to explain.
        
        /// Momentum scroll
        
        _momentumAnimator = [[TouchAnimator alloc] init];
        
    }
}

#pragma mark - Main interface

/**
 Post scroll events that behave as if they are coming from an Apple Trackpad or Magic Mouse.
 This function is a wrapper for `postGestureScrollEventWithGestureVector:scrollVector:scrollVectorPoint:phase:momentumPhase:`

 Scrolling will continue automatically but get slower over time after the function has been called with phase kIOHIDEventPhaseEnded. (Momentum scroll)
 
    - The initial speed of this "momentum phase" is based on the delta values of last time that this function is called with at least one non-zero delta and with phase kIOHIDEventPhaseBegan or kIOHIDEventPhaseChanged before it is called with phase kIOHIDEventPhaseEnded.
 
    - The reason behind this is that this is how real trackpad input seems to work. Some apps like Xcode will automatically keep scrolling if no events are sent after the event with phase kIOHIDEventPhaseEnded. And others, like Safari will not. This function wil automatically keep sending events after it has been called with kIOHIDEventPhaseEnded in order to make all apps react as consistently as possible.
 
 \note In order to minimize momentum scrolling,  send an event with a very small but non-zero scroll delta before calling the function with phase kIOHIDEventPhaseEnded, or call stopMomentumScroll()
 \note For more info on which delta values and which phases to use, see the documentation for `postGestureScrollEventWithGestureDeltaX:deltaY:phase:momentumPhase:scrollDeltaConversionFunction:scrollPointDeltaConversionFunction:`. In contrast to the aforementioned function, you shouldn't need to call this function with kIOHIDEventPhaseUndefined.
*/

+ (void)postGestureScrollEventWithDeltaX:(int64_t)dx deltaY:(int64_t)dy phase:(IOHIDEventPhaseBits)phase autoMomentumScroll:(BOOL)autoMomentumScroll invertedFromDevice:(BOOL)invertedFromDevice {
    
    /// This function doesn't dispatch to _queue. It should only be called if you're already on _queue. Otherwise there will be race conditions with the other functions that execute on _queue.
    /// `autoMomentumScroll` should always be true, except if you are going to post momentumScrolls manually using `+ postMomentumScrollEvent`
    
    /// Debug
    
    //    DDLogDebug(@"Request to post Gesture Scroll: (%f, %f), phase: %d", dx, dy, phase);
    
    /// Validate input
    
    if (phase != kIOHIDEventPhaseEnded && dx == 0.0 && dy == 0.0) {
        /// Maybe kIOHIDEventPhaseBegan events from the Trackpad driver can also contain zero-deltas? I don't think so by I'm not sure.
        /// Real trackpad driver seems to only produce zero deltas when phase is kIOHIDEventPhaseEnded.
        ///     - (And probably also if phase is kIOHIDEventPhaseCancelled or kIOHIDEventPhaseMayBegin, but we're not using those here - IIRC those are only produced when the user touches the trackpad but doesn't begin scrolling before lifting fingers off again)
        /// The main practical reason we're emulating this behavour of the trackpad driver because of this: There are certain apps (or views?) which create their own momentum scrolls and ignore the momentum scroll deltas contained in the momentum scroll events we send. E.g. Xcode or the Finder collection view. I think that these views ignore all zero-delta events when they calculate what the initial momentum scroll speed should be. (It's been months since I discovered that though, so maybe I'm rememvering wrong) We want to match these apps momentum scroll algortihm closely to provide a consisten experience. So we're not sending the zero-delta events either and ignoring them for the purposes of our momentum scroll calculation and everything else.
        
        DDLogWarn(@"Trying to post gesture scroll with zero deltas while phase is not kIOHIDEventPhaseEnded - ignoring");
        
        return;
    }
    
    
    /// Stop momentum scroll
    ///     Do it sync otherwise it will be stopped immediately after it's startet by this block
    [GestureScrollSimulator stopMomentumScroll_Unsafe];
    
    /// Timestamps and static vars

    static CFTimeInterval lastInputTime;
    static Vector lastScrollVec;
    
    CFTimeInterval now = CACurrentMediaTime();
    CFTimeInterval timeSinceLastInput;
    
    if (phase == kIOHIDEventPhaseBegan) {
        timeSinceLastInput = DBL_MAX; /// This means we can't say anything useful about the time since last input
    } else {
        timeSinceLastInput = now - lastInputTime;
    }
    
    /// Main
    
    if (phase == kIOHIDEventPhaseBegan) {
        
        /// Reset subpixelator
        [_scrollLinePixelator reset];
    }
    if (phase == kIOHIDEventPhaseBegan || phase == kIOHIDEventPhaseChanged) {
        
        /// Get vectors
        
        Vector vecScrollPoint = (Vector){ .x = dx, .y = dy };
        Vector vecScrollLine;
        Vector vecScrollLineInt;
        Vector vecGesture;
        getDeltaVectors(vecScrollPoint, _scrollLinePixelator, &vecScrollLine, &vecScrollLineInt, &vecGesture);
        
        /// Record last scroll point vec
        
        lastScrollVec = vecScrollPoint;
        
        /// Post events
        
        [GestureScrollSimulator postGestureScrollEventWithGestureVector:vecGesture
                                                       scrollVectorLine:vecScrollLine
                                                    scrollVectorLineInt:vecScrollLineInt
                                                      scrollVectorPoint:vecScrollPoint
                                                                  phase:phase
                                                          momentumPhase:kCGMomentumScrollPhaseNone
                                                     invertedFromDevice:invertedFromDevice];
        
        /// Debug
        //        DDLogInfo(@"timeSinceLast: %f scrollVec: %f %f speed: %f", timeSinceLastInput, vecScrollPoint.x, vecScrollPoint.y, vecScrollPoint.y / timeSinceLastInput);
        /// ^ We're trying to analyze what makes a sequence of (modifiedDrag) scrolls produce an absurly fast momentum Scroll in Xcode (Xcode has it's own momentumScroll algorirthm that doesn't just follow our smoothed algorithm)
        ///     I can't see a simple pattern. I don't get it.
        ///     I do see thought that the timeSinceLast fluctuates wildly. This might be part of the issue.
        ///         Solution idea: Feed the deltas from modifiedDrag into a display-synced coalescing loop. This coalescing loop will then call GestureScrollSimulator at most [refreshRate] times a second.
        
    } else if (phase == kIOHIDEventPhaseEnded) {
        
        /// Post `ended` event
        [GestureScrollSimulator postGestureScrollEventWithGestureVector:(Vector){}
                                                       scrollVectorLine:(Vector){}
                                                    scrollVectorLineInt:(Vector){}
                                                      scrollVectorPoint:(Vector){}
                                                                  phase:kIOHIDEventPhaseEnded
                                                          momentumPhase:0
                                                     invertedFromDevice:invertedFromDevice];
        
        if (autoMomentumScroll) {
        
            /// Get exitSpeed (aka initialSpeed for momentum Scroll)
            
            Vector exitVelocity = (Vector) {
                .x = lastScrollVec.x / timeSinceLastInput,
                .y = lastScrollVec.y / timeSinceLastInput
            };
            
            /// Get momentum scroll params
            ///     These params try to emulate the momentum scrolls of a real trackpad as closely as possible
            
            double stopSpeed = 1.0;
            double dragCoeff = 30.0;
            double dragExp = 0.7;
            
            /// Do start momentum scroll
            
            startMomentumScroll(timeSinceLastInput, exitVelocity, stopSpeed, dragCoeff, dragExp, invertedFromDevice);
        }
        
    } else {
        DDLogError(@"Trying to send GestureScroll with invalid IOHIDEventPhase: %d", phase);
        assert(false);
    }
    
    lastInputTime = now; /// Make sure you don't return early so this is always executed
}

#pragma mark - Direct momentum scroll interface

+ (void)postMomentumScrollDirectlyWithDeltaX:(double)dx
                                      deltaY:(double)dy
                               momentumPhase:(CGMomentumScrollPhase)momentumPhase
                          invertedFromDevice:(BOOL)invertedFromDevice {
    
    /// Reset subpixelator
    if (momentumPhase == kCGMomentumScrollPhaseBegin) {
        [_scrollLinePixelator reset];
    }
    
    /// Declare zero Vec
    Vector zeroVector = (Vector){0};
    
    /// Get deltaVectors
    Vector vecScrollPoint = (Vector){ .x = dx, .y = dy };
    Vector vecScrollLine;
    Vector vecScrollLineInt;
    getDeltaVectors(vecScrollPoint, _scrollLinePixelator, &vecScrollLine, &vecScrollLineInt, NULL);
    
    [GestureScrollSimulator postGestureScrollEventWithGestureVector:zeroVector
                                                   scrollVectorLine:vecScrollLine
                                                scrollVectorLineInt:vecScrollLineInt
                                                  scrollVectorPoint:vecScrollPoint
                                                              phase:kIOHIDEventPhaseUndefined
                                                      momentumPhase:momentumPhase
                                                 invertedFromDevice:invertedFromDevice];
}

#pragma mark - Auto momentum scroll

static void (^_momentumScrollCallback)(void);
+ (void (^)(void))getAfterStartingMomentumScrollCallback {
    /// Just wrote this getter for debugging.
    return _momentumScrollCallback;
}
+ (void)afterStartingMomentumScroll:(void (^ _Nullable)(void))callback {
    /// `callback` will be called after the last `kIOHIDEventPhaseEnd` event has been sent, leading momentum scroll to be started
    ///     If it's decided that momentumScroll shouldn't be started because the `kIOHIDEventPhaseEnd` event had a too low delta or some other reason, then `callback` will be called right away.
    ///     If momentum scroll *is* started, then `callback` will be called after the first momentumScroll event has been sent.
    ///
    ///     This is only used by `ModifiedDrag`.
    ///     It probably shouldn't be sued by other classes, because of its specific behaviour and because, other classes might override eachothers callbacks, which would lead to really bad issues in ModifiedDrag
    
    dispatch_async(_momentumQueue, ^{
        
        if (_momentumAnimator.isRunning && callback != NULL) {
            /// ^ `&& callback != NULL` is a hack to make ModifiedDragOutputTwoFingerSwipe work properly. I'm not sure what I'm doing.
            
            DDLogError(@"Trying to set momentumScroll start callback while it's running. This can lead to bad issues and you probably don't want to do it.");
            assert(false);
        }
        
        _momentumScrollCallback = callback;
    });
}

/// Stop momentum scroll

+ (void)suspendMomentumScroll {
    dispatch_sync(_momentumQueue, ^{
        [self stopMomentumScroll_Unsafe];
    });
}

+ (void)stopMomentumScroll {
    
    DDLogDebug(@"momentumScroll stop request. Caller: %@", [SharedUtility callerInfo]);
    
    dispatch_async(_momentumQueue, ^{
        [self stopMomentumScroll_Unsafe];
    });
}

+ (void)stopMomentumScroll_Unsafe {
    [_momentumAnimator cancel_forAutoMomentumScroll:YES];
}

/// Momentum scroll main

static void startMomentumScroll(double timeSinceLastInput, Vector exitVelocity, double stopSpeed, double dragCoefficient, double dragExponent, BOOL invertedFromDevice) {
    dispatch_sync(_momentumQueue, ^{
        startMomentumScroll_Unsafe(timeSinceLastInput, exitVelocity, stopSpeed, dragCoefficient, dragExponent, invertedFromDevice);
    });
}

static void startMomentumScroll_Unsafe(double timeSinceLastInput, Vector exitVelocity, double stopSpeed, double dragCoefficient, double dragExponent, BOOL invertedFromDevice) {
    
    /// Debug
    
    DDLogDebug(@"momentumScroll start request");
    
//    DDLogDebug(@"Exit velocity: %f, %f", exitVelocity.x, exitVelocity.y);
    
    /// Declare constants
    
    Vector zeroVector = (Vector){ .x = 0, .y = 0 };
    
    /// Stop immediately, if too much time has passed since last event (So if the mouse is stationary)
    if (GeneralConfig.mouseMovingMaxIntervalLarge < timeSinceLastInput
        || timeSinceLastInput == DBL_MAX) { /// This should never be true at this point, because it's only set to DBL_MAX when phase == kIOHIDEventPhaseBegan
        DDLogDebug(@"Not sending momentum scroll - timeSinceLastInput: %f", timeSinceLastInput);
        if (_momentumScrollCallback != NULL) _momentumScrollCallback();
        [GestureScrollSimulator stopMomentumScroll];
        return;
    }
    
    /// Notify other touch drivers

//    (void)[OutputCoordinator suspendTouchDriversFromDriver:kTouchDriverGestureScrollSimulator];
    
    /// Init animator
    
    [_momentumAnimator resetSubPixelator]; /// Shouldn't we use the `_Unsafe` version here?
    [_momentumAnimator linkToMainScreen];
    
    /// Start animator
    
    [_momentumAnimator startWithParams:^NSDictionary<NSString *,id> * _Nonnull(Vector valueLeft, BOOL isRunning, Curve * _Nullable curve, Vector currentSpeed) {
        
        NSMutableDictionary *p = [NSMutableDictionary dictionary];
        
        /// Reset subpixelators
        [_scrollLinePixelator reset];
        
        /// Get animator params
        
        /// Get initial velocity
        Vector initialVelocity = initalMomentumScrollVelocity_FromExitVelocity(exitVelocity);
        
        /// Get initial speed
        double initialSpeed = magnitudeOfVector(initialVelocity); /// Magnitude is always positive
        
        /// Stop momentumScroll immediately, if the initial Speed is too small
        if (initialSpeed <= stopSpeed) {
            DDLogDebug(@"Not starting momentum scroll - initialSpeed smaller stopSpeed: i: %f, s: %f", initialSpeed, stopSpeed);
            if (_momentumScrollCallback != NULL) _momentumScrollCallback();
            [GestureScrollSimulator stopMomentumScroll];
            p[@"doStart"] = @(NO);
            return p;
        }
        
        /// Get drag animation curve
        
        DragCurve *animationCurve = [[DragCurve alloc] initWithCoefficient:dragCoefficient
                                                                  exponent:dragExponent
                                                              initialSpeed:initialSpeed
                                                                 stopSpeed:stopSpeed];
        
        /// Get duration and distance for animation from DragCurve
        
        double duration = animationCurve.timeInterval.length;
        double distance = animationCurve.distanceInterval.length;
        
        /// Get distanceVec
        
        Vector distanceVec = scaledVector(unitVector(initialVelocity), distance);
        
        /// Return
        
        p[@"vector"] = nsValueFromVector(distanceVec);
        p[@"duration"] = @(duration);
        p[@"curve"] = animationCurve;
        
        return p;
        
    } integerCallback:^(Vector deltaVec, MFAnimationCallbackPhase animationPhase, MFMomentumHint subCurve) {
        
        /// Debug
        DDLogDebug(@"Momentum scrolling - delta: (%f, %f), animationPhase: %d", deltaVec.x, deltaVec.y, animationPhase);
        
        /// Get delta vectors
        Vector vecScrollLine;
        Vector vecScrollLineInt;
        getDeltaVectors(deltaVec, _scrollLinePixelator, &vecScrollLine, &vecScrollLineInt, NULL);
        
        /// Get momentumPhase from animationPhase
        
        CGMomentumScrollPhase momentumPhase;
        
        if (animationPhase == kMFAnimationCallbackPhaseStart) {
            momentumPhase = kCGMomentumScrollPhaseBegin;
        } else if (animationPhase == kMFAnimationCallbackPhaseContinue) {
            momentumPhase = kCGMomentumScrollPhaseContinue;
        } else if (animationPhase == kMFAnimationCallbackPhaseEnd) {
            momentumPhase = kCGMomentumScrollPhaseEnd;
        } else if (animationPhase == kMFAnimationCallbackPhaseCanceled) {
            momentumPhase = kCGMomentumScrollPhaseEnd;
        } else {
            assert(false);
        }
        
        /// Validate
        if (momentumPhase == kCGMomentumScrollPhaseEnd) {
            assert(isZeroVector(deltaVec));
        }
        
        /// Post event
        [GestureScrollSimulator postGestureScrollEventWithGestureVector:zeroVector
                                                       scrollVectorLine:vecScrollLine
                                                    scrollVectorLineInt:vecScrollLineInt
                                                      scrollVectorPoint:deltaVec
                                                                  phase:kIOHIDEventPhaseUndefined
                                                          momentumPhase:momentumPhase
                                                     invertedFromDevice:invertedFromDevice];
        /// Call momentumScrollStart callback
        if (animationPhase == kMFAnimationCallbackPhaseStart) {
            if (_momentumScrollCallback != NULL) _momentumScrollCallback();
        }

    }];
    
}

#pragma mark - Vectors

//static Vector scrollLineVector_FromScrollPointVector(Vector vec) {
//
//    return scaledVectorWithFunction(vec, ^double(double x) {
//        return x / _pixelsPerLine; /// See CGEventSource.pixelsPerLine - it's 10 by default
//    });
//}
//
//static Vector gestureVector_FromScrollPointVector(Vector vec) {
//
//    return scaledVectorWithFunction(vec, ^double(double x) {
////        return 1.35 * x; /// This makes swipe to mark unread in Apple Mail feel really nice
////        return 1.0 * x; /// This feels better for swiping between pages in Safari
////        return 1.15 * x; /// I think this is a nice compromise
////        return 1.0 * x; /// Even 1.15 feels to fast right now. Edit: But why? Swipeing between pages and marking as unread feel to hard to trigger with this.
//        return 1.67 * x; /// This makes click and drag to swipe between pages in Safari appropriately easy to trigger
//    });
//}

static Vector initalMomentumScrollVelocity_FromExitVelocity(Vector exitVelocity) {
    
    return scaledVectorWithFunction(exitVelocity, ^double(double x) {
//        return pow(fabs(x), 1.08) * sign(x);
        return x * 1;
    });
}

static void getDeltaVectors(Vector point, VectorSubPixelator *subPixelator, Vector *line, Vector *lineInt, Vector *gesture) {
    
    /// `point` and `subPixelator` are the input, all the other vectors are the output.
    /// You can pass NULL for `gesture` if you don't need it. (You don't need it for momentum scrolls)
    
    /// Guard `point` contains int
    assert(point.x == round(point.x) && point.y == round(point.y));
    
    /// Configure pixelator threshold
    
    /// Notes on pixelationThreshold:
    /// - pixelationThreshold will make it so the pixelator will only pixelate if `abs(inputDelta) < threshold`. Otherwise it will just return the input value.
    /// - Why do this? It's how the fixedPt line deltas in real trackpad events seem to work. In testing, I don't see a clear benefit to this over just always pixelating, but it's generally better to be as close as possible to the real events.
    ///
    /// - There are still lots of differences to the way real events look:
    ///     - Real trackpad events seem to use around 0.5 threshold for momentumScroll events, and around 0.3 for gesture scroll events. But then they also round up to values like 0.7 (we can only round to integers).
    ///     - The min output size that the Apple Trackpad pixelation produces is not 1 like in our case, but 0.6 or 0.7 (around double the threshold) and both the threshold and the min size are different depending on momentumScroll or gestureScrolls and depending on scrollDirection. I think most of this weirdness is due to sloppy programming in the Apple Trackpad driver though. I don't think it's useful to replicate all of this.
    /// - In testing (with iTerm), I thought it might actually be feeling WORSE than always pixelating. I felt like it made the end of a scroll feel too fast vs the start. This might be placebo but we're turning this off for now (by setting the threshold to `INFINITY`)
    
    [subPixelator setPixelationThreshold:/*1.0*/INFINITY];
    
    /// Generate line delta
    *line = scaledVector(point, 1.0/10); /// See CGEventSource.pixelsPerLine - it's 10 by default || Note 1/10 == 0 in C! (integer division)
    *line = [subPixelator intVectorWithDoubleVector:*line];
    
    /// Generate rounded line delta
    ///     I think this algorithm is exactly how the Apple Trackpad driver gets the rounded line deltas
    ///     However if we're subpixelating the normal line deltas, (so they are already rounded) this does nothing
    *lineInt = vectorByApplyingToEachDimension(*line, ^double(double val) {
        /// Round values between 0 and 1 up and all others down. (Vice-versa for negative values)
        ///     That's what the real trackpad values look like
        return fabs(val) <= 1.0 ? signedCeil(val) : signedFloor(val);
    });
    
    /// Generate gesture delta
    if (gesture != NULL) {
        *gesture = scaledVector(point, 1.67); /// 1.67 makes click and drag to swipe between pages in Safari appropriately easy to trigger
    }
    
    /// Debug
    
    DDLogDebug(@"\nHNGG Constructed deltas - point: %@ \t line: %@ \t lineInt: %@", vectorDescription(point), vectorDescription(*line), vectorDescription(*lineInt));
}


#pragma mark - Post CGEvents

+ (void)postGestureScrollEventWithGestureVector:(Vector)vecGesture
                               scrollVectorLine:(Vector)vecScrollLine
                            scrollVectorLineInt:(Vector)vecScrollLineInt
                              scrollVectorPoint:(Vector)vecScrollPoint
                                          phase:(IOHIDEventPhaseBits)phase
                                  momentumPhase:(CGMomentumScrollPhase)momentumPhase
                             invertedFromDevice:(BOOL)invertedFromDevice {

    /// Post scroll events that behave as if they are coming from an Apple Trackpad or Magic Mouse.
    /// This allows for swiping between pages in apps like Safari or Preview, and it also makes overscroll and inertial scrolling work.
    ///
    /// Notes on the 4 Vectors:
    /// - The gestureVector and scrollVectorLine are supposed to contain **floats**, the scrollVectorLineInt and scrollVectorPoint are expected to contain **int** values.
    ///
    /// Notes on phases:
    ///     1. kIOHIDEventPhaseMayBegin - First event. Deltas should be 0.
    ///     2. kIOHIDEventPhaseBegan - Second event. At least one of the two deltas should be non-0.
    ///     4. kIOHIDEventPhaseChanged - All events in between. At least one of the two deltas should be non-0.
    ///     5. kIOHIDEventPhaseEnded - Last event before momentum phase. Deltas should be 0.
    ///       - If you stop sending events at this point, scrolling will continue in certain apps like Xcode, but get slower with time until it stops. The initial speed and direction of this "automatic momentum phase" seems to be based on the last kIOHIDEventPhaseChanged event which contained at least one non-zero delta.
    ///       - To stop this from happening, either give the last kIOHIDEventPhaseChanged event very small deltas, or send an event with phase kIOHIDEventPhaseUndefined and momentumPhase kCGMomentumScrollPhaseEnd right after this one.
    ///     6. kIOHIDEventPhaseUndefined - Use this phase with non-0 momentumPhase values. (0 being kCGMomentumScrollPhaseNone)
    ///     7. What about kIOHIDEventPhaseCanceled? It seems to occur when you touch the trackpad (producing MayBegin events) and then lift your fingers off before scrolling. I guess the deltas are always gonna be 0 on that, too, but I'm not sure.
    
    
    /// Debug
    
    if (runningPreRelease()) {
        
        static double tsLast = 0;
        double ts = CACurrentMediaTime();
        double timeSinceLast = ts - tsLast;
        tsLast = ts;
        
        DDLogDebug(@"\nHNGG Posting: gesture: %@ \t line: %@, lineInt: %@, point: %@ \t phases: (%d, %d) \t timeSinceLast: %f \n", vectorDescription(vecGesture), vectorDescription(vecScrollLine), vectorDescription(vecScrollLineInt), vectorDescription(vecScrollPoint), phase, momentumPhase, timeSinceLast*1000);
    }
    
    /// Validate
    
    assert((phase == kIOHIDEventPhaseUndefined || momentumPhase == kCGMomentumScrollPhaseNone)); /// At least one of the phases has to be 0
    
    ///
    ///  Get stuff we need for both the type 22 and the type 29 event
    ///
    
    CGEventTimestamp eventTs = (CACurrentMediaTime() * NSEC_PER_SEC); /// Timestamp doesn't seem to make a difference anywhere. Could also set to 0
    
    ///
    /// Create type 22 event
    ///     (scroll event)
    ///
    
    CGEventRef e22 = CGEventCreate(NULL);
    
    /// Set static fields
    
    CGEventSetIntegerValueField(e22, 55, 22); /// 22 -> NSEventTypeScrollWheel // Setting field 55 is the same as using CGEventSetType(), I'm not sure if that has weird side-effects though, so I'd rather do it this way.
    CGEventSetIntegerValueField(e22, 88, 1); /// 88 -> kCGScrollWheelEventIsContinuous
    CGEventSetIntegerValueField(e22, 137, invertedFromDevice ? 1 : 0); /// I think this is NSEvent.directionInvertedFromDevice. Will flip direction of unread swiping in Mail
    
    /// Set dynamic fields
    
    /// Scroll deltas
    /// Notes:
    ///     - Fixed point deltas are set automatically by setting these deltas IIRC.
    ///         - Edit: Under Ventura Beta, the fixed point deltas are not automatically being set. Not sure if this was ever the case. So we're setting it manually now. Edit 2: Under a later Ventura Beta they ARE set automatically. The fixedPt delta (kCGScrollWheelEventFixedPtDeltaAxis1) is automatically set to the same value as the "normal" delta (kCGScrollWheelEventDeltaAxis1). But if we look at real trackpad values it's more complicated. So we're setting our own values to be more true to how the trackpad works
    ///
    ///     - Doing similar things in see Scroll.m line-scroll-generation
    
    CGEventSetIntegerValueField(e22, 11, vecScrollLineInt.y); /// 11 -> kCGScrollWheelEventDeltaAxis1
    CGEventSetIntegerValueField(e22, 96, vecScrollPoint.y); /// 96 -> kCGScrollWheelEventPointDeltaAxis1
    CGEventSetIntegerValueField(e22, 93, fixedScrollDelta(vecScrollLine.y)); /// 93 -> kCGScrollWheelEventFixedPtDeltaAxis1
    
    CGEventSetIntegerValueField(e22, 12, vecScrollLineInt.x); /// 12 -> kCGScrollWheelEventDeltaAxis2
    CGEventSetIntegerValueField(e22, 97, vecScrollPoint.x); /// 97 -> kCGScrollWheelEventPointDeltaAxis2
    CGEventSetIntegerValueField(e22, 94, fixedScrollDelta(vecScrollLine.x)); /// 94 -> kCGScrollWheelEventFixedPtDeltaAxis2
    
    /// Phase
    
    CGEventSetIntegerValueField(e22, 99, phase);
    CGEventSetIntegerValueField(e22, 123, momentumPhase);

    /// Debug
    
    DDLogDebug(@"\nHNGG Sent event: %@", scrollEventDescription(e22));
    
    /// Post t22s0 event
    ///     Posting after the t29s6 event because I thought that was close to real trackpad events. But in real trackpad events the order is always different it seems.
    ///     Wow, posting this after the t29s6 events removed the little stutter when swiping between pages, nice!
    
    CGEventSetTimestamp(e22, eventTs);
//    CGEventSetLocation(e22, eventLocation);
    CGEventPost(kCGSessionEventTap, e22); /// Needs to be kCGHIDEventTap instead of kCGSessionEventTap to work with Swish, but that will make the events feed back into our scroll event tap. That's not tooo bad, because we ignore continuous events anyways, still bad because CPU use and stuff.
    CFRelease(e22);
    
    if (phase != kIOHIDEventPhaseUndefined) {
       
        /// Create type 29 subtype 6 event
        ///     (gesture event)
        
        CGEventRef e29 = CGEventCreate(NULL);
        
        /// Set static fields
        
        CGEventSetIntegerValueField(e29, 55, 29); /// 29 -> NSEventTypeGesture // Setting field 55 is the same as using CGEventSetType()
        CGEventSetIntegerValueField(e29, 110, 6); /// 110 -> subtype // 6 -> kIOHIDEventTypeScroll
        
        /// Set dynamic fields
        
        /// Deltas
        double dxGesture = (double)vecGesture.x;
        double dyGesture = (double)vecGesture.y;
        if (dxGesture == 0) dxGesture = -0.0f; /// The original events only contain -0 but this probably doesn't make a difference.
        if (dyGesture == 0) dyGesture = -0.0f;
        CGEventSetDoubleValueField(e29, 116, dxGesture);
        CGEventSetDoubleValueField(e29, 119, dyGesture);
        
        /// Phase
        CGEventSetIntegerValueField(e29, 132, phase);
        
        /// Post t29s6 events
        CGEventSetTimestamp(e29, eventTs);
//        CGEventSetLocation(e29, eventLocation);
        CGEventPost(kCGSessionEventTap, e29);
        CFRelease(e29);
    }
    
}

@end

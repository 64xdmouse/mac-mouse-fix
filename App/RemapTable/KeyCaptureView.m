//
// --------------------------------------------------------------------------
// MFKeystrokeCaptureView.m
// Created for Mac Mouse Fix (https://github.com/noah-nuebling/mac-mouse-fix)
// Created by Noah Nuebling in 2021
// Licensed under MIT
// --------------------------------------------------------------------------
//

#import "KeyCaptureView.h"
#import "AppDelegate.h"
#import "UIStrings.h"
#import "KeyCaptureViewBackground.h"

@interface KeyCaptureView ()

@property IBOutlet KeyCaptureViewBackground *backgroundButton;

@end

@implementation KeyCaptureView {
    
    CaptureHandler _captureHandler;
    CancelHandler _cancelHandler;
    
    id _localEventMonitor;
    
    NSDictionary *_attributesFromIB;
}

#pragma mark - (Pseudo) Properties

- (void)setCoolString:(NSString *)string {
    
    NSAttributedString *attributedString = [[NSAttributedString alloc] initWithString:string attributes:_attributesFromIB];
    
    self.textStorage.attributedString = attributedString;
}

#pragma mark - Setup

- (void)setupWithCaptureHandler:(CaptureHandler)captureHandler
                   cancelHandler:(CancelHandler)cancelHandler {
    
#if DEBUG
    NSLog(@"Setting up keystroke capture view");
#endif
    
    
    self.delegate = self;
    _captureHandler = captureHandler;
    _cancelHandler = cancelHandler;
    
    dispatch_async(dispatch_get_main_queue(), ^{
        [AppDelegate.mainWindow makeFirstResponder:self];
    });
    // ^ This view is being drawn by the tableView. Using dispatch_async makes it execute after the tableView is done drawing preventing a crash
    
}

#pragma mark - Init and drawing

- (void)awakeFromNib {
    
    if (_attributesFromIB == nil) {
        _attributesFromIB = [self.attributedString attributesAtIndex:0 effectiveRange:nil];
    }
    self.focusRingType = NSFocusRingTypeNone;
}

- (void)drawRect:(NSRect)dirtyRect {
    [super drawRect:dirtyRect];

    BOOL focus = AppDelegate.mainWindow.firstResponder == self;

    if (true) {
        NSRect bounds = self.bounds;
        NSRect outerRect = NSMakeRect(bounds.origin.x - 2,
                                      bounds.origin.y - 2,
                                      bounds.size.width + 4,
                                      bounds.size.height + 4);

        NSRect innerRect = NSInsetRect(outerRect, 1, 1);

        NSBezierPath *clipPath = [NSBezierPath bezierPathWithRect:outerRect];
        [clipPath appendBezierPath:[NSBezierPath bezierPathWithRect:innerRect]];

        [clipPath setWindingRule:NSEvenOddWindingRule];
        [clipPath setClip];

        [[NSColor colorWithCalibratedWhite:0.6 alpha:1.0] setFill];
        [[NSBezierPath bezierPathWithRect:outerRect] fill];
    }
}

- (void)drawEmptyAppearance {
    
    self.coolString = @"Enter keyboard shortcut";
//    self.textColor = NSColor.placeholderTextColor;
    
    [self selectAll:nil];
}

#pragma mark FirstResponderStatus handlers

- (BOOL)becomeFirstResponder {

#if DEBUG
    NSLog(@"BECOME FIRST RESPONDER");
#endif
    
    BOOL superAccepts = [super becomeFirstResponder];
    
    if (superAccepts) {
        
        [self drawEmptyAppearance];
        
        _localEventMonitor = [NSEvent addLocalMonitorForEventsMatchingMask:(NSEventMaskKeyDown | NSEventMaskFlagsChanged) handler:^NSEvent * _Nullable(NSEvent * _Nonnull event) {
            CGEventRef e = event.CGEvent;
            
            CGKeyCode keyCode = CGEventGetIntegerValueField(e, kCGKeyboardEventKeycode);
            CGEventFlags flags = CGEventGetFlags(e);
            
            
            self.textColor = NSColor.labelColor;
            
            if (event.type == NSEventTypeKeyDown) {
//                [AppDelegate.mainWindow makeFirstResponder:nil];
                self->_captureHandler(keyCode, flags); // This should undraw this view
                
            } else {
                // User is playing around with modifier keys
                
                NSString *modString = [UIStrings getKeyboardModifierString:flags];
                if (modString.length > 0) {
                    self.coolString = modString;
                } else {
                    [self drawEmptyAppearance];
                }
                
                
            }
            
            return nil;
        }];
    }
    
    return superAccepts;
}
/// This is called too often and at weird times (always right before the `becomeFirstResponder` call)
- (BOOL)resignFirstResponder {

#if DEBUG
    NSLog(@"RESIGN FIRST RESPONDER");
#endif
    
    BOOL superResigns = [super resignFirstResponder];

    if (superResigns) {
        [NSEvent removeMonitor:_localEventMonitor];
        _cancelHandler();
    }
    return superResigns;
}

#pragma mark - Disable MouseDown and mouseover cursor

- (void)mouseDown:(NSEvent *)event {
    // Ignore
}
- (void)mouseMoved:(NSEvent *)event {
    [NSCursor.arrowCursor set]; // Prevent text insertion cursor from appearing on mouseover
}

@end

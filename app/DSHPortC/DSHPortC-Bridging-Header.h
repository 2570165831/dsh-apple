//
//  DSHPortC-Bridging-Header.h
//  DSHPortC
//
//  Objective-C the Swift side calls into.
//
//  Node does not need this. The single nodejs-mobile symbol NodeRunner.swift
//  uses is declared with `@_silgen_name("node_start")`, which avoids the
//  framework's headers entirely, and that is still the right call for Node.
//
//  The embedded Linux guest does need it. ISHGuest is Objective-C precisely
//  because the kernel it wraps is C: those headers are full of thread-local
//  globals, function-pointer hooks and double-NUL byte blobs, none of which
//  Swift can import directly. The Objective-C boundary is where that becomes a
//  normal object with methods.
//
//  ISHGuestChannel is here for the same reason plus one: it is built on the C
//  Network.framework API (nw_listener_t and friends), which Swift can import but
//  which would then need the whole request parser rewritten in Swift for no
//  benefit. Keeping the HTTP boundary next to the kernel calls it protects also
//  keeps the token handling in one place.
//
//  ISHImageService is Objective-C for a third reason: ImageIO and CoreGraphics
//  are C APIs with manual lifetime rules (every `CGImageSourceRef`,
//  `CGImageDestinationRef` and `CGImageRef` needs its own release, and several
//  getters follow the Get rule and must NOT be transferred to ARC). Getting that
//  wrong leaks or over-releases silently, so the C-shaped code stays in C. Its
//  only caller is Node, over the channel's image endpoints; the import here is
//  what lets a Swift caller — the step-5 image probe — exercise it directly.
//

#import <Foundation/Foundation.h>

#import "ISHGuest.h"
#import "ISHGuestChannel.h"
#import "ISHImageService.h"

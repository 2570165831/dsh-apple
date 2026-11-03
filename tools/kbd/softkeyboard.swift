// Toggle the simulator's software keyboard.
//
// WHY THIS EXISTS
// ---------------
// Step 11 has to measure what the keyboard does to the layout, and a simulator
// boots with "simulate hardware keyboard" on: focusing a field then shows no
// on-screen keyboard at all, so `visualViewport.height` never shrinks and the
// bug the task describes cannot even be reproduced.
//
// Xcode 27 ships no Simulator.app (removed, not relocated), so there is no
// Hardware Keyboard menu item; and `simctl` has no verb for it. The switch is
// still there in CoreSimulator, as `-[SimDevice setHardwareKeyboardEnabled:
// keyboardType:error:]`, which the DeviceHub app calls when that checkbox is
// toggled. This invokes the same selector on the same object, against this
// task's own device set, and nothing else.
//
// It writes no files and changes no preferences outside the running device.

import Foundation
import ObjectiveC

let coreSimulatorPath =
    "/Library/Developer/PrivateFrameworks/CoreSimulator.framework/Versions/A/CoreSimulator"

guard dlopen(coreSimulatorPath, RTLD_NOW) != nil else {
    FileHandle.standardError.write("cannot load CoreSimulator\n".data(using: .utf8)!)
    exit(2)
}

func usage() -> Never {
    FileHandle.standardError.write(
        "usage: softkeyboard <device-set-path> <udid> <soft|hard>\n".data(using: .utf8)!)
    exit(2)
}

let args = CommandLine.arguments
guard args.count == 4 else { usage() }
let setPath = args[1]
let udid = args[2]
// The argument names the keyboard a person wants to SEE, not the CoreSimulator
// flag, because the flag is inverted and naming it after the flag is how the
// first version turned the software keyboard off while printing "off".
//   soft  -> hardwareKeyboardEnabled = false  (the on-screen keyboard appears)
//   hard  -> hardwareKeyboardEnabled = true   (no on-screen keyboard)
guard let wantSoftware = ["soft", "hard"].firstIndex(of: args[3]).map({ $0 == 0 }) else { usage() }

final class ErrorBox: NSObject {
    var message: String?
}

// SimServiceContext + deviceSetWithPath:error:
guard let contextClass = NSClassFromString("SimServiceContext") as? NSObject.Type else {
    FileHandle.standardError.write("no SimServiceContext\n".data(using: .utf8)!)
    exit(3)
}
let initSelector = NSSelectorFromString("initWithDeveloperDir:connectionType:error:")
guard let allocated = contextClass.perform(NSSelectorFromString("alloc"))?.takeUnretainedValue() else {
    exit(3)
}
typealias InitFn = @convention(c) (AnyObject, Selector, NSString, Int, UnsafeMutablePointer<AnyObject?>?) -> AnyObject?
let initFn = unsafeBitCast(class_getMethodImplementation(contextClass, initSelector), to: InitFn.self)
var error: AnyObject?
let developerDir = "/Applications/Xcode.app/Contents/Developer" as NSString
guard let context = initFn(allocated, initSelector, developerDir, 0, &error) else {
    FileHandle.standardError.write("context init failed: \(String(describing: error))\n".data(using: .utf8)!)
    exit(3)
}

// Connect before asking for a set. Without this the context is missing its
// connection to CoreSimulatorService, and `devices` answers an empty array for a
// set that `simctl --set ... list` lists two devices in. Measured: the probe
// that called `connectWithError:` first saw both devices; the one that did not
// saw none.
let connectSelector = NSSelectorFromString("connectWithError:")
typealias ConnectFn = @convention(c) (AnyObject, Selector, UnsafeMutablePointer<AnyObject?>?) -> Bool
var connectError: AnyObject?
let connected = unsafeBitCast(class_getMethodImplementation(type(of: context), connectSelector),
                              to: ConnectFn.self)(context, connectSelector, &connectError)
guard connected else {
    FileHandle.standardError.write("connect failed: \(String(describing: connectError))\n".data(using: .utf8)!)
    exit(3)
}

let setSelector = NSSelectorFromString("deviceSetWithPath:error:")
typealias SetFn = @convention(c) (AnyObject, Selector, NSString, UnsafeMutablePointer<AnyObject?>?) -> AnyObject?
let setFn = unsafeBitCast(class_getMethodImplementation(type(of: context), setSelector), to: SetFn.self)
var setError: AnyObject?
guard let deviceSet = setFn(context, setSelector, setPath as NSString, &setError) else {
    FileHandle.standardError.write("deviceSet failed: \(String(describing: setError))\n".data(using: .utf8)!)
    exit(3)
}

// `devicesByUDID` answers an empty dictionary for a set whose plist has just
// been loaded; the `devices` array answers two. Measured, not assumed — the
// first version of this tool read the dictionary and reported "no device" for a
// device `simctl --set` listed a second earlier.
let devicesSelector = NSSelectorFromString("devices")
typealias ArrayFn = @convention(c) (AnyObject, Selector) -> NSArray?
let arrayFn = unsafeBitCast(class_getMethodImplementation(type(of: deviceSet), devicesSelector),
                            to: ArrayFn.self)
// The set populates asynchronously after `deviceSetWithPath:` returns: polled
// immediately it answers zero devices for a set `simctl` had just listed.
var all: NSArray = []
// CoreSimulatorService throttles a second client while `simctl` holds a
// connection ("Retrying in 9.9s"), so a four-second poll can legitimately see an
// empty set. Poll for half a minute instead of concluding the device is gone.
for _ in 0..<150 {
    all = arrayFn(deviceSet, devicesSelector) ?? []
    if all.count > 0 { break }
    Thread.sleep(forTimeInterval: 0.2)
}
// `UDID` is an NSUUID, not a string. Comparing it as a String silently matched
// nothing and produced "no device" for a device that was right there — the same
// shape of bug as the `index($0, ...)` indent mistake in scripts/device.sh.
var found: AnyObject?
for candidate in all {
    let object = candidate as AnyObject
    let candidateUDID = (object.value(forKey: "UDID") as? UUID)?.uuidString.uppercased()
        ?? (object.value(forKey: "UDID") as? NSUUID)?.uuidString.uppercased()
    if candidateUDID == udid.uppercased() {
        found = object
        break
    }
}
guard let device = found else {
    FileHandle.standardError.write("no device \(udid) in \(setPath)\n".data(using: .utf8)!)
    exit(4)
}

// -[SimDevice setHardwareKeyboardEnabled:keyboardType:error:]  B16@0:8B16C20^@24
// keyboardType 0 is the touch (software) keyboard on iPhone/iPad.
let keyboardSelector = NSSelectorFromString("setHardwareKeyboardEnabled:keyboardType:error:")
guard class_getInstanceMethod(type(of: device), keyboardSelector) != nil else {
    FileHandle.standardError.write("no setHardwareKeyboardEnabled on SimDevice\n".data(using: .utf8)!)
    exit(5)
}
typealias KeyboardFn = @convention(c) (AnyObject, Selector, Bool, UInt8, UnsafeMutablePointer<AnyObject?>?) -> Bool
let keyboardFn = unsafeBitCast(class_getMethodImplementation(type(of: device), keyboardSelector), to: KeyboardFn.self)
var kbError: AnyObject?
let ok = keyboardFn(device, keyboardSelector, !wantSoftware, 0, &kbError)
if !ok {
    FileHandle.standardError.write("setHardwareKeyboardEnabled failed: \(String(describing: kbError))\n".data(using: .utf8)!)
    exit(6)
}
print("keyboard=\(wantSoftware ? "soft" : "hard") hardwareKeyboardSimulated=\(!wantSoftware) udid=\(udid)")

//
//  ISHGuestChannel.m
//  DSHPortC
//
//  A very small HTTP/1.1 server over Network.framework, bound to loopback, that
//  exposes the guest as three endpoints:
//
//    POST /v1/exec      run a command, stream its output as NDJSON
//    POST /v1/resolve   stat + access a guest path
//    GET  /v1/health    liveness and the workspace mapping
//
//  and, since step 5, two more that do not touch the guest at all:
//
//    POST /v1/image/probe    header facts, optionally proven by one decode
//    POST /v1/image/encode   decode → orient → 8-bit sRGB → fit → re-encode
//
//  Those two are the platform's replacement for `sharp`, which cannot be loaded
//  on iOS. They live here rather than on a second listener because the security
//  posture this server already implements (loopback binding, per-launch bearer
//  token, Host check against DNS rebinding, one request per connection) is
//  exactly what a decoder handed arbitrary bytes needs, and a second copy of it
//  would be a second place to get it wrong.
//
//  Deliberately not a general-purpose server. It speaks exactly the subset of
//  HTTP/1.1 that Node's `fetch` polyfill emits (Content-Length bodies, one
//  request per connection, `Connection: close`), and it answers anything else
//  with 400/405/415 rather than guessing. A smaller surface is the point: this
//  is the trust boundary between two halves of the same process, and every
//  request that reaches it can start a process in the guest.
//
//  The response to /v1/exec is `Transfer-Encoding: chunked` with one JSON object
//  per chunk. Output is base64 in the JSON so that (a) arbitrary bytes survive,
//  and (b) a multi-byte UTF-8 character split across two guest writes is not
//  corrupted at this layer. The incremental decoder lives on the Node side,
//  which is where step 5's provider needs it anyway.
//

#import "ISHGuestChannel.h"
#import "ISHGuest.h"
#import "ISHImageService.h"

#import <Network/Network.h>
// `os_unfair_lock` for the fault-injection counters; see the note on
// `_injectionLock` for why the channel's own queue cannot be used.
#import <os/lock.h>
#include <arpa/inet.h>
#include <string.h>

static NSString *const kChannelLogPrefix = @"dshportc.channel";

NSString *const ISHGuestChannelPathImageProbe = @"/v1/image/probe";
NSString *const ISHGuestChannelPathImageEncode = @"/v1/image/encode";

/// How many ports to try before giving up. Small on purpose: a machine that
/// cannot find a free loopback port in eight tries has something else wrong
/// with it, and spinning longer just delays the error message.
static const NSInteger kMaxPortAttempts = 8;

/// A single request is bounded. The largest thing Node sends here is a command
/// line plus optional stdin; 16 MiB is far past that and still small enough that
/// a hostile or buggy client cannot exhaust the app's memory.
static const NSUInteger kMaxRequestBytes = 16u * 1024 * 1024;

/// The bound for the two image endpoints, and ONLY for them.
///
/// A 20 MiB image (DSH's own `maxImageBytes` default) is about 27 MiB once
/// base64-encoded inside a JSON body, so 16 MiB would refuse the largest image
/// DSH is configured to accept. 48 MiB leaves room for that plus the JSON
/// envelope; past it the request is refused with 413 instead of being buffered.
/// Kept as a separate constant so `exec` keeps the tighter bound it was
/// designed with — the image path never starts a process.
static const NSUInteger kMaxImageRequestBytes = 48u * 1024 * 1024;

/// How long a connection may sit without completing its headers.
static const NSTimeInterval kRequestTimeout = 30.0;

/// Fault injection for the "provider failure is visible" acceptance criterion.
/// Guarded by a dedicated lock, not the channel queue: handler bodies run ON
/// the channel queue, so guarding them with it would self-deadlock.
@interface ISHGuestChannel ()
@property (nonatomic) NSUInteger injectedExecFailures;
@property (nonatomic, copy, nullable) NSString *injectedExecFailureMessage;
@end

#pragma mark - one connection

@interface DSHChannelConnection : NSObject
@property (nonatomic, strong) nw_connection_t connection;
@property (nonatomic, strong) NSMutableData *input;
@property (nonatomic) BOOL headersParsed;
@property (nonatomic) BOOL closed;
/// Serializes sends: NWConnection allows overlapping sends but the ordering of
/// chunked bodies must not be left to chance.
@property (nonatomic, strong) dispatch_queue_t sendQueue;
@end

@implementation DSHChannelConnection
- (instancetype)init {
    if (self = [super init]) {
        _input = [NSMutableData data];
        _sendQueue = dispatch_queue_create("dshportc.channel.send", DISPATCH_QUEUE_SERIAL);
    }
    return self;
}
@end

#pragma mark - channel

@implementation ISHGuestChannel {
    nw_listener_t _listener;
    dispatch_queue_t _queue;
    /// Serialises the fault-injection counters. A dedicated lock rather than
    /// `_queue` because handler bodies already run on `_queue`.
    os_unfair_lock _injectionLock;
    /// Serialises `_activeExecs`. Same reason: `/v1/cancel` reads it from a
    /// handler that already owns `_queue`.
    os_unfair_lock _activeExecsLock;
    NSInteger _port;
    NSString *_token;
    NSMutableArray<DSHChannelConnection *> *_connections;
    /// Executions started by this server, so a shutdown can cancel them.
    NSMutableSet<NSString *> *_activeExecs;
}

+ (ISHGuestChannel *)shared {
    static ISHGuestChannel *shared;
    static dispatch_once_t once;
    dispatch_once(&once, ^{ shared = [[ISHGuestChannel alloc] init]; });
    return shared;
}

- (instancetype)init {
    if (self = [super init]) {
        _queue = dispatch_queue_create("dshportc.channel", DISPATCH_QUEUE_SERIAL);
        _injectionLock = OS_UNFAIR_LOCK_INIT;
        _activeExecsLock = OS_UNFAIR_LOCK_INIT;
        _connections = [NSMutableArray array];
        _activeExecs = [NSMutableSet set];
        _state = ISHGuestChannelStateIdle;
        _token = [ISHGuestChannel makeToken];
    }
    return self;
}

/// 32 bytes from the system CSPRNG, hex-encoded.
///
/// `arc4random_buf` is the platform CSPRNG and cannot fail; `SecRandomCopyBytes`
/// would be the other correct choice, but this avoids pulling Security.framework
/// into the app for one call. Hex rather than base64 so the value can be put in
/// a header, an environment variable, and a `grep` without escaping questions.
+ (NSString *)makeToken {
    uint8_t bytes[32];
    arc4random_buf(bytes, sizeof(bytes));
    NSMutableString *hex = [NSMutableString stringWithCapacity:64];
    for (size_t i = 0; i < sizeof(bytes); i++) {
        [hex appendFormat:@"%02x", bytes[i]];
    }
    return hex;
}

- (NSString *)redact:(NSString *)text {
    if (text.length == 0) return text ?: @"";
    NSString *token = _token;
    if (token.length == 0) return text;
    return [text stringByReplacingOccurrencesOfString:token withString:@"<redacted>"];
}

#pragma mark start

- (void)startWithCompletion:(void (^)(NSError *_Nullable))completion {
    dispatch_async(_queue, ^{
        if (self->_state == ISHGuestChannelStateListening) {
            dispatch_async(dispatch_get_main_queue(), ^{ if (completion) completion(nil); });
            return;
        }
        [self startOnQueueWithCompletion:completion];
    });
}

/// A port the caller would like to use, from `DSH_GUEST_CHANNEL_PREFERRED_PORT`.
///
/// Only an acceptance test sets this. In normal operation the port is 0 and the
/// system picks. The test uses it to prove the retry path: it occupies the
/// preferred port, then checks that this server came up somewhere else rather
/// than failing.
- (NSInteger)preferredPort {
    NSString *raw = NSProcessInfo.processInfo.environment[@"DSH_GUEST_CHANNEL_PREFERRED_PORT"];
    if (raw.length == 0) return 0;
    NSInteger value = raw.integerValue;
    return (value > 0 && value < 65536) ? value : 0;
}

- (void)startOnQueueWithCompletion:(void (^)(NSError *_Nullable))completion {
    _state = ISHGuestChannelStateStarting;

    NSInteger preferred = [self preferredPort];
    NSInteger first = preferred > 0 ? preferred : 0;
    [self attemptPort:first attempt:0 preferred:preferred completion:completion];
}

- (void)attemptPort:(NSInteger)port
            attempt:(NSInteger)attempt
          preferred:(NSInteger)preferred
         completion:(void (^)(NSError *_Nullable))completion {
    if (attempt >= kMaxPortAttempts) {
        _state = ISHGuestChannelStateFailed;
        _lastError = [NSString stringWithFormat:
            @"no free loopback port after %ld attempts", (long) kMaxPortAttempts];
        NSLog(@"%@: %@", kChannelLogPrefix, _lastError);
        dispatch_async(dispatch_get_main_queue(), ^{
            if (completion) completion([NSError errorWithDomain:@"dshportc.channel" code:1
                                                       userInfo:@{NSLocalizedDescriptionKey: self->_lastError}]);
        });
        return;
    }

    nw_parameters_t parameters = nw_parameters_create_secure_tcp(
        NW_PARAMETERS_DISABLE_PROTOCOL,   // no TLS: this is loopback, in-process
        NW_PARAMETERS_DEFAULT_CONFIGURATION);
    // Bind to loopback only. NWListener would otherwise listen on every
    // interface, including the Wi-Fi one, which on a phone means anyone on the
    // same network could talk to a server that starts guest processes.
    nw_endpoint_t local = nw_endpoint_create_host("127.0.0.1", port == 0 ? "0" : [[NSString stringWithFormat:@"%ld", (long) port] UTF8String]);
    nw_parameters_set_local_endpoint(parameters, local);
    // One request per connection: the client sends `Connection: close`, and the
    // server closes after each response, so keep-alive is never negotiated.

    nw_listener_t listener = nw_listener_create(parameters);
    if (listener == NULL) {
        _state = ISHGuestChannelStateFailed;
        _lastError = @"nw_listener_create returned NULL";
        dispatch_async(dispatch_get_main_queue(), ^{
            if (completion) completion([NSError errorWithDomain:@"dshportc.channel" code:2
                                                       userInfo:@{NSLocalizedDescriptionKey: self->_lastError}]);
        });
        return;
    }

    __block BOOL settled = NO;
    __weak ISHGuestChannel *weakSelf = self;

    // The listener needs a dispatch queue before any handler can fire. Without
    // this the state handler is silently never invoked — the listener exists, the
    // port is not bound, and the failure looks like "the channel just hangs".
    // Measured: the first acceptance run sat at `phase: starting` forever.
    nw_listener_set_queue(listener, _queue);

    nw_listener_set_state_changed_handler(listener, ^(nw_listener_state_t state, nw_error_t error) {
        ISHGuestChannel *strongSelf = weakSelf;
        if (strongSelf == nil) return;
        if (settled) return;

        switch (state) {
            case nw_listener_state_ready: {
                settled = YES;
                uint16_t boundPort = nw_listener_get_port(listener);
                strongSelf->_port = (NSInteger) boundPort;
                strongSelf->_listener = listener;
                strongSelf->_state = ISHGuestChannelStateListening;
                strongSelf->_lastError = nil;
                NSLog(@"%@: listening on 127.0.0.1:%ld (attempt %ld%s)",
                      kChannelLogPrefix, (long) boundPort, (long) attempt,
                      preferred > 0 ? ", preferred port was requested" : "");
                dispatch_async(dispatch_get_main_queue(), ^{ if (completion) completion(nil); });
                break;
            }
            case nw_listener_state_failed: {
                settled = YES;
                int errorCode = error != NULL ? nw_error_get_error_code(error) : 0;
                NSLog(@"%@: bind attempt %ld on port %ld failed (code %d)",
                      kChannelLogPrefix, (long) attempt, (long) port, errorCode);
                nw_listener_cancel(listener);
                // A taken port is the expected reason to be here. Advance and
                // retry; the caller sees only the final outcome.
                NSInteger nextPort = 0;
                if (preferred > 0) {
                    nextPort = preferred + attempt + 1;
                    if (nextPort >= 65536) nextPort = 0;
                }
                [strongSelf attemptPort:nextPort
                                attempt:attempt + 1
                              preferred:preferred
                             completion:completion];
                break;
            }
            case nw_listener_state_cancelled: {
                if (!settled) {
                    settled = YES;
                    [strongSelf attemptPort:0 attempt:attempt + 1
                                  preferred:preferred completion:completion];
                }
                break;
            }
            default:
                break;
        }
    });

    nw_listener_set_new_connection_handler(listener, ^(nw_connection_t connection) {
        ISHGuestChannel *strongSelf = weakSelf;
        if (strongSelf == nil) { nw_connection_cancel(connection); return; }
        [strongSelf acceptConnection:connection];
    });

    nw_listener_start(listener);
}

#pragma mark request handling

- (void)acceptConnection:(nw_connection_t)connection {
    DSHChannelConnection *context = [[DSHChannelConnection alloc] init];
    context.connection = connection;
    dispatch_async(_queue, ^{ [self->_connections addObject:context]; });

    nw_connection_set_queue(connection, _queue);
    __weak ISHGuestChannel *weakSelf = self;

    nw_connection_set_state_changed_handler(connection, ^(nw_connection_state_t state, nw_error_t error) {
        if (state == nw_connection_state_failed || state == nw_connection_state_cancelled) {
            context.closed = YES;
            ISHGuestChannel *strongSelf = weakSelf;
            if (strongSelf != nil) {
                dispatch_async(strongSelf->_queue, ^{ [strongSelf->_connections removeObject:context]; });
            }
        }
    });

    // Headers must arrive promptly; a client that connects and says nothing is
    // holding a slot for no reason.
    dispatch_after(dispatch_time(DISPATCH_TIME_NOW, (int64_t)(kRequestTimeout * NSEC_PER_SEC)), _queue, ^{
        if (!context.headersParsed && !context.closed) {
            [self closeConnection:context];
        }
    });

    [self receiveOnConnection:context];
    nw_connection_start(connection);
}

- (void)receiveOnConnection:(DSHChannelConnection *)context {
    __weak ISHGuestChannel *weakSelf = self;
    nw_connection_receive(context.connection, 1, 65536,
                          ^(dispatch_data_t data, dispatch_data_t contextData,
                            bool isComplete, nw_error_t error) {
        ISHGuestChannel *strongSelf = weakSelf;
        if (strongSelf == nil) return;
        if (data != NULL) {
            dispatch_data_apply(data, ^bool(dispatch_data_t region, size_t offset, const void *buffer, size_t size) {
                [context.input appendBytes:buffer length:size];
                return true;
            });
        }

        if (context.input.length > kMaxRequestBytes) {
            [strongSelf respondAndClose:context status:413 message:@"request too large" body:nil];
            return;
        }

        if (!context.headersParsed) {
            NSRange terminator = [context.input rangeOfData:[@"\r\n\r\n" dataUsingEncoding:NSUTF8StringEncoding]
                                                    options:0
                                                      range:NSMakeRange(0, context.input.length)];
            if (terminator.location == NSNotFound) {
                if (isComplete || error != NULL) [strongSelf closeConnection:context];
                else [strongSelf receiveOnConnection:context];
                return;
            }
            context.headersParsed = YES;
            [strongSelf handleParsedHeadersFor:context headerLength:NSMaxRange(terminator)];
            return;
        }

        // Body still being read; the handler above decides when it has enough.
        if (isComplete || error != NULL) {
            [strongSelf closeConnection:context];
        }
    });
}

- (void)handleParsedHeadersFor:(DSHChannelConnection *)context headerLength:(NSUInteger)headerLength {
    NSData *headerData = [context.input subdataWithRange:NSMakeRange(0, headerLength)];
    NSString *headerText = [[NSString alloc] initWithData:headerData encoding:NSISOLatin1StringEncoding];
    if (headerText == nil) {
        [self respondAndClose:context status:400 message:@"unreadable headers" body:nil];
        return;
    }

    NSArray<NSString *> *lines = [headerText componentsSeparatedByString:@"\r\n"];
    if (lines.count == 0) {
        [self respondAndClose:context status:400 message:@"empty request" body:nil];
        return;
    }
    NSArray<NSString *> *requestParts = [lines[0] componentsSeparatedByString:@" "];
    if (requestParts.count < 3) {
        [self respondAndClose:context status:400 message:@"malformed request line" body:nil];
        return;
    }
    NSString *method = requestParts[0];
    NSString *target = requestParts[1];

    NSMutableDictionary<NSString *, NSString *> *headers = [NSMutableDictionary dictionary];
    for (NSUInteger i = 1; i < lines.count; i++) {
        NSString *line = lines[i];
        NSRange colon = [line rangeOfString:@":"];
        if (colon.location == NSNotFound || colon.location == 0) continue;
        NSString *name = [[line substringToIndex:colon.location] lowercaseString];
        NSString *value = [[line substringFromIndex:colon.location + 1]
                           stringByTrimmingCharactersInSet:[NSCharacterSet whitespaceCharacterSet]];
        headers[name] = value;
    }

    // ---- Host check -------------------------------------------------------
    // Loopback only passes. Without this, a page the user visits could resolve
    // a name to 127.0.0.1 and reach this server; the browser would send its own
    // Host, which would not be loopback.
    NSString *host = headers[@"host"];
    if (![self isLoopbackHost:host]) {
        NSLog(@"%@: rejected request with Host=%@ (not loopback)",
              kChannelLogPrefix, host.length > 0 ? host : @"<absent>");
        [self respondAndClose:context status:403 message:@"host is not loopback" body:nil];
        return;
    }

    // ---- auth -------------------------------------------------------------
    NSString *authorization = headers[@"authorization"];
    if (![self authorizationIsValid:authorization]) {
        // The header value is not logged, not even a prefix: it is a credential.
        NSLog(@"%@: rejected request: %@ authorization",
              kChannelLogPrefix, authorization.length == 0 ? @"missing" : @"invalid");
        [self respondAndClose:context status:401 message:@"unauthorized" body:nil];
        return;
    }

    // ---- route ------------------------------------------------------------
    NSString *path = [target componentsSeparatedByString:@"?"].firstObject ?: @"";

    if ([path isEqualToString:@"/v1/health"]) {
        if (![method isEqualToString:@"GET"]) {
            [self respondAndClose:context status:405 message:@"use GET" body:nil];
            return;
        }
        [self respondHealth:context];
        return;
    }

    if ([path isEqualToString:@"/v1/resolve"]) {
        if (!([method isEqualToString:@"POST"] || [method isEqualToString:@"GET"])) {
            [self respondAndClose:context status:405 message:@"use POST or GET" body:nil];
            return;
        }
        NSUInteger contentLength = [headers[@"content-length"] integerValue];
        [self readBodyFor:context
            contentLength:contentLength
             headerLength:headerLength
                whenReady:^(NSData *fullBody) {
            [self handleResolve:context method:method target:target body:fullBody];
        }];
        return;
    }

    if ([path isEqualToString:@"/v1/exec"]) {
        if (![method isEqualToString:@"POST"]) {
            [self respondAndClose:context status:405 message:@"use POST" body:nil];
            return;
        }
        NSUInteger contentLength = [headers[@"content-length"] integerValue];
        [self readBodyFor:context
            contentLength:contentLength
             headerLength:headerLength
                whenReady:^(NSData *fullBody) {
            [self handleExec:context body:fullBody];
        }];
        return;
    }

    // ---- /v1/_inject-failure -------------------------------------------
    // TEST HOOK: make the next `/v1/exec` answer 500 without starting anything.
    //
    // WHY A SERVER-SIDE SWITCH AND NOT A CLIENT-SIDE STUB: the criterion is
    // "when the Swift side fails, the model sees a failure rather than a silent
    // success". Stubbing the client would test the stub. This makes the real
    // server produce a real failure over the real socket, so the path under
    // test is exactly the one a genuine bug would take.
    //
    // It is not a general fault-injection surface: it can only make the NEXT
    // exec fail, it needs the same bearer token as everything else, and it is
    // compiled in unconditionally rather than shipped hidden — an acceptance
    // hook nobody can reach is an acceptance hook nobody has exercised.
    if ([path isEqualToString:@"/v1/_inject-failure"]) {
        if (![method isEqualToString:@"POST"]) {
            [self respondAndClose:context status:405 message:@"use POST" body:nil];
            return;
        }
        NSUInteger contentLength = [headers[@"content-length"] integerValue];
        [self readBodyFor:context
            contentLength:contentLength
             headerLength:headerLength
                whenReady:^(NSData *fullBody) {
            NSDictionary *json = [NSJSONSerialization JSONObjectWithData:fullBody options:0 error:nil];
            NSString *message = [json isKindOfClass:[NSDictionary class]] && [json[@"message"] isKindOfClass:[NSString class]]
                ? json[@"message"] : @"injected failure (no message supplied)";
            NSNumber *count = [json isKindOfClass:[NSDictionary class]] && [json[@"count"] isKindOfClass:[NSNumber class]]
                ? json[@"count"] : @1;
            os_unfair_lock_lock(&self->_injectionLock);
            self->_injectedExecFailures = count.unsignedIntegerValue;
            self->_injectedExecFailureMessage = [message copy];
            os_unfair_lock_unlock(&self->_injectionLock);
            NSData *body = [NSJSONSerialization dataWithJSONObject:@{
                @"armed": @YES,
                @"count": count,
                @"message": message,
            } options:0 error:nil];
            [self respondAndClose:context status:200 message:@"" body:body];
        }];
        return;
    }

    // ---- /v1/cancel ----------------------------------------------------
    // POST { "execId": "..." }. Cancels the exec if it is the running one.
    //
    // A separate endpoint rather than "close the execed connection": the
    // provider has to be able to cancel from a place that is not the streaming
    // response handler (a timeout, an AbortController, service disposal), and
    // those callers may already be gone by the time the socket would close.
    if ([path isEqualToString:@"/v1/cancel"]) {
        if (![method isEqualToString:@"POST"]) {
            [self respondAndClose:context status:405 message:@"use POST" body:nil];
            return;
        }
        NSUInteger contentLength = [headers[@"content-length"] integerValue];
        [self readBodyFor:context
            contentLength:contentLength
             headerLength:headerLength
                whenReady:^(NSData *fullBody) {
            [self handleCancel:context body:fullBody];
        }];
        return;
    }

    // ---- /v1/executable ------------------------------------------------
    // POST { "name": "git", "path": "..." } -> { found, path, ... }.
    //
    // This is what makes `resolveExecutable` honest. Answering it on the host
    // would mean guessing: the host's /usr/bin/git and the guest's are
    // different files, and on a phone the host one may not exist at all. The
    // guest is the only authority on what the guest can execute.
    if ([path isEqualToString:@"/v1/executable"]) {
        if (![method isEqualToString:@"POST"]) {
            [self respondAndClose:context status:405 message:@"use POST" body:nil];
            return;
        }
        NSUInteger contentLength = [headers[@"content-length"] integerValue];
        [self readBodyFor:context
            contentLength:contentLength
             headerLength:headerLength
                whenReady:^(NSData *fullBody) {
            [self handleExecutable:context body:fullBody];
        }];
        return;
    }

    // ---- /v1/image/probe and /v1/image/encode ---------------------------
    //
    // The raster operations DSH performs through `sharp`, served by ImageIO
    // instead. Both take a JSON body with the image bytes in base64 and answer
    // with the facts the Node provider reports into DSH's attachment seam.
    //
    // WHY ON THIS SERVER rather than a second listener: the security posture is
    // already exactly what an image decoder needs — loopback only, a bearer
    // token minted per launch, a Host check against DNS rebinding, and one
    // request per connection — and duplicating that machinery would create a
    // second place for it to be got wrong. The two endpoints decode no guest
    // state and start no process, so they do not disturb the single-exec queue.
    //
    // SIZE: a 20 MiB image is ~27 MiB of base64 in a JSON body. kMaxRequestBytes
    // is 16 MiB, which was sized for a command line. It is raised here only for
    // these two paths (`imageBodyLimit` below), so the exec endpoints keep the
    // bound they were designed with.
    if ([path isEqualToString:ISHGuestChannelPathImageProbe] || [path isEqualToString:ISHGuestChannelPathImageEncode]) {
        if (![method isEqualToString:@"POST"]) {
            [self respondAndClose:context status:405 message:@"use POST" body:nil];
            return;
        }
        BOOL encode = [path isEqualToString:ISHGuestChannelPathImageEncode];
        [self readBodyFor:context
            contentLength:[headers[@"content-length"] integerValue]
             headerLength:headerLength
               sizeLimit:kMaxImageRequestBytes
                whenReady:^(NSData *fullBody) {
            [self handleImageRequest:context body:fullBody encode:encode];
        }];
        return;
    }

    [self respondAndClose:context status:404 message:@"no such endpoint" body:nil];
}

/// Arrange for `whenReady` to run once the whole body has arrived.
///
/// The callback is handed the *body only*, sliced at `headerLength`, because
/// every handler that uses it immediately parses JSON out of it.
///
/// The four-argument form keeps the exec-sized bound; the `sizeLimit:` form
/// exists for the image endpoints, whose bodies are legitimately much larger.
/// Passing the limit explicitly rather than switching on the path keeps the
/// decision at the call site, where the handler and its bound are visible
/// together.
- (void)readBodyFor:(DSHChannelConnection *)context
      contentLength:(NSUInteger)contentLength
       headerLength:(NSUInteger)headerLength
          whenReady:(void (^)(NSData *body))whenReady {
    [self readBodyFor:context
        contentLength:contentLength
         headerLength:headerLength
           sizeLimit:kMaxRequestBytes
            whenReady:whenReady];
}

- (void)readBodyFor:(DSHChannelConnection *)context
      contentLength:(NSUInteger)contentLength
       headerLength:(NSUInteger)headerLength
          sizeLimit:(NSUInteger)sizeLimit
          whenReady:(void (^)(NSData *body))whenReady {
    if (contentLength == 0) {
        // Zero-length bodies are legal on GET /v1/resolve.
        whenReady([NSData data]);
        return;
    }
    if (contentLength > sizeLimit) {
        // Refuse on the declared length, before buffering anything: a client
        // that announces 200 MiB should cost one header parse, not 200 MiB of
        // growth in the app's heap.
        [self respondAndClose:context status:413 message:@"request too large" body:nil];
        return;
    }
    if (context.input.length >= headerLength + contentLength) {
        whenReady([context.input subdataWithRange:NSMakeRange(headerLength, contentLength)]);
        return;
    }

    __weak ISHGuestChannel *weakSelf = self;
    __weak DSHChannelConnection *weakContext = context;
    [self readMoreFor:context
                until:headerLength + contentLength
            sizeLimit:sizeLimit
            whenReady:^(NSData *whole) {
        ISHGuestChannel *strongSelf = weakSelf;
        DSHChannelConnection *strongContext = weakContext;
        if (strongSelf == nil || strongContext == nil) return;
        if (whole.length < headerLength + contentLength) {
            [strongSelf respondAndClose:strongContext status:400 message:@"truncated body" body:nil];
            return;
        }
        whenReady([whole subdataWithRange:NSMakeRange(headerLength, contentLength)]);
    }];
}

- (void)readMoreFor:(DSHChannelConnection *)context
              until:(NSUInteger)totalLength
          sizeLimit:(NSUInteger)sizeLimit
          whenReady:(void (^)(NSData *))whenReady {
    __weak ISHGuestChannel *weakSelf = self;
    __weak DSHChannelConnection *weakContext = context;
    nw_connection_receive(context.connection, 1, 65536,
                          ^(dispatch_data_t data, dispatch_data_t ctx,
                            bool isComplete, nw_error_t error) {
        ISHGuestChannel *strongSelf = weakSelf;
        DSHChannelConnection *strongContext = weakContext;
        if (strongSelf == nil || strongContext == nil) return;
        if (data != NULL) {
            dispatch_data_apply(data, ^bool(dispatch_data_t region, size_t offset, const void *buffer, size_t size) {
                [strongContext.input appendBytes:buffer length:size];
                return true;
            });
        }
        if (strongContext.input.length > sizeLimit) {
            [strongSelf respondAndClose:strongContext status:413 message:@"request too large" body:nil];
            return;
        }
        if (strongContext.input.length >= totalLength) {
            // The caller slices from its own offset; hand it the whole buffer.
            whenReady(strongContext.input);
            return;
        }
        if (isComplete || error != NULL) {
            [strongSelf respondAndClose:strongContext status:400 message:@"truncated body" body:nil];
            return;
        }
        [strongSelf readMoreFor:strongContext until:totalLength sizeLimit:sizeLimit whenReady:whenReady];
    });
}

- (BOOL)isLoopbackHost:(NSString *)host {
    if (host.length == 0) return NO;
    NSString *name = host;
    // Strip the port. IPv6 literals are bracketed; this server never uses one,
    // so a bracket here means a client that is not us, and it is rejected.
    if ([name hasPrefix:@"["]) return NO;
    NSRange colon = [name rangeOfString:@":" options:NSBackwardsSearch];
    if (colon.location != NSNotFound) name = [name substringToIndex:colon.location];
    name = [name lowercaseString];
    return [name isEqualToString:@"127.0.0.1"] || [name isEqualToString:@"localhost"];
}

- (BOOL)authorizationIsValid:(NSString *)authorization {
    if (authorization.length == 0) return NO;
    static NSString *const prefix = @"Bearer ";
    if (![authorization hasPrefix:prefix]) return NO;
    NSString *presented = [authorization substringFromIndex:prefix.length];
    NSString *expected = _token;
    if (expected.length == 0) return NO;
    // Constant-time comparison: a length check first (which leaks only the
    // length, and the length is fixed), then a byte-wise XOR accumulate.
    if (presented.length != expected.length) return NO;
    const char *a = presented.UTF8String;
    const char *b = expected.UTF8String;
    if (a == NULL || b == NULL) return NO;
    unsigned char difference = 0;
    for (size_t i = 0; i < (size_t) expected.length; i++) {
        difference |= (unsigned char) (a[i] ^ b[i]);
    }
    return difference == 0;
}

#pragma mark responses

- (void)sendOnConnection:(DSHChannelConnection *)context
                    data:(NSData *)data
              completion:(void (^)(BOOL ok))completion {
    dispatch_async(context.sendQueue, ^{
        if (context.closed) { if (completion) completion(NO); return; }
        nw_connection_send(context.connection,
                           dispatch_data_create(data.bytes, data.length, NULL, DISPATCH_DATA_DESTRUCTOR_DEFAULT),
                           NW_CONNECTION_DEFAULT_MESSAGE_CONTEXT, false,
                           ^(nw_error_t error) {
            if (completion) completion(error == NULL);
        });
    });
}

- (void)respondAndClose:(DSHChannelConnection *)context
                 status:(NSInteger)status
                message:(NSString *)message
                   body:(nullable NSData *)body {
    NSData *payload = body ?: [message dataUsingEncoding:NSUTF8StringEncoding];
    NSString *contentType = body != nil ? @"application/json" : @"text/plain; charset=utf-8";
    NSString *header = [NSString stringWithFormat:
        @"HTTP/1.1 %ld %@\r\n"
        @"Content-Type: %@\r\n"
        @"Content-Length: %lu\r\n"
        @"Connection: close\r\n"
        @"X-DSH-Channel: guest\r\n"
        @"\r\n",
        (long) status, [self reasonForStatus:status], contentType,
        (unsigned long) payload.length];
    NSMutableData *response = [[header dataUsingEncoding:NSUTF8StringEncoding] mutableCopy];
    [response appendData:payload];
    [self sendOnConnection:context data:response completion:^(BOOL ok) { (void) ok; }];
    // Give the write a moment before tearing the connection down: cancelling
    // immediately can drop the tail of the response.
    dispatch_after(dispatch_time(DISPATCH_TIME_NOW, (int64_t)(0.15 * NSEC_PER_SEC)), _queue, ^{
        [self closeConnection:context];
    });
}

- (NSString *)reasonForStatus:(NSInteger)status {
    switch (status) {
        case 200: return @"OK";
        case 400: return @"Bad Request";
        case 401: return @"Unauthorized";
        case 403: return @"Forbidden";
        case 404: return @"Not Found";
        case 405: return @"Method Not Allowed";
        case 409: return @"Conflict";
        case 413: return @"Payload Too Large";
        case 415: return @"Unsupported Media Type";
        case 500: return @"Internal Server Error";
        default: return @"Unknown";
    }
}

- (void)closeConnection:(DSHChannelConnection *)context {
    if (context.closed) return;
    context.closed = true;
    nw_connection_cancel(context.connection);
    dispatch_async(_queue, ^{ [self->_connections removeObject:context]; });
}

#pragma mark /v1/health

- (void)respondHealth:(DSHChannelConnection *)context {
    ISHGuest *guest = ISHGuest.shared;
    NSDictionary *payload = @{
        @"ok": @YES,
        @"guestState": @(guest.state),
        @"guestDetail": guest.stateDetail ?: @"",
        @"workspaceGuestPath": guest.boundWorkspaceGuestPath ?: (id) [NSNull null],
        @"workspaceHostPath": guest.boundWorkspaceHostPath ?: (id) [NSNull null],
        @"pid": @(getpid()),
    };
    NSData *body = [NSJSONSerialization dataWithJSONObject:payload options:0 error:nil];
    [self respondAndClose:context status:200 message:@"" body:body];
}

#pragma mark /v1/resolve

- (void)handleResolve:(DSHChannelConnection *)context
               method:(NSString *)method
               target:(NSString *)target
                 body:(NSData *)body {
    NSString *path = nil;
    if ([method isEqualToString:@"GET"]) {
        NSArray<NSString *> *parts = [target componentsSeparatedByString:@"?"];
        if (parts.count > 1) {
            for (NSString *pair in [parts[1] componentsSeparatedByString:@"&"]) {
                NSArray<NSString *> *kv = [pair componentsSeparatedByString:@"="];
                if (kv.count == 2 && [kv[0] isEqualToString:@"path"]) {
                    path = [kv[1] stringByRemovingPercentEncoding];
                }
            }
        }
    } else {
        NSDictionary *json = [NSJSONSerialization JSONObjectWithData:body options:0 error:nil];
        if ([json isKindOfClass:[NSDictionary class]]) path = json[@"path"];
    }

    if (![path isKindOfClass:[NSString class]] || path.length == 0) {
        [self respondAndClose:context status:400 message:@"resolve needs a path" body:nil];
        return;
    }

    __weak ISHGuestChannel *weakSelf = self;
    [ISHGuest.shared resolvePath:path completion:^(NSDictionary<NSString *, id> *info) {
        ISHGuestChannel *strongSelf = weakSelf;
        if (strongSelf == nil) return;
        NSData *responseBody = [NSJSONSerialization dataWithJSONObject:info options:0 error:nil];
        [strongSelf respondAndClose:context status:200 message:@"" body:responseBody];
    }];
}

#pragma mark /v1/exec

/// Called by `handleExec:` with the body of the request (headers already
/// stripped by `readBodyFor:`).
- (void)handleExec:(DSHChannelConnection *)context body:(NSData *)body {
    // Consume an armed injected failure first, so the criterion tests the
    // transport's error path rather than the guest's behaviour.
    //
    // A plain mutex, NOT `dispatch_sync(_queue, ...)`. Request handler bodies
    // already run ON the channel's serial queue (the connection's receive
    // callback is scheduled there), so a synchronous dispatch back onto it is a
    // self-deadlock: libdispatch traps with "BUG IN CLIENT OF LIBDISPATCH:
    // dispatch_sync called on queue already owned by current thread", which the
    // app sees as SIGTRAP and dies. Measured — the app crashed on the first real
    // tool call after this hook was added.
    BOOL inject = NO;
    NSString *injectionMessage = nil;
    os_unfair_lock_lock(&_injectionLock);
    if (_injectedExecFailures > 0) {
        _injectedExecFailures -= 1;
        inject = YES;
        injectionMessage = [_injectedExecFailureMessage copy];
        if (_injectedExecFailures == 0) _injectedExecFailureMessage = nil;
    }
    os_unfair_lock_unlock(&_injectionLock);
    if (inject) {
        [self respondAndClose:context status:500 message:injectionMessage ?: @"injected failure" body:nil];
        return;
    }

    NSDictionary *json = [NSJSONSerialization JSONObjectWithData:body options:0 error:nil];
    if (![json isKindOfClass:[NSDictionary class]]) {
        [self respondAndClose:context status:400 message:@"exec needs a JSON object" body:nil];
        return;
    }

    ISHGuestExecRequest *request = [[ISHGuestExecRequest alloc] init];
    request.command = [json[@"command"] isKindOfClass:[NSString class]] ? json[@"command"] : nil;
    if ([json[@"argv"] isKindOfClass:[NSArray class]]) {
        request.argv = [json[@"argv"] filteredArrayUsingPredicate:
                        [NSPredicate predicateWithBlock:^BOOL(id object, NSDictionary *bindings) {
            return [object isKindOfClass:[NSString class]];
        }]];
    }
    request.workingDirectory = [json[@"cwd"] isKindOfClass:[NSString class]] ? json[@"cwd"] : nil;
    request.execID = [json[@"execId"] isKindOfClass:[NSString class]] ? json[@"execId"] : nil;
    request.timeout = [json[@"timeout"] isKindOfClass:[NSNumber class]] ? [json[@"timeout"] doubleValue] : 0;
    if ([json[@"maxOutputBytes"] isKindOfClass:[NSNumber class]]) {
        request.maxOutputBytes = (NSUInteger) [json[@"maxOutputBytes"] unsignedLongLongValue];
    }
    if ([json[@"env"] isKindOfClass:[NSArray class]]) {
        request.environment = [json[@"env"] filteredArrayUsingPredicate:
                              [NSPredicate predicateWithBlock:^BOOL(id object, NSDictionary *bindings) {
            return [object isKindOfClass:[NSString class]];
        }]];
    }
    if ([json[@"stdinBase64"] isKindOfClass:[NSString class]]) {
        request.stdin = [[NSData alloc] initWithBase64EncodedString:json[@"stdinBase64"]
                                                           options:NSDataBase64DecodingIgnoreUnknownCharacters];
    }
    // Bounded output belongs to the Node side (see ISHGuestExecRequest
    // .retainOutput). The channel therefore asks the guest not to keep a copy:
    // `maxBytes`/spill are `OutputCollector`'s job, and a second truncation
    // here would make its `spillPath` promise — "the complete stream" — false.
    // Only `totalOutputBytes` is still counted, so the caller can tell the
    // model the stream was larger than what it will see.
    request.retainOutput = NO;

    if (request.command.length == 0 && request.argv.count == 0) {
        [self respondAndClose:context status:400 message:@"exec needs command or argv" body:nil];
        return;
    }

    [self beginStreamingExec:request onConnection:context];
}

/// Start the command and stream its events as chunked NDJSON.
- (void)beginStreamingExec:(ISHGuestExecRequest *)request onConnection:(DSHChannelConnection *)context {
    NSString *execID = request.execID.length > 0 ? request.execID : [[NSUUID UUID] UUIDString];
    request.execID = execID;
    os_unfair_lock_lock(&_activeExecsLock);
    [self->_activeExecs addObject:execID];
    os_unfair_lock_unlock(&_activeExecsLock);

    NSString *header =
        @"HTTP/1.1 200 OK\r\n"
        @"Content-Type: application/x-ndjson; charset=utf-8\r\n"
        @"Transfer-Encoding: chunked\r\n"
        @"Connection: close\r\n"
        @"Cache-Control: no-store\r\n"
        @"X-DSH-Channel: guest\r\n"
        @"\r\n";
    [self sendOnConnection:context
                      data:[header dataUsingEncoding:NSUTF8StringEncoding]
                completion:^(BOOL ok) { (void) ok; }];

    __weak ISHGuestChannel *weakSelf = self;
    __weak DSHChannelConnection *weakContext = context;

    void (^sendEvent)(NSDictionary *) = ^(NSDictionary *event) {
        ISHGuestChannel *strongSelf = weakSelf;
        DSHChannelConnection *strongContext = weakContext;
        if (strongSelf == nil || strongContext == nil || strongContext.closed) return;
        NSData *json = [NSJSONSerialization dataWithJSONObject:event options:0 error:nil];
        if (json == nil) return;
        NSMutableData *line = [json mutableCopy];
        [line appendBytes:"\n" length:1];
        [strongSelf sendChunk:line onConnection:strongContext];
    };

    [ISHGuest.shared execRequest:request
                      chunkBlock:^(NSData *data, BOOL isStdErr) {
        sendEvent(@{
            @"type": isStdErr ? @"stderr" : @"stdout",
            @"data": [data base64EncodedStringWithOptions:0] ?: @"",
            @"t": @([NSDate date].timeIntervalSince1970 * 1000.0),
        });
    }
                       lineBlock:nil
                      completion:^(ISHGuestExecResult *result) {
        ISHGuestChannel *strongSelf = weakSelf;
        DSHChannelConnection *strongContext = weakContext;
        if (strongSelf == nil || strongContext == nil) return;

        NSMutableDictionary *done = [@{
            @"type": @"exit",
            @"execId": result.execID ?: execID,
            @"pid": @(result.pid),
            @"exitCode": @(result.exitCode),
            @"durationMs": @(result.duration * 1000.0),
            @"timedOut": @(result.timedOut),
            @"truncated": @(result.truncated),
            @"totalOutputBytes": @(result.totalOutputBytes),
            @"t": @([NSDate date].timeIntervalSince1970 * 1000.0),
        } mutableCopy];
        if (result.launchError.length > 0) done[@"launchError"] = result.launchError;
        sendEvent(done);

        // The terminating chunk is already framed ("0\r\n\r\n"); sending it
        // through sendChunk: would frame it a second time and leave the client
        // with a stray "\r" line after the last event.
        [strongSelf sendOnConnection:strongContext
                                data:[NSMutableData dataWithBytes:"0\r\n\r\n" length:5]
                          completion:^(BOOL ok) { (void) ok; }];
        dispatch_after(dispatch_time(DISPATCH_TIME_NOW, (int64_t)(0.2 * NSEC_PER_SEC)),
                       strongSelf->_queue, ^{
            [strongSelf closeConnection:strongContext];
            os_unfair_lock_lock(&strongSelf->_activeExecsLock);
            [strongSelf->_activeExecs removeObject:execID];
            os_unfair_lock_unlock(&strongSelf->_activeExecsLock);
        });
    }];
}

/// One chunk of the chunked-transfer body.
- (void)sendChunk:(NSData *)payload onConnection:(DSHChannelConnection *)context {
    NSMutableData *chunk = [NSMutableData data];
    NSString *size = [NSString stringWithFormat:@"%lx\r\n", (unsigned long) payload.length];
    [chunk appendData:[size dataUsingEncoding:NSUTF8StringEncoding]];
    [chunk appendData:payload];
    [chunk appendBytes:"\r\n" length:2];
    [self sendOnConnection:context data:chunk completion:^(BOOL ok) { (void) ok; }];
}

#pragma mark /v1/cancel

- (void)handleCancel:(DSHChannelConnection *)context body:(NSData *)body {
    NSDictionary *json = [NSJSONSerialization JSONObjectWithData:body options:0 error:nil];
    NSString *execID = [json isKindOfClass:[NSDictionary class]] && [json[@"execId"] isKindOfClass:[NSString class]]
        ? json[@"execId"] : nil;
    if (execID.length == 0) {
        [self respondAndClose:context status:400 message:@"cancel needs an execId" body:nil];
        return;
    }

    BOOL cancelled = [ISHGuest.shared cancelExecWithID:execID];
    NSDictionary *payload = @{
        @"execId": execID,
        // Honest answer, not a success flag: NO means the id did not name the
        // exec that is running right now (already finished, or never started),
        // and the caller must not treat that as "the process is dead".
        @"cancelled": @(cancelled),
        @"active": @([self activeExecCount]),
    };
    NSData *responseBody = [NSJSONSerialization dataWithJSONObject:payload options:0 error:nil];
    [self respondAndClose:context status:200 message:@"" body:responseBody];
}

/// How many exec ids the server believes are in flight. Reported by /v1/cancel
/// so a caller can tell "my id was stale" from "the server has lost track".
- (NSUInteger)activeExecCount {
    // NOT `dispatch_sync(_queue, ...)`. `_activeExecs` is mutated from `_queue`
    // (see `beginStreamingExec:`), but this method is itself called from a
    // request handler, and those already run ON `_queue`. Dispatching
    // synchronously back onto the queue a thread already owns is a libdispatch
    // contract violation: it traps with SIGTRAP and takes the app down. Measured
    // — the app died the first time `/v1/cancel` was ever exercised, which is
    // exactly the endpoint that had never been called before this step.
    //
    // An unfair lock is right here: the critical section is one integer, the
    // concurrency is nil, and correctness only needs the read to be atomic with
    // respect to the mutations, not ordered with respect to the queue.
    os_unfair_lock_lock(&_activeExecsLock);
    NSUInteger count = _activeExecs.count;
    os_unfair_lock_unlock(&_activeExecsLock);
    return count;
}

#pragma mark /v1/executable

- (void)handleExecutable:(DSHChannelConnection *)context body:(NSData *)body {
    NSDictionary *json = [NSJSONSerialization JSONObjectWithData:body options:0 error:nil];
    if (![json isKindOfClass:[NSDictionary class]]) {
        [self respondAndClose:context status:400 message:@"executable needs a JSON object" body:nil];
        return;
    }
    NSString *name = [json[@"name"] isKindOfClass:[NSString class]] ? json[@"name"] : nil;
    if (name.length == 0) {
        [self respondAndClose:context status:400 message:@"executable needs a name" body:nil];
        return;
    }
    NSString *pathValue = [json[@"path"] isKindOfClass:[NSString class]] ? json[@"path"] : nil;

    NSString *resolved = [ISHGuest.shared resolveExecutableNamed:name pathValue:pathValue];
    NSDictionary *payload = resolved != nil
        ? @{ @"name": name, @"found": @YES, @"path": resolved }
        // `found: NO` rather than a 404: "git is not installed" is a normal
        // answer to this question, and the provider turns it into
        // SubprocessExecutableNotFoundError. A 404 would look like a channel
        // failure and get retried.
        : @{ @"name": name, @"found": @NO };
    NSData *responseBody = [NSJSONSerialization dataWithJSONObject:payload options:0 error:nil];
    [self respondAndClose:context status:200 message:@"" body:responseBody];
}

#pragma mark /v1/image/probe and /v1/image/encode

/// Serve one image request.
///
/// Body (JSON): `{ "data": "<base64>", "maxPixels"?, "maxDimension"?,
/// "maxWidth"?, "maxHeight"?, "maxBytes"? }`. Answer (JSON): the dictionary
/// `ISHImageService` produced, plus `"endpoint"` so a log line cannot be
/// mistaken for the other one.
///
/// WHY THE DECODE RUNS OFF THE CHANNEL QUEUE: both operations block for tens of
/// milliseconds on a small image and for a few hundred on a 24-megapixel one.
/// Running them inline would stall every other connection for that long — and
/// the channel queue is also what serves `/v1/exec` and the health probe, so a
/// slow image would look like a wedged guest. The service owns a serial queue of
/// its own for exactly this reason; this handler only hands work to it.
- (void)handleImageRequest:(DSHChannelConnection *)context
                      body:(NSData *)body
                    encode:(BOOL)encode {
    NSDictionary *json = [NSJSONSerialization JSONObjectWithData:body options:0 error:nil];
    if (![json isKindOfClass:[NSDictionary class]] || ![json[@"data"] isKindOfClass:[NSString class]]) {
        [self respondAndClose:context status:400 message:@"image request needs a base64 \"data\" string" body:nil];
        return;
    }
    // Base64 string → bytes. A non-base64 payload is the caller's bug, not a
    // decoder failure, so it is a 400 with a specific message rather than a
    // generic INVALID_IMAGE from the decoder.
    NSData *imageData = [[NSData alloc] initWithBase64EncodedString:json[@"data"] options:0];
    if (imageData == nil) {
        [self respondAndClose:context status:400 message:@"image request \"data\" is not valid base64" body:nil];
        return;
    }

    long long maxPixels = [json[@"maxPixels"] isKindOfClass:[NSNumber class]] ? [json[@"maxPixels"] longLongValue] : 0;
    long long maxDimension = [json[@"maxDimension"] isKindOfClass:[NSNumber class]] ? [json[@"maxDimension"] longLongValue] : 0;
    long long maxWidth = [json[@"maxWidth"] isKindOfClass:[NSNumber class]] ? [json[@"maxWidth"] longLongValue] : 0;
    long long maxHeight = [json[@"maxHeight"] isKindOfClass:[NSNumber class]] ? [json[@"maxHeight"] longLongValue] : 0;
    long long maxBytes = [json[@"maxBytes"] isKindOfClass:[NSNumber class]] ? [json[@"maxBytes"] longLongValue] : 0;
    BOOL fullDecode = [json[@"fullDecode"] isKindOfClass:[NSNumber class]] ? [json[@"fullDecode"] boolValue] : YES;

    __weak ISHGuestChannel *weakSelf = self;
    __weak DSHChannelConnection *weakContext = context;
    dispatch_async(ISHImageService.shared.queue, ^{
        ISHImageService *service = ISHImageService.shared;
        NSDictionary *answer = encode
            ? [service encodeData:imageData maxWidth:maxWidth maxHeight:maxHeight maxBytes:maxBytes]
            : [service probeData:imageData fullDecode:fullDecode maxPixels:maxPixels maxDimension:maxDimension];
        NSMutableDictionary *payload = [answer mutableCopy];
        payload[@"endpoint"] = encode ? @"encode" : @"probe";
        NSData *responseBody = [NSJSONSerialization dataWithJSONObject:payload options:0 error:nil];
        ISHGuestChannel *strongSelf = weakSelf;
        DSHChannelConnection *strongContext = weakContext;
        if (strongSelf == nil || strongContext == nil) return;
        // Back onto the channel queue: every connection's state and its send
        // queue are owned there, and responding from the image queue would race
        // the connection bookkeeping.
        dispatch_async(strongSelf->_queue, ^{
            if (responseBody == nil) {
                [strongSelf respondAndClose:strongContext status:500 message:@"image answer is not JSON" body:nil];
                return;
            }
            // 200 even when the decoder refused the image: "these bytes are not
            // a decodable image" is a normal answer to the question this
            // endpoint was asked, and the Node provider turns `ok: NO` into the
            // matching DSH AttachmentError. A 4xx here would look like a channel
            // failure and invite a retry of something that will never succeed.
            [strongSelf respondAndClose:strongContext status:200 message:@"" body:responseBody];
        });
    });
}

#pragma mark environment

- (void)exportEnvironmentForNode:(NSMutableDictionary<NSString *, NSString *> *)environment {
    if (_state != ISHGuestChannelStateListening || _port <= 0) return;
    environment[@"DSH_GUEST_CHANNEL_URL"] =
        [NSString stringWithFormat:@"http://127.0.0.1:%ld", (long) _port];
    environment[@"DSH_GUEST_CHANNEL_TOKEN"] = _token;
    // A second copy under a name that says what it is for, so a reader of the
    // Node side does not have to guess. Same value, no new exposure: it is the
    // same process's environment either way.
    environment[@"DSH_GUEST_CHANNEL_PORT"] = [NSString stringWithFormat:@"%ld", (long) _port];
}

@end

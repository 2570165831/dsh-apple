//
//  ISHGuestChannel.h
//  DSHPortC
//
//  The loopback HTTP channel between the embedded Node process and the guest.
//
//  WHY A SOCKET AND NOT A FUNCTION CALL: Node and Swift are in the same
//  process, so the shortest path would be a C function pointer. That path is
//  not available. The guest kernel keeps `current` in thread-local storage and
//  a guest command may not be started from an arbitrary Node thread — Node's
//  event loop thread would become a guest process and never come back, and a
//  worker thread would be a second kernel entry point the kernel is not
//  thread-safe against. The one thread that may start a command is the guest
//  queue, and there is exactly one of those.
//
//  So the boundary is an HTTP server on 127.0.0.1 with a random port and a
//  random 32-byte bearer token. That is the same shape C-stage/D-stage research
//  recommended, and it has two side benefits: Node uses its ordinary `fetch`
//  (the polyfill in sim/ already streams), and the boundary is inspectable with
//  curl when something goes wrong.
//
//  Security posture, stated plainly:
//    * bound to 127.0.0.1 only, never 0.0.0.0
//    * every request must carry `Authorization: Bearer <32 random bytes>`
//    * the `Host` header must name a loopback address (defends against DNS
//      rebinding, where a browser resolves attacker.example to 127.0.0.1)
//    * the token is never written to any log this class owns
//

#import <Foundation/Foundation.h>

NS_ASSUME_NONNULL_BEGIN

/// How the server came up. Read by the app after `startWithCompletion:`.
typedef NS_ENUM(NSInteger, ISHGuestChannelState) {
    ISHGuestChannelStateIdle = 0,
    ISHGuestChannelStateStarting,
    ISHGuestChannelStateListening,
    ISHGuestChannelStateFailed,
};

/// The two image endpoints, spelled once.
///
/// `/v1/exec`, `/v1/resolve`, `/v1/health`, `/v1/cancel` and `/v1/executable`
/// belong to the guest. These two do not touch the guest at all: they are the
/// platform's image decoder, standing in for the `sharp` native addon iOS
/// cannot load. Declared rather than inlined so the Node provider, the
/// acceptance script and the report all spell them the same way.
extern NSString *const ISHGuestChannelPathImageProbe;
extern NSString *const ISHGuestChannelPathImageEncode;

@interface ISHGuestChannel : NSObject

@property (class, nonatomic, readonly) ISHGuestChannel *shared;

@property (nonatomic, readonly) ISHGuestChannelState state;
/// The port actually bound, or 0.
@property (nonatomic, readonly) NSInteger port;
/// The token this process minted. Deliberately not a property that logs: the
/// only consumers are the two environment variables written in
/// `exportEnvironmentForNode` and the auth check itself.
@property (nonatomic, readonly, copy, nullable) NSString *token;
/// Human-readable failure, safe to log (never contains the token).
@property (atomic, readonly, copy, nullable) NSString *lastError;

/// Bind, listen, and start serving. Idempotent. Tries successive ports when a
/// port is taken: 8 attempts, then gives up with a message that says so.
/// Completion arrives on the main queue.
- (void)startWithCompletion:(void (^)(NSError *_Nullable error))completion;

/// Publish the URL and token to the environment Node will be started with.
///
/// Node reads `DSH_GUEST_CHANNEL_URL` and `DSH_GUEST_CHANNEL_TOKEN`. The token
/// goes through the environment, not argv, because argv is visible in the boot
/// log the app writes and the env block is not.
///
/// Takes a `NSMutableDictionary` for the Objective-C caller (a host script that
/// links this class); the Swift host builds its dictionary directly from
/// `url`, `port` and `token` instead, because bridging an `[String: String]` to
/// `NSMutableDictionary` in place is not something Swift does implicitly.
- (void)exportEnvironmentForNode:(NSMutableDictionary<NSString *, NSString *> *)environment;

/// Redact the token from any text. Used by the log path so a message that
/// happens to echo a header cannot leak it.
- (NSString *)redact:(NSString *)text;

@end

NS_ASSUME_NONNULL_END

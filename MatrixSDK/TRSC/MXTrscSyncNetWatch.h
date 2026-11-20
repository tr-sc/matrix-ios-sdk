// Copyright 2026
// SPDX-License-Identifier: Apache-2.0

#import <Foundation/Foundation.h>

NS_ASSUME_NONNULL_BEGIN

/** Why the session cancelled the sync request in flight and sent a new one. */
typedef NSString *MXTrscSyncRestartReason NS_TYPED_ENUM;
/** The network path moved to another interface while it stayed usable (Wi-Fi ↔ cellular, VPN). */
FOUNDATION_EXPORT MXTrscSyncRestartReason const MXTrscSyncRestartReasonNetworkChange;
/** The network path became usable again after it was not. */
FOUNDATION_EXPORT MXTrscSyncRestartReason const MXTrscSyncRestartReasonNetworkRestored;
/** The long-poll got no answer within its server timeout + the grace. */
FOUNDATION_EXPORT MXTrscSyncRestartReason const MXTrscSyncRestartReasonWatchdog;
/** Rooms were added to the next request (`-[MXSession trscSubscribeRoomsInNextSyncRequest:]`). */
FOUNDATION_EXPORT MXTrscSyncRestartReason const MXTrscSyncRestartReasonSubscription;
/** The app asked (`-[MXSession trscRestartSyncWithReason:]`), e.g. a push for an event the sync has not brought. */
FOUNDATION_EXPORT MXTrscSyncRestartReason const MXTrscSyncRestartReasonApp;

/** One state of the network path, as much of it as the sync cares about. */
@interface MXTrscNetworkPath : NSObject

+ (instancetype)pathWithSatisfied:(BOOL)satisfied interfaces:(NSArray<NSString *> *)interfaces;

/** The path can carry traffic (`nw_path_status_satisfied`). */
@property (nonatomic, readonly) BOOL satisfied;
/** The interface types in use, sorted: `wifi`, `cellular`, `wired`, `loopback`, `other`. */
@property (nonatomic, readonly) NSArray<NSString *> *interfaces;
/** `wifi+cellular`, or `none` without an interface; for the log. */
@property (nonatomic, readonly) NSString *interfaceDescription;

@end

/** Where the network paths come from: `NWPathMonitor` in the app, a mock in tests. */
@protocol MXTrscNetworkPathSource <NSObject>
/** Starts the updates. The first one is the current path. The handler may be called on any queue. */
- (void)startWithHandler:(void (^)(MXTrscNetworkPath *path))handler;
- (void)cancel;
@end

/** `NWPathMonitor` (the C API of Network.framework) as a path source. */
@interface MXTrscNWPathMonitorSource : NSObject <MXTrscNetworkPathSource>
@end

/**
 TRSC: what a long-poll alone does not notice (delivery-path.md, B2).

 - A change of the network path leaves the long-poll in flight on a socket that will never answer: the request
   waits for the client timeout, up to a minute. The watch asks for a restart as soon as the path moves to
   another interface or becomes usable again. A path that becomes unusable asks for nothing: there is nowhere
   to send the new request, and the restore will ask.
 - A long-poll can also hang without any path change (NAT timeout, a dead proxy). The watchdog asks for a
   restart when a long-poll has had no answer for its server timeout + `watchdogGrace`.

 It only decides; the session cancels and resends (`onRestart`). All calls and callbacks are on the main queue.
 */
@interface MXTrscSyncNetWatch : NSObject

- (instancetype)initWithPathSource:(id<MXTrscNetworkPathSource>)pathSource NS_DESIGNATED_INITIALIZER;
- (instancetype)init NS_UNAVAILABLE;

/** Called on the main queue with the reason. The session decides whether a restart makes sense now and
 returns YES when it cancelled and resent. */
@property (nonatomic, copy, nullable) BOOL (^onRestart)(MXTrscSyncRestartReason reason);

/** Added to the server timeout of a long-poll before the watchdog fires. 10 s. */
@property (nonatomic) NSTimeInterval watchdogGrace;

/** A path change is ignored when the request in flight started less than this ago: it already went over the
 new path (the session's own reachability retry often wins the race). 1 s. */
@property (nonatomic) NSTimeInterval freshRequestInterval;

/** The last path seen, nil before the first update. */
@property (nonatomic, readonly, nullable) MXTrscNetworkPath *currentPath;

- (void)start;
- (void)stop;

/** The session sent a sync request. `serverTimeoutMs` > 0 arms the watchdog; 0 disarms it. */
- (void)syncRequestDidStartWithServerTimeout:(NSUInteger)serverTimeoutMs;

/** The request in flight answered or failed: the watchdog is disarmed. An answer after a restart for a network
 reason logs the time from the path change to it (`sync_first_response_after_restart`). */
- (void)syncRequestDidFinishWithResponse:(BOOL)gotResponse;

@end

NS_ASSUME_NONNULL_END

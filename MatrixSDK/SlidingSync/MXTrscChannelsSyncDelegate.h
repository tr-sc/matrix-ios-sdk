// Copyright 2026
// SPDX-License-Identifier: Apache-2.0

#import <Foundation/Foundation.h>

@class MXSession;

NS_ASSUME_NONNULL_BEGIN

/** Key of the TRSC channels extension in Sliding Sync requests and answers. */
FOUNDATION_EXPORT NSString *const kMXTrscChannelsSyncExtensionKey;

/**
 TRSC channels (channel-svc) ride on Sliding Sync: the request carries the `tr.sc.channels`
 extension, the answer carries the channel heads under the same key, and the request may go to
 sync-edge instead of the homeserver.

 The session asks its delegate on every request. Without a delegate, or when the delegate gives
 no extension and no base URL, the request and its handling are exactly the ones without TRSC
 channels. All methods are called on the main thread and must return fast.
 */
@protocol MXTrscChannelsSyncDelegate <NSObject>

/**
 The object to send as `extensions["tr.sc.channels"]` of the request being built now, or nil to
 send nothing. Asked for every request, never kept in the static configuration.
 */
- (nullable NSDictionary<NSString *, id> *)trscChannelsExtensionForSession:(MXSession *)session
    NS_SWIFT_NAME(trscChannelsExtension(for:));

/**
 Base URL (`https://host`, no path) of the host the request being built goes to, or nil for the
 homeserver. The request keeps the session's access token.
 */
- (nullable NSString *)trscChannelsSyncBaseURLForSession:(MXSession *)session
    NS_SWIFT_NAME(trscChannelsSyncBaseURL(for:));

/**
 The answer carried `extensions["tr.sc.channels"]`.

 @param fastPath YES when nothing but the extension moved (same `pos`, no rooms, no lists, no
 other extension): the session skipped the Matrix pipeline and stored nothing for this answer.
 */
- (void)session:(MXSession *)session didReceiveTrscChannelsExtension:(NSDictionary<NSString *, id> *)extension fastPath:(BOOL)fastPath
    NS_SWIFT_NAME(trscChannelsSession(_:didReceiveExtension:fastPath:));

/** An answer to a request that carried the extension came back without it. */
- (void)trscChannelsSessionDidReceiveAnswerWithoutExtension:(MXSession *)session
    NS_SWIFT_NAME(trscChannelsSessionDidReceiveAnswerWithoutExtension(_:));

/**
 A request sent to a base URL from `trscChannelsSyncBaseURLForSession:` was answered (`error` is
 nil) or failed. Not called for a cancelled request, for an unknown position, or while the
 network is unreachable.

 @return YES when the delegate moved to another host and the session should send the next request
 at once; NO lets the session handle the error as usual. A failure on such a host never makes the
 session fall back to `/sync`.
 */
- (BOOL)session:(MXSession *)session trscChannelsSyncRequestToBaseURL:(NSString *)baseURL didCompleteWithError:(nullable NSError *)error
    NS_SWIFT_NAME(trscChannelsSession(_:syncRequestTo:didCompleteWith:));

/** Sliding Sync is not available: the session went to `/sync` (v3) for good. */
- (void)trscChannelsSessionDidFallBackToLegacySync:(MXSession *)session
    NS_SWIFT_NAME(trscChannelsSessionDidFallBackToLegacySync(_:));

@optional

/** `homeserverWellknown` was read from the server again. */
- (void)trscChannelsSessionDidRefreshHomeserverWellknown:(MXSession *)session
    NS_SWIFT_NAME(trscChannelsSessionDidRefreshHomeserverWellknown(_:));

@end

NS_ASSUME_NONNULL_END

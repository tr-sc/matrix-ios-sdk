// Copyright 2026 TRSC contributors.
// SPDX-License-Identifier: Apache-2.0

#import "MXHTTPOperation.h"

@interface MXHTTPOperation (HTTPClient)
- (void)setHTTPCancellationHandler:(dispatch_block_t)handler;
- (void)setHTTPRetryCancellation:(dispatch_block_t)cancellation;
// Logical-request cleanup, independent of replaceable per-attempt retry timers.
- (void)setHTTPCompletionHandler:(dispatch_block_t)handler;
- (BOOL)completeHTTPRequest;
- (BOOL)isHTTPRequestComplete;
- (BOOL)hasRemainingHTTPAttempts;
@property (nonatomic, strong) NSError *lastHTTPError;
// Atomically install/resume a suspended task, or cancel it if cancellation won.
- (void)resumeHTTPTask:(NSURLSessionDataTask *)task;
@end

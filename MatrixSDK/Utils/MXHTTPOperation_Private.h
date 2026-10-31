// Copyright 2026 TRSC contributors.
// SPDX-License-Identifier: Apache-2.0

#import "MXHTTPOperation.h"

// Аренда обработки владеет одним физическим этапом. Освобождение отброшенного обратного вызова также освобождает
// его аренду; finish безопасно вызывать повторно. Физические этапы переживают логическую
// отмену; отменённое продолжение завершается, когда оно больше не может выполняться.
@interface MXHTTPProcessingLease : NSObject
- (void)finish;
@end

@interface MXHTTPOperation (HTTPClient)
- (MXHTTPProcessingLease *)beginProcessing;
- (dispatch_block_t)processingBlock:(dispatch_block_t)block;
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

/*
 Copyright 2015 OpenMarket Ltd
 Copyright 2017 Vector Creations Ltd

 Licensed under the Apache License, Version 2.0 (the "License");
 you may not use this file except in compliance with the License.
 You may obtain a copy of the License at

 http://www.apache.org/licenses/LICENSE-2.0

 Unless required by applicable law or agreed to in writing, software
 distributed under the License is distributed on an "AS IS" BASIS,
 WITHOUT WARRANTIES OR CONDITIONS OF ANY KIND, either express or implied.
 See the License for the specific language governing permissions and
 limitations under the License.
 */

#import "MXHTTPOperation.h"
#import "MXHTTPOperation_Private.h"

#import <AFNetworking/AFNetworking.h>
#import "MXError.h"

#pragma mark - Constants definitions

/**
 The default max attempts.
 */
#define MXHTTPOPERATION_DEFAULT_MAX_RETRIES 4

/**
 The default max time a request can be retried.
 */
#define MXHTTPOPERATION_DEFAULT_MAX_TIME_MS 180000


@interface MXHTTPOperation ()
{
    NSDate *creationDate;
    MXHTTPOperation *chainedOperation;
    dispatch_block_t cancellationHandler;
    dispatch_block_t retryCancellation;
    dispatch_block_t completionHandler;
    BOOL httpComplete;
    NSUInteger processingCount;
    NSMutableArray<MXHTTPOperation *> *processingChildren;
}
@property (nonatomic, strong) NSError *lastHTTPError;
- (void)finishProcessing;
@end

@interface MXHTTPProcessingLease ()
@property (nonatomic, strong) MXHTTPOperation *owner;
@end

@implementation MXHTTPProcessingLease
- (void)finish
{
    MXHTTPOperation *owner;
    @synchronized (self) { owner = _owner; _owner = nil; }
    [owner finishProcessing];
}
- (void)dealloc { [self finish]; }
@end

@implementation MXHTTPOperation

@synthesize operation = _operation;
@synthesize canceled = _canceled;
@synthesize maxTotalAttempts = _maxTotalAttempts;
@synthesize lastHTTPError = _lastHTTPError;

- (MXHTTPProcessingLease *)beginProcessing
{
    MXHTTPProcessingLease *lease = [MXHTTPProcessingLease new];
    @synchronized (self) { processingCount++; }
    lease.owner = self;
    return lease;
}

- (void)finishProcessing
{
    @synchronized (self) { NSAssert(processingCount, @"Unbalanced processing lease"); processingCount--; }
}

- (dispatch_block_t)processingBlock:(dispatch_block_t)block
{
    MXHTTPProcessingLease *lease = [self beginProcessing];
    return ^{ @try { if (block) block(); } @finally { [lease finish]; } };
}

- (BOOL)hasPendingProcessing
{
    NSArray<MXHTTPOperation *> *children;
    BOOL pending;
    @synchronized (self) { pending = processingCount != 0; children = [processingChildren copy]; }
    for (MXHTTPOperation *child in children)
    {
        if (child.hasPendingProcessing) pending = YES;
        else if (child.isHTTPRequestComplete)
        {
            // Завершённая дочерняя HTTP-операция не может запланировать новую попытку. Её продолжения
            // SDK в очереди удерживают аренды обработки до доставки завершения HTTP.
            @synchronized (self) { [processingChildren removeObjectIdenticalTo:child]; }
        }
    }
    return pending;
}

- (NSNumber *)maxTotalAttempts { @synchronized (self) { return _maxTotalAttempts; } }
- (void)setMaxTotalAttempts:(NSNumber *)limit
{
    NSParameterAssert(!limit || (limit.doubleValue >= 1 && limit.doubleValue == limit.unsignedIntegerValue));
    @synchronized (self) { _maxTotalAttempts = [limit copy]; }
}
- (BOOL)hasRemainingHTTPAttempts
{
    @synchronized (self) { return !_maxTotalAttempts || _numberOfTries < _maxTotalAttempts.unsignedIntegerValue; }
}

- (instancetype)init
{
    self = [super init];
    if (self)
    {
        creationDate = [NSDate date];
        _numberOfTries = 0;
        _maxNumberOfTries = MXHTTPOPERATION_DEFAULT_MAX_RETRIES;
        _maxRetriesTime = MXHTTPOPERATION_DEFAULT_MAX_TIME_MS;
        _canceled = NO;
        processingChildren = [NSMutableArray array];
    }
    return self;
}

- (void)cancel
{
    NSURLSessionDataTask *task;
    NSArray<MXHTTPOperation *> *children;
    dispatch_block_t handler;
    @synchronized (self)
    {
        if (_canceled) return;
        _maxNumberOfTries = 0;
        _maxRetriesTime = 0;
        _canceled = YES;
        _httpResponse = nil;
        task = _operation;
        _operation = nil;
        children = [processingChildren copy];
        chainedOperation = nil;
        handler = cancellationHandler;
        cancellationHandler = nil;
    }
    // No callbacks or traversal of other operations while holding our lock.
    [task cancel];
    for (MXHTTPOperation *child in children) [child cancel];
    if (handler) handler();
}

- (BOOL)isCancelled { @synchronized (self) { return _canceled; } }
- (NSURLSessionDataTask *)operation { @synchronized (self) { return _operation; } }
- (void)setOperation:(NSURLSessionDataTask *)task
{
    BOOL cancelled;
    @synchronized (self)
    {
        cancelled = _canceled || httpComplete;
        if (!cancelled) _operation = task;
    }
    if (cancelled) [task cancel];
}

- (void)resumeHTTPTask:(NSURLSessionDataTask *)task
{
    @synchronized (self)
    {
        if (!_canceled && !httpComplete)
        {
            _operation = task;
            _numberOfTries++;
            // URLSession delivers callbacks asynchronously. Cancellation and
            // starting the task must have one ordering, not a check/resume gap.
            [task resume];
            return;
        }
    }
    [task cancel];
}

- (void)setHTTPCancellationHandler:(dispatch_block_t)handler
{
    BOOL cancelled;
    @synchronized (self)
    {
        if (httpComplete) return;
        cancelled = _canceled;
        if (!cancelled) cancellationHandler = [handler copy];
    }
    if (cancelled && handler) handler();
}

- (void)setHTTPRetryCancellation:(dispatch_block_t)cancellation
{
    dispatch_block_t previous;
    BOOL finished;
    @synchronized (self)
    {
        previous = retryCancellation;
        finished = _canceled || httpComplete;
        retryCancellation = finished ? nil : [cancellation copy];
    }
    if (previous) previous();
    if (finished && cancellation) cancellation();
}

- (BOOL)completeHTTPRequest
{
    dispatch_block_t cleanup;
    dispatch_block_t completed;
    @synchronized (self)
    {
        if (httpComplete) return NO;
        httpComplete = YES;
        cancellationHandler = nil;
        cleanup = retryCancellation;
        retryCancellation = nil;
        completed = completionHandler;
        completionHandler = nil;
        _operation = nil;
    }
    if (cleanup) cleanup();
    if (completed) completed();
    return YES;
}

- (void)setHTTPCompletionHandler:(dispatch_block_t)handler
{
    BOOL finished;
    @synchronized (self)
    {
        finished = httpComplete;
        if (!finished) completionHandler = [handler copy];
    }
    if (finished && handler) handler();
}

- (BOOL)isHTTPRequestComplete { @synchronized (self) { return httpComplete; } }

- (NSUInteger)age
{
    return [[NSDate date] timeIntervalSinceDate:creationDate] * 1000;
}

- (void)mutateTo:(MXHTTPOperation *)operation
{
    if (!operation || operation == self)
    {
        return;
    }
    
    BOOL cancelled;
    // Serialize link changes (not HTTP work) so concurrent A->B / B->A cannot
    // создать цикл удержания, в том числе через предыдущие дочерние операции, обработка которых ещё завершается.
    @synchronized (MXHTTPOperation.class)
    {
        NSMutableArray<MXHTTPOperation *> *pending = [NSMutableArray arrayWithObject:operation];
        NSHashTable *visited = [NSHashTable hashTableWithOptions:NSPointerFunctionsObjectPointerPersonality];
        while (pending.count)
        {
            MXHTTPOperation *cursor = pending.lastObject;
            [pending removeLastObject];
            if (cursor == self) return;
            if ([visited containsObject:cursor]) continue;
            [visited addObject:cursor];
            @synchronized (cursor)
            {
                [pending addObjectsFromArray:cursor->processingChildren];
                if (cursor->chainedOperation) [pending addObject:cursor->chainedOperation];
            }
        }
        NSURLSessionDataTask *task = operation.operation;
        @synchronized (self)
        {
            cancelled = _canceled;
            if (![processingChildren containsObject:operation]) [processingChildren addObject:operation];
            chainedOperation = cancelled ? nil : operation;
            _operation = cancelled ? nil : task;
            creationDate = operation->creationDate;
            _numberOfTries = operation.numberOfTries;
            _maxNumberOfTries = cancelled ? 0 : operation.maxNumberOfTries;
            _maxTotalAttempts = operation.maxTotalAttempts;
            _maxRetriesTime = cancelled ? 0 : operation.maxRetriesTime;
            _httpResponse = cancelled ? nil : operation.httpResponse;
        }
    }
    if (cancelled)
    {
        [operation cancel];
    }
}

+ (NSHTTPURLResponse *)urlResponseFromError:(NSError*)error
{
    NSHTTPURLResponse *response;
    if ([MXError isMXError:error])
    {
        MXError *mxError = [[MXError alloc] initWithNSError:error];
        response = mxError.httpResponse;
    }
    else
    {
        response = error.userInfo[AFNetworkingOperationFailingURLResponseErrorKey];
    }
    return response;
}

@end

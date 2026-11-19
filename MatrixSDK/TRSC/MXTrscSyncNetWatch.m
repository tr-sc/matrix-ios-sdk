// Copyright 2026
// SPDX-License-Identifier: Apache-2.0

#import "MXTrscSyncNetWatch.h"

#import <Network/Network.h>
#import <QuartzCore/QuartzCore.h>

#import "MXLog.h"

MXTrscSyncRestartReason const MXTrscSyncRestartReasonNetworkChange = @"network_change";
MXTrscSyncRestartReason const MXTrscSyncRestartReasonNetworkRestored = @"network_restored";
MXTrscSyncRestartReason const MXTrscSyncRestartReasonWatchdog = @"watchdog";
MXTrscSyncRestartReason const MXTrscSyncRestartReasonApp = @"app";
MXTrscSyncRestartReason const MXTrscSyncRestartReasonSubscription = @"subscription";

#pragma mark - MXTrscNetworkPath

@implementation MXTrscNetworkPath

+ (instancetype)pathWithSatisfied:(BOOL)satisfied interfaces:(NSArray<NSString *> *)interfaces
{
    MXTrscNetworkPath *path = [self new];
    path->_satisfied = satisfied;
    path->_interfaces = [[NSSet setWithArray:interfaces].allObjects sortedArrayUsingSelector:@selector(compare:)];
    return path;
}

- (NSString *)interfaceDescription
{
    return self.interfaces.count ? [self.interfaces componentsJoinedByString:@"+"] : @"none";
}

- (BOOL)isEqual:(id)object
{
    if (![object isKindOfClass:MXTrscNetworkPath.class]) return NO;
    MXTrscNetworkPath *other = object;
    return other.satisfied == self.satisfied && [other.interfaces isEqualToArray:self.interfaces];
}

- (NSUInteger)hash
{
    return self.interfaces.hash ^ (NSUInteger)self.satisfied;
}

- (NSString *)description
{
    return [NSString stringWithFormat:@"%@/%@", self.satisfied ? @"satisfied" : @"unsatisfied", self.interfaceDescription];
}

@end

#pragma mark - MXTrscNWPathMonitorSource

@implementation MXTrscNWPathMonitorSource
{
    nw_path_monitor_t _monitor;
}

- (void)startWithHandler:(void (^)(MXTrscNetworkPath *))handler
{
    [self cancel];
    nw_path_monitor_t monitor = nw_path_monitor_create();
    nw_path_monitor_set_queue(monitor, dispatch_get_global_queue(QOS_CLASS_UTILITY, 0));
    nw_path_monitor_set_update_handler(monitor, ^(nw_path_t path) {
        BOOL satisfied = nw_path_get_status(path) == nw_path_status_satisfied;
        NSMutableArray<NSString *> *interfaces = [NSMutableArray array];
        nw_path_enumerate_interfaces(path, ^bool(nw_interface_t interface) {
            switch (nw_interface_get_type(interface))
            {
                case nw_interface_type_wifi: [interfaces addObject:@"wifi"]; break;
                case nw_interface_type_cellular: [interfaces addObject:@"cellular"]; break;
                case nw_interface_type_wired: [interfaces addObject:@"wired"]; break;
                case nw_interface_type_loopback: [interfaces addObject:@"loopback"]; break;
                default: [interfaces addObject:@"other"]; break;
            }
            return true;
        });
        handler([MXTrscNetworkPath pathWithSatisfied:satisfied interfaces:interfaces]);
    });
    nw_path_monitor_start(monitor);
    _monitor = monitor;
}

- (void)cancel
{
    if (_monitor) nw_path_monitor_cancel(_monitor);
    _monitor = nil;
}

- (void)dealloc
{
    [self cancel];
}

@end

#pragma mark - MXTrscSyncNetWatch

@interface MXTrscSyncNetWatch ()
@property (nonatomic, strong) id<MXTrscNetworkPathSource> pathSource;
@property (nonatomic, readwrite, nullable) MXTrscNetworkPath *currentPath;
@property (nonatomic) BOOL started;
/** Bumped by every start, stop, sent request and answer: a watchdog timer fires only for its own request. */
@property (nonatomic) NSUInteger requestGeneration;
@property (nonatomic) BOOL requestInFlight;
@property (nonatomic) CFTimeInterval requestStartedAt;
/** A restart whose first answer is still awaited: its reason and when its cause happened. */
@property (nonatomic, copy, nullable) MXTrscSyncRestartReason measuredReason;
@property (nonatomic) CFTimeInterval measuredSince;
@end

@implementation MXTrscSyncNetWatch

- (instancetype)initWithPathSource:(id<MXTrscNetworkPathSource>)pathSource
{
    self = [super init];
    if (self)
    {
        _pathSource = pathSource;
        _watchdogGrace = 10;
        _freshRequestInterval = 1;
    }
    return self;
}

- (void)start
{
    if (self.started) return;
    self.started = YES;
    __weak typeof(self) weakSelf = self;
    [self.pathSource startWithHandler:^(MXTrscNetworkPath *path) {
        dispatch_async(dispatch_get_main_queue(), ^{
            [weakSelf handlePath:path];
        });
    }];
}

- (void)stop
{
    if (!self.started) return;
    self.started = NO;
    [self.pathSource cancel];
    self.currentPath = nil;
    self.requestInFlight = NO;
    self.requestGeneration++;
    self.measuredReason = nil;
}

- (void)dealloc
{
    [_pathSource cancel];
}

#pragma mark Path

- (void)handlePath:(MXTrscNetworkPath *)path
{
    if (!self.started) return;
    MXTrscNetworkPath *previous = self.currentPath;
    self.currentPath = path;
    // The first update is the path the app started on: nothing changed.
    if (!previous || [previous isEqual:path]) return;

    MXLogDebug(@"[MXTrscSyncNetWatch] network path %@ -> %@", previous, path);
    if (!path.satisfied) return;
    MXTrscSyncRestartReason reason = previous.satisfied ? MXTrscSyncRestartReasonNetworkChange : MXTrscSyncRestartReasonNetworkRestored;

    CFTimeInterval now = CACurrentMediaTime();
    self.measuredReason = reason;
    self.measuredSince = now;
    if (self.requestInFlight && now - self.requestStartedAt < self.freshRequestInterval)
    {
        MXLogDebug(@"[MXTrscSyncNetWatch] sync_restart_skipped reason=%@ path=%@ request_age_ms=%.0f",
                   reason, path.interfaceDescription, (now - self.requestStartedAt) * 1000);
        return;
    }
    [self requestRestartWithReason:reason];
}

#pragma mark Watchdog

- (void)syncRequestDidStartWithServerTimeout:(NSUInteger)serverTimeoutMs
{
    NSUInteger generation = ++self.requestGeneration;
    self.requestInFlight = YES;
    self.requestStartedAt = CACurrentMediaTime();
    if (!self.started || serverTimeoutMs == 0) return;

    NSTimeInterval deadline = serverTimeoutMs / 1000.0 + self.watchdogGrace;
    __weak typeof(self) weakSelf = self;
    dispatch_after(dispatch_time(DISPATCH_TIME_NOW, (int64_t)(deadline * NSEC_PER_SEC)), dispatch_get_main_queue(), ^{
        MXTrscSyncNetWatch *strongSelf = weakSelf;
        if (!strongSelf || !strongSelf.started || !strongSelf.requestInFlight || strongSelf.requestGeneration != generation) return;
        MXLogWarning(@"[MXTrscSyncNetWatch] long-poll silent for %.0f s (server timeout %tu ms)", deadline, serverTimeoutMs);
        strongSelf.measuredReason = MXTrscSyncRestartReasonWatchdog;
        strongSelf.measuredSince = CACurrentMediaTime();
        [strongSelf requestRestartWithReason:MXTrscSyncRestartReasonWatchdog];
    });
}

- (void)syncRequestDidFinishWithResponse:(BOOL)gotResponse
{
    self.requestGeneration++;
    self.requestInFlight = NO;
    if (!gotResponse || !self.measuredReason) return;
    MXLogDebug(@"[MXTrscSyncNetWatch] sync_first_response_after_restart reason=%@ ms=%.0f path=%@",
               self.measuredReason, (CACurrentMediaTime() - self.measuredSince) * 1000,
               self.currentPath.interfaceDescription ?: @"unknown");
    self.measuredReason = nil;
}

#pragma mark Restart

- (void)requestRestartWithReason:(MXTrscSyncRestartReason)reason
{
    BOOL restarted = self.onRestart ? self.onRestart(reason) : NO;
    // Nothing was resent (paused, closed, a background sync): no first answer to wait for.
    if (!restarted) self.measuredReason = nil;
}

@end

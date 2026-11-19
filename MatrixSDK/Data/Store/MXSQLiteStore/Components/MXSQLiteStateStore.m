//
// Copyright 2026 TRSC contributors.
// SPDX-License-Identifier: Apache-2.0
//

#import "MXSQLiteStateStore.h"

@implementation MXSQLiteStateStore

- (instancetype)initWithContext:(MXSQLiteStoreContext *)context
{
    return [super init];
}

- (void)storeStateForRoom:(NSString *)roomId stateEvents:(NSArray<MXEvent *> *)stateEvents {}

- (void)stateOfRoom:(NSString *)roomId success:(void (^)(NSArray<MXEvent *> *))success failure:(void (^)(NSError *))failure
{
    dispatch_async(dispatch_get_main_queue(), ^{ success(@[]); });
}

- (void)storeAccountDataForRoom:(NSString *)roomId userData:(MXRoomAccountData *)accountData {}
- (MXRoomAccountData *)accountDataOfRoom:(NSString *)roomId { return nil; }

- (void)storePaginationTokenOfRoom:(NSString *)roomId andToken:(NSString *)token {}
- (NSString *)paginationTokenOfRoom:(NSString *)roomId { return nil; }
- (void)storeHasReachedHomeServerPaginationEndForRoom:(NSString *)roomId andValue:(BOOL)value {}
- (BOOL)hasReachedHomeServerPaginationEndForRoom:(NSString *)roomId { return NO; }
- (void)storeBackwardPaginationStateForRoom:(NSString *)roomId state:(MXRoomBackwardPaginationState)state {}
- (MXRoomBackwardPaginationState)backwardPaginationStateForRoom:(NSString *)roomId { return MXRoomBackwardPaginationStateUnknown; }
- (void)storeHasLoadedAllRoomMembersForRoom:(NSString *)roomId andValue:(BOOL)value {}
- (BOOL)hasLoadedAllRoomMembersForRoom:(NSString *)roomId { return NO; }

@end

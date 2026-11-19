//
// Copyright 2026 TRSC contributors.
// SPDX-License-Identifier: Apache-2.0
//

#import "MXSQLiteReceiptStore.h"

@implementation MXSQLiteReceiptStore

- (instancetype)initWithContext:(MXSQLiteStoreContext *)context
{
    return [super init];
}

- (void)getEventReceipts:(NSString *)roomId eventId:(NSString *)eventId threadId:(NSString *)threadId sorted:(BOOL)sort completion:(void (^)(NSArray<MXReceiptData *> *))completion
{
    dispatch_async(dispatch_get_main_queue(), ^{ completion(@[]); });
}

- (BOOL)storeReceipt:(MXReceiptData *)receipt inRoom:(NSString *)roomId { return NO; }
- (NSDictionary<NSString *, MXReceiptData *> *)getReceiptsInRoom:(NSString *)roomId forUserId:(NSString *)userId { return @{}; }
- (MXReceiptData *)getReceiptInRoom:(NSString *)roomId threadId:(NSString *)threadId forUserId:(NSString *)userId { return nil; }

- (void)loadReceiptsForRoom:(NSString *)roomId completion:(void (^)(void))completion
{
    // Квитанции читаются запросом, прогревать нечего (ADR-0022).
    if (completion)
    {
        dispatch_async(dispatch_get_main_queue(), completion);
    }
}

- (void)setUnreadForRoom:(NSString *)roomId {}
- (void)resetUnreadForRoom:(NSString *)roomId {}
- (BOOL)isRoomMarkedAsUnread:(NSString *)roomId { return NO; }

@end

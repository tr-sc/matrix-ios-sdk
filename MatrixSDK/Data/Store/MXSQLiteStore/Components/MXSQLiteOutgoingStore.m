//
// Copyright 2026 TRSC contributors.
// SPDX-License-Identifier: Apache-2.0
//

#import "MXSQLiteOutgoingStore.h"

@implementation MXSQLiteOutgoingStore

- (instancetype)initWithContext:(MXSQLiteStoreContext *)context
{
    return [super init];
}

- (void)storeOutgoingMessageForRoom:(NSString *)roomId outgoingMessage:(MXEvent *)outgoingMessage {}
- (void)removeAllOutgoingMessagesFromRoom:(NSString *)roomId {}
- (void)removeOutgoingMessageFromRoom:(NSString *)roomId outgoingMessage:(NSString *)outgoingMessageEventId {}
- (NSArray<MXEvent *> *)outgoingMessagesInRoom:(NSString *)roomId { return @[]; }

- (void)storePartialAttributedTextMessageForRoom:(NSString *)roomId partialAttributedTextMessage:(NSAttributedString *)partialAttributedTextMessage {}
- (NSAttributedString *)partialAttributedTextMessageOfRoom:(NSString *)roomId { return nil; }

- (NSString *)consumeOutgoingForTransactionId:(NSString *)transactionId inRoom:(NSString *)roomId { return nil; }

@end

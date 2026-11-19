//
// Copyright 2026 TRSC contributors.
// SPDX-License-Identifier: Apache-2.0
//

#import "MXSQLiteStoreComponent.h"

#import "MXSQLiteDatabase.h"

@interface MXSQLiteCommitContext ()
@property (nonatomic, readonly) NSMutableSet<NSString *> *rooms;
@end

@implementation MXSQLiteCommitContext

- (instancetype)init
{
    self = [super init];
    if (self)
    {
        _rooms = [NSMutableSet set];
    }
    return self;
}

- (void)touchRoomId:(NSString *)roomId
{
    [_rooms addObject:roomId];
}

- (void)countEvents:(NSUInteger)count
{
    _eventCount += count;
}

- (NSSet<NSString *> *)touchedRoomIds
{
    return [_rooms copy];
}

@end

@implementation MXSQLiteStoreContext

- (instancetype)initWithRooms:(MXSQLiteRoomRegistry *)rooms
{
    self = [super init];
    if (self)
    {
        _rooms = rooms;
    }
    return self;
}

- (BOOL)readOnly
{
    return self.database.readOnly;
}

@end

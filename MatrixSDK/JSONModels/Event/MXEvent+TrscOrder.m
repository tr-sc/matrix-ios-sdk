//
// Copyright 2026 TRSC contributors.
// SPDX-License-Identifier: Apache-2.0
//

#import "MXEvent+TrscOrder.h"

#import "MXEventUnsignedData.h"

@implementation MXEvent (TrscOrder)

- (BOOL)hasTrscOrder
{
    int64_t order;
    return [MXEvent trscOrderFromCount:self.unsignedData.trscCount order:&order];
}

- (int64_t)trscOrder
{
    int64_t order = 0;
    return [MXEvent trscOrderFromCount:self.unsignedData.trscCount order:&order] ? order : 0;
}

+ (BOOL)trscOrderFromCount:(NSString *)count order:(int64_t *)order
{
    NSUInteger length = count.length;
    if (length == 0 || length > 20)
    {
        return NO;
    }

    char buffer[22];
    if (![count getCString:buffer maxLength:sizeof(buffer) encoding:NSASCIIStringEncoding])
    {
        return NO;
    }

    // strtoll сам пропускает пробелы и принимает «+»: сервер такого не шлёт, а значит это не его номер.
    const char first = buffer[0];
    if (!(first == '-' || (first >= '0' && first <= '9')))
    {
        return NO;
    }

    char *end = NULL;
    errno = 0;
    long long value = strtoll(buffer, &end, 10);
    if (errno == ERANGE || end == buffer || *end != '\0' || (first == '-' && length == 1))
    {
        return NO;
    }

    *order = (int64_t)value;
    return YES;
}

@end

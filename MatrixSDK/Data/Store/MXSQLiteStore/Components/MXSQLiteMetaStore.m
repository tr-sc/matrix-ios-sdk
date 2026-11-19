//
// Copyright 2026 TRSC contributors.
// SPDX-License-Identifier: Apache-2.0
//

#import "MXSQLiteMetaStore.h"

@implementation MXSQLiteMetaStore

// Заглушка держит значения в памяти: сессии нужен токен синка и well-known в пределах запуска.
@synthesize eventStreamToken, userAccountData, areAllIdentityServerTermsAgreed, syncFilterId;
@synthesize homeserverWellknown, homeserverCapabilities, supportedMatrixVersions, authMetadata, maxUploadSize;

- (instancetype)initWithContext:(MXSQLiteStoreContext *)context
{
    self = [super init];
    if (self)
    {
        maxUploadSize = -1;
    }
    return self;
}

- (void)storeHomeserverWellknown:(MXWellKnown *)wellknown { homeserverWellknown = wellknown; }
- (void)storeHomeserverCapabilities:(MXCapabilities *)capabilities { homeserverCapabilities = capabilities; }
- (void)storeSupportedMatrixVersions:(MXMatrixVersions *)versions { supportedMatrixVersions = versions; }
- (void)storeAuthMetadata:(MXAuthMetadata *)metadata { authMetadata = metadata; }
- (void)storeMaxUploadSize:(NSInteger)size { maxUploadSize = size; }

- (void)storeUser:(MXUser *)user {}
- (NSArray<MXUser *> *)users { return @[]; }
- (MXUser *)userWithUserId:(NSString *)userId { return nil; }

- (void)storeGroup:(MXGroup *)group {}
- (NSArray<MXGroup *> *)groups { return @[]; }
- (MXGroup *)groupWithGroupId:(NSString *)groupId { return nil; }
- (void)deleteGroup:(NSString *)groupId {}

- (void)storeFilter:(MXFilterJSONModel *)filter withFilterId:(NSString *)filterId {}
- (NSArray<NSString *> *)allFilterIds { return @[]; }

- (void)filterWithFilterId:(NSString *)filterId success:(void (^)(MXFilterJSONModel *))success failure:(void (^)(NSError *))failure
{
    dispatch_async(dispatch_get_main_queue(), ^{ success(nil); });
}

- (void)filterIdForFilter:(MXFilterJSONModel *)filter success:(void (^)(NSString *))success failure:(void (^)(NSError *))failure
{
    dispatch_async(dispatch_get_main_queue(), ^{ success(nil); });
}

- (void)didDeleteAllData
{
    eventStreamToken = nil;
    userAccountData = nil;
    syncFilterId = nil;
    homeserverWellknown = nil;
    homeserverCapabilities = nil;
    supportedMatrixVersions = nil;
    authMetadata = nil;
    maxUploadSize = -1;
}

@end

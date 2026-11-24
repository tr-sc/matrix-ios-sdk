//
// Copyright 2026 TRSC contributors.
// SPDX-License-Identifier: Apache-2.0
//

#import <Foundation/Foundation.h>

@class MXSQLiteDatabase;
@class MXSQLiteStore;
@protocol MXSQLiteKeyProviding;

NS_ASSUME_NONNULL_BEGIN

/**
 Открытие базы аккаунта для `MXSQLiteStore` с самовосстановлением: чужой ключ или битый файл — база и ключ
 пересоздаются; временный отказ и отказ без SQLCipher — база не трогается. Исход уходит в `metricsDelegate` стора.
 */
@interface MXSQLiteStoreOpener : NSObject

- (instancetype)initWithStore:(MXSQLiteStore *)store
                  keyProvider:(id<MXSQLiteKeyProviding>)keyProvider
                rootDirectory:(NSURL *)rootDirectory
                  readerCount:(NSUInteger)readerCount;

- (instancetype)init NS_UNAVAILABLE;

- (nullable MXSQLiteDatabase *)openDatabaseForUserId:(NSString *)userId error:(NSError **)error;

@end

NS_ASSUME_NONNULL_END

//
// Copyright 2026 TRSC contributors.
// SPDX-License-Identifier: Apache-2.0
//

#import <Foundation/Foundation.h>

@class MXSQLiteStore;
@class MXCredentials;

NS_ASSUME_NONNULL_BEGIN

/// Что перенесено.
@interface MXSQLiteLegacyImportResult : NSObject
/// YES — перенос уже был (отметка в `meta`) или папки MXFileStore нет: ничего не делали.
@property (nonatomic, readonly) BOOL skipped;
@property (nonatomic, readonly) NSUInteger outgoingCount;
@property (nonatomic, readonly) NSUInteger draftCount;
@property (nonatomic, readonly) NSUInteger roomCount;
/// YES только если данные и маркер миграции подтверждены одной долговечной транзакцией.
@property (nonatomic, readonly) BOOL succeeded;
@property (nonatomic, readonly, nullable) NSError *error;
@end

/**
 Одноразовый перенос того, чего нет на сервере, из `MXFileStore` в `MXSQLiteStore` при переключении (ADR-0022 §1.14,
 решение владельца: история не переносится, черновики и неотправленные — переносятся).

 Читает только `rooms/<roomId>/outgoingMessages` и черновик из `rooms/<roomId>/messages` (сам архив комнаты не
 разворачивается: вместо `MXFileRoomStore` подставляется класс, который декодирует один ключ). Пишет через API стора
 и сразу сбрасывает на диск одной транзакцией вместе с отметкой «сделано» — повторный вызов ничего не делает.

 Звать после `openWithCredentials:` нового стора и до удаления папки MXFileStore (`TrscStoreSwitch`, iP9).
 Синхронно, вне main: на больших архивах комнат это сотни миллисекунд.
 */
@interface MXSQLiteLegacyImport : NSObject

/// Папка `MXFileStore` аккаунта: `<app group или Caches>/MXFileStore/<userId>`.
+ (NSURL *)fileStoreURLForUserId:(NSString *)userId;

+ (MXSQLiteLegacyImportResult *)importFromFileStoreAtURL:(NSURL *)fileStoreURL intoStore:(MXSQLiteStore *)store
    NS_SWIFT_NAME(importFromFileStore(at:into:));

/// Экспортировать локальные черновики и исходящие сообщения обратно в MXFileStore перед откатом флага.
+ (BOOL)exportLocalOnlyDataFromStore:(MXSQLiteStore *)store
                     toFileStoreAtURL:(NSURL *)fileStoreURL
                          credentials:(MXCredentials *)credentials
                                error:(NSError **)error
    NS_SWIFT_NAME(exportLocalOnlyData(from:toFileStoreAt:credentials:));

@end

NS_ASSUME_NONNULL_END

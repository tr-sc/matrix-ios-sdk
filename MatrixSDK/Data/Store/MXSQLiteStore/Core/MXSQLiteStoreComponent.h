//
// Copyright 2026 TRSC contributors.
// SPDX-License-Identifier: Apache-2.0
//

#import <Foundation/Foundation.h>

#import "MXTimelineStore.h"

@class MXSQLiteDatabase, MXSQLiteConnection, MXSQLiteRoomRegistry, MXCredentials;
@protocol MXSQLiteOutgoingStoring;

NS_ASSUME_NONNULL_BEGIN

/**
 Учёт одной транзакции коммита: какие комнаты затронуты (им `revision++` и строка в `MXStoreDidCommitNotification`)
 и сколько событий записано (метрика `store_commit`).
 */
@interface MXSQLiteCommitContext : NSObject
- (void)touchRoomId:(NSString *)roomId;
- (void)countEvents:(NSUInteger)count;
@property (nonatomic, readonly) NSSet<NSString *> *touchedRoomIds;
@property (nonatomic, readonly) NSUInteger eventCount;
@end

/// Часть транзакции коммита от одного компонента. Выполняется на очереди писателя. NO — откат всей транзакции.
typedef BOOL (^MXSQLiteCommitBody)(MXSQLiteConnection *connection, MXSQLiteCommitContext *commit, NSError **error);

/**
 Общее для компонентов одного `MXSQLiteStore`: база, реестр комнат, учётная запись, соседи.
 */
@interface MXSQLiteStoreContext : NSObject
- (instancetype)initWithRooms:(MXSQLiteRoomRegistry *)rooms NS_DESIGNATED_INITIALIZER;
- (instancetype)init NS_UNAVAILABLE;

/// nil до `openWithCredentials:` и после `deleteAllData` / `close`: компонент обязан это переживать — чтение
/// пустое, запись остаётся в накладке. Так же ведёт себя `MXFileStore` до открытия. Меняет только фасад.
@property (atomic, nullable) MXSQLiteDatabase *database;
@property (nonatomic, readonly) MXSQLiteRoomRegistry *rooms;
/// nil до открытия. Меняет только фасад.
@property (atomic, nullable) MXCredentials *credentials;
@property (nonatomic, readonly) BOOL readOnly;
/// Фасад — для `MXStoreMetricsDelegate` и уведомлений.
@property (nonatomic, weak, nullable) id<MXTimelineStore> store;
/// Исходящие: событию из синка с `unsigned.transaction_id` компонент событий зовёт
/// `consumeOutgoingForTransactionId:inRoom:` — эхо и серверное событие становятся одной строкой в одном коммите.
@property (nonatomic, weak, nullable) id<MXSQLiteOutgoingStoring> outgoing;
@end

/**
 Компонент `MXSQLiteStore`. Фасад сам ничего не хранит: методы `MXStore` / `MXTimelineStore` уходят тому
 компоненту, чей протокол (`MXSQLiteStoreComponents.h`) их объявляет.

 Запись — накладкой: метод записи меняет память компонента и сразу виден чтению; на `commit` фасад собирает
 `takePendingWrites` всех компонентов и пишет их **одной транзакцией** (события, дыры, токен синка, исходящие вместе).
 */
@protocol MXSQLiteStoreComponent <NSObject>

- (instancetype)initWithContext:(MXSQLiteStoreContext *)context;

@optional

/// Забрать накопленное для коммита. Поток вызывающего `commit`. nil — писать нечего.
/// Накладка остаётся видимой для чтения до `didFinishPendingWrites:`.
- (nullable MXSQLiteCommitBody)takePendingWrites;

/// Транзакция с этим телом закончилась (очередь писателя). NO — откат: тело вернуть в накладку и повторить на
/// следующем коммите.
- (void)didFinishPendingWrites:(BOOL)committed;

/// Комната удаляется: забыть её в накладке и кешах. Строки таблиц удаляет фасад в следующем коммите.
- (void)willDeleteRoom:(NSString *)roomId;

/// Все данные удалены (файл снесён): забыть всё.
- (void)didDeleteAllData;

@end

NS_ASSUME_NONNULL_END

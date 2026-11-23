//
// Copyright 2026 TRSC contributors.
// SPDX-License-Identifier: Apache-2.0
//

#import <Foundation/Foundation.h>

#import "MXSQLiteStoreComponent.h"
#import "MXStore.h"
#import "MXTimelineStore.h"

@class MXSQLiteConnection;

/**
 Раскладка `MXStore` + `MXTimelineStore` по компонентам `MXSQLiteStore` (ADR-0022, пакеты iP2–iP5).

 Фасад маршрутизирует метод тому компоненту, чей протокол ниже его объявляет. Метод, которого нет ни в одном
 протоколе и который не реализует сам фасад, — ошибка; её ловит `MXSQLiteStoreFacadeTests`.

 Владельцы файлов: события — iP2, состояние и мета — iP3, квитанции и исходящие — iP4, сводки — iP5.
 До них компоненты — заглушки из iP1: чтение пустое, запись принимается и забывается.
 */

#pragma mark - События, дыры, перечислители (iP2: MXSQLiteEventStore.m)

@protocol MXSQLiteEventStoring <MXSQLiteStoreComponent>

@property (nonatomic, readonly, nonnull) NSArray<NSString*> *roomIds;

- (void)storeEventForRoom:(nonnull NSString*)roomId event:(nonnull MXEvent*)event direction:(MXTimelineDirection)direction;
- (void)replaceEvent:(nonnull MXEvent*)event inRoom:(nonnull NSString*)roomId;
- (BOOL)eventExistsWithEventId:(nonnull NSString*)eventId inRoom:(nonnull NSString*)roomId;
- (MXEvent* _Nullable)eventWithEventId:(nonnull NSString*)eventId inRoom:(nonnull NSString*)roomId;
- (void)deleteAllMessagesInRoom:(nonnull NSString *)roomId;
- (void)loadRoomMessagesForRoom:(nonnull NSString *)roomId completion:(nullable void (^)(void))completion;

- (id<MXEventsEnumerator> _Nonnull)messagesEnumeratorForRoom:(nonnull NSString*)roomId;
- (id<MXEventsEnumerator> _Nonnull)messagesEnumeratorForRoom:(nonnull NSString*)roomId withTypeIn:(nullable NSArray*)types;
- (NSArray<MXEvent*>* _Nonnull)relationsForEvent:(nonnull NSString*)eventId inRoom:(nonnull NSString*)roomId relationType:(nonnull NSString*)relationType;

- (NSUInteger)localUnreadEventCount:(nonnull NSString*)roomId threadId:(nullable NSString*)threadId withTypeIn:(nullable NSArray*)types;
- (nonnull NSDictionary <NSString *, NSNumber *> *)localUnreadEventCountPerThread:(nonnull NSString*)roomId withTypeIn:(nullable NSArray*)types;
- (nonnull NSArray<MXEvent*>*)newIncomingEventsInRoom:(nonnull NSString*)roomId
                                             threadId:(nullable NSString*)threadId
                                           withTypeIn:(nullable NSArray<MXEventTypeString>*)types;

- (BOOL)removeAllMessagesSentBefore:(uint64_t)limitTs inRoom:(nonnull NSString *)roomId;
- (void)removeExpiredMessagesWithRoomMinimumTimestamps:(nonnull NSDictionary<NSString *, NSNumber *> *)roomMinimumTimestamps
                                            completion:(nullable void (^)(NSUInteger cleanedRoomCount,
                                                                          NSUInteger failedRoomCount,
                                                                          BOOL cancelled))completion;

// Прокладка старой модели дыр поверх `hole` (ADR-0022: gapId = holeId, якоря — события на границах).
- (NSArray<MXRoomHistoryGap *> * _Nonnull)historyGapsForRoom:(NSString * _Nonnull)roomId;
- (NSUInteger)historyRevisionForRoom:(NSString * _Nonnull)roomId;
- (NSArray<MXEvent *> * _Nonnull)continuousRecentMessagesForRoom:(NSString * _Nonnull)roomId;
- (void)storeHistoryGap:(MXRoomHistoryGap * _Nonnull)gap forRoom:(NSString * _Nonnull)roomId;
- (void)removeHistoryGapWithId:(NSString * _Nonnull)gapId inRoom:(NSString * _Nonnull)roomId;
- (void)insertHistoryEvents:(NSArray<MXEvent *> * _Nonnull)events inRoom:(NSString * _Nonnull)roomId beforeEventId:(NSString * _Nullable)eventId;
- (NSArray<MXEvent *> * _Nonnull)historyBlockBeforeGap:(MXRoomHistoryGap * _Nonnull)gap inRoom:(NSString * _Nonnull)roomId;
- (void)applyHistoryGap:(MXRoomHistoryGap * _Nonnull)gap inRoom:(NSString * _Nonnull)roomId events:(NSArray<MXEvent *> * _Nonnull)events nextToken:(NSString * _Nullable)token;

// Контексты в новом сторе не хранятся (окно — диапазон между дырами): «нет» и NO, как у MXBackgroundStore.
- (NSArray<MXRoomHistoryContext *> * _Nonnull)historyContextsForRoom:(NSString * _Nonnull)roomId;
- (MXRoomHistoryContext * _Nullable)historyContextForEventId:(NSString * _Nonnull)eventId inRoom:(NSString * _Nonnull)roomId filter:(NSDictionary * _Nonnull)filter;
- (NSString * _Nullable)historyContextGenerationForRoom:(NSString * _Nonnull)roomId;
- (BOOL)storeHistoryContext:(MXRoomHistoryContext * _Nonnull)context inRoom:(NSString * _Nonnull)roomId expectedGeneration:(NSString * _Nonnull)generation expectedRoomRevision:(NSUInteger)roomRevision expectedComponentRevision:(NSUInteger)componentRevision;

// MXTimelineStore (кроме сводок и метрик).
- (nonnull MXStorePage *)latestPageInRoom:(nonnull NSString *)roomId thread:(nullable NSString *)threadId limit:(NSUInteger)limit types:(nullable NSSet<NSString *> *)types;
- (nonnull MXStorePage *)pageInRoom:(nonnull NSString *)roomId thread:(nullable NSString *)threadId beforeOrder:(int64_t)order limit:(NSUInteger)limit types:(nullable NSSet<NSString *> *)types;
- (nonnull MXStorePage *)pageInRoom:(nonnull NSString *)roomId thread:(nullable NSString *)threadId afterOrder:(int64_t)order limit:(NSUInteger)limit types:(nullable NSSet<NSString *> *)types;
- (nullable MXStorePage *)pageAroundEvent:(nonnull NSString *)eventId inRoom:(nonnull NSString *)roomId limit:(NSUInteger)limit;
- (BOOL)orderOfEvent:(nonnull NSString *)eventId inRoom:(nonnull NSString *)roomId order:(nonnull int64_t *)order;
- (nonnull NSArray<MXRoomHole *> *)holesInRoom:(nonnull NSString *)roomId thread:(nullable NSString *)threadId;
- (NSUInteger)revisionOfRoom:(nonnull NSString *)roomId;
- (nullable MXEvent *)latestEventInRoom:(nonnull NSString *)roomId types:(nullable NSSet<NSString *> *)types threadId:(nullable NSString *)threadId beforeOrder:(int64_t)order;
- (NSUInteger)countEventsInRoom:(nonnull NSString *)roomId afterEventId:(nullable NSString *)eventId types:(nullable NSSet<NSString *> *)types excludingSender:(nullable NSString *)userId threadId:(nullable NSString *)threadId limit:(NSUInteger)limit;
- (void)noteSyncTimelineInRoom:(nonnull NSString *)roomId firstEvent:(nullable MXEvent *)firstEvent limited:(BOOL)limited prevBatch:(nullable NSString *)prevBatch;
- (void)applyPage:(nonnull MXPaginationResponse *)response toHole:(nonnull MXRoomHole *)hole direction:(MXTimelineDirection)direction;
- (void)insertContext:(nonnull MXEventContext *)context inRoom:(nonnull NSString *)roomId;
- (BOOL)insertDetachedEvent:(nonnull MXEvent *)event inRoom:(nonnull NSString *)roomId;

@end

#pragma mark - Состояние и флаги комнаты (iP3: MXSQLiteStateStore.m)

@protocol MXSQLiteStateStoring <MXSQLiteStoreComponent>

- (void)storeStateForRoom:(nonnull NSString*)roomId stateEvents:(nonnull NSArray<MXEvent*> *)stateEvents;
- (void)stateOfRoom:(nonnull NSString *)roomId
            success:(nonnull void (^)(NSArray<MXEvent *> * _Nonnull stateEvents))success
            failure:(nullable void (^)(NSError * _Nonnull error))failure;
- (void)storeAccountDataForRoom:(nonnull NSString*)roomId userData:(nonnull MXRoomAccountData*)accountData;
- (MXRoomAccountData* _Nullable)accountDataOfRoom:(nonnull NSString*)roomId;

- (void)storePaginationTokenOfRoom:(nonnull NSString*)roomId andToken:(nonnull NSString*)token;
- (NSString * _Nullable)paginationTokenOfRoom:(nonnull NSString*)roomId;
- (void)storeHasReachedHomeServerPaginationEndForRoom:(nonnull NSString*)roomId andValue:(BOOL)value;
- (BOOL)hasReachedHomeServerPaginationEndForRoom:(nonnull NSString*)roomId;
- (void)storeBackwardPaginationStateForRoom:(nonnull NSString*)roomId state:(MXRoomBackwardPaginationState)state;
- (MXRoomBackwardPaginationState)backwardPaginationStateForRoom:(nonnull NSString*)roomId;
- (void)storeHasLoadedAllRoomMembersForRoom:(nonnull NSString*)roomId andValue:(BOOL)value;
- (BOOL)hasLoadedAllRoomMembersForRoom:(nonnull NSString*)roomId;

@end

#pragma mark - Мета сессии, пользователи, группы, фильтры (iP3: MXSQLiteMetaStore.m)

@protocol MXSQLiteMetaStoring <MXSQLiteStoreComponent>

/// Пишется в той же транзакции, что события синка: после падения синк повторится от прошлого токена.
@property (nonatomic) NSString * _Nullable eventStreamToken;
@property (nonatomic) NSDictionary * _Nullable userAccountData;
@property (nonatomic) BOOL areAllIdentityServerTermsAgreed;
@property (nonatomic) NSString * _Nullable syncFilterId;
@property (nonatomic, readonly) MXWellKnown * _Nullable homeserverWellknown;
@property (nonatomic, readonly) MXCapabilities * _Nullable homeserverCapabilities;
@property (nonatomic, readonly) MXMatrixVersions * _Nullable supportedMatrixVersions;
@property (nonatomic, readonly) MXAuthMetadata * _Nullable authMetadata;
@property (nonatomic, readonly) NSInteger maxUploadSize;

/// Одноразовый перенос черновиков и исходящих из MXFileStore уже сделан (`MXSQLiteLegacyImport`).
@property (nonatomic) BOOL legacyFileStoreImported;

/// Состояние Sliding Sync (позиция, conn_id, порядок комнат) — в той же транзакции, что данные ответа (iP9).
@property (nonatomic, copy) NSDictionary * _Nullable trscSlidingSyncState;

- (void)storeHomeserverWellknown:(nonnull MXWellKnown*)homeserverWellknown;
- (void)storeHomeserverCapabilities:(nonnull MXCapabilities*)homeserverCapabilities;
- (void)storeSupportedMatrixVersions:(nonnull MXMatrixVersions*)supportedMatrixVersions;
- (void)storeAuthMetadata:(nonnull MXAuthMetadata*)authMetadata;
- (void)storeMaxUploadSize:(NSInteger)maxUploadSize;

- (void)storeUser:(nonnull MXUser*)user;
- (NSArray<MXUser*>* _Nullable)users;
- (MXUser* _Nullable)userWithUserId:(nonnull NSString*)userId;

- (void)storeGroup:(nonnull MXGroup*)group;
- (NSArray<MXGroup*>* _Nullable)groups;
- (MXGroup* _Nullable)groupWithGroupId:(nonnull NSString*)groupId;
- (void)deleteGroup:(nonnull NSString*)groupId;

- (void)storeFilter:(nonnull MXFilterJSONModel*)filter withFilterId:(nonnull NSString*)filterId;
- (nonnull NSArray <NSString *> *)allFilterIds;
- (void)filterWithFilterId:(nonnull NSString*)filterId
                   success:(nonnull void (^)(MXFilterJSONModel * _Nullable filter))success
                   failure:(nullable void (^)(NSError * _Nullable error))failure;
- (void)filterIdForFilter:(nonnull MXFilterJSONModel*)filter
                  success:(nonnull void (^)(NSString * _Nullable filterId))success
                  failure:(nullable void (^)(NSError * _Nullable error))failure;

@end

#pragma mark - Квитанции и отметка «непрочитано» (iP4: MXSQLiteReceiptStore.m)

@protocol MXSQLiteReceiptStoring <MXSQLiteStoreComponent>

- (void)getEventReceipts:(nonnull NSString*)roomId
                 eventId:(nonnull NSString*)eventId
                threadId:(nonnull NSString*)threadId
                  sorted:(BOOL)sort
              completion:(nonnull void (^)(NSArray<MXReceiptData*> * _Nonnull))completion;
- (BOOL)storeReceipt:(nonnull MXReceiptData*)receipt inRoom:(nonnull NSString*)roomId;
- (nonnull NSDictionary<NSString *, MXReceiptData *> *)getReceiptsInRoom:(nonnull NSString*)roomId forUserId:(nonnull NSString*)userId;
- (nullable MXReceiptData *)getReceiptInRoom:(nonnull NSString*)roomId threadId:(nonnull NSString*)threadId forUserId:(nonnull NSString*)userId;
- (void)loadReceiptsForRoom:(nonnull NSString *)roomId completion:(nullable void (^)(void))completion;

- (void)setUnreadForRoom:(nonnull NSString*)roomId;
- (void)resetUnreadForRoom:(nonnull NSString*)roomId;
- (BOOL)isRoomMarkedAsUnread:(nonnull NSString*)roomId;

@end

#pragma mark - Исходящие и черновики (iP4: MXSQLiteOutgoingStore.m)

@protocol MXSQLiteOutgoingStoring <MXSQLiteStoreComponent>

- (void)storeOutgoingMessageForRoom:(nonnull NSString*)roomId outgoingMessage:(nonnull MXEvent*)outgoingMessage;
- (void)removeAllOutgoingMessagesFromRoom:(nonnull NSString*)roomId;
- (void)removeOutgoingMessageFromRoom:(nonnull NSString*)roomId outgoingMessage:(nonnull NSString*)outgoingMessageEventId;
- (NSArray<MXEvent*>* _Nullable)outgoingMessagesInRoom:(nonnull NSString*)roomId;

- (void)storePartialAttributedTextMessageForRoom:(nonnull NSString*)roomId partialAttributedTextMessage:(nonnull NSAttributedString*)partialAttributedTextMessage;
- (NSAttributedString* _Nullable)partialAttributedTextMessageOfRoom:(nonnull NSString*)roomId;

/**
 Хук для компонента событий: серверное событие с `unsigned.transaction_id` пришло в синке. Строка `outgoing` с этим
 txn_id исчезает из накладки сразу и из базы — в той же транзакции коммита, что и вставка события.
 @return local_id снятой строки (UI связывает local_id ↔ event_id и обновляет строку на месте) или nil.
 */
- (nullable NSString *)consumeOutgoingForTransactionId:(nonnull NSString *)transactionId inRoom:(nonnull NSString *)roomId;

@end

//
// Copyright 2026 TRSC contributors.
// SPDX-License-Identifier: Apache-2.0
//

#import <Foundation/Foundation.h>

#import "MXStore.h"
#import "MXTimelineStore.h"

NS_ASSUME_NONNULL_BEGIN

/// Куда SDK отдаёт метрики хранилища (iP12). Приложение пишет их в журнал запуска (`TrscLaunchMetrics`).
/// Вызывается на любом потоке.
@protocol MXTrscStoreMetricsSink <NSObject>
/// Одно измерение вне записи запуска (`perf-events.jsonl`).
- (void)storeMetricsEvent:(NSString *)name milliseconds:(double)milliseconds detail:(NSString *)detail;
/// Значение контекста записи запуска (`NSNumber` или `NSString`).
- (void)storeMetricsContext:(NSString *)key value:(id)value;
@optional
/// Чат этой комнаты сейчас на экране (`live_insert_ms` пишется только для него). Без метода — любая лента
/// с подписчиками. Вызывается на main.
- (BOOL)storeMetricsShowsRoom:(NSString *)roomId;
@end

/**
 Метрики хранилища для журнала запуска — имена и detail те же, что у Android (`TrscStartupTimings.kt`), и в каждом
 detail `store=sqlite|file`, чтобы один отчёт сравнивал старый стор и новый:

 - ctx `db_open_ms` — открытие базы SQLite (ключ, PRAGMA, схема; у MXFileStore — `openWithCredentials:` до
   `onComplete`), `store_open_ms` — `openWithCredentials:` до `onComplete` на main, `store`, у SQLite `db_mb`;
 - `sync_persist_ms` — запись одного ответа синка (detail `events rooms initial`); у SQLite — транзакция на писателе
   (`MXStoreMetricsDelegate`), у MXFileStore — `commitWithCompletion:` до completion; пустой long-poll не пишется;
 - `chat_window_ms` — первое окно чата из стора (detail `rows anchor=live|event`);
 - `page_fetch_ms` — догрузка с сервера: запрос, его запись в стор (detail `dir count rows`);
 - `live_insert_ms` — ответ синка получен → его событие отдано слушателям открытой ленты.

 Без приёмника (`sink == nil`) ничего не считается и не копится.
 */
@interface MXTrscStoreMetrics : NSObject <MXStoreMetricsDelegate>

@property (class, nonatomic, strong, nullable) id<MXTrscStoreMetricsSink> sink;

/// Делегат метрик `MXTimelineStore` (ставит `MXSession` при открытии стора).
@property (class, nonatomic, readonly) MXTrscStoreMetrics *shared;

/// `sqlite`, `file`, `memory`, `none` (nil) или имя класса.
+ (NSString *)kindOfStore:(nullable id<MXStore>)store NS_SWIFT_NAME(kind(of:));

/// Первое открытие стора сессии в процессе; повторные (смена аккаунта, перезапуск сессии) не пишутся.
+ (void)reportStoreOpen:(id<MXStore>)store milliseconds:(double)milliseconds;

/// Запись ответа синка начинается (перед `commitWithCompletion:`).
+ (void)beginSyncPersistOfStore:(id<MXStore>)store events:(NSUInteger)events rooms:(NSUInteger)rooms initial:(BOOL)initial
    NS_SWIFT_NAME(beginSyncPersist(of:events:rooms:initial:));
/// Completion того коммита. MXFileStore: замер от `begin`; SQLite: уже записан писателем, здесь только сброс.
+ (void)endSyncPersistOfStore:(id<MXStore>)store NS_SWIFT_NAME(endSyncPersist(of:));

+ (void)reportSyncPersist:(nullable id<MXStore>)store milliseconds:(double)milliseconds events:(NSUInteger)events
                    rooms:(NSUInteger)rooms initial:(BOOL)initial;
+ (void)reportChatWindow:(nullable id<MXStore>)store milliseconds:(double)milliseconds rows:(NSUInteger)rows
                  anchor:(NSString *)anchor;
+ (void)reportPageFetch:(nullable id<MXStore>)store milliseconds:(double)milliseconds direction:(NSString *)direction
                  count:(NSUInteger)count rows:(NSUInteger)rows;

/// События ответа синка (время — `CACurrentMediaTime()`), последние 256.
+ (void)noteSyncEventIds:(NSArray<NSString *> *)eventIds;
+ (void)noteSyncEventIds:(NSArray<NSString *> *)eventIds at:(NSTimeInterval)time;
/// Событие отдано слушателям живой ленты комнаты; первое попадание по id в чате на экране
/// (`storeMetricsShowsRoom:`) пишет `live_insert_ms`.
+ (void)reportLiveEventDelivered:(NSString *)eventId roomId:(NSString *)roomId store:(nullable id<MXStore>)store;
+ (void)reportLiveEventDelivered:(NSString *)eventId roomId:(NSString *)roomId store:(nullable id<MXStore>)store
                              at:(NSTimeInterval)time;

/// Сброс состояния (тесты).
+ (void)resetForTests;

@end

NS_ASSUME_NONNULL_END

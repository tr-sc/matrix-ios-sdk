/*
 Copyright 2016 OpenMarket Ltd
 Copyright 2019 The Matrix.org Foundation C.I.C

 Licensed under the Apache License, Version 2.0 (the "License");
 you may not use this file except in compliance with the License.
 You may obtain a copy of the License at

 http://www.apache.org/licenses/LICENSE-2.0

 Unless required by applicable law or agreed to in writing, software
 distributed under the License is distributed on an "AS IS" BASIS,
 WITHOUT WARRANTIES OR CONDITIONS OF ANY KIND, either express or implied.
 See the License for the specific language governing permissions and
 limitations under the License.
 */

#import <Foundation/Foundation.h>
#import "MXEventTimeline.h"

@class MXRoomHistoryGap;
@class MXRoomHistoryContext;
@class MXEventContext;

NS_ASSUME_NONNULL_BEGIN

/**
 Prefix used to build fake invite event.
 */
FOUNDATION_EXPORT NSString *const kMXRoomInviteStateEventIdPrefix;
/** Дополнительное уведомление о прогрессе интервала; object — MXRoom, userInfo содержит historyRevision. */
FOUNDATION_EXPORT NSString *const MXRoomHistoryGapsDidChangeNotification;

@interface MXRoomEventTimeline: NSObject <MXEventTimeline>

/**
 Create a timeline instance for a room.

 If the timeline is live, the events will be stored to the MXSession instance store.
 Else, they will be only stored in memory and released on [MXEventTimeline destroy].

 @param room the room associated to the timeline
 @param initialEventId the initial event for the timeline. A nil value will create a live timeline.
 @return a MXEventTimeline instance.
 */
- (instancetype)initWithRoom:(MXRoom*)room andInitialEventId:(nullable NSString*)initialEventId;

/**
 Create a timeline instance for a room and force it to use the given MXStore to store events.

 @param room the room associated to the timeline
 @param initialEventId the initial event for the timeline. A nil value will create a live timeline.
 @param store the store to use to store timeline events.
 @return a MXEventTimeline instance.
 */
- (instancetype)initWithRoom:(MXRoom*)room initialEventId:(nullable NSString*)initialEventId andStore:(id<MXStore>)store;

/** Последний успешно загруженный целевой контекст. Независимые окна контекста остаются доступными
 для чтения, даже если невозможно доказать их положение в сохраняемых интервалах. */
@property (nonatomic, strong, readonly, nullable) MXEventContext *historyContext;

/** Текущий сохраняемый целевой компонент, обновляемый из основного хранилища комнаты. */
@property (nonatomic, readonly, nullable) MXRoomHistoryContext *historyContextComponent;
/** Каноническое присоединение подтверждено, и эта лента уже передала соединяющий
 суффикс контекста. Последующие строки live без разрывов относятся к live-проекции, а не к этому хранилищу. */
@property (nonatomic, readonly) BOOL historyContextAttachedToLive;
/** Восстановить совместимое сохранённое состояние и синхронно воспроизвести события слушателям. Не выполняет HTTP-запросов. */
- (BOOL)restoreHistoryContextFromStore;
/** Загрузить страницу сохранённого компонента через прокси вне live-ленты. Возвращаемая операция управляет
 отменой на этапах HTTP/расшифровки/сохранения; success возвращает события страницы. */
- (MXHTTPOperation *)paginateHistoryContext:(NSString *)componentId
                                direction:(MXTimelineDirection)direction
                                  success:(void (^)(NSArray<MXEvent *> *events))success
                                  failure:(void (^)(NSError *error))failure NS_SWIFT_NAME(paginateHistoryContext(_:direction:success:failure:));

/** Загрузить не более 50 событий по курсору интервала, а не по курсору самой старой истории.
 При успехе восстановленная страница передаётся от новых событий к старым. Застрявший интервал остаётся сохранённым,
 а операция завершается ошибкой MXRoomHistoryGap вместо ложного подтверждения непрерывности. */
- (MXHTTPOperation *)paginateHistoryGap:(NSString *)gapId
                               success:(void (^)(NSArray<MXEvent *> *events))success
                               failure:(void (^)(NSError *error))failure NS_SWIFT_NAME(paginateHistoryGap(_:success:failure:));
/** Сохранить островок контекста с явно заданным положением. Вызывающий код передаёт ID содержащего его разрыва;
 нельзя угадывать неизвестное положение по серверным меткам времени. Обе неподтверждённые стороны сохраняются. */
- (BOOL)persistHistoryContext:(MXEventContext *)context inGap:(NSString *)gapId NS_SWIFT_NAME(persistHistoryContext(_:inGap:));
@end

NS_ASSUME_NONNULL_END

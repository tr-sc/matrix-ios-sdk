// Support for SDK tests against the local bench stand (scripts/ios-store-bench/up.sh, iP13).
//
// Everything here goes through `id<MXStore>`: the store under test is chosen by one setting,
// TRSC_BENCH_STORE = file (MXFileStore, default) | sqlite (MXSQLiteStore) | memory (MXMemoryStore).
// With xcodebuild pass it as TEST_RUNNER_TRSC_BENCH_STORE=sqlite.

#import <Foundation/Foundation.h>
#import <MatrixSDK/MatrixSDK.h>

NS_ASSUME_NONNULL_BEGIN

/// fixture.json written by scripts/ios-store-bench/seed.py.
@interface TrscStandFixture : NSObject
@property (nonatomic, readonly) NSString *homeserver;
@property (nonatomic, readonly) NSString *password;
@property (nonatomic, readonly) NSString *readerUser;
@property (nonatomic, readonly) NSString *senderUser;
/// [{alias, local, room_id, messages, newest_trsc_count}], smallest room first.
@property (nonatomic, readonly) NSArray<NSDictionary *> *rooms;
@property (nonatomic, readonly) NSString *path;

/// TRSC_BENCH_FIXTURE, else $SIMULATOR_HOST_HOME/trsc-wt/i2-bench-stand/fixture.json. Nil when absent.
+ (nullable instancetype)load;
@end

/// Times every commit of the wrapped store: from the call to the moment its data is on disk
/// (the completion of `commitWithCompletion:`). Everything else is forwarded untouched.
@interface TrscTimedStore : NSProxy <MXStore>
@property (nonatomic, readonly) id<MXStore> target;
/// Main queue: milliseconds of one finished commit.
@property (nonatomic, copy, nullable) void (^onCommitDone)(double ms);
+ (id<MXStore>)wrap:(id<MXStore>)store;
/// The TrscTimedStore behind a store returned by +wrap:, nil for any other object.
+ (nullable TrscTimedStore *)unwrap:(id)store;
@end

@interface TrscStandSupport : NSObject

/// "file", "sqlite" or "memory".
+ (NSString *)storeKind;
/// A new store of the kind above, nil when that class is not linked (e.g. MXSQLiteStore before iP1).
+ (nullable id<MXStore>)makeStore;

/// Value of an environment variable of the test run (TEST_RUNNER_ prefix stripped by xcodebuild).
+ (nullable NSString *)env:(NSString *)name;
+ (NSInteger)envInt:(NSString *)name fallback:(NSInteger)fallback;

/// Bytes of all files under the directories whose name is `name` inside the app's sandbox and app
/// group containers (MXFileStore keeps one directory per room id). 0 when there is none.
+ (unsigned long long)bytesOfDirectoriesNamed:(NSString *)name;

/// Total size the store reports (`diskUsageWithBlock:`), or the sum of every MXFileStore/SQLite file
/// of the user when it reports none.
+ (void)diskUsageOfStore:(id<MXStore>)store userId:(NSString *)userId completion:(void (^)(unsigned long long bytes))completion;

@end

/// JSON lines in the format of the app's perf journal ({"v":1,"type":"event",…,"ms":…,"ctx":{…}}),
/// so scripts/perf/launch-metrics-report.py reads them, plus `ctx` for scripts/ios-store-bench/report.py.
/// Each line goes to stdout with the prefix [TRSC-BENCH], to results/<run>.jsonl of the stand, and to
/// the app's perf-events.jsonl when the test target provides TrscBenchJournalBridge.
@interface TrscBenchJournal : NSObject
@property (nonatomic, readonly) NSString *runId;
@property (nonatomic, readonly, nullable) NSString *filePath;
- (instancetype)initWithStoreKind:(NSString *)storeKind;
- (void)record:(NSString *)name value:(double)value unit:(NSString *)unit ctx:(NSDictionary *)ctx;
@end

NS_ASSUME_NONNULL_END

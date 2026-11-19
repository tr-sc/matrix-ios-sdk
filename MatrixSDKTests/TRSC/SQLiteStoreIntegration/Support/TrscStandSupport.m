#import "TrscStandSupport.h"

#import <UIKit/UIKit.h>
#import <sys/utsname.h>
#import <objc/message.h>
#import <objc/runtime.h>

#pragma mark - Fixture

@implementation TrscStandFixture

+ (instancetype)load
{
    NSString *path = [TrscStandSupport env:@"TRSC_BENCH_FIXTURE"];
    if (!path.length)
    {
        NSString *home = NSProcessInfo.processInfo.environment[@"SIMULATOR_HOST_HOME"] ?: NSHomeDirectory();
        path = [home stringByAppendingPathComponent:@"trsc-wt/i2-bench-stand/fixture.json"];
    }
    NSData *data = [NSData dataWithContentsOfFile:path];
    if (!data) return nil;
    NSDictionary *json = [NSJSONSerialization JSONObjectWithData:data options:0 error:nil];
    if (![json isKindOfClass:NSDictionary.class]) return nil;

    TrscStandFixture *fixture = [TrscStandFixture new];
    fixture->_path = path;
    fixture->_homeserver = [TrscStandSupport env:@"TRSC_BENCH_HS"] ?: json[@"hs"];
    fixture->_password = json[@"password"];
    fixture->_readerUser = json[@"reader"][@"user"];
    fixture->_senderUser = json[@"sender"][@"user"];
    fixture->_rooms = [json[@"rooms"] sortedArrayUsingComparator:^NSComparisonResult(NSDictionary *a, NSDictionary *b) {
        return [a[@"messages"] compare:b[@"messages"]];
    }];
    return fixture;
}

@end

#pragma mark - Timed store

@implementation TrscTimedStore
{
    id<MXStore> _target;
}

+ (id<MXStore>)wrap:(id<MXStore>)store
{
    TrscTimedStore *proxy = [TrscTimedStore alloc];
    proxy->_target = store;
    return proxy;
}

+ (TrscTimedStore *)unwrap:(id)store
{
    // -class is forwarded to the target, so ask the runtime for the real class of the proxy.
    return object_getClass(store) == TrscTimedStore.class ? (TrscTimedStore *)store : nil;
}

- (id<MXStore>)target
{
    return _target;
}

- (void)commit
{
    [self commitWithCompletion:nil];
}

- (void)commitWithCompletion:(void (^)(void))completion
{
    CFAbsoluteTime start = CFAbsoluteTimeGetCurrent();
    void (^done)(void) = ^{
        double ms = (CFAbsoluteTimeGetCurrent() - start) * 1000;
        if (self.onCommitDone) self.onCommitDone(ms);
        if (completion) completion();
    };
    if ([_target respondsToSelector:@selector(commitWithCompletion:)])
    {
        [_target commitWithCompletion:^{
            dispatch_async(dispatch_get_main_queue(), done);
        }];
    }
    else
    {
        if ([_target respondsToSelector:@selector(commit)]) [_target commit];
        dispatch_async(dispatch_get_main_queue(), done);
    }
}

- (BOOL)respondsToSelector:(SEL)aSelector
{
    if (aSelector == @selector(commit) || aSelector == @selector(commitWithCompletion:)) return YES;
    return [(NSObject *)_target respondsToSelector:aSelector];
}

- (BOOL)conformsToProtocol:(Protocol *)aProtocol
{
    return [(NSObject *)_target conformsToProtocol:aProtocol];
}

- (BOOL)isKindOfClass:(Class)aClass
{
    return [(NSObject *)_target isKindOfClass:aClass];
}

- (id)forwardingTargetForSelector:(SEL)aSelector
{
    return _target;
}

- (NSMethodSignature *)methodSignatureForSelector:(SEL)sel
{
    return [(NSObject *)_target methodSignatureForSelector:sel];
}

- (void)forwardInvocation:(NSInvocation *)invocation
{
    [invocation invokeWithTarget:_target];
}

- (NSString *)description
{
    return [NSString stringWithFormat:@"<TrscTimedStore %@>", _target];
}

@end

#pragma mark - Support

@implementation TrscStandSupport

+ (NSString *)env:(NSString *)name
{
    NSDictionary *environment = NSProcessInfo.processInfo.environment;
    NSString *value = environment[name] ?: environment[[@"TEST_RUNNER_" stringByAppendingString:name]];
    return value.length ? value : nil;
}

+ (NSInteger)envInt:(NSString *)name fallback:(NSInteger)fallback
{
    NSString *value = [self env:name];
    return value ? value.integerValue : fallback;
}

+ (NSString *)storeKind
{
    return [self env:@"TRSC_BENCH_STORE"].lowercaseString ?: @"file";
}

+ (id<MXStore>)makeStore
{
    NSString *kind = [self storeKind];
    NSString *className = [kind isEqualToString:@"sqlite"] ? @"MXSQLiteStore"
                        : [kind isEqualToString:@"memory"] ? @"MXMemoryStore"
                        : @"MXFileStore";
    Class storeClass = NSClassFromString(className);
    if (!storeClass || ![storeClass conformsToProtocol:@protocol(MXStore)]) return nil;
    return [[storeClass alloc] init];
}

+ (NSArray<NSString *> *)containerRoots
{
    NSMutableArray *roots = [NSMutableArray arrayWithObject:NSHomeDirectory()];
    NSString *group = MXSDKOptions.sharedInstance.applicationGroupIdentifier;
    if (group.length)
    {
        NSURL *url = [NSFileManager.defaultManager containerURLForSecurityApplicationGroupIdentifier:group];
        if (url.path) [roots addObject:url.path];
    }
    return roots;
}

+ (unsigned long long)bytesUnder:(NSString *)directory
{
    unsigned long long total = 0;
    NSDirectoryEnumerator *files = [NSFileManager.defaultManager enumeratorAtPath:directory];
    for (NSString *file in files)
    {
        if ([files.fileAttributes[NSFileType] isEqualToString:NSFileTypeRegular])
        {
            total += [files.fileAttributes[NSFileSize] unsignedLongLongValue];
        }
    }
    return total;
}

+ (unsigned long long)bytesOfDirectoriesNamed:(NSString *)name
{
    unsigned long long total = 0;
    for (NSString *root in [self containerRoots])
    {
        NSDirectoryEnumerator *walker = [NSFileManager.defaultManager enumeratorAtPath:root];
        for (NSString *relative in walker)
        {
            if ([relative.lastPathComponent isEqualToString:name]
                && [walker.fileAttributes[NSFileType] isEqualToString:NSFileTypeDirectory])
            {
                total += [self bytesUnder:[root stringByAppendingPathComponent:relative]];
                [walker skipDescendants];
            }
        }
    }
    return total;
}

+ (void)diskUsageOfStore:(id<MXStore>)store userId:(NSString *)userId completion:(void (^)(unsigned long long))completion
{
    if ([store respondsToSelector:@selector(diskUsageWithBlock:)])
    {
        // Not part of MXStore; MXFileStore declares it, other stores may implement the same selector.
        [(MXFileStore *)store diskUsageWithBlock:^(NSUInteger diskUsage) {
            completion(diskUsage);
        }];
        return;
    }
    completion([self bytesOfDirectoriesNamed:userId]);
}

@end

#pragma mark - Journal

@implementation TrscBenchJournal
{
    NSString *_storeKind;
    NSString *_device;
    NSFileHandle *_file;
    NSISO8601DateFormatter *_formatter;
}

- (instancetype)initWithStoreKind:(NSString *)storeKind
{
    if (self = [super init])
    {
        _storeKind = storeKind;
        _formatter = [NSISO8601DateFormatter new];
        _formatter.formatOptions = NSISO8601DateFormatWithInternetDateTime | NSISO8601DateFormatWithFractionalSeconds;
        _runId = [NSString stringWithFormat:@"bench-%@-%@", storeKind,
                  [[_formatter stringFromDate:NSDate.date] stringByReplacingOccurrencesOfString:@":" withString:@""]];
        NSString *model = NSProcessInfo.processInfo.environment[@"SIMULATOR_MODEL_IDENTIFIER"];
        if (!model)
        {
            struct utsname info;
            uname(&info);
            model = @(info.machine);
        }
        _device = NSProcessInfo.processInfo.environment[@"SIMULATOR_DEVICE_NAME"]
            ? [NSString stringWithFormat:@"%@ (sim %@)", model, UIDevice.currentDevice.systemVersion] : model;

        NSString *dir = [TrscStandSupport env:@"TRSC_BENCH_RESULTS"];
        if (!dir)
        {
            NSString *home = NSProcessInfo.processInfo.environment[@"SIMULATOR_HOST_HOME"];
            if (home) dir = [home stringByAppendingPathComponent:@"trsc-wt/i2-bench-stand/results"];
        }
        if (dir)
        {
            [NSFileManager.defaultManager createDirectoryAtPath:dir withIntermediateDirectories:YES attributes:nil error:nil];
            _filePath = [dir stringByAppendingPathComponent:[_runId stringByAppendingString:@".jsonl"]];
            [NSFileManager.defaultManager createFileAtPath:_filePath contents:nil attributes:nil];
            _file = [NSFileHandle fileHandleForWritingAtPath:_filePath];
        }
    }
    return self;
}

- (void)record:(NSString *)name value:(double)value unit:(NSString *)unit ctx:(NSDictionary *)ctx
{
    NSMutableDictionary *context = [ctx mutableCopy];
    context[@"store"] = _storeKind;
    context[@"device"] = _device;
    NSDictionary *record = @{
        @"v": @1, @"type": @"event", @"platform": @"ios", @"app": @"store-bench",
        @"launch_id": _runId, @"ts": [_formatter stringFromDate:NSDate.date],
        @"name": name, @"ms": @(round(value * 10) / 10), @"unit": unit, @"detail": @"", @"ctx": context,
    };
    // "v" first: report scripts find a record by the substring {"v":1.
    NSMutableDictionary *rest = [record mutableCopy];
    [rest removeObjectForKey:@"v"];
    NSData *body = [NSJSONSerialization dataWithJSONObject:rest options:NSJSONWritingSortedKeys error:nil];
    NSString *line = [@"{\"v\":1," stringByAppendingString:[[NSString alloc] initWithData:body encoding:NSUTF8StringEncoding].length > 2
                      ? [[[NSString alloc] initWithData:body encoding:NSUTF8StringEncoding] substringFromIndex:1] : @"}"];

    printf("[TRSC-BENCH] %s\n", line.UTF8String);
    fflush(stdout);
    [_file writeData:[[line stringByAppendingString:@"\n"] dataUsingEncoding:NSUTF8StringEncoding]];

    // The app's own journal (perf-events.jsonl), when the host target links the bridge.
    Class bridge = NSClassFromString(@"TrscBenchJournalBridge");
    SEL append = NSSelectorFromString(@"append:");
    if ([bridge respondsToSelector:append])
    {
        ((void (*)(id, SEL, NSString *))objc_msgSend)(bridge, append, line);
    }
}

@end

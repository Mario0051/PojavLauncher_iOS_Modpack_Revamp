#import "NetworkService.h"
#import "AFNetworking.h"

@interface NetworkService ()
@property (nonatomic, strong) AFHTTPSessionManager *sessionManager;
@property (nonatomic, strong) NSCache *responseCache;
@property (nonatomic, strong) NSURLSession *downloadSession;
@end

@implementation NetworkService

+ (instancetype)sharedInstance {
    static NetworkService *sharedInstance = nil;
    static dispatch_once_t onceToken;
    dispatch_once(&onceToken, ^{
        sharedInstance = [[self alloc] init];
    });
    return sharedInstance;
}

- (instancetype)init {
    if (self = [super init]) {
        // Configure session manager
        NSURLSessionConfiguration *config = [NSURLSessionConfiguration defaultSessionConfiguration];
        config.timeoutIntervalForRequest = 30.0;
        config.HTTPMaximumConnectionsPerHost = 10;
        _sessionManager = [[AFHTTPSessionManager alloc] initWithSessionConfiguration:config];
        _sessionManager.requestSerializer = [AFJSONRequestSerializer serializer];
        _sessionManager.responseSerializer = [AFJSONResponseSerializer serializer];
        
        // Configure download session
        _downloadSession = [NSURLSession sessionWithConfiguration:config
                                                        delegate:nil
                                                   delegateQueue:[NSOperationQueue mainQueue]];
        
        // Initialize cache
        _responseCache = [[NSCache alloc] init];
        _responseCache.countLimit = 100;
    }
    return self;
}

- (NSURLSessionDataTask *)GET:(NSString *)url 
                    parameters:(NSDictionary *)parameters 
                       headers:(NSDictionary *)headers
                     cacheName:(NSString *)cacheName
                    completion:(NetworkCompletionHandler)completion {
    
    // Check cache if cacheName is provided
    if (cacheName) {
        id cachedResponse = [self cachedResponseForKey:cacheName];
        if (cachedResponse) {
            if (completion) {
                completion(cachedResponse, nil);
            }
            return nil;
        }
    }
    
    return [self.sessionManager GET:url parameters:parameters headers:headers progress:nil success:^(NSURLSessionDataTask * _Nonnull task, id  _Nullable responseObject) {
        // Cache the response if cacheName provided
        if (cacheName && responseObject) {
            [self cacheResponse:responseObject forKey:cacheName];
        }
        
        if (completion) {
            completion(responseObject, nil);
        }
    } failure:^(NSURLSessionDataTask * _Nullable task, NSError * _Nonnull error) {
        if (completion) {
            completion(nil, error);
        }
    }];
}

- (NSURLSessionDownloadTask *)download:(NSString *)url 
                             toPath:(NSString *)path
                           progress:(void (^)(NSProgress *progress))progressHandler
                         completion:(void (^)(NSURL *location, NSError *_Nullable error))completion {
    
    NSURLRequest *request = [NSURLRequest requestWithURL:[NSURL URLWithString:url]];
    NSURLSessionDownloadTask *task = [self.downloadSession downloadTaskWithRequest:request completionHandler:^(NSURL * _Nullable location, NSURLResponse * _Nullable response, NSError * _Nullable error) {
        if (error) {
            if (completion) {
                completion(nil, error);
            }
            return;
        }
        
        // Ensure the destination directory exists
        NSString *directory = [path stringByDeletingLastPathComponent];
        NSError *dirError = nil;
        [[NSFileManager defaultManager] createDirectoryAtPath:directory 
                                  withIntermediateDirectories:YES 
                                                   attributes:nil 
                                                        error:&dirError];
        
        if (dirError) {
            if (completion) {
                completion(nil, dirError);
            }
            return;
        }
        
        // Move the downloaded file to the destination
        NSError *moveError = nil;
        
        // Remove existing file if needed
        if ([[NSFileManager defaultManager] fileExistsAtPath:path]) {
            [[NSFileManager defaultManager] removeItemAtPath:path error:nil];
        }
        
        [[NSFileManager defaultManager] moveItemAtURL:location toURL:[NSURL fileURLWithPath:path] error:&moveError];
        
        if (completion) {
            completion(moveError ? nil : [NSURL fileURLWithPath:path], moveError);
        }
    }];
    
    if (progressHandler) {
        [task addObserver:self forKeyPath:@"countOfBytesReceived" options:NSKeyValueObservingOptionNew context:NULL];
        objc_setAssociatedObject(task, @"progressHandler", progressHandler, OBJC_ASSOCIATION_COPY);
    }
    
    return task;
}

- (void)observeValueForKeyPath:(NSString *)keyPath ofObject:(id)object change:(NSDictionary<NSKeyValueChangeKey,id> *)change context:(void *)context {
    if ([object isKindOfClass:[NSURLSessionDownloadTask class]] && [keyPath isEqualToString:@"countOfBytesReceived"]) {
        NSURLSessionDownloadTask *task = (NSURLSessionDownloadTask *)object;
        void (^progressHandler)(NSProgress *) = objc_getAssociatedObject(task, @"progressHandler");
        
        if (progressHandler) {
            NSProgress *progress = [NSProgress progressWithTotalUnitCount:task.countOfBytesExpectedToReceive];
            progress.completedUnitCount = task.countOfBytesReceived;
            progressHandler(progress);
        }
    } else {
        [super observeValueForKeyPath:keyPath ofObject:object change:change context:context];
    }
}

- (id)cachedResponseForKey:(NSString *)key {
    return [self.responseCache objectForKey:key];
}

- (void)cacheResponse:(id)response forKey:(NSString *)key {
    [self.responseCache setObject:response forKey:key];
}

- (void)clearCache {
    [self.responseCache removeAllObjects];
}

@end

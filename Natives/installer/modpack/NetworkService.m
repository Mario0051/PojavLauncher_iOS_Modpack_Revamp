#import "NetworkService.h"
#import "AFNetworking.h"
#import <objc/runtime.h>
#import <CommonCrypto/CommonCrypto.h>

// Define constants for caching
static NSString * const kNetworkServiceCachePrefix = @"NetworkServiceCache_";
static const NSTimeInterval kCacheExpirationDefault = 3600.0; // 1 hour default
static const NSUInteger kMaxConcurrentRequests = 10;

@interface NetworkServiceRequest : NSObject
@property (nonatomic, strong) NSString *url;
@property (nonatomic, strong) NSDictionary *parameters;
@property (nonatomic, strong) NSDictionary *headers;
@property (nonatomic, copy) NetworkCompletionHandler completion;
@property (nonatomic, strong) NSDate *timestamp;
@property (nonatomic, copy) NSString *cacheKey;
@end

@implementation NetworkServiceRequest
@end

@interface NetworkService ()
@property (nonatomic, strong) AFHTTPSessionManager *sessionManager;
@property (nonatomic, strong) NSCache *responseCache;
@property (nonatomic, strong) NSURLSession *downloadSession;
@property (nonatomic, strong) dispatch_queue_t cacheQueue;
@property (nonatomic, strong) NSMutableDictionary<NSString *, NSMutableArray<NetworkServiceRequest *> *> *pendingRequests;
@property (nonatomic, strong) NSMutableSet<NSString *> *activeRequests;
@property (nonatomic, strong) NSMutableDictionary<NSString *, NSDate *> *cacheExpirations;
@property (nonatomic, strong) NSOperationQueue *downloadQueue;
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
        config.HTTPMaximumConnectionsPerHost = kMaxConcurrentRequests;
        
        // Optimize based on iOS version
        if (@available(iOS 13.0, *)) {
            config.multipathServiceType = NSURLSessionMultipathServiceTypeHandover;
        }
        
        _sessionManager = [[AFHTTPSessionManager alloc] initWithSessionConfiguration:config];
        _sessionManager.requestSerializer = [AFJSONRequestSerializer serializer];
        _sessionManager.responseSerializer = [AFJSONResponseSerializer serializer];
        
        // Configure response serializer for more robustness
        AFJSONResponseSerializer *serializer = (AFJSONResponseSerializer *)_sessionManager.responseSerializer;
        serializer.removesKeysWithNullValues = YES;
        serializer.readingOptions = NSJSONReadingAllowFragments | NSJSONReadingMutableContainers;
        
        // Configure download session
        _downloadSession = [NSURLSession sessionWithConfiguration:config
                                                        delegate:nil
                                                   delegateQueue:[NSOperationQueue mainQueue]];
        
        // Initialize cache
        _responseCache = [[NSCache alloc] init];
        _responseCache.countLimit = 200;
        _responseCache.totalCostLimit = 50 * 1024 * 1024; // 50MB cache limit
        
        // Initialize queue for cache operations
        _cacheQueue = dispatch_queue_create("com.pojavlauncher.network.cache", DISPATCH_QUEUE_SERIAL);
        
        // Initialize request tracking
        _pendingRequests = [NSMutableDictionary dictionary];
        _activeRequests = [NSMutableSet set];
        _cacheExpirations = [NSMutableDictionary dictionary];
        
        // Initialize download queue
        _downloadQueue = [[NSOperationQueue alloc] init];
        _downloadQueue.maxConcurrentOperationCount = kMaxConcurrentRequests;
        
        // Register for memory warning notifications
        [[NSNotificationCenter defaultCenter] addObserver:self 
                                                 selector:@selector(handleMemoryWarning) 
                                                     name:UIApplicationDidReceiveMemoryWarningNotification 
                                                   object:nil];
    }
    return self;
}

- (void)dealloc {
    [[NSNotificationCenter defaultCenter] removeObserver:self];
}

- (void)handleMemoryWarning {
    // Reduce cache size on memory warning
    [self.responseCache removeAllObjects];
    dispatch_async(self.cacheQueue, ^{
        [self.cacheExpirations removeAllObjects];
    });
}

- (NSURLSessionDataTask *)GET:(NSString *)url 
                    parameters:(nullable NSDictionary *)parameters 
                       headers:(nullable NSDictionary *)headers
                     cacheName:(nullable NSString *)cacheName
                    completion:(NetworkCompletionHandler)completion {
    
    // Normalize parameters to prevent unnecessary cache misses
    parameters = [self normalizeParameters:parameters];
    
    // Generate cache key
    NSString *cacheKey = cacheName ?: [self generateCacheKeyForURL:url parameters:parameters];
    
    // Check if there's a valid cached response
    id cachedResponse = [self cachedResponseForKey:cacheKey];
    BOOL isCacheValid = [self isCacheValidForKey:cacheKey];
    
    if (cachedResponse && isCacheValid) {
        // Return from cache immediately
        if (completion) {
            completion(cachedResponse, nil);
        }
        
        // Refresh cache in background if it's about to expire
        if ([self shouldRefreshCacheForKey:cacheKey]) {
            [self performBackgroundRefreshForURL:url parameters:parameters headers:headers cacheKey:cacheKey];
        }
        
        return nil;
    }
    
    // Check if the same request is already in progress
    NSString *requestID = [self generateRequestIDForURL:url parameters:parameters];
    
    @synchronized(self.activeRequests) {
        if ([self.activeRequests containsObject:requestID]) {
            // The same request is in progress, queue this request for later
            NetworkServiceRequest *request = [[NetworkServiceRequest alloc] init];
            request.url = url;
            request.parameters = parameters;
            request.headers = headers;
            request.completion = completion;
            request.timestamp = [NSDate date];
            request.cacheKey = cacheKey;
            
            @synchronized(self.pendingRequests) {
                if (!self.pendingRequests[requestID]) {
                    self.pendingRequests[requestID] = [NSMutableArray array];
                }
                [self.pendingRequests[requestID] addObject:request];
            }
            
            return nil;
        }
        
        // Mark this request as active
        [self.activeRequests addObject:requestID];
    }
    
    // Apply proper timeout for each request
    NSMutableDictionary *requestHeaders = headers ? [headers mutableCopy] : [NSMutableDictionary dictionary];
    
    // Make the actual network request
    return [self.sessionManager GET:url parameters:parameters headers:requestHeaders progress:nil success:^(NSURLSessionDataTask * _Nonnull task, id  _Nullable responseObject) {
        // Cache the response
        if (responseObject) {
            [self cacheResponse:responseObject forKey:cacheKey withExpiration:kCacheExpirationDefault];
        }
        
        // Call the original completion handler
        if (completion) {
            completion(responseObject, nil);
        }
        
        // Process any pending requests for the same URL
        [self processPendingRequestsForRequestID:requestID withResponse:responseObject error:nil];
        
    } failure:^(NSURLSessionDataTask * _Nullable task, NSError * _Nonnull error) {
        // On network failure, use cache even if expired (as a fallback)
        id fallbackResponse = [self cachedResponseForKey:cacheKey ignoreExpiration:YES];
        if (fallbackResponse && completion) {
            NSLog(@"Network request failed, using cached response as fallback");
            completion(fallbackResponse, nil);
        } else if (completion) {
            completion(nil, error);
        }
        
        // Process any pending requests for the same URL
        [self processPendingRequestsForRequestID:requestID withResponse:fallbackResponse error:error];
    }];
}

- (void)performBackgroundRefreshForURL:(NSString *)url 
                            parameters:(NSDictionary *)parameters 
                               headers:(NSDictionary *)headers 
                              cacheKey:(NSString *)cacheKey {
    // Perform a background refresh to update the cache without blocking the caller
    dispatch_async(dispatch_get_global_queue(DISPATCH_QUEUE_PRIORITY_BACKGROUND, 0), ^{
        [self.sessionManager GET:url parameters:parameters headers:headers progress:nil success:^(NSURLSessionDataTask * _Nonnull task, id  _Nullable responseObject) {
            if (responseObject) {
                [self cacheResponse:responseObject forKey:cacheKey withExpiration:kCacheExpirationDefault];
            }
        } failure:^(NSURLSessionDataTask * _Nullable task, NSError * _Nonnull error) {
            // Silently fail - we'll continue using the existing cache
        }];
    });
}

- (void)processPendingRequestsForRequestID:(NSString *)requestID withResponse:(id)response error:(NSError *)error {
    NSMutableArray<NetworkServiceRequest *> *requests;
    
    @synchronized(self.pendingRequests) {
        requests = [self.pendingRequests[requestID] mutableCopy];
        [self.pendingRequests removeObjectForKey:requestID];
    }
    
    @synchronized(self.activeRequests) {
        [self.activeRequests removeObject:requestID];
    }
    
    // Process all pending requests with the same response
    for (NetworkServiceRequest *request in requests) {
        if (request.completion) {
            dispatch_async(dispatch_get_main_queue(), ^{
                request.completion(response, error);
            });
        }
    }
}

- (NSDictionary *)normalizeParameters:(NSDictionary *)parameters {
    if (!parameters) {
        return @{};
    }
    
    // Sort dictionary keys to ensure consistent cache keys
    NSArray *sortedKeys = [[parameters allKeys] sortedArrayUsingSelector:@selector(compare:)];
    NSMutableDictionary *normalized = [NSMutableDictionary dictionaryWithCapacity:parameters.count];
    
    for (NSString *key in sortedKeys) {
        id value = parameters[key];
        
        // Handle NSNumber specially to ensure consistent representation
        if ([value isKindOfClass:[NSNumber class]]) {
            if (strcmp([value objCType], @encode(BOOL)) == 0) {
                normalized[key] = [value boolValue] ? @"true" : @"false";
            } else {
                normalized[key] = [value stringValue];
            }
        } 
        // Handle arrays and dictionaries by converting to JSON
        else if ([value isKindOfClass:[NSArray class]] || [value isKindOfClass:[NSDictionary class]]) {
            NSError *error;
            NSData *jsonData = [NSJSONSerialization dataWithJSONObject:value options:0 error:&error];
            if (jsonData && !error) {
                normalized[key] = [[NSString alloc] initWithData:jsonData encoding:NSUTF8StringEncoding];
            } else {
                normalized[key] = [value description];
            }
        } else {
            normalized[key] = value;
        }
    }
    
    return normalized;
}

- (NSString *)generateCacheKeyForURL:(NSString *)url parameters:(NSDictionary *)parameters {
    NSMutableString *key = [NSMutableString stringWithString:url];
    
    if (parameters.count > 0) {
        [key appendString:@"?"];
        NSArray *sortedKeys = [[parameters allKeys] sortedArrayUsingSelector:@selector(compare:)];
        
        for (NSString *paramKey in sortedKeys) {
            id value = parameters[paramKey];
            [key appendFormat:@"%@=%@&", paramKey, [value description]];
        }
        
        // Remove trailing &
        if ([key hasSuffix:@"&"]) {
            [key deleteCharactersInRange:NSMakeRange(key.length - 1, 1)];
        }
    }
    
    // Use MD5 hash to create a fixed-length key
    const char *cKey = [key UTF8String];
    unsigned char result[16];
    CC_MD5(cKey, (CC_LONG)strlen(cKey), result);
    
    NSMutableString *hash = [NSMutableString stringWithCapacity:32];
    for (int i = 0; i < 16; i++) {
        [hash appendFormat:@"%02x", result[i]];
    }
    
    return [NSString stringWithFormat:@"%@%@", kNetworkServiceCachePrefix, hash];
}

- (NSString *)generateRequestIDForURL:(NSString *)url parameters:(NSDictionary *)parameters {
    // Create a unique identifier for this request
    NSString *cacheKey = [self generateCacheKeyForURL:url parameters:parameters];
    return [NSString stringWithFormat:@"req_%@", cacheKey];
}

- (BOOL)isCacheValidForKey:(NSString *)key {
    __block BOOL isValid = NO;
    
    dispatch_sync(self.cacheQueue, ^{
        NSDate *expirationDate = self.cacheExpirations[key];
        if (expirationDate) {
            isValid = ([expirationDate timeIntervalSinceNow] > 0);
        }
    });
    
    return isValid;
}

- (BOOL)shouldRefreshCacheForKey:(NSString *)key {
    __block BOOL shouldRefresh = NO;
    
    dispatch_sync(self.cacheQueue, ^{
        NSDate *expirationDate = self.cacheExpirations[key];
        if (expirationDate) {
            // Refresh if less than 10% of cache lifetime remains
            NSTimeInterval timeToExpiration = [expirationDate timeIntervalSinceNow];
            NSTimeInterval totalCacheLifetime = kCacheExpirationDefault;
            shouldRefresh = (timeToExpiration > 0 && timeToExpiration < (totalCacheLifetime * 0.1));
        }
    });
    
    return shouldRefresh;
}

- (id)cachedResponseForKey:(NSString *)key {
    return [self cachedResponseForKey:key ignoreExpiration:NO];
}

- (id)cachedResponseForKey:(NSString *)key ignoreExpiration:(BOOL)ignoreExpiration {
    if (!key) return nil;
    
    id cachedObject = [self.responseCache objectForKey:key];
    
    if (cachedObject && !ignoreExpiration) {
        // Check if cache is expired
        BOOL isValid = [self isCacheValidForKey:key];
        if (!isValid) {
            [self.responseCache removeObjectForKey:key];
            return nil;
        }
    }
    
    return cachedObject;
}

- (void)cacheResponse:(id)response forKey:(NSString *)key {
    [self cacheResponse:response forKey:key withExpiration:kCacheExpirationDefault];
}

- (void)cacheResponse:(id)response forKey:(NSString *)key withExpiration:(NSTimeInterval)expiration {
    if (!response || !key) return;
    
    // Calculate the size for prioritizing cache entries
    NSUInteger cost = 0;
    if ([response isKindOfClass:[NSData class]]) {
        cost = [(NSData *)response length];
    } else if ([response isKindOfClass:[NSString class]]) {
        cost = [(NSString *)response lengthOfBytesUsingEncoding:NSUTF8StringEncoding];
    } else if ([response isKindOfClass:[NSArray class]] || [response isKindOfClass:[NSDictionary class]]) {
        NSError *error;
        NSData *jsonData = [NSJSONSerialization dataWithJSONObject:response options:0 error:&error];
        if (!error && jsonData) {
            cost = jsonData.length;
        }
    }
    
    // Set the cache entry with cost
    [self.responseCache setObject:response forKey:key cost:cost];
    
    // Set expiration date
    NSDate *expirationDate = [NSDate dateWithTimeIntervalSinceNow:expiration];
    dispatch_async(self.cacheQueue, ^{
        self.cacheExpirations[key] = expirationDate;
    });
}

- (NSURLSessionDownloadTask *)download:(NSString *)url 
                                toPath:(NSString *)path
                              progress:(void (^)(NSProgress *progress))progressHandler
                            completion:(void (^)(NSURL *location, NSError *_Nullable error))completion {
    
    // Create the directory path if it doesn't exist
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
        return nil;
    }
    
    // Check if file already exists with the same size/hash
    if ([[NSFileManager defaultManager] fileExistsAtPath:path]) {
        // Get file attributes
        NSError *attrError = nil;
        NSDictionary *attributes = [[NSFileManager defaultManager] attributesOfItemAtPath:path error:&attrError];
        
        if (!attrError) {
            // Perform a HEAD request to check if file is already up-to-date
            NSMutableURLRequest *headRequest = [NSMutableURLRequest requestWithURL:[NSURL URLWithString:url]];
            headRequest.HTTPMethod = @"HEAD";
            headRequest.timeoutInterval = 10.0;
            
            NSURLSessionDataTask *headTask = [self.sessionManager.session dataTaskWithRequest:headRequest completionHandler:^(NSData * _Nullable data, NSURLResponse * _Nullable response, NSError * _Nullable error) {
                if (!error && [response isKindOfClass:[NSHTTPURLResponse class]]) {
                    NSHTTPURLResponse *httpResponse = (NSHTTPURLResponse *)response;
                    
                    // Compare file size if Content-Length is available
                    NSString *contentLength = httpResponse.allHeaderFields[@"Content-Length"];
                    if (contentLength) {
                        NSUInteger remoteSize = [contentLength longLongValue];
                        NSUInteger localSize = [attributes fileSize];
                        
                        if (remoteSize == localSize) {
                            // File is likely the same, skip download
                            dispatch_async(dispatch_get_main_queue(), ^{
                                if (completion) {
                                    completion([NSURL fileURLWithPath:path], nil);
                                }
                            });
                            return;
                        }
                    }
                }
                
                // File is different or HEAD request failed, proceed with download
                [self performDownloadToPath:path fromURL:url progressHandler:progressHandler completion:completion];
            }];
            
            [headTask resume];
            NSURLSessionDownloadTask *downloadTask = [self performDownloadToPath:path fromURL:url progressHandler:progressHandler completion:completion];
return downloadTask;
        }
    }
    
    // File doesn't exist or attributes couldn't be read, perform the download
    return [self performDownloadToPath:path fromURL:url progressHandler:progressHandler completion:completion];
}

- (NSURLSessionDownloadTask *)performDownloadToPath:(NSString *)path 
                                            fromURL:(NSString *)url 
                                    progressHandler:(void (^)(NSProgress *progress))progressHandler 
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
        objc_setAssociatedObject(task, @"progressHandler", progressHandler, OBJC_ASSOCIATION_COPY_NONATOMIC);
        
        // Add throttling to avoid too frequent progress updates
        NSOperationQueue *mainQueue = [NSOperationQueue mainQueue];
        __block NSDate *lastUpdateTime = [NSDate date];
        objc_setAssociatedObject(task, @"lastUpdateTime", lastUpdateTime, OBJC_ASSOCIATION_RETAIN_NONATOMIC);
        
        [task addObserver:self forKeyPath:@"countOfBytesReceived" options:NSKeyValueObservingOptionNew context:NULL];
    }
    
    [task resume];
    return task;
}

- (void)observeValueForKeyPath:(NSString *)keyPath ofObject:(id)object change:(NSDictionary<NSKeyValueChangeKey,id> *)change context:(void *)context {
    if ([object isKindOfClass:[NSURLSessionDownloadTask class]] && [keyPath isEqualToString:@"countOfBytesReceived"]) {
        NSURLSessionDownloadTask *task = (NSURLSessionDownloadTask *)object;
        void (^progressHandler)(NSProgress *) = objc_getAssociatedObject(task, @"progressHandler");
        
        if (progressHandler) {
            // Throttle updates to reduce UI workload
            NSDate *lastUpdateTime = objc_getAssociatedObject(task, @"lastUpdateTime");
            NSDate *now = [NSDate date];
            
            if ([now timeIntervalSinceDate:lastUpdateTime] < 0.1) {
                // Too soon, skip this update
                return;
            }
            
            objc_setAssociatedObject(task, @"lastUpdateTime", now, OBJC_ASSOCIATION_RETAIN_NONATOMIC);
            
            // Create progress object
            NSProgress *progress = [NSProgress progressWithTotalUnitCount:task.countOfBytesExpectedToReceive];
            progress.completedUnitCount = task.countOfBytesReceived;
            
            // Dispatch to main queue
            dispatch_async(dispatch_get_main_queue(), ^{
                progressHandler(progress);
            });
        }
    } else {
        [super observeValueForKeyPath:keyPath ofObject:object change:change context:context];
    }
}

- (void)clearCache {
    [self.responseCache removeAllObjects];
    dispatch_async(self.cacheQueue, ^{
        [self.cacheExpirations removeAllObjects];
    });
}

@end

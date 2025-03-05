#import "ModrinthAPI.h"
#import "MinecraftResourceDownloadTask.h"
#import "PLProfiles.h"
#import "AFNetworking.h"
#import "UIAlertUtilities.h"

@interface ModrinthAPI ()
@property (nonatomic, strong) AFHTTPSessionManager *sessionManager;
@property (nonatomic, strong) NSCache *responseCache;
@property (nonatomic, strong) NSOperationQueue *operationQueue;
@end

@implementation ModrinthAPI

#pragma mark - Initialization

+ (instancetype)defaultAPI {
    return [[self alloc] initWithURL:@"https://api.modrinth.com/v2"];
}

- (instancetype)init {
    return [self initWithURL:@"https://api.modrinth.com/v2"];
}

- (instancetype)initWithURL:(NSString *)url {
    self = [super initWithURL:url];
    if (self) {
        // Initialize session manager
        _sessionManager = [AFHTTPSessionManager manager];
        _sessionManager.requestSerializer = [AFJSONRequestSerializer serializer];
        _sessionManager.responseSerializer = [AFJSONResponseSerializer serializer];
        _sessionManager.completionQueue = dispatch_get_global_queue(DISPATCH_QUEUE_PRIORITY_DEFAULT, 0);
        
        // Initialize response cache
        _responseCache = [[NSCache alloc] init];
        _responseCache.countLimit = 100; // Cache up to 100 responses
        
        // Initialize operation queue
        _operationQueue = [[NSOperationQueue alloc] init];
        _operationQueue.maxConcurrentOperationCount = 4; // Limit concurrent operations
    }
    return self;
}

#pragma mark - Caching

- (NSString *)cacheKeyForEndpoint:(NSString *)endpoint params:(NSDictionary *)params {
    NSData *paramsData = [NSJSONSerialization dataWithJSONObject:params ?: @{} options:0 error:nil];
    NSString *paramsStr = paramsData ? [[NSString alloc] initWithData:paramsData encoding:NSUTF8StringEncoding] : @"";
    return [NSString stringWithFormat:@"%@-%@", endpoint, paramsStr];
}

- (id)getCachedResponseForEndpoint:(NSString *)endpoint params:(NSDictionary *)params {
    NSString *cacheKey = [self cacheKeyForEndpoint:endpoint params:params];
    return [self.responseCache objectForKey:cacheKey];
}

- (void)cacheResponse:(id)response forEndpoint:(NSString *)endpoint params:(NSDictionary *)params {
    if (!response) return;
    NSString *cacheKey = [self cacheKeyForEndpoint:endpoint params:params];
    [self.responseCache setObject:response forKey:cacheKey];
}

#pragma mark - Retry Mechanism

- (void)requestWithRetry:(NSString *)endpoint 
                  params:(NSDictionary *)params 
             maxAttempts:(NSUInteger)maxAttempts 
          currentAttempt:(NSUInteger)currentAttempt 
              completion:(void (^)(id response, NSError *error))completion {
    
    [self getEndpoint:endpoint params:params completion:^(id response, NSError *error) {
        if (error && currentAttempt < maxAttempts) {
            // Calculate delay with exponential backoff
            NSTimeInterval delay = pow(2, currentAttempt) * 0.5; // 0.5, 1, 2, 4, 8...
            
            dispatch_after(dispatch_time(DISPATCH_TIME_NOW, (int64_t)(delay * NSEC_PER_SEC)), 
                           dispatch_get_global_queue(DISPATCH_QUEUE_PRIORITY_DEFAULT, 0), ^{
                [self requestWithRetry:endpoint 
                               params:params 
                          maxAttempts:maxAttempts 
                       currentAttempt:currentAttempt+1 
                           completion:completion];
            });
        } else {
            if (completion) {
                completion(response, error);
            }
        }
    }];
}

#pragma mark - Queue Management

- (void)queueOperation:(void (^)(void))block withPriority:(NSOperationQueuePriority)priority {
    NSBlockOperation *operation = [NSBlockOperation blockOperationWithBlock:block];
    operation.queuePriority = priority;
    [self.operationQueue addOperation:operation];
}

#pragma mark - Network Requests

- (void)getEndpoint:(NSString *)endpoint params:(NSDictionary *)params completion:(void (^)(id, NSError *))completion {
    // Check cache first
    id cachedResponse = [self getCachedResponseForEndpoint:endpoint params:params];
    if (cachedResponse) {
        NSLog(@"getEndpoint: Cache hit for %@", endpoint);
        if (completion) completion(cachedResponse, nil);
        return;
    }
    
    NSString *url = [self.baseURL stringByAppendingPathComponent:endpoint];
    
    [self.sessionManager GET:url parameters:params headers:nil progress:nil success:^(NSURLSessionTask *task, id responseObject) {
        // Cache the response
        [self cacheResponse:responseObject forEndpoint:endpoint params:params];
        
        if (completion) completion(responseObject, nil);
    } failure:^(NSURLSessionTask *operation, NSError *error) {
        self.lastError = error;
        NSLog(@"getEndpoint: Failed for %@: %@", endpoint, error);
        
        if (completion) completion(nil, error);
    }];
}

#pragma mark - String Encoding

- (NSString *)encodedSearchQuery:(NSString *)query {
    // Replace multiple spaces with a single space
    NSString *trimmed = [query stringByTrimmingCharactersInSet:[NSCharacterSet whitespaceAndNewlineCharacterSet]];
    NSArray *components = [trimmed componentsSeparatedByCharactersInSet:[NSCharacterSet whitespaceCharacterSet]];
    components = [components filteredArrayUsingPredicate:[NSPredicate predicateWithFormat:@"length > 0"]];
    NSString *normalizedQuery = [components componentsJoinedByString:@" "];
    
    // Now encode properly for URL
    return [normalizedQuery stringByAddingPercentEncodingWithAllowedCharacters:[NSCharacterSet URLQueryAllowedCharacterSet]];
}

#pragma mark - Facets Construction

- (NSString *)createFacetsJSON:(NSDictionary *)filters {
    NSMutableArray *facets = [NSMutableArray array];
    
    // Project type facet (mod/modpack)
    BOOL isModpack = [filters[@"isModpack"] boolValue];
    [facets addObject:@[[NSString stringWithFormat:@"project_type:%@", isModpack ? @"modpack" : @"mod"]]];
    
    // Minecraft version facet
    NSString *mcVersion = filters[@"mcVersion"];
    if (mcVersion.length > 0) {
        [facets addObject:@[[NSString stringWithFormat:@"versions:%@", mcVersion]]];
    }
    
    // Categories facet
    NSArray *categories = filters[@"categories"];
    if ([categories isKindOfClass:[NSArray class]] && categories.count > 0) {
        NSMutableArray *categoryFacets = [NSMutableArray array];
        for (NSString *category in categories) {
            [categoryFacets addObject:[NSString stringWithFormat:@"categories:%@", category]];
        }
        [facets addObject:categoryFacets];
    }
    
    // Loader types facet
    NSString *loader = filters[@"loader"];
    if (loader.length > 0) {
        [facets addObject:@[[NSString stringWithFormat:@"categories:%@", loader]]];
    }
    
    NSError *error = nil;
    NSData *facetsData = [NSJSONSerialization dataWithJSONObject:facets options:0 error:&error];
    if (error) {
        NSLog(@"Error creating facets JSON: %@", error);
        return @"[]";
    }
    
    return [[NSString alloc] initWithData:facetsData encoding:NSUTF8StringEncoding] ?: @"[]";
}

#pragma mark - Version Filtering

- (NSArray *)filterVersionsForGameVersion:(NSString *)gameVersion 
                                   loader:(NSString *)loader 
                             fromVersions:(NSArray *)versions {
    NSMutableArray *filtered = [NSMutableArray array];
    
    for (NSDictionary *version in versions) {
        // Check game version compatibility
        NSArray *gameVersions = version[@"game_versions"];
        BOOL matchesGameVersion = NO;
        
        if (!gameVersion || gameVersion.length == 0) {
            matchesGameVersion = YES;
        } else {
            for (NSString *versionStr in gameVersions) {
                if ([versionStr isEqualToString:gameVersion] || 
                    [versionStr hasPrefix:[gameVersion stringByAppendingString:@"."]] ||
                    [gameVersion hasPrefix:[versionStr stringByAppendingString:@"."]]) {
                    matchesGameVersion = YES;
                    break;
                }
            }
        }
        
        if (!matchesGameVersion) continue;
        
        // Check loader compatibility
        NSArray *loaders = version[@"loaders"];
        BOOL matchesLoader = NO;
        
        if (!loader || loader.length == 0) {
            matchesLoader = YES;
        } else {
            for (NSString *loaderStr in loaders) {
                if ([loaderStr caseInsensitiveCompare:loader] == NSOrderedSame) {
                    matchesLoader = YES;
                    break;
                }
            }
        }
        
        if (matchesLoader) {
            [filtered addObject:version];
        }
    }
    
    return filtered;
}

#pragma mark - Search Implementation

- (NSMutableArray *)searchModWithFilters:(NSDictionary<NSString *, id> *)searchFilters
                       previousPageResult:(NSMutableArray *)modrinthSearchResult {
    __block NSMutableArray *result = nil;
    
    // Use operation queue for better task management
    dispatch_semaphore_t semaphore = dispatch_semaphore_create(0);
    
    [self queueOperation:^{
        // Create proper facets
        NSString *facetsParam = [self createFacetsJSON:searchFilters];
        
        // Encode search query properly
        NSString *rawName = (searchFilters[@"name"] != nil ? searchFilters[@"name"] : @"");
        NSString *nameQuery = [self encodedSearchQuery:rawName];
        
        int limit = 20;
        NSDictionary *params = @{
            @"limit": @(limit),
            @"index": @"relevance",
            @"facets": facetsParam,
            @"offset": @(modrinthSearchResult.count),
            @"query": nameQuery
        };
        
        // Use retry mechanism
        [self requestWithRetry:@"search" params:params maxAttempts:3 currentAttempt:0 completion:^(id response, NSError *error) {
            if (!response) {
                NSLog(@"[ModrinthAPI] searchModWithFilters: No response returned");
                self.lastError = error ?: [NSError errorWithDomain:@"ModrinthAPIErrorDomain" 
                                                             code:100 
                                                         userInfo:@{NSLocalizedDescriptionKey: @"Search request failed"}];
                dispatch_semaphore_signal(semaphore);
                return;
            }
            
            result = modrinthSearchResult ?: [NSMutableArray new];
            NSArray *hits = response[@"hits"];
            if ([hits isKindOfClass:[NSArray class]]) {
                for (NSDictionary *hit in hits) {
                    if (![hit isKindOfClass:[NSDictionary class]]) {
                        continue;
                    }
                    
                    NSString *projectType = hit[@"project_type"];
                    BOOL isModpack = [projectType isKindOfClass:[NSString class]] && [projectType isEqualToString:@"modpack"];
                    
                    NSMutableDictionary *entry = [@{
                        @"apiSource": @(1),
                        @"isModpack": @(isModpack),
                        @"id": hit[@"project_id"] ?: @"",
                        @"title": hit[@"title"] ?: @"",
                        @"description": hit[@"description"] ?: @"",
                        @"imageUrl": hit[@"icon_url"] ?: @""
                    } mutableCopy];
                    
                    [result addObject:entry];
                }
            }
            
            // Check if we've reached the last page
            NSNumber *totalHits = response[@"total_hits"];
            if ([totalHits isKindOfClass:[NSNumber class]]) {
                self.reachedLastPage = result.count >= [totalHits unsignedLongValue];
            } else {
                self.reachedLastPage = YES;
            }
            
            dispatch_semaphore_signal(semaphore);
        }];
    } withPriority:NSOperationQueuePriorityNormal];
    
    // Wait for completion
    dispatch_semaphore_wait(semaphore, DISPATCH_TIME_FOREVER);
    
    return result;
}

#pragma mark - Load Details Implementation

- (void)loadDetailsOfMod:(NSMutableDictionary *)item {
    [self loadDetailsOfMod:item completion:^(NSError *error) {}];
}

- (void)loadDetailsOfModSync:(NSMutableDictionary *)item {
    if (!item || ![item isKindOfClass:[NSMutableDictionary class]]) {
        NSLog(@"loadDetailsOfModSync: Invalid item");
        return;
    }
    
    NSString *modId = item[@"id"];
    if (!modId || ![modId isKindOfClass:[NSString class]] || modId.length == 0) {
        NSLog(@"loadDetailsOfModSync: Missing mod ID");
        return;
    }
    
    // Use operation queue for better task management
    dispatch_semaphore_t semaphore = dispatch_semaphore_create(0);
    __block NSArray *response = nil;
    
    [self queueOperation:^{
        NSString *endpoint = [NSString stringWithFormat:@"project/%@/version", modId];
        
        // Use retry mechanism
        [self requestWithRetry:endpoint params:@{} maxAttempts:3 currentAttempt:0 completion:^(id result, NSError *error) {
            response = result;
            dispatch_semaphore_signal(semaphore);
        }];
    } withPriority:NSOperationQueuePriorityHigh];
    
    // Wait for completion
    dispatch_semaphore_wait(semaphore, DISPATCH_TIME_FOREVER);
    
    if (!response) {
        NSLog(@"loadDetailsOfModSync: No response for mod id %@", modId);
        return;
    }
    
    if (![response isKindOfClass:[NSArray class]]) {
        NSLog(@"loadDetailsOfModSync: Unexpected response type: %@", [response class]);
        return;
    }
    
    NSMutableArray *versionNames = [NSMutableArray new];
    NSMutableArray *gameVersionsArray = [NSMutableArray new];
    NSMutableArray *versionUrls = [NSMutableArray new];
    NSMutableArray *versionSizes = [NSMutableArray new];
    NSMutableArray *versionHashes = [NSMutableArray new];
    NSMutableArray *versionLoaders = [NSMutableArray new];
    
    for (NSDictionary *versionDict in response) {
        if (![versionDict isKindOfClass:[NSDictionary class]]) {
            continue;
        }
        
        // Extract version display name
        NSString *versionDisplay = versionDict[@"version_number"] ?: versionDict[@"name"] ?: @"";
        
        // Extract game versions
        NSArray *supportedGameVersions = versionDict[@"game_versions"];
        if (![supportedGameVersions isKindOfClass:[NSArray class]]) {
            supportedGameVersions = @[];
        }
        
        // Extract file info
        NSArray *files = versionDict[@"files"];
        if (![files isKindOfClass:[NSArray class]] || files.count == 0) {
            NSLog(@"loadDetailsOfModSync: Missing file info for version %@", versionDict);
            continue;
        }
        
        NSDictionary *file = files[0];
        if (![file isKindOfClass:[NSDictionary class]]) {
            continue;
        }
        
        NSString *url = file[@"url"] ?: @"";
        NSNumber *size = file[@"size"];
        if (![size isKindOfClass:[NSNumber class]]) {
            size = @0;
        }
        
        // Extract hashes
        NSDictionary *hashes = file[@"hashes"];
        NSString *sha1 = @"";
        if ([hashes isKindOfClass:[NSDictionary class]]) {
            sha1 = hashes[@"sha1"] ?: @"";
        }
        
        // Extract loaders
        NSArray *loaders = versionDict[@"loaders"];
        if (![loaders isKindOfClass:[NSArray class]]) {
            loaders = @[];
        }
        
        [versionNames addObject:versionDisplay];
        [gameVersionsArray addObject:supportedGameVersions];
        [versionUrls addObject:url];
        [versionSizes addObject:size];
        [versionHashes addObject:sha1];
        [versionLoaders addObject:loaders];
    }
    
    item[@"versionNames"] = versionNames;
    item[@"gameVersions"] = gameVersionsArray;
    item[@"versionUrls"] = versionUrls;
    item[@"versionSizes"] = versionSizes;
    item[@"versionHashes"] = versionHashes;
    item[@"versionLoaders"] = versionLoaders;
    item[@"versionDetailsLoaded"] = @(YES);
}

- (void)loadDetailsOfMod:(NSMutableDictionary *)item completion:(void (^)(NSError *error))completion {
    if (!item || ![item isKindOfClass:[NSMutableDictionary class]]) {
        NSError *error = [NSError errorWithDomain:@"ModrinthAPIErrorDomain" 
                                             code:101 
                                         userInfo:@{NSLocalizedDescriptionKey: @"Invalid item"}];
        if (completion) {
            completion(error);
        }
        return;
    }
    
    NSString *modId = item[@"id"];
    if (!modId || ![modId isKindOfClass:[NSString class]] || modId.length == 0) {
        NSError *error = [NSError errorWithDomain:@"ModrinthAPIErrorDomain" 
                                             code:102 
                                         userInfo:@{NSLocalizedDescriptionKey: @"Missing mod ID"}];
        if (completion) {
            completion(error);
        }
        return;
    }
    
    [self queueOperation:^{
        NSString *endpoint = [NSString stringWithFormat:@"project/%@/version", modId];
        __weak typeof(self) weakSelf = self;
        
        [self requestWithRetry:endpoint params:@{} maxAttempts:3 currentAttempt:0 completion:^(id response, NSError *error) {
            __strong typeof(weakSelf) strongSelf = weakSelf;
            
            if (!response) {
                NSLog(@"loadDetailsOfMod: No response for mod id %@, error: %@", modId, error);
                if (completion) {
                    completion(error);
                }
                return;
            }
            
            if (![response isKindOfClass:[NSArray class]]) {
                NSLog(@"loadDetailsOfMod: Unexpected response type: %@", [response class]);
                NSError *formatError = [NSError errorWithDomain:@"ModrinthAPIErrorDomain" 
                                                           code:103 
                                                       userInfo:@{NSLocalizedDescriptionKey:@"Unexpected response format"}];
                if (completion) {
                    completion(formatError);
                }
                return;
            }
            
            NSMutableArray *versionNames = [NSMutableArray new];
            NSMutableArray *gameVersionsArray = [NSMutableArray new];
            NSMutableArray *versionUrls = [NSMutableArray new];
            NSMutableArray *versionSizes = [NSMutableArray new];
            NSMutableArray *versionHashes = [NSMutableArray new];
            NSMutableArray *versionLoaders = [NSMutableArray new];
            
            NSArray *versionsArray = (NSArray *)response;
            
            // Use version filtering if we have game version or loader filters
            NSString *gameVersion = item[@"gameVersionFilter"];
            NSString *loader = item[@"loaderFilter"];
            
            if ((gameVersion && gameVersion.length > 0) || (loader && loader.length > 0)) {
                versionsArray = [strongSelf filterVersionsForGameVersion:gameVersion 
                                                                  loader:loader 
                                                            fromVersions:versionsArray];
            }
            
            for (NSDictionary *versionDict in versionsArray) {
                if (![versionDict isKindOfClass:[NSDictionary class]]) {
                    continue;
                }
                
                // Extract version display name
                NSString *versionDisplay = versionDict[@"version_number"] ?: versionDict[@"name"] ?: @"";
                
                // Extract game versions
                NSArray *supportedGameVersions = versionDict[@"game_versions"];
                if (![supportedGameVersions isKindOfClass:[NSArray class]]) {
                    supportedGameVersions = @[];
                }
                
                // Extract file info
                NSArray *files = versionDict[@"files"];
                if (![files isKindOfClass:[NSArray class]] || files.count == 0) {
                    NSLog(@"loadDetailsOfMod: Missing file info for version %@", versionDict);
                    continue;
                }
                
                NSDictionary *file = files[0];
                if (![file isKindOfClass:[NSDictionary class]]) {
                    continue;
                }
                
                NSString *url = file[@"url"] ?: @"";
                NSNumber *size = file[@"size"];
                if (![size isKindOfClass:[NSNumber class]]) {
                    size = @0;
                }
                
                // Extract hashes
                NSDictionary *hashes = file[@"hashes"];
                NSString *sha1 = @"";
                if ([hashes isKindOfClass:[NSDictionary class]]) {
                    sha1 = hashes[@"sha1"] ?: @"";
                }
                
                // Extract loaders
                NSArray *loaders = versionDict[@"loaders"];
                if (![loaders isKindOfClass:[NSArray class]]) {
                    loaders = @[];
                }
                
                [versionNames addObject:versionDisplay];
                [gameVersionsArray addObject:supportedGameVersions];
                [versionUrls addObject:url];
                [versionSizes addObject:size];
                [versionHashes addObject:sha1];
                [versionLoaders addObject:loaders];
            }
            
            dispatch_async(dispatch_get_main_queue(), ^{
                item[@"versionNames"] = versionNames;
                item[@"gameVersions"] = gameVersionsArray;
                item[@"versionUrls"] = versionUrls;
                item[@"versionSizes"] = versionSizes;
                item[@"versionHashes"] = versionHashes;
                item[@"versionLoaders"] = versionLoaders;
                item[@"versionDetailsLoaded"] = @(YES);
                
                NSLog(@"loadDetailsOfMod: Loaded %lu versions for mod %@", (unsigned long)versionNames.count, modId);
                
                if (completion) {
                    completion(nil);
                }
            });
        }];
    } withPriority:NSOperationQueuePriorityHigh];
}

#pragma mark - Mod Installation with Background Task Support

- (void)installModFromDetail:(NSDictionary *)modDetail atIndex:(NSUInteger)selectedVersion {
    if (!modDetail) {
        NSLog(@"[ModrinthAPI] Cannot install mod: nil modDetail");
        return;
    }
    
    // Use background task to ensure installation completes
    __block UIBackgroundTaskIdentifier backgroundTask = [[UIApplication sharedApplication] beginBackgroundTaskWithName:@"ModrinthInstall" expirationHandler:^{
        [[UIApplication sharedApplication] endBackgroundTask:backgroundTask];
        backgroundTask = UIBackgroundTaskInvalid;
    }];
    
    [self queueOperation:^{
        NSDictionary *userInfo = @{
            @"detail": modDetail,
            @"index": @(selectedVersion)
        };
        
        dispatch_async(dispatch_get_main_queue(), ^{
            [[NSNotificationCenter defaultCenter] postNotificationName:@"InstallMod" 
                                                                object:self 
                                                              userInfo:userInfo];
            
            // End the background task when done
            [[UIApplication sharedApplication] endBackgroundTask:backgroundTask];
            backgroundTask = UIBackgroundTaskInvalid;
        });
    } withPriority:NSOperationQueuePriorityHigh];
}

@end

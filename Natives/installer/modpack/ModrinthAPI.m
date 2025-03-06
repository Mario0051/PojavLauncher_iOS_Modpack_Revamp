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
    // Use previous working implementation with optimizations
    int limit = 50;

    NSMutableString *facetString = [NSMutableString new];
    [facetString appendString:@"["];
    [facetString appendFormat:@"[\"project_type:%@\"]", [searchFilters[@"isModpack"] boolValue] ? @"modpack" : @"mod"];
    if (searchFilters[@"mcVersion"] && [searchFilters[@"mcVersion"] length] > 0) {
        [facetString appendFormat:@",[\"versions:%@\"]", searchFilters[@"mcVersion"]];
    }
    [facetString appendString:@"]"];

    NSDictionary *params = @{
        @"facets": facetString,
        @"query": searchFilters[@"name"] ? [searchFilters[@"name"] stringByReplacingOccurrencesOfString:@" " withString:@"+"] : @"",
        @"limit": @(limit),
        @"index": @"relevance",
        @"offset": @(modrinthSearchResult.count)
    };
    
    // Check cache first
    NSString *cacheKey = [self cacheKeyForEndpoint:@"search" params:params];
    id cachedResponse = [self.responseCache objectForKey:cacheKey];
    if (cachedResponse) {
        NSLog(@"Cache hit for search query");
        
        NSDictionary *response = cachedResponse;
        NSMutableArray *result = modrinthSearchResult ?: [NSMutableArray new];
        for (NSDictionary *hit in response[@"hits"]) {
            BOOL isModpack = [hit[@"project_type"] isEqualToString:@"modpack"];
            [result addObject:@{
                @"apiSource": @(1), // Constant MODRINTH
                @"isModpack": @(isModpack),
                @"id": hit[@"project_id"],
                @"title": hit[@"title"],
                @"description": hit[@"description"],
                @"imageUrl": hit[@"icon_url"]
            }.mutableCopy];
        }
        self.reachedLastPage = result.count >= [response[@"total_hits"] unsignedLongValue];
        return result;
    }
    
    NSDictionary *response = [self getEndpoint:@"search" params:params];
    if (!response) {
        return nil;
    }

    // Cache the response
    [self.responseCache setObject:response forKey:cacheKey];

    NSMutableArray *result = modrinthSearchResult ?: [NSMutableArray new];
    for (NSDictionary *hit in response[@"hits"]) {
        BOOL isModpack = [hit[@"project_type"] isEqualToString:@"modpack"];
        [result addObject:@{
            @"apiSource": @(1), // Constant MODRINTH
            @"isModpack": @(isModpack),
            @"id": hit[@"project_id"],
            @"title": hit[@"title"],
            @"description": hit[@"description"],
            @"imageUrl": hit[@"icon_url"]
        }.mutableCopy];
    }
    self.reachedLastPage = result.count >= [response[@"total_hits"] unsignedLongValue];
    return result;
}

#pragma mark - Load Details Implementation

- (void)loadDetailsOfMod:(NSMutableDictionary *)item {
    // Use the previously working implementation that's been proven to work
    NSArray *response = [self getEndpoint:[NSString stringWithFormat:@"project/%@/version", item[@"id"]] params:nil];
    if (!response) {
        return;
    }
    
    NSMutableArray<NSString *> *names = [NSMutableArray new];
    NSMutableArray<NSString *> *mcNames = [NSMutableArray new];
    NSMutableArray<NSString *> *urls = [NSMutableArray new];
    NSMutableArray<NSNumber *> *sizes = [NSMutableArray new];
    NSMutableArray<NSString *> *hashes = [NSMutableArray new];
    NSMutableArray<NSArray *> *loaders = [NSMutableArray new];
    
    for (NSDictionary *version in response) {
        // Version name
        NSString *versionName = version[@"name"];
        if (!versionName) {
            versionName = version[@"version_number"] ?: @"Unknown";
        }
        [names addObject:versionName];
        
        // Game versions
        NSArray *gameVersions = version[@"game_versions"];
        [mcNames addObject:gameVersions.firstObject ?: @""];
        
        // Files
        NSArray *files = version[@"files"];
        NSDictionary *file = files.firstObject;
        
        // URL
        NSString *url = file[@"url"] ?: @"";
        [urls addObject:url];
        
        // Size
        NSNumber *size = file[@"size"] ?: @0;
        [sizes addObject:size];
        
        // Hash
        NSDictionary *hashesDict = file[@"hashes"];
        NSString *sha1 = hashesDict[@"sha1"] ?: @"";
        [hashes addObject:sha1];
        
        // Loaders
        NSArray *versionLoaders = version[@"loaders"] ?: @[];
        [loaders addObject:versionLoaders];
    }
    
    // Update the item dictionary with all the collected information
    item[@"versionNames"] = names;
    item[@"mcVersionNames"] = mcNames;
    item[@"versionUrls"] = urls;
    item[@"versionSizes"] = sizes;
    item[@"versionHashes"] = hashes;
    item[@"versionLoaders"] = loaders;
    item[@"versionDetailsLoaded"] = @(YES);
    
    NSLog(@"loadDetailsOfMod: Loaded %lu versions for mod %@", (unsigned long)names.count, item[@"id"]);
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
    
    [self loadDetailsOfMod:item];
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

#pragma mark - Modpack Installation

- (void)downloader:(MinecraftResourceDownloadTask *)downloader submitDownloadTasksFromPackage:(NSString *)packagePath toPath:(NSString *)destPath {
    NSError *error;
    UZKArchive *archive = [[UZKArchive alloc] initWithPath:packagePath error:&error];
    if (error) {
        NSLog(@"[ModrinthAPI] Failed to open modpack package: %@", error.localizedDescription);
        dispatch_async(dispatch_get_main_queue(), ^{
            downloader.textProgress.localizedDescription = [NSString stringWithFormat:@"Error: %@", error.localizedDescription];
        });
        return;
    }

    // Extract and parse the index file
    NSData *indexData = [archive extractDataFromFile:@"modrinth.index.json" error:&error];
    if (!indexData) {
        NSLog(@"[ModrinthAPI] Failed to extract modrinth.index.json: %@", error.localizedDescription);
        dispatch_async(dispatch_get_main_queue(), ^{
            downloader.textProgress.localizedDescription = @"Error: Failed to extract modpack index";
        });
        return;
    }
    
    NSDictionary* indexDict = [NSJSONSerialization JSONObjectWithData:indexData options:0 error:&error];
    if (error) {
        NSLog(@"[ModrinthAPI] Failed to parse modrinth.index.json: %@", error.localizedDescription);
        dispatch_async(dispatch_get_main_queue(), ^{
            downloader.textProgress.localizedDescription = @"Error: Failed to parse modpack index";
        });
        return;
    }

    // Set up progress tracking
    NSArray *files = indexDict[@"files"];
    if (!files || ![files isKindOfClass:[NSArray class]]) {
        NSLog(@"[ModrinthAPI] Invalid files list in modpack index");
        dispatch_async(dispatch_get_main_queue(), ^{
            downloader.textProgress.localizedDescription = @"Error: Invalid files list in modpack";
        });
        return;
    }
    
    // Update progress display
    dispatch_async(dispatch_get_main_queue(), ^{
        downloader.progress.totalUnitCount = [files count] + 2; // Files + extraction + setup
        downloader.textProgress.localizedDescription = [NSString stringWithFormat:@"Installing %@ (%lu files)", 
                                                        indexDict[@"name"] ?: @"Modpack", 
                                                        (unsigned long)files.count];
    });
    
    // Download each file
    for (NSDictionary *indexFile in files) {
        if (![indexFile isKindOfClass:[NSDictionary class]]) {
            continue;
        }
        
        NSArray *downloads = indexFile[@"downloads"];
        if (![downloads isKindOfClass:[NSArray class]] || downloads.count == 0) {
            NSLog(@"[ModrinthAPI] Missing download URLs for file, skipping");
            continue;
        }
        
        NSString *url = [downloads firstObject];
        if (![url isKindOfClass:[NSString class]] || url.length == 0) {
            NSLog(@"[ModrinthAPI] Invalid download URL for file, skipping");
            continue;
        }
        
        NSDictionary *hashes = indexFile[@"hashes"];
        NSString *sha = [hashes isKindOfClass:[NSDictionary class]] ? hashes[@"sha1"] : nil;
        
        NSString *path = [destPath stringByAppendingPathComponent:indexFile[@"path"]];
        NSNumber *fileSizeNumber = indexFile[@"fileSize"];
        NSUInteger size = [fileSizeNumber isKindOfClass:[NSNumber class]] ? [fileSizeNumber unsignedLongLongValue] : 0;
        
        // Create directory structure
        NSString *dirPath = [path stringByDeletingLastPathComponent];
        if (![NSFileManager.defaultManager fileExistsAtPath:dirPath]) {
            [NSFileManager.defaultManager createDirectoryAtPath:dirPath withIntermediateDirectories:YES attributes:nil error:nil];
        }
        
        // Get a file name for display (just the last component)
        NSString *fileName = [path lastPathComponent];
        
        // Add to file list for progress tracking
        dispatch_async(dispatch_get_main_queue(), ^{
            [downloader.fileList addObject:fileName];
            
            // Create progress for this file
            NSProgress *fileProgress = [NSProgress progressWithTotalUnitCount:1];
            fileProgress.kind = NSProgressKindFile;
            [downloader.progressList addObject:fileProgress];
            [downloader.progress addChild:fileProgress withPendingUnitCount:1];
        });
        
        // Create and start download task
        NSURLSessionDownloadTask *task = [downloader createDownloadTask:url size:size sha:sha altName:nil toPath:path];
        if (task) {
            [task resume];
        } else if (!downloader.progress.cancelled) {
            downloader.progress.completedUnitCount++;
        } else {
            NSLog(@"[ModrinthAPI] Download cancelled");
            return; // cancelled
        }
    }

    // Show extraction progress
    dispatch_async(dispatch_get_main_queue(), ^{
        downloader.textProgress.localizedDescription = @"Extracting overrides";
        [downloader.fileList addObject:@"Extracting overrides"];
        
        // Create progress for extraction
        NSProgress *extractProgress = [NSProgress progressWithTotalUnitCount:1];
        extractProgress.kind = NSProgressKindFile;
        [downloader.progressList addObject:extractProgress];
        [downloader.progress addChild:extractProgress withPendingUnitCount:1];
    });
    
    // Extract overrides
    [ModpackUtils archive:archive extractDirectory:@"overrides" toPath:destPath error:&error];
    if (error) {
        NSLog(@"[ModrinthAPI] Failed to extract overrides: %@", error.localizedDescription);
        dispatch_async(dispatch_get_main_queue(), ^{
            downloader.textProgress.localizedDescription = [NSString stringWithFormat:@"Warning: %@", error.localizedDescription];
        });
        // Continue anyway - don't return here as it's not fatal
    } else {
        // Mark extraction as complete
        dispatch_async(dispatch_get_main_queue(), ^{
            NSProgress *extractProgress = [downloader.progressList lastObject];
            extractProgress.completedUnitCount = 1;
        });
    }

    // Extract client-overrides if present
    [ModpackUtils archive:archive extractDirectory:@"client-overrides" toPath:destPath error:&error];
    // We don't fail if client-overrides extraction fails - it's optional
    
    // Delete package cache
    [NSFileManager.defaultManager removeItemAtPath:packagePath error:nil];
    
    // Show profile setup progress
    dispatch_async(dispatch_get_main_queue(), ^{
        downloader.textProgress.localizedDescription = @"Setting up profile";
        [downloader.fileList addObject:@"Setting up profile"];
        
        // Create progress for profile setup
        NSProgress *setupProgress = [NSProgress progressWithTotalUnitCount:1];
        setupProgress.kind = NSProgressKindFile;
        [downloader.progressList addObject:setupProgress];
        [downloader.progress addChild:setupProgress withPendingUnitCount:1];
    });

    // Download dependency client json (if available)
    NSDictionary<NSString *, NSString *> *depInfo = [ModpackUtils infoForDependencies:indexDict[@"dependencies"]];
    if (depInfo[@"json"]) {
        NSString *jsonPath = [NSString stringWithFormat:@"%1$s/versions/%2$@/%2$@.json", getenv("POJAV_GAME_DIR"), depInfo[@"id"]];
        
        // Create directory structure for the JSON file
        [NSFileManager.defaultManager createDirectoryAtPath:[jsonPath stringByDeletingLastPathComponent] 
                              withIntermediateDirectories:YES attributes:nil error:nil];
                              
        NSURLSessionDownloadTask *jsonTask = [downloader createDownloadTask:depInfo[@"json"] size:0 sha:nil altName:nil toPath:jsonPath];
        if (jsonTask) {
            [jsonTask resume];
        }
    }

    // Create profile
    NSString *tmpIconPath = [NSTemporaryDirectory() stringByAppendingPathComponent:@"icon.png"];
    NSString *iconBase64 = @"";
    NSData *iconData = [NSData dataWithContentsOfFile:tmpIconPath];
    if (iconData) {
        iconBase64 = [iconData base64EncodedStringWithOptions:0];
    }
    
    // Update the profile
    dispatch_async(dispatch_get_main_queue(), ^{
        // Create the profile with the modpack info
        PLProfiles.current.profiles[indexDict[@"name"]] = @{
            @"gameDir": [NSString stringWithFormat:@"./profiles/%@", destPath.lastPathComponent],
            @"name": indexDict[@"name"],
            @"lastVersionId": depInfo[@"id"],
            @"icon": iconBase64.length > 0 ? [NSString stringWithFormat:@"data:image/png;base64,%@", iconBase64] : @""
        }.mutableCopy;
        
        PLProfiles.current.selectedProfileName = indexDict[@"name"];
        [PLProfiles.current save];
        
        // Mark profile setup as complete
        NSProgress *setupProgress = [downloader.progressList lastObject];
        setupProgress.completedUnitCount = 1;
        
        // Update progress to show completion
        downloader.textProgress.localizedDescription = @"Modpack installation complete";
    });
    
    // Create installation log
    NSString *logContent = [NSString stringWithFormat:@"Modrinth modpack installation completed\n"
                          "Name: %@\n"
                          "Version: %@\n"
                          "Directory: %@\n"
                          "Date: %@",
                          indexDict[@"name"],
                          indexDict[@"versionId"],
                          destPath,
                          [NSDate date]];
    
    [logContent writeToFile:[destPath stringByAppendingPathComponent:@"modrinth_install.log"]
                 atomically:YES
                   encoding:NSUTF8StringEncoding
                      error:nil];
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

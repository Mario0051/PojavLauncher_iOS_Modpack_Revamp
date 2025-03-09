#import "ModrinthAPI.h"
#import "MinecraftResourceDownloadTask.h"
#import "PLProfiles.h"
#import "ModpackUtils.h"
#import "AFNetworking.h"
#import "UIAlertUtilities.h"
#import "UnzipKit.h"
#import "utils.h"

// Constants
static NSString * const kModrinthAPIErrorDomain = @"ModrinthAPIErrorDomain";
static NSTimeInterval const kDefaultRequestTimeout = 30.0;
static NSUInteger const kDefaultCacheLimit = 100;
static NSUInteger const kMaxConcurrentOperations = 4;
static NSUInteger const kMaxRetryAttempts = 3;
static NSUInteger const kDefaultPageSize = 50;

// Error codes
typedef NS_ENUM(NSInteger, ModrinthErrorCode) {
    ModrinthErrorCodeNetwork = 1000,
    ModrinthErrorCodeParsing = 1001,
    ModrinthErrorCodeResourceNotFound = 1002,
    ModrinthErrorCodeExtraction = 1003,
    ModrinthErrorCodeInvalidManifest = 1004
};

@interface ModrinthAPI ()
@property (nonatomic, strong) AFHTTPSessionManager *sessionManager;
@property (nonatomic, strong) NSCache *responseCache;
@property (nonatomic, strong) NSOperationQueue *operationQueue;
@property (nonatomic, strong) dispatch_queue_t downloadQueue;
@property (nonatomic, strong) dispatch_semaphore_t downloadSemaphore;
@end

@implementation ModrinthAPI

#pragma mark - Initialization

+ (instancetype)defaultAPI {
    return [[self alloc] initWithURL:@"https://api.modrinth.com/v2"];
}

- (instancetype)initWithURL:(NSString *)url {
    self = [super initWithURL:url];
    if (self) {
        // Configure network manager with improved settings
        NSURLSessionConfiguration *config = [NSURLSessionConfiguration defaultSessionConfiguration];
        config.timeoutIntervalForRequest = kDefaultRequestTimeout;
        config.HTTPMaximumConnectionsPerHost = 10;
        _sessionManager = [[AFHTTPSessionManager alloc] initWithSessionConfiguration:config];
        _sessionManager.requestSerializer = [AFJSONRequestSerializer serializer];
        _sessionManager.responseSerializer = [AFJSONResponseSerializer serializer];
        _sessionManager.completionQueue = dispatch_get_global_queue(DISPATCH_QUEUE_PRIORITY_DEFAULT, 0);
        
        // Initialize response cache with appropriate limits
        _responseCache = [[NSCache alloc] init];
        _responseCache.countLimit = kDefaultCacheLimit;
        
        // Initialize operation queue with concurrency limits
        _operationQueue = [[NSOperationQueue alloc] init];
        _operationQueue.maxConcurrentOperationCount = kMaxConcurrentOperations;
        
        // Set up download queue with concurrency control
        _downloadQueue = dispatch_queue_create("com.modrinth.download", DISPATCH_QUEUE_CONCURRENT);
        _downloadSemaphore = dispatch_semaphore_create(kMaxConcurrentOperations);
        
        NSLog(@"ModrinthAPI: Initialized with URL: %@", url);
    }
    return self;
}

#pragma mark - Error Handling

- (NSError *)errorWithCode:(ModrinthErrorCode)code message:(NSString *)message underlyingError:(NSError *)underlyingError {
    NSMutableDictionary *userInfo = [NSMutableDictionary dictionary];
    userInfo[NSLocalizedDescriptionKey] = message;
    if (underlyingError) {
        userInfo[NSUnderlyingErrorKey] = underlyingError;
    }
    
    return [NSError errorWithDomain:kModrinthAPIErrorDomain code:code userInfo:userInfo];
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
            
            NSLog(@"[ModrinthAPI] Request failed, retrying in %.1f seconds (attempt %lu/%lu)", 
                  delay, (unsigned long)currentAttempt+1, (unsigned long)maxAttempts);
            
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

#pragma mark - Network Requests

- (void)getEndpoint:(NSString *)endpoint params:(NSDictionary *)params completion:(void (^)(id, NSError *))completion {
    if (!endpoint) {
        if (completion) {
            NSError *error = [self errorWithCode:ModrinthErrorCodeParsing 
                                         message:@"Invalid endpoint" 
                                 underlyingError:nil];
            dispatch_async(dispatch_get_main_queue(), ^{
                completion(nil, error);
            });
        }
        return;
    }
    
    // Check cache first (for non-critical requests)
    if (!params[@"skipCache"]) {
        id cachedResponse = [self getCachedResponseForEndpoint:endpoint params:params];
        if (cachedResponse) {
            NSLog(@"[ModrinthAPI] Cache hit for %@", endpoint);
            if (completion) {
                dispatch_async(dispatch_get_main_queue(), ^{
                    completion(cachedResponse, nil);
                });
            }
            return;
        }
    }
    
    NSString *url = [self.baseURL stringByAppendingPathComponent:endpoint];
    NSLog(@"[ModrinthAPI] Requesting %@ with params: %@", url, params);
    
    // Execute request
    [self.sessionManager GET:url parameters:params headers:nil progress:nil success:^(NSURLSessionTask *task, id responseObject) {
        NSLog(@"[ModrinthAPI] Success for %@", endpoint);
        
        // Cache the response (unless specified not to)
        if (!params[@"skipCache"]) {
            [self cacheResponse:responseObject forEndpoint:endpoint params:params];
        }
        
        if (completion) {
            dispatch_async(dispatch_get_main_queue(), ^{
                completion(responseObject, nil);
            });
        }
    } failure:^(NSURLSessionTask *operation, NSError *error) {
        self.lastError = error;
        NSLog(@"[ModrinthAPI] Failed for %@: %@", endpoint, error);
        
        // Parse HTTP status code for better error information
        NSHTTPURLResponse *httpResponse = (NSHTTPURLResponse *)operation.response;
        NSInteger statusCode = httpResponse ? httpResponse.statusCode : 0;
        
        NSError *apiError;
        if (statusCode == 404) {
            apiError = [self errorWithCode:ModrinthErrorCodeResourceNotFound 
                                   message:@"The requested resource was not found" 
                           underlyingError:error];
        } else {
            apiError = [self errorWithCode:ModrinthErrorCodeNetwork 
                                   message:@"A network error occurred" 
                           underlyingError:error];
        }
        
        if (completion) {
            dispatch_async(dispatch_get_main_queue(), ^{
                completion(nil, apiError);
            });
        }
    }];
}

- (id)getEndpoint:(NSString *)endpoint params:(NSDictionary *)params {
    if (!endpoint) {
        return nil;
    }
    
    // Check cache first
    id cachedResponse = [self getCachedResponseForEndpoint:endpoint params:params];
    if (cachedResponse) {
        return cachedResponse;
    }
    
    __block id result = nil;
    __block NSError *requestError = nil;
    
    dispatch_semaphore_t semaphore = dispatch_semaphore_create(0);
    [self getEndpoint:endpoint params:params completion:^(id response, NSError *error) {
        result = response;
        requestError = error;
        dispatch_semaphore_signal(semaphore);
    }];
    dispatch_semaphore_wait(semaphore, DISPATCH_TIME_FOREVER);
    
    if (!result) {
        NSLog(@"[ModrinthAPI] Synchronous request to %@ failed: %@", endpoint, requestError);
        self.lastError = requestError;
    }
    
    return result;
}

#pragma mark - Search Implementation

- (NSMutableArray *)searchModWithFilters:(NSDictionary *)searchFilters previousPageResult:(NSMutableArray *)prevResult {
    NSMutableString *facetString = [NSMutableString new];
    [facetString appendString:@"["];
    [facetString appendFormat:@"[\"project_type:%@\"]", [searchFilters[@"isModpack"] boolValue] ? @"modpack" : @"mod"];
    
    if (searchFilters[@"mcVersion"] && [searchFilters[@"mcVersion"] length] > 0) {
        [facetString appendFormat:@",[\"versions:%@\"]", searchFilters[@"mcVersion"]];
    }
    
    if (searchFilters[@"loader"] && [searchFilters[@"loader"] length] > 0) {
        [facetString appendFormat:@",[\"categories:%@\"]", searchFilters[@"loader"]];
    }
    
    [facetString appendString:@"]"];
    
    NSString *searchQuery = searchFilters[@"name"] ?: @"";
    NSString *formattedQuery = [searchQuery stringByReplacingOccurrencesOfString:@" " withString:@"+"];
    
    NSDictionary *params = @{
        @"facets": facetString,
        @"query": formattedQuery,
        @"limit": @(kDefaultPageSize),
        @"index": @"relevance",
        @"offset": @(prevResult.count)
    };
    
    // Try from cache first
    id cachedResponse = [self getCachedResponseForEndpoint:@"search" params:params];
    if (cachedResponse) {
        return [self processSearchResponse:cachedResponse previousResult:prevResult];
    }
    
    // Perform synchronous request
    __block NSDictionary *response = nil;
    __block NSError *requestError = nil;
    
    dispatch_semaphore_t semaphore = dispatch_semaphore_create(0);
    [self getEndpoint:@"search" params:params completion:^(id responseObject, NSError *error) {
        response = responseObject;
        requestError = error;
        dispatch_semaphore_signal(semaphore);
    }];
    dispatch_semaphore_wait(semaphore, DISPATCH_TIME_FOREVER);
    
    if (!response) {
        NSLog(@"[ModrinthAPI] Search failed: %@", requestError);
        return nil;
    }
    
    return [self processSearchResponse:response previousResult:prevResult];
}

- (NSMutableArray *)processSearchResponse:(NSDictionary *)response previousResult:(NSMutableArray *)prevResult {
    NSMutableArray *result = prevResult ?: [NSMutableArray new];
    NSArray *hits = response[@"hits"];
    
    if (![hits isKindOfClass:[NSArray class]]) {
        NSLog(@"[ModrinthAPI] Invalid search response format");
        return result;
    }
    
    for (NSDictionary *hit in hits) {
        BOOL isModpack = [hit[@"project_type"] isEqualToString:@"modpack"];
        
        // Process icon URL properly
        NSString *iconUrl = hit[@"icon_url"];
        // Ensure icon URL is valid and not null
        if ([iconUrl isEqual:[NSNull null]]) {
            iconUrl = @"";
        }
        
        NSMutableDictionary *entry = [@{
            @"apiSource": @(0), // 0 = Modrinth
            @"isModpack": @(isModpack),
            @"id": hit[@"project_id"] ?: @"",
            @"title": hit[@"title"] ?: @"",
            @"description": hit[@"description"] ?: @"",
            @"imageUrl": iconUrl ?: @""
        } mutableCopy];
        
        [result addObject:entry];
    }
    
    // Update pagination status
    NSUInteger totalCount = [response[@"total_hits"] unsignedLongValue];
    self.reachedLastPage = result.count >= totalCount;
    
    return result;
}

#pragma mark - Load Mod Details

- (void)loadDetailsOfMod:(NSMutableDictionary *)item completion:(void (^)(NSError *))completion {
    NSString *modId = item[@"id"];
    if (!modId || ![modId isKindOfClass:[NSString class]] || modId.length == 0) {
        NSError *error = [self errorWithCode:ModrinthErrorCodeParsing
                                     message:@"Invalid mod ID"
                             underlyingError:nil];
        if (completion) {
            completion(error);
        }
        return;
    }
    
    NSString *endpoint = [NSString stringWithFormat:@"project/%@/version", modId];
    
    [self requestWithRetry:endpoint params:nil maxAttempts:kMaxRetryAttempts currentAttempt:0 completion:^(id response, NSError *error) {
        if (!response) {
            NSLog(@"[ModrinthAPI] Failed to load versions for %@: %@", modId, error);
            if (completion) {
                completion(error);
            }
            return;
        }
        
        if (![response isKindOfClass:[NSArray class]]) {
            NSError *formatError = [self errorWithCode:ModrinthErrorCodeParsing
                                              message:@"Invalid response format"
                                      underlyingError:nil];
            if (completion) {
                completion(formatError);
            }
            return;
        }
        
        NSMutableArray *versionNames = [NSMutableArray new];
        NSMutableArray *mcVersionsArray = [NSMutableArray new];
        NSMutableArray *versionUrls = [NSMutableArray new];
        NSMutableArray *versionSizes = [NSMutableArray new];
        NSMutableArray *versionHashes = [NSMutableArray new];
        NSMutableArray *versionLoaders = [NSMutableArray new];
        
        NSArray *versions = (NSArray *)response;
        
        // Filter versions if needed
        NSString *gameVersionFilter = item[@"gameVersionFilter"];
        NSString *loaderFilter = item[@"loaderFilter"];
        
        for (NSDictionary *version in versions) {
            // Apply filters
            if (gameVersionFilter && gameVersionFilter.length > 0) {
                NSArray *gameVersions = version[@"game_versions"];
                BOOL matches = NO;
                
                for (NSString *gameVersion in gameVersions) {
                    if ([gameVersion isEqualToString:gameVersionFilter] ||
                        [gameVersion hasPrefix:[gameVersionFilter stringByAppendingString:@"."]] ||
                        [gameVersionFilter hasPrefix:[gameVersion stringByAppendingString:@"."]]) {
                        matches = YES;
                        break;
                    }
                }
                
                if (!matches) continue;
            }
            
            if (loaderFilter && loaderFilter.length > 0) {
                NSArray *loaders = version[@"loaders"];
                BOOL matches = NO;
                
                for (NSString *loader in loaders) {
                    if ([loader caseInsensitiveCompare:loaderFilter] == NSOrderedSame) {
                        matches = YES;
                        break;
                    }
                }
                
                if (!matches) continue;
            }
            
            // Extract version name
            NSString *versionName = version[@"version_number"] ?: version[@"name"] ?: @"Unknown";
            [versionNames addObject:versionName];
            
            // Extract game versions
            NSArray *gameVersions = version[@"game_versions"] ?: @[];
            [mcVersionsArray addObject:gameVersions];
            
            // Extract files
            NSArray *files = version[@"files"];
            if (![files isKindOfClass:[NSArray class]] || files.count == 0) {
                // Skip versions with no files
                continue;
            }
            
            // Get primary file
            NSDictionary *primaryFile = files[0];
            if (![primaryFile isKindOfClass:[NSDictionary class]]) {
                continue;
            }
            
            // Extract URL
            NSString *url = primaryFile[@"url"] ?: @"";
            [versionUrls addObject:url];
            
            // Extract size
            NSNumber *size = primaryFile[@"size"] ?: @0;
            [versionSizes addObject:size];
            
            // Extract hash
            NSString *sha1 = @"";
            NSDictionary *hashes = primaryFile[@"hashes"];
            if ([hashes isKindOfClass:[NSDictionary class]]) {
                sha1 = hashes[@"sha1"] ?: @"";
            }
            [versionHashes addObject:sha1];
            
            // Extract loaders
            NSArray *loaders = version[@"loaders"] ?: @[];
            [versionLoaders addObject:loaders];
        }
        
        dispatch_async(dispatch_get_main_queue(), ^{
            // Update the item with all version information
            item[@"versionNames"] = versionNames;
            item[@"mcVersionNames"] = mcVersionsArray;
            item[@"versionUrls"] = versionUrls;
            item[@"versionSizes"] = versionSizes;
            item[@"versionHashes"] = versionHashes;
            item[@"versionLoaders"] = versionLoaders;
            item[@"versionDetailsLoaded"] = @YES;
            
            NSLog(@"[ModrinthAPI] Loaded %lu versions for mod %@", (unsigned long)versionNames.count, modId);
            
            if (completion) {
                completion(nil);
            }
        });
    }];
}

#pragma mark - Modpack Installation

- (void)installModpackFromDetail:(NSDictionary *)modDetail atIndex:(NSUInteger)selectedVersion {
    // Skip the prompt and directly initiate installation
    NSDictionary *userInfo = @{
        @"detail": modDetail,
        @"index": @(selectedVersion)
    };
    
    dispatch_async(dispatch_get_main_queue(), ^{
        [[NSNotificationCenter defaultCenter] postNotificationName:@"InstallModpack" 
                                                          object:self 
                                                        userInfo:userInfo];
    });
}

- (void)downloader:(MinecraftResourceDownloadTask *)downloader submitDownloadTasksFromPackage:(NSString *)packagePath toPath:(NSString *)destPath {
    // Create a background queue for extraction operations
    dispatch_queue_t extractionQueue = dispatch_queue_create("com.modrinth.extraction", DISPATCH_QUEUE_CONCURRENT);
    
    // First add the extraction task to the UI
    dispatch_async(dispatch_get_main_queue(), ^{
        // Add extraction task to display
        [downloader.fileList addObject:@"Extracting modpack index"];
        
        // Create progress for extraction
        NSProgress *indexProgress = [NSProgress progressWithTotalUnitCount:1];
        indexProgress.kind = NSProgressKindFile;
        [downloader.progressList addObject:indexProgress];
        [downloader.progress addChild:indexProgress withPendingUnitCount:1];
    });
    
    // Open the archive on a background thread
    dispatch_async(extractionQueue, ^{
        NSError *error;
        UZKArchive *archive = [[UZKArchive alloc] initWithPath:packagePath error:&error];
        if (error) {
            NSLog(@"[ModrinthAPI] Failed to open modpack package: %@", error.localizedDescription);
            dispatch_async(dispatch_get_main_queue(), ^{
                [downloader finishDownloadWithErrorString:[NSString stringWithFormat:@"Failed to open modpack package: %@", error.localizedDescription]];
            });
            return;
        }

        // Extract and parse the index file
        NSData *indexData = [archive extractDataFromFile:@"modrinth.index.json" error:&error];
        if (!indexData) {
            NSLog(@"[ModrinthAPI] Failed to extract modrinth.index.json: %@", error.localizedDescription);
            dispatch_async(dispatch_get_main_queue(), ^{
                [downloader finishDownloadWithErrorString:@"Failed to extract modpack index"];
            });
            return;
        }
        
        NSDictionary *indexDict = [NSJSONSerialization JSONObjectWithData:indexData options:0 error:&error];
        if (error) {
            NSLog(@"[ModrinthAPI] Failed to parse modrinth.index.json: %@", error.localizedDescription);
            dispatch_async(dispatch_get_main_queue(), ^{
                [downloader finishDownloadWithErrorString:@"Failed to parse modpack index"];
            });
            return;
        }

        // Update index extraction progress
        dispatch_async(dispatch_get_main_queue(), ^{
            NSProgress *indexProgress = [downloader.progressList lastObject];
            indexProgress.completedUnitCount = 1;
        });
        
        // Prepare for overrides extraction
        dispatch_async(dispatch_get_main_queue(), ^{
            // Add extraction task to display
            [downloader.fileList addObject:@"Extracting modpack overrides"];
            
            // Create progress for extraction
            NSProgress *overridesProgress = [NSProgress progressWithTotalUnitCount:100]; // Use percentage
            overridesProgress.kind = NSProgressKindFile;
            [downloader.progressList addObject:overridesProgress];
            [downloader.progress addChild:overridesProgress withPendingUnitCount:100];
        });
        
        // Extract overrides on background thread
        dispatch_async(extractionQueue, ^{
            NSError *extractError = nil;
            
            // Create a custom extraction method that updates progress
            [self extractOverrides:archive toPath:destPath withProgress:^(double progress) {
                dispatch_async(dispatch_get_main_queue(), ^{
                    NSProgress *overridesProgress = downloader.progressList.count >= 2 ? downloader.progressList[downloader.progressList.count - 1] : nil;
                    if (overridesProgress) {
                        overridesProgress.completedUnitCount = (int64_t)(progress * 100);
                    }
                });
            } error:&extractError];
            
            if (extractError) {
                NSLog(@"[ModrinthAPI] Failed to extract overrides: %@", extractError.localizedDescription);
                dispatch_async(dispatch_get_main_queue(), ^{
                    [downloader finishDownloadWithErrorString:[NSString stringWithFormat:@"Failed to extract overrides: %@", extractError.localizedDescription]];
                });
                return;
            }
            
            // Finalize overrides extraction progress
            dispatch_async(dispatch_get_main_queue(), ^{
                NSProgress *overridesProgress = downloader.progressList.count >= 2 ? downloader.progressList[downloader.progressList.count - 1] : nil;
                if (overridesProgress) {
                    overridesProgress.completedUnitCount = 100;
                }
            });
            
            // Optional: Extract client-overrides if present
            NSError *clientExtractError = nil;
            [ModpackUtils archive:archive extractDirectory:@"client-overrides" toPath:destPath error:&clientExtractError];
            if (clientExtractError) {
                NSLog(@"[ModrinthAPI] Note: No client-overrides found or error extracting them: %@", clientExtractError);
                // Non-fatal error, continue
            }
            
            // Now prepare for mod downloads
            NSArray *files = indexDict[@"files"];
            if (!files || ![files isKindOfClass:[NSArray class]] || files.count == 0) {
                // No files to download, move to profile setup
                [self finalizeModpackInstallation:indexDict destPath:destPath downloader:downloader];
                return;
            }
            
            // Prepare mod download progress tracking
            dispatch_async(dispatch_get_main_queue(), ^{
                // Add downloads task to display
                [downloader.fileList addObject:@"Downloading mod files"];
                
                // Create progress for mod downloads
                NSProgress *modsProgress = [NSProgress progressWithTotalUnitCount:files.count];
                modsProgress.kind = NSProgressKindFile;
                [downloader.progressList addObject:modsProgress];
                [downloader.progress addChild:modsProgress withPendingUnitCount:files.count];
            });
            
            // Process files in manageable batches to avoid overwhelming the system
            [self downloadModFiles:files toDestPath:destPath withDownloader:downloader andCompletion:^{
                // Delete package cache after all downloads complete
                NSError *removeError = nil;
                [[NSFileManager defaultManager] removeItemAtPath:packagePath error:&removeError];
                if (removeError) {
                    NSLog(@"[ModrinthAPI] Warning: Failed to delete modpack package: %@", removeError);
                }
                
                // Proceed to finalization
                [self finalizeModpackInstallation:indexDict destPath:destPath downloader:downloader];
            }];
        });
    });
}

#pragma mark - Mod Installation

- (void)installModFromDetail:(NSDictionary *)modDetail atIndex:(NSUInteger)selectedVersion {
    if (!modDetail) {
        NSLog(@"[ModrinthAPI] Cannot install mod: nil modDetail");
        return;
    }
    
    NSDictionary *userInfo = @{
        @"detail": modDetail,
        @"index": @(selectedVersion)
    };
    
    dispatch_async(dispatch_get_main_queue(), ^{
        [[NSNotificationCenter defaultCenter] postNotificationName:@"InstallMod" 
                                                            object:self 
                                                          userInfo:userInfo];
    });
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
                if (![versionStr isKindOfClass:[NSString class]]) continue;
                
                NSString *trimmedGV = [[versionStr stringByTrimmingCharactersInSet:[NSCharacterSet whitespaceAndNewlineCharacterSet]] lowercaseString];
                NSString *trimmedFilter = [[gameVersion stringByTrimmingCharactersInSet:[NSCharacterSet whitespaceAndNewlineCharacterSet]] lowercaseString];
                
                // More relaxed version matching
                if ([trimmedGV isEqualToString:trimmedFilter] ||
                    [trimmedGV hasPrefix:[trimmedFilter stringByAppendingString:@"."]] ||
                    [trimmedFilter hasPrefix:[trimmedGV stringByAppendingString:@"."]]) {
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
                if (![loaderStr isKindOfClass:[NSString class]]) continue;
                
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

#pragma mark - Queue Management

- (void)queueOperation:(void (^)(void))block withPriority:(NSOperationQueuePriority)priority {
    NSBlockOperation *operation = [NSBlockOperation blockOperationWithBlock:block];
    operation.queuePriority = priority;
    [self.operationQueue addOperation:operation];
}

#pragma mark - Extraction and Download Methods

// Improved extract overrides method with better progress reporting
- (void)extractOverrides:(UZKArchive *)archive toPath:(NSString *)destPath withProgress:(void (^)(double progress))progressCallback error:(NSError * __strong *)error {
    // First count the number of files in the overrides directory
    __block NSUInteger totalFiles = 0;
    __block NSUInteger processedFiles = 0;
    
    // Count files first to enable accurate progress reporting
    NSError *countError = nil;
    [archive performOnFilesInArchive:^(UZKFileInfo *fileInfo, BOOL *stop) {
        if ([fileInfo.filename hasPrefix:@"overrides/"]) {
            totalFiles++;
        }
    } error:&countError];
    
    if (countError) {
        if (error) {
            *error = countError;
        }
        return;
    }
    
    if (totalFiles == 0) {
        // No overrides to extract - might not be a modpack or has a different structure
        NSLog(@"[ModrinthAPI] Warning: No override files found. This might not be a standard modpack.");
        if (progressCallback) {
            progressCallback(1.0); // Complete
        }
        return;
    }
    
    // Create a timer for smoother progress updates on the main thread
    dispatch_source_t progressTimer = dispatch_source_create(DISPATCH_SOURCE_TYPE_TIMER, 0, 0, dispatch_get_main_queue());
    dispatch_source_set_timer(progressTimer, DISPATCH_TIME_NOW, 0.5 * NSEC_PER_SEC, 0.1 * NSEC_PER_SEC);
    
    __block double lastReportedProgress = 0;
    __block NSString *currentFile = @"";
    
    dispatch_source_set_event_handler(progressTimer, ^{
        double currentProgress = (double)processedFiles / totalFiles;
        
        // Only update if progress has changed significantly
        if (currentProgress - lastReportedProgress >= 0.01 || currentProgress == 1.0) {
            lastReportedProgress = currentProgress;
            if (progressCallback) {
                progressCallback(currentProgress);
            }
        }
        
        // If extraction is complete, stop the timer
        if (processedFiles >= totalFiles) {
            dispatch_source_cancel(progressTimer);
        }
    });
    
    // Start the timer
    dispatch_resume(progressTimer);
    
    // Now extract the files with progress updates
    NSError *archiveError = nil;
    [archive performOnFilesInArchive:^(UZKFileInfo *fileInfo, BOOL *stop) {
        // Skip files that are not in the overrides directory
        if (![fileInfo.filename hasPrefix:@"overrides/"]) {
            return;
        }
        
        // Track current file for progress reporting
        currentFile = fileInfo.filename;
        
        // Get relative path (remove "overrides/" prefix)
        NSString *relativePath = [fileInfo.filename substringFromIndex:10]; // "overrides/".length == 10
        if (relativePath.length == 0) {
            // Skip the root overrides directory itself
            processedFiles++;
            return;
        }
        
        NSString *destItemPath = [destPath stringByAppendingPathComponent:relativePath];
        NSString *destDirPath = fileInfo.isDirectory ? destItemPath : [destItemPath stringByDeletingLastPathComponent];
        
        // Create destination directory if needed
        NSError *dirError = nil;
        if (![NSFileManager.defaultManager fileExistsAtPath:destDirPath]) {
            BOOL created = [NSFileManager.defaultManager createDirectoryAtPath:destDirPath 
                                                  withIntermediateDirectories:YES 
                                                                   attributes:nil 
                                                                        error:&dirError];
            if (!created) {
                *stop = YES;
                if (error) {
                    *error = dirError;
                }
                return;
            }
        }
        
        // Skip directories (we've already created them)
        if (fileInfo.isDirectory) {
            processedFiles++;
            return;
        }
        
        // Extract file data
        NSError *extractError = nil;
        NSData *fileData = [archive extractData:fileInfo error:&extractError];
        if (extractError) {
            *stop = YES;
            if (error) {
                *error = extractError;
            }
            return;
        }
        
        // Write data to destination
        NSError *writeError = nil;
        BOOL written = [fileData writeToFile:destItemPath options:NSDataWritingAtomic error:&writeError];
        if (!written) {
            *stop = YES;
            if (error) {
                *error = writeError;
            }
            return;
        }
        
        // Update progress
        processedFiles++;
    } error:&archiveError];
    
    // Handle archive error
    if (archiveError && error) {
        *error = archiveError;
    }
    
    // Cancel timer if there was an error
    if (error && *error) {
        dispatch_source_cancel(progressTimer);
    }
    
    // Ensure final progress update
    if ((!error || !*error) && progressCallback) {
        progressCallback(1.0);
    }
}

// Improved version of downloadModFiles method for better reporting
- (void)downloadModFiles:(NSArray *)files toDestPath:(NSString *)destPath withDownloader:(MinecraftResourceDownloadTask *)downloader andCompletion:(void (^)(void))completion {
    // Get reference to the mods progress object
    __block NSProgress *modsProgress = downloader.progressList.lastObject;
    
    // Create mods directory if it doesn't exist
    NSString *modsDir = [destPath stringByAppendingPathComponent:@"mods"];
    if (![NSFileManager.defaultManager fileExistsAtPath:modsDir]) {
        NSError *dirError = nil;
        [[NSFileManager defaultManager] createDirectoryAtPath:modsDir 
                               withIntermediateDirectories:YES 
                                                attributes:nil 
                                                     error:&dirError];
        if (dirError) {
            NSLog(@"[ModrinthAPI] Failed to create mods directory: %@", dirError);
        }
    }
    
    // Track download stats
    __block NSUInteger completedFiles = 0;
    __block NSUInteger failedFiles = 0;
    __block NSUInteger totalFiles = files.count;
    
    // Ensure modsProgress has the right unit count
    dispatch_async(dispatch_get_main_queue(), ^{
        modsProgress.totalUnitCount = totalFiles;
        modsProgress.completedUnitCount = 0;
    });
    
    // If no files to download, call completion immediately
    if (totalFiles == 0) {
        dispatch_async(dispatch_get_main_queue(), ^{
            // Make sure progress is fully completed
            modsProgress.completedUnitCount = modsProgress.totalUnitCount;
            
            NSLog(@"[ModrinthAPI] No files to download, completing immediately");
            
            if (completion) {
                completion();
            }
        });
        return;
    }
    
    // Use a dispatch group to track completion
    dispatch_group_t downloadGroup = dispatch_group_create();
    
    // Use a semaphore to limit concurrent downloads
    dispatch_semaphore_t downloadSemaphore = dispatch_semaphore_create(4); // Limit to 4 concurrent downloads
    
    // Keep track of download tasks
    __block NSMutableArray *activeTasks = [NSMutableArray array];
    
    // Start a counter to track file index for better display
    __block int fileIndex = 0;
    
    // Process each file
    for (NSDictionary *indexFile in files) {
        fileIndex++;
        if (![indexFile isKindOfClass:[NSDictionary class]]) {
            dispatch_async(dispatch_get_main_queue(), ^{
                failedFiles++;
                modsProgress.completedUnitCount++;
                
                // Check if we're done with all files
                if ((completedFiles + failedFiles) >= totalFiles) {
                    // Ensure progress is fully completed
                    modsProgress.completedUnitCount = modsProgress.totalUnitCount;
                    
                    if (completion) {
                        completion();
                    }
                }
            });
            continue;
        }
        
        NSArray *downloads = indexFile[@"downloads"];
        if (![downloads isKindOfClass:[NSArray class]] || downloads.count == 0) {
            NSLog(@"[ModrinthAPI] Missing download URLs for file, skipping");
            dispatch_async(dispatch_get_main_queue(), ^{
                failedFiles++;
                modsProgress.completedUnitCount++;
                
                // Check if we're done with all files
                if ((completedFiles + failedFiles) >= totalFiles) {
                    // Ensure progress is fully completed
                    modsProgress.completedUnitCount = modsProgress.totalUnitCount;
                    
                    if (completion) {
                        completion();
                    }
                }
            });
            continue;
        }
        
        NSString *url = [downloads firstObject];
        if (![url isKindOfClass:[NSString class]] || url.length == 0) {
            NSLog(@"[ModrinthAPI] Invalid download URL for file, skipping");
            dispatch_async(dispatch_get_main_queue(), ^{
                failedFiles++;
                modsProgress.completedUnitCount++;
                
                // Check if we're done with all files
                if ((completedFiles + failedFiles) >= totalFiles) {
                    // Ensure progress is fully completed
                    modsProgress.completedUnitCount = modsProgress.totalUnitCount;
                    
                    if (completion) {
                        completion();
                    }
                }
            });
            continue;
        }
        
        // Get mod name for better display
        NSString *modName = indexFile[@"name"];
        if (!modName || ![modName isKindOfClass:[NSString class]] || modName.length == 0) {
            // Try to extract a name from path or URL
            NSString *path = indexFile[@"path"];
            if ([path isKindOfClass:[NSString class]] && path.length > 0) {
                modName = [path lastPathComponent];
            } else {
                modName = [[NSURL URLWithString:url] lastPathComponent] ?: @"Unknown mod";
            }
        }
        
        // Create a better display name with index for progress tracking
        NSString *displayName = [NSString stringWithFormat:@"Mod %d/%lu: %@", 
                                fileIndex, (unsigned long)files.count, modName];
        
        // Determine file path based on metadata
        NSString *path;
        if ([indexFile[@"path"] isKindOfClass:[NSString class]] && [indexFile[@"path"] length] > 0) {
            path = [destPath stringByAppendingPathComponent:indexFile[@"path"]];
        } else {
            // Default to mods directory with filename from URL
            NSString *fileName = [[NSURL URLWithString:url] lastPathComponent];
            if (!fileName || fileName.length == 0) {
                fileName = [NSString stringWithFormat:@"mod_%@.jar", modName ?: [[NSUUID UUID] UUIDString]];
            }
            path = [modsDir stringByAppendingPathComponent:fileName];
        }
        
        // Create directory structure
        NSString *dirPath = [path stringByDeletingLastPathComponent];
        if (![NSFileManager.defaultManager fileExistsAtPath:dirPath]) {
            NSError *dirError = nil;
            BOOL created = [NSFileManager.defaultManager createDirectoryAtPath:dirPath 
                                              withIntermediateDirectories:YES 
                                                               attributes:nil 
                                                                    error:&dirError];
            if (!created) {
                NSLog(@"[ModrinthAPI] Failed to create directory %@: %@", dirPath, dirError);
                dispatch_async(dispatch_get_main_queue(), ^{
                    failedFiles++;
                    modsProgress.completedUnitCount++;
                    
                    // Check if we're done with all files
                    if ((completedFiles + failedFiles) >= totalFiles) {
                        // Ensure progress is fully completed
                        modsProgress.completedUnitCount = modsProgress.totalUnitCount;
                        
                        if (completion) {
                            completion();
                        }
                    }
                });
                continue;
            }
        }
        
        NSDictionary *hashes = indexFile[@"hashes"];
        NSString *sha = [hashes isKindOfClass:[NSDictionary class]] ? hashes[@"sha1"] : nil;
        
        NSNumber *fileSizeNumber = indexFile[@"fileSize"];
        NSUInteger size = [fileSizeNumber isKindOfClass:[NSNumber class]] ? [fileSizeNumber unsignedLongLongValue] : 0;
        
        // Enter download group and wait for semaphore slot
        dispatch_group_enter(downloadGroup);
        
        // Wait for semaphore slot in the background
        dispatch_async(dispatch_get_global_queue(DISPATCH_QUEUE_PRIORITY_DEFAULT, 0), ^{
            dispatch_semaphore_wait(downloadSemaphore, DISPATCH_TIME_FOREVER);
            
            // Create download task with improved display name
            NSURLSessionDownloadTask *task = [downloader createDownloadTask:url 
                                                                       size:size 
                                                                        sha:sha 
                                                                    altName:displayName
                                                                     toPath:path 
                                                                    success:^{
                // Update progress
                dispatch_async(dispatch_get_main_queue(), ^{
                    completedFiles++;
                    // This is the key line - ensure we increment the mods progress counter
                    modsProgress.completedUnitCount++;
                    NSLog(@"[ModrinthAPI] Download completed (%lu/%lu): %@", 
                          (unsigned long)completedFiles, 
                          (unsigned long)totalFiles, 
                          modName);
                    
                    // Check if we're done with all files
                    if ((completedFiles + failedFiles) >= totalFiles) {
                        // Ensure progress is fully completed
                        modsProgress.completedUnitCount = modsProgress.totalUnitCount;
                        
                        if (completion) {
                            completion();
                        }
                    }
                });
                
                // Track task completion
                @synchronized(activeTasks) {
                    [activeTasks removeObject:task];
                }
                
                // Release semaphore slot
                dispatch_semaphore_signal(downloadSemaphore);
                
                // Mark this download as complete
                dispatch_group_leave(downloadGroup);
            }];
            
            if (task) {
                @synchronized(activeTasks) {
                    [activeTasks addObject:task];
                }
                [task resume];
                
                // Add a fail-safe timeout
                dispatch_after(dispatch_time(DISPATCH_TIME_NOW, (int64_t)(300 * NSEC_PER_SEC)), dispatch_get_global_queue(DISPATCH_QUEUE_PRIORITY_DEFAULT, 0), ^{
                    if (task.state != NSURLSessionTaskStateCompleted) {
                        NSLog(@"[ModrinthAPI] Download timed out after 5 minutes: %@", displayName);
                        
                        // Cancel the task
                        [task cancel];
                        
                        // Update progress
                        dispatch_async(dispatch_get_main_queue(), ^{
                            failedFiles++;
                            modsProgress.completedUnitCount++;
                            
                            // Check if we're done with all files
                            if ((completedFiles + failedFiles) >= totalFiles) {
                                // Ensure progress is fully completed
                                modsProgress.completedUnitCount = modsProgress.totalUnitCount;
                                
                                if (completion) {
                                    completion();
                                }
                            }
                        });
                        
                        // Track task completion
                        @synchronized(activeTasks) {
                            [activeTasks removeObject:task];
                        }
                        
                        // Release semaphore slot
                        dispatch_semaphore_signal(downloadSemaphore);
                        
                        // Mark this download as complete
                        dispatch_group_leave(downloadGroup);
                    }
                });
            } else {
                // Task creation failed, update counters and continue
                dispatch_async(dispatch_get_main_queue(), ^{
                    failedFiles++;
                    // Make sure to increment progress even on failure
                    modsProgress.completedUnitCount++;
                    
                    // Check if we're done with all files
                    if ((completedFiles + failedFiles) >= totalFiles) {
                        // Ensure progress is fully completed
                        modsProgress.completedUnitCount = modsProgress.totalUnitCount;
                        
                        if (completion) {
                            completion();
                        }
                    }
                });
                
                // Release semaphore slot
                dispatch_semaphore_signal(downloadSemaphore);
                
                // Mark this download as complete
                dispatch_group_leave(downloadGroup);
            }
        });
    }
    
    // Set up a timeout for the entire download process
    dispatch_after(dispatch_time(DISPATCH_TIME_NOW, (int64_t)(900 * NSEC_PER_SEC)), dispatch_get_global_queue(DISPATCH_QUEUE_PRIORITY_DEFAULT, 0), ^{
        // Check if we're still waiting for downloads after 15 minutes
        if ((completedFiles + failedFiles) < totalFiles) {
            NSLog(@"[ModrinthAPI] Overall download process timed out after 15 minutes");
            
            // Cancel any remaining tasks
            @synchronized(activeTasks) {
                for (NSURLSessionDownloadTask *task in activeTasks) {
                    [task cancel];
                }
                [activeTasks removeAllObjects];
            }
            
            // Update progress for any remaining files
            dispatch_async(dispatch_get_main_queue(), ^{
                NSUInteger remainingFiles = totalFiles - (completedFiles + failedFiles);
                failedFiles += remainingFiles;
                
                // Force progress to complete
                modsProgress.completedUnitCount = modsProgress.totalUnitCount;
                
                NSLog(@"[ModrinthAPI] Forced completion after timeout: %lu completed, %lu failed", 
                      (unsigned long)completedFiles, 
                      (unsigned long)failedFiles);
                
                if (completion) {
                    completion();
                }
            });
        }
    });
    
    // Set up a background task to monitor progress and ensure completion
    dispatch_async(dispatch_get_global_queue(DISPATCH_QUEUE_PRIORITY_DEFAULT, 0), ^{
        // Wait for the group with a reasonable timeout
        dispatch_time_t timeout = dispatch_time(DISPATCH_TIME_NOW, (int64_t)(600 * NSEC_PER_SEC)); // 10 minute timeout
        long result = dispatch_group_wait(downloadGroup, timeout);
        
        if (result != 0) {
            // Timeout occurred
            NSLog(@"[ModrinthAPI] Warning: Not all downloads completed within timeout period");
        }
        
        // Ensure completion is called regardless of timeout
        dispatch_async(dispatch_get_main_queue(), ^{
            // Force progress to complete
            modsProgress.completedUnitCount = modsProgress.totalUnitCount;
            
            NSLog(@"[ModrinthAPI] All downloads completed or timed out: %lu successful, %lu failed", 
                  (unsigned long)completedFiles, 
                  (unsigned long)failedFiles);
            
            // Create a log entry of the installation
            NSString *logPath = [destPath stringByAppendingPathComponent:@"modrinth_download.log"];
            NSString *logContent = [NSString stringWithFormat:@"Modrinth mod download completed\n"
                                  "Total files: %lu\n"
                                  "Successful: %lu\n"
                                  "Failed: %lu\n"
                                  "Date: %@",
                                  (unsigned long)totalFiles,
                                  (unsigned long)completedFiles,
                                  (unsigned long)failedFiles,
                                  [NSDate date]];
            
            [logContent writeToFile:logPath atomically:YES encoding:NSUTF8StringEncoding error:nil];
            
            if (completion) {
                completion();
            }
            
            // Mark the task as fully completed
            [downloader markAsCompleted];
        });
    });
}

- (void)finalizeModpackInstallation:(NSDictionary *)indexDict destPath:(NSString *)destPath downloader:(MinecraftResourceDownloadTask *)downloader {
    // Log information about the modpack
    NSLog(@"[ModrinthAPI] Finalizing modpack installation: %@", indexDict[@"name"]);
    
    // Prepare profile setup UI
    dispatch_async(dispatch_get_main_queue(), ^{
        // Add profile setup task to display
        [downloader.fileList addObject:@"Setting up profile"];
        
        // Create progress for profile setup
        NSProgress *setupProgress = [NSProgress progressWithTotalUnitCount:2]; // Two steps: JSON download and profile creation
        setupProgress.kind = NSProgressKindFile;
        [downloader.progressList addObject:setupProgress];
        [downloader.progress addChild:setupProgress withPendingUnitCount:2];
    });
    
    // Process on background thread
    dispatch_async(dispatch_get_global_queue(DISPATCH_QUEUE_PRIORITY_DEFAULT, 0), ^{
        // First step: Download dependency client json (if available)
        NSDictionary<NSString *, NSString *> *depInfo = [ModpackUtils infoForDependencies:indexDict[@"dependencies"]];
        
        if (depInfo[@"json"]) {
            NSString *jsonPath = [NSString stringWithFormat:@"%1$s/versions/%2$@/%2$@.json", 
                                 getenv("POJAV_GAME_DIR"), 
                                 depInfo[@"id"]];
            
            // Create directory structure for the JSON file
            [NSFileManager.defaultManager createDirectoryAtPath:[jsonPath stringByDeletingLastPathComponent] 
                                    withIntermediateDirectories:YES attributes:nil error:nil];
                              
            // Download JSON file
            dispatch_semaphore_t jsonSemaphore = dispatch_semaphore_create(0);
            
            NSURLSessionDownloadTask *jsonTask = [downloader createDownloadTask:depInfo[@"json"] 
                                                                         size:0 
                                                                          sha:nil 
                                                                      altName:nil 
                                                                       toPath:jsonPath 
                                                                      success:^{
                dispatch_async(dispatch_get_main_queue(), ^{
                    NSProgress *setupProgress = downloader.progressList.lastObject;
                    setupProgress.completedUnitCount = 1; // First step complete
                });
                
                dispatch_semaphore_signal(jsonSemaphore);
            }];
            
            if (jsonTask) {
                [jsonTask resume];
                
                // Wait for JSON download with timeout
                dispatch_time_t timeout = dispatch_time(DISPATCH_TIME_NOW, 60 * NSEC_PER_SEC);
                if (dispatch_semaphore_wait(jsonSemaphore, timeout) != 0) {
                    NSLog(@"[ModrinthAPI] Warning: Timed out waiting for JSON download");
                }
            } else {
                // JSON task couldn't be created - update progress anyway
                dispatch_async(dispatch_get_main_queue(), ^{
                    NSProgress *setupProgress = downloader.progressList.lastObject;
                    setupProgress.completedUnitCount = 1;
                });
            }
        } else {
            // No JSON to download - update progress
            dispatch_async(dispatch_get_main_queue(), ^{
                NSProgress *setupProgress = downloader.progressList.lastObject;
                setupProgress.completedUnitCount = 1;
            });
        }
        
        // Second step: Create profile
        dispatch_async(dispatch_get_main_queue(), ^{
            // Create the profile with the modpack info
            NSString *profileName = indexDict[@"name"] ?: @"Modrinth Modpack";
            NSString *safeProfileName = [profileName stringByReplacingOccurrencesOfString:@"/" withString:@"_"];
            safeProfileName = [safeProfileName stringByReplacingOccurrencesOfString:@"\\" withString:@"_"];
            safeProfileName = [safeProfileName stringByReplacingOccurrencesOfString:@":" withString:@"_"];
            
            // Get modified version string
            NSDictionary<NSString *, NSString *> *depInfo = [ModpackUtils infoForDependencies:indexDict[@"dependencies"]];
            
            // Create a unique game directory path
            NSString *gameDir = [NSString stringWithFormat:@"./profiles/%@", destPath.lastPathComponent];
            
            // Get the icon URL from the modpack data
            NSString *iconUrl = indexDict[@"icon"];
            
            // Update or create the profile in the launcher's profiles.json
            PLProfiles.current.profiles[safeProfileName] = @{
                @"gameDir": gameDir,
                @"name": profileName,
                @"lastVersionId": depInfo[@"id"] ?: @"latest-release",
                @"icon": iconUrl ?: @""
            }.mutableCopy;
            
            PLProfiles.current.selectedProfileName = safeProfileName;
            [PLProfiles.current save];
            
            // Create a log file
            NSString *logContent = [NSString stringWithFormat:@"Modrinth modpack installation completed\n"
                                  "Profile: %@\n"
                                  "Directory: %@\n"
                                  "Game Version: %@\n"
                                  "Mod Loader: %@\n"
                                  "Date: %@",
                                  profileName, 
                                  destPath, 
                                  depInfo[@"mcVersion"] ?: @"unknown",
                                  depInfo[@"loader"] ?: @"unknown",
                                  [NSDate date]];
            
            [logContent writeToFile:[destPath stringByAppendingPathComponent:@"modrinth_install.log"]
                         atomically:YES
                           encoding:NSUTF8StringEncoding
                              error:nil];

            // Mark setup as complete
            NSProgress *setupProgress = downloader.progressList.lastObject;
            setupProgress.completedUnitCount = 2; // Both steps complete
            
            // Explicitly mark the task as fully completed
            [downloader markAsCompleted];
            
            // Make sure metadata is properly set for launch
            downloader.metadata[@"allTasksComplete"] = @YES;
        });
    });
}

@end

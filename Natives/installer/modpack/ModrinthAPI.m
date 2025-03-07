#import "ModrinthAPI.h"
#import "MinecraftResourceDownloadTask.h"
#import "PLProfiles.h"
#import "AFNetworking.h"
#import "UIAlertUtilities.h"

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
        NSMutableDictionary *entry = [@{
            @"apiSource": @(0), // 0 = Modrinth
            @"isModpack": @(isModpack),
            @"id": hit[@"project_id"] ?: @"",
            @"title": hit[@"title"] ?: @"",
            @"description": hit[@"description"] ?: @"",
            @"imageUrl": hit[@"icon_url"] ?: @""
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
    
    NSDictionary *indexDict = [NSJSONSerialization JSONObjectWithData:indexData options:0 error:&error];
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
        downloader.progress.totalUnitCount = files.count + 2; // Files + extraction + setup
        downloader.textProgress.localizedDescription = [NSString stringWithFormat:@"Installing %@ (%lu files)", 
                                                        indexDict[@"name"] ?: @"Modpack", 
                                                        (unsigned long)files.count];
    });
    
    // Create a task tracker dictionary to map tasks to their progress objects
    NSMutableDictionary *taskProgressMap = [NSMutableDictionary dictionary];
    
    // Create download queue and tracker
    dispatch_group_t downloadGroup = dispatch_group_create();
    __block NSUInteger completedDownloads = 0;
    __block NSUInteger failedDownloads = 0;
    
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
            [NSFileManager.defaultManager createDirectoryAtPath:dirPath 
                                   withIntermediateDirectories:YES 
                                                    attributes:nil 
                                                         error:nil];
        }
        
        // Get a file name for display (just the last component)
        NSString *fileName = [path lastPathComponent];
        
        // Enter the download group
        dispatch_group_enter(downloadGroup);
        
        // Create progress object for this file
        NSProgress *fileProgress = [NSProgress progressWithTotalUnitCount:size > 0 ? size : 1000000]; // Use actual size or estimate
        fileProgress.kind = NSProgressKindFile;
        fileProgress.fileOperationKind = NSProgressFileOperationKindDownloading;
        
        // Add to file list and progress tracking on main thread
        dispatch_async(dispatch_get_main_queue(), ^{
            [downloader.fileList addObject:fileName];
            [downloader.progressList addObject:fileProgress];
            [downloader.progress addChild:fileProgress withPendingUnitCount:fileProgress.totalUnitCount];
        });
        
        // Limit concurrent downloads
        dispatch_semaphore_wait(self.downloadSemaphore, DISPATCH_TIME_FOREVER);
        
        // Create and start download task with progress tracking
        NSURLSessionConfiguration *config = [NSURLSessionConfiguration defaultSessionConfiguration];
        NSURLSession *session = [NSURLSession sessionWithConfiguration:config
                                                              delegate:nil
                                                         delegateQueue:[NSOperationQueue mainQueue]];
        
        NSURLSessionDownloadTask *task = [session downloadTaskWithURL:[NSURL URLWithString:url]
                                                 completionHandler:^(NSURL *location, NSURLResponse *response, NSError *downloadError) {
            // Signal semaphore to allow another download
            dispatch_semaphore_signal(self.downloadSemaphore);
            
            if (downloadError) {
                failedDownloads++;
                NSLog(@"[ModrinthAPI] Failed to download %@: %@", fileName, downloadError);
                
                // Mark progress as failed but "complete" for tracking purposes
                dispatch_async(dispatch_get_main_queue(), ^{
                    fileProgress.completedUnitCount = 0;
                    fileProgress.totalUnitCount = 1; // Zero out the contribution to parent
                });
            } else {
                // Move file to destination
                NSError *moveError = nil;
                if ([[NSFileManager defaultManager] fileExistsAtPath:path]) {
                    [[NSFileManager defaultManager] removeItemAtPath:path error:nil];
                }
                
                [[NSFileManager defaultManager] moveItemAtURL:location toURL:[NSURL fileURLWithPath:path] error:&moveError];
                
                if (moveError) {
                    failedDownloads++;
                    NSLog(@"[ModrinthAPI] Failed to save %@: %@", fileName, moveError);
                    
                    // Mark progress as failed
                    dispatch_async(dispatch_get_main_queue(), ^{
                        fileProgress.completedUnitCount = 0;
                    });
                } else {
                    completedDownloads++;
                    
                    // Mark progress as complete with proper size
                    dispatch_async(dispatch_get_main_queue(), ^{
                        // Get actual file size
                        NSError *attributesError = nil;
                        NSDictionary *attributes = [[NSFileManager defaultManager] attributesOfItemAtPath:path 
                                                                                                   error:&attributesError];
                        if (!attributesError) {
                            NSUInteger actualSize = [attributes fileSize];
                            fileProgress.totalUnitCount = actualSize;
                            fileProgress.completedUnitCount = actualSize;
                        } else {
                            // Use response size or fall back to 1
                            fileProgress.totalUnitCount = response.expectedContentLength > 0 ? response.expectedContentLength : 1;
                            fileProgress.completedUnitCount = fileProgress.totalUnitCount;
                        }
                    });
                }
            }
            
            // Leave the download group
            dispatch_group_leave(downloadGroup);
        }];
        
        // Start the download
        [task resume];
    }
    
    // Wait for all downloads to complete
    dispatch_async(dispatch_get_global_queue(DISPATCH_QUEUE_PRIORITY_DEFAULT, 0), ^{
        dispatch_group_wait(downloadGroup, DISPATCH_TIME_FOREVER);
        
        // Update stats
        NSLog(@"[ModrinthAPI] Downloads complete: %lu successful, %lu failed",
              (unsigned long)completedDownloads, (unsigned long)failedDownloads);
        
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
        NSError *extractError = nil;
        [ModpackUtils archive:archive extractDirectory:@"overrides" toPath:destPath error:&extractError];
        if (extractError) {
            NSLog(@"[ModrinthAPI] Failed to extract overrides: %@", extractError.localizedDescription);
            dispatch_async(dispatch_get_main_queue(), ^{
                downloader.textProgress.localizedDescription = [NSString stringWithFormat:@"Warning: %@", extractError.localizedDescription];
            });
        }
        
        // Mark extraction as complete
        dispatch_async(dispatch_get_main_queue(), ^{
            NSProgress *extractProgress = [downloader.progressList lastObject];
            extractProgress.completedUnitCount = 1;
        });
        
        // Extract client-overrides if present
        NSError *clientExtractError = nil;
        [ModpackUtils archive:archive extractDirectory:@"client-overrides" toPath:destPath error:&clientExtractError];
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
            NSString *safeProfileName = indexDict[@"name"];
            PLProfiles.current.profiles[safeProfileName] = @{
                @"gameDir": [NSString stringWithFormat:@"./profiles/%@", destPath.lastPathComponent],
                @"name": safeProfileName,
                @"lastVersionId": depInfo[@"id"] ?: @"latest-release",
                @"icon": iconBase64.length > 0 ? [NSString stringWithFormat:@"data:image/png;base64,%@", iconBase64] : @""
            }.mutableCopy;
            
            PLProfiles.current.selectedProfileName = safeProfileName;
            [PLProfiles.current save];
            
            // Mark profile setup as complete
            NSProgress *setupProgress = [downloader.progressList lastObject];
            setupProgress.completedUnitCount = 1;
            
            // Update progress to show completion
            downloader.textProgress.localizedDescription = @"Modpack installation complete";
            
            // Add completion message to progress
            [downloader.fileList addObject:@"Complete"];
        });
        
        // Create installation log
        NSString *logContent = [NSString stringWithFormat:@"Modrinth modpack installation completed\n"
                              "Name: %@\n"
                              "Version: %@\n"
                              "Directory: %@\n"
                              "Files: %lu downloaded (%lu failed)\n"
                              "Date: %@",
                              indexDict[@"name"],
                              indexDict[@"versionId"],
                              destPath,
                              (unsigned long)completedDownloads,
                              (unsigned long)failedDownloads,
                              [NSDate date]];
        
        [logContent writeToFile:[destPath stringByAppendingPathComponent:@"modrinth_install.log"]
                     atomically:YES
                       encoding:NSUTF8StringEncoding
                          error:nil];
    });
}

#pragma mark - Mod Installation

- (void)installModFromDetail:(NSDictionary *)modDetail atIndex:(NSUInteger)selectedVersion {
    if (!modDetail) {
        NSLog(@"[ModrinthAPI] Cannot install mod: nil modDetail");
        return;
    }
    
    NSArray *urls = modDetail[@"versionUrls"];
    if (!urls || selectedVersion >= urls.count) {
        NSLog(@"[ModrinthAPI] Invalid version index for mod installation");
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
                
                // More relaxed version matching
                if ([trimmedGV isEqualToString:gameVersion] ||
                    [trimmedGV hasPrefix:[gameVersion stringByAppendingString:@"."]] ||
                    [gameVersion hasPrefix:[trimmedGV stringByAppendingString:@"."]]) {
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

#pragma mark - Queue Management

- (void)queueOperation:(void (^)(void))block withPriority:(NSOperationQueuePriority)priority {
    NSBlockOperation *operation = [NSBlockOperation blockOperationWithBlock:block];
    operation.queuePriority = priority;
    [self.operationQueue addOperation:operation];
}

@end

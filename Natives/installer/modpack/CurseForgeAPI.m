#import "CurseForgeAPI.h"
#import "MinecraftResourceDownloadTask.h"
#import "PLProfiles.h"
#import "ModpackUtils.h"
#import "UnzipKit.h"
#import "AFNetworking.h"
#import "UIAlertUtilities.h"
#import "config.h"
#import "utils.h"

// Constants
#define kCurseForgeGameIDMinecraft 432
#define kCurseForgeClassIDModpack 4471
#define kCurseForgeClassIDMod 6
#define CURSEFORGE_PAGINATION_SIZE 50
#define CURSEFORGE_MAX_RETRY_ATTEMPTS 3
#define CURSEFORGE_MAX_CONCURRENT_DOWNLOADS 5

// Error domain and codes
NSString * const CurseForgeAPIErrorDomain = @"CurseForgeAPIErrorDomain";
typedef NS_ENUM(NSInteger, CurseForgeErrorCode) {
    CurseForgeErrorCodeNetwork = 1000,
    CurseForgeErrorCodeAuthentication = 1001,
    CurseForgeErrorCodeResourceNotFound = 1002,
    CurseForgeErrorCodeServerError = 1003,
    CurseForgeErrorCodeParsingError = 1004,
    CurseForgeErrorCodeExtraction = 1005,
    CurseForgeErrorCodeInvalidManifest = 1006,
    CurseForgeErrorCodeFileOperation = 1007
};

@interface CurseForgeAPI ()
@property (nonatomic, copy) NSString *apiKey;
@property (nonatomic, strong) AFHTTPSessionManager *sessionManager;
@property (nonatomic, strong) NSCache *responseCache;
@property (nonatomic, strong) NSOperationQueue *operationQueue;
@property (nonatomic, strong) NSMutableDictionary *taskPathMap;
@property (nonatomic, strong) NSError *lastFetchError;
@property (nonatomic, strong) dispatch_queue_t downloadQueue;
@property (nonatomic, strong) dispatch_semaphore_t downloadSemaphore;
@end

@implementation CurseForgeAPI

#pragma mark - Initialization

- (instancetype)initWithAPIKey:(NSString *)apiKey {
    self = [super initWithURL:@"https://api.curseforge.com/v1"];
    if (self) {
        _apiKey = apiKey ?: @"";
        
        // Initialize session manager with appropriate configuration
        NSURLSessionConfiguration *config = [NSURLSessionConfiguration defaultSessionConfiguration];
        config.timeoutIntervalForRequest = 30.0;
        config.HTTPMaximumConnectionsPerHost = 10;
        _sessionManager = [[AFHTTPSessionManager alloc] initWithSessionConfiguration:config];
        _sessionManager.requestSerializer = [AFJSONRequestSerializer serializer];
        _sessionManager.responseSerializer = [AFJSONResponseSerializer serializer];
        
        // Initialize response cache
        _responseCache = [[NSCache alloc] init];
        _responseCache.countLimit = 50; // Limit cache size
        
        // Initialize operation queue with limited concurrency
        _operationQueue = [[NSOperationQueue alloc] init];
        _operationQueue.maxConcurrentOperationCount = 4;
        
        // Initialize task path map for resumable downloads
        _taskPathMap = [NSMutableDictionary dictionary];
        
        // Set up download queue and semaphore for concurrent download limiting
        _downloadQueue = dispatch_queue_create("com.curseforge.download", DISPATCH_QUEUE_CONCURRENT);
        _downloadSemaphore = dispatch_semaphore_create(CURSEFORGE_MAX_CONCURRENT_DOWNLOADS);
        
        NSLog(@"CurseForgeAPI: Initialized with API key: %@", _apiKey.length > 0 ? @"[REDACTED]" : @"(none)");
    }
    return self;
}

#pragma mark - Error Handling

- (NSError *)errorWithCode:(CurseForgeErrorCode)code message:(NSString *)message underlyingError:(NSError *)underlyingError {
    NSMutableDictionary *userInfo = [NSMutableDictionary dictionary];
    userInfo[NSLocalizedDescriptionKey] = message;
    if (underlyingError) {
        userInfo[NSUnderlyingErrorKey] = underlyingError;
    }
    return [NSError errorWithDomain:CurseForgeAPIErrorDomain code:code userInfo:userInfo];
}

#pragma mark - Network Requests

- (void)getEndpoint:(NSString *)endpoint params:(NSDictionary *)params completion:(void (^)(id, NSError *))completion {
    if (!endpoint) {
        if (completion) {
            NSError *error = [self errorWithCode:CurseForgeErrorCodeParsingError 
                                         message:@"Invalid endpoint" 
                                 underlyingError:nil];
            dispatch_async(dispatch_get_main_queue(), ^{
                completion(nil, error);
            });
        }
        return;
    }
    
    // Check API key
    if (self.apiKey.length == 0) {
        NSLog(@"getEndpoint: No API key provided");
        if (completion) {
            NSError *error = [self errorWithCode:CurseForgeErrorCodeAuthentication 
                                         message:@"No API key provided" 
                                 underlyingError:nil];
            dispatch_async(dispatch_get_main_queue(), ^{
                completion(nil, error);
            });
        }
        return;
    }
    
    // Set up the request with API key
    NSString *url = [self.baseURL stringByAppendingPathComponent:endpoint];
    [self.sessionManager.requestSerializer setValue:self.apiKey forHTTPHeaderField:@"x-api-key"];
    
    // Check cache first (for non-critical requests)
    NSString *cacheKey = [self cacheKeyForEndpoint:endpoint params:params];
    id cachedResponse = params[@"skipCache"] ? nil : [self.responseCache objectForKey:cacheKey];
    if (cachedResponse) {
        NSLog(@"getEndpoint: Cache hit for %@", endpoint);
        if (completion) {
            dispatch_async(dispatch_get_main_queue(), ^{
                completion(cachedResponse, nil);
            });
        }
        return;
    }
    
    NSLog(@"getEndpoint: Requesting %@ with params: %@", url, params);
    
    // Execute request
    [self.sessionManager GET:url parameters:params headers:nil progress:nil success:^(NSURLSessionTask *task, id responseObject) {
        NSLog(@"getEndpoint: Success for %@", endpoint);
        
        // Cache the response (unless specified not to)
        if (!params[@"skipCache"]) {
            [self.responseCache setObject:responseObject forKey:cacheKey];
        }
        
        if (completion) {
            dispatch_async(dispatch_get_main_queue(), ^{
                completion(responseObject, nil);
            });
        }
    } failure:^(NSURLSessionTask *operation, NSError *error) {
        self.lastError = error;
        self.lastFetchError = error;
        NSLog(@"getEndpoint: Failed for %@: %@", endpoint, error);
        
        // Determine error type for better error messages
        NSInteger statusCode = 0;
        if ([operation.response isKindOfClass:[NSHTTPURLResponse class]]) {
            statusCode = [(NSHTTPURLResponse *)operation.response statusCode];
        }
        
        NSError *apiError;
        if (statusCode == 401 || statusCode == 403) {
            apiError = [self errorWithCode:CurseForgeErrorCodeAuthentication 
                                   message:@"Authentication failed. Please check your API key." 
                           underlyingError:error];
        } else if (statusCode == 404) {
            apiError = [self errorWithCode:CurseForgeErrorCodeResourceNotFound 
                                   message:@"The requested resource was not found." 
                           underlyingError:error];
        } else if (statusCode >= 500) {
            apiError = [self errorWithCode:CurseForgeErrorCodeServerError 
                                   message:@"A server error occurred. Please try again later." 
                           underlyingError:error];
        } else {
            apiError = [self errorWithCode:CurseForgeErrorCodeNetwork 
                                   message:@"A network error occurred. Please check your connection." 
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
    
    __block id result = nil;
    __block NSError *requestError = nil;
    dispatch_group_t group = dispatch_group_create();
    dispatch_group_enter(group);
    
    NSString *url = [self.baseURL stringByAppendingPathComponent:endpoint];
    AFHTTPSessionManager *manager = [AFHTTPSessionManager manager];
    
    [manager GET:url parameters:params headers:nil progress:nil success:^(NSURLSessionTask *task, id responseObject) {
        result = responseObject;
        dispatch_group_leave(group);
    } failure:^(NSURLSessionTask *operation, NSError *error) {
        requestError = error;
        self.lastError = error;
        dispatch_group_leave(group);
    }];
    
    dispatch_group_wait(group, DISPATCH_TIME_FOREVER);
    
    if (requestError) {
        NSLog(@"[ModpackAPI] GET request to %@ failed: %@", endpoint, requestError);
    }
    
    return result;
}

#pragma mark - Caching

- (NSString *)cacheKeyForEndpoint:(NSString *)endpoint params:(NSDictionary *)params {
    NSData *paramsData = [NSJSONSerialization dataWithJSONObject:params ?: @{} options:0 error:nil];
    NSString *paramsStr = paramsData ? [[NSString alloc] initWithData:paramsData encoding:NSUTF8StringEncoding] : @"";
    return [NSString stringWithFormat:@"%@-%@", endpoint, paramsStr];
}

#pragma mark - Search Implementation

- (void)searchModWithFilters:(NSDictionary *)searchFilters previousPageResult:(NSMutableArray *)prevResult completion:(void (^ _Nonnull)(NSMutableArray * _Nullable, NSError * _Nullable))completion {
    // Clear previous errors
    self.lastFetchError = nil;
    
    NSBlockOperation *operation = [NSBlockOperation blockOperationWithBlock:^{
        // Prepare parameters for the API request
        NSString *query = searchFilters[@"name"] ?: @"";
        NSMutableDictionary *params = [@{
            @"gameId": @(kCurseForgeGameIDMinecraft),
            @"classId": ([searchFilters[@"isModpack"] boolValue] ? @(kCurseForgeClassIDModpack) : @(kCurseForgeClassIDMod)),
            @"searchFilter": query,
            @"sortField": @(1), // Sort by popularity
            @"sortOrder": @"desc",
            @"pageSize": @(CURSEFORGE_PAGINATION_SIZE),
            @"index": @(prevResult.count)
        } mutableCopy];
        
        // Add game version filter if specified
        if (searchFilters[@"mcVersion"] && [searchFilters[@"mcVersion"] length] > 0) {
            params[@"gameVersion"] = searchFilters[@"mcVersion"];
        }
        
        // Add mod loader filter if specified
        if (searchFilters[@"loader"] && [searchFilters[@"loader"] length] > 0) {
            params[@"modLoaderType"] = searchFilters[@"loader"];
        }
        
        NSLog(@"searchModWithFilters: Searching with params: %@", params);
        
        __weak typeof(self) weakSelf = self;
        
        // Execute the API request
        [self getEndpoint:@"mods/search" params:params completion:^(id response, NSError *error) {
            __strong typeof(weakSelf) strongSelf = weakSelf;
            if (!strongSelf) {
                dispatch_async(dispatch_get_main_queue(), ^{
                    completion(nil, error);
                });
                return;
            }
            
            if (!response) {
                NSLog(@"searchModWithFilters: Failed: %@", error);
                dispatch_async(dispatch_get_main_queue(), ^{
                    completion(nil, strongSelf.lastFetchError ?: error);
                });
                return;
            }
            
            @try {
                // Process the API response
                NSMutableArray *result = prevResult ?: [NSMutableArray new];
                NSArray *data = response[@"data"];
                if (![data isKindOfClass:[NSArray class]]) {
                    NSLog(@"searchModWithFilters: Invalid data format");
                    dispatch_async(dispatch_get_main_queue(), ^{
                        NSError *formatError = [NSError errorWithDomain:CurseForgeAPIErrorDomain 
                                                                code:CurseForgeErrorCodeParsingError 
                                                            userInfo:@{NSLocalizedDescriptionKey: @"Invalid response format"}];
                        completion(nil, formatError);
                    });
                    return;
                }
                
                NSLog(@"searchModWithFilters: Found %lu items", (unsigned long)data.count);
                
                // Process each mod from the response
                for (NSDictionary *mod in data) {
                    if (![mod isKindOfClass:[NSDictionary class]]) continue;
                    
                    // Skip mods that don't allow distribution
                    id allow = mod[@"allowModDistribution"];
                    if (allow && ![allow isKindOfClass:[NSNull class]] && ![allow boolValue]) {
                        NSLog(@"searchModWithFilters: Skipping mod %@ due to distribution restriction", mod[@"name"]);
                        continue;
                    }
                    
                    // Extract required information safely
                    NSString *idString = [self safeStringFromDictionary:mod forKey:@"id" defaultValue:@"0"];
                    NSString *title = [self safeStringFromDictionary:mod forKey:@"name" defaultValue:@""];
                    NSString *description = [self safeStringFromDictionary:mod forKey:@"summary" defaultValue:@""];
                    
                    // Extract logo URL
                    NSString *imageUrl = @"";
                    if (mod[@"logo"] && [mod[@"logo"] isKindOfClass:[NSDictionary class]]) {
                        imageUrl = [self safeStringFromDictionary:mod[@"logo"] forKey:@"thumbnailUrl" defaultValue:@""];
                    }
                    
                    // Create the result entry
                    NSMutableDictionary *entry = [@{
                        @"apiSource": @(1),  // 1 = CurseForge
                        @"isModpack": @([searchFilters[@"isModpack"] boolValue]),
                        @"id": idString,
                        @"title": title,
                        @"description": description,
                        @"imageUrl": imageUrl
                    } mutableCopy];
                    
                    [result addObject:entry];
                }
                
                // Check if we've reached the last page
                NSDictionary *pagination = response[@"pagination"];
                if ([pagination isKindOfClass:[NSDictionary class]]) {
                    NSUInteger totalCount = [pagination[@"totalCount"] unsignedIntegerValue];
                    strongSelf.reachedLastPage = (result.count >= totalCount);
                } else {
                    strongSelf.reachedLastPage = YES;
                }
                
                dispatch_async(dispatch_get_main_queue(), ^{
                    completion(result, nil);
                });
            } @catch (NSException *exception) {
                NSLog(@"searchModWithFilters: Exception: %@", exception);
                dispatch_async(dispatch_get_main_queue(), ^{
                    NSError *exceptionError = [NSError errorWithDomain:CurseForgeAPIErrorDomain 
                                                                code:CurseForgeErrorCodeParsingError 
                                                            userInfo:@{NSLocalizedDescriptionKey: [NSString stringWithFormat:@"Exception: %@", exception.reason]}];
                    completion(nil, exceptionError);
                });
            }
        }];
    }];
    
    [self.operationQueue addOperation:operation];
}

#pragma mark - Load Details of Mod

- (void)loadDetailsOfMod:(NSMutableDictionary *)item completion:(void (^ _Nonnull)(NSError * _Nullable))completion {
    // Clear previous error
    self.lastFetchError = nil;
    
    NSBlockOperation *operation = [NSBlockOperation blockOperationWithBlock:^{
        // Get the mod ID
        NSString *modId = [NSString stringWithFormat:@"%@", item[@"id"]];
        NSLog(@"loadDetailsOfMod: Loading details for mod ID %@", modId);
        
        // Endpoint to get files for the mod
        [self getEndpoint:[NSString stringWithFormat:@"mods/%@/files", modId] params:nil completion:^(id response, NSError *error) {
            if (!response) {
                NSLog(@"loadDetailsOfMod: Failed to load details for %@: %@", modId, error);
                if (completion) {
                    completion(error);
                }
                return;
            }
            
            // Process the files from the response
            NSArray *files = response[@"data"];
            NSMutableArray *names = [NSMutableArray new];
            NSMutableArray *mcNames = [NSMutableArray new];
            NSMutableArray *urls = [NSMutableArray new];
            NSMutableArray *hashes = [NSMutableArray new];
            NSMutableArray *sizes = [NSMutableArray new];
            NSMutableArray *loaders = [NSMutableArray new];
            
            // Sort files by date (newest first)
            NSArray *sortedFiles = [files sortedArrayUsingComparator:^NSComparisonResult(NSDictionary *file1, NSDictionary *file2) {
                NSString *dateStr1 = file1[@"fileDate"];
                NSString *dateStr2 = file2[@"fileDate"];
                
                if (dateStr1 && dateStr2) {
                    NSDateFormatter *formatter = [[NSDateFormatter alloc] init];
                    formatter.dateFormat = @"yyyy-MM-dd'T'HH:mm:ss.SSSZ";
                    NSDate *date1 = [formatter dateFromString:dateStr1];
                    NSDate *date2 = [formatter dateFromString:dateStr2];
                    
                    if (date1 && date2) {
                        return [date2 compare:date1]; // Newest first
                    }
                }
                
                // Fallback to filename comparison
                NSString *fileName1 = file1[@"fileName"] ?: @"";
                NSString *fileName2 = file2[@"fileName"] ?: @"";
                return [fileName2 compare:fileName1];
            }];
            
            // Process each file
            for (NSDictionary *file in sortedFiles) {
                // Skip files that are not available
                if (![file[@"isAvailable"] boolValue]) {
                    continue;
                }
                
                // Add file name
                NSString *fileName = [self safeStringFromDictionary:file forKey:@"fileName" defaultValue:@""];
                [names addObject:fileName];
                
                // Extract game versions
                NSArray *gameVersions = file[@"gameVersions"];
                NSMutableArray *versionsArray = [NSMutableArray new];
                NSMutableArray *loaderArray = [NSMutableArray new];
                
                if ([gameVersions isKindOfClass:[NSArray class]]) {
                    for (id version in gameVersions) {
                        if ([version isKindOfClass:[NSString class]]) {
                            NSString *versionStr = (NSString *)version;
                            
                            // Categorize as Minecraft version or loader
                            if ([versionStr hasPrefix:@"1."] || [versionStr hasPrefix:@"2."]) {
                                [versionsArray addObject:versionStr];
                            } else if ([versionStr caseInsensitiveCompare:@"Forge"] == NSOrderedSame ||
                                      [versionStr caseInsensitiveCompare:@"Fabric"] == NSOrderedSame || 
                                      [versionStr caseInsensitiveCompare:@"Quilt"] == NSOrderedSame ||
                                      [versionStr caseInsensitiveCompare:@"NeoForge"] == NSOrderedSame) {
                                [loaderArray addObject:versionStr];
                            }
                        }
                    }
                }
                
                [mcNames addObject:versionsArray];
                
                // Extract download URL
                NSString *downloadUrl = [self safeStringFromDictionary:file forKey:@"downloadUrl" defaultValue:@""];
                BOOL needsDownloadUrl = (downloadUrl.length == 0 || [downloadUrl isEqualToString:@"(null)"]);
                
                if (needsDownloadUrl) {
                    // Store placeholder that will be resolved when user selects this version
                    [urls addObject:[NSString stringWithFormat:@"placeholder:%@:%@", 
                                    file[@"modId"] ?: modId, 
                                    file[@"id"] ?: @"0"]];
                } else {
                    [urls addObject:downloadUrl];
                }
                
                // Extract file size
                NSNumber *fileSize = @0;
                id fileLengthValue = file[@"fileLength"];
                if ([fileLengthValue isKindOfClass:[NSNumber class]]) {
                    fileSize = fileLengthValue;
                } else if ([fileLengthValue isKindOfClass:[NSString class]]) {
                    fileSize = @([fileLengthValue unsignedLongLongValue]);
                }
                [sizes addObject:fileSize];
                
                // Extract hash
                NSString *sha1 = @"";
                NSArray *hashesArray = file[@"hashes"];
                if ([hashesArray isKindOfClass:[NSArray class]]) {
                    for (NSDictionary *hashDict in hashesArray) {
                        if ([[self safeStringFromDictionary:hashDict forKey:@"algo" defaultValue:@""] isEqualToString:@"SHA1"]) {
                            sha1 = [self safeStringFromDictionary:hashDict forKey:@"value" defaultValue:@""];
                            break;
                        }
                    }
                }
                [hashes addObject:sha1];
                
                // Look at dependencies for loader info
                NSArray *dependencies = file[@"dependencies"];
                if ([dependencies isKindOfClass:[NSArray class]]) {
                    for (NSDictionary *dep in dependencies) {
                        if ([dep isKindOfClass:[NSDictionary class]]) {
                            NSNumber *modId = dep[@"modId"];
                            if (modId) {
                                // Common mod loader IDs in CurseForge
                                if ([modId integerValue] == 306612 && ![loaderArray containsObject:@"Fabric"]) {
                                    [loaderArray addObject:@"Fabric"];
                                } else if ([modId integerValue] == 250763 && ![loaderArray containsObject:@"Forge"]) {
                                    [loaderArray addObject:@"Forge"];
                                } else if ([modId integerValue] == 634179 && ![loaderArray containsObject:@"Quilt"]) {
                                    [loaderArray addObject:@"Quilt"];
                                }
                            }
                        }
                    }
                }
                
                // If still no loaders detected, check filename for hints
                if (loaderArray.count == 0) {
                    NSString *lowerFileName = [fileName lowercaseString];
                    
                    if ([lowerFileName containsString:@"fabric"]) {
                        [loaderArray addObject:@"Fabric"];
                    }
                    if ([lowerFileName containsString:@"forge"]) {
                        [loaderArray addObject:@"Forge"];
                    }
                    if ([lowerFileName containsString:@"quilt"]) {
                        [loaderArray addObject:@"Quilt"];
                    }
                    if ([lowerFileName containsString:@"neoforge"]) {
                        [loaderArray addObject:@"NeoForge"];
                    }
                }
                
                // Add loader info to the list
                [loaders addObject:loaderArray];
            }
            
            // Update the item with all collected information
            dispatch_async(dispatch_get_main_queue(), ^{
                item[@"versionNames"] = names;
                item[@"mcVersionNames"] = mcNames;
                item[@"versionUrls"] = urls;
                item[@"versionHashes"] = hashes;
                item[@"versionSizes"] = sizes;
                item[@"versionLoaders"] = loaders;
                item[@"versionDetailsLoaded"] = @(YES);
                NSLog(@"loadDetailsOfMod: Loaded %lu versions for mod %@", (unsigned long)names.count, modId);
                
                if (completion) {
                    completion(nil);
                }
            });
        }];
    }];
    
    [self.operationQueue addOperation:operation];
}

#pragma mark - Download URL Generation

- (void)getDownloadUrlForProject:(uint64_t)projectID fileID:(uint64_t)fileID completion:(void (^)(NSString *, NSError *))completion {
    NSString *endpoint = [NSString stringWithFormat:@"mods/%llu/files/%llu/download-url", projectID, fileID];
    
    [self getEndpoint:endpoint params:@{@"skipCache": @YES} completion:^(id response, NSError *error) {
        if (response && response[@"data"] && ![response[@"data"] isKindOfClass:[NSNull class]]) {
            NSString *urlString = [NSString stringWithFormat:@"%@", response[@"data"]];
            NSLog(@"getDownloadUrlForProject: Got URL for project %llu, file %llu", projectID, fileID);
            if (completion) completion(urlString, nil);
        } else {
            // Use fallback URL if API fails
            NSString *fallbackUrl = [NSString stringWithFormat:@"https://www.curseforge.com/api/v1/mods/%llu/files/%llu/download", projectID, fileID];
            if (self.apiKey.length > 0) {
                fallbackUrl = [fallbackUrl stringByAppendingFormat:@"?apiKey=%@", self.apiKey];
            }
            
            NSLog(@"getDownloadUrlForProject: Using fallback URL for project %llu, file %llu", projectID, fileID);
            if (completion) {
                if (error) {
                    completion(fallbackUrl, error);
                } else {
                    completion(fallbackUrl, nil);
                }
            }
        }
    }];
}

#pragma mark - Mod Installation

- (void)installModFromDetail:(NSDictionary *)modDetail atIndex:(NSUInteger)selectedVersion {
    // Basic validation
    if (!modDetail) {
        NSLog(@"[CurseForge] Cannot install mod: nil modDetail");
        return;
    }
    
    NSArray *versionUrls = modDetail[@"versionUrls"];
    if (!versionUrls || selectedVersion >= versionUrls.count) {
        NSLog(@"[CurseForge] Invalid version index for mod installation");
        return;
    }
    
    NSString *urlString = versionUrls[selectedVersion];
    
    // Check if we need to resolve a placeholder URL
    if ([urlString hasPrefix:@"placeholder:"]) {
        NSArray *components = [urlString componentsSeparatedByString:@":"];
        if (components.count >= 3) {
            NSString *projectId = components[1];
            NSString *fileId = components[2];
            
            // Get download URL and install
            [self getDownloadUrlForProject:[projectId longLongValue] fileID:[fileId longLongValue] completion:^(NSString *downloadUrl, NSError *error) {
                if (downloadUrl) {
                    // Create a new modDetail with the resolved URL
                    NSMutableDictionary *updatedDetail = [modDetail mutableCopy];
                    NSMutableArray *updatedUrls = [versionUrls mutableCopy];
                    updatedUrls[selectedVersion] = downloadUrl;
                    updatedDetail[@"versionUrls"] = updatedUrls;
                    
                    // Post notification to handle actual installation
                    NSDictionary *userInfo = @{@"detail": updatedDetail, @"index": @(selectedVersion)};
                    dispatch_async(dispatch_get_main_queue(), ^{
                        [[NSNotificationCenter defaultCenter] postNotificationName:@"InstallMod" object:self userInfo:userInfo];
                    });
                } else {
                    NSLog(@"[CurseForge] Failed to get download URL for mod: %@", error);
                    dispatch_async(dispatch_get_main_queue(), ^{
                        [UIAlertUtilities presentAlertWithTitle:@"Download Error" 
                                                      message:[NSString stringWithFormat:@"Could not retrieve download URL: %@", error.localizedDescription]
                                              viewController:self.parentViewController];
                    });
                }
            }];
        }
    } else {
        // URL already resolved - post notification for installation
        NSDictionary *userInfo = @{@"detail": modDetail, @"index": @(selectedVersion)};
        dispatch_async(dispatch_get_main_queue(), ^{
            [[NSNotificationCenter defaultCenter] postNotificationName:@"InstallMod" object:self userInfo:userInfo];
        });
    }
}

#pragma mark - Modpack Installation

- (void)installModpackFromDetail:(NSDictionary *)modDetail atIndex:(NSUInteger)selectedVersion completion:(void (^)(NSError * _Nullable))completion {
    NSLog(@"[CurseForge-Modpack] Starting installation for modpack %@ (version index: %lu)", modDetail[@"title"], (unsigned long)selectedVersion);
    
    // Validate input
    NSArray *versionUrls = modDetail[@"versionUrls"];
    if (selectedVersion >= versionUrls.count) {
        NSError *error = [self errorWithCode:CurseForgeErrorCodeResourceNotFound
                                     message:@"Invalid version index"
                             underlyingError:nil];
        if (completion) {
            completion(error);
        }
        return;
    }
    
    NSString *urlString = versionUrls[selectedVersion];
    
    // Create a download task for tracking progress
    MinecraftResourceDownloadTask *downloadTask = [[MinecraftResourceDownloadTask alloc] init];
    [downloadTask prepareForDownload];
    
    // Resolve placeholder URL if needed
    if ([urlString hasPrefix:@"placeholder:"]) {
        NSArray *components = [urlString componentsSeparatedByString:@":"];
        if (components.count >= 3) {
            NSString *projectId = components[1];
            NSString *fileId = components[2];
            
            [self getDownloadUrlForProject:[projectId longLongValue] fileID:[fileId longLongValue] completion:^(NSString *downloadUrl, NSError *error) {
                if (!downloadUrl) {
                    if (completion) {
                        completion(error);
                    }
                    return;
                }
                
                [self downloadAndInstallModpackWithURL:downloadUrl 
                                             modDetail:modDetail 
                                       selectedVersion:selectedVersion 
                                          downloadTask:downloadTask
                                           completion:completion];
            }];
        } else {
            NSError *error = [self errorWithCode:CurseForgeErrorCodeParsingError
                                         message:@"Invalid placeholder URL format"
                                 underlyingError:nil];
            if (completion) {
                completion(error);
            }
        }
    } else {
        // URL already resolved
        [self downloadAndInstallModpackWithURL:urlString 
                                     modDetail:modDetail 
                               selectedVersion:selectedVersion 
                                  downloadTask:downloadTask
                                   completion:completion];
    }
}

- (void)downloadAndInstallModpackWithURL:(NSString *)downloadUrl 
                               modDetail:(NSDictionary *)modDetail 
                         selectedVersion:(NSUInteger)selectedVersion 
                            downloadTask:(MinecraftResourceDownloadTask *)downloadTask
                             completion:(void (^)(NSError *))completion {
    // Create a temporary directory for the modpack ZIP
    NSString *tempDir = NSTemporaryDirectory();
    NSString *profileName = [modDetail[@"title"] stringByReplacingOccurrencesOfString:@" " withString:@"_"];
    NSString *zipPath = [tempDir stringByAppendingPathComponent:[NSString stringWithFormat:@"%@.zip", profileName]];
    
    // Generate safe profile name for directory
    NSString *safeProfileName = [profileName stringByReplacingOccurrencesOfString:@"/" withString:@"_"];
    safeProfileName = [safeProfileName stringByReplacingOccurrencesOfString:@"\\" withString:@"_"];
    safeProfileName = [safeProfileName stringByReplacingOccurrencesOfString:@":" withString:@"_"];
    
    // Set up profile directory
    NSString *gameDir = [NSString stringWithFormat:@"./profiles/%@", safeProfileName];
    NSString *destPath = [PLProfiles fullPathForProfileWithName:safeProfileName gameDir:gameDir];
    
    // Make sure the destination directory exists
    NSError *dirError = nil;
    [[NSFileManager defaultManager] createDirectoryAtPath:destPath
                            withIntermediateDirectories:YES
                                             attributes:nil
                                                  error:&dirError];
    if (dirError) {
        NSLog(@"[CurseForge-Modpack] Failed to create destination directory: %@", dirError);
        if (completion) {
            completion(dirError);
        }
        return;
    }
    
    // Create mods directory up front
    NSString *modsDir = [destPath stringByAppendingPathComponent:@"mods"];
    [[NSFileManager defaultManager] createDirectoryAtPath:modsDir
                           withIntermediateDirectories:YES
                                            attributes:nil
                                                 error:nil];
    
    NSLog(@"[CurseForge-Modpack] Downloading modpack to %@", zipPath);
    
    // Create a download task for the modpack zip file
    __weak typeof(self) weakSelf = self;
    NSURLSessionDownloadTask *task = [downloadTask createDownloadTask:downloadUrl 
                                                              size:0
                                                               sha:nil
                                                           altName:[NSString stringWithFormat:@"Downloading %@", modDetail[@"title"]]
                                                            toPath:zipPath
                                                           success:^{
        // Extract the modpack
        NSError *extractError = nil;
        UZKArchive *archive = [[UZKArchive alloc] initWithPath:zipPath error:&extractError];
        
        if (extractError) {
            NSLog(@"[CurseForge-Modpack] Failed to open zip archive: %@", extractError);
            if (completion) {
                completion(extractError);
            }
            return;
        }
        
        // Create extraction progress
        __block NSProgress *extractionProgress;
        dispatch_async(dispatch_get_main_queue(), ^{
            [downloadTask.fileList addObject:@"Extracting overrides"];
            
            // Create progress for extraction and add to tracking
            extractionProgress = [NSProgress progressWithTotalUnitCount:1];
            extractionProgress.kind = NSProgressKindFile;
            [downloadTask.progressList addObject:extractionProgress];
            [downloadTask.progress addChild:extractionProgress withPendingUnitCount:1];
        });
        
        // Extract the manifest
        NSData *manifestData = [archive extractDataFromFile:@"manifest.json" error:&extractError];
        if (!manifestData) {
            NSLog(@"[CurseForge-Modpack] Failed to extract manifest.json: %@", extractError);
            if (completion) {
                NSError *customError = [weakSelf errorWithCode:CurseForgeErrorCodeExtraction
                                               message:@"Failed to extract manifest.json from modpack"
                                       underlyingError:extractError];
                completion(customError);
            }
            return;
        }
        
        // Parse the manifest
        NSDictionary *manifestDict = [NSJSONSerialization JSONObjectWithData:manifestData options:0 error:&extractError];
        if (!manifestDict) {
            NSLog(@"[CurseForge-Modpack] Failed to parse manifest.json: %@", extractError);
            if (completion) {
                NSError *customError = [weakSelf errorWithCode:CurseForgeErrorCodeParsingError
                                               message:@"Failed to parse manifest.json"
                                       underlyingError:extractError];
                completion(customError);
            }
            return;
        }
        
        // Verify the manifest
        if (![weakSelf verifyManifestFromDictionary:manifestDict]) {
            NSLog(@"[CurseForge-Modpack] Invalid manifest");
            if (completion) {
                NSError *customError = [weakSelf errorWithCode:CurseForgeErrorCodeInvalidManifest
                                               message:@"Invalid manifest format"
                                       underlyingError:nil];
                completion(customError);
            }
            return;
        }
        
        // Extract Minecraft version and mod loader info from manifest
        NSDictionary *minecraft = manifestDict[@"minecraft"];
        NSString *vanillaVersion = minecraft[@"version"] ?: @"";
        NSString *modLoaderId = @"";
        NSString *modLoaderVersion = @"";
        NSString *finalVersionString = @"";
        CurseForgeLoader loaderType = CurseForgeLoaderUnknown;
        
        // Find the primary mod loader
        NSArray *modLoaders = minecraft[@"modLoaders"];
        NSDictionary *primaryModLoader = nil;
        
        for (NSDictionary *loader in modLoaders) {
            if ([loader[@"primary"] boolValue]) {
                primaryModLoader = loader;
                break;
            }
        }
        
        if (!primaryModLoader && modLoaders.count > 0) {
            primaryModLoader = modLoaders[0];
        }
        
        // Parse the loader ID
        NSString *rawId = primaryModLoader[@"id"] ?: @"";
        NSRange dashRange = [rawId rangeOfString:@"-"];
        if (dashRange.location != NSNotFound) {
            NSString *loaderName = [rawId substringToIndex:dashRange.location];
            NSString *loaderVer = [rawId substringFromIndex:(dashRange.location + 1)];
            
            if ([loaderName isEqualToString:@"forge"]) {
                modLoaderId = @"forge";
                modLoaderVersion = loaderVer;
                finalVersionString = [NSString stringWithFormat:@"%@-forge-%@", vanillaVersion, modLoaderVersion];
                loaderType = CurseForgeLoaderForge;
            } else if ([loaderName isEqualToString:@"fabric"]) {
                modLoaderId = @"fabric";
                modLoaderVersion = loaderVer;
                finalVersionString = [NSString stringWithFormat:@"fabric-loader-%@-%@", modLoaderVersion, vanillaVersion];
                loaderType = CurseForgeLoaderFabric;
            } else if ([loaderName isEqualToString:@"quilt"]) {
                modLoaderId = @"quilt";
                modLoaderVersion = loaderVer;
                finalVersionString = [NSString stringWithFormat:@"quilt-loader-%@-%@", modLoaderVersion, vanillaVersion];
                loaderType = CurseForgeLoaderQuilt;
            } else if ([loaderName isEqualToString:@"neoforge"]) {
                modLoaderId = @"neoforge";
                modLoaderVersion = loaderVer;
                finalVersionString = [NSString stringWithFormat:@"%@-neoforge-%@", vanillaVersion, modLoaderVersion];
                loaderType = CurseForgeLoaderNeoForge;
            }
        }
        
        // Create the loader JSON file
        NSString *jsonPath = [weakSelf createModLoaderJSON:vanillaVersion 
                                            loaderVersion:modLoaderVersion 
                                               loaderType:loaderType];
        
        // Extract overrides
        NSError *overridesError = nil;
        [ModpackUtils archive:archive extractDirectory:@"overrides" toPath:destPath error:&overridesError];
        if (overridesError) {
            NSLog(@"[CurseForge-Modpack] Failed to extract overrides: %@", overridesError);
        }
        
        // Mark extraction as complete
        dispatch_async(dispatch_get_main_queue(), ^{
            extractionProgress.completedUnitCount = 1;
        });
        
        // Create setup progress
        __block NSProgress *setupProgress;
        dispatch_async(dispatch_get_main_queue(), ^{
            [downloadTask.fileList addObject:@"Setting up profile"];
            
            // Create progress for profile setup
            setupProgress = [NSProgress progressWithTotalUnitCount:1];
            setupProgress.kind = NSProgressKindFile;
            [downloadTask.progressList addObject:setupProgress];
            [downloadTask.progress addChild:setupProgress withPendingUnitCount:1];
        });
        
        // Download mod files
        [weakSelf downloadModFilesFromManifest:manifestDict 
                                   toModsDir:modsDir
                                downloadTask:downloadTask 
                                  completion:^(NSUInteger completedFiles, NSUInteger totalFiles, NSUInteger failedFiles) {
            // Create a log file
            NSString *logContent = [NSString stringWithFormat:@"CurseForge modpack installation completed\n"
                                  "Profile: %@\n"
                                  "Directory: %@\n"
                                  "Total files: %lu\n"
                                  "Completed: %lu\n"
                                  "Failed: %lu\n"
                                  "Date: %@",
                                  profileName, destPath, (unsigned long)totalFiles, 
                                  (unsigned long)completedFiles, (unsigned long)failedFiles,
                                  [NSDate date]];
            
            [logContent writeToFile:[destPath stringByAppendingPathComponent:@"curseforge_install.log"]
                         atomically:YES
                           encoding:NSUTF8StringEncoding
                              error:nil];
            
            // Clean up ZIP file
            [[NSFileManager defaultManager] removeItemAtPath:zipPath error:nil];
            
            // Update profile
            dispatch_async(dispatch_get_main_queue(), ^{
                // Create the profile with the modpack info
                NSString *profileName = manifestDict[@"name"] ?: @"CurseForge Modpack";
                NSString *safeProfileName = [profileName stringByReplacingOccurrencesOfString:@"/" withString:@"_"];
                safeProfileName = [safeProfileName stringByReplacingOccurrencesOfString:@"\\" withString:@"_"];
                safeProfileName = [safeProfileName stringByReplacingOccurrencesOfString:@":" withString:@"_"];
                
                PLProfiles.current.profiles[safeProfileName] = @{
                    @"gameDir": gameDir,
                    @"name": profileName,
                    @"lastVersionId": finalVersionString.length > 0 ? finalVersionString : @"latest-release",
                    @"icon": @"" // CurseForge doesn't typically provide icon data
                }.mutableCopy;
                
                PLProfiles.current.selectedProfileName = safeProfileName;
                [PLProfiles.current save];
                
                // Mark setup as complete
                setupProgress.completedUnitCount = 1;
                
                // Add completion progress
                [downloadTask.fileList addObject:@"Complete"];
                
                // Create completion progress
                NSProgress *completeProgress = [NSProgress progressWithTotalUnitCount:1];
                completeProgress.completedUnitCount = 1; // Already complete
                completeProgress.kind = NSProgressKindFile;
                [downloadTask.progressList addObject:completeProgress];
                [downloadTask.progress addChild:completeProgress withPendingUnitCount:1];
            });
            
            if (completion) {
                completion(nil);
            }
        }];
    }];
    
    // Start the download
    [task resume];
}

- (void)downloadModFilesFromManifest:(NSDictionary *)manifestDict 
                           toModsDir:(NSString *)modsDir
                        downloadTask:(MinecraftResourceDownloadTask *)downloadTask
                          completion:(void (^)(NSUInteger completedFiles, NSUInteger totalFiles, NSUInteger failedFiles))completion {
    // Get the files array from the manifest
    NSArray *files = manifestDict[@"files"];
    if (!files || ![files isKindOfClass:[NSArray class]]) {
        NSLog(@"[CurseForge-Modpack] No files found in manifest");
        if (completion) {
            completion(0, 0, 0);
        }
        return;
    }
    
    NSLog(@"[CurseForge-Modpack] Preparing to download %lu mod files", (unsigned long)files.count);
    
    // Update progress
    dispatch_async(dispatch_get_main_queue(), ^{
        downloadTask.textProgress.localizedDescription = [NSString stringWithFormat:@"Preparing %lu mod downloads", (unsigned long)files.count];
    });
    
    // Keep track of download status
    __block NSInteger totalFiles = files.count;
    __block NSInteger completedFiles = 0;
    __block NSInteger failedFiles = 0;
    __block NSMutableArray *downloadTasks = [NSMutableArray array];
    
    // Use dispatch group to track downloads
    dispatch_group_t downloadGroup = dispatch_group_create();
    
    // Process each file
    for (NSDictionary *file in files) {
        NSNumber *projectID = file[@"projectID"];
        NSNumber *fileID = file[@"fileID"];
        BOOL required = [file[@"required"] boolValue];
        
        if (!projectID || !fileID) {
            NSLog(@"[CurseForge-Modpack] Invalid file entry: missing projectID or fileID");
            failedFiles++;
            continue;
        }
        
        // Get download URL for this file
        dispatch_group_enter(downloadGroup);
        [self getDownloadUrlForProject:[projectID unsignedLongLongValue] 
                               fileID:[fileID unsignedLongLongValue] 
                           completion:^(NSString *downloadUrl, NSError *error) {
            if (!downloadUrl) {
                failedFiles++;
                NSLog(@"[CurseForge-Modpack] Failed to get download URL for project %@, file %@: %@", 
                      projectID, fileID, error);
                
                // Only fail if the file is required
                if (required) {
                    NSLog(@"[CurseForge-Modpack] Required mod download failed");
                }
                dispatch_group_leave(downloadGroup);
                return;
            }
            
            // Get file name from URL or use project/file IDs if not available
            NSString *fileName = [NSURL URLWithString:downloadUrl].lastPathComponent;
            if (!fileName || fileName.length == 0) {
                fileName = [NSString stringWithFormat:@"mod_%@_%@.jar", projectID, fileID];
            }
            
            // Path to save the file
            NSString *modPath = [modsDir stringByAppendingPathComponent:fileName];
            
            // Create a download task using MinecraftResourceDownloadTask's built-in method
            // This ensures proper tracking with the UI
            NSURLSessionDownloadTask *task = [downloadTask createDownloadTask:downloadUrl 
                                                                        size:0 // Size not known yet
                                                                         sha:nil 
                                                                     altName:[NSString stringWithFormat:@"Mod: %@", fileName] 
                                                                      toPath:modPath];
            
            if (task) {
                @synchronized(downloadTasks) {
                    [downloadTasks addObject:task];
                }
                [task resume];
            } else {
                failedFiles++;
                NSLog(@"[CurseForge-Modpack] Failed to create download task for %@", fileName);
            }
            
            dispatch_group_leave(downloadGroup);
        }];
    }
    
    // Wait for URL resolution to complete (this happens quickly)
    dispatch_group_wait(downloadGroup, dispatch_time(DISPATCH_TIME_NOW, 30 * NSEC_PER_SEC));
    
    // Create a new dispatch group for monitoring downloads
    dispatch_group_t completionGroup = dispatch_group_create();
    dispatch_group_enter(completionGroup);
    
    // Start a background task to monitor download completion
    dispatch_async(dispatch_get_global_queue(DISPATCH_QUEUE_PRIORITY_DEFAULT, 0), ^{
        // Check periodically if all downloads are complete
        dispatch_source_t timer = dispatch_source_create(DISPATCH_SOURCE_TYPE_TIMER, 0, 0, dispatch_get_global_queue(DISPATCH_QUEUE_PRIORITY_DEFAULT, 0));
        dispatch_source_set_timer(timer, dispatch_walltime(NULL, 0), 1 * NSEC_PER_SEC, 0.1 * NSEC_PER_SEC);
        
        __block int checkCount = 0;
        dispatch_source_set_event_handler(timer, ^{
            // Check if all tasks are completed
            BOOL allCompleted = YES;
            @synchronized(downloadTasks) {
                for (NSURLSessionDownloadTask *task in downloadTasks) {
                    if (task.state != NSURLSessionTaskStateCompleted) {
                        allCompleted = NO;
                        break;
                    }
                }
            }
            
            checkCount++;
            
            // If all downloads are complete or we've checked enough times, proceed
            if (allCompleted || checkCount > 120) { // 2 minutes max wait
                dispatch_source_cancel(timer);
                
                // Count successful downloads
                completedFiles = totalFiles - failedFiles;
                NSLog(@"[CurseForge-Modpack] All downloads completed: %ld successful, %ld failed", 
                      (long)completedFiles, (long)failedFiles);
                
                dispatch_group_leave(completionGroup);
            }
        });
        
        dispatch_resume(timer);
    });
    
    // Wait for download completion (with timeout)
    long result = dispatch_group_wait(completionGroup, dispatch_time(DISPATCH_TIME_NOW, 300 * NSEC_PER_SEC));
    if (result != 0) {
        NSLog(@"[CurseForge-Modpack] Timeout waiting for downloads to complete");
    }
    
    // Provide completion info
    if (completion) {
        completion((NSUInteger)completedFiles, (NSUInteger)totalFiles, (NSUInteger)failedFiles);
    }
}

#pragma mark - Manifest Verification

- (BOOL)verifyManifestFromDictionary:(NSDictionary *)manifest {
    // Check for required fields
    if (![manifest[@"manifestType"] isEqualToString:@"minecraftModpack"]) {
        NSLog(@"[CurseForge-Manifest] Invalid manifestType: %@", manifest[@"manifestType"]);
        return NO;
    }
    
    if ([manifest[@"manifestVersion"] integerValue] != 1) {
        NSLog(@"[CurseForge-Manifest] Unsupported manifestVersion: %@", manifest[@"manifestVersion"]);
        return NO;
    }
    
    if (!manifest[@"minecraft"]) {
        NSLog(@"[CurseForge-Manifest] Missing minecraft key");
        return NO;
    }
    
    NSDictionary *minecraft = manifest[@"minecraft"];
    if (!minecraft[@"version"]) {
        NSLog(@"[CurseForge-Manifest] Missing minecraft.version");
        return NO;
    }
    
    if (!minecraft[@"modLoaders"]) {
        NSLog(@"[CurseForge-Manifest] Missing minecraft.modLoaders");
        return NO;
    }
    
    NSArray *modLoaders = minecraft[@"modLoaders"];
    if (![modLoaders isKindOfClass:[NSArray class]] || modLoaders.count < 1) {
        NSLog(@"[CurseForge-Manifest] Invalid modLoaders: %@", modLoaders);
        return NO;
    }
    
    // Check for files list
    if (!manifest[@"files"] || ![manifest[@"files"] isKindOfClass:[NSArray class]]) {
        NSLog(@"[CurseForge-Manifest] Missing or invalid files list");
        return NO;
    }
    
    NSLog(@"[CurseForge-Manifest] Manifest is valid");
    return YES;
}

#pragma mark - Mod Loader Installation

- (NSString *)createModLoaderJSON:(NSString *)minecraftVersion loaderVersion:(NSString *)loaderVersion loaderType:(CurseForgeLoader)loaderType {
    if (!minecraftVersion || minecraftVersion.length == 0 || !loaderVersion || loaderVersion.length == 0) {
        NSLog(@"[CurseForgeAPI] Missing version information for mod loader JSON");
        return nil;
    }
    
    NSString *finalId = nil;
    NSDictionary *loaderDict = nil;
    
    switch (loaderType) {
        case CurseForgeLoaderForge:
            finalId = [NSString stringWithFormat:@"%@-forge-%@", minecraftVersion, loaderVersion];
            loaderDict = @{
                @"id": finalId,
                @"type": @"custom",
                @"minecraft": minecraftVersion,
                @"loader": @"forge",
                @"loaderVersion": loaderVersion
            };
            break;
            
        case CurseForgeLoaderFabric:
            finalId = [NSString stringWithFormat:@"fabric-loader-%@-%@", loaderVersion, minecraftVersion];
            loaderDict = @{
                @"id": finalId,
                @"type": @"custom",
                @"minecraft": minecraftVersion,
                @"loader": @"fabric",
                @"loaderVersion": finalId
            };
            break;
            
        case CurseForgeLoaderQuilt:
            finalId = [NSString stringWithFormat:@"quilt-loader-%@-%@", loaderVersion, minecraftVersion];
            loaderDict = @{
                @"id": finalId,
                @"type": @"custom",
                @"minecraft": minecraftVersion,
                @"loader": @"quilt",
                @"loaderVersion": finalId
            };
            break;
            
        case CurseForgeLoaderNeoForge:
            finalId = [NSString stringWithFormat:@"%@-neoforge-%@", minecraftVersion, loaderVersion];
            loaderDict = @{
                @"id": finalId,
                @"type": @"custom",
                @"minecraft": minecraftVersion,
                @"loader": @"neoforge",
                @"loaderVersion": loaderVersion
            };
            break;
            
        default:
            NSLog(@"[CurseForgeAPI] Unknown mod loader type: %ld", (long)loaderType);
            return nil;
    }
    
    if (!finalId || !loaderDict) {
        return nil;
    }
    
    NSString *jsonPath = [NSString stringWithFormat:@"%@/versions/%@/%@.json", 
                         [NSString stringWithUTF8String:getenv("POJAV_GAME_DIR")], finalId, finalId];
    
    [[NSFileManager defaultManager] createDirectoryAtPath:jsonPath.stringByDeletingLastPathComponent 
                             withIntermediateDirectories:YES 
                                              attributes:nil 
                                                   error:nil];
    
    NSError *writeErr = saveJSONToFile(loaderDict, jsonPath);
    if (writeErr) {
        NSLog(@"[CurseForgeAPI] Failed to write loader JSON: %@", writeErr);
        return nil;
    } else {
        NSLog(@"[CurseForgeAPI] Successfully created loader JSON at %@", jsonPath);
        return jsonPath;
    }
}

#pragma mark - Utility Methods

- (NSString *)safeStringFromDictionary:(NSDictionary *)dict forKey:(NSString *)key defaultValue:(NSString *)defaultValue {
    id value = dict[key];
    if (!value || [value isKindOfClass:[NSNull class]]) {
        return defaultValue;
    }
    
    if ([value isKindOfClass:[NSString class]]) {
        return value;
    } else {
        return [NSString stringWithFormat:@"%@", value];
    }
}

@end

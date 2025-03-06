#import "CurseForgeAPI.h"
#import "MinecraftResourceDownloadTask.h"
#import "PLProfiles.h"
#import "ModpackUtils.h"
#import "UnzipKit.h"
#import "AFNetworking.h"
#import "UIAlertUtilities.h"
#import "installer/FabricUtils.h"
#import "config.h"
#import "utils.h"
#import "DownloadProgressViewController.h"

#pragma mark - Constants and Helpers

// CurseForge API Constants
#define kCurseForgeGameIDMinecraft 432
#define kCurseForgeClassIDModpack 4471
#define kCurseForgeClassIDMod 6
#define CURSEFORGE_PAGINATION_SIZE 50

typedef NS_ENUM(NSInteger, CurseForgeErrorCode) {
    CurseForgeErrorCodeNetwork = 1000,
    CurseForgeErrorCodeAuthentication = 1001,
    CurseForgeErrorCodeResourceNotFound = 1002,
    CurseForgeErrorCodeServerError = 1003,
    CurseForgeErrorCodeParsingError = 1004,
    CurseForgeErrorCodeExtraction = 1005,
    CurseForgeErrorCodeInvalidManifest = 1006
};

#pragma mark - Private Interface

@interface CurseForgeAPI ()
@property (nonatomic, copy) NSString *apiKey;
@property (nonatomic, strong) AFHTTPSessionManager *sessionManager;
@property (nonatomic, strong) NSCache *responseCache;
@property (nonatomic, strong) NSOperationQueue *operationQueue;
@property (nonatomic, strong) NSMutableDictionary *taskPathMap;
@property (nonatomic, strong) NSError *lastFetchError;

// Private Methods
- (NSError *)errorWithCode:(CurseForgeErrorCode)code message:(NSString *)message underlyingError:(NSError *)underlyingError;
- (void)getDownloadUrlForProject:(unsigned long long)projectID fileID:(unsigned long long)fileID completion:(void (^)(NSString *downloadUrl, NSError *error))completion;
- (NSURLSessionDownloadTask *)resumableDownloadTaskWithURL:(NSString *)urlString toPath:(NSString *)destinationPath completion:(void(^)(BOOL success, NSError *error))completion;
- (BOOL)verifyManifestFromDictionary:(NSDictionary *)manifest;
- (void)setupProfileWithManifest:(NSDictionary *)manifestDict destPath:(NSString *)destPath finalVersionString:(NSString *)finalVersionString;
- (void)installModLoaderFromManifest:(NSDictionary *)manifestDict;
@end

#pragma mark - CurseForgeAPI Implementation

@implementation CurseForgeAPI

#pragma mark - Initialization

- (instancetype)initWithAPIKey:(NSString *)apiKey {
    self = [super initWithURL:@"https://api.curseforge.com/v1"];
    if (self) {
        _apiKey = apiKey ?: @"";
        
        // Initialize session manager with appropriate configuration
        _sessionManager = [AFHTTPSessionManager manager];
        _sessionManager.requestSerializer = [AFJSONRequestSerializer serializer];
        _sessionManager.responseSerializer = [AFJSONResponseSerializer serializer];
        _sessionManager.requestSerializer.timeoutInterval = 20.0; // Set a reasonable timeout
        
        // Initialize response cache
        _responseCache = [[NSCache alloc] init];
        _responseCache.countLimit = 100; // Cache up to 100 responses
        
        // Initialize operation queue with limited concurrency
        _operationQueue = [[NSOperationQueue alloc] init];
        _operationQueue.maxConcurrentOperationCount = 2; // Limit concurrent operations
        
        // Initialize task path map for resumable downloads
        _taskPathMap = [NSMutableDictionary dictionary];
        
        NSLog(@"CurseForgeAPI: Initialized with API key: %@", _apiKey.length > 0 ? @"[redacted]" : @"(none)");
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
    return [NSError errorWithDomain:@"CurseForgeAPIErrorDomain" code:code userInfo:userInfo];
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
    
    // Check cache first
    id cachedResponse = [self getCachedResponseForEndpoint:endpoint params:params];
    if (cachedResponse) {
        NSLog(@"getEndpoint: Cache hit for %@", endpoint);
        if (completion) {
            dispatch_async(dispatch_get_main_queue(), ^{
                completion(cachedResponse, nil);
            });
        }
        return;
    }
    
    NSString *url = [self.baseURL stringByAppendingPathComponent:endpoint];
    NSString *key = self.apiKey;
    
    if (key.length == 0) {
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
    
    [self.sessionManager.requestSerializer setValue:key forHTTPHeaderField:@"x-api-key"];
    NSLog(@"getEndpoint: Requesting %@ with params: %@", url, params);
    
    [self.sessionManager GET:url parameters:params headers:nil progress:nil success:^(NSURLSessionTask *task, id responseObject) {
        NSLog(@"getEndpoint: Success for %@.", endpoint);
        
        // Cache the response
        [self cacheResponse:responseObject forEndpoint:endpoint params:params];
        
        if (completion) {
            dispatch_async(dispatch_get_main_queue(), ^{
                completion(responseObject, nil);
            });
        }
    } failure:^(NSURLSessionTask *operation, NSError *error) {
        self.lastError = error;
        self.lastFetchError = error;
        NSLog(@"getEndpoint: Failed for %@: %@", endpoint, error);
        
        // Determine error type
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

#pragma mark - Search Implementation

- (void)searchModWithFilters:(NSDictionary *)searchFilters previousPageResult:(NSMutableArray *)prevResult completion:(void (^ _Nonnull)(NSMutableArray * _Nullable results, NSError * _Nullable error))completion {
    // Clear previous error
    self.lastFetchError = nil;
    
    NSBlockOperation *operation = [NSBlockOperation blockOperationWithBlock:^{
        int limit = CURSEFORGE_PAGINATION_SIZE;
        NSString *query = searchFilters[@"name"] ?: @"";
        NSMutableDictionary *params = [@{
            @"gameId": @(kCurseForgeGameIDMinecraft),
            @"classId": ([searchFilters[@"isModpack"] boolValue] ? @(kCurseForgeClassIDModpack) : @(kCurseForgeClassIDMod)),
            @"searchFilter": query,
            @"sortField": @(1),
            @"sortOrder": @"desc",
            @"pageSize": @(limit),
            @"index": @(prevResult.count)
        } mutableCopy];
        
        if (searchFilters[@"mcVersion"] && [searchFilters[@"mcVersion"] length] > 0) {
            params[@"gameVersion"] = searchFilters[@"mcVersion"];
        }
        
        NSLog(@"searchModWithFilters: Searching with params: %@", params);
        
        __weak typeof(self) weakSelf = self;
        
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
                NSMutableArray *result = prevResult ?: [NSMutableArray new];
                NSArray *data = response[@"data"];
                if (![data isKindOfClass:[NSArray class]]) {
                    NSLog(@"searchModWithFilters: Invalid data format");
                    dispatch_async(dispatch_get_main_queue(), ^{
                        NSError *formatError = [NSError errorWithDomain:@"CurseForgeAPIErrorDomain" 
                                                                  code:1004 
                                                              userInfo:@{NSLocalizedDescriptionKey: @"Invalid response format"}];
                        completion(nil, formatError);
                    });
                    return;
                }
                
                NSLog(@"searchModWithFilters: Found %lu items", (unsigned long)data.count);
                
                for (NSDictionary *mod in data) {
                    if (![mod isKindOfClass:[NSDictionary class]]) continue;
                    
                    id allow = mod[@"allowModDistribution"];
                    if (allow && ![allow isKindOfClass:[NSNull class]] && ![allow boolValue]) {
                        NSLog(@"searchModWithFilters: Skipping mod %@ due to distribution restriction", mod[@"name"]);
                        continue;
                    }
                    
                    // Safely handle all possible field types
                    NSString *idString = @"0";
                    if (mod[@"id"]) {
                        if ([mod[@"id"] isKindOfClass:[NSString class]]) {
                            idString = mod[@"id"];
                        } else {
                            idString = [NSString stringWithFormat:@"%@", mod[@"id"]];
                        }
                    }
                    
                    NSString *title = @"";
                    if (mod[@"name"]) {
                        if ([mod[@"name"] isKindOfClass:[NSString class]]) {
                            title = mod[@"name"];
                        } else {
                            title = [NSString stringWithFormat:@"%@", mod[@"name"]];
                        }
                    }
                    
                    NSString *description = @"";
                    if (mod[@"summary"]) {
                        if ([mod[@"summary"] isKindOfClass:[NSString class]]) {
                            description = mod[@"summary"];
                        } else {
                            description = [NSString stringWithFormat:@"%@", mod[@"summary"]];
                        }
                    }
                    
                    NSString *imageUrl = @"";
                    if (mod[@"logo"]) {
                        if ([mod[@"logo"] isKindOfClass:[NSDictionary class]]) {
                            NSDictionary *logoDict = mod[@"logo"];
                            imageUrl = logoDict[@"thumbnailUrl"] ?: @"";
                        } else if ([mod[@"logo"] isKindOfClass:[NSString class]]) {
                            imageUrl = mod[@"logo"];
                        } else {
                            imageUrl = [NSString stringWithFormat:@"%@", mod[@"logo"]];
                        }
                    }
                    
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
                    NSError *exceptionError = [NSError errorWithDomain:@"CurseForgeAPIErrorDomain" 
                                                                  code:1004 
                                                              userInfo:@{NSLocalizedDescriptionKey: [NSString stringWithFormat:@"Exception: %@", exception.reason]}];
                    completion(nil, exceptionError);
                });
            }
        }];
    }];
    
    [self.operationQueue addOperation:operation];
}

#pragma mark - Load Details of Mod

- (void)loadDetailsOfMod:(NSMutableDictionary *)item completion:(void (^ _Nonnull)(NSError * _Nullable error))completion {
    // Clear previous error
    self.lastFetchError = nil;
    
    NSBlockOperation *operation = [NSBlockOperation blockOperationWithBlock:^{
        NSString *modId = [NSString stringWithFormat:@"%@", item[@"id"]];
        NSLog(@"loadDetailsOfMod: Loading details for mod ID %@", modId);
        
        [self getEndpoint:[NSString stringWithFormat:@"mods/%@/files", modId] params:nil completion:^(id response, NSError *error) {
            if (!response) {
                NSLog(@"loadDetailsOfMod: Failed to load details for %@: %@", modId, error);
                if (completion) {
                    completion(error);
                }
                return;
            }
            
            NSArray *files = response[@"data"];
            NSMutableArray *names = [NSMutableArray new];
            NSMutableArray *mcNames = [NSMutableArray new];
            NSMutableArray *urls = [NSMutableArray new];
            NSMutableArray *hashes = [NSMutableArray new];
            NSMutableArray *sizes = [NSMutableArray new];
            NSMutableArray *loaders = [NSMutableArray new];
            
            // Sort files by date (newest first) if possible
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
                
                // Fallback to filename comparison if dates not available
                return [file2[@"fileName"] compare:file1[@"fileName"]];
            }];
            
            for (NSDictionary *file in sortedFiles) {
                // Skip files that are marked as not available
                if (![file[@"isAvailable"] boolValue]) {
                    continue;
                }
                
                // Add file name
                [names addObject:[NSString stringWithFormat:@"%@", file[@"fileName"] ?: @""]];
                
                // Extract game versions - CurseForge uses "gameVersions" key
                NSArray *gameVersions = file[@"gameVersions"];
                NSMutableArray *versionsArray = [NSMutableArray new];
                NSMutableArray *loaderArray = [NSMutableArray new];
                
                if ([gameVersions isKindOfClass:[NSArray class]]) {
                    for (id version in gameVersions) {
                        if ([version isKindOfClass:[NSString class]]) {
                            NSString *versionStr = (NSString *)version;
                            
                            // Extract proper Minecraft version vs loader information
                            if ([versionStr hasPrefix:@"1."] || [versionStr hasPrefix:@"2."]) {
                                // This is likely a Minecraft version
                                [versionsArray addObject:versionStr];
                            } else if ([versionStr caseInsensitiveCompare:@"Forge"] == NSOrderedSame ||
                                      [versionStr caseInsensitiveCompare:@"Fabric"] == NSOrderedSame || 
                                      [versionStr caseInsensitiveCompare:@"Quilt"] == NSOrderedSame ||
                                      [versionStr caseInsensitiveCompare:@"NeoForge"] == NSOrderedSame) {
                                // This is a mod loader
                                [loaderArray addObject:versionStr];
                            }
                        }
                    }
                }
                
                [mcNames addObject:versionsArray];
                
                // Extract download URL
                NSString *downloadUrl = [NSString stringWithFormat:@"%@", file[@"downloadUrl"] ?: @""];
                
                // If no direct download URL, we'll need to use the getDownloadUrl method later
                BOOL needsDownloadUrl = (downloadUrl.length == 0 || [downloadUrl isEqualToString:@"(null)"]);
                
                if (needsDownloadUrl) {
                    // Store placeholder that will be replaced when user selects the version
                    [urls addObject:[NSString stringWithFormat:@"placeholder:%@:%@", 
                                    file[@"modId"] ?: modId, 
                                    file[@"id"] ?: @"0"]];
                } else {
                    [urls addObject:downloadUrl];
                }
                
                // Extract file size
                NSNumber *sizeNumber = nil;
                id fileLength = file[@"fileLength"];
                if ([fileLength isKindOfClass:[NSNumber class]]) {
                    sizeNumber = fileLength;
                } else if ([fileLength isKindOfClass:[NSString class]]) {
                    sizeNumber = @([fileLength unsignedLongLongValue]);
                } else {
                    sizeNumber = @(0);
                }
                [sizes addObject:sizeNumber];
                
                // Extract hashes
                NSString *sha1 = @"";
                NSArray *hashesArray = file[@"hashes"];
                if ([hashesArray isKindOfClass:[NSArray class]]) {
                    for (NSDictionary *hashDict in hashesArray) {
                        if ([[NSString stringWithFormat:@"%@", hashDict[@"algo"]] isEqualToString:@"SHA1"]) {
                            sha1 = [NSString stringWithFormat:@"%@", hashDict[@"value"]];
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
                                // Fabric API: 306612
                                // Forge: 250763
                                // Quilt: 634179
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
                
                // If still no loaders and filename contains loader hint
                if (loaderArray.count == 0) {
                    NSString *fileName = [NSString stringWithFormat:@"%@", file[@"fileName"] ?: @""];
                    NSString *lowerFileName = [fileName lowercaseString];
                    
                    if ([lowerFileName containsString:@"fabric"] && ![loaderArray containsObject:@"Fabric"]) {
                        [loaderArray addObject:@"Fabric"];
                    }
                    if ([lowerFileName containsString:@"forge"] && ![loaderArray containsObject:@"Forge"]) {
                        [loaderArray addObject:@"Forge"];
                    }
                    if ([lowerFileName containsString:@"quilt"] && ![loaderArray containsObject:@"Quilt"]) {
                        [loaderArray addObject:@"Quilt"];
                    }
                    if ([lowerFileName containsString:@"neoforge"] && ![loaderArray containsObject:@"NeoForge"]) {
                        [loaderArray addObject:@"NeoForge"];
                    }
                }
                
                // Add loader info to the list
                [loaders addObject:loaderArray];
            }
            
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

- (void)getDownloadUrlForProject:(unsigned long long)projectID fileID:(unsigned long long)fileID completion:(void (^)(NSString *, NSError *))completion {
    NSString *endpoint = [NSString stringWithFormat:@"mods/%llu/files/%llu/download-url", projectID, fileID];
    
    [self getEndpoint:endpoint params:nil completion:^(id response, NSError *error) {
        if (response && response[@"data"] && ![response[@"data"] isKindOfClass:[NSNull class]]) {
            NSString *urlString = [NSString stringWithFormat:@"%@", response[@"data"]];
            NSLog(@"getDownloadUrlForProject: Got URL for project %llu, file %llu: %@", projectID, fileID, urlString);
            if (completion) completion(urlString, nil);
        } else {
            NSString *fallbackUrl = [NSString stringWithFormat:@"https://www.curseforge.com/api/v1/mods/%llu/files/%llu/download", projectID, fileID];
            if (self.apiKey.length > 0) {
                fallbackUrl = [fallbackUrl stringByAppendingFormat:@"?apiKey=%@", self.apiKey];
            }
            
            NSLog(@"getDownloadUrlForProject: Using fallback URL for project %llu, file %llu", projectID, fileID);
            if (completion) completion(fallbackUrl, error);
        }
    }];
}

#pragma mark - Resumable Downloads

- (NSURLSessionDownloadTask *)resumableDownloadTaskWithURL:(NSString *)urlString toPath:(NSString *)destinationPath completion:(void(^)(BOOL success, NSError *error))completion {
    NSURL *url = [NSURL URLWithString:urlString];
    NSURLRequest *request = [NSURLRequest requestWithURL:url];
    
    __weak typeof(self) weakSelf = self;
    NSURLSessionDownloadTask *task = [self.sessionManager downloadTaskWithRequest:request progress:nil destination:^NSURL *(NSURL *targetPath, NSURLResponse *response) {
        return [NSURL fileURLWithPath:destinationPath];
    } completionHandler:^(NSURLResponse *response, NSURL *filePath, NSError *error) {
        // Remove from task map
        [weakSelf.taskPathMap removeObjectForKey:@(task.taskIdentifier)];
        
        if (completion) {
            completion(error == nil, error);
        }
    }];
    
    // Save destination path
    [self.taskPathMap setObject:destinationPath forKey:@(task.taskIdentifier)];
    
    return task;
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

#pragma mark - Simplified mod installation - Just creates JSON files

- (void)installModFromDetail:(NSDictionary *)modDetail atIndex:(NSUInteger)selectedVersion {
    // Resolve the download URL if needed
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
                    NSDictionary *userInfo = @{@"detail": modDetail, @"index": @(selectedVersion)};
                    [[NSNotificationCenter defaultCenter] postNotificationName:@"InstallMod" object:self userInfo:userInfo];
                } else {
                    NSLog(@"[CurseForge] Failed to get download URL for mod: %@", error);
                    [UIAlertUtilities presentAlertWithTitle:@"Download Error" 
                                               message:[NSString stringWithFormat:@"Could not retrieve download URL: %@", error.localizedDescription]
                                       viewController:nil];
                }
            }];
        }
    } else {
        // URL already resolved
        NSDictionary *userInfo = @{@"detail": modDetail, @"index": @(selectedVersion)};
        [[NSNotificationCenter defaultCenter] postNotificationName:@"InstallMod" object:self userInfo:userInfo];
    }
}

#pragma mark - Modpack Installation with Progress Tracking

- (void)installModpackFromDetail:(NSDictionary *)modDetail atIndex:(NSUInteger)selectedVersion completion:(void (^ _Nonnull)(NSError * _Nullable error))completion {
    NSLog(@"[CurseForge-Modpack] Starting installation for modpack %@ (version index: %lu)", modDetail[@"title"], (unsigned long)selectedVersion);
    
    // Get the download URL
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
    
    // Create a download task that will be visible in the download progress view
    MinecraftResourceDownloadTask *downloadTask = [[MinecraftResourceDownloadTask alloc] init];
    
    // Initialize progress tracking data - alternative to prepareForDownload
    downloadTask.textProgress = [NSProgress new];
    downloadTask.textProgress.kind = NSProgressKindFile;
    downloadTask.textProgress.fileOperationKind = NSProgressFileOperationKindDownloading;
    downloadTask.textProgress.totalUnitCount = -1;

    downloadTask.progress = [NSProgress new];
    // Push 1 byte so it won't accidentally finish after downloading assets index
    downloadTask.progress.totalUnitCount = 1;
    downloadTask.fileList = [NSMutableArray new];
    downloadTask.progressList = [NSMutableArray new];
    
    // Check if we need to resolve a placeholder URL
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
    
    // Use the same directory structure as Modrinth
    NSString *gameDir = [NSString stringWithFormat:@"./custom_gamedir/%@", safeProfileName];
    
    // Create actual destination directory path
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
    
    // Add to file list for progress tracking
    [downloadTask.fileList addObject:[NSString stringWithFormat:@"Downloading %@", modDetail[@"title"]]];
    
    // Create progress for this file
    NSProgress *fileProgress = [NSProgress progressWithTotalUnitCount:1]; 
    fileProgress.kind = NSProgressKindFile;
    [downloadTask.progressList addObject:fileProgress];
    [downloadTask.progress addChild:fileProgress withPendingUnitCount:1];
    
    __weak typeof(self) weakSelf = self;
    NSURLSessionDownloadTask *task = [[NSURLSession sharedSession] downloadTaskWithRequest:[NSURLRequest requestWithURL:[NSURL URLWithString:downloadUrl]] completionHandler:^(NSURL *location, NSURLResponse *response, NSError *error) {
        if (error) {
            fileProgress.completedUnitCount = 0;
            NSLog(@"[CurseForge-Modpack] Failed to download modpack: %@", error);
            if (completion) {
                completion(error);
            }
            return;
        }
        
        // Update progress
        fileProgress.totalUnitCount = response.expectedContentLength > 0 ? response.expectedContentLength : 1;
        fileProgress.completedUnitCount = response.expectedContentLength > 0 ? response.expectedContentLength : 1;
        
        // Move download to destination
        NSError *moveError = nil;
        [[NSFileManager defaultManager] moveItemAtURL:location toURL:[NSURL fileURLWithPath:zipPath] error:&moveError];
        if (moveError) {
            NSLog(@"[CurseForge-Modpack] Failed to move downloaded file: %@", moveError);
            if (completion) {
                completion(moveError);
            }
            return;
        }
        
        NSLog(@"[CurseForge-Modpack] Downloaded modpack, extracting...");
        
        // Update file list for extraction
        dispatch_async(dispatch_get_main_queue(), ^{
            [downloadTask.fileList addObject:@"Extracting modpack"];
            
            // Create progress for extraction
            NSProgress *extractProgress = [NSProgress progressWithTotalUnitCount:1];
            extractProgress.kind = NSProgressKindFile;
            [downloadTask.progressList addObject:extractProgress];
            [downloadTask.progress addChild:extractProgress withPendingUnitCount:1];
        });
        
        dispatch_async(dispatch_get_global_queue(DISPATCH_QUEUE_PRIORITY_DEFAULT, 0), ^{
            __strong typeof(weakSelf) strongSelf = weakSelf;
            
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
            
            // Extract the manifest
            NSData *manifestData = [archive extractDataFromFile:@"manifest.json" error:&extractError];
            if (!manifestData) {
                NSLog(@"[CurseForge-Modpack] Failed to extract manifest.json: %@", extractError);
                if (completion) {
                    NSError *customError = [strongSelf errorWithCode:CurseForgeErrorCodeExtraction
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
                    NSError *customError = [strongSelf errorWithCode:CurseForgeErrorCodeParsingError
                                                           message:@"Failed to parse manifest.json"
                                                   underlyingError:extractError];
                    completion(customError);
                }
                return;
            }
            
            // Verify the manifest
            if (![strongSelf verifyManifestFromDictionary:manifestDict]) {
                NSLog(@"[CurseForge-Modpack] Invalid manifest");
                if (completion) {
                    NSError *customError = [strongSelf errorWithCode:CurseForgeErrorCodeInvalidManifest
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
                } else if ([loaderName isEqualToString:@"fabric"]) {
                    modLoaderId = @"fabric";
                    modLoaderVersion = loaderVer;
                    finalVersionString = [NSString stringWithFormat:@"fabric-loader-%@-%@", modLoaderVersion, vanillaVersion];
                } else if ([loaderName isEqualToString:@"quilt"]) {
                    modLoaderId = @"quilt";
                    modLoaderVersion = loaderVer;
                    finalVersionString = [NSString stringWithFormat:@"quilt-loader-%@-%@", modLoaderVersion, vanillaVersion];
                } else if ([loaderName isEqualToString:@"neoforge"]) {
                    modLoaderId = @"neoforge";
                    modLoaderVersion = loaderVer;
                    finalVersionString = [NSString stringWithFormat:@"%@-neoforge-%@", vanillaVersion, modLoaderVersion];
                }
            }
            
            // Setup profile with the same approach as Modrinth
            NSString *profileName = manifestDict[@"name"] ?: @"Unknown Modpack";
            
            // Create profile with basic icon
            NSDictionary *profileInfo = @{
                @"gameDir": gameDir,
                @"name": profileName,
                @"lastVersionId": finalVersionString,
                @"icon": manifestDict[@"overrides"] ? @"" : @"data:image/png;base64,iVBORw0KGgoAAAANSUhEUgAAAEAAAABACAMAAACdt4HsAAAABGdBTUEAALGPC/xhBQAAAAFzUkdCAK7OHOkAAAA8UExURUxpcejp6erp6erp6ejo6Onp6enp6enp6enp6enp6enp6enp6enp6enp6enp6enp6enp6enp6enp6enp6VvMQMcAAAATdFJOUwBAv4BATz8Q798Qr1+vn3+fYL+Qu+0AAAE+SURBVFjD7ZZLkoQgDEApFHzPqPe/7MQZp3WwSQrX7mXDg5BAvkaj0fgfuMRJ8gw5SadHwPMLQXbBExA0Mp8A/d0ToCXIQD6fkLItoAb/wB8CjVJEPQbhTxUwEzZZAnTERUBERPR2ERDfERIBoEzQb2IQZudP8gS+DgAiIpoPAO1APkbsV2CAqAK+FlBflQHUAV5WgFfiVYCfWp4iMCcVcAtQS9RlQFQ8A/FVAFqCXASUE78L4OUBVEsQfwfAM1Hwc0BRAWoB6KQZcEoB2LEFXAuITgFYeQwkNQHnJSCrCYiaALWAtSbAbwKeRTbgPwCLZsARlYBZM2AsEsBmzYDnJ8CnzYBPAFQnuKzAbF23DQj9ZY0a3z3A7LZnvjuuJnN7b7r3Xn3G/H5dDwfIb/j1Jb57o9FoXHEDgWAupBBbCjcAAAAASUVORK5CYII="
            };
            
            // Ensure the profile directory exists
            [PLProfiles ensureProfileDirectoryExists:safeProfileName gameDir:gameDir];
            
            // Save the profile
            dispatch_async(dispatch_get_main_queue(), ^{
                NSLog(@"[CurseForge-Modpack] Setting profile: %@", profileName);
                PLProfiles.current.profiles[safeProfileName] = [profileInfo mutableCopy];
                PLProfiles.current.selectedProfileName = safeProfileName;
                [PLProfiles.current save];
            });
            
            // Create the simplified JSON file for the mod loader
            if ([modLoaderId isEqualToString:@"forge"]) {
                [strongSelf createForgeJSONWithVersion:vanillaVersion loaderVersion:modLoaderVersion];
            } else if ([modLoaderId isEqualToString:@"fabric"]) {
                [strongSelf createFabricJSONWithVersion:finalVersionString];
            } else if ([modLoaderId isEqualToString:@"neoforge"]) {
                [strongSelf createNeoForgeJSONWithVersion:vanillaVersion loaderVersion:modLoaderVersion];
            }
            
            // Extract overrides
            NSLog(@"[CurseForge-Modpack] Extracting overrides");
            NSString *overridesDir = manifestDict[@"overrides"];
            if (overridesDir) {
                NSError *overridesError = nil;
                [ModpackUtils archive:archive extractDirectory:overridesDir toPath:destPath error:&overridesError];
                if (overridesError) {
                    NSLog(@"[CurseForge-Modpack] Failed to extract overrides: %@", overridesError);
                }
            }
            
            // Download mod files
            NSLog(@"[CurseForge-Modpack] Downloading mod files");
            NSArray *files = manifestDict[@"files"];
            __block NSInteger totalFiles = files.count;
            __block NSInteger completedFiles = 0;
            __block NSInteger failedFiles = 0;
            
            dispatch_group_t group = dispatch_group_create();
            dispatch_semaphore_t semaphore = dispatch_semaphore_create(5); // Limit concurrent downloads
            
            for (NSDictionary *file in files) {
                dispatch_group_enter(group);
                dispatch_semaphore_wait(semaphore, DISPATCH_TIME_FOREVER);
                
                NSNumber *projectID = file[@"projectID"];
                NSNumber *fileID = file[@"fileID"];
                BOOL required = [file[@"required"] boolValue];
                
                // Update progress
                dispatch_async(dispatch_get_main_queue(), ^{
                    [downloadTask.fileList addObject:[NSString stringWithFormat:@"Mod: %@_%@", projectID, fileID]];
                    
                    // Create progress for this mod file
                    NSProgress *modProgress = [NSProgress progressWithTotalUnitCount:1];
                    modProgress.kind = NSProgressKindFile;
                    [downloadTask.progressList addObject:modProgress];
                    [downloadTask.progress addChild:modProgress withPendingUnitCount:1];
                });
                
                [strongSelf getDownloadUrlForProject:[projectID unsignedLongLongValue] fileID:[fileID unsignedLongLongValue] completion:^(NSString *url, NSError *error) {
                    if (!url) {
                        NSLog(@"[CurseForge-Modpack] Failed to get download URL for project %@, file %@: %@", projectID, fileID, error);
                        failedFiles++;
                        dispatch_semaphore_signal(semaphore);
                        dispatch_group_leave(group);
                        
                        // Only fail if the file is required
                        if (required) {
                            NSLog(@"[CurseForge-Modpack] Required mod download failed");
                        }
                        return;
                    }
                    
                    // Get file name from URL
                    NSString *fileName = [NSURL URLWithString:url].lastPathComponent;
                    if (!fileName || fileName.length == 0) {
                        fileName = [NSString stringWithFormat:@"mod_%@_%@.jar", projectID, fileID];
                    }
                    
                    // Download directly to final mods directory
                    NSString *modPath = [modsDir stringByAppendingPathComponent:fileName];
                    
                    NSURL *modURL = [NSURL URLWithString:url];
                    NSURLSessionDownloadTask *modTask = [[NSURLSession sharedSession] downloadTaskWithURL:modURL completionHandler:^(NSURL *location, NSURLResponse *response, NSError *downloadError) {
                        NSProgress *modProgress = downloadTask.progressList.lastObject;
                        
                        if (downloadError) {
                            NSLog(@"[CurseForge-Modpack] Failed to download mod %@: %@", fileName, downloadError);
                            failedFiles++;
                            
                            // Only fail if the file is required
                            if (required) {
                                NSLog(@"[CurseForge-Modpack] Required mod download failed");
                            }
                        } else {
                            // Move downloaded file to destination
                            NSError *moveError = nil;
                            if ([[NSFileManager defaultManager] fileExistsAtPath:modPath]) {
                                [[NSFileManager defaultManager] removeItemAtPath:modPath error:nil];
                            }
                            
                            [[NSFileManager defaultManager] moveItemAtURL:location toURL:[NSURL fileURLWithPath:modPath] error:&moveError];
                            
                            if (moveError) {
                                NSLog(@"[CurseForge-Modpack] Failed to save mod %@: %@", fileName, moveError);
                                failedFiles++;
                            } else {
                                NSLog(@"[CurseForge-Modpack] Downloaded mod %@ to %@ (%ld/%ld)", 
                                     fileName, modPath, (long)completedFiles+1, (long)totalFiles);
                                
                                // Update progress
                                modProgress.totalUnitCount = 1;
                                modProgress.completedUnitCount = 1;
                            }
                        }
                        
                        completedFiles++;
                        dispatch_semaphore_signal(semaphore);
                        dispatch_group_leave(group);
                    }];
                    
                    [modTask resume];
                }];
            }
            
            // Wait for all downloads to complete
            dispatch_group_notify(group, dispatch_get_global_queue(DISPATCH_QUEUE_PRIORITY_DEFAULT, 0), ^{
                NSLog(@"[CurseForge-Modpack] All downloads completed (%ld/%ld, %ld failed)", 
                      (long)completedFiles, (long)totalFiles, (long)failedFiles);
                
                // Create a log file in the destination directory to help with troubleshooting
                NSString *logContent = [NSString stringWithFormat:@"CurseForge modpack installation completed\n"
                                       "Profile: %@\n"
                                       "Directory: %@\n"
                                       "Total files: %ld\n"
                                       "Completed: %ld\n"
                                       "Failed: %ld\n"
                                       "Date: %@",
                                       profileName, destPath, (long)totalFiles, 
                                       (long)completedFiles, (long)failedFiles,
                                       [NSDate date]];
                
                [logContent writeToFile:[destPath stringByAppendingPathComponent:@"curseforge_install.log"]
                             atomically:YES
                               encoding:NSUTF8StringEncoding
                                  error:nil];
                
                // Clean up ZIP file
                [[NSFileManager defaultManager] removeItemAtPath:zipPath error:nil];
                
                // Complete the installation
                if (completion) {
                    completion(nil);
                }
            });
        });
    }];
    
    [task resume];
}

// Helper method to copy directories recursively
- (void)copyDirectory:(NSString *)sourceDir toDirectory:(NSString *)destDir {
    NSFileManager *fileManager = [NSFileManager defaultManager];
    
    // Create destination directory if it doesn't exist
    if (![fileManager fileExistsAtPath:destDir]) {
        [fileManager createDirectoryAtPath:destDir withIntermediateDirectories:YES attributes:nil error:nil];
    }
    
    NSError *error = nil;
    NSArray *contents = [fileManager contentsOfDirectoryAtPath:sourceDir error:&error];
    
    if (error) {
        NSLog(@"[CurseForge-Modpack] Error getting contents of directory %@: %@", sourceDir, error);
        return;
    }
    
    for (NSString *item in contents) {
        NSString *sourcePath = [sourceDir stringByAppendingPathComponent:item];
        NSString *destPath = [destDir stringByAppendingPathComponent:item];
        
        BOOL isDir = NO;
        if ([fileManager fileExistsAtPath:sourcePath isDirectory:&isDir]) {
            if (isDir) {
                // Recursively copy subdirectories
                [self copyDirectory:sourcePath toDirectory:destPath];
            } else {
                // Copy file
                if ([fileManager fileExistsAtPath:destPath]) {
                    [fileManager removeItemAtPath:destPath error:nil];
                }
                
                [fileManager copyItemAtPath:sourcePath toPath:destPath error:&error];
                if (error) {
                    NSLog(@"[CurseForge-Modpack] Error copying %@ to %@: %@", sourcePath, destPath, error);
                }
            }
        }
    }
}

#pragma mark - Modloader Installation

- (void)autoInstallForge:(NSString *)vanillaVer loaderVersion:(NSString *)forgeVer {
    if (!vanillaVer.length || !forgeVer.length) {
        NSLog(@"[CurseForge-Forge] Missing version information (vanilla: %@, forge: %@)", vanillaVer, forgeVer);
        return;
    }
    
    NSString *finalId = [NSString stringWithFormat:@"%@-forge-%@", vanillaVer, forgeVer];
    NSString *jsonPath = [NSString stringWithFormat:@"%@/versions/%@/%@.json", 
                         [NSString stringWithUTF8String:getenv("POJAV_GAME_DIR")], finalId, finalId];
    
    [[NSFileManager defaultManager] createDirectoryAtPath:jsonPath.stringByDeletingLastPathComponent 
                             withIntermediateDirectories:YES 
                                              attributes:nil 
                                                   error:nil];
    
    // Create basic JSON file for Forge
    NSDictionary *forgeDict = @{
        @"id": finalId,
        @"type": @"custom",
        @"minecraft": vanillaVer,
        @"loader": @"forge",
        @"loaderVersion": forgeVer
    };
    
    NSError *writeErr = saveJSONToFile(forgeDict, jsonPath);
    if (writeErr) {
        NSLog(@"[CurseForge-Forge] Failed to write Forge JSON: %@", writeErr);
    } else {
        NSLog(@"[CurseForge-Forge] Successfully created Forge JSON at %@", jsonPath);
    }
}

- (void)setupProfileWithManifest:(NSDictionary *)manifestDict destPath:(NSString *)destPath finalVersionString:(NSString *)finalVersionString {
    // Create a profile for this modpack
    NSString *profileName = manifestDict[@"name"] ?: @"Unknown Modpack";
    if (profileName.length > 0) {
        // Create a unique gameDir for this modpack
        NSString *safeProfileName = [profileName stringByReplacingOccurrencesOfString:@"/" withString:@"_"];
        safeProfileName = [safeProfileName stringByReplacingOccurrencesOfString:@"\\" withString:@"_"];
        safeProfileName = [safeProfileName stringByReplacingOccurrencesOfString:@":" withString:@"_"];
        
        NSString *gameDir = [NSString stringWithFormat:@"./profiles/%@", safeProfileName];
        
        // Create profile with basic icon
        NSDictionary *profileInfo = @{
            @"gameDir": gameDir,
            @"name": profileName,
            @"lastVersionId": finalVersionString,
            @"icon": manifestDict[@"overrides"] ? @"" : @"data:image/png;base64,iVBORw0KGgoAAAANSUhEUgAAAEAAAABACAMAAACdt4HsAAAABGdBTUEAALGPC/xhBQAAAAFzUkdCAK7OHOkAAAA8UExURUxpcejp6erp6erp6ejo6Onp6enp6enp6enp6enp6enp6enp6enp6enp6enp6enp6enp6enp6enp6enp6VvMQMcAAAATdFJOUwBAv4BATz8Q798Qr1+vn3+fYL+Qu+0AAAE+SURBVFjD7ZZLkoQgDEApFHzPqPe/7MQZp3WwSQrX7mXDg5BAvkaj0fgfuMRJ8gw5SadHwPMLQXbBExA0Mp8A/d0ToCXIQD6fkLItoAb/wB8CjVJEPQbhTxUwEzZZAnTERUBERPR2ERDfERIBoEzQb2IQZudP8gS+DgAiIpoPAO1APkbsV2CAqAK+FlBflQHUAV5WgFfiVYCfWp4iMCcVcAtQS9RlQFQ8A/FVAFqCXASUE78L4OUBVEsQfwfAM1Hwc0BRAWoB6KQZcEoB2LEFXAuITgFYeQwkNQHnJSCrCYiaALWAtSbAbwKeRTbgPwCLZsARlYBZM2AsEsBmzYDnJ8CnzYBPAFQnuKzAbF23DQj9ZY0a3z3A7LZnvjuuJnN7b7r3Xn3G/H5dDwfIb/j1Jb57o9FoXHEDgWAupBBbCjcAAAAASUVORK5CYII="
        };
        
        // Ensure the profile directory exists
        [PLProfiles ensureProfileDirectoryExists:safeProfileName gameDir:gameDir];
        
        // Save the profile
        dispatch_async(dispatch_get_main_queue(), ^{
            NSLog(@"[CurseForge-Modpack] Setting profile: %@", profileName);
            PLProfiles.current.profiles[safeProfileName] = [profileInfo mutableCopy];
            PLProfiles.current.selectedProfileName = safeProfileName;
            [PLProfiles.current save];
        });
    }
}

- (void)installModLoaderFromManifest:(NSDictionary *)manifestDict {
    // Extract Minecraft version and mod loader info from manifest
    NSDictionary *minecraft = manifestDict[@"minecraft"];
    if (!minecraft) return;
    
    NSString *vanillaVersion = minecraft[@"version"] ?: @"";
    NSString *modLoaderId = @"";
    NSString *modLoaderVersion = @"";
    
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
            [self createForgeJSONWithVersion:vanillaVersion loaderVersion:modLoaderVersion];
        } else if ([loaderName isEqualToString:@"fabric"]) {
            modLoaderId = @"fabric";
            modLoaderVersion = loaderVer;
            [self createFabricJSONWithVersion:[NSString stringWithFormat:@"fabric-loader-%@-%@", modLoaderVersion, vanillaVersion]];
        } else if ([loaderName isEqualToString:@"quilt"]) {
            modLoaderId = @"quilt";
            modLoaderVersion = loaderVer;
            [self createFabricJSONWithVersion:[NSString stringWithFormat:@"quilt-loader-%@-%@", modLoaderVersion, vanillaVersion]];
        } else if ([loaderName isEqualToString:@"neoforge"]) {
            modLoaderId = @"neoforge";
            modLoaderVersion = loaderVer;
            [self createNeoForgeJSONWithVersion:vanillaVersion loaderVersion:modLoaderVersion];
        }
    }
}

#pragma mark - Simple JSON File Creation

- (void)createForgeJSONWithVersion:(NSString *)vanillaVer loaderVersion:(NSString *)forgeVer {
    if (!vanillaVer.length || !forgeVer.length) {
        NSLog(@"[CurseForge-Forge] Missing version information (vanilla: %@, forge: %@)", vanillaVer, forgeVer);
        return;
    }
    
    NSString *finalId = [NSString stringWithFormat:@"%@-forge-%@", vanillaVer, forgeVer];
    NSString *jsonPath = [NSString stringWithFormat:@"%@/versions/%@/%@.json", 
                         [NSString stringWithUTF8String:getenv("POJAV_GAME_DIR")], finalId, finalId];
    
    [[NSFileManager defaultManager] createDirectoryAtPath:jsonPath.stringByDeletingLastPathComponent 
                             withIntermediateDirectories:YES 
                                              attributes:nil 
                                                   error:nil];
    
    NSDictionary *forgeDict = @{
        @"id": finalId,
        @"type": @"custom",
        @"minecraft": vanillaVer,
        @"loader": @"forge",
        @"loaderVersion": forgeVer
    };
    
    NSError *writeErr = saveJSONToFile(forgeDict, jsonPath);
    if (writeErr) {
        NSLog(@"[CurseForge-Forge] Failed to write Forge JSON: %@", writeErr);
    } else {
        NSLog(@"[CurseForge-Forge] Successfully created Forge JSON at %@", jsonPath);
    }
}

- (void)createFabricJSONWithVersion:(NSString *)fabricString {
    if (!fabricString.length) {
        NSLog(@"[CurseForge-Fabric] Missing fabric version string");
        return;
    }
    
    NSString *jsonPath = [NSString stringWithFormat:@"%@/versions/%@/%@.json", 
                         [NSString stringWithUTF8String:getenv("POJAV_GAME_DIR")], fabricString, fabricString];
    
    [[NSFileManager defaultManager] createDirectoryAtPath:jsonPath.stringByDeletingLastPathComponent 
                             withIntermediateDirectories:YES 
                                              attributes:nil 
                                                   error:nil];
    
    // Extract Minecraft version from the fabricString if possible
    NSArray *components = [fabricString componentsSeparatedByString:@"-"];
    NSString *mcVersion = @"";
    
    if ([fabricString hasPrefix:@"fabric-loader"] && components.count >= 3) {
        // Format: fabric-loader-0.14.22-1.20.1
        mcVersion = components.lastObject;
    }
    
    NSDictionary *fabricDict = @{
        @"id": fabricString,
        @"type": @"custom",
        @"loader": @"fabric",
        @"loaderVersion": fabricString,
        @"minecraft": mcVersion.length > 0 ? mcVersion : @""
    };
    
    NSError *writeErr = saveJSONToFile(fabricDict, jsonPath);
    if (writeErr) {
        NSLog(@"[CurseForge-Fabric] Failed to write Fabric JSON: %@", writeErr);
    } else {
        NSLog(@"[CurseForge-Fabric] Successfully created Fabric JSON at %@", jsonPath);
    }
}

- (void)createNeoForgeJSONWithVersion:(NSString *)vanillaVer loaderVersion:(NSString *)neoforgeVer {
    if (!vanillaVer.length || !neoforgeVer.length) {
        NSLog(@"[CurseForge-NeoForge] Missing version information (vanilla: %@, neoforge: %@)", vanillaVer, neoforgeVer);
        return;
    }
    
    NSString *finalId = [NSString stringWithFormat:@"%@-neoforge-%@", vanillaVer, neoforgeVer];
    NSString *jsonPath = [NSString stringWithFormat:@"%@/versions/%@/%@.json", 
                         [NSString stringWithUTF8String:getenv("POJAV_GAME_DIR")], finalId, finalId];
    
    [[NSFileManager defaultManager] createDirectoryAtPath:jsonPath.stringByDeletingLastPathComponent 
                             withIntermediateDirectories:YES 
                                              attributes:nil 
                                                   error:nil];
    
    NSDictionary *neoforgeDict = @{
        @"id": finalId,
        @"type": @"custom",
        @"minecraft": vanillaVer,
        @"loader": @"neoforge",
        @"loaderVersion": neoforgeVer
    };
    
    NSError *writeErr = saveJSONToFile(neoforgeDict, jsonPath);
    if (writeErr) {
        NSLog(@"[CurseForge-NeoForge] Failed to write NeoForge JSON: %@", writeErr);
    } else {
        NSLog(@"[CurseForge-NeoForge] Successfully created NeoForge JSON at %@", jsonPath);
    }
}

@end

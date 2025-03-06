#import "CurseForgeAPI.h"
#import "MinecraftResourceDownloadTask.h"
#import "PLProfiles.h"
#import "ModpackUtils.h"
#import "UnzipKit.h"
#import "AFNetworking.h"
#import "UIAlertUtilities.h"
#import "config.h"
#import "utils.h"

#pragma mark - Constants

// CurseForge API Constants
#define kCurseForgeGameIDMinecraft 432
#define kCurseForgeClassIDModpack 4471
#define kCurseForgeClassIDMod 6
#define CURSEFORGE_PAGINATION_SIZE 50

@interface CurseForgeAPI ()
@property (nonatomic, copy) NSString *apiKey;
@property (nonatomic, strong) AFHTTPSessionManager *sessionManager;
@property (nonatomic, strong) NSCache *responseCache;
@property (nonatomic, strong) NSOperationQueue *operationQueue;
@property (nonatomic, strong) NSMutableDictionary *taskPathMap;
@property (nonatomic, strong) NSError *lastFetchError;
@end

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

#pragma mark - Network requests

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
    
    [manager.requestSerializer setValue:self.apiKey forHTTPHeaderField:@"x-api-key"];
    
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
        NSLog(@"[CurseForgeAPI] GET request to %@ failed: %@", endpoint, requestError);
    }
    
    return result;
}

- (void)getEndpoint:(NSString *)endpoint params:(NSDictionary *)params completion:(void (^)(id, NSError *))completion {
    if (!endpoint) {
        if (completion) {
            NSError *error = [ModpackUtils errorWithCode:ModpackUtilsErrorCodeInvalidParameters
                                                message:@"Invalid endpoint"
                                        underlyingError:nil];
            completion(nil, error);
        }
        return;
    }
    
    NSString *url = [self.baseURL stringByAppendingPathComponent:endpoint];
    
    if (self.apiKey.length == 0) {
        NSError *error = [ModpackUtils errorWithCode:ModpackUtilsErrorCodeAuthenticationFailed
                                            message:@"No API key provided"
                                    underlyingError:nil];
        if (completion) {
            completion(nil, error);
        }
        return;
    }
    
    [self.sessionManager.requestSerializer setValue:self.apiKey forHTTPHeaderField:@"x-api-key"];
    
    [self.sessionManager GET:url parameters:params headers:nil progress:nil success:^(NSURLSessionTask *task, id responseObject) {
        if (completion) {
            completion(responseObject, nil);
        }
    } failure:^(NSURLSessionTask *operation, NSError *error) {
        self.lastError = error;
        self.lastFetchError = error;
        
        // Determine error type
        NSInteger statusCode = 0;
        if ([operation.response isKindOfClass:[NSHTTPURLResponse class]]) {
            statusCode = [(NSHTTPURLResponse *)operation.response statusCode];
        }
        
        ModpackUtilsErrorCode errorCode;
        NSString *errorMessage;
        
        if (statusCode == 401 || statusCode == 403) {
            errorCode = ModpackUtilsErrorCodeAuthenticationFailed;
            errorMessage = @"Authentication failed. Please check your API key.";
        } else if (statusCode == 404) {
            errorCode = ModpackUtilsErrorCodeInvalidParameters;
            errorMessage = @"The requested resource was not found.";
        } else if (statusCode >= 500) {
            errorCode = ModpackUtilsErrorCodeNetworkError;
            errorMessage = @"A server error occurred. Please try again later.";
        } else {
            errorCode = ModpackUtilsErrorCodeNetworkError;
            errorMessage = @"A network error occurred. Please check your connection.";
        }
        
        NSError *apiError = [ModpackUtils errorWithCode:errorCode
                                              message:errorMessage
                                      underlyingError:error];
        
        if (completion) {
            completion(nil, apiError);
        }
    }];
}

#pragma mark - API Implementation

- (void)searchModWithFilters:(NSDictionary *)searchFilters
           previousPageResult:(NSMutableArray *)prevResult
                   completion:(void (^)(NSMutableArray *, NSError *))completion {
    
    // Clear previous error
    self.lastFetchError = nil;
    
    NSOperationQueue *operationQueue = self.operationQueue ?: [NSOperationQueue mainQueue];
    
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
                if (completion) {
                    completion(nil, error);
                }
                return;
            }
            
            if (!response) {
                NSLog(@"searchModWithFilters: Failed: %@", error);
                if (completion) {
                    completion(nil, strongSelf.lastFetchError ?: error);
                }
                return;
            }
            
            @try {
                NSMutableArray *result = prevResult ?: [NSMutableArray new];
                NSArray *data = response[@"data"];
                if (![data isKindOfClass:[NSArray class]]) {
                    NSError *formatError = [ModpackUtils errorWithCode:ModpackUtilsErrorCodeParsingFailed
                                                              message:@"Invalid response format"
                                                      underlyingError:nil];
                    if (completion) {
                        completion(nil, formatError);
                    }
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
                
                if (completion) {
                    completion(result, nil);
                }
            } @catch (NSException *exception) {
                NSLog(@"searchModWithFilters: Exception: %@", exception);
                NSError *exceptionError = [ModpackUtils errorWithCode:ModpackUtilsErrorCodeParsingFailed
                                                            message:[NSString stringWithFormat:@"Exception: %@", exception.reason]
                                                    underlyingError:nil];
                if (completion) {
                    completion(nil, exceptionError);
                }
            }
        }];
    }];
    
    [operationQueue addOperation:operation];
}

- (void)loadDetailsOfMod:(NSMutableDictionary *)item completion:(void (^)(NSError *))completion {
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
}

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

- (void)installModFromDetail:(NSDictionary *)modDetail atIndex:(NSUInteger)selectedVersion completion:(void (^)(NSError *))completion {
    // Resolve the download URL if needed
    NSArray *versionUrls = modDetail[@"versionUrls"];
    if (!versionUrls || selectedVersion >= versionUrls.count) {
        NSError *error = [ModpackUtils errorWithCode:ModpackUtilsErrorCodeInvalidParameters
                                           message:@"Invalid version index for mod installation"
                                   underlyingError:nil];
        if (completion) {
            completion(error);
        }
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
                    // Create a new dictionary with the resolved URL
                    NSMutableDictionary *resolvedModDetail = [modDetail mutableCopy];
                    NSMutableArray *resolvedUrls = [versionUrls mutableCopy];
                    resolvedUrls[selectedVersion] = downloadUrl;
                    resolvedModDetail[@"versionUrls"] = resolvedUrls;
                    
                    // Trigger the normal installation process
                    [super installModFromDetail:resolvedModDetail atIndex:selectedVersion completion:completion];
                } else {
                    NSLog(@"[CurseForge] Failed to get download URL for mod: %@", error);
                    if (completion) {
                        completion(error);
                    }
                }
            }];
        } else {
            NSError *error = [ModpackUtils errorWithCode:ModpackUtilsErrorCodeInvalidParameters
                                              message:@"Invalid placeholder URL format"
                                      underlyingError:nil];
            if (completion) {
                completion(error);
            }
        }
    } else {
        // URL already resolved, use the base class implementation
        [super installModFromDetail:modDetail atIndex:selectedVersion completion:completion];
    }
}

- (void)installModpackFromDetail:(NSDictionary *)modDetail atIndex:(NSUInteger)selectedVersion completion:(void (^)(NSError *))completion {
    NSLog(@"[CurseForge-Modpack] Starting installation for modpack %@ (version index: %lu)", modDetail[@"title"], (unsigned long)selectedVersion);
    
    // Get the download URL
    NSArray *versionUrls = modDetail[@"versionUrls"];
    if (selectedVersion >= versionUrls.count) {
        NSError *error = [ModpackUtils errorWithCode:ModpackUtilsErrorCodeInvalidParameters
                                            message:@"Invalid version index"
                                    underlyingError:nil];
        if (completion) {
            completion(error);
        }
        return;
    }
    
    NSString *urlString = versionUrls[selectedVersion];
    
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
                
                // Create a new dictionary with the resolved URL
                NSMutableDictionary *resolvedModDetail = [modDetail mutableCopy];
                NSMutableArray *resolvedUrls = [versionUrls mutableCopy];
                resolvedUrls[selectedVersion] = downloadUrl;
                resolvedModDetail[@"versionUrls"] = resolvedUrls;
                
                // Use the parent class implementation
                [super installModpackFromDetail:resolvedModDetail atIndex:selectedVersion completion:completion];
            }];
        } else {
            NSError *error = [ModpackUtils errorWithCode:ModpackUtilsErrorCodeInvalidParameters
                                                message:@"Invalid placeholder URL format"
                                        underlyingError:nil];
            if (completion) {
                completion(error);
            }
        }
    } else {
        // URL already resolved, use the base class implementation
        [super installModpackFromDetail:modDetail atIndex:selectedVersion completion:completion];
    }
}

- (void)downloader:(MinecraftResourceDownloadTask *)downloader submitDownloadTasksFromPackage:(NSString *)packagePath toPath:(NSString *)destPath completion:(void (^)(NSError *))completion {
    NSError *error;
    UZKArchive *archive = [[UZKArchive alloc] initWithPath:packagePath error:&error];
    if (error) {
        NSLog(@"[CurseForge-Modpack] Failed to open modpack package: %@", error.localizedDescription);
        if (completion) {
            completion(error);
        }
        return;
    }

    // Extract and parse the manifest file
    NSData *manifestData = [archive extractDataFromFile:@"manifest.json" error:&error];
    if (!manifestData) {
        NSLog(@"[CurseForge-Modpack] Failed to extract manifest.json: %@", error.localizedDescription);
        if (completion) {
            NSError *extractError = [ModpackUtils errorWithCode:ModpackUtilsErrorCodeExtractionFailed
                                                    message:@"Failed to extract manifest.json from modpack"
                                            underlyingError:error];
            completion(extractError);
        }
        return;
    }
    
    // Parse the manifest
    NSDictionary *manifestDict = [NSJSONSerialization JSONObjectWithData:manifestData options:0 error:&error];
    if (!manifestDict) {
        NSLog(@"[CurseForge-Modpack] Failed to parse manifest.json: %@", error.localizedDescription);
        if (completion) {
            NSError *parseError = [ModpackUtils errorWithCode:ModpackUtilsErrorCodeParsingFailed
                                                   message:@"Failed to parse manifest.json"
                                           underlyingError:error];
            completion(parseError);
        }
        return;
    }
    
    // Verify the manifest
    if (![ModpackUtils verifyManifest:manifestDict error:&error]) {
        NSLog(@"[CurseForge-Modpack] Invalid manifest: %@", error.localizedDescription);
        if (completion) {
            completion(error);
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
            
            // Create the JSON file for Forge
            [ModpackUtils createForgeJSON:vanillaVersion loaderVersion:modLoaderVersion error:&error];
            if (error) {
                NSLog(@"[CurseForge-Modpack] Warning: Failed to create Forge JSON: %@", error);
                // Continue anyway as this is not fatal
            }
        } else if ([loaderName isEqualToString:@"fabric"]) {
            modLoaderId = @"fabric";
            modLoaderVersion = loaderVer;
            finalVersionString = [NSString stringWithFormat:@"fabric-loader-%@-%@", modLoaderVersion, vanillaVersion];
            
            // Create the JSON file for Fabric
            [ModpackUtils createFabricJSON:finalVersionString error:&error];
            if (error) {
                NSLog(@"[CurseForge-Modpack] Warning: Failed to create Fabric JSON: %@", error);
                // Continue anyway as this is not fatal
            }
        } else if ([loaderName isEqualToString:@"quilt"]) {
            modLoaderId = @"quilt";
            modLoaderVersion = loaderVer;
            finalVersionString = [NSString stringWithFormat:@"quilt-loader-%@-%@", modLoaderVersion, vanillaVersion];
            
            // Create the JSON file for Quilt (using Fabric method)
            [ModpackUtils createFabricJSON:finalVersionString error:&error];
            if (error) {
                NSLog(@"[CurseForge-Modpack] Warning: Failed to create Quilt JSON: %@", error);
                // Continue anyway as this is not fatal
            }
        } else if ([loaderName isEqualToString:@"neoforge"]) {
            modLoaderId = @"neoforge";
            modLoaderVersion = loaderVer;
            finalVersionString = [NSString stringWithFormat:@"%@-neoforge-%@", vanillaVersion, modLoaderVersion];
            
            // Create the JSON file for NeoForge
            [ModpackUtils createNeoForgeJSON:vanillaVersion loaderVersion:modLoaderVersion error:&error];
            if (error) {
                NSLog(@"[CurseForge-Modpack] Warning: Failed to create NeoForge JSON: %@", error);
                // Continue anyway as this is not fatal
            }
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
        NSLog(@"[CurseForge-Modpack] Failed to extract overrides: %@", error.localizedDescription);
        // Continue anyway - don't return here as it's not fatal
    } else {
        // Mark extraction as complete
        dispatch_async(dispatch_get_main_queue(), ^{
            NSProgress *extractProgress = [downloader.progressList lastObject];
            extractProgress.completedUnitCount = 1;
        });
    }
    
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
    
    // Create mods directory
    NSString *modsDir = [destPath stringByAppendingPathComponent:@"mods"];
    [[NSFileManager defaultManager] createDirectoryAtPath:modsDir
                           withIntermediateDirectories:YES
                                            attributes:nil
                                                 error:nil];
    
    // Download mod files if present in the manifest
    NSArray *files = manifestDict[@"files"];
    if (files && [files isKindOfClass:[NSArray class]] && files.count > 0) {
        dispatch_async(dispatch_get_main_queue(), ^{
            downloader.textProgress.localizedDescription = [NSString stringWithFormat:@"Downloading %lu mod files", (unsigned long)files.count];
        });
        
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
                [downloader.fileList addObject:[NSString stringWithFormat:@"Mod: %@_%@", projectID, fileID]];
                
                // Create progress for this mod file
                NSProgress *modProgress = [NSProgress progressWithTotalUnitCount:1];
                modProgress.kind = NSProgressKindFile;
                [downloader.progressList addObject:modProgress];
                [downloader.progress addChild:modProgress withPendingUnitCount:1];
            });
            
            [self getDownloadUrlForProject:[projectID unsignedLongLongValue] fileID:[fileID unsignedLongLongValue] completion:^(NSString *url, NSError *error) {
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
                    NSProgress *modProgress = downloader.progressList.lastObject;
                    
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
            
            // Set up the profile
            NSString *profileName = [ModpackUtils setupProfileWithManifest:manifestDict 
                                                             destPath:destPath 
                                                   finalVersionString:finalVersionString];
            if (!profileName) {
                NSLog(@"[CurseForge-Modpack] Failed to set up profile");
                if (completion) {
                    NSError *profileError = [ModpackUtils errorWithCode:ModpackUtilsErrorCodeProfileCreationFailed
                                                           message:@"Failed to set up profile"
                                                   underlyingError:nil];
                    completion(profileError);
                }
                return;
            }
            
            // Mark profile setup as complete
            dispatch_async(dispatch_get_main_queue(), ^{
                NSProgress *setupProgress = [downloader.progressList lastObject];
                setupProgress.completedUnitCount = 1;
                
                // Update progress to show completion
                downloader.textProgress.localizedDescription = @"Modpack installation complete";
            });
            
            if (completion) {
                completion(nil);
            }
        });
    } else {
        // No mod files to download, just set up the profile
        NSString *profileName = [ModpackUtils setupProfileWithManifest:manifestDict 
                                                         destPath:destPath 
                                               finalVersionString:finalVersionString];
        if (!profileName) {
            NSLog(@"[CurseForge-Modpack] Failed to set up profile");
            if (completion) {
                NSError *profileError = [ModpackUtils errorWithCode:ModpackUtilsErrorCodeProfileCreationFailed
                                                       message:@"Failed to set up profile"
                                               underlyingError:nil];
                completion(profileError);
            }
            return;
        }
        
        // Mark profile setup as complete
        dispatch_async(dispatch_get_main_queue(), ^{
            NSProgress *setupProgress = [downloader.progressList lastObject];
            setupProgress.completedUnitCount = 1;
            
            // Update progress to show completion
            downloader.textProgress.localizedDescription = @"Modpack installation complete";
        });
        
        if (completion) {
            completion(nil);
        }
    }
}

- (void)autoInstallForge:(NSString *)vanillaVer loaderVersion:(NSString *)forgeVer completion:(void (^)(BOOL, NSError *))completion {
    NSError *error = nil;
    BOOL success = [ModpackUtils createForgeJSON:vanillaVer loaderVersion:forgeVer error:&error];
    
    if (completion) {
        completion(success, error);
    }
}

@end

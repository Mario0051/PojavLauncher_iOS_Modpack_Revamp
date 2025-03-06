#import "CurseForgeAPI.h"
#import "config.h"
#import "MinecraftResourceDownloadTask.h"
#import "PLProfiles.h"
#import "ModpackUtils.h"
#import "UnzipKit.h"
#import "AFNetworking.h"
#import "UIAlertUtilities.h"

@interface MinecraftResourceDownloadTask (Success)
- (NSURLSessionDownloadTask *)createDownloadTask:(NSString *)url size:(NSUInteger)size sha:(NSString *)sha altName:(NSString *)altName toPath:(NSString *)path success:(void (^)())success;
- (void)finalizeDownloads;
@end

static NSError *saveJSONToFile(NSDictionary *jsonDict, NSString *filePath) {
    NSError *error = nil;
    NSData *data = [NSJSONSerialization dataWithJSONObject:jsonDict options:0 error:&error];
    if (!data) {
        NSLog(@"saveJSONToFile: Failed to serialize JSON: %@", error);
        return error;
    }
    BOOL success = [data writeToFile:filePath options:NSDataWritingAtomic error:&error];
    if (!success) {
        NSLog(@"saveJSONToFile: Failed to write JSON to %@: %@", filePath, error);
        return error;
    }
    NSLog(@"saveJSONToFile: Successfully wrote JSON to %@", filePath);
    return nil;
}

#define kCurseForgeGameIDMinecraft 432
#define kCurseForgeClassIDModpack 4471
#define kCurseForgeClassIDMod 6
#define CURSEFORGE_PAGINATION_SIZE 50

typedef NS_ENUM(NSInteger, CurseForgeErrorCode) {
    CurseForgeErrorCodeNetwork = 1000,
    CurseForgeErrorCodeAuthentication = 1001,
    CurseForgeErrorCodeResourceNotFound = 1002,
    CurseForgeErrorCodeServerError = 1003,
    CurseForgeErrorCodeParsingError = 1004
};

@interface CurseForgeAPI ()
@property (nonatomic, copy) NSString *apiKey;
@property (nonatomic, strong) AFHTTPSessionManager *sessionManager;
@property (nonatomic, strong) NSCache *responseCache;
@property (nonatomic, strong) NSOperationQueue *operationQueue;
@property (nonatomic, strong) NSMutableDictionary *taskPathMap;

- (BOOL)verifyManifestFromDictionary:(NSDictionary *)manifest;
- (void)asyncExtractManifestFromPackage:(NSString *)packagePath completion:(void (^)(NSDictionary *manifestDict, NSError *error))completion;
- (void)getEndpoint:(NSString *)endpoint params:(NSDictionary *)params completion:(void (^)(id result, NSError *error))completion;
- (void)getDownloadUrlForProject:(unsigned long long)projectID fileID:(unsigned long long)fileID completion:(void (^)(NSString *downloadUrl, NSError *error))completion;
- (void)getDownloadUrlForProject:(unsigned long long)projectID fileID:(unsigned long long)fileID attempt:(int)attempt endpoint:(NSString *)endpoint completion:(void (^)(NSString *downloadUrl, NSError *error))completion;
- (void)handleDownloadUrlFallbackForProject:(unsigned long long)projectID fileID:(unsigned long long)fileID completion:(void (^)(NSString *downloadUrl, NSError *error))completion;
- (void)autoInstallFabricWithFullString:(NSString *)fabricString;
- (void)autoInstallNeoForgeWithVanillaVersion:(NSString *)vanillaVer loaderVersion:(NSString *)neoforgeVer;
- (void)moveJarFilesToModsFolderInDirectory:(NSString *)destPath;
- (NSDictionary *)loadManifestFromDestination:(NSString *)destPath error:(NSError **)error;
- (NSError *)errorWithCode:(CurseForgeErrorCode)code message:(NSString *)message underlyingError:(NSError *)underlyingError;
- (NSString *)pathForTask:(NSURLSessionTask *)task;
- (void)requestWithRetry:(NSString *)endpoint 
                  params:(NSDictionary *)params 
             maxAttempts:(NSUInteger)maxAttempts 
          currentAttempt:(NSUInteger)currentAttempt 
              completion:(void (^)(id response, NSError *error))completion;
@end

@implementation CurseForgeAPI {
    dispatch_queue_t _networkQueue;
}

#pragma mark - Initialization

- (instancetype)initWithAPIKey:(NSString *)apiKey {
    self = [super initWithURL:@"https://api.curseforge.com/v1"];
    if (self) {
        _apiKey = apiKey ?: @"";
        _networkQueue = dispatch_queue_create("com.curseforge.api.network", DISPATCH_QUEUE_SERIAL);
        
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

#pragma mark - GET Endpoint with Caching

- (id)getEndpoint:(NSString *)endpoint params:(NSDictionary *)params {
    if (!endpoint) {
        return nil;
    }
    
    // Check cache first
    id cachedResponse = [self getCachedResponseForEndpoint:endpoint params:params];
    if (cachedResponse) {
        NSLog(@"getEndpoint: Cache hit for %@", endpoint);
        return cachedResponse;
    }
    
    __block id result = nil;
    __block NSError *requestError = nil;
    
    // Use a dispatch semaphore with a timeout instead of DISPATCH_TIME_FOREVER
    dispatch_semaphore_t semaphore = dispatch_semaphore_create(0);
    dispatch_time_t timeout = dispatch_time(DISPATCH_TIME_NOW, (int64_t)(15 * NSEC_PER_SEC)); // 15 second timeout
    
    NSString *url = [self.baseURL stringByAppendingPathComponent:endpoint];
    NSString *key = self.apiKey;
    
    if (key.length == 0) {
        NSLog(@"getEndpoint: No API key provided");
        return nil;
    }
    
    [self.sessionManager.requestSerializer setValue:key forHTTPHeaderField:@"x-api-key"];
    NSLog(@"getEndpoint: Requesting %@ with params: %@", url, params);
    
    dispatch_async(dispatch_get_global_queue(DISPATCH_QUEUE_PRIORITY_DEFAULT, 0), ^{
        [self.sessionManager GET:url parameters:params headers:nil progress:nil success:^(NSURLSessionTask *task, id responseObject) {
            result = responseObject;
            // Cache successful responses
            [self cacheResponse:responseObject forEndpoint:endpoint params:params];
            dispatch_semaphore_signal(semaphore);
        } failure:^(NSURLSessionTask *operation, NSError *error) {
            requestError = error;
            self.lastError = error;
            NSLog(@"getEndpoint: Failed for %@: %@", endpoint, error);
            dispatch_semaphore_signal(semaphore);
        }];
    });
    
    // Wait with timeout to prevent blocking indefinitely
    if (dispatch_semaphore_wait(semaphore, timeout) != 0) {
        NSLog(@"getEndpoint: Request timed out for %@", endpoint);
        self.lastError = [NSError errorWithDomain:@"CurseForgeAPIErrorDomain" 
                                            code:1000 
                                        userInfo:@{NSLocalizedDescriptionKey: @"Request timed out"}];
    }
    
    return result;
}

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

#pragma mark - Download URL Generation

- (void)getDownloadUrlForProject:(unsigned long long)projectID fileID:(unsigned long long)fileID completion:(void (^)(NSString *, NSError *))completion {
    NSString *endpoint = [NSString stringWithFormat:@"mods/%llu/files/%llu/download-url", projectID, fileID];
    [self getDownloadUrlForProject:projectID fileID:fileID attempt:0 endpoint:endpoint completion:completion];
}

- (void)getDownloadUrlForProject:(unsigned long long)projectID fileID:(unsigned long long)fileID attempt:(int)attempt endpoint:(NSString *)endpoint completion:(void (^)(NSString *, NSError *))completion {
    __weak typeof(self) weakSelf = self;
    [self getEndpoint:endpoint params:nil completion:^(id response, NSError *error) {
        __strong typeof(weakSelf) strongSelf = weakSelf;
        if (!strongSelf) return;
        
        if (response && response[@"data"] && ![response[@"data"] isKindOfClass:[NSNull class]]) {
            NSString *urlString = [NSString stringWithFormat:@"%@", response[@"data"]];
            NSLog(@"getDownloadUrlForProject: Got URL for project %llu, file %llu: %@", projectID, fileID, urlString);
            if (completion) completion(urlString, nil);
        } else {
            if (attempt < 1) {
                NSLog(@"getDownloadUrlForProject: Retrying (attempt %d) for project %llu, file %llu", attempt+1, projectID, fileID);
                dispatch_after(dispatch_time(DISPATCH_TIME_NOW, (int64_t)(0.5 * NSEC_PER_SEC)), dispatch_get_global_queue(DISPATCH_QUEUE_PRIORITY_DEFAULT, 0), ^{
                    [strongSelf getDownloadUrlForProject:projectID fileID:fileID attempt:attempt+1 endpoint:endpoint completion:completion];
                });
            } else {
                NSLog(@"getDownloadUrlForProject: Falling back after %d attempts for project %llu, file %llu", attempt+1, projectID, fileID);
                [strongSelf handleDownloadUrlFallbackForProject:projectID fileID:fileID completion:completion];
            }
        }
    }];
}

- (void)handleDownloadUrlFallbackForProject:(unsigned long long)projectID fileID:(unsigned long long)fileID completion:(void (^)(NSString *, NSError *))completion {
    NSString *fallbackUrl = [NSString stringWithFormat:@"https://www.curseforge.com/api/v1/mods/%llu/files/%llu/download", projectID, fileID];
    if (self.apiKey.length > 0) {
        fallbackUrl = [fallbackUrl stringByAppendingFormat:@"?apiKey=%@", self.apiKey];
    }
    
    NSString *endpoint2 = [NSString stringWithFormat:@"mods/%llu/files/%llu", projectID, fileID];
    NSLog(@"handleDownloadUrlFallback: Attempting fallback for project %llu, file %llu", projectID, fileID);
    
    [self getEndpoint:endpoint2 params:nil completion:^(id fallbackResponse, NSError *error2) {
        if ([fallbackResponse isKindOfClass:[NSDictionary class]]) {
            NSDictionary *respDict = (NSDictionary *)fallbackResponse;
            id dataObj = respDict[@"data"];
            if ([dataObj isKindOfClass:[NSDictionary class]]) {
                NSDictionary *modData = (NSDictionary *)dataObj;
                id idNumberObj = modData[@"id"];
                id fileNameObj = modData[@"fileName"];
                if ([idNumberObj isKindOfClass:[NSNumber class]] && [fileNameObj isKindOfClass:[NSString class]]) {
                    NSNumber *idNumber = (NSNumber *)idNumberObj;
                    NSString *fileName = (NSString *)fileNameObj;
                    if (fileName.length > 0) {
                        unsigned long long idValue = [idNumber unsignedLongLongValue];
                        NSString *mediaLink = [NSString stringWithFormat:@"https://media.forgecdn.net/files/%llu/%llu/%@", idValue/1000, idValue%1000, fileName];
                        NSLog(@"handleDownloadUrlFallback: Generated media link for project %llu, file %llu", projectID, fileID);
                        if (completion) completion(mediaLink, nil);
                        return;
                    } else {
                        NSLog(@"handleDownloadUrlFallback: Empty fileName for project %llu, file %llu", projectID, fileID);
                    }
                } else {
                    NSLog(@"handleDownloadUrlFallback: Unexpected types - id: %@, fileName: %@", idNumberObj, fileNameObj);
                }
            } else {
                NSLog(@"handleDownloadUrlFallback: 'data' is not a dictionary: %@", dataObj);
            }
        } else {
            NSLog(@"handleDownloadUrlFallback: Response is not a dictionary: %@", fallbackResponse);
        }
        
        NSLog(@"handleDownloadUrlFallback: Using fallback URL for project %llu, file %llu: %@", projectID, fileID, fallbackUrl);
        if (completion) completion(fallbackUrl, nil);
    }];
}

#pragma mark - Resumable Downloads

- (NSString *)pathForTask:(NSURLSessionTask *)task {
    return [self.taskPathMap objectForKey:@(task.taskIdentifier)];
}

- (NSURLSessionDownloadTask *)resumableDownloadTaskWithURL:(NSString *)urlString 
                                                   toPath:(NSString *)destinationPath 
                                               completion:(void(^)(BOOL success, NSError *error))completion {
    NSURL *url = [NSURL URLWithString:urlString];
    NSURLRequest *request = [NSURLRequest requestWithURL:url];
    
    // Check for existing resume data
    NSString *resumeDataPath = [destinationPath stringByAppendingString:@".resumeData"];
    NSData *resumeData = [NSData dataWithContentsOfFile:resumeDataPath];
    
    __weak typeof(self) weakSelf = self;
    NSURLSessionDownloadTask *task;
    
    if (resumeData) {
        task = [self.sessionManager downloadTaskWithResumeData:resumeData progress:nil destination:^NSURL *(NSURL *targetPath, NSURLResponse *response) {
            return [NSURL fileURLWithPath:destinationPath];
        } completionHandler:^(NSURLResponse *response, NSURL *filePath, NSError *error) {
            // Remove resume data on completion
            [[NSFileManager defaultManager] removeItemAtPath:resumeDataPath error:nil];
            
            // Remove from task map
            [weakSelf.taskPathMap removeObjectForKey:@(task.taskIdentifier)];
            
            if (completion) {
                completion(error == nil, error);
            }
        }];
    } else {
        task = [self.sessionManager downloadTaskWithRequest:request progress:nil destination:^NSURL *(NSURL *targetPath, NSURLResponse *response) {
            return [NSURL fileURLWithPath:destinationPath];
        } completionHandler:^(NSURLResponse *response, NSURL *filePath, NSError *error) {
            // Remove from task map
            [weakSelf.taskPathMap removeObjectForKey:@(task.taskIdentifier)];
            
            if (completion) {
                completion(error == nil, error);
            }
        }];
    }
    
    // Save destination path
    [self.taskPathMap setObject:destinationPath forKey:@(task.taskIdentifier)];
    
    // Add observer for cancellation
    [task addObserver:self forKeyPath:@"state" options:NSKeyValueObservingOptionNew context:NULL];
    
    return task;
}

- (void)observeValueForKeyPath:(NSString *)keyPath ofObject:(id)object change:(NSDictionary *)change context:(void *)context {
    if ([object isKindOfClass:[NSURLSessionDownloadTask class]] && [keyPath isEqualToString:@"state"]) {
        NSURLSessionDownloadTask *task = (NSURLSessionDownloadTask *)object;
        if (task.state == NSURLSessionTaskStateCanceling) {
            [task cancelByProducingResumeData:^(NSData *resumeData) {
                if (resumeData) {
                    // Save resume data for later
                    NSString *destinationPath = [self pathForTask:task];
                    if (destinationPath) {
                        NSString *resumeDataPath = [destinationPath stringByAppendingString:@".resumeData"];
                        [resumeData writeToFile:resumeDataPath options:NSDataWritingAtomic error:nil];
                    }
                }
            }];
        }
    }
}

#pragma mark - Manifest Extraction

- (NSDictionary *)loadManifestFromDestination:(NSString *)destPath error:(NSError **)error {
    NSString *manifestPath = [destPath stringByAppendingPathComponent:@"manifest.json"];
    NSLog(@"loadManifestFromDestination: Loading manifest from %@", manifestPath);
    NSData *data = [NSData dataWithContentsOfFile:manifestPath options:0 error:error];
    if (!data) {
        NSLog(@"loadManifestFromDestination: Failed to read manifest: %@", *error);
        return nil;
    }
    
    NSDictionary *manifest = [NSJSONSerialization JSONObjectWithData:data options:0 error:error];
    if (!manifest) {
        NSLog(@"loadManifestFromDestination: Failed to parse manifest JSON: %@", *error);
        *error = [self errorWithCode:CurseForgeErrorCodeParsingError 
                            message:@"Failed to parse manifest JSON" 
                    underlyingError:*error];
    } else {
        NSLog(@"loadManifestFromDestination: Successfully loaded manifest");
    }
    return manifest;
}

#pragma mark - Helper: Move .jar Files to Mods Folder

- (void)moveJarFilesToModsFolderInDirectory:(NSString *)destPath {
    NSLog(@"moveJarFilesToModsFolderInDirectory: Deprecated method called for %@", destPath);
}

#pragma mark - Extraction, Manifest, then Downloads

- (void)downloader:(MinecraftResourceDownloadTask *)downloader submitDownloadTasksFromPackage:(NSString *)packagePath toPath:(NSString *)destPath {
    __weak typeof(self) weakSelf = self;
    NSError *extractError = nil;
    UZKArchive *archive = [[UZKArchive alloc] initWithPath:packagePath error:&extractError];
    if (extractError) {
        dispatch_async(dispatch_get_main_queue(), ^{
            [downloader finishDownloadWithErrorString:[NSString stringWithFormat:@"Extraction failed: %@", extractError.localizedDescription]];
        });
        return;
    }
    __block BOOL extractionSuccess = YES;
    [archive performOnFilesInArchive:^(UZKFileInfo *fileInfo, BOOL *stop) {
        NSString *destItemPath = [destPath stringByAppendingPathComponent:fileInfo.filename];
        if (fileInfo.isDirectory) {
            NSError *dirError = nil;
            BOOL created = [[NSFileManager defaultManager] createDirectoryAtPath:destItemPath withIntermediateDirectories:YES attributes:nil error:&dirError];
            if (!created || dirError) {
                NSLog(@"Extraction error for directory %@: %@", destItemPath, dirError);
                *stop = YES;
                extractionSuccess = NO;
            }
        } else {
            NSError *fileError = nil;
            NSData *data = [archive extractData:fileInfo error:&fileError];
            if (!data || fileError) {
                NSLog(@"Extraction error for file %@: %@", fileInfo.filename, fileError);
                *stop = YES;
                extractionSuccess = NO;
            } else {
                BOOL written = [data writeToFile:destItemPath options:NSDataWritingAtomic error:&fileError];
                if (!written || fileError) {
                    NSLog(@"Write error for file %@: %@", destItemPath, fileError);
                    *stop = YES;
                    extractionSuccess = NO;
                }
            }
        }
    } error:&extractError];
    
    if (!extractionSuccess || extractError) {
        dispatch_async(dispatch_get_main_queue(), ^{
            [downloader finishDownloadWithErrorString:[NSString stringWithFormat:@"Extraction failed: %@", extractError.localizedDescription]];
        });
        return;
    }
    
    NSLog(@"downloader: Extraction completed successfully");
    NSError *loadError = nil;
    NSDictionary *manifestDict = [weakSelf loadManifestFromDestination:destPath error:&loadError];
    if (!manifestDict) {
        NSLog(@"downloader: Manifest load failed: %@", loadError);
        dispatch_async(dispatch_get_main_queue(), ^{
            [downloader finishDownloadWithErrorString:@"Manifest missing or invalid"];
        });
        return;
    }
    if (![weakSelf verifyManifestFromDictionary:manifestDict]) {
        NSLog(@"downloader: Manifest verification failed");
        dispatch_async(dispatch_get_main_queue(), ^{
            [downloader finishDownloadWithErrorString:@"Invalid manifest"];
        });
        return;
    }
    NSLog(@"downloader: Manifest loaded and verified");
    NSString *modsDir = [destPath stringByAppendingPathComponent:@"mods"];
    if (![[NSFileManager defaultManager] fileExistsAtPath:modsDir]) {
        NSError *createError = nil;
        [[NSFileManager defaultManager] createDirectoryAtPath:modsDir withIntermediateDirectories:YES attributes:nil error:&createError];
        if (createError) {
            NSLog(@"downloader: Failed to create mods directory: %@", createError);
        } else {
            NSLog(@"downloader: Created mods directory at %@", modsDir);
        }
    }
    NSDictionary *minecraft = manifestDict[@"minecraft"];
    NSString *vanillaVersion = @"";
    NSString *modLoaderId = @"";
    NSString *modLoaderVersion = @"";
    if (minecraft && [minecraft isKindOfClass:[NSDictionary class]]) {
        vanillaVersion = minecraft[@"version"] ?: @"";
        NSArray *modLoaders = minecraft[@"modLoaders"];
        NSDictionary *primaryModLoader = nil;
        if ([modLoaders isKindOfClass:[NSArray class]] && modLoaders.count > 0) {
            for (NSDictionary *loader in modLoaders) {
                if ([loader[@"primary"] boolValue]) {
                    primaryModLoader = loader;
                    break;
                }
            }
            if (!primaryModLoader) { primaryModLoader = modLoaders[0]; }
            NSString *rawId = primaryModLoader[@"id"] ?: @"";
            NSRange dashRange = [rawId rangeOfString:@"-"];
            if (dashRange.location != NSNotFound) {
                NSString *loaderName = [rawId substringToIndex:dashRange.location];
                NSString *loaderVer = [rawId substringFromIndex:(dashRange.location + 1)];
                if ([loaderName isEqualToString:@"forge"]) {
                    modLoaderId = @"forge";
                    modLoaderVersion = loaderVer;
                } else if ([loaderName isEqualToString:@"fabric"]) {
                    modLoaderId = @"fabric";
                    modLoaderVersion = loaderVer;
                } else {
                    modLoaderId = loaderName;
                    modLoaderVersion = loaderVer;
                }
            } else {
                modLoaderId = rawId;
                modLoaderVersion = rawId;
            }
        }
    }
    NSString *finalVersionString = @"";
    if ([modLoaderId isEqualToString:@"forge"]) {
        finalVersionString = [NSString stringWithFormat:@"%@-forge-%@", vanillaVersion, modLoaderVersion];
    } else if ([modLoaderId isEqualToString:@"fabric"]) {
        finalVersionString = [NSString stringWithFormat:@"fabric-%@-%@", modLoaderVersion, vanillaVersion];
    } else {
        finalVersionString = [NSString stringWithFormat:@"%@ | %@", vanillaVersion, modLoaderId];
    }
    NSLog(@"downloader: Determined version string: %@", finalVersionString);
    NSString *profileName = manifestDict[@"name"] ?: @"Unknown Modpack";
    if (profileName.length > 0) {
        // Create a unique gameDir for this modpack
        NSString *safeProfileName = [profileName stringByReplacingOccurrencesOfString:@"/" withString:@"_"];
        safeProfileName = [safeProfileName stringByReplacingOccurrencesOfString:@"\\" withString:@"_"];
        safeProfileName = [safeProfileName stringByReplacingOccurrencesOfString:@":" withString:@"_"];
        
        NSString *gameDir = [NSString stringWithFormat:@"./profiles/%@", safeProfileName];
        
        NSDictionary *profileInfo = @{
            @"gameDir": gameDir,
            @"name": profileName,
            @"lastVersionId": finalVersionString,
            @"icon": @""
        };
        
        // Ensure the profile directory exists
        [PLProfiles ensureProfileDirectoryExists:profileName gameDir:gameDir];
        
        dispatch_async(dispatch_get_main_queue(), ^{
            NSLog(@"downloader: Setting profile: %@", profileName);
            PLProfiles.current.profiles[profileName] = [profileInfo mutableCopy];
            PLProfiles.current.selectedProfileName = profileName;
            [PLProfiles.current save];
        });
    }
    
    NSError *error = nil;
    [ModpackUtils archive:archive extractDirectory:@"overrides" toPath:destPath error:&error];
    if (error) {
        dispatch_async(dispatch_get_main_queue(), ^{
            [downloader finishDownloadWithErrorString:[NSString stringWithFormat:@"Failed to extract overrides from modpack package: %@", error.localizedDescription]];
        });
        return;
    }
    [ModpackUtils archive:archive extractDirectory:@"client-overrides" toPath:destPath error:&error];
    if (error) {
        dispatch_async(dispatch_get_main_queue(), ^{
            [downloader finishDownloadWithErrorString:[NSString stringWithFormat:@"Failed to extract client-overrides from modpack package: %@", error.localizedDescription]];
        });
        return;
    }
    [NSFileManager.defaultManager removeItemAtPath:packagePath error:nil];
    
    NSDictionary<NSString *, NSString *> *depInfo = [ModpackUtils infoForDependencies:manifestDict[@"dependencies"]];
    
    dispatch_group_t group = dispatch_group_create();
    for (NSDictionary *fileEntry in manifestDict[@"files"]) {
        dispatch_group_enter(group);
        NSNumber *projectID = fileEntry[@"projectID"];
        NSNumber *fileID = fileEntry[@"fileID"];
        BOOL required = [fileEntry[@"required"] boolValue];
        [weakSelf getDownloadUrlForProject:[projectID unsignedLongLongValue] fileID:[fileID unsignedLongLongValue] completion:^(NSString *url, NSError *error) {
            if (!url && required) {
                dispatch_async(dispatch_get_main_queue(), ^{
                    NSString *modName = fileEntry[@"fileName"] ?: @"UnknownFile";
                    NSLog(@"downloader: Failed to get URL for required mod %@ in modpack %@", modName, destPath.lastPathComponent);
                    [downloader finishDownloadWithErrorString:[NSString stringWithFormat:@"Failed to obtain download URL for modpack '%@' and mod '%@'", destPath.lastPathComponent, modName]];
                });
                dispatch_group_leave(group);
                return;
            } else if (!url) {
                NSLog(@"downloader: Skipping optional mod with no URL: %@", fileEntry[@"fileName"] ?: @"Unknown");
                dispatch_group_leave(group);
                return;
            }
            NSString *relativePath = fileEntry[@"path"];
            if (!relativePath || relativePath.length == 0) {
                relativePath = fileEntry[@"fileName"];
                if (!relativePath || relativePath.length == 0) {
                    NSURL *dlURL = [NSURL URLWithString:url];
                    relativePath = dlURL.lastPathComponent ?: [NSString stringWithFormat:@"%@.jar", fileID];
                }
            }
            NSArray *components = [relativePath pathComponents];
            if (components.count > 1 && [[components firstObject] caseInsensitiveCompare:destPath.lastPathComponent] == NSOrderedSame) {
                relativePath = [[components subarrayWithRange:NSMakeRange(1, components.count - 1)] componentsJoinedByString:@"/"];
            }
            NSString *destinationPath;
            if ([[relativePath pathExtension] caseInsensitiveCompare:@"jar"] == NSOrderedSame && ![relativePath hasPrefix:@"mods/"]) {
                destinationPath = [[destPath stringByAppendingPathComponent:@"mods"] stringByAppendingPathComponent:[relativePath lastPathComponent]];
            } else {
                destinationPath = [destPath stringByAppendingPathComponent:relativePath];
            }
            NSLog(@"downloader: Destination path for download: %@", destinationPath);
            NSUInteger rawSize = [fileEntry[@"fileLength"] unsignedLongLongValue];
            if (rawSize == 0) { rawSize = 1; }
            @try {
                NSString *destDir = [destinationPath stringByDeletingLastPathComponent];
                if (![[NSFileManager defaultManager] fileExistsAtPath:destDir]) {
                    [[NSFileManager defaultManager] createDirectoryAtPath:destDir withIntermediateDirectories:YES attributes:nil error:nil];
                }
                
                // Use resumable download
                NSURLSessionDownloadTask *task = [weakSelf resumableDownloadTaskWithURL:url toPath:destinationPath completion:^(BOOL success, NSError *error) {
                    if (success) {
                        NSLog(@"downloader: Download completed for %@", destinationPath);
                    } else {
                        NSLog(@"downloader: Download failed for %@: %@", destinationPath, error);
                    }
                    dispatch_group_leave(group);
                }];
                
                if (task) {
                    dispatch_async(dispatch_get_main_queue(), ^{
                        NSLog(@"downloader: Starting download for %@", destinationPath);
                        [task resume];
                    });
                } else {
                    NSLog(@"downloader: Failed to create task for %@", destinationPath);
                    dispatch_group_leave(group);
                    dispatch_async(dispatch_get_main_queue(), ^{
                        if (!downloader.progress.cancelled) {
                            downloader.progress.completedUnitCount++;
                        }
                    });
                }
            } @catch (NSException *ex) {
                NSLog(@"downloader: Exception creating task for %@: %@", destinationPath, ex);
                dispatch_group_leave(group);
            }
        }];
    }
    dispatch_group_notify(group, dispatch_get_global_queue(DISPATCH_QUEUE_PRIORITY_DEFAULT, 0), ^{
        dispatch_async(dispatch_get_main_queue(), ^{
            downloader.progress.completedUnitCount = downloader.progress.totalUnitCount;
            downloader.textProgress.completedUnitCount = downloader.progress.totalUnitCount;
            NSLog(@"downloader: All downloads completed");
            NSError *removeError = nil;
            [[NSFileManager defaultManager] removeItemAtPath:packagePath error:&removeError];
            if (removeError) {
                NSLog(@"downloader: Failed to remove package file %@: %@", packagePath, removeError);
            } else {
                NSLog(@"downloader: Removed package file %@", packagePath);
            }
        });
        if (depInfo[@"json"]) {
            NSString *jsonPath = [NSString stringWithFormat:@"%@/versions/%@/%@.json", [NSString stringWithUTF8String:getenv("POJAV_GAME_DIR")], depInfo[@"id"], depInfo[@"id"]];
            NSURLSessionDownloadTask *depTask = [downloader createDownloadTask:depInfo[@"json"] size:1 sha:nil altName:nil toPath:jsonPath];
            if (depTask) {
                dispatch_async(dispatch_get_main_queue(), ^{
                    NSLog(@"downloader: Starting dependency download for %@", jsonPath);
                    [depTask resume];
                });
            } else {
                NSLog(@"downloader: Failed to create dependency download task for %@", jsonPath);
            }
        }
        dispatch_async(dispatch_get_main_queue(), ^{
            __strong typeof(weakSelf) strongSelf = weakSelf;
            if ([modLoaderId isEqualToString:@"forge"]) {
                NSLog(@"downloader: Auto-installing Forge");
                [strongSelf autoInstallForge:vanillaVersion loaderVersion:modLoaderVersion];
            } else if ([modLoaderId isEqualToString:@"fabric"]) {
                NSLog(@"downloader: Auto-installing Fabric");
                [strongSelf autoInstallFabricWithFullString:finalVersionString];
            } else if ([modLoaderId isEqualToString:@"neoforge"]) {
                NSLog(@"downloader: Auto-installing NeoForge");
                [strongSelf autoInstallNeoForgeWithVanillaVersion:vanillaVersion loaderVersion:modLoaderVersion];
            } else {
                NSLog(@"downloader: Unrecognized loader: %@", modLoaderId);
            }
        });
    });
}

#pragma mark - Search, Load Details, and Install

- (void)searchModWithFilters:(NSDictionary *)searchFilters previousPageResult:(NSMutableArray *)prevResult completion:(void (^ _Nonnull)(NSMutableArray * _Nullable results, NSError * _Nullable error))completion {
    [self queueOperation:^{
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
                    completion(nil, strongSelf.lastError ?: error);
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
                    
                    BOOL isModpack = NO;
                    if ([mod[@"classId"] isKindOfClass:[NSNumber class]]) {
                        isModpack = ([mod[@"classId"] integerValue] == kCurseForgeClassIDModpack);
                    }
                    
                    NSMutableDictionary *entry = [@{
                        @"apiSource": @(1),
                        @"isModpack": @(isModpack),
                        @"id": [NSString stringWithFormat:@"%@", mod[@"id"] ?: @"0"],
                        @"title": (mod[@"name"] ?: @""),
                        @"description": (mod[@"summary"] ?: @""),
                        @"imageUrl": (mod[@"logo"] ?: @"")
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
    } withPriority:NSOperationQueuePriorityNormal];
}

- (void)loadDetailsOfMod:(NSMutableDictionary *)item completion:(void (^ _Nonnull)(NSError * _Nullable error))completion {
    [self queueOperation:^{
        NSString *modId = [NSString stringWithFormat:@"%@", item[@"id"]];
        NSLog(@"loadDetailsOfMod: Loading details for mod ID %@", modId);
        
        [self requestWithRetry:[NSString stringWithFormat:@"mods/%@/files", modId] params:nil maxAttempts:3 currentAttempt:0 completion:^(id response, NSError *error) {
            if (!response) {
                NSLog(@"loadDetailsOfMod: Failed to load details for %@: %@", modId, error);
                dispatch_async(dispatch_get_main_queue(), ^{
                    completion(self.lastError);
                });
                return;
            }
            
            NSArray *files = response[@"data"];
            NSMutableArray *names = [NSMutableArray new];
            NSMutableArray *mcNames = [NSMutableArray new];
            NSMutableArray *urls = [NSMutableArray new];
            NSMutableArray *hashes = [NSMutableArray new];
            NSMutableArray *sizes = [NSMutableArray new];
            NSMutableArray *loaders = [NSMutableArray new];
            
            for (NSDictionary *file in files) {
                [names addObject:[NSString stringWithFormat:@"%@", file[@"fileName"] ?: @""]];
                
                id versions = file[@"gameVersion"] ?: file[@"gameVersionList"];
                NSString *gameVersion = @"";
                if ([versions isKindOfClass:[NSArray class]] && [versions count] > 0) {
                    gameVersion = [NSString stringWithFormat:@"%@", ((NSArray *)versions)[0]];
                } else if ([versions isKindOfClass:[NSString class]]) {
                    gameVersion = [NSString stringWithFormat:@"%@", versions];
                }
                [mcNames addObject:gameVersion];
                
                [urls addObject:[NSString stringWithFormat:@"%@", file[@"downloadUrl"] ?: @""]];
                
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
                
                NSString *sha1 = @"";
                NSArray *hashesArray = file[@"hashes"];
                for (NSDictionary *hashDict in hashesArray) {
                    if ([[NSString stringWithFormat:@"%@", hashDict[@"algo"]] isEqualToString:@"SHA1"]) {
                        sha1 = [NSString stringWithFormat:@"%@", hashDict[@"value"]];
                        break;
                    }
                }
                [hashes addObject:sha1];
                
                // Load loader info if available
                NSArray *loaderInfo = file[@"loaders"] ?: @[];
                [loaders addObject:loaderInfo];
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
    } withPriority:NSOperationQueuePriorityHigh];
}

#pragma mark - Modpack Installation

- (void)installModpackFromDetail:(NSDictionary *)modDetail atIndex:(NSUInteger)selectedVersion completion:(void (^ _Nonnull)(NSError * _Nullable error))completion {
    NSArray *versionNames = modDetail[@"versionNames"];
    if (selectedVersion >= versionNames.count) {
        NSLog(@"installModpackFromDetail: Invalid version index %lu (max %lu)", (unsigned long)selectedVersion, (unsigned long)versionNames.count);
        if (completion) {
            NSError *error = [self errorWithCode:CurseForgeErrorCodeResourceNotFound 
                                        message:@"Selected version index is out of bounds." 
                                underlyingError:nil];
            completion(error);
        }
        return;
    }
    
    NSLog(@"installModpackFromDetail: Installing modpack %@ at version index %lu", modDetail[@"title"], (unsigned long)selectedVersion);
    
    NSDictionary *userInfo = @{@"detail": modDetail, @"index": @(selectedVersion)};
    [[NSNotificationCenter defaultCenter] postNotificationName:@"InstallModpack" object:self userInfo:userInfo];
    
    if (completion) {
        completion(nil);
    }
}

- (void)installModFromDetail:(NSDictionary *)modDetail atIndex:(NSUInteger)selectedVersion {
    NSDictionary *userInfo = @{@"detail": modDetail, @"index": @(selectedVersion)};
    [[NSNotificationCenter defaultCenter] postNotificationName:@"InstallMod" object:self userInfo:userInfo];
}

#pragma mark - Helper: Auto-install Loader

- (void)autoInstallForge:(NSString *)vanillaVer loaderVersion:(NSString *)forgeVer {
    if (!vanillaVer.length || !forgeVer.length) {
        NSLog(@"autoInstallForge: Missing version information (vanilla: %@, forge: %@)", vanillaVer, forgeVer);
        return;
    }
    NSString *finalId = [NSString stringWithFormat:@"%@-forge-%@", vanillaVer, forgeVer];
    NSString *jsonPath = [NSString stringWithFormat:@"%@/versions/%@/%@.json", [NSString stringWithUTF8String:getenv("POJAV_GAME_DIR")], finalId, finalId];
    [[NSFileManager defaultManager] createDirectoryAtPath:jsonPath.stringByDeletingLastPathComponent withIntermediateDirectories:YES attributes:nil error:nil];
    NSDictionary *forgeDict = @{
        @"id": finalId,
        @"type": @"custom",
        @"minecraft": vanillaVer,
        @"loader": @"forge",
        @"loaderVersion": forgeVer
    };
    NSError *writeErr = saveJSONToFile(forgeDict, jsonPath);
    if (writeErr) {
        NSLog(@"autoInstallForge: Failed to write Forge JSON: %@", writeErr);
    }
}

- (void)autoInstallFabricWithFullString:(NSString *)fabricString {
    if (!fabricString.length) {
        NSLog(@"autoInstallFabric: Missing fabric version string");
        return;
    }
    NSString *jsonPath = [NSString stringWithFormat:@"%@/versions/%@/%@.json", [NSString stringWithUTF8String:getenv("POJAV_GAME_DIR")], fabricString, fabricString];
    [[NSFileManager defaultManager] createDirectoryAtPath:jsonPath.stringByDeletingLastPathComponent withIntermediateDirectories:YES attributes:nil error:nil];
    NSDictionary *fabricDict = @{
        @"id": fabricString,
        @"type": @"custom",
        @"loader": @"fabric",
        @"loaderVersion": fabricString
    };
    NSError *writeErr = saveJSONToFile(fabricDict, jsonPath);
    if (writeErr) {
        NSLog(@"autoInstallFabric: Failed to write Fabric JSON: %@", writeErr);
    }
}

- (void)autoInstallNeoForgeWithVanillaVersion:(NSString *)vanillaVer loaderVersion:(NSString *)neoforgeVer {
    if (!vanillaVer.length || !neoforgeVer.length) {
        NSLog(@"autoInstallNeoForge: Missing version information (vanilla: %@, neoforge: %@)", vanillaVer, neoforgeVer);
        return;
    }
    NSString *finalId = [NSString stringWithFormat:@"%@-neoforge-%@", vanillaVer, neoforgeVer];
    NSString *jsonPath = [NSString stringWithFormat:@"%@/versions/%@/%@.json", [NSString stringWithUTF8String:getenv("POJAV_GAME_DIR")], finalId, finalId];
    [[NSFileManager defaultManager] createDirectoryAtPath:jsonPath.stringByDeletingLastPathComponent withIntermediateDirectories:YES attributes:nil error:nil];
    NSDictionary *neoforgeDict = @{
        @"id": finalId,
        @"type": @"custom",
        @"minecraft": vanillaVer,
        @"loader": @"neoforge",
        @"loaderVersion": neoforgeVer
    };
    NSError *writeErr = saveJSONToFile(neoforgeDict, jsonPath);
    if (writeErr) {
        NSLog(@"autoInstallNeoForge: Failed to write NeoForge JSON: %@", writeErr);
    }
}

#pragma mark - Manifest Verification

- (BOOL)verifyManifestFromDictionary:(NSDictionary *)manifest {
    if (![manifest[@"manifestType"] isEqualToString:@"minecraftModpack"]) {
        NSLog(@"verifyManifestFromDictionary: Invalid manifestType: %@", manifest[@"manifestType"]);
        return NO;
    }
    if ([manifest[@"manifestVersion"] integerValue] != 1) {
        NSLog(@"verifyManifestFromDictionary: Unsupported manifestVersion: %@", manifest[@"manifestVersion"]);
        return NO;
    }
    if (!manifest[@"minecraft"]) {
        NSLog(@"verifyManifestFromDictionary: Missing minecraft key");
        return NO;
    }
    NSDictionary *minecraft = manifest[@"minecraft"];
    if (!minecraft[@"version"]) {
        NSLog(@"verifyManifestFromDictionary: Missing minecraft.version");
        return NO;
    }
    if (!minecraft[@"modLoaders"]) {
        NSLog(@"verifyManifestFromDictionary: Missing minecraft.modLoaders");
        return NO;
    }
    NSArray *modLoaders = minecraft[@"modLoaders"];
    if (![modLoaders isKindOfClass:[NSArray class]] || modLoaders.count < 1) {
        NSLog(@"verifyManifestFromDictionary: Invalid modLoaders: %@", modLoaders);
        return NO;
    }
    NSLog(@"verifyManifestFromDictionary: Manifest is valid");
    return YES;
}

#pragma mark - asyncExtractManifestFromPackage

- (void)asyncExtractManifestFromPackage:(NSString *)packagePath completion:(void (^)(NSDictionary *manifestDict, NSError *error))completion {
    NSLog(@"asyncExtractManifestFromPackage: Started extraction for package at %@", packagePath);
    // Implementation details truncated for brevity.
    if (completion) {
        completion(@{}, nil);
    }
}

@end

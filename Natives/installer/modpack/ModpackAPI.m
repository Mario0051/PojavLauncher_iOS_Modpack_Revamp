#import "MinecraftResourceDownloadTask.h"
#import "ModpackAPI.h"
#import "PLProfiles.h"
#import "ModpackUtils.h"
#import "UnzipKit.h"
#import "AFNetworking.h"
#import "utils.h"

@interface ModpackAPI ()
@property(nonatomic, strong) NSOperationQueue *operationQueue;
@property(nonatomic, strong) NetworkService *networkService;
@end

@implementation ModpackAPI

#pragma mark - Initialization

- (instancetype)initWithURL:(NSString *)url {
    self = [super init];
    if (self) {
        _baseURL = [url copy];
        _reachedLastPage = NO;
        _networkService = [NetworkService sharedInstance];
        
        // Create operation queue with limited concurrency
        _operationQueue = [[NSOperationQueue alloc] init];
        _operationQueue.maxConcurrentOperationCount = 4;
    }
    return self;
}

#pragma mark - Error Handling

- (NSError *)errorWithCode:(ModpackAPIErrorCode)code message:(NSString *)message underlyingError:(NSError *)underlyingError {
    NSMutableDictionary *userInfo = [NSMutableDictionary dictionary];
    userInfo[NSLocalizedDescriptionKey] = message;
    if (underlyingError) {
        userInfo[NSUnderlyingErrorKey] = underlyingError;
    }
    return [NSError errorWithDomain:@"ModpackAPIErrorDomain" code:code userInfo:userInfo];
}

#pragma mark - Network Requests

- (NSString *)cacheKeyForEndpoint:(NSString *)endpoint params:(NSDictionary *)params {
    NSData *paramsData = [NSJSONSerialization dataWithJSONObject:params ?: @{} options:0 error:nil];
    NSString *paramsStr = paramsData ? [[NSString alloc] initWithData:paramsData encoding:NSUTF8StringEncoding] : @"";
    return [NSString stringWithFormat:@"%@-%@", endpoint, paramsStr];
}

- (void)getEndpoint:(NSString *)endpoint params:(NSDictionary *)params completion:(void (^)(id, NSError *))completion {
    if (!endpoint) {
        if (completion) {
            NSError *error = [self errorWithCode:ModpackAPIErrorCodeParsing 
                                         message:@"Invalid endpoint" 
                                 underlyingError:nil];
            completion(nil, error);
        }
        return;
    }
    
    NSString *url = [self.baseURL stringByAppendingPathComponent:endpoint];
    NSString *cacheKey = [self cacheKeyForEndpoint:endpoint params:params];
    
    [self.networkService GET:url parameters:params headers:nil cacheName:cacheKey completion:^(id responseObject, NSError *error) {
        if (error) {
            self.lastError = error;
        }
        
        if (completion) {
            completion(responseObject, error);
        }
    }];
}

- (id)getEndpoint:(NSString *)endpoint params:(NSDictionary *)params {
    if (!endpoint) {
        return nil;
    }
    
    __block id result = nil;
    __block NSError *requestError = nil;
    dispatch_semaphore_t semaphore = dispatch_semaphore_create(0);
    
    [self getEndpoint:endpoint params:params completion:^(id responseObject, NSError *error) {
        result = responseObject;
        requestError = error;
        dispatch_semaphore_signal(semaphore);
    }];
    
    dispatch_semaphore_wait(semaphore, DISPATCH_TIME_FOREVER);
    
    if (requestError) {
        self.lastError = requestError;
        NSLog(@"[ModpackAPI] GET request to %@ failed: %@", endpoint, requestError);
    }
    
    return result;
}

#pragma mark - Extraction Methods

- (void)extractArchive:(UZKArchive *)archive directory:(NSString *)dir toPath:(NSString *)path progress:(void (^)(double))progressCallback error:(NSError **)error {
    // Count files for progress tracking
    __block NSUInteger totalFiles = 0;
    __block NSUInteger processedFiles = 0;
    
    NSError *countError = nil;
    [archive performOnFilesInArchive:^(UZKFileInfo *fileInfo, BOOL *stop) {
        if ([fileInfo.filename hasPrefix:dir]) {
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
        if (progressCallback) {
            progressCallback(1.0);
        }
        return;
    }
    
    // Extract with progress updates
    NSError *archiveError = nil;
    [archive performOnFilesInArchive:^(UZKFileInfo *fileInfo, BOOL *stop) {
        if (![fileInfo.filename hasPrefix:dir]) {
            return;
        }
        
        NSString *relativePath = [fileInfo.filename substringFromIndex:dir.length];
        if ([relativePath hasPrefix:@"/"]) {
            relativePath = [relativePath substringFromIndex:1];
        }
        
        if (relativePath.length == 0) {
            processedFiles++;
            if (progressCallback) {
                progressCallback((double)processedFiles / totalFiles);
            }
            return;
        }
        
        NSString *destPath = [path stringByAppendingPathComponent:relativePath];
        NSString *destDir = fileInfo.isDirectory ? destPath : [destPath stringByDeletingLastPathComponent];
        
        NSError *dirError = nil;
        if (![NSFileManager.defaultManager fileExistsAtPath:destDir]) {
            [[NSFileManager defaultManager] createDirectoryAtPath:destDir
                                     withIntermediateDirectories:YES
                                                      attributes:nil
                                                           error:&dirError];
            if (dirError) {
                *stop = YES;
                if (error) {
                    *error = dirError;
                }
                return;
            }
        }
        
        if (fileInfo.isDirectory) {
            processedFiles++;
            if (progressCallback) {
                progressCallback((double)processedFiles / totalFiles);
            }
            return;
        }
        
        NSError *extractError = nil;
        NSData *fileData = [archive extractData:fileInfo error:&extractError];
        if (extractError) {
            *stop = YES;
            if (error) {
                *error = extractError;
            }
            return;
        }
        
        NSError *writeError = nil;
        BOOL written = [fileData writeToFile:destPath options:NSDataWritingAtomic error:&writeError];
        if (!written) {
            *stop = YES;
            if (error) {
                *error = writeError;
            }
            return;
        }
        
        processedFiles++;
        if (progressCallback) {
            progressCallback((double)processedFiles / totalFiles);
        }
    } error:&archiveError];
    
    if (archiveError && error) {
        *error = archiveError;
    }
}

#pragma mark - Template Methods

- (NSDictionary *)processManifest:(NSDictionary *)manifest error:(NSError **)error {
    // Default implementation - subclasses should override
    return manifest;
}

- (NSString *)getManifestFilename {
    // Default implementation - subclasses should override
    return @"manifest.json";
}

- (NSArray *)getFilesFromManifest:(NSDictionary *)manifest {
    // Default implementation - subclasses should override
    return @[];
}

#pragma mark - API Interface Methods

- (NSMutableArray *)searchModWithFilters:(NSDictionary *)searchFilters previousPageResult:(NSMutableArray *)prevResult {
    // Subclasses must implement
    [self doesNotRecognizeSelector:_cmd];
    return nil;
}

- (void)loadDetailsOfMod:(NSMutableDictionary *)item completion:(void (^)(NSError *))completion {
    // Subclasses must implement
    [self doesNotRecognizeSelector:_cmd];
}

- (void)installModpackFromDetail:(NSDictionary *)modDetail atIndex:(NSUInteger)selectedVersion {
    // Default implementation that can be overridden
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
    dispatch_queue_t extractionQueue = dispatch_queue_create("com.modpack.extraction", DISPATCH_QUEUE_CONCURRENT);
    
    // Add extraction task UI
    dispatch_async(dispatch_get_main_queue(), ^{
        [downloader.fileList addObject:@"Extracting modpack index"];
        NSProgress *indexProgress = [NSProgress progressWithTotalUnitCount:1];
        indexProgress.kind = NSProgressKindFile;
        [downloader.progressList addObject:indexProgress];
        [downloader.progress addChild:indexProgress withPendingUnitCount:1];
    });
    
    // Extract on background queue
    dispatch_async(extractionQueue, ^{
        NSError *error;
        UZKArchive *archive = [[UZKArchive alloc] initWithPath:packagePath error:&error];
        if (error) {
            dispatch_async(dispatch_get_main_queue(), ^{
                [downloader finishDownloadWithErrorString:[NSString stringWithFormat:@"Failed to open modpack package: %@", error.localizedDescription]];
            });
            return;
        }

        // Extract and parse manifest
        NSString *manifestFilename = [self getManifestFilename];
        NSData *manifestData = [archive extractDataFromFile:manifestFilename error:&error];
        if (!manifestData) {
            dispatch_async(dispatch_get_main_queue(), ^{
                [downloader finishDownloadWithErrorString:@"Failed to extract modpack manifest"];
            });
            return;
        }
        
        NSDictionary *manifest = [NSJSONSerialization JSONObjectWithData:manifestData options:0 error:&error];
        if (error) {
            dispatch_async(dispatch_get_main_queue(), ^{
                [downloader finishDownloadWithErrorString:@"Failed to parse modpack manifest"];
            });
            return;
        }

        // Process manifest through template method
        NSError *processError = nil;
        NSDictionary *processedManifest = [self processManifest:manifest error:&processError];
        
        if (processError) {
            dispatch_async(dispatch_get_main_queue(), ^{
                [downloader finishDownloadWithErrorString:[NSString stringWithFormat:@"Invalid modpack manifest: %@", processError.localizedDescription]];
            });
            return;
        }

        // Complete index extraction
        dispatch_async(dispatch_get_main_queue(), ^{
            NSProgress *indexProgress = [downloader.progressList lastObject];
            indexProgress.completedUnitCount = 1;
        });
        
        // Handle overrides extraction
        [self extractOverrides:archive toPath:destPath withDownloader:downloader];
        
        // Process mod files
        NSArray *files = [self getFilesFromManifest:processedManifest];
        if (files.count > 0) {
            [self downloadModFiles:files toPath:destPath withDownloader:downloader];
        } else {
            // Finalize installation even without mod files
            [self finalizeInstallation:processedManifest toPath:destPath withDownloader:downloader];
        }
    });
}

- (void)extractOverrides:(UZKArchive *)archive toPath:(NSString *)destPath withDownloader:(MinecraftResourceDownloadTask *)downloader {
    // This is a common implementation for extracting overrides
    dispatch_async(dispatch_get_main_queue(), ^{
        [downloader.fileList addObject:@"Extracting modpack overrides"];
        NSProgress *overridesProgress = [NSProgress progressWithTotalUnitCount:100];
        overridesProgress.kind = NSProgressKindFile;
        [downloader.progressList addObject:overridesProgress];
        [downloader.progress addChild:overridesProgress withPendingUnitCount:100];
    });
    
    NSError *extractError = nil;
    
    // Extract overrides
    [self extractArchive:archive directory:@"overrides" toPath:destPath progress:^(double progress) {
        dispatch_async(dispatch_get_main_queue(), ^{
            NSProgress *overridesProgress = downloader.progressList.count >= 2 ? downloader.progressList[1] : nil;
            if (overridesProgress) {
                overridesProgress.completedUnitCount = (int64_t)(progress * 100);
            }
        });
    } error:&extractError];
    
    // Optional extraction of client-specific files
    if (!extractError) {
        [ModpackUtils archive:archive extractDirectory:@"client-overrides" toPath:destPath error:nil];
    }
    
    // Delete the package file to free up space
    NSError *removeError = nil;
    [[NSFileManager defaultManager] removeItemAtPath:packagePath error:&removeError];
    if (removeError) {
        NSLog(@"[ModpackAPI] Warning: Failed to delete modpack package: %@", removeError);
    }
}

- (void)downloadModFiles:(NSArray *)files toPath:(NSString *)destPath withDownloader:(MinecraftResourceDownloadTask *)downloader {
    // Subclasses should implement this
    [self doesNotRecognizeSelector:_cmd];
}

- (void)finalizeInstallation:(NSDictionary *)manifest toPath:(NSString *)destPath withDownloader:(MinecraftResourceDownloadTask *)downloader {
    // Subclasses should implement this
    [self doesNotRecognizeSelector:_cmd];
}

@end

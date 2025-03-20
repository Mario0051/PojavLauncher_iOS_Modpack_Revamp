#include <CommonCrypto/CommonDigest.h>

#import "authenticator/BaseAuthenticator.h"
#import "installer/modpack/ModpackAPI.h"
#import "AFNetworking.h"
#import "LauncherNavigationController.h"
#import "LauncherPreferences.h"
#import "MinecraftResourceDownloadTask.h"
#import "MinecraftResourceUtils.h"
#import "ios_uikit_bridge.h"
#import "PLProfiles.h"
#import "utils.h"
#import <objc/runtime.h>

// Static key for objc association
static const void *kIsTrackedByTaskKey = &kIsTrackedByTaskKey;

@interface MinecraftResourceDownloadTask ()
@property(nonatomic, readwrite) AFURLSessionManager* manager;
@property(nonatomic, strong) NSLock *progressLock; // Lock for synchronizing progress updates
@property(nonatomic, strong) NSLock *fileListLock; // Lock for synchronizing file list updates
@end

@implementation MinecraftResourceDownloadTask

- (instancetype)init {
    self = [super init];
    if (self) {
        // Initialize with safer session configuration
        NSURLSessionConfiguration *configuration = [NSURLSessionConfiguration defaultSessionConfiguration];
        configuration.timeoutIntervalForRequest = 86400;
        configuration.HTTPMaximumConnectionsPerHost = 6; // Limit concurrent connections
        self.manager = [[AFURLSessionManager alloc] initWithSessionConfiguration:configuration];
        
        // Initialize collections with thread safety in mind
        self.fileList = [NSMutableArray new];
        self.progressList = [NSMutableArray new];
        
        // Initialize lock objects for thread safety
        self.progressLock = [[NSLock alloc] init];
        self.fileListLock = [[NSLock alloc] init];
        
        // Initialize progress tracking
        self.progress = [NSProgress new];
        self.progress.totalUnitCount = 0;
        self.progress.cancellable = YES;
        
        // Initialize text progress for UI updates
        self.textProgress = [NSProgress new];
        self.textProgress.totalUnitCount = 0;
        self.textProgress.cancellable = YES;
    }
    return self;
}

- (void)prepareForDownload {
    [self.progressLock lock];
    // Reset progress tracking
    self.progress = [NSProgress new];
    self.progress.totalUnitCount = 0; // Start with 0 and add as we go
    self.progress.cancellable = YES;
    
    // Reset text progress for UI
    self.textProgress = [NSProgress new];
    self.textProgress.totalUnitCount = 0;
    self.textProgress.cancellable = YES;
    [self.progressLock unlock];
    
    // Reset tracking lists
    [self.fileListLock lock];
    [self.fileList removeAllObjects];
    [self.progressList removeAllObjects];
    [self.fileListLock unlock];
}

- (NSURLSessionDownloadTask *)createDownloadTask:(NSString *)url 
                                           size:(NSUInteger)size 
                                            sha:(NSString *)sha 
                                        altName:(NSString *)altName 
                                         toPath:(NSString *)path 
                                        success:(void (^)(void))success
                                        failure:(void (^)(NSError *error))failure {
    @autoreleasepool {
        // Safety check for invalid URL
        if (!url || url.length == 0) {
            NSLog(@"[MCDL] Error: Invalid or empty download URL");
            NSError *urlError = [NSError errorWithDomain:@"net.kdt.pojavlauncher" 
                                                code:1001 
                                            userInfo:@{NSLocalizedDescriptionKey: @"Invalid download URL"}];
            if (failure) {
                failure(urlError);
            } else {
                [self finishDownloadWithErrorString:@"Invalid download URL"];
            }
            return nil;
        }
        
        // Check if file already exists and has correct SHA1
        BOOL fileExists = [NSFileManager.defaultManager fileExistsAtPath:path];
        
        if (fileExists && [self checkSHA:sha forFile:path altName:altName]) {
            if (success) {
                success();
            }
            return nil;
        } else if (![self checkAccessWithDialog:YES]) {
            return nil;
        }

        // Use filename as display name if no alternate name provided
        NSString *name = altName ?: path.lastPathComponent;
        
        // Create URL request
        NSURL *requestURL = [NSURL URLWithString:url];
        if (!requestURL) {
            NSLog(@"[MCDL] Error: Invalid download URL format: %@", url);
            NSError *urlError = [NSError errorWithDomain:@"net.kdt.pojavlauncher" 
                                                code:1001 
                                            userInfo:@{NSLocalizedDescriptionKey: @"Invalid download URL format"}];
            if (failure) {
                failure(urlError);
            } else {
                [self finishDownloadWithErrorString:@"Invalid download URL format"];
            }
            return nil;
        }
        
        NSMutableURLRequest *request = [NSMutableURLRequest requestWithURL:requestURL];
        request.timeoutInterval = 60; // Set a reasonable timeout
        request.cachePolicy = NSURLRequestReloadIgnoringLocalCacheData; // Avoid cache issues
        
        __block NSProgress *downloadProgress = nil;
        __block BOOL sizeUpdated = NO;
        
        // Log detailed file information for debugging
        NSLog(@"[MCDL] Creating download task for %@, size: %lu, path: %@", name, (unsigned long)size, path);
        
        // Add to file list for UI tracking (before creating the task to avoid race conditions)
        [self.fileListLock lock];
        [self.fileList addObject:name];
        [self.fileListLock unlock];
        
        // Create a progress object for this download before the task is created
        downloadProgress = [NSProgress progressWithTotalUnitCount:size > 0 ? size : 1000000];
        downloadProgress.kind = NSProgressKindFile;
        
        // Add this progress to our tracking list
        [self.progressLock lock];
        [self.progressList addObject:downloadProgress];
        
        // Update overall progress total
        if (!self.progress) {
            self.progress = [NSProgress progressWithTotalUnitCount:downloadProgress.totalUnitCount];
        } else {
            self.progress.totalUnitCount += downloadProgress.totalUnitCount;
        }
        
        if (!self.textProgress) {
            self.textProgress = [NSProgress progressWithTotalUnitCount:downloadProgress.totalUnitCount];
        } else {
            self.textProgress.totalUnitCount = self.progress.totalUnitCount;
        }
        
        // Add the progress as a child to our overall progress
        [self.progress addChild:downloadProgress withPendingUnitCount:downloadProgress.totalUnitCount];
        [self.progressLock unlock];
        
        // Mark the progress object as tracked by this task
        objc_setAssociatedObject(downloadProgress, kIsTrackedByTaskKey, @YES, OBJC_ASSOCIATION_RETAIN_NONATOMIC);
        
        // Create download task with proper completion handling
        __weak typeof(self) weakSelf = self;
        NSURLSessionDownloadTask *task = [self.manager downloadTaskWithRequest:request progress:^(NSProgress * _Nonnull taskProgress) {
            // Update progress for this specific task
            if (taskProgress && downloadProgress) {
                [weakSelf.progressLock lock];
                
                // Update completion amount with safeguards
                CGFloat fraction = taskProgress.fractionCompleted;
                if (!isnan(fraction) && fraction >= 0 && fraction <= 1.0) {
                    downloadProgress.completedUnitCount = (NSInteger)(downloadProgress.totalUnitCount * fraction);
                    
                    // Also update text progress
                    if (weakSelf.textProgress) {
                        weakSelf.textProgress.completedUnitCount = weakSelf.progress.completedUnitCount;
                    }
                }
                
                [weakSelf.progressLock unlock];
            }
        } destination:^NSURL * _Nonnull(NSURL * _Nonnull targetPath, NSURLResponse * _Nonnull response) {
            NSLog(@"[MCDL] Downloading %@, expected length: %lld", name, response.expectedContentLength);
            
            // If size wasn't provided but response has size info, update progress
            if (size == 0 && response.expectedContentLength > 0) {
                NSUInteger actualSize = (NSUInteger)response.expectedContentLength;
                [weakSelf.progressLock lock];
                
                // Update progress size and overall progress total
                NSUInteger oldSize = downloadProgress.totalUnitCount;
                downloadProgress.totalUnitCount = actualSize;
                
                // Update parent progress total
                if (weakSelf.progress) {
                    weakSelf.progress.totalUnitCount = weakSelf.progress.totalUnitCount - oldSize + actualSize;
                }
                
                if (weakSelf.textProgress) {
                    weakSelf.textProgress.totalUnitCount = weakSelf.progress.totalUnitCount;
                }
                
                sizeUpdated = YES;
                [weakSelf.progressLock unlock];
                
                NSLog(@"[MCDL] Using response size: %lu for %@", (unsigned long)actualSize, name);
            }
            
            // Create directory structure if needed
            NSError *dirError;
            NSString *dirPath = [path stringByDeletingLastPathComponent];
            BOOL success = [NSFileManager.defaultManager createDirectoryAtPath:dirPath 
                                                withIntermediateDirectories:YES 
                                                                 attributes:nil 
                                                                      error:&dirError];
            if (!success) {
                NSLog(@"[MCDL] Warning: Could not create directory for %@: %@", name, dirError.localizedDescription);
            }
            
            // Remove existing file if it exists
            if ([NSFileManager.defaultManager fileExistsAtPath:path]) {
                NSError *removeError;
                [NSFileManager.defaultManager removeItemAtPath:path error:&removeError];
                if (removeError) {
                    NSLog(@"[MCDL] Warning: Could not remove existing file %@: %@", path, removeError.localizedDescription);
                }
            }
            
            return [NSURL fileURLWithPath:path];
        } completionHandler:^(NSURLResponse * _Nonnull response, NSURL * _Nullable filePath, NSError * _Nullable error) {
            // Safely check if progress is cancelled
            BOOL isCancelled = NO;
            @try {
                isCancelled = weakSelf.progress.cancelled;
            } @catch (NSException *exception) {
                NSLog(@"[MCDL] Warning: Exception checking if progress is cancelled: %@", exception);
                isCancelled = NO;
            }
            
            if (isCancelled) {
                // Ignore any further errors when cancelled
                NSLog(@"[MCDL] Download cancelled for %@", name);
                return;
            } 
            
            if (error != nil) {
                NSLog(@"[MCDL] Download error for %@: %@", name, error.localizedDescription);
                if (failure) {
                    failure(error);
                } else {
                    [weakSelf finishDownloadWithError:error file:name];
                }
                return;
            }
            
            if (![weakSelf checkSHA:sha forFile:path altName:altName]) {
                NSError *shaError = [NSError errorWithDomain:@"net.kdt.pojavlauncher" 
                                                    code:1000 
                                                userInfo:@{NSLocalizedDescriptionKey: [NSString stringWithFormat:@"Failed to verify file %@: SHA1 mismatch", path.lastPathComponent]}];
                if (failure) {
                    failure(shaError);
                } else {
                    [weakSelf finishDownloadWithErrorString:[NSString stringWithFormat:@"Failed to verify file %@: SHA1 mismatch", path.lastPathComponent]];
                }
                return;
            }
            
            // If we didn't have an accurate size initially and didn't update it from the response
            if (!sizeUpdated && size == 0 && downloadProgress) {
                // Get the actual file size for more accurate progress reporting
                NSError *fileError;
                NSDictionary *fileAttrs = [NSFileManager.defaultManager attributesOfItemAtPath:path error:&fileError];
                if (!fileError && fileAttrs) {
                    NSUInteger fileSize = [fileAttrs fileSize];
                    NSLog(@"[MCDL] Updating progress with actual file size: %lu for %@", (unsigned long)fileSize, name);
                    
                    // Update progress with actual file size - safely
                    @try {
                        [weakSelf.progressLock lock];
                        if (fileSize > 0 && fileSize != downloadProgress.totalUnitCount && weakSelf.progress) {
                            // Add the difference to total progress
                            NSUInteger oldSize = downloadProgress.totalUnitCount;
                            weakSelf.progress.totalUnitCount += (fileSize - oldSize);
                            
                            if (weakSelf.textProgress) {
                                weakSelf.textProgress.totalUnitCount = weakSelf.progress.totalUnitCount;
                            }
                            
                            downloadProgress.totalUnitCount = fileSize;
                        }
                        [weakSelf.progressLock unlock];
                    } @catch (NSException *exception) {
                        [weakSelf.progressLock unlock];
                        NSLog(@"[MCDL] Warning: Exception updating progress size: %@", exception);
                    }
                }
            }
            
            // Ensure progress is marked as complete
            @try {
                [weakSelf.progressLock lock];
                downloadProgress.completedUnitCount = downloadProgress.totalUnitCount;
                
                // Update text progress
                if (weakSelf.textProgress) {
                    weakSelf.textProgress.completedUnitCount = weakSelf.progress.completedUnitCount;
                }
                [weakSelf.progressLock unlock];
            } @catch (NSException *exception) {
                [weakSelf.progressLock unlock];
                NSLog(@"[MCDL] Warning: Exception setting progress as complete: %@", exception);
            }
            
            NSLog(@"[MCDL] Download completed for %@", name);
            if (success) {
                success();
            }
        }];

        return task;
    }
}

// Compatibility method that calls the full version without failure callback
- (NSURLSessionDownloadTask *)createDownloadTask:(NSString *)url 
                                           size:(NSUInteger)size 
                                            sha:(NSString *)sha 
                                        altName:(NSString *)altName 
                                         toPath:(NSString *)path 
                                        success:(void (^)(void))success {
    return [self createDownloadTask:url size:size sha:sha altName:altName toPath:path success:success failure:nil];
}

// Compatibility method for older code
- (NSURLSessionDownloadTask *)createDownloadTask:(NSString *)url 
                                           size:(NSUInteger)size 
                                            sha:(NSString *)sha 
                                        altName:(NSString *)altName 
                                         toPath:(NSString *)path {
    return [self createDownloadTask:url size:size sha:sha altName:altName toPath:path success:nil failure:nil];
}

- (void)addDownloadTaskToProgress:(NSURLSessionDownloadTask *)task size:(NSUInteger)size {
    // Safety check for nil task
    if (!task) {
        NSLog(@"[MCDL] Warning: Cannot add nil task to progress tracking");
        return;
    }
    
    NSProgress *progress = [self.manager downloadProgressForTask:task];
    // Safety check for nil progress
    if (!progress) {
        NSLog(@"[MCDL] Warning: Could not get progress for download task, creating a new one");
        progress = [NSProgress progressWithTotalUnitCount:1];
    }
    
    // Check if this progress is already a child of another progress
    // This can be done by checking a custom property we can associate with the progress
    NSNumber *isTracked = objc_getAssociatedObject(progress, kIsTrackedByTaskKey);
    if (isTracked && [isTracked boolValue]) {
        NSLog(@"[MCDL] Warning: Progress is already being tracked, skipping");
        return;
    }
    
    // Mark this progress as tracked BEFORE adding it as a child to prevent race conditions
    objc_setAssociatedObject(progress, kIsTrackedByTaskKey, @YES, OBJC_ASSOCIATION_RETAIN_NONATOMIC);
    
    [self.progressLock lock];
    
    NSUInteger fileSize = size > 0 ? size : 1000000; // Use 1MB as minimum placeholder
    progress.kind = NSProgressKindFile;
    progress.totalUnitCount = fileSize;
    [self.progressList addObject:progress];
    
    // Create main progress if it doesn't exist yet
    if (!self.progress) {
        self.progress = [NSProgress progressWithTotalUnitCount:fileSize];
    } else {
        // Update the total unit count for the parent progress separately
        self.progress.totalUnitCount += fileSize;
    }
    
    // Also update text progress
    if (!self.textProgress) {
        self.textProgress = [NSProgress progressWithTotalUnitCount:fileSize];
    } else {
        self.textProgress.totalUnitCount = self.progress.totalUnitCount;
    }
    
    // Safely check if progress is cancelled
    BOOL isCancelled = NO;
    @try {
        isCancelled = self.progress.cancelled;
    } @catch (NSException *exception) {
        NSLog(@"[MCDL] Warning: Exception checking if progress is cancelled: %@", exception);
        isCancelled = NO;
    }
    
    if (!isCancelled) {
        // Try-catch to handle case where progress is already a child
        @try {
            [self.progress addChild:progress withPendingUnitCount:fileSize];
        } @catch (NSException *exception) {
            NSLog(@"[MCDL] Warning: Exception adding child progress: %@", exception);
            // Just log the exception, don't rethrow
        }
    }
    
    [self.progressLock unlock];
}

- (void)finishDownloadWithError:(NSError *)error file:(NSString *)file {
    NSString *errorStr = [NSString stringWithFormat:localize(@"launcher.mcl.error_download", NULL), file, error.localizedDescription];
    NSLog(@"[MCDL] Error: %@ %@", errorStr, NSThread.callStackSymbols);
    [self finishDownloadWithErrorString:errorStr];
}

- (void)finishDownloadWithErrorString:(NSString *)error {
    // Safely cancel progress
    @try {
        [self.progressLock lock];
        [self.progress cancel];
        [self.textProgress cancel];
        [self.progressLock unlock];
    } @catch (NSException *exception) {
        [self.progressLock unlock];
        NSLog(@"[MCDL] Warning: Exception cancelling progress: %@", exception);
    }
    
    [self.manager invalidateSessionCancelingTasks:YES resetSession:YES];
    showDialog(localize(@"Error", nil), error);
    if (self.handleError) {
        self.handleError();
    }
}

// Check if the account has permission to download
- (BOOL)checkAccessWithDialog:(BOOL)show {
    // for now
    BOOL accessible = [BaseAuthenticator.current.authData[@"username"] hasPrefix:@"Demo."] || BaseAuthenticator.current.authData[@"xboxGamertag"] != nil;
    if (!accessible) {
        @try {
            [self.progressLock lock];
            [self.progress cancel];
            [self.textProgress cancel];
            [self.progressLock unlock];
        } @catch (NSException *exception) {
            [self.progressLock unlock];
            NSLog(@"[MCDL] Warning: Exception cancelling progress: %@", exception);
        }
        
        if (show) {
            [self finishDownloadWithErrorString:@"Minecraft can't be legally installed when logged in with a local account. Please switch to an online account to continue."];
        }
    }
    return accessible;
}

// Check SHA of the file with logging option
- (BOOL)checkSHAIgnorePref:(NSString *)sha forFile:(NSString *)path altName:(NSString *)altName logSuccess:(BOOL)logSuccess {
    if (sha.length == 0) {
        // When sha = skip, only check for file existence
        BOOL existence = [NSFileManager.defaultManager fileExistsAtPath:path];
        if (existence) {
            NSLog(@"[MCDL] Warning: couldn't find SHA for %@, have to assume it's good.", path);
        }
        return existence;
    }

    NSData *data = [NSData dataWithContentsOfFile:path];
    if (data == nil) {
        NSLog(@"[MCDL] SHA1 checker: file doesn't exist: %@", altName ? altName : path.lastPathComponent);
        return NO;
    }

    unsigned char digest[CC_SHA1_DIGEST_LENGTH];
    CC_SHA1(data.bytes, (CC_LONG)data.length, digest);
    NSMutableString *localSHA = [NSMutableString stringWithCapacity:CC_SHA1_DIGEST_LENGTH * 2];
    for(int i = 0; i < CC_SHA1_DIGEST_LENGTH; i++) {
        [localSHA appendFormat:@"%02x", digest[i]];
    }

    BOOL check = [sha isEqualToString:localSHA];
    if (!check || (getPrefBool(@"general.debug_logging") && logSuccess)) {
        NSLog(@"[MCDL] SHA1 %@ for %@%@",
          (check ? @"passed" : @"failed"), 
          (altName ? altName : path.lastPathComponent),
          (check ? @"" : [NSString stringWithFormat:@" (expected: %@, got: %@)", sha, localSHA]));
    }
    return check;
}

// Check SHA of the file respecting user preferences
- (BOOL)checkSHA:(NSString *)sha forFile:(NSString *)path altName:(NSString *)altName logSuccess:(BOOL)logSuccess {
    if (getPrefBool(@"general.check_sha")) {
        return [self checkSHAIgnorePref:sha forFile:path altName:altName logSuccess:logSuccess];
    } else {
        return [NSFileManager.defaultManager fileExistsAtPath:path];
    }
}

// Simplified SHA check with default logging behavior
- (BOOL)checkSHA:(NSString *)sha forFile:(NSString *)path altName:(NSString *)altName {
    return [self checkSHA:sha forFile:path altName:altName logSuccess:altName==nil];
}

- (void)downloadVersion:(NSDictionary *)version {
    [self prepareForDownload];
    [self downloadVersionMetadata:version success:^{
        [self downloadAssetMetadataWithSuccess:^{
            NSArray *libTasks = [self downloadClientLibraries];
            NSArray *assetTasks = [self downloadClientAssets];
            
            @synchronized(self) {
                // If we have nothing to download, add a completed marker
                if (self.progress.totalUnitCount == 0) {
                    [self.progressLock lock];
                    self.progress.totalUnitCount = 1;
                    self.progress.completedUnitCount = 1;
                    self.textProgress.totalUnitCount = 1;
                    self.textProgress.completedUnitCount = 1;
                    [self.progressLock unlock];
                    
                    // Add completion marker
                    [self.fileListLock lock];
                    [self.fileList addObject:@"Complete"];
                    NSProgress *completeProgress = [NSProgress progressWithTotalUnitCount:1];
                    completeProgress.completedUnitCount = 1;
                    [self.progressList addObject:completeProgress];
                    [self.fileListLock unlock];
                    return;
                }
            }
            
            // Start all download tasks in batches to avoid overwhelming the network
            NSInteger batchSize = 10;
            NSInteger totalTasks = libTasks.count + assetTasks.count;
            
            // Run batches in the background
            dispatch_async(dispatch_get_global_queue(DISPATCH_QUEUE_PRIORITY_DEFAULT, 0), ^{
                // First process library tasks which are usually more important
                for (NSInteger i = 0; i < libTasks.count; i += batchSize) {
                    NSInteger end = MIN(i + batchSize, libTasks.count);
                    for (NSInteger j = i; j < end; j++) {
                        if (self.progress.cancelled) {
                            return;
                        }
                        [(NSURLSessionDownloadTask *)libTasks[j] resume];
                    }
                    
                    // Small delay between batches
                    [NSThread sleepForTimeInterval:0.5];
                }
                
                // Then process asset tasks
                for (NSInteger i = 0; i < assetTasks.count; i += batchSize) {
                    NSInteger end = MIN(i + batchSize, assetTasks.count);
                    for (NSInteger j = i; j < end; j++) {
                        if (self.progress.cancelled) {
                            return;
                        }
                        [(NSURLSessionDownloadTask *)assetTasks[j] resume];
                    }
                    
                    // Small delay between batches
                    [NSThread sleepForTimeInterval:0.5];
                }
            });
            
            // Clean up large metadata we don't need anymore
            [self.metadata removeObjectForKey:@"assetIndexObj"];
        }];
    }];
}

- (void)downloadVersionMetadata:(NSDictionary *)version success:(void (^)(void))success {
    // Download base json
    NSString *versionStr = version[@"id"];
    if ([versionStr isEqualToString:@"latest-release"]) {
        versionStr = getPrefObject(@"internal.latest_version.release");
    } else if ([versionStr isEqualToString:@"latest-snapshot"]) {
        versionStr = getPrefObject(@"internal.latest_version.snapshot");
    }

    NSString *path = [NSString stringWithFormat:@"%1$s/versions/%2$@/%2$@.json", getenv("POJAV_GAME_DIR"), versionStr];
    // Find it again to resolve latest-*
    version = (id)[MinecraftResourceUtils findVersion:versionStr inList:remoteVersionList];

    // Create a wrapped success callback
    __weak typeof(self) weakSelf = self;
    void(^wrappedSuccess)(void) = ^{
        weakSelf.metadata = parseJSONFromFile(path);
        if (weakSelf.metadata[@"NSErrorObject"]) {
            [weakSelf finishDownloadWithErrorString:[weakSelf.metadata[@"NSErrorObject"] localizedDescription]];
            return;
        }
        if (weakSelf.metadata[@"inheritsFrom"]) {
            NSMutableDictionary *inheritsFromDict = parseJSONFromFile([NSString stringWithFormat:@"%1$s/versions/%2$@/%2$@.json", getenv("POJAV_GAME_DIR"), weakSelf.metadata[@"inheritsFrom"]]);
            if (inheritsFromDict) {
                [MinecraftResourceUtils processVersion:weakSelf.metadata inheritsFrom:inheritsFromDict];
                weakSelf.metadata = inheritsFromDict;
            }
        }
        [MinecraftResourceUtils tweakVersionJson:weakSelf.metadata];
        success();
    };

    if (!version) {
        // This is likely local version, check if json exists and has inheritsFrom
        NSMutableDictionary *json = parseJSONFromFile(path);
        if (json[@"NSErrorObject"]) {
            [self finishDownloadWithErrorString:[json[@"NSErrorObject"] localizedDescription]];
            return;
        } else if (json[@"inheritsFrom"]) {
            version = (id)[MinecraftResourceUtils findVersion:json[@"inheritsFrom"] inList:remoteVersionList];
            path = [NSString stringWithFormat:@"%1$s/versions/%2$@/%2$@.json", getenv("POJAV_GAME_DIR"), json[@"inheritsFrom"]];
        } else {
            wrappedSuccess();
            return;
        }
    }

    versionStr = version[@"id"];
    NSString *url = version[@"url"];
    NSString *sha = url.stringByDeletingLastPathComponent.lastPathComponent;
    NSUInteger size = [version[@"size"] unsignedLongLongValue];

    NSURLSessionDownloadTask *task = [self createDownloadTask:url size:size sha:sha altName:versionStr toPath:path success:wrappedSuccess];
    if (task) {
        [task resume];
    }
}

- (void)downloadAssetMetadataWithSuccess:(void (^)(void))success {
    NSDictionary *assetIndex = self.metadata[@"assetIndex"];
    if (!assetIndex) {
        success();
        return;
    }
    
    NSString *name = [NSString stringWithFormat:@"assets/indexes/%@.json", assetIndex[@"id"]];
    NSString *path = [@(getenv("POJAV_GAME_DIR")) stringByAppendingPathComponent:name];
    NSString *url = assetIndex[@"url"];
    NSString *sha = url.stringByDeletingLastPathComponent.lastPathComponent;
    NSUInteger size = [assetIndex[@"size"] unsignedLongLongValue];
    
    // Create a wrapped success callback to update phase
    __weak typeof(self) weakSelf = self;
    void(^wrappedSuccess)(void) = ^{
        weakSelf.metadata[@"assetIndexObj"] = parseJSONFromFile(path);
        success();
    };
    
    NSURLSessionDownloadTask *task = [self createDownloadTask:url size:size sha:sha altName:name toPath:path success:wrappedSuccess];
    if (task) {
        [task resume];
    } else {
        // If no task was created (file already exists), continue
        wrappedSuccess();
    }
}

- (NSArray *)downloadClientLibraries {
    NSMutableArray *tasks = [NSMutableArray new];
    
    for (NSDictionary *library in self.metadata[@"libraries"]) {
        NSString *name = library[@"name"];

        NSMutableDictionary *artifact = library[@"downloads"][@"artifact"];
        if (artifact == nil && [name containsString:@":"]) {
            NSLog(@"[MCDL] Unknown artifact object for %@, attempting to generate one", name);
            artifact = [[NSMutableDictionary alloc] init];
            NSString *prefix = library[@"url"] == nil ? @"https://libraries.minecraft.net/" : [library[@"url"] stringByReplacingOccurrencesOfString:@"http://" withString:@"https://"];
            NSArray *libParts = [name componentsSeparatedByString:@":"];
            artifact[@"path"] = [NSString stringWithFormat:@"%1$@/%2$@/%3$@/%2$@-%3$@.jar", [libParts[0] stringByReplacingOccurrencesOfString:@"." withString:@"/"], libParts[1], libParts[2]];
            artifact[@"url"] = [NSString stringWithFormat:@"%@%@", prefix, artifact[@"path"]];
            artifact[@"sha1"] = library[@"checksums"][0];
        }

        NSString *path = [NSString stringWithFormat:@"%s/libraries/%@", getenv("POJAV_GAME_DIR"), artifact[@"path"]];
        NSString *sha = artifact[@"sha1"];
        NSUInteger size = [artifact[@"size"] unsignedLongLongValue];
        NSString *url = artifact[@"url"];
        if ([library[@"skip"] boolValue]) {
            NSLog(@"[MDCL] Skipped library %@", name);
            continue;
        }

        NSURLSessionDownloadTask *task = [self createDownloadTask:url size:size sha:sha altName:name toPath:path success:nil];
        if (task) {
            [tasks addObject:task];
        } else if (self.progress.cancelled) {
            return nil;
        }
    }
    return tasks;
}

- (NSArray *)downloadClientAssets {
    NSMutableArray *tasks = [NSMutableArray new];
    NSDictionary *assets = self.metadata[@"assetIndexObj"];
    
    if (!assets) {
        return @[];
    }
    
    for (NSString *name in assets[@"objects"]) {
        NSDictionary *object = assets[@"objects"][name];
        NSString *hash = object[@"hash"];
        NSString *pathname = [NSString stringWithFormat:@"%@/%@", [hash substringToIndex:2], hash];
        NSUInteger size = [object[@"size"] unsignedLongLongValue];

        NSString *path;
        if ([assets[@"map_to_resources"] boolValue]) {
            path = [NSString stringWithFormat:@"%s/resources/%@", getenv("POJAV_GAME_DIR"), name];
        } else {
            path = [NSString stringWithFormat:@"%s/assets/objects/%@", getenv("POJAV_GAME_DIR"), pathname];
        }

        /* Special case for 1.19+
         * Since 1.19-pre1, setting the window icon on macOS invokes ObjC.
         * However, if an IOException occurs, it won't try to set.
         * We skip downloading the icon file to workaround this. */
        if ([name hasSuffix:@"/minecraft.icns"]) {
            [NSFileManager.defaultManager removeItemAtPath:path error:nil];
            continue;
        }

        NSString *url = [NSString stringWithFormat:@"https://resources.download.minecraft.net/%@", pathname];
        NSURLSessionDownloadTask *task = [self createDownloadTask:url size:size sha:hash altName:name toPath:path success:nil];
        if (task) {
            [tasks addObject:task];
        } else if (self.progress.cancelled) {
            return nil;
        }
    }
    return tasks;
}

- (void)downloadModpackFromAPI:(ModpackAPI *)api detail:(NSDictionary *)modDetail atIndex:(NSUInteger)selectedVersion {
    [self prepareForDownload];
    
    // Set flag in metadata that this is a modpack installation
    if (!self.metadata) {
        self.metadata = [NSMutableDictionary dictionary];
    }
    self.metadata[@"isModpackInstall"] = @YES;

    NSString *url = modDetail[@"versionUrls"][selectedVersion];
    NSUInteger size = [modDetail[@"versionSizes"][selectedVersion] unsignedLongLongValue];
    NSString *sha = modDetail[@"versionHashes"][selectedVersion];
    
    // Use the original title without converting to lowercase or replacing spaces with underscores
    NSString *name = [modDetail[@"title"] stringByTrimmingCharactersInSet:NSCharacterSet.whitespaceCharacterSet];
    // For the filesystem paths, create a sanitized version of the name (for the zip file only)
    NSString *sanitizedName = [[name lowercaseString] stringByReplacingOccurrencesOfString:@" " withString:@"_"];
    NSString *packagePath = [NSTemporaryDirectory() stringByAppendingFormat:@"/%@.zip", sanitizedName];
    
    // Get the game directory for this modpack
    NSString *gameDir = [PLProfiles uniqueGameDirForProfileName:name];
    
    // Get the full absolute path where we'll extract the modpack
    NSString *destPath = [PLProfiles fullPathForProfileWithName:name gameDir:gameDir];
    
    // Store the game directory in metadata for proper profile creation
    self.metadata[@"gameDir"] = gameDir;
    
    // Create a clear display name for progress reporting
    NSString *displayName = [NSString stringWithFormat:@"Downloading modpack: %@", name];
    
    // Create a wrapped success callback that transitions to extraction phase
    __weak typeof(self) weakSelf = self;
    void(^modpackSuccess)(void) = ^{
        // Add placeholder progress for extraction phase - reset overall progress
        @synchronized(weakSelf) {
            [weakSelf.progressLock lock];
            weakSelf.progress.totalUnitCount = 1;
            weakSelf.progress.completedUnitCount = 0;
            weakSelf.textProgress.totalUnitCount = 1;
            weakSelf.textProgress.completedUnitCount = 0;
            [weakSelf.progressLock unlock];
        }
        
        NSLog(@"[MCDL] Modpack download complete, proceeding to extraction.");
        // Use the API to handle extraction and installation
        [api downloader:weakSelf submitDownloadTasksFromPackage:packagePath toPath:destPath];
    };
    
    // Failure callback to handle retries for modpack download
    void(^modpackFailure)(NSError *error) = ^(NSError *error) {
        NSLog(@"[MCDL] Failed to download modpack: %@. Retrying...", error.localizedDescription);
        
        // Add retry attempt to file list for UI visibility
        [weakSelf.fileListLock lock];
        [weakSelf.fileList addObject:[NSString stringWithFormat:@"Retrying download for %@", name]];
        [weakSelf.fileListLock unlock];
        
        // Create a retry task
        NSURLSessionDownloadTask *retryTask = [weakSelf createDownloadTask:url 
                                                                     size:size 
                                                                      sha:sha 
                                                                  altName:[NSString stringWithFormat:@"Downloading %@ (retry)", name]
                                                                   toPath:packagePath 
                                                                  success:modpackSuccess
                                                                  failure:^(NSError *retryError) {
            // If retry also fails, show error
            [weakSelf finishDownloadWithErrorString:[NSString stringWithFormat:@"Failed to download modpack after retry: %@", retryError.localizedDescription]];
        }];
        
        if (retryTask) {
            [retryTask resume];
        } else {
            [weakSelf finishDownloadWithErrorString:@"Failed to create retry download task for modpack"];
        }
    };

    NSURLSessionDownloadTask *task = [self createDownloadTask:url 
                                                        size:size 
                                                         sha:sha 
                                                     altName:displayName
                                                      toPath:packagePath 
                                                     success:modpackSuccess
                                                     failure:modpackFailure];

    if (task) {
        [task resume];
    }
}

@end

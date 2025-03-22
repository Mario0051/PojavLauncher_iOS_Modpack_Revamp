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
static const NSInteger kMaxConcurrentDownloads = 6; // Limit concurrent downloads

@interface MinecraftResourceDownloadTask ()
@property(nonatomic, readwrite) AFURLSessionManager* manager;
@property(nonatomic, strong) NSLock *progressLock; // Lock for synchronizing progress updates
@property(nonatomic, strong) NSLock *fileListLock; // Lock for synchronizing file list updates
@property(nonatomic, strong) dispatch_queue_t downloadQueue; // Serial queue for managing downloads
@property(nonatomic, strong) NSMutableArray *pendingDownloads; // Queue of pending downloads
@property(nonatomic, assign) NSInteger activeDownloads; // Track active downloads
@property(nonatomic, strong) NSTimer *uiUpdateTimer; // Timer for batched UI updates
@property(nonatomic, assign) BOOL needsUIUpdate; // Flag for pending UI updates
@end

@implementation MinecraftResourceDownloadTask

- (instancetype)init {
    self = [super init];
    if (self) {
        // Initialize with safer session configuration
        NSURLSessionConfiguration *configuration = [NSURLSessionConfiguration defaultSessionConfiguration];
        configuration.timeoutIntervalForRequest = 60; // Shorter default timeout
        configuration.timeoutIntervalForResource = 300; // 5 minutes max for resource
        configuration.HTTPMaximumConnectionsPerHost = kMaxConcurrentDownloads; // Limit concurrent connections
        configuration.requestCachePolicy = NSURLRequestReloadIgnoringLocalCacheData; // Avoid cache issues
        
        self.manager = [[AFURLSessionManager alloc] initWithSessionConfiguration:configuration];
        
        // Initialize collections with thread safety in mind
        self.fileList = [NSMutableArray new];
        self.progressList = [NSMutableArray new];
        self.pendingDownloads = [NSMutableArray new];
        self.activeDownloads = 0;
        
        // Initialize lock objects for thread safety
        self.progressLock = [[NSLock alloc] init];
        self.fileListLock = [[NSLock alloc] init];
        
        // Create serial queue for managing downloads
        self.downloadQueue = dispatch_queue_create("net.kdt.pojavlauncher.downloadQueue", DISPATCH_QUEUE_SERIAL);
        
        // Initialize progress tracking
        self.progress = [NSProgress new];
        self.progress.totalUnitCount = 0;
        self.progress.cancellable = YES;
        
        // Initialize text progress for UI updates
        self.textProgress = [NSProgress new];
        self.textProgress.totalUnitCount = 0;
        self.textProgress.cancellable = YES;
        
        // Setup timer for batched UI updates
        self.needsUIUpdate = NO;
        self.uiUpdateTimer = [NSTimer scheduledTimerWithTimeInterval:0.2 
                                                             target:self 
                                                           selector:@selector(processBatchedUIUpdates) 
                                                           userInfo:nil 
                                                            repeats:YES];
    }
    return self;
}

- (void)dealloc {
    [self.uiUpdateTimer invalidate];
    self.uiUpdateTimer = nil;
}

- (void)processBatchedUIUpdates {
    if (!self.needsUIUpdate) return;
    
    // Send a notification for UI components to update
    dispatch_async(dispatch_get_main_queue(), ^{
        [NSNotificationCenter.defaultCenter postNotificationName:@"DownloadProgressUpdated" object:self];
        self.needsUIUpdate = NO;
        
        // Update text progress
        [self.progressLock lock];
        if (self.textProgress && self.progress) {
            self.textProgress.completedUnitCount = self.progress.completedUnitCount;
        }
        [self.progressLock unlock];
    });
}

- (void)prepareForDownload {
    // Reset progress tracking
    @synchronized(self) {
        // Reset progress tracking
        self.progress = [NSProgress new];
        self.progress.totalUnitCount = 0; // Start with 0 and add as we go
        self.progress.cancellable = YES;
        
        // Reset text progress for UI
        self.textProgress = [NSProgress new];
        self.textProgress.totalUnitCount = 0;
        self.textProgress.cancellable = YES;
    }
    
    // Reset tracking lists
    @synchronized(self.fileList) {
        [self.fileList removeAllObjects];
    }
    
    @synchronized(self.progressList) {
        [self.progressList removeAllObjects];
    }
    
    // Reset download tracking
    @synchronized(self.pendingDownloads) {
        [self.pendingDownloads removeAllObjects];
        self.activeDownloads = 0;
    }
}


- (void)processNextDownloadInQueue {
    @synchronized(self.pendingDownloads) {
        // Check if we're at the concurrency limit
        if (self.activeDownloads >= kMaxConcurrentDownloads || self.pendingDownloads.count == 0) {
            return;
        }
        
        // Check if download was cancelled
        BOOL isCancelled = NO;
        
        @try {
            isCancelled = self.progress.cancelled;
        } @catch (NSException *exception) {
            NSLog(@"[MCDL] Warning: Exception checking if progress is cancelled: %@", exception);
            isCancelled = NO;
        }
        
        if (isCancelled) {
            return;
        }
        
        // Get next download task
        NSURLSessionDownloadTask *nextTask = nil;
        if (self.pendingDownloads.count > 0) {
            nextTask = self.pendingDownloads[0];
            [self.pendingDownloads removeObjectAtIndex:0];
            self.activeDownloads++;
            
            // Resume task on a background queue to not block the serial queue
            dispatch_async(dispatch_get_global_queue(DISPATCH_QUEUE_PRIORITY_DEFAULT, 0), ^{
                [nextTask resume];
            });
        }
    }
}

- (NSURLSessionDownloadTask *)createDownloadTask:(NSString *)url 
                                          size:(NSUInteger)size 
                                           sha:(NSString *)sha 
                                       altName:(NSString *)altName 
                                        toPath:(NSString *)path 
                                       success:(void (^)(void))success
                                       failure:(void (^)(NSError *error))failure {
    @autoreleasepool {
        // Safety check for invalid URL with enhanced logging
        if (!url || url.length == 0) {
            NSLog(@"[MCDL] Error: Invalid or empty download URL");
            NSLog(@"[MCDL] File: %@, Path: %@", altName ?: @"(null)", path ?: @"(null)");
            NSLog(@"[MCDL] SHA: %@, Size: %lu", sha ?: @"(null)", (unsigned long)size);
            
            NSError *urlError = [NSError errorWithDomain:@"net.kdt.pojavlauncher" 
                                                   code:1001 
                                               userInfo:@{NSLocalizedDescriptionKey: @"Invalid download URL"}];
            if (failure) {
                dispatch_async(dispatch_get_global_queue(DISPATCH_QUEUE_PRIORITY_DEFAULT, 0), ^{
                    failure(urlError);
                });
            } else {
                [self finishDownloadWithErrorString:@"Invalid download URL"];
            }
            return nil;
        }
        
        // Log valid URL information for debugging
        NSLog(@"[MCDL] Creating download task - URL: %@", url);
        NSLog(@"[MCDL] File: %@, Path: %@", altName ?: @"(null)", path);
        
        // Check if file already exists and has correct SHA1 - with quick return
        BOOL fileExists = [NSFileManager.defaultManager fileExistsAtPath:path];
        
        if (fileExists && [self checkSHA:sha forFile:path altName:altName]) {
            // Optimization: Handle success callback on background thread
            if (success) {
                dispatch_async(dispatch_get_global_queue(DISPATCH_QUEUE_PRIORITY_DEFAULT, 0), ^{
                    success();
                });
                
                // Mark as needing UI update
                self.needsUIUpdate = YES;
            }
            return nil;
        } else if (![self checkAccessWithDialog:YES]) {
            return nil;
        }

        // Use filename as display name if no alternate name provided
        NSString *name = altName ?: path.lastPathComponent;
        
        // Create URL request with increased validity checks
        NSURL *requestURL = [NSURL URLWithString:url];
        if (!requestURL) {
            NSLog(@"[MCDL] Error: Invalid download URL format: %@", url);
            NSError *urlError = [NSError errorWithDomain:@"net.kdt.pojavlauncher" 
                                                   code:1001 
                                               userInfo:@{NSLocalizedDescriptionKey: @"Invalid download URL format"}];
            if (failure) {
                dispatch_async(dispatch_get_global_queue(DISPATCH_QUEUE_PRIORITY_DEFAULT, 0), ^{
                    failure(urlError);
                });
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
        
        // Add to file list for UI tracking (before creating the task to avoid race conditions)
        @synchronized(self.fileList) {
            [self.fileList addObject:name];
        }
        
        // Create a progress object for this download before the task is created
        downloadProgress = [NSProgress progressWithTotalUnitCount:size > 0 ? size : 1000000];
        downloadProgress.kind = NSProgressKindFile;
        
        // Add this progress to our tracking list - using synchronization for thread safety
        BOOL progressAdded = NO;
        
        @synchronized(self) {
            @try {
                @synchronized(self.progressList) {
                    [self.progressList addObject:downloadProgress];
                }
                
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
                progressAdded = YES;
            } @catch (NSException *exception) {
                NSLog(@"[MCDL] Exception adding progress: %@", exception);
            }
        }
        
        if (!progressAdded) {
            NSLog(@"[MCDL] Failed to add progress for %@", name);
            // If we couldn't add progress, still try to proceed with the download
        }
        
        // Mark the progress object as tracked by this task
        objc_setAssociatedObject(downloadProgress, kIsTrackedByTaskKey, @YES, OBJC_ASSOCIATION_RETAIN_NONATOMIC);
        
        // Create weak reference to self to avoid retain cycles
        __weak typeof(self) weakSelf = self;
        
        // Create download task with proper completion handling
        NSURLSessionDownloadTask *task = [self.manager downloadTaskWithRequest:request progress:^(NSProgress * _Nonnull taskProgress) {
            // Throttle progress updates to reduce overhead - only update if significant change
            static NSInteger lastReportedPercent = -1;
            NSInteger currentPercent = (NSInteger)(taskProgress.fractionCompleted * 100);
            
            if (currentPercent != lastReportedPercent && currentPercent % 5 == 0) { // Update every 5%
                lastReportedPercent = currentPercent;
                
                // Safely update progress with retry mechanism
                BOOL updated = NO;
                NSUInteger retryCount = 0;
                
                while (!updated && retryCount < 3) {
                    if (retryCount > 0) {
                        // Add short delay before retry
                        usleep(10000); // 10ms
                    }
                    
                    if (!weakSelf || !taskProgress || !downloadProgress) {
                        break; // Skip if objects are no longer valid
                    }
                    
                    // Make sure the task is still running
                    if (taskProgress.cancelled || taskProgress.finished) {
                        break;
                    }
                    
                    @synchronized(weakSelf) {
                        @try {
                            // Update completion amount with safeguards
                            CGFloat fraction = taskProgress.fractionCompleted;
                            if (!isnan(fraction) && fraction >= 0 && fraction <= 1.0) {
                                downloadProgress.completedUnitCount = (NSInteger)(downloadProgress.totalUnitCount * fraction);
                                
                                // Flag for UI update instead of updating immediately
                                weakSelf.needsUIUpdate = YES;
                                updated = YES;
                            }
                        } @catch (NSException *exception) {
                            NSLog(@"[MCDL] Warning: Exception updating progress: %@", exception);
                        }
                    }
                    
                    retryCount++;
                }
            }
        } destination:^NSURL * _Nonnull(NSURL * _Nonnull targetPath, NSURLResponse * _Nonnull response) {
            NSLog(@"[MCDL] Downloading %@, expected length: %lld", name, response.expectedContentLength);
            
            // If size wasn't provided but response has size info, update progress
            if (size == 0 && response.expectedContentLength > 0) {
                NSUInteger actualSize = (NSUInteger)response.expectedContentLength;
                
                @synchronized(weakSelf) {
                    @try {
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
                    } @catch (NSException *exception) {
                        NSLog(@"[MCDL] Warning: Exception updating progress size: %@", exception);
                    }
                }
                
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
            
            // Remove existing file if it exists to avoid write errors
            NSError *removeError = nil;
            if ([NSFileManager.defaultManager fileExistsAtPath:path]) {
                [NSFileManager.defaultManager removeItemAtPath:path error:&removeError];
                if (removeError) {
                    NSLog(@"[MCDL] Warning: Could not remove existing file %@: %@", path, removeError.localizedDescription);
                }
            }
            
            return [NSURL fileURLWithPath:path];
        } completionHandler:^(NSURLResponse * _Nonnull response, NSURL * _Nullable filePath, NSError * _Nullable error) {
            // Always decrement active downloads count
            @synchronized(weakSelf.pendingDownloads) {
                weakSelf.activeDownloads = MAX(0, weakSelf.activeDownloads - 1);
                // Process next download on the serial queue
                dispatch_async(weakSelf.downloadQueue, ^{
                    [weakSelf processNextDownloadInQueue];
                });
            }
            
            // Safely check if progress is cancelled to avoid potential crashes
            BOOL isCancelled = NO;
            @synchronized(weakSelf) {
                @try {
                    isCancelled = weakSelf.progress.cancelled;
                } @catch (NSException *exception) {
                    NSLog(@"[MCDL] Warning: Exception checking if progress is cancelled: %@", exception);
                    isCancelled = NO;
                }
            }
            
            if (isCancelled) {
                // Ignore any further errors when cancelled
                NSLog(@"[MCDL] Download cancelled for %@", name);
                return;
            } 
            
            if (error != nil) {
                NSLog(@"[MCDL] Download error for %@: %@", name, error.localizedDescription);
                if (failure) {
                    dispatch_async(dispatch_get_global_queue(DISPATCH_QUEUE_PRIORITY_DEFAULT, 0), ^{
                        failure(error);
                    });
                } else {
                    [weakSelf finishDownloadWithError:error file:name];
                }
                return;
            }
            
            // Verify the downloaded file if checksum is provided
            if (sha.length > 0 && ![weakSelf checkSHA:sha forFile:path altName:altName]) {
                NSError *shaError = [NSError errorWithDomain:@"net.kdt.pojavlauncher" 
                                                       code:1000 
                                                   userInfo:@{NSLocalizedDescriptionKey: [NSString stringWithFormat:@"Failed to verify file %@: SHA1 mismatch", path.lastPathComponent]}];
                if (failure) {
                    dispatch_async(dispatch_get_global_queue(DISPATCH_QUEUE_PRIORITY_DEFAULT, 0), ^{
                        failure(shaError);
                    });
                } else {
                    [weakSelf finishDownloadWithErrorString:[NSString stringWithFormat:@"Failed to verify file %@: SHA1 mismatch", path.lastPathComponent]];
                }
                return;
            }
            
            // If we didn't have an accurate size initially and didn't update it from the response
            if (!sizeUpdated && size == 0) {
                // Get the actual file size for more accurate progress reporting
                NSError *fileError;
                NSDictionary *fileAttrs = [NSFileManager.defaultManager attributesOfItemAtPath:path error:&fileError];
                if (!fileError && fileAttrs) {
                    NSUInteger fileSize = [fileAttrs fileSize];
                    if (fileSize > 0) {
                        NSLog(@"[MCDL] Updating progress with actual file size: %lu for %@", (unsigned long)fileSize, name);
                        
                        // Update progress with actual file size - safely
                        @synchronized(weakSelf) {
                            @try {
                                if (fileSize > 0 && fileSize != downloadProgress.totalUnitCount && weakSelf.progress) {
                                    // Add the difference to total progress
                                    NSUInteger oldSize = downloadProgress.totalUnitCount;
                                    weakSelf.progress.totalUnitCount += (fileSize - oldSize);
                                    
                                    if (weakSelf.textProgress) {
                                        weakSelf.textProgress.totalUnitCount = weakSelf.progress.totalUnitCount;
                                    }
                                    
                                    downloadProgress.totalUnitCount = fileSize;
                                }
                            } @catch (NSException *exception) {
                                NSLog(@"[MCDL] Warning: Exception updating progress size: %@", exception);
                            }
                        }
                    }
                }
            }
            
            // Ensure progress is marked as complete
            @synchronized(weakSelf) {
                @try {
                    downloadProgress.completedUnitCount = downloadProgress.totalUnitCount;
                    
                    // Flag for UI update
                    weakSelf.needsUIUpdate = YES;
                } @catch (NSException *exception) {
                    NSLog(@"[MCDL] Warning: Exception setting progress as complete: %@", exception);
                }
            }
            
            NSLog(@"[MCDL] Download completed for %@", name);
            if (success) {
                dispatch_async(dispatch_get_global_queue(DISPATCH_QUEUE_PRIORITY_DEFAULT, 0), ^{
                    success();
                });
            }
        }];

        // Instead of immediately resuming, queue it for controlled execution
        @synchronized(self.pendingDownloads) {
            [self.pendingDownloads addObject:task];
        }
        
        // Process the download queue on our serial queue
        dispatch_async(self.downloadQueue, ^{
            [self processNextDownloadInQueue];
        });

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
    
    BOOL lockAcquired = [self.progressLock tryLock];
    if (!lockAcquired) {
        NSLog(@"[MCDL] Warning: Could not acquire progress lock, retrying...");
        // Wait a bit and try again
        usleep(10000); // 10ms
        lockAcquired = [self.progressLock tryLock];
        if (!lockAcquired) {
            NSLog(@"[MCDL] Error: Failed to acquire progress lock after retry");
            return;
        }
    }
    
    @try {
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
    } @catch (NSException *exception) {
        NSLog(@"[MCDL] Exception in addDownloadTaskToProgress: %@", exception);
    } @finally {
        [self.progressLock unlock];
    }
    
    // Instead of immediately resuming, queue it for controlled execution
    @synchronized(self.pendingDownloads) {
        [self.pendingDownloads addObject:task];
    }
    
    // Process the download queue
    dispatch_async(self.downloadQueue, ^{
        [self processNextDownloadInQueue];
    });
}

- (void)finishDownloadWithError:(NSError *)error file:(NSString *)file {
    NSString *errorStr = [NSString stringWithFormat:localize(@"launcher.mcl.error_download", NULL), file, error.localizedDescription];
    NSLog(@"[MCDL] Error: %@ %@", errorStr, NSThread.callStackSymbols);
    [self finishDownloadWithErrorString:errorStr];
}

- (void)finishDownloadWithErrorString:(NSString *)error {
    // Safely cancel progress
    @synchronized(self) {
        @try {
            [self.progress cancel];
            [self.textProgress cancel];
        } @catch (NSException *exception) {
            NSLog(@"[MCDL] Warning: Exception cancelling progress: %@", exception);
        }
    }
    
    [self.manager invalidateSessionCancelingTasks:YES resetSession:YES];
    
    // Clear pending downloads
    @synchronized(self.pendingDownloads) {
        [self.pendingDownloads removeAllObjects];
        self.activeDownloads = 0;
    }
    
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
            BOOL lockAcquired = [self.progressLock tryLock];
            if (lockAcquired) {
                [self.progress cancel];
                [self.textProgress cancel];
                [self.progressLock unlock];
            } else {
                // Try without lock if we can't acquire it
                [self.progress cancel];
                [self.textProgress cancel];
            }
        } @catch (NSException *exception) {
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
            [self downloadClientLibraries];
            [self downloadClientAssets];
            
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
            
            // Tasks are now automatically queued and will be processed by the download queue
            
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

    // Log the version we're trying to download
    NSLog(@"[MCDL] Downloading metadata for version: %@", versionStr);

    NSString *path = [NSString stringWithFormat:@"%1$s/versions/%2$@/%2$@.json", getenv("POJAV_GAME_DIR"), versionStr];
    // Find it again to resolve latest-*
    version = (id)[MinecraftResourceUtils findVersion:versionStr inList:remoteVersionList];
    
    // Log if version was found in the remote list
    NSLog(@"[MCDL] Version in remote list? %@", version ? @"YES" : @"NO");

    // Create a wrapped success callback
    __weak typeof(self) weakSelf = self;
    void(^wrappedSuccess)(void) = ^{
        weakSelf.metadata = parseJSONFromFile(path);
        if (weakSelf.metadata[@"NSErrorObject"]) {
            [weakSelf finishDownloadWithErrorString:[weakSelf.metadata[@"NSErrorObject"] localizedDescription]];
            return;
        }
        if (weakSelf.metadata[@"inheritsFrom"]) {
            NSLog(@"[MCDL] Version inherits from: %@", weakSelf.metadata[@"inheritsFrom"]);
            NSString *inheritsFromPath = [NSString stringWithFormat:@"%1$s/versions/%2$@/%2$@.json", getenv("POJAV_GAME_DIR"), weakSelf.metadata[@"inheritsFrom"]];
            NSMutableDictionary *inheritsFromDict = parseJSONFromFile(inheritsFromPath);
            if (inheritsFromDict) {
                [MinecraftResourceUtils processVersion:weakSelf.metadata inheritsFrom:inheritsFromDict];
                weakSelf.metadata = inheritsFromDict;
            } else {
                NSLog(@"[MCDL] Failed to load parent version JSON: %@", inheritsFromPath);
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
            NSLog(@"[MCDL] Local version inherits from: %@", json[@"inheritsFrom"]);
            version = (id)[MinecraftResourceUtils findVersion:json[@"inheritsFrom"] inList:remoteVersionList];
            path = [NSString stringWithFormat:@"%1$s/versions/%2$@/%2$@.json", getenv("POJAV_GAME_DIR"), json[@"inheritsFrom"]];
            
            // FIX: If inheritsFrom version isn't found
            if (!version) {
                NSLog(@"[MCDL] Warning: Could not find inheritsFrom version %@ in remoteVersionList", json[@"inheritsFrom"]);
                NSString *parentPath = [NSString stringWithFormat:@"%1$s/versions/%2$@/%2$@.json", getenv("POJAV_GAME_DIR"), json[@"inheritsFrom"]];
                NSLog(@"[MCDL] Checking if parent version exists locally at: %@", parentPath);
                
                if ([NSFileManager.defaultManager fileExistsAtPath:parentPath]) {
                    NSLog(@"[MCDL] Parent version exists locally, proceeding with local files");
                    wrappedSuccess();
                } else {
                    NSLog(@"[MCDL] Parent version not found locally, will try to download from Mojang");
                    // Instead of failing, create a minimal version object to force download
                    version = @{
                        @"id": json[@"inheritsFrom"],
                        @"type": @"release",
                        @"url": [NSString stringWithFormat:@"https://piston-meta.mojang.com/v1/packages/%@/json", json[@"inheritsFrom"]]
                    };
                }
            } else {
                NSLog(@"[MCDL] Found parent version in remote list: %@", json[@"inheritsFrom"]);
            }
        } else {
            NSLog(@"[MCDL] Using local version without inheritsFrom");
            wrappedSuccess();
            return;
        }
    }

    versionStr = version[@"id"];
    NSString *url = version[@"url"];
    NSLog(@"[MCDL] Download URL for %@: %@", versionStr, url ?: @"(null)");
    
    NSString *sha = url.stringByDeletingLastPathComponent.lastPathComponent;
    NSUInteger size = [version[@"size"] unsignedLongLongValue];

    NSURLSessionDownloadTask *task = [self createDownloadTask:url size:size sha:sha altName:versionStr toPath:path success:wrappedSuccess];
    if (task) {
        // Task is automatically queued by createDownloadTask
    } else {
        // If no task was created, still call success
        wrappedSuccess();
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
        // Task is automatically queued by createDownloadTask
    } else {
        // If no task was created (file already exists), continue
        wrappedSuccess();
    }
}

- (NSArray *)downloadClientLibraries {
    NSMutableArray *tasks = [NSMutableArray new];
    
    for (NSDictionary *library in self.metadata[@"libraries"]) {
        NSString *name = library[@"name"];

        NSMutableDictionary *artifactDict = library[@"downloads"][@"artifact"];
        if (artifactDict == nil && [name containsString:@":"]) {
            NSLog(@"[MCDL] Unknown artifact object for %@, attempting to generate one", name);
            artifactDict = [[NSMutableDictionary alloc] init];
            NSString *prefix = library[@"url"] == nil ? @"https://libraries.minecraft.net/" : [library[@"url"] stringByReplacingOccurrencesOfString:@"http://" withString:@"https://"];
            NSArray *libParts = [name componentsSeparatedByString:@":"];
            
            // Handle library names with more than 3 components (e.g., Forge libraries with classifier)
            if (libParts.count >= 3) {
                NSString *group = [libParts[0] stringByReplacingOccurrencesOfString:@"." withString:@"/"];
                NSString *artifactName = libParts[1];
                NSString *version = libParts[2];
                
                // Check if we have a classifier (4th component)
                NSString *classifier = @"";
                if (libParts.count > 3) {
                    classifier = [NSString stringWithFormat:@"-%@", libParts[3]];
                }
                
                // Construct path and URL correctly
                artifactDict[@"path"] = [NSString stringWithFormat:@"%@/%@/%@/%@-%@%@.jar", 
                                     group, artifactName, version, artifactName, version, classifier];
                artifactDict[@"url"] = [NSString stringWithFormat:@"%@%@", prefix, artifactDict[@"path"]];
                
                if (library[@"checksums"] && [library[@"checksums"] isKindOfClass:[NSArray class]] && library[@"checksums"].count > 0) {
                    artifactDict[@"sha1"] = library[@"checksums"][0];
                }
            } else {
                // Fallback to the original logic for standard 3-part library names
                artifactDict[@"path"] = [NSString stringWithFormat:@"%1$@/%2$@/%3$@/%2$@-%3$@.jar", 
                                     [libParts[0] stringByReplacingOccurrencesOfString:@"." withString:@"/"], 
                                     libParts[1], 
                                     libParts[2]];
                artifactDict[@"url"] = [NSString stringWithFormat:@"%@%@", prefix, artifactDict[@"path"]];
                
                if (library[@"checksums"] && [library[@"checksums"] isKindOfClass:[NSArray class]] && library[@"checksums"].count > 0) {
                    artifactDict[@"sha1"] = library[@"checksums"][0];
                }
            }
        }

        NSString *path = [NSString stringWithFormat:@"%s/libraries/%@", getenv("POJAV_GAME_DIR"), artifactDict[@"path"]];
        NSString *sha = artifactDict[@"sha1"];
        NSUInteger size = [artifactDict[@"size"] unsignedLongLongValue];
        NSString *url = artifactDict[@"url"];
        if ([library[@"skip"] boolValue]) {
            NSLog(@"[MCDL] Skipped library %@", name);
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
    
    // Create a secondary queue for processing asset entries to avoid blocking
    dispatch_queue_t assetProcessingQueue = dispatch_queue_create("net.kdt.pojavlauncher.assetProcessingQueue", DISPATCH_QUEUE_CONCURRENT);
    dispatch_group_t assetGroup = dispatch_group_create();
    
    // Process assets in batches for better performance
    id objectsObj = assets[@"objects"];
    NSArray *assetNames = nil;
    
    // Check if objects is a dictionary
    if (objectsObj && [objectsObj isKindOfClass:[NSDictionary class]]) {
        NSDictionary *objectsDict = (NSDictionary *)objectsObj;
        assetNames = objectsDict.allKeys;
    } else {
        // Handle the case where objects is nil or not a dictionary
        NSLog(@"[MCDL] Warning: assets[@\"objects\"] is nil or not a dictionary");
        return @[];
    }
    
    NSInteger totalAssets = assetNames.count;
    NSInteger batchSize = 100; // Process 100 assets at a time
    
    for (NSInteger startIndex = 0; startIndex < totalAssets; startIndex += batchSize) {
        NSInteger endIndex = MIN(startIndex + batchSize, totalAssets);
        NSRange batchRange = NSMakeRange(startIndex, endIndex - startIndex);
        NSArray *batchNames = [assetNames subarrayWithRange:batchRange];
        
        // Process this batch concurrently
        dispatch_group_enter(assetGroup);
        dispatch_async(assetProcessingQueue, ^{
            NSMutableArray *batchTasks = [NSMutableArray new];
            
            for (NSString *name in batchNames) {
                if (self.progress.cancelled) {
                    dispatch_group_leave(assetGroup);
                    return;
                }
                
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
                    [batchTasks addObject:task];
                } else if (self.progress.cancelled) {
                    dispatch_group_leave(assetGroup);
                    return;
                }
            }
            
            // Add all tasks from this batch to the main tasks array
            @synchronized(tasks) {
                [tasks addObjectsFromArray:batchTasks];
            }
            
            dispatch_group_leave(assetGroup);
        });
    }
    
    // Wait for all batches to be processed
    dispatch_group_wait(assetGroup, DISPATCH_TIME_FOREVER);
    
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
            // Task is automatically queued by createDownloadTask
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
        // Task is automatically queued by createDownloadTask
    }
}
@end

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
        
        // Initialize counters for logging
        self.successfulDownloads = 0;
        self.totalDownloads = 0;
        self.verboseLogging = getPrefBool(@"general.debug_logging");
        
        // Setup timer for batched UI updates with lower frequency
        self.needsUIUpdate = NO;
        self.uiUpdateTimer = [NSTimer scheduledTimerWithTimeInterval:0.5
                                                             target:self 
                                                           selector:@selector(processBatchedUIUpdates) 
                                                           userInfo:nil 
                                                            repeats:YES];
        [[NSRunLoop currentRunLoop] addTimer:self.uiUpdateTimer forMode:NSRunLoopCommonModes];
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
    // Create a fresh progress object with proper initial values
    @synchronized(self) {
        // Create a new progress tracking object starting with 1 unit
        self.progress = [NSProgress new];
        self.progress.totalUnitCount = 1; // Critical: Start with 1 instead of 0
        self.progress.cancellable = YES;
        
        // Create a text progress for UI display
        self.textProgress = [NSProgress new];
        self.textProgress.kind = NSProgressKindFile;
        self.textProgress.fileOperationKind = NSProgressFileOperationKindDownloading;
        self.textProgress.totalUnitCount = 1; // Critical: Start with 1 instead of 0
        self.textProgress.cancellable = YES;
        
        // Reset counters
        self.successfulDownloads = 0;
        self.totalDownloads = 0;
    }
    
    // Reset tracking lists with proper synchronization
    @synchronized(self.fileList) {
        [self.fileList removeAllObjects];
    }
    
    @synchronized(self.progressList) {
        [self.progressList removeAllObjects];
    }
    
    // Reset download queue
    @synchronized(self.pendingDownloads) {
        [self.pendingDownloads removeAllObjects];
        self.activeDownloads = 0;
    }
    
    // Flag that UI update is needed
    self.needsUIUpdate = YES;
}

- (void)processNextDownloadInQueue {
    @synchronized(self.pendingDownloads) {
        // Check if we're at the concurrency limit or if there are no pending downloads
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
            // Clear all pending downloads if cancelled
            [self.pendingDownloads removeAllObjects];
            self.activeDownloads = 0;
            return;
        }
        
        // Get next download task and start it
        NSURLSessionDownloadTask *nextTask = self.pendingDownloads[0];
        [self.pendingDownloads removeObjectAtIndex:0];
        self.activeDownloads++;
        
        // Resume task on a background queue to avoid blocking
        dispatch_async(dispatch_get_global_queue(DISPATCH_QUEUE_PRIORITY_DEFAULT, 0), ^{
            [nextTask resume];
        });
        
        // If we're still below the concurrent limit and have more tasks, process another one
        if (self.activeDownloads < kMaxConcurrentDownloads && self.pendingDownloads.count > 0) {
            dispatch_async(self.downloadQueue, ^{
                [self processNextDownloadInQueue];
            });
        }
    }
}

- (NSURLSessionDownloadTask *)createDownloadTask:(NSString *)url size:(NSUInteger)size sha:(NSString *)sha altName:(NSString *)altName toPath:(NSString *)path success:(void (^)())success {
    @autoreleasepool {
        // Safety check for invalid URL with enhanced logging
        if (!url || url.length == 0) {
            NSLog(@"[MCDL] Error: Invalid or empty download URL");
            NSLog(@"[MCDL] File: %@, Path: %@", altName ?: @"(null)", path ?: @"(null)");
            
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
        
        // Track total downloads
        self.totalDownloads++;
        
        // Check if file already exists and has correct SHA1 - with quick return
        BOOL fileExists = [NSFileManager.defaultManager fileExistsAtPath:path];
        
        // Special handling for version files
        BOOL isVersionFile = (altName && [altName hasSuffix:@".json"]) || 
                             (path && [path hasSuffix:@".json"] && [path containsString:@"/versions/"]);
        
        // Check for latest version files that should be forced to re-download
        BOOL isLatestVersionFile = (altName && 
                                  ([altName containsString:@"latest-release"] || 
                                   [altName containsString:@"latest-snapshot"]));

        if (!isLatestVersionFile && fileExists && [self checkSHA:sha forFile:path altName:altName]) {
            // Increment successful downloads counter
            self.successfulDownloads++;
            
            // Only log skipped files in verbose mode
            if (self.verboseLogging) {
                NSLog(@"[MCDL] Skipping download - file exists and SHA1 matched: %@", 
                      altName ?: path.lastPathComponent);
            } else if (self.successfulDownloads % 50 == 0) {
                // Log periodic summaries if not in verbose mode
                NSLog(@"[MCDL] Progress: %ld of %ld files verified/downloaded", 
                      (long)self.successfulDownloads, (long)self.totalDownloads);
            }
            
            // Optimization: Handle success callback on background thread
            if (success) {
                dispatch_async(dispatch_get_global_queue(DISPATCH_QUEUE_PRIORITY_DEFAULT, 0), ^{
                    success();
                    
                    // Mark as needing UI update
                    self.needsUIUpdate = YES;
                });
            }
            return nil;
        } else if (![self checkAccessWithDialog:YES]) {
            return nil;
        }

        // Only log detailed URL information for files we're actually downloading
        if (self.verboseLogging) {
            NSLog(@"[MCDL] Creating download task - URL: %@", url);
            NSLog(@"[MCDL] File: %@, Path: %@", altName ?: @"(null)", path);
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
        
        // Add to file list for UI tracking (before creating the task to avoid race conditions)
        @synchronized(self.fileList) {
            [self.fileList addObject:name];
        }
        
        // Create a progress object for this download before the task is created
        NSProgress *downloadProgress = [NSProgress progressWithTotalUnitCount:size > 0 ? size : 1000000];
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
        }
        
        // Mark the progress object as tracked by this task
        objc_setAssociatedObject(downloadProgress, kIsTrackedByTaskKey, @YES, OBJC_ASSOCIATION_RETAIN_NONATOMIC);
        
        // Create weak reference to self to avoid retain cycles
        __weak typeof(self) weakSelf = self;
        
        // Create download task with proper completion handling
        __block NSURLSessionDownloadTask *task = [self.manager downloadTaskWithRequest:request progress:^(NSProgress * _Nonnull taskProgress) {
            // Only update progress every 10% to reduce overhead
            static NSInteger lastReportedPercent = -1;
            NSInteger currentPercent = (NSInteger)(taskProgress.fractionCompleted * 100);
            
            if (currentPercent != lastReportedPercent && currentPercent % 10 == 0) {
                lastReportedPercent = currentPercent;
                
                // Safely update progress
                @synchronized(weakSelf) {
                    @try {
                        // Update completion amount with safeguards
                        CGFloat fraction = taskProgress.fractionCompleted;
                        if (!isnan(fraction) && fraction >= 0 && fraction <= 1.0) {
                            downloadProgress.completedUnitCount = (NSInteger)(downloadProgress.totalUnitCount * fraction);
                            
                            // Flag for UI update instead of updating immediately
                            weakSelf.needsUIUpdate = YES;
                        }
                    } @catch (NSException *exception) {
                        // Just log and continue
                        NSLog(@"[MCDL] Exception in progress update: %@", exception);
                    }
                }
            }
        } destination:^NSURL * _Nonnull(NSURL * _Nonnull targetPath, NSURLResponse * _Nonnull response) {
            NSLog(@"[MCDL] Downloading %@", name);
            NSProgress *progress = [self.manager downloadProgressForTask:task];
            
            if (!size && task) {
                [weakSelf addDownloadTaskToProgress:task size:response.expectedContentLength];
                
                @synchronized(weakSelf.fileList) {
                    [weakSelf.fileList addObject:name];
                }
            }
            
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
                    } @catch (NSException *exception) {
                        NSLog(@"[MCDL] Exception updating progress size: %@", exception);
                    }
                }
            }
            
            // Create directory structure if needed
            NSString *dirPath = [path stringByDeletingLastPathComponent];
            NSError *dirError = nil;
            BOOL dirCreated = [[NSFileManager defaultManager] createDirectoryAtPath:dirPath 
                                             withIntermediateDirectories:YES 
                                                              attributes:nil 
                                                                   error:&dirError];
            
            if (!dirCreated) {
                NSLog(@"[MCDL] Warning: Could not create directory at %@: %@", 
                      dirPath, dirError ? dirError.localizedDescription : @"Unknown error");
            }
            
            // Remove existing file if it exists to avoid write errors
            if ([NSFileManager.defaultManager fileExistsAtPath:path]) {
                NSError *removeError = nil;
                BOOL removed = [NSFileManager.defaultManager removeItemAtPath:path error:&removeError];
                
                if (!removed) {
                    NSLog(@"[MCDL] Warning: Could not remove existing file at %@: %@", 
                          path, removeError ? removeError.localizedDescription : @"Unknown error");
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
                    NSLog(@"[MCDL] Exception checking if cancelled: %@", exception);
                    isCancelled = NO;
                }
            }
            
            if (isCancelled) {
                NSLog(@"[MCDL] Download cancelled for %@", name);
                return;
            } 
            
            if (error != nil) {
                // Always log errors
                NSLog(@"[MCDL] Download error for %@: %@", name, error.localizedDescription);
                
                // For version files, be less strict about failures
                if (isVersionFile) {
                    NSLog(@"[MCDL] Version file download failed but continuing: %@", path.lastPathComponent);
                    
                    // Check if the file exists despite the error (might have been partially downloaded)
                    if ([NSFileManager.defaultManager fileExistsAtPath:path]) {
                        NSLog(@"[MCDL] Version file exists despite error, will use it: %@", path);
                        
                        // Mark progress as complete
                        @synchronized(weakSelf) {
                            downloadProgress.completedUnitCount = downloadProgress.totalUnitCount;
                        }
                        
                        if (success) {
                            dispatch_async(dispatch_get_global_queue(DISPATCH_QUEUE_PRIORITY_DEFAULT, 0), ^{
                                success();
                            });
                        }
                        return;
                    }
                }
                
                // Normal failure handling for non-version files or if version file doesn't exist
                if (failure) {
                    dispatch_async(dispatch_get_global_queue(DISPATCH_QUEUE_PRIORITY_DEFAULT, 0), ^{
                        failure(error);
                    });
                } else {
                    [weakSelf finishDownloadWithError:error file:name];
                }
                return;
            }
            
            // Increment successful download counter
            weakSelf.successfulDownloads++;
            
            // Log progress summary periodically instead of every file
            if (weakSelf.verboseLogging) {
                NSLog(@"[MCDL] Successfully downloaded %@", name);
            } else if (weakSelf.successfulDownloads % 50 == 0) {
                NSLog(@"[MCDL] Progress: %ld of %ld files downloaded", 
                      (long)weakSelf.successfulDownloads, (long)weakSelf.totalDownloads);
            }
            
            // Verify the downloaded file if checksum is provided
            BOOL shaValid = YES;
            if (sha.length > 0) {
                shaValid = [weakSelf checkSHAIgnorePref:sha forFile:path altName:altName logSuccess:YES];
                
                if (!shaValid) {
                    NSLog(@"[MCDL] SHA1 verification failed for %@", path.lastPathComponent);
                    
                    // For version files, be less strict about SHA verification
                    if (isVersionFile) {
                        NSLog(@"[MCDL] Version file SHA mismatch but continuing: %@", path.lastPathComponent);
                        shaValid = YES;
                    } else {
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
                }
            }
            
            // Ensure progress is marked as complete
            @synchronized(weakSelf) {
                @try {
                    downloadProgress.completedUnitCount = downloadProgress.totalUnitCount;
                    
                    // Flag for UI update
                    weakSelf.needsUIUpdate = YES;
                } @catch (NSException *exception) {
                    NSLog(@"[MCDL] Exception marking progress complete: %@", exception);
                }
            }
            
            if (success && shaValid) {
                dispatch_async(dispatch_get_global_queue(DISPATCH_QUEUE_PRIORITY_DEFAULT, 0), ^{
                    success();
                });
            }
        }];

        // Instead of immediately resuming, queue it for controlled execution
        @synchronized(self.pendingDownloads) {
            [self.pendingDownloads addObject:task];
            
            // Only process next download if we're not at the limit
            if (self.activeDownloads < kMaxConcurrentDownloads) {
                dispatch_async(self.downloadQueue, ^{
                    [self processNextDownloadInQueue];
                });
            }
        }

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
    // Cancel progress safely
    @synchronized(self) {
        @try {
            [self.progress cancel];
            [self.textProgress cancel];
        } @catch (NSException *exception) {
            NSLog(@"[MCDL] Warning: Exception cancelling progress: %@", exception);
        }
    }
    
    // Cancel all active downloads and reset session
    [self.manager invalidateSessionCancelingTasks:YES resetSession:YES];
    
    // Clear pending downloads
    @synchronized(self.pendingDownloads) {
        [self.pendingDownloads removeAllObjects];
        self.activeDownloads = 0;
    }
    
    // Show error dialog
    showDialog(localize(@"Error", nil), error);
    
    // Call error handler if set
    if (self.handleError) {
        self.handleError();
    }
}

// Check if the account has permission to download
- (BOOL)checkAccessWithDialog:(BOOL)show {
    // Check if account is allowed to download Minecraft
    BOOL accessible = [BaseAuthenticator.current.authData[@"username"] hasPrefix:@"Demo."] || BaseAuthenticator.current.authData[@"xboxGamertag"] != nil;
    
    if (!accessible) {
        // Cancel download if not accessible
        @synchronized(self) {
            @try {
                [self.progress cancel];
                [self.textProgress cancel];
            } @catch (NSException *exception) {
                NSLog(@"[MCDL] Warning: Exception cancelling progress: %@", exception);
            }
        }
        
        // Show error dialog if requested
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
        if (existence && self.verboseLogging) {
            NSLog(@"[MCDL] Warning: couldn't find SHA for %@, have to assume it's good.", path);
        }
        return existence;
    }

    // Get file attributes to check file size
    NSError *attributesError = nil;
    NSDictionary *fileAttributes = [[NSFileManager defaultManager] attributesOfItemAtPath:path error:&attributesError];
    
    if (attributesError || !fileAttributes) {
        if (self.verboseLogging) {
            NSLog(@"[MCDL] SHA1 checker: couldn't get file attributes: %@", attributesError ? attributesError.localizedDescription : @"Unknown error");
        }
        return NO;
    }
    
    // Check if file size is zero, which would indicate a corrupted download
    unsigned long long fileSize = [fileAttributes fileSize];
    if (fileSize == 0) {
        NSLog(@"[MCDL] SHA1 checker: file exists but has zero size: %@", path.lastPathComponent);
        return NO;
    }

    // Read file contents for SHA calculation
    NSData *data = [NSData dataWithContentsOfFile:path];
    if (data == nil) {
        NSLog(@"[MCDL] SHA1 checker: file doesn't exist or couldn't be read: %@", altName ? altName : path.lastPathComponent);
        return NO;
    }

    // Calculate SHA1 hash
    unsigned char digest[CC_SHA1_DIGEST_LENGTH];
    CC_SHA1(data.bytes, (CC_LONG)data.length, digest);
    NSMutableString *localSHA = [NSMutableString stringWithCapacity:CC_SHA1_DIGEST_LENGTH * 2];
    for(int i = 0; i < CC_SHA1_DIGEST_LENGTH; i++) {
        [localSHA appendFormat:@"%02x", digest[i]];
    }

    BOOL check = [sha isEqualToString:localSHA];
    
    // Always log detailed information for SHA1 failures to help diagnose issues
    if (!check) {
        NSLog(@"[MCDL] SHA1 failed for %@", altName ? altName : path.lastPathComponent);
        NSLog(@"[MCDL] Expected: %@", sha);
        NSLog(@"[MCDL]Got:      %@", localSHA);
        NSLog(@"[MCDL] File size: %llu bytes", fileSize);
    } else if (self.verboseLogging && logSuccess) {
        NSLog(@"[MCDL] SHA1 passed for %@", altName ? altName : path.lastPathComponent);
    }
    
    return check;
}

// Simplified SHA check with default logging behavior
- (BOOL)checkSHA:(NSString *)sha forFile:(NSString *)path altName:(NSString *)altName {
    // Special handling for version files to be more selective about forced downloads
    if (altName) {
        // Force download for latest version files
        if ([altName hasSuffix:@".json"] && 
            ([altName containsString:@"latest-release"] ||
             [altName containsString:@"latest-snapshot"])) {
            
            if (self.verboseLogging) {
                NSLog(@"[MCDL] Forcing download of latest version file: %@", altName);
            }
            return NO;
        }
        
        // For specific version files (not latest-*) check if they exist
        if ([altName hasSuffix:@".json"] || 
            ([path containsString:@"/versions/"] && [path hasSuffix:@".jar"])) {
            
            BOOL fileExists = [NSFileManager.defaultManager fileExistsAtPath:path];
            if (!fileExists) {
                if (self.verboseLogging) {
                    NSLog(@"[MCDL] Version file doesn't exist, downloading: %@", altName);
                }
                return NO;
            }
        }
    }
    
    // For other files, perform the normal SHA check
    return [self checkSHA:sha forFile:path altName:altName logSuccess:altName==nil];
}

// Check SHA of the file respecting user preferences
- (BOOL)checkSHA:(NSString *)sha forFile:(NSString *)path altName:(NSString *)altName logSuccess:(BOOL)logSuccess {
    // Respect user preference for SHA checking
    if (getPrefBool(@"general.check_sha")) {
        return [self checkSHAIgnorePref:sha forFile:path altName:altName logSuccess:logSuccess];
    } else {
        // When SHA checking is disabled, still check if file exists
        return [NSFileManager.defaultManager fileExistsAtPath:path];
    }
}

- (void)downloadVersion:(NSDictionary *)version {
    // Prepare download state
    [self prepareForDownload];
    
    // Reset metadata and explicitly mark as NOT a modpack
    if (!self.metadata) {
        self.metadata = [NSMutableDictionary dictionary];
    } else {
        [self.metadata removeAllObjects];
    }
    
    // Critical: Mark this as NOT a modpack installation
    self.metadata[@"isModpackInstall"] = @NO;
    
    NSLog(@"[MCDL] Starting download for version: %@", version[@"id"]);
    
    // Chain download operations
    [self downloadVersionMetadata:version success:^{
        [self downloadAssetMetadataWithSuccess:^{
            // Download libraries and assets in parallel
            NSArray *libTasks = [self downloadClientLibraries];
            NSArray *assetTasks = [self downloadClientAssets];
            
            @synchronized(self) {
                // Critical: Drop the 1 byte we set initially 
                self.progress.totalUnitCount--;
                self.textProgress.totalUnitCount--;
                
                // If we have nothing to download, mark as complete
                if (self.progress.totalUnitCount == 0) {
                    // Set progress to 100% complete
                    self.progress.totalUnitCount = 1;
                    self.progress.completedUnitCount = 1;
                    self.textProgress.totalUnitCount = 1;
                    self.textProgress.completedUnitCount = 1;
                    
                    // Add completion marker to file list for UI
                    @synchronized(self.fileList) {
                        [self.fileList addObject:@"Complete"];
                    }
                    
                    return;
                }
            }
            
            // Start all queued download tasks
            [libTasks makeObjectsPerformSelector:@selector(resume)];
            [assetTasks makeObjectsPerformSelector:@selector(resume)];
            
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
    
    // Ensure version directory exists before attempting to download
    NSString *versionDir = [path stringByDeletingLastPathComponent];
    NSError *dirError = nil;
    [[NSFileManager defaultManager] createDirectoryAtPath:versionDir 
                             withIntermediateDirectories:YES 
                                              attributes:nil 
                                                   error:&dirError];
    if (dirError) {
        NSLog(@"[MCDL] Error creating version directory %@: %@", versionDir, dirError.localizedDescription);
        [self finishDownloadWithErrorString:[NSString stringWithFormat:@"Failed to create version directory: %@", dirError.localizedDescription]];
        return;
    }
    
    // Find it again to resolve latest-*
    version = (id)[MinecraftResourceUtils findVersion:versionStr inList:remoteVersionList];
    
    // Create wrapped success callback
    __weak typeof(self) weakSelf = self;
    void(^wrappedSuccess)(void) = ^{
        // Safely check if task is cancelled
        BOOL isCancelled = NO;
        @synchronized(weakSelf) {
            @try {
                isCancelled = weakSelf.progress.cancelled;
            } @catch (NSException *exception) {
                NSLog(@"[MCDL] Exception checking if cancelled: %@", exception);
                isCancelled = NO;
            }
        }
        
        if (isCancelled) {
            return;
        }
        
        // Parse the JSON file
        NSError *jsonError = nil;
        NSData *jsonData = [NSData dataWithContentsOfFile:path options:0 error:&jsonError];
        if (!jsonData || jsonError) {
            NSLog(@"[MCDL] Error reading version JSON: %@", jsonError.localizedDescription);
            [weakSelf finishDownloadWithErrorString:[NSString stringWithFormat:@"Error reading version JSON: %@", jsonError.localizedDescription]];
            return;
        }
        
        // Parse JSON with mutable containers option
        id jsonObject = [NSJSONSerialization JSONObjectWithData:jsonData 
                                                       options:NSJSONReadingMutableContainers 
                                                         error:&jsonError];
        if (!jsonObject || jsonError) {
            NSLog(@"[MCDL] Error parsing version JSON: %@", jsonError.localizedDescription);
            [weakSelf finishDownloadWithErrorString:[NSString stringWithFormat:@"Error parsing version JSON: %@", jsonError.localizedDescription]];
            return;
        }
        
        // Set metadata safely
        @synchronized(weakSelf) {
            // Store version metadata
            weakSelf.metadata = jsonObject;
            
            // Explicitly mark as NOT a modpack installation
            weakSelf.metadata[@"isModpackInstall"] = @NO;
        }
        
        // Handle inheritsFrom for mod versions
        @synchronized(weakSelf) {
            if (weakSelf.metadata[@"inheritsFrom"]) {
                NSLog(@"[MCDL] Version inherits from: %@", weakSelf.metadata[@"inheritsFrom"]);
                NSString *inheritsFromPath = [NSString stringWithFormat:@"%1$s/versions/%2$@/%2$@.json", 
                                            getenv("POJAV_GAME_DIR"), 
                                            weakSelf.metadata[@"inheritsFrom"]];
                
                // Read parent version JSON
                NSMutableDictionary *inheritsFromDict = parseJSONFromFile(inheritsFromPath);
                if (inheritsFromDict) {
                    [MinecraftResourceUtils processVersion:weakSelf.metadata inheritsFrom:inheritsFromDict];
                    weakSelf.metadata = inheritsFromDict;
                }
            }
            
            // Apply version tweaks
            [MinecraftResourceUtils tweakVersionJson:weakSelf.metadata];
        }
        
        // Call original success callback
        if (success) {
            success();
        }
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
            // Use local version directly
            wrappedSuccess();
            return;
        }
    }

    versionStr = version[@"id"];
    NSString *url = version[@"url"];
    NSString *sha = url.stringByDeletingLastPathComponent.lastPathComponent;
    NSUInteger size = [version[@"size"] unsignedLongLongValue];
    
    if (self.verboseLogging) {
        NSLog(@"[MCDL] Downloading version JSON from %@", url);
    }

    NSURLSessionDownloadTask *task = [self createDownloadTask:url size:size sha:sha altName:nil toPath:path success:wrappedSuccess];
    if (task) {
        [task resume];
    } else {
        // If no task was created, still call success if file exists and the download wasn't cancelled
        if (!self.progress.cancelled && [[NSFileManager defaultManager] fileExistsAtPath:path]) {
            wrappedSuccess();
        } else if (self.progress.cancelled) {
            // If cancelled, do nothing - the cancellation handler will clean up
        } else {
            // If file doesn't exist and no download task was created, report error
            [self finishDownloadWithErrorString:[NSString stringWithFormat:@"Failed to create download task for version %@", versionStr]];
        }
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
    
    // Create wrapped success callback
    __weak typeof(self) weakSelf = self;
    void(^wrappedSuccess)(void) = ^{
        // Safely check if task is cancelled
        BOOL isCancelled = NO;
        @synchronized(weakSelf) {
            @try {
                isCancelled = weakSelf.progress.cancelled;
            } @catch (NSException *exception) {
                NSLog(@"[MCDL] Exception checking if cancelled: %@", exception);
                isCancelled = NO;
            }
        }
        
        if (isCancelled) {
            return;
        }
        
        // Parse the JSON file
        NSError *jsonError = nil;
        NSData *jsonData = [NSData dataWithContentsOfFile:path options:0 error:&jsonError];
        if (!jsonData || jsonError) {
            NSLog(@"[MCDL] Error reading asset index JSON: %@", jsonError.localizedDescription);
            [weakSelf finishDownloadWithErrorString:[NSString stringWithFormat:@"Error reading asset index JSON: %@", jsonError.localizedDescription]];
            return;
        }
        
        // Parse JSON with mutable containers option
        id jsonObject = [NSJSONSerialization JSONObjectWithData:jsonData 
                                                       options:NSJSONReadingMutableContainers 
                                                         error:&jsonError];
        if (!jsonObject || jsonError) {
            NSLog(@"[MCDL] Error parsing asset index JSON: %@", jsonError.localizedDescription);
            [weakSelf finishDownloadWithErrorString:[NSString stringWithFormat:@"Error parsing asset index JSON: %@", jsonError.localizedDescription]];
            return;
        }
        
        // Set asset index object safely
        @synchronized(weakSelf) {
            weakSelf.metadata[@"assetIndexObj"] = jsonObject;
        }
        
        // Call original success callback
        if (success) {
            success();
        }
    };
    
    // Ensure directories exist
    NSString *dirPath = [path stringByDeletingLastPathComponent];
    NSError *dirError = nil;
    BOOL dirCreated = [[NSFileManager defaultManager] createDirectoryAtPath:dirPath
                                               withIntermediateDirectories:YES
                                                                attributes:nil
                                                                     error:&dirError];
    if (!dirCreated) {
        NSLog(@"[MCDL] Error creating asset index directory: %@", dirError.localizedDescription);
        [self finishDownloadWithErrorString:[NSString stringWithFormat:@"Failed to create asset index directory: %@", dirError.localizedDescription]];
        return;
    }
    
    NSURLSessionDownloadTask *task = [self createDownloadTask:url size:size sha:sha altName:name toPath:path success:wrappedSuccess];
    if (task) {
        [task resume];
    } else {
        // If no task was created, still call success if file exists and the download wasn't cancelled
        if (!self.progress.cancelled && [[NSFileManager defaultManager] fileExistsAtPath:path]) {
            wrappedSuccess();
        } else if (self.progress.cancelled) {
            // If cancelled, do nothing - the cancellation handler will clean up
        } else {
            // If file doesn't exist and no download task was created, report error
            [self finishDownloadWithErrorString:[NSString stringWithFormat:@"Failed to create download task for asset index %@", assetIndex[@"id"]]];
        }
    }
}

- (NSArray *)downloadClientLibraries {
    NSMutableArray *tasks = [NSMutableArray new];
    
    // Skip if no libraries defined
    if (!self.metadata[@"libraries"] || ![self.metadata[@"libraries"] isKindOfClass:[NSArray class]]) {
        return tasks;
    }
    
    NSInteger libraryCount = [self.metadata[@"libraries"] count];
    
    if (self.verboseLogging) {
        NSLog(@"[MCDL] Processing %ld libraries for download", (long)libraryCount);
    }
    
    for (NSDictionary *library in self.metadata[@"libraries"]) {
        NSString *name = library[@"name"];
        if (!name) continue;

        // Skip Forge/NeoForge client JARs entirely - they're already installed by the installer
        if (([name containsString:@"net.minecraftforge:forge:"] || 
             [name containsString:@"net.neoforged:neoforge:"]) && 
            ([name hasSuffix:@":client"] || [name hasSuffix:@":universal"])) {
            if (self.verboseLogging) {
                NSLog(@"[MCDL] Skipping Forge/NeoForge client JAR %@ - already installed by the installer", name);
            }
            continue;
        }

        NSMutableDictionary *artifactDict = library[@"downloads"][@"artifact"];
        if (artifactDict == nil && [name containsString:@":"]) {
            if (self.verboseLogging) {
                NSLog(@"[MCDL] Unknown artifact object for %@, attempting to generate one", name);
            }
            artifactDict = [[NSMutableDictionary alloc] init];
            
            // Standard library URL construction
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
                
                // Safely get SHA1 from checksums if available
                id checksums = library[@"checksums"];
                if (checksums && [checksums isKindOfClass:[NSArray class]]) {
                    NSArray *checksumsArray = (NSArray *)checksums;
                    if (checksumsArray.count > 0) {
                        artifactDict[@"sha1"] = checksumsArray[0];
                    }
                }
            } else {
                // Fallback to the original logic for standard 3-part library names
                artifactDict[@"path"] = [NSString stringWithFormat:@"%1$@/%2$@/%3$@/%2$@-%3$@.jar", 
                                     [libParts[0] stringByReplacingOccurrencesOfString:@"." withString:@"/"], 
                                     libParts[1], 
                                     libParts[2]];
                artifactDict[@"url"] = [NSString stringWithFormat:@"%@%@", prefix, artifactDict[@"path"]];
                
                // Safely get SHA1 from checksums if available
                id checksums = library[@"checksums"];
                if (checksums && [checksums isKindOfClass:[NSArray class]]) {
                    NSArray *checksumsArray = (NSArray *)checksums;
                    if (checksumsArray.count > 0) {
                        artifactDict[@"sha1"] = checksumsArray[0];
                    }
                }
            }
        }

        // Skip library if marked to skip
        if ([library[@"skip"] boolValue]) {
            if (self.verboseLogging) {
                NSLog(@"[MCDL] Skipped library %@", name);
            }
            continue;
        }

        // Build the download path
        NSString *path = [NSString stringWithFormat:@"%s/libraries/%@", getenv("POJAV_GAME_DIR"), artifactDict[@"path"]];
        NSString *sha = artifactDict[@"sha1"];
        NSUInteger size = [artifactDict[@"size"] unsignedLongLongValue];
        NSString *url = artifactDict[@"url"];
        
        // Create download task
        NSURLSessionDownloadTask *task = [self createDownloadTask:url size:size sha:sha altName:name toPath:path success:nil];
        if (task) {
            [tasks addObject:task];
        } else if (self.progress.cancelled) {
            return nil;
        }
    }
    
    NSLog(@"[MCDL] Created %lu library download tasks", (unsigned long)tasks.count);
    return tasks;
}

- (NSArray *)downloadClientAssets {
    NSMutableArray *tasks = [NSMutableArray new];
    NSDictionary *assets = self.metadata[@"assetIndexObj"];
    
    if (!assets || !assets[@"objects"] || ![assets[@"objects"] isKindOfClass:[NSDictionary class]]) {
        return tasks;
    }
    
    NSDictionary *objectsDict = assets[@"objects"];
    NSArray *assetNames = objectsDict.allKeys;
    NSInteger totalAssets = assetNames.count;
    
    NSLog(@"[MCDL] Processing %ld assets for download", (long)totalAssets);
    
    // Set up asset directories
    NSString *assetsDir = [NSString stringWithFormat:@"%s/assets/objects", getenv("POJAV_GAME_DIR")];
    NSError *dirError = nil;
    [[NSFileManager defaultManager] createDirectoryAtPath:assetsDir 
                             withIntermediateDirectories:YES 
                                              attributes:nil 
                                                   error:&dirError];
    if (dirError) {
        NSLog(@"[MCDL] Warning: Error creating assets directory: %@", dirError.localizedDescription);
    }
    
    // Process each asset
    for (NSString *name in assetNames) {
        // Check if download was cancelled
        if (self.progress.cancelled) {
            return nil;
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
            [tasks addObject:task];
        } else if (self.progress.cancelled) {
            return nil;
        }
    }
    
    NSLog(@"[MCDL] Created %lu asset download tasks", (unsigned long)tasks.count);
    return tasks;
}

- (void)downloadModpackFromAPI:(ModpackAPI *)api detail:(NSDictionary *)modDetail atIndex:(NSUInteger)selectedVersion {
    [self prepareForDownload];
    
    // Reset counters
    self.successfulDownloads = 0;
    self.totalDownloads = 0;
    
    // Create metadata dictionary if needed
    if (!self.metadata) {
        self.metadata = [NSMutableDictionary dictionary];
    }
    
    // Explicitly mark this as a modpack installation
    self.metadata[@"isModpackInstall"] = @YES;

    NSString *url = modDetail[@"versionUrls"][selectedVersion];
    NSUInteger size = [modDetail[@"versionSizes"][selectedVersion] unsignedLongLongValue];
    NSString *sha = modDetail[@"versionHashes"][selectedVersion];
    
    // Use the original title without converting to lowercase or replacing spaces with underscores
    NSString *name = [modDetail[@"title"] stringByTrimmingCharactersInSet:NSCharacterSet.whitespaceCharacterSet];
    
    // For the filesystem paths, create a sanitized version of the name (for the zip file only)
    NSString *sanitizedName = [[name lowercaseString] stringByReplacingOccurrencesOfString:@" " withString:@"_"];
    NSString *packagePath = [NSTemporaryDirectory() stringByAppendingFormat:@"/%@.zip", sanitizedName];
    
    NSLog(@"[MCDL] Starting download for modpack: %@", name);
    
    // Get the game directory for this modpack
    NSString *gameDir = [PLProfiles uniqueGameDirForProfileName:name];
    
    // Get the full absolute path where we'll extract the modpack
    NSString *destPath = [PLProfiles fullPathForProfileWithName:name gameDir:gameDir];
    
    // Store the game directory in metadata for proper profile creation
    self.metadata[@"gameDir"] = gameDir;
    
    // Create a display name for progress reporting
    NSString *displayName = [NSString stringWithFormat:@"Downloading modpack: %@", name];
    
    // Create success callback for modpack download
    __weak typeof(self) weakSelf = self;
    void(^modpackSuccess)(void) = ^{
        @synchronized(weakSelf) {
            // Reset progress for extraction phase
            weakSelf.progress.totalUnitCount = 1;
            weakSelf.progress.completedUnitCount = 0;
            weakSelf.textProgress.totalUnitCount = 1;
            weakSelf.textProgress.completedUnitCount = 0;
            
            // Add extraction marker to file list
            [weakSelf.fileList addObject:[NSString stringWithFormat:@"Extracting %@", name]];
            
            // Create a progress object for extraction
            NSProgress *extractionProgress = [NSProgress progressWithTotalUnitCount:1];
            [weakSelf.progressList addObject:extractionProgress];
            [weakSelf.progress addChild:extractionProgress withPendingUnitCount:1];
        }
        
        NSLog(@"[MCDL] Modpack download complete, proceeding to extraction.");
        
        // Use the API to handle extraction and installation
        [api downloader:weakSelf submitDownloadTasksFromPackage:packagePath toPath:destPath];
    };
    
    // Failure callback to handle retries for modpack download
    void(^modpackFailure)(NSError *error) = ^(NSError *error) {
        NSLog(@"[MCDL] Failed to download modpack: %@. Retrying...", error.localizedDescription);
        
        // Add retry attempt to file list for UI visibility
        @synchronized(weakSelf.fileList) {
            [weakSelf.fileList addObject:[NSString stringWithFormat:@"Retrying download for %@", name]];
        }
        
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
            // Resume task immediately
            [retryTask resume];
        } else {
            [weakSelf finishDownloadWithErrorString:@"Failed to create retry download task for modpack"];
        }
    };

    // Create initial download task
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

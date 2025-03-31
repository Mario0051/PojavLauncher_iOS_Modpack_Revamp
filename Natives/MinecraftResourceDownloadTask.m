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

// Static keys for objc association
static const void *kIsTrackedByTaskKey = &kIsTrackedByTaskKey;
static const NSInteger kMaxConcurrentDownloads = 6; // Limit concurrent downloads
static const NSTimeInterval kUIUpdateInterval = 0.3; // Update UI every 0.3 seconds
static const NSTimeInterval kDownloadTimeout = 60.0; // 60 second timeout for downloads
static const NSTimeInterval kResourceTimeout = 300.0; // 5 minute timeout for resources

// Class extension to declare private properties
@interface MinecraftResourceDownloadTask ()
@property(nonatomic, readwrite) AFURLSessionManager* manager;
@property(nonatomic, strong) NSLock *progressLock;
@property(nonatomic, strong) NSLock *fileListLock;
@property(nonatomic, strong) NSLock *completionLock;
@property(nonatomic, strong) dispatch_queue_t downloadQueue;
@property(nonatomic, strong) NSMutableArray *pendingDownloads;
@property(nonatomic, assign) NSInteger activeDownloads;
@property(nonatomic, strong) NSTimer *uiUpdateTimer;
@property(nonatomic, assign) BOOL needsUIUpdate;
@property(nonatomic, strong) dispatch_group_t downloadCompletionGroup;
@property(nonatomic, readwrite) BOOL isDownloadPhaseComplete;
@property(nonatomic, assign) NSInteger totalTasksEnqueued;
@property(nonatomic, assign) NSInteger tasksLeftGroup;
@property(nonatomic, strong) NSDate *downloadStartTime;
@end

@implementation MinecraftResourceDownloadTask

- (instancetype)init {
    self = [super init];
    if (self) {
        // Initialize with improved session configuration
        NSURLSessionConfiguration *configuration = [NSURLSessionConfiguration defaultSessionConfiguration];
        configuration.timeoutIntervalForRequest = kDownloadTimeout;
        configuration.timeoutIntervalForResource = kResourceTimeout;
        configuration.HTTPMaximumConnectionsPerHost = kMaxConcurrentDownloads;
        configuration.requestCachePolicy = NSURLRequestReloadIgnoringLocalCacheData;
        
        self.manager = [[AFURLSessionManager alloc] initWithSessionConfiguration:configuration];
        
        // Initialize collections with thread safety in mind
        self.fileList = [NSMutableArray new];
        self.progressList = [NSMutableArray new];
        self.pendingDownloads = [NSMutableArray new];
        self.pendingVerificationList = [NSMutableArray new];
        self.activeDownloads = 0;
        
        // Initialize lock objects
        self.progressLock = [[NSLock alloc] init];
        self.fileListLock = [[NSLock alloc] init];
        self.completionLock = [[NSLock alloc] init];
        
        // Create serial queue for managing downloads
        self.downloadQueue = dispatch_queue_create("net.kdt.pojavlauncher.downloadQueue", DISPATCH_QUEUE_SERIAL);
        
        // Initialize progress tracking
        self.progress = [NSProgress new];
        self.progress.totalUnitCount = 0;
        self.progress.cancellable = YES;
        
        // Initialize text progress for UI updates
        self.textProgress = [NSProgress new];
        self.textProgress.kind = NSProgressKindFile;
        self.textProgress.fileOperationKind = NSProgressFileOperationKindDownloading;
        self.textProgress.totalUnitCount = 0;
        self.textProgress.cancellable = YES;
        
        // Initialize counters
        self.successfulDownloads = 0;
        self.totalDownloads = 0;
        self.verboseLogging = getPrefBool(@"general.debug_logging");
        
        // Initialize verification flag
        self.deferSHAVerification = !getPrefBool(@"general.check_sha");
        
        // Flag to prevent duplicate asset processing
        self.hasProcessedAssets = NO;
        
        // Setup timer for UI updates with lower frequency
        self.needsUIUpdate = NO;
        self.uiUpdateTimer = [NSTimer scheduledTimerWithTimeInterval:kUIUpdateInterval
                                                             target:self
                                                           selector:@selector(processBatchedUIUpdates)
                                                           userInfo:nil
                                                            repeats:YES];
        // Ensure timer runs even during scrolling
        [[NSRunLoop mainRunLoop] addTimer:self.uiUpdateTimer forMode:NSRunLoopCommonModes];
        
        // Initialize download completion tracking
        self.downloadCompletionGroup = dispatch_group_create();
        self.isDownloadPhaseComplete = NO;
        self.totalTasksEnqueued = 0;
        self.tasksLeftGroup = 0;
        self.hasFinishedSetup = NO;
    }
    return self;
}

- (void)dealloc {
    [self cleanupProgressObservers];
    
    // Clear any pending downloads
    @synchronized(self.pendingDownloads) {
        [self.pendingDownloads removeAllObjects];
        self.activeDownloads = 0;
    }
    
    // Invalidate timers
    [self.uiUpdateTimer invalidate];
    self.uiUpdateTimer = nil;
    
    // Invalidate the session manager
    if (self.manager) {
        [self.manager invalidateSessionCancelingTasks:YES resetSession:YES];
        self.manager = nil;
    }
}

#pragma mark - Progress Management

- (void)processBatchedUIUpdates {
    if (!self.needsUIUpdate) return;
    
    // Send a notification for UI components to update
    dispatch_async(dispatch_get_main_queue(), ^{
        [NSNotificationCenter.defaultCenter postNotificationName:@"DownloadProgressUpdated" object:self];
        self.needsUIUpdate = NO;
        
        // Update text progress safely
        [self.progressLock lock];
        if (self.textProgress && self.progress && self.progress.totalUnitCount > 0) {
            self.textProgress.completedUnitCount = self.progress.completedUnitCount;
            self.textProgress.totalUnitCount = self.progress.totalUnitCount;
            
            // Calculate speed and ETA if we have a start time
            if (self.downloadStartTime) {
                NSTimeInterval elapsed = [[NSDate date] timeIntervalSinceDate:self.downloadStartTime];
                if (elapsed > 0 && self.progress.completedUnitCount > 0) {
                    // Calculate bytes per second
                    double bytesPerSecond = self.progress.completedUnitCount / elapsed;
                    self.textProgress.throughput = @(bytesPerSecond);
                    
                    // Calculate estimated time remaining
                    if (bytesPerSecond > 0 && self.progress.fractionCompleted < 1.0) {
                        double remaining = (self.progress.totalUnitCount - self.progress.completedUnitCount) / bytesPerSecond;
                        self.textProgress.estimatedTimeRemaining = @(remaining);
                    }
                }
            }
        }
        [self.progressLock unlock];
    });
}

- (void)prepareForDownload {
    @synchronized(self) {
        // Create new progress tracking objects
        self.progress = [NSProgress new];
        self.progress.totalUnitCount = 0;
        self.progress.cancellable = YES;
        
        self.textProgress = [NSProgress new];
        self.textProgress.kind = NSProgressKindFile;
        self.textProgress.fileOperationKind = NSProgressFileOperationKindDownloading;
        self.textProgress.totalUnitCount = 0;
        self.textProgress.cancellable = YES;
        
        // Reset counters
        self.successfulDownloads = 0;
        self.totalDownloads = 0;
        self.totalTasksEnqueued = 0;
        self.tasksLeftGroup = 0;
        
        // Reset flags
        self.hasProcessedAssets = NO;
        self.isDownloadPhaseComplete = NO;
        self.hasFinishedSetup = NO;
        
        // Set download start time for speed calculations
        self.downloadStartTime = [NSDate date];
    }
    
    // Reset tracking lists with synchronization
    [self.fileListLock lock];
    [self.fileList removeAllObjects];
    [self.fileListLock unlock];
    
    [self.progressLock lock];
    [self.progressList removeAllObjects];
    [self.progressLock unlock];
    
    // Reset download queue
    @synchronized(self.pendingDownloads) {
        [self.pendingDownloads removeAllObjects];
        self.activeDownloads = 0;
    }
    
    // Reset verification list
    @synchronized(self.pendingVerificationList) {
        [self.pendingVerificationList removeAllObjects];
    }
    
    // Flag UI update
    self.needsUIUpdate = YES;
    
    // Check SHA verification preference
    self.deferSHAVerification = !getPrefBool(@"general.check_sha");
}

#pragma mark - Completion Management

- (void)safelyLeaveDispatchGroup:(NSString *)reason {
    [self.completionLock lock];
    self.tasksLeftGroup++;
    if (self.verboseLogging) {
        NSLog(@"[MCDL] Task left group (%@). Total Left: %ld, Total Enqueued: %ld", 
              reason, (long)self.tasksLeftGroup, (long)self.totalTasksEnqueued);
    }
    BOOL shouldCheckCompletion = (self.tasksLeftGroup >= self.totalTasksEnqueued && self.totalTasksEnqueued > 0);
    [self.completionLock unlock];
    
    dispatch_group_leave(self.downloadCompletionGroup);
    
    if (shouldCheckCompletion) {
        [self checkFinalCompletion];
    }
}

- (void)markDownloadPhaseComplete:(BOOL)complete {
    [self.completionLock lock];
    BOOL oldValue = self.isDownloadPhaseComplete;
    
    if (oldValue != complete) {
        [self willChangeValueForKey:@"isDownloadPhaseComplete"];
        _isDownloadPhaseComplete = complete;
        [self didChangeValueForKey:@"isDownloadPhaseComplete"];
        
        if (self.verboseLogging) {
            NSLog(@"[MCDL] Download phase completion state changed: %@ -> %@", 
                  oldValue ? @"YES" : @"NO", complete ? @"YES" : @"NO");
        }
        
        // Add completion marker to fileList
        if (complete) {
            [self.fileListLock lock];
            if (![self.fileList containsObject:@"Complete"]) {
                [self.fileList addObject:@"Complete"];
                self.needsUIUpdate = YES;
            }
            [self.fileListLock unlock];
        }
    }
    [self.completionLock unlock];
}

- (void)checkFinalCompletion {
    if (self.verboseLogging) {
        NSLog(@"[MCDL] All enqueued tasks have left the group. Proceeding to final checks.");
    }
    
    __weak typeof(self) weakSelf = self;
    dispatch_async(dispatch_get_global_queue(DISPATCH_QUEUE_PRIORITY_DEFAULT, 0), ^{
        if (!weakSelf) return;
        
        // Check for pending downloads
        BOOL hasActiveDownloads = NO;
        @synchronized(weakSelf.pendingDownloads) {
            hasActiveDownloads = (weakSelf.pendingDownloads.count > 0 || weakSelf.activeDownloads > 0);
        }
        
        if (hasActiveDownloads) {
            if (weakSelf.verboseLogging) {
                NSLog(@"[MCDL] Warning: Tasks left dispatch group but downloads are still active. Delaying completion.");
            }
            return;
        }
        
        // Check for pending verifications
        BOOL hasPendingVerifications = NO;
        @synchronized(weakSelf.pendingVerificationList) {
            hasPendingVerifications = (weakSelf.pendingVerificationList.count > 0);
        }
        
        // Verify any pending files
        BOOL verificationSuccess = YES;
        if (hasPendingVerifications) {
            if (weakSelf.verboseLogging) {
                NSLog(@"[MCDL] Starting verification of pending files...");
            }
            verificationSuccess = [weakSelf verifyPendingFiles];
            if (!verificationSuccess) {
                if (weakSelf.verboseLogging) {
                    NSLog(@"[MCDL] Verification failed, redownload initiated. Completion delayed.");
                }
                return;
            }
        }
        
        if (verificationSuccess) {
            BOOL alreadyComplete = NO;
            [weakSelf.completionLock lock];
            alreadyComplete = weakSelf.isDownloadPhaseComplete;
            [weakSelf.completionLock unlock];
            
            if (!alreadyComplete) {
                if (weakSelf.verboseLogging) {
                    NSLog(@"[MCDL] All tasks truly complete and verified.");
                }
                
                // Ensure progress is complete
                [weakSelf.progressLock lock];
                if (weakSelf.progress.totalUnitCount <= 0) {
                    weakSelf.progress.totalUnitCount = 1;
                    weakSelf.textProgress.totalUnitCount = 1;
                }
                weakSelf.progress.completedUnitCount = weakSelf.progress.totalUnitCount;
                weakSelf.textProgress.completedUnitCount = weakSelf.textProgress.totalUnitCount;
                [weakSelf.progressLock unlock];
                
                // Validate metadata before signaling completion
                BOOL metadataValid = NO;
                @synchronized(weakSelf) {
                    // Check if this is a modpack installation
                    BOOL isModpackInstall = NO;
                    if (weakSelf.metadata && weakSelf.metadata[@"isModpackInstall"]) {
                        isModpackInstall = [weakSelf.metadata[@"isModpackInstall"] boolValue];
                    }
                    
                    // For regular Minecraft installations, ensure we have valid metadata with an ID
                    if (!isModpackInstall) {
                        metadataValid = (weakSelf.metadata != nil && weakSelf.metadata[@"id"] != nil);
                        
                        if (!metadataValid && !weakSelf.progress.cancelled) {
                            NSLog(@"[MCDL] Warning: Download completed but metadata is incomplete or missing required keys. Delaying completion.");
                            
                            // Schedule a retry after a short delay
                            dispatch_after(dispatch_time(DISPATCH_TIME_NOW, (int64_t)(0.5 * NSEC_PER_SEC)), dispatch_get_global_queue(DISPATCH_QUEUE_PRIORITY_DEFAULT, 0), ^{
                                [weakSelf checkFinalCompletion];
                            });
                            return;
                        }
                        
                        if (weakSelf.verboseLogging) {
                            NSLog(@"[MCDL] Metadata validation passed. ID: %@", weakSelf.metadata[@"id"]);
                        }
                    } else {
                        // For modpacks, we don't need to validate the same way
                        metadataValid = YES;
                    }
                }
                
                // Only mark complete if metadata is valid
                if (metadataValid) {
                    [weakSelf markDownloadPhaseComplete:YES];
                    
                    // Final UI update
                    weakSelf.needsUIUpdate = YES;
                    [weakSelf processBatchedUIUpdates];
                }
            }
        }
    });
}

#pragma mark - Download Queue Management

- (void)processNextDownloadInQueue {
    @synchronized(self.pendingDownloads) {
        // Check concurrency limits and queue state
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
            // Clear all pending downloads
            NSInteger countToLeave = self.pendingDownloads.count;
            [self.pendingDownloads removeAllObjects];
            self.activeDownloads = 0;
            
            // Leave the group for cancelled tasks
            for (NSInteger i = 0; i < countToLeave; i++) {
                [self safelyLeaveDispatchGroup:@"CancelledPendingQueue"];
            }
            return;
        }
        
        // Get next download task and start it
        NSURLSessionDownloadTask *nextTask = self.pendingDownloads[0];
        [self.pendingDownloads removeObjectAtIndex:0];
        self.activeDownloads++;
        
        // Resume task on background thread
        dispatch_async(dispatch_get_global_queue(DISPATCH_QUEUE_PRIORITY_DEFAULT, 0), ^{
            BOOL isCancelledBeforeResume = NO;
            @try {
                isCancelledBeforeResume = self.progress.cancelled;
            } @catch (NSException *exception) {}
            
            if (!isCancelledBeforeResume) {
                [nextTask resume];
            } else {
                // If cancelled before resume, decrement active count and leave the group
                @synchronized(self.pendingDownloads) {
                    self.activeDownloads--;
                }
                [self safelyLeaveDispatchGroup:@"CancelledBeforeResume"];
                
                // Process next if possible
                dispatch_async(self.downloadQueue, ^{
                    [self processNextDownloadInQueue];
                });
            }
        });
        
        // Process another task if below concurrent limit
        if (self.activeDownloads < kMaxConcurrentDownloads && self.pendingDownloads.count > 0) {
            dispatch_async(self.downloadQueue, ^{
                [self processNextDownloadInQueue];
            });
        }
    }
}

#pragma mark - Download Task Creation

- (NSURLSessionDownloadTask *)createDownloadTask:(NSString *)url
                                           size:(NSUInteger)size
                                            sha:(NSString *)sha
                                        altName:(NSString *)altName
                                         toPath:(NSString *)path
                                        success:(void (^)(void))success
                                        failure:(void (^)(NSError *error))failure {
    @autoreleasepool {
        // Validate URL
        if (!url || url.length == 0) {
            NSLog(@"[MCDL] Error: Invalid or empty download URL for %@", altName ?: path.lastPathComponent);
            
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
        
        // Enter dispatch group before checking cache
        dispatch_group_enter(self.downloadCompletionGroup);
        
        [self.completionLock lock];
        self.totalTasksEnqueued++;
        [self.completionLock unlock];
        
        // Track total downloads
        self.totalDownloads++;
        
        // Check if file exists and has valid SHA
        BOOL fileExists = [NSFileManager.defaultManager fileExistsAtPath:path];
        BOOL isVersionFile = [path hasSuffix:@".json"] && [path containsString:@"/versions/"];
        BOOL isLatestVersionFile = [path containsString:@"latest-release"] || [path containsString:@"latest-snapshot"];
        
        // Determine if we should verify now or defer
        BOOL shouldVerifyNow = !self.deferSHAVerification || isVersionFile || isLatestVersionFile;
        
        if (shouldVerifyNow && fileExists && sha && sha.length > 0 && [self checkSHA:sha forFile:path altName:altName]) {
            // Use estimated size if actual size is 0
            NSUInteger itemSize = size > 0 ? size : 100000;
            
            [self.progressLock lock];
            self.progress.totalUnitCount += itemSize;
            self.progress.completedUnitCount += itemSize;
            self.textProgress.totalUnitCount = self.progress.totalUnitCount;
            self.textProgress.completedUnitCount = self.progress.completedUnitCount;
            [self.progressLock unlock];
            
            // Increment successful downloads counter
            self.successfulDownloads++;
            
            // Periodic logging
            if (self.verboseLogging && self.successfulDownloads % 50 == 0) {
                NSLog(@"[MCDL] Progress: %ld of %ld files verified/downloaded",
                      (long)self.successfulDownloads, (long)self.totalDownloads);
            }
            
            // Handle success callback
            if (success) {
                dispatch_async(dispatch_get_global_queue(DISPATCH_QUEUE_PRIORITY_DEFAULT, 0), ^{
                    success();
                });
            }
            
            // Leave group for cached file
            [self safelyLeaveDispatchGroup:@"CachedFile"];
            return nil;
        } else if (fileExists && self.deferSHAVerification && sha && sha.length > 0) {
            // File exists, but we're deferring SHA verification
            [self addFileToVerificationList:path sha:sha altName:altName url:url size:size];
            
            // Update progress
            NSUInteger itemSize = size > 0 ? size : 100000;
            
            [self.progressLock lock];
            self.progress.totalUnitCount += itemSize;
            self.progress.completedUnitCount += itemSize;
            self.textProgress.totalUnitCount = self.progress.totalUnitCount;
            self.textProgress.completedUnitCount = self.progress.completedUnitCount;
            [self.progressLock unlock];
            
            self.successfulDownloads++;
            
            if (success) {
                dispatch_async(dispatch_get_global_queue(DISPATCH_QUEUE_PRIORITY_DEFAULT, 0), ^{
                    success();
                });
            }
            
            [self safelyLeaveDispatchGroup:@"DeferredVerification"];
            return nil;
        } else if (![self checkAccessWithDialog:YES]) {
            [self safelyLeaveDispatchGroup:@"AccessDenied"];
            self.totalDownloads--;
            return nil;
        }
        
        // Use filename as display name if none provided
        NSString *name = altName ?: path.lastPathComponent;
        
        // Create URL request
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
            
            [self safelyLeaveDispatchGroup:@"InvalidURL"];
            self.totalDownloads--;
            return nil;
        }
        
        NSMutableURLRequest *request = [NSMutableURLRequest requestWithURL:requestURL];
        request.timeoutInterval = kDownloadTimeout;
        request.cachePolicy = NSURLRequestReloadIgnoringLocalCacheData;
        
        // Add to file list for UI tracking
        [self.fileListLock lock];
        if (![self.fileList containsObject:name]) {
            [self.fileList addObject:name];
            self.needsUIUpdate = YES;
        }
        [self.fileListLock unlock];
        
        // Create and track progress
        NSUInteger estimatedSize = size > 0 ? size : 100000;
        NSProgress *downloadProgress = [NSProgress progressWithTotalUnitCount:estimatedSize];
        downloadProgress.kind = NSProgressKindFile;
        
        // Add to tracking list
        BOOL progressAdded = NO;
        
        [self.progressLock lock];
        @try {
            [self.progressList addObject:downloadProgress];
            
            // Update total progress
            self.progress.totalUnitCount += downloadProgress.totalUnitCount;
            self.textProgress.totalUnitCount = self.progress.totalUnitCount;
            
            // Add child progress
            [self.progress addChild:downloadProgress withPendingUnitCount:downloadProgress.totalUnitCount];
            
            // Mark progress as tracked
            objc_setAssociatedObject(downloadProgress, kIsTrackedByTaskKey, @YES, OBJC_ASSOCIATION_RETAIN_NONATOMIC);
            progressAdded = YES;
        } @catch (NSException *exception) {
            NSLog(@"[MCDL] Exception adding progress: %@", exception);
            
            [self.fileListLock lock];
            if ([self.fileList.lastObject isEqual:name]) {
                [self.fileList removeLastObject];
            }
            [self.fileListLock unlock];
            
            self.totalDownloads--;
            [self safelyLeaveDispatchGroup:@"ProgressAddFail"];
            return nil;
        }
        [self.progressLock unlock];
        
        if (!progressAdded) {
            NSLog(@"[MCDL] Failed to add progress for %@", name);
            [self safelyLeaveDispatchGroup:@"ProgressAddFail2"];
            self.totalDownloads--;
            return nil;
        }
        
        // Create weak reference to self to avoid retain cycles
        __weak typeof(self) weakSelf = self;
        
        // Create download task with proper completion handling
        __block NSURLSessionDownloadTask *task = [self.manager downloadTaskWithRequest:request progress:^(NSProgress * _Nonnull taskProgress) {
            // Only update on significant changes to reduce overhead
            static NSInteger lastReportedPercent = -1;
            NSInteger currentPercent = (NSInteger)(taskProgress.fractionCompleted * 100);
            
            if (currentPercent != lastReportedPercent && (currentPercent % 5 == 0 || currentPercent == 100)) {
                lastReportedPercent = currentPercent;
                
                // Update progress safely
                @synchronized(weakSelf) {
                    if (!weakSelf) return;
                    @try {
                        CGFloat fraction = taskProgress.fractionCompleted;
                        if (!isnan(fraction) && fraction >= 0 && fraction <= 1.0) {
                            downloadProgress.completedUnitCount = (NSInteger)(downloadProgress.totalUnitCount * fraction);
                        }
                    } @catch (NSException *exception) {
                        NSLog(@"[MCDL] Exception in progress update: %@", exception);
                    }
                }
            }
        } destination:^NSURL * _Nonnull(NSURL * _Nonnull targetPath, NSURLResponse * _Nonnull response) {
            if (!weakSelf) return nil;
            
            // Update progress size if response has content length
            if (size == 0 && response.expectedContentLength > 0) {
                NSUInteger actualSize = (NSUInteger)response.expectedContentLength;
                
                [weakSelf.progressLock lock];
                @try {
                    NSUInteger oldSize = downloadProgress.totalUnitCount;
                    downloadProgress.totalUnitCount = actualSize;
                    
                    if (weakSelf.progress && !weakSelf.progress.cancelled) {
                        weakSelf.progress.totalUnitCount = MAX(0, weakSelf.progress.totalUnitCount - oldSize + actualSize);
                    }
                    
                    if (weakSelf.textProgress && !weakSelf.textProgress.cancelled) {
                        weakSelf.textProgress.totalUnitCount = weakSelf.progress.totalUnitCount;
                    }
                } @catch (NSException *exception) {
                    NSLog(@"[MCDL] Exception updating progress size: %@", exception);
                }
                [weakSelf.progressLock unlock];
            }
            
            // Create directory structure
            NSString *dirPath = [path stringByDeletingLastPathComponent];
            NSError *dirError = nil;
            [[NSFileManager defaultManager] createDirectoryAtPath:dirPath
                                       withIntermediateDirectories:YES
                                                        attributes:nil
                                                             error:&dirError];
            
            if (dirError && dirError.code != NSFileWriteFileExistsError) {
                NSLog(@"[MCDL] Warning: Could not create directory at %@: %@",
                      dirPath, dirError ? dirError.localizedDescription : @"Unknown error");
            }
            
            // Remove existing file if needed
            if ([NSFileManager.defaultManager fileExistsAtPath:path]) {
                NSError *removeError = nil;
                [NSFileManager.defaultManager removeItemAtPath:path error:&removeError];
                
                if (removeError) {
                    NSLog(@"[MCDL] Warning: Could not remove existing file at %@: %@",
                          path, removeError.localizedDescription);
                }
            }
            
            return [NSURL fileURLWithPath:path];
        } completionHandler:^(NSURLResponse * _Nonnull response, NSURL * _Nullable filePath, NSError * _Nullable error) {
            if (!weakSelf) return;
            
            // Decrement active downloads count
            @synchronized(weakSelf.pendingDownloads) {
                weakSelf.activeDownloads--;
            }
            
            // Check if cancelled
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
                [weakSelf safelyLeaveDispatchGroup:@"Cancelled"];
                return;
            }
            
            if (error) {
                NSLog(@"[MCDL] Download error for %@: %@", name, error.localizedDescription);
                
                if (failure) {
                    dispatch_async(dispatch_get_global_queue(DISPATCH_QUEUE_PRIORITY_DEFAULT, 0), ^{
                        failure(error);
                        [weakSelf safelyLeaveDispatchGroup:@"DownloadError"];
                    });
                } else {
                    [weakSelf finishDownloadWithError:error file:name];
                    [weakSelf safelyLeaveDispatchGroup:@"DownloadErrorFinish"];
                }
                return;
            }
            
            // Increment successful download counter
            weakSelf.successfulDownloads++;
            
            // Log progress periodically
            if (weakSelf.verboseLogging && weakSelf.successfulDownloads % 50 == 0) {
                NSLog(@"[MCDL] Progress: %ld of %ld files downloaded",
                      (long)weakSelf.successfulDownloads, (long)weakSelf.totalDownloads);
            }
            
            // Verify downloaded file if checksum is provided
            BOOL shaValid = YES;
            if (sha.length > 0 && !weakSelf.deferSHAVerification) {
                shaValid = [weakSelf checkSHAIgnorePref:sha forFile:path altName:altName logSuccess:NO];
                
                if (!shaValid) {
                    NSLog(@"[MCDL] SHA1 verification failed for %@", path.lastPathComponent);
                    
                    // Version files can continue with SHA mismatch
                    if (isVersionFile) {
                        NSLog(@"[MCDL] Version file SHA mismatch but continuing: %@", path.lastPathComponent);
                        shaValid = YES;
                    } else {
                        NSError *shaError = [NSError errorWithDomain:@"net.kdt.pojavlauncher"
                                                           code:1000
                                                       userInfo:@{NSLocalizedDescriptionKey: 
                                                                 [NSString stringWithFormat:@"Failed to verify file %@: SHA1 mismatch", 
                                                                  path.lastPathComponent]}];
                        
                        weakSelf.successfulDownloads--;
                        
                        if (failure) {
                            dispatch_async(dispatch_get_global_queue(DISPATCH_QUEUE_PRIORITY_DEFAULT, 0), ^{
                                failure(shaError);
                                [weakSelf safelyLeaveDispatchGroup:@"SHAFailure"];
                            });
                        } else {
                            [weakSelf finishDownloadWithErrorString:[NSString stringWithFormat:@"Failed to verify file %@: SHA1 mismatch", 
                                                                    path.lastPathComponent]];
                            [weakSelf safelyLeaveDispatchGroup:@"SHAFailureFinish"];
                        }
                        return;
                    }
                }
            } else if (sha.length > 0 && weakSelf.deferSHAVerification) {
                // Add to verification list for later checking
                [weakSelf addFileToVerificationList:path sha:sha altName:altName url:url size:size];
            }
            
            // Mark progress as complete
            @synchronized(weakSelf) {
                @try {
                    if (downloadProgress.totalUnitCount > 0) {
                        downloadProgress.completedUnitCount = downloadProgress.totalUnitCount;
                    } else {
                        downloadProgress.completedUnitCount = 1;
                        downloadProgress.totalUnitCount = 1;
                    }
                    weakSelf.needsUIUpdate = YES;
                } @catch (NSException *exception) {
                    NSLog(@"[MCDL] Exception marking progress complete: %@", exception);
                }
            }
            
            // Call success callback if SHA is valid
            if (success && shaValid) {
                dispatch_async(dispatch_get_global_queue(DISPATCH_QUEUE_PRIORITY_DEFAULT, 0), ^{
                    success();
                });
            }
            
            // Leave dispatch group
            [weakSelf safelyLeaveDispatchGroup:@"Success"];
            
            // Process next in queue if needed
            dispatch_async(weakSelf.downloadQueue, ^{
                [weakSelf processNextDownloadInQueue];
            });
        }];
        
        // Add task to pending queue
        @synchronized(self.pendingDownloads) {
            [self.pendingDownloads addObject:task];
        }
        
        // Trigger queue processing
        dispatch_async(self.downloadQueue, ^{
            [self processNextDownloadInQueue];
        });
        
        return task;
    }
}

#pragma mark - Legacy API Compatibility

- (NSURLSessionDownloadTask *)createDownloadTask:(NSString *)url size:(NSUInteger)size sha:(NSString *)sha altName:(NSString *)altName toPath:(NSString *)path success:(void (^)(void))success {
    return [self createDownloadTask:url size:size sha:sha altName:altName toPath:path success:success failure:nil];
}

- (NSURLSessionDownloadTask *)createDownloadTask:(NSString *)url size:(NSUInteger)size sha:(NSString *)sha altName:(NSString *)altName toPath:(NSString *)path {
    return [self createDownloadTask:url size:size sha:sha altName:altName toPath:path success:nil failure:nil];
}

#pragma mark - File Verification

- (void)addFileToVerificationList:(NSString *)path sha:(NSString *)sha altName:(NSString *)altName url:(NSString *)url size:(NSUInteger)size {
    @synchronized(self.pendingVerificationList) {
        NSDictionary *verificationItem = @{
            @"path": path,
            @"sha": sha,
            @"altName": altName ?: [NSNull null],
            @"url": url,
            @"size": @(size)
        };
        
        [self.pendingVerificationList addObject:verificationItem];
    }
}

- (BOOL)verifyPendingFiles {
    // Make a thread-safe copy of verification list
    NSArray *verificationItems;
    
    @synchronized(self.pendingVerificationList) {
        if (self.pendingVerificationList.count == 0) {
            return YES;
        }
        
        verificationItems = [NSArray arrayWithArray:self.pendingVerificationList];
        [self.pendingVerificationList removeAllObjects];
    }
    
    if (self.verboseLogging) {
        NSLog(@"[MCDL] Verifying %lu files", (unsigned long)verificationItems.count);
    }
    
    // Track failed items
    NSMutableArray *failedItems = [NSMutableArray array];
    
    // Verify each file
    NSUInteger verifiedCount = 0;
    for (NSDictionary *item in verificationItems) {
        NSString *path = item[@"path"];
        NSString *sha = item[@"sha"];
        NSString *altName = [item[@"altName"] isEqual:[NSNull null]] ? nil : item[@"altName"];
        
        if (![NSFileManager.defaultManager fileExistsAtPath:path] ||
            ![self checkSHAIgnorePref:sha forFile:path altName:altName logSuccess:NO]) {
            [failedItems addObject:item];
        } else {
            verifiedCount++;
        }
    }
    
    // Handle failed verifications
    if (failedItems.count > 0) {
        NSLog(@"[MCDL] %lu files failed verification and will be redownloaded", (unsigned long)failedItems.count);
        
        // Adjust progress for redownloads
        [self.progressLock lock];
        NSUInteger sizeToSubtract = 0;
        for (NSDictionary *item in failedItems) {
            sizeToSubtract += [item[@"size"] unsignedIntegerValue] > 0 ? [item[@"size"] unsignedIntegerValue] : 100000;
        }
        self.progress.completedUnitCount = MAX(0, self.progress.completedUnitCount - sizeToSubtract);
        self.textProgress.completedUnitCount = self.progress.completedUnitCount;
        [self.progressLock unlock];
        
        // Adjust counters for redownloads
        self.successfulDownloads -= failedItems.count;
        self.totalDownloads = failedItems.count;
        
        // Reset group counters
        [self.completionLock lock];
        self.totalTasksEnqueued = 0;
        self.tasksLeftGroup = 0;
        [self.completionLock unlock];
        
        self.isDownloadPhaseComplete = NO;
        
        // Force immediate verification for redownloads
        self.deferSHAVerification = NO;
        
        // Redownload failed files
        for (NSDictionary *item in failedItems) {
            NSString *path = item[@"path"];
            NSString *sha = item[@"sha"];
            NSString *altName = [item[@"altName"] isEqual:[NSNull null]] ? nil : item[@"altName"];
            NSString *url = item[@"url"];
            NSUInteger size = [item[@"size"] unsignedIntegerValue];
            
            [self redownloadFileWithPath:path sha:sha altName:altName url:url size:size];
        }
        
        return NO;
    }
    
    if (self.verboseLogging) {
        NSLog(@"[MCDL] All %lu files verified successfully", (unsigned long)verifiedCount);
    }
    
    return YES;
}

- (void)redownloadFileWithPath:(NSString *)path sha:(NSString *)sha altName:(NSString *)altName url:(NSString *)url size:(NSUInteger)size {
    if (self.verboseLogging) {
        NSLog(@"[MCDL] Redownloading file: %@", altName ?: path.lastPathComponent);
    }
    
    [self createDownloadTask:url size:size sha:sha altName:altName toPath:path success:nil failure:nil];
}

- (BOOL)checkSHAIgnorePref:(NSString *)sha forFile:(NSString *)path altName:(NSString *)altName logSuccess:(BOOL)logSuccess {
    if (sha.length == 0) {
        // When no SHA is provided, just check file existence
        return [NSFileManager.defaultManager fileExistsAtPath:path];
    }
    
    // Check file attributes
    NSError *attributesError = nil;
    NSDictionary *fileAttributes = [[NSFileManager defaultManager] attributesOfItemAtPath:path error:&attributesError];
    
    if (attributesError || !fileAttributes) {
        return NO;
    }
    
    // Reject zero-size files
    unsigned long long fileSize = [fileAttributes fileSize];
    if (fileSize == 0) {
        NSLog(@"[MCDL] SHA1 checker: file exists but has zero size: %@", path.lastPathComponent);
        return NO;
    }
    
    // Read file data
    NSData *data = [NSData dataWithContentsOfFile:path options:NSDataReadingMappedIfSafe error:nil];
    if (!data) {
        NSLog(@"[MCDL] SHA1 checker: file doesn't exist or couldn't be read: %@", 
              altName ? altName : path.lastPathComponent);
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
    
    // Log failures and optionally successes
    if (!check) {
        NSLog(@"[MCDL] SHA1 failed for %@", altName ? altName : path.lastPathComponent);
        NSLog(@"[MCDL] Expected: %@", sha);
        NSLog(@"[MCDL]Got:      %@", localSHA);
        NSLog(@"[MCDL] File size: %llu bytes", fileSize);
    } else if (logSuccess && self.verboseLogging) {
        NSLog(@"[MCDL] SHA1 verified for %@", altName ? altName : path.lastPathComponent);
    }
    
    return check;
}

- (BOOL)checkSHA:(NSString *)sha forFile:(NSString *)path altName:(NSString *)altName {
    // Force download for latest version files
    if (altName && [altName hasSuffix:@".json"] && 
        ([altName containsString:@"latest-release"] || [altName containsString:@"latest-snapshot"])) {
        if (self.verboseLogging) {
            NSLog(@"[MCDL] Forcing download of latest version file: %@", altName);
        }
        return NO;
    }
    
    // For specific version files, check existence
    if (([altName hasSuffix:@".json"] && [path containsString:@"/versions/"]) ||
        ([path containsString:@"/versions/"] && [path hasSuffix:@".jar"])) {
        
        BOOL fileExists = [NSFileManager.defaultManager fileExistsAtPath:path];
        if (!fileExists) {
            if (self.verboseLogging) {
                NSLog(@"[MCDL] Version file doesn't exist, downloading: %@", altName);
            }
            return NO;
        }
    }
    
    // Respect user preference for SHA checking
    return [self checkSHA:sha forFile:path altName:altName logSuccess:NO];
}

- (BOOL)checkSHA:(NSString *)sha forFile:(NSString *)path altName:(NSString *)altName logSuccess:(BOOL)logSuccess {
    if (getPrefBool(@"general.check_sha")) {
        return [self checkSHAIgnorePref:sha forFile:path altName:altName logSuccess:logSuccess];
    } else {
        // When SHA checking is disabled, just check file existence
        return [NSFileManager.defaultManager fileExistsAtPath:path];
    }
}

#pragma mark - Account Validation

- (BOOL)checkAccessWithDialog:(BOOL)show {
    // Check if account is allowed to download Minecraft
    BOOL accessible = [BaseAuthenticator.current.authData[@"username"] hasPrefix:@"Demo."] || 
                      BaseAuthenticator.current.authData[@"xboxGamertag"] != nil;
    
    if (!accessible) {
        // Cancel download if not accessible
        [self.progressLock lock];
        @try {
            [self.progress cancel];
            [self.textProgress cancel];
        } @catch (NSException *exception) {
            NSLog(@"[MCDL] Warning: Exception cancelling progress: %@", exception);
        }
        [self.progressLock unlock];
        
        self.isDownloadPhaseComplete = YES;
        
        // Show error dialog if requested
        if (show) {
            [self finishDownloadWithErrorString:@"Minecraft can't be legally installed when logged in with a local account. Please switch to an online account to continue."];
        }
    }
    
    return accessible;
}

#pragma mark - Error Handling

- (void)finishDownloadWithError:(NSError *)error file:(NSString *)file {
    NSString *errorStr = [NSString stringWithFormat:localize(@"launcher.mcl.error_download", NULL), 
                          file, error.localizedDescription];
    NSLog(@"[MCDL] Error: %@", errorStr);
    [self finishDownloadWithErrorString:errorStr];
}

- (void)finishDownloadWithErrorString:(NSString *)error {
    // Cancel progress
    [self.progressLock lock];
    @try {
        [self.progress cancel];
        [self.textProgress cancel];
    } @catch (NSException *exception) {
        NSLog(@"[MCDL] Warning: Exception cancelling progress: %@", exception);
    }
    [self.progressLock unlock];
    
    [self markDownloadPhaseComplete:YES];
    
    // Cancel all active downloads
    [self.manager invalidateSessionCancelingTasks:YES resetSession:YES];
    
    // Clear pending downloads
    @synchronized(self.pendingDownloads) {
        NSInteger countToLeave = self.pendingDownloads.count;
        [self.pendingDownloads removeAllObjects];
        self.activeDownloads = 0;
        
        // Leave the group for cancelled pending tasks
        for (NSInteger i = 0; i < countToLeave; i++) {
            [self safelyLeaveDispatchGroup:@"CancelledPendingOnError"];
        }
    }
    
    // Show error dialog
    dispatch_async(dispatch_get_main_queue(), ^{
        showDialog(localize(@"Error", nil), error);
    });
    
    // Call error handler if set
    if (self.handleError) {
        dispatch_async(dispatch_get_global_queue(DISPATCH_QUEUE_PRIORITY_DEFAULT, 0), ^{
            self.handleError();
        });
    }
}

- (void)cleanupProgressObservers {
    // Cancel main progress
    [self.progressLock lock];
    if (self.progress) {
        @try {
            [self.progress cancel];
        } @catch (NSException *exception) {
            NSLog(@"[MCDL] Exception cancelling progress: %@", exception);
        }
    }
    
    // Cancel individual progress objects
    for (NSProgress *childProgress in [self.progressList copy]) {
        if ([childProgress isKindOfClass:[NSProgress class]]) {
            @try {
                [childProgress cancel];
            } @catch (NSException *exception) {
                NSLog(@"[MCDL] Exception cancelling child progress: %@", exception);
            }
        }
    }
    [self.progressList removeAllObjects];
    
    // Cancel text progress
    if (self.textProgress) {
        @try {
            [self.textProgress cancel];
        } @catch (NSException *exception) {
            NSLog(@"[MCDL] Exception cancelling text progress: %@", exception);
        }
    }
    [self.progressLock unlock];
    
    // Invalidate timer
    if (self.uiUpdateTimer) {
        [self.uiUpdateTimer invalidate];
        self.uiUpdateTimer = nil;
    }
    
    // Mark completion
    self.isDownloadPhaseComplete = YES;
}

#pragma mark - Resource Download Methods

- (void)downloadVersion:(NSDictionary *)version {
    // Prepare download state
    [self prepareForDownload];
    
    // Reset metadata
    @synchronized(self) {
        if (!self.metadata) {
            self.metadata = [NSMutableDictionary dictionary];
        } else {
            [self.metadata removeAllObjects];
        }
        self.metadata[@"isModpackInstall"] = @NO;
        self.isDownloadPhaseComplete = NO;
    }
    
    NSLog(@"[MCDL] Starting download for version: %@", version[@"id"]);
    
    // Setup completion gate
    self.hasFinishedSetup = NO;
    
    // Enter group twice - for metadata and gate
    dispatch_group_enter(self.downloadCompletionGroup);
    dispatch_group_enter(self.downloadCompletionGroup);
    
    [self.completionLock lock];
    self.totalTasksEnqueued += 2;
    [self.completionLock unlock];
    
    // Setup completion notification
    __weak typeof(self) weakSelf = self;
    dispatch_group_notify(self.downloadCompletionGroup, dispatch_get_global_queue(DISPATCH_QUEUE_PRIORITY_DEFAULT, 0), ^{
        [weakSelf checkFinalCompletion];
    });
    
    // Start with metadata download
    [self downloadVersionMetadata:version success:^{
        // Process all other downloads
        [weakSelf processPostMetadataDownloads];
        
        // Leave group for metadata phase
        [weakSelf safelyLeaveDispatchGroup:@"MetadataPhase"];
        
        // Mark setup complete and start monitoring
        dispatch_async(dispatch_get_global_queue(DISPATCH_QUEUE_PRIORITY_DEFAULT, 0), ^{
            // Give queue time to start downloads
            sleep(1);
            [weakSelf finalizeSetup];
        });
    }];
}

- (void)finalizeSetup {
    @synchronized(self) {
        if (self.hasFinishedSetup) return;
        
        self.hasFinishedSetup = YES;
        
        // Check for active downloads or pending verifications
        BOOL hasActiveDownloads = NO;
        @synchronized(self.pendingDownloads) {
            hasActiveDownloads = (self.pendingDownloads.count > 0 || self.activeDownloads > 0);
        }
        
        BOOL hasPendingVerifications = NO;
        @synchronized(self.pendingVerificationList) {
            hasPendingVerifications = (self.pendingVerificationList.count > 0);
        }
        
        if (hasActiveDownloads || hasPendingVerifications) {
            if (self.verboseLogging) {
                NSLog(@"[MCDL] Setup complete but downloads/verifications still in progress. Starting download monitor.");
            }
            [self startDownloadMonitor];
        } else {
            if (self.verboseLogging) {
                NSLog(@"[MCDL] Setup complete and no downloads in progress. Removing gate.");
            }
            [self safelyLeaveDispatchGroup:@"GateRemoval"];
        }
    }
}

- (void)startDownloadMonitor {
    __weak typeof(self) weakSelf = self;
    
    dispatch_async(dispatch_get_global_queue(DISPATCH_QUEUE_PRIORITY_DEFAULT, 0), ^{
        // Monitor loop - check every second for up to 2 minutes
        for (int i = 0; i < 120; i++) {
            sleep(1);
            
            if (!weakSelf) return;
            
            // Check for pending downloads
            BOOL downloadsPending = NO;
            @synchronized(weakSelf.pendingDownloads) {
                downloadsPending = (weakSelf.pendingDownloads.count > 0 || weakSelf.activeDownloads > 0);
            }
            
            // Check for pending verifications
            BOOL verificationsPending = NO;
            @synchronized(weakSelf.pendingVerificationList) {
                verificationsPending = (weakSelf.pendingVerificationList.count > 0);
            }
            
            // If everything is done, leave the group
            if (!downloadsPending && !verificationsPending) {
                if (weakSelf.verboseLogging) {
                    NSLog(@"[MCDL] All downloads and verifications completed. Removing gate.");
                }
                [weakSelf safelyLeaveDispatchGroup:@"GateRemoval"];
                return;
            }
            
            // Log progress periodically
            if (weakSelf.verboseLogging && i % 10 == 0) {
                NSInteger pendingDownloads, activeDownloads, pendingVerifications;
                
                @synchronized(weakSelf.pendingDownloads) {
                    pendingDownloads = weakSelf.pendingDownloads.count;
                    activeDownloads = weakSelf.activeDownloads;
                }
                
                @synchronized(weakSelf.pendingVerificationList) {
                    pendingVerifications = weakSelf.pendingVerificationList.count;
                }
                
                NSLog(@"[MCDL] Download monitor: %ld pending, %ld active downloads, %ld pending verifications",
                      (long)pendingDownloads, (long)activeDownloads, (long)pendingVerifications);
            }
        }
        
        // Timeout after 2 minutes
        NSLog(@"[MCDL] Download monitor timeout after 120 seconds. Removing gate.");
        [weakSelf safelyLeaveDispatchGroup:@"GateRemovalTimeout"];
    });
}

- (void)processPostMetadataDownloads {
    @synchronized(self) {
        if (!self || self.progress.cancelled) return;
        
        NSDictionary *localMetadata = [self.metadata copy];
        
        // Enter group for libraries and client JAR
        dispatch_group_enter(self.downloadCompletionGroup);
        
        [self.completionLock lock];
        self.totalTasksEnqueued++;
        [self.completionLock unlock];
        
        // Enqueue downloads
        if (self.verboseLogging) NSLog(@"[MCDL] Enqueuing libraries...");
        [self downloadClientLibraries:localMetadata];
        
        if (self.verboseLogging) NSLog(@"[MCDL] Enqueuing client JAR...");
        [self downloadClientJar:localMetadata];
        
        // Leave group for libraries and client JAR
        [self safelyLeaveDispatchGroup:@"LibrariesAndClientJar"];
        
        // Handle Assets
        NSDictionary *assetIndexInfo = localMetadata[@"assetIndex"];
        if (assetIndexInfo) {
            // Enter group for asset index download
            dispatch_group_enter(self.downloadCompletionGroup);
            
            [self.completionLock lock];
            self.totalTasksEnqueued++;
            [self.completionLock unlock];
            
            if (self.verboseLogging) NSLog(@"[MCDL] Downloading Asset Metadata...");
            
            [self downloadAssetMetadataWithSuccess:^{
                @synchronized(self) {
                    if (!self || self.progress.cancelled) {
                        [self safelyLeaveDispatchGroup:@"AssetIndexCancelled"];
                        return;
                    }
                    
                    NSDictionary *assetIndexObj = self.metadata[@"assetIndexObj"];
                    if (assetIndexObj && assetIndexObj[@"objects"]) {
                        // Enter group for asset downloads
                        dispatch_group_enter(self.downloadCompletionGroup);
                        
                        [self.completionLock lock];
                        self.totalTasksEnqueued++;
                        [self.completionLock unlock];
                        
                        if (self.verboseLogging) NSLog(@"[MCDL] Enqueuing assets...");
                        [self downloadClientAssets:assetIndexObj];
                        
                        // Leave group for asset downloads
                        [self safelyLeaveDispatchGroup:@"AssetDownloads"];
                        
                        [self.metadata removeObjectForKey:@"assetIndexObj"];
                    } else {
                        NSLog(@"[MCDL] No assets found in index or index missing.");
                    }
                    
                    // Leave group for asset index processing
                    [self safelyLeaveDispatchGroup:@"AssetIndexSuccess"];
                }
            }];
        } else {
            NSLog(@"[MCDL] No asset index found. Skipping asset downloads.");
        }
        
        // Leave group for overall process
        [self safelyLeaveDispatchGroup:@"OverallProcessStart"];
    }
}

#pragma mark - Resource Download Methods

- (void)downloadVersionMetadata:(NSDictionary *)version success:(void (^)(void))success {
    // Download base json
    NSString *versionStr = version[@"id"];
    if ([versionStr isEqualToString:@"latest-release"]) {
        versionStr = getPrefObject(@"internal.latest_version.release");
    } else if ([versionStr isEqualToString:@"latest-snapshot"]) {
        versionStr = getPrefObject(@"internal.latest_version.snapshot");
    }
    
    NSString *path = [NSString stringWithFormat:@"%1$s/versions/%2$@/%2$@.json", getenv("POJAV_GAME_DIR"), versionStr];
    
    // Ensure version directory exists
    NSString *versionDir = [path stringByDeletingLastPathComponent];
    NSError *dirError = nil;
    [[NSFileManager defaultManager] createDirectoryAtPath:versionDir
                             withIntermediateDirectories:YES
                                              attributes:nil
                                                   error:&dirError];
    if (dirError && dirError.code != NSFileWriteFileExistsError) {
        NSLog(@"[MCDL] Error creating version directory %@: %@", versionDir, dirError.localizedDescription);
        [self finishDownloadWithErrorString:[NSString stringWithFormat:@"Failed to create version directory: %@", dirError.localizedDescription]];
        return;
    }
    
    // Find version in remote list
    NSDictionary* versionInfoToDownload = (id)[MinecraftResourceUtils findVersion:versionStr inList:remoteVersionList];
    
    // Create wrapped success callback
    __weak typeof(self) weakSelf = self;
    void(^wrappedSuccess)(void) = ^{
        // Check if cancelled
        BOOL isCancelled = NO;
        @synchronized(weakSelf) {
            if (!weakSelf) return;
            @try {
                isCancelled = weakSelf.progress.cancelled;
            } @catch (NSException *exception) {
                NSLog(@"[MCDL] Exception checking if cancelled: %@", exception);
                isCancelled = NO;
            }
        }
        if (isCancelled) return;
        
        // Parse the JSON file
        NSError *jsonError = nil;
        NSData *jsonData = [NSData dataWithContentsOfFile:path options:0 error:&jsonError];
        if (!jsonData || jsonError) {
            NSLog(@"[MCDL] Error reading version JSON: %@", jsonError.localizedDescription);
            [weakSelf finishDownloadWithErrorString:[NSString stringWithFormat:@"Error reading version JSON: %@", jsonError.localizedDescription]];
            return;
        }
        
        // Parse JSON with mutable containers
        id jsonObject = [NSJSONSerialization JSONObjectWithData:jsonData
                                                       options:NSJSONReadingMutableContainers
                                                         error:&jsonError];
        if (!jsonObject || jsonError) {
            NSLog(@"[MCDL] Error parsing version JSON: %@", jsonError.localizedDescription);
            [weakSelf finishDownloadWithErrorString:[NSString stringWithFormat:@"Error parsing version JSON: %@", jsonError.localizedDescription]];
            return;
        }
        
        // Store and process metadata
        @synchronized(weakSelf) {
            if (!weakSelf) return;
            
            // Store metadata
            weakSelf.metadata = [jsonObject mutableCopy];
            weakSelf.metadata[@"isModpackInstall"] = @NO;
            
            // Handle inheritsFrom for mod versions
            NSString *inheritsFromVersionId = weakSelf.metadata[@"inheritsFrom"];
            if (inheritsFromVersionId) {
                NSLog(@"[MCDL] Version inherits from: %@", inheritsFromVersionId);
                NSString *inheritsFromPath = [NSString stringWithFormat:@"%1$s/versions/%2$@/%2$@.json",
                                           getenv("POJAV_GAME_DIR"),
                                           inheritsFromVersionId];
                
                // Read parent version JSON
                NSMutableDictionary *inheritsFromDict = parseJSONFromFile(inheritsFromPath);
                if (inheritsFromDict && !inheritsFromDict[@"NSErrorObject"]) {
                    [MinecraftResourceUtils processVersion:weakSelf.metadata inheritsFrom:inheritsFromDict];
                    weakSelf.metadata = inheritsFromDict; // Replace with merged parent
                } else {
                    // Download parent version if missing
                    NSDictionary *parentVersionInfo = (id)[MinecraftResourceUtils findVersion:inheritsFromVersionId inList:remoteVersionList];
                    if (parentVersionInfo) {
                        NSLog(@"[MCDL] Parent JSON missing, downloading: %@", inheritsFromVersionId);
                        
                        // Download parent recursively
                        [weakSelf downloadVersionMetadata:parentVersionInfo success:^{
                            // Re-attempt merging after parent download
                            NSMutableDictionary *childJson = parseJSONFromFile(path);
                            NSMutableDictionary *parentJson = parseJSONFromFile(inheritsFromPath);
                            
                            if (childJson && !childJson[@"NSErrorObject"] && 
                                parentJson && !parentJson[@"NSErrorObject"]) {
                                [MinecraftResourceUtils processVersion:childJson inheritsFrom:parentJson];
                                
                                @synchronized(weakSelf) {
                                    if (!weakSelf) return;
                                    weakSelf.metadata = parentJson; // Use merged parent
                                    [MinecraftResourceUtils tweakVersionJson:weakSelf.metadata];
                                }
                                
                                // Call original success callback
                                if (success) success();
                            } else {
                                [weakSelf finishDownloadWithErrorString:@"Failed to load or merge inherited version JSON after download."];
                            }
                        }];
                        return; // Exit as recursive call will handle success
                    } else {
                        [weakSelf finishDownloadWithErrorString:[NSString stringWithFormat:@"Could not find inherited version %@ in remote list.", inheritsFromVersionId]];
                        return;
                    }
                }
            }
            
            // Apply tweaks to version JSON
            [MinecraftResourceUtils tweakVersionJson:weakSelf.metadata];
        }
        
        // Call original success callback
        if (success) {
            success();
        }
    };
    
    if (!versionInfoToDownload) {
        // Check for local version
        if ([[NSFileManager defaultManager] fileExistsAtPath:path]) {
            if (self.verboseLogging) {
                NSLog(@"[MCDL] Using existing local/custom version JSON: %@", path.lastPathComponent);
            }
            wrappedSuccess(); // Process existing file
        } else {
            // Error if not found
            [self finishDownloadWithErrorString:[NSString stringWithFormat:@"Version JSON not found locally or remotely: %@", versionStr]];
        }
        return;
    }
    
    // Get version details for download
    versionStr = versionInfoToDownload[@"id"];
    NSString *url = versionInfoToDownload[@"url"];
    NSString *sha = versionInfoToDownload[@"sha1"];
    NSUInteger size = [versionInfoToDownload[@"size"] unsignedLongLongValue];
    
    if (self.verboseLogging) {
        NSLog(@"[MCDL] Downloading version JSON from %@", url);
    }
    
    // Create download task
    NSURLSessionDownloadTask *task = [self createDownloadTask:url 
                                                        size:size 
                                                         sha:sha 
                                                     altName:[path lastPathComponent] 
                                                      toPath:path 
                                                     success:wrappedSuccess 
                                                     failure:^(NSError *error) {
        // Try existing file if download fails
        if ([[NSFileManager defaultManager] fileExistsAtPath:path]) {
            NSLog(@"[MCDL] Warning: Version JSON download failed, using existing file: %@", path.lastPathComponent);
            wrappedSuccess(); // Try to proceed with existing file
        } else {
            [self finishDownloadWithError:error file:[path lastPathComponent]];
        }
    }];
    
    // Handle case where no task was created
    if (!task && !self.progress.cancelled) {
        if ([[NSFileManager defaultManager] fileExistsAtPath:path]) {
            wrappedSuccess();
        } else {
            [self finishDownloadWithErrorString:[NSString stringWithFormat:@"File %@ missing and download task not created.", path.lastPathComponent]];
        }
    } else if (!task && self.progress.cancelled) {
        if (self.verboseLogging) {
            NSLog(@"[MCDL] Version JSON download cancelled before task creation.");
        }
    }
}

- (void)downloadAssetMetadataWithSuccess:(void (^)(void))success {
    // Get asset index from metadata
    NSDictionary *assetIndex = nil;
    @synchronized(self) {
        if (!self) return;
        assetIndex = [self.metadata[@"assetIndex"] copy];
    }
    
    if (!assetIndex) {
        if (success) success(); // Call success if no asset index
        return;
    }
    
    // Prepare path and download info
    NSString *assetIndexId = assetIndex[@"id"];
    NSString *name = [NSString stringWithFormat:@"assets/indexes/%@.json", assetIndexId];
    NSString *path = [@(getenv("POJAV_GAME_DIR")) stringByAppendingPathComponent:name];
    NSString *url = assetIndex[@"url"];
    NSString *sha = assetIndex[@"sha1"];
    NSUInteger size = [assetIndex[@"size"] unsignedLongLongValue];
    
    // Create wrapped success callback
    __weak typeof(self) weakSelf = self;
    void(^wrappedSuccess)(void) = ^{
        // Check if cancelled
        BOOL isCancelled = NO;
        @synchronized(weakSelf) {
            if (!weakSelf) return;
            @try { 
                isCancelled = weakSelf.progress.cancelled; 
            } @catch (NSException *e) {}
        }
        if (isCancelled) return;
        
        // Parse the JSON file
        NSError *jsonError = nil;
        NSData *jsonData = [NSData dataWithContentsOfFile:path options:NSDataReadingMappedIfSafe error:&jsonError];
        if (!jsonData || jsonError) {
            NSLog(@"[MCDL] Error reading asset index JSON %@: %@", name, jsonError.localizedDescription);
            [weakSelf finishDownloadWithErrorString:[NSString stringWithFormat:@"Error reading asset index JSON: %@", jsonError.localizedDescription]];
            return;
        }
        
        // Parse JSON
        id jsonObject = [NSJSONSerialization JSONObjectWithData:jsonData
                                                       options:NSJSONReadingMutableContainers
                                                         error:&jsonError];
        if (!jsonObject || jsonError) {
            NSLog(@"[MCDL] Error parsing asset index JSON %@: %@", name, jsonError.localizedDescription);
            [weakSelf finishDownloadWithErrorString:[NSString stringWithFormat:@"Error parsing asset index JSON: %@", jsonError.localizedDescription]];
            return;
        }
        
        // Store asset index
        @synchronized(weakSelf) {
            if (!weakSelf) return;
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
    [[NSFileManager defaultManager] createDirectoryAtPath:dirPath
                                withIntermediateDirectories:YES
                                                 attributes:nil
                                                      error:&dirError];
    if (dirError && dirError.code != NSFileWriteFileExistsError) {
        NSLog(@"[MCDL] Error creating asset index directory: %@", dirError.localizedDescription);
        [self finishDownloadWithErrorString:[NSString stringWithFormat:@"Failed to create asset index directory: %@", dirError.localizedDescription]];
        return;
    }
    
    // Create download task
    NSURLSessionDownloadTask *task = [self createDownloadTask:url 
                                                        size:size 
                                                         sha:sha 
                                                     altName:name 
                                                      toPath:path 
                                                     success:wrappedSuccess 
                                                     failure:^(NSError *error) {
        // Try existing file if download fails
        if ([[NSFileManager defaultManager] fileExistsAtPath:path]) {
            NSLog(@"[MCDL] Warning: Asset index download failed, using existing file: %@", path.lastPathComponent);
            wrappedSuccess();
        } else {
            [self finishDownloadWithError:error file:name];
        }
    }];
    
    // Handle case where no task was created
    if (!task && !self.progress.cancelled) {
        if ([[NSFileManager defaultManager] fileExistsAtPath:path]) {
            wrappedSuccess();
        } else {
            [self finishDownloadWithErrorString:[NSString stringWithFormat:@"File %@ missing and download task not created.", path.lastPathComponent]];
        }
    } else if (!task && self.progress.cancelled) {
        if (self.verboseLogging) {
            NSLog(@"[MCDL] Asset index download cancelled before task creation.");
        }
    }
}

- (NSArray *)downloadClientLibraries:(NSDictionary *)versionMetadata {
    NSMutableArray *tasks = [NSMutableArray new];
    
    // Skip if no libraries defined
    if (!versionMetadata[@"libraries"] || ![versionMetadata[@"libraries"] isKindOfClass:[NSArray class]]) {
        return tasks;
    }
    
    NSArray *libraries = versionMetadata[@"libraries"];
    NSInteger libraryCount = libraries.count;
    
    if (self.verboseLogging) {
        NSLog(@"[MCDL] Processing %ld libraries for download", (long)libraryCount);
    }
    
    // Process each library
    for (NSDictionary *library in libraries) {
        // Check if cancelled
        BOOL isCancelled = NO;
        @synchronized(self) {
            @try { 
                isCancelled = self.progress.cancelled; 
            } @catch(NSException* e){}
        }
        if (isCancelled) break;
        
        NSString *name = library[@"name"];
        if (!name) continue;
        
        // Skip Forge/NeoForge client JARs
        if (([name containsString:@"net.minecraftforge:forge:"] ||
             [name containsString:@"net.neoforged:neoforge:"] ||
             [name containsString:@"net.neoforged.forge:forge:"]) && 
            ([name hasSuffix:@":client"] || [name hasSuffix:@":universal"] || [name containsString:@"-installer"])) {
            if (self.verboseLogging) {
                NSLog(@"[MCDL] Skipping Forge/NeoForge JAR %@ - installed separately", name);
            }
            continue;
        }
        
        // Get or generate artifact information
        NSMutableDictionary *artifactDict = [library[@"downloads"][@"artifact"] mutableCopy];
        if (artifactDict == nil && [name containsString:@":"]) {
            if (self.verboseLogging) {
                NSLog(@"[MCDL] Generating artifact object for %@", name);
            }
            artifactDict = [[NSMutableDictionary alloc] init];
            
            // Build library URL
            NSString *prefix = library[@"url"] ?: @"https://libraries.minecraft.net/";
            prefix = [prefix stringByReplacingOccurrencesOfString:@"http://" withString:@"https://"];
            if (![prefix hasSuffix:@"/"]) {
                prefix = [prefix stringByAppendingString:@"/"];
            }
            
            NSArray *libParts = [name componentsSeparatedByString:@":"];
            
            if (libParts.count >= 3) {
                NSString *group = [libParts[0] stringByReplacingOccurrencesOfString:@"." withString:@"/"];
                NSString *artifactName = libParts[1];
                NSString *version = libParts[2];
                
                // Handle classifier and extension
                NSString *classifier = @"";
                NSString *extension = @"jar";
                
                if (libParts.count > 3) {
                    NSRange extRange = [libParts[3] rangeOfString:@"@"];
                    if (extRange.location != NSNotFound) {
                        classifier = [libParts[3] substringToIndex:extRange.location];
                        extension = [libParts[3] substringFromIndex:extRange.location + 1];
                    } else {
                        classifier = libParts[3];
                    }
                    
                    if (classifier.length > 0) {
                        classifier = [NSString stringWithFormat:@"-%@", classifier];
                    }
                }
                
                // Build path and URL
                artifactDict[@"path"] = [NSString stringWithFormat:@"%@/%@/%@/%@-%@%@.%@",
                                     group, artifactName, version, artifactName, version, classifier, extension];
                artifactDict[@"url"] = [NSString stringWithFormat:@"%@%@", prefix, artifactDict[@"path"]];
                
                // Get SHA1 if available
                id checksums = library[@"checksums"];
                if (checksums && [checksums isKindOfClass:[NSArray class]]) {
                    NSArray *checksumsArray = (NSArray *)checksums;
                    if (checksumsArray.count > 0 && [checksumsArray[0] isKindOfClass:[NSString class]]) {
                        artifactDict[@"sha1"] = checksumsArray[0];
                    }
                } else if (library[@"sha1"] && [library[@"sha1"] isKindOfClass:[NSString class]]) {
                    artifactDict[@"sha1"] = library[@"sha1"];
                }
            } else {
                NSLog(@"[MCDL] Warning: Malformed library name: %@", name);
                continue;
            }
        }
        
        // Skip if marked to skip
        if ([library[@"skip"] boolValue]) {
            if (self.verboseLogging) {
                NSLog(@"[MCDL] Skipped library %@", name);
            }
            continue;
        }
        
        // Check rules
        NSArray* rules = library[@"rules"];
        if (rules) {
            BOOL allow = YES;
            for (NSDictionary* rule in rules) {
                NSString* action = rule[@"action"];
                NSDictionary* os = rule[@"os"];
                if (os) {
                    NSString* osName = os[@"name"];
                    if ([action isEqualToString:@"disallow"] && ![osName isEqualToString:@"osx"] && ![osName isEqualToString:@"ios"]) {
                        allow = NO; break;
                    } else if ([action isEqualToString:@"allow"] && ![osName isEqualToString:@"osx"] && ![osName isEqualToString:@"ios"]) {
                        allow = NO; break;
                    } else if ([action isEqualToString:@"allow"] && ([osName isEqualToString:@"osx"] || [osName isEqualToString:@"ios"])) {
                        allow = YES; break;
                    }
                } else {
                    allow = [action isEqualToString:@"allow"];
                }
            }
            
            if (!allow) {
                if (self.verboseLogging) {
                    NSLog(@"[MCDL] Skipped library due to rules: %@", name);
                }
                continue;
            }
        }
        
        // Prepare download parameters
        NSString *path = [NSString stringWithFormat:@"%s/libraries/%@", getenv("POJAV_GAME_DIR"), artifactDict[@"path"]];
        NSString *sha = artifactDict[@"sha1"];
        NSUInteger size = [artifactDict[@"size"] unsignedLongLongValue];
        NSString *url = artifactDict[@"url"];
        
        // Skip if URL is missing
        if (!url || [url length] == 0) {
            NSLog(@"[MCDL] Warning: Skipping library %@ due to missing URL", name);
            continue;
        }
        
        // Create download task
        NSURLSessionDownloadTask *task = [self createDownloadTask:url size:size sha:sha altName:name toPath:path success:nil failure:nil];
        if (task) {
            [tasks addObject:task];
        }
    }
    
    if (self.verboseLogging) {
        NSLog(@"[MCDL] Enqueued %ld library downloads", (long)tasks.count);
    }
    
    return tasks;
}

- (void)downloadClientJar:(NSDictionary *)versionMetadata {
    // Get client download information
    NSDictionary *downloads = versionMetadata[@"downloads"];
    NSDictionary *clientInfo = downloads[@"client"];
    
    if (!clientInfo) {
        NSLog(@"[MCDL] No client JAR information found in version metadata.");
        return;
    }
    
    NSString *url = clientInfo[@"url"];
    NSString *sha1 = clientInfo[@"sha1"];
    NSUInteger size = [clientInfo[@"size"] unsignedIntegerValue];
    NSString *versionId = versionMetadata[@"id"];
    
    if (!versionId || !url || !sha1) {
        NSLog(@"[MCDL] Client JAR information incomplete. Cannot download.");
        return;
    }
    
    NSString *path = [NSString stringWithFormat:@"%s/versions/%@/%@.jar", getenv("POJAV_GAME_DIR"), versionId, versionId];
    NSString *altName = [NSString stringWithFormat:@"%@.jar", versionId];
    
    if (self.verboseLogging) {
        NSLog(@"[MCDL] Enqueuing client JAR: %@", altName);
    }
    
    // Create download task
    [self createDownloadTask:url size:size sha:sha1 altName:altName toPath:path success:nil failure:nil];
}

- (NSArray *)downloadClientAssets:(NSDictionary *)assetIndexObj {
    // Check if we've already processed assets
    @synchronized(self) {
        if (self.hasProcessedAssets) {
            if (self.verboseLogging) {
                NSLog(@"[MCDL] Assets already processed for this session, skipping");
            }
            return @[];
        }
        
        // Mark that we've processed assets
        self.hasProcessedAssets = YES;
    }
    
    NSMutableArray *tasks = [NSMutableArray new];
    
    // Validate asset index
    if (!assetIndexObj || !assetIndexObj[@"objects"] || ![assetIndexObj[@"objects"] isKindOfClass:[NSDictionary class]]) {
        return tasks;
    }
    
    NSDictionary *objectsDict = assetIndexObj[@"objects"];
    NSArray *assetNames = objectsDict.allKeys;
    NSInteger totalAssets = assetNames.count;
    
    if (self.verboseLogging) {
        NSLog(@"[MCDL] Processing %ld assets for download", (long)totalAssets);
    }
    
    // Set up asset directories
    NSString *assetsDir = [NSString stringWithFormat:@"%s/assets/objects", getenv("POJAV_GAME_DIR")];
    NSString *resourcesDir = [NSString stringWithFormat:@"%s/resources", getenv("POJAV_GAME_DIR")];
    
    // Create directories
    NSError *dirError = nil;
    [[NSFileManager defaultManager] createDirectoryAtPath:assetsDir
                             withIntermediateDirectories:YES
                                              attributes:nil
                                                   error:&dirError];
    if (dirError) NSLog(@"[MCDL] Warning: Error creating assets directory: %@", dirError.localizedDescription);
    
    dirError = nil;
    [[NSFileManager defaultManager] createDirectoryAtPath:resourcesDir
                             withIntermediateDirectories:YES
                                              attributes:nil
                                                   error:&dirError];
    if (dirError) NSLog(@"[MCDL] Warning: Error creating resources directory: %@", dirError.localizedDescription);
    
    // Process assets
    for (NSString *name in assetNames) {
        // Check if cancelled
        BOOL isCancelled = NO;
        @synchronized(self) {
            @try { 
                isCancelled = self.progress.cancelled; 
            } @catch(NSException *e){}
        }
        if (isCancelled) break;
        
        NSDictionary *object = assetIndexObj[@"objects"][name];
        NSString *hash = object[@"hash"];
        
        if (!hash || hash.length < 2) {
            NSLog(@"[MCDL] Warning: Skipping asset %@ due to missing or short hash", name);
            continue;
        }
        
        NSString *pathname = [NSString stringWithFormat:@"%@/%@", [hash substringToIndex:2], hash];
        NSUInteger size = [object[@"size"] unsignedLongLongValue];
        
        // Determine path based on mapping
        NSString *path;
        if ([assetIndexObj[@"map_to_resources"] boolValue]) {
            path = [NSString stringWithFormat:@"%s/resources/%@", getenv("POJAV_GAME_DIR"), name];
        } else {
            path = [NSString stringWithFormat:@"%s/assets/objects/%@", getenv("POJAV_GAME_DIR"), pathname];
        }
        
        // Skip icon for 1.19+ to avoid ObjC issue
        if ([name hasSuffix:@"/minecraft.icns"]) {
            [NSFileManager.defaultManager removeItemAtPath:path error:nil];
            continue;
        }
        
        // Create download task
        NSString *url = [NSString stringWithFormat:@"https://resources.download.minecraft.net/%@", pathname];
        NSURLSessionDownloadTask *task = [self createDownloadTask:url size:size sha:hash altName:name toPath:path success:nil failure:nil];
        
        if (task) {
            [tasks addObject:task];
        }
    }
    
    if (self.verboseLogging) {
        NSLog(@"[MCDL] Enqueued %ld asset downloads", (long)tasks.count);
    }
    
    return tasks;
}

- (void)downloadModpackFromAPI:(ModpackAPI *)api detail:(NSDictionary *)modDetail atIndex:(NSUInteger)selectedVersion {
    // Initialize download state
    [self prepareForDownload];
    
    // Reset metadata and mark as modpack
    @synchronized(self) {
        if (!self.metadata) {
            self.metadata = [NSMutableDictionary dictionary];
        } else {
            [self.metadata removeAllObjects];
        }
        self.metadata[@"isModpackInstall"] = @YES;
        self.isDownloadPhaseComplete = NO;
    }
    
    // Get modpack info
    NSString *url = modDetail[@"versionUrls"][selectedVersion];
    NSUInteger size = [modDetail[@"versionSizes"][selectedVersion] unsignedLongLongValue];
    NSString *sha = modDetail[@"versionHashes"][selectedVersion];
    
    // Use original modpack name
    NSString *name = [modDetail[@"title"] stringByTrimmingCharactersInSet:NSCharacterSet.whitespaceCharacterSet];
    
    // Create sanitized name for file path
    NSString *sanitizedName = [[name lowercaseString] stringByReplacingOccurrencesOfString:@" " withString:@"_"];
    sanitizedName = [sanitizedName stringByReplacingOccurrencesOfString:@"[^a-z0-9_]+" 
                                                           withString:@"" 
                                                              options:NSRegularExpressionSearch 
                                                                range:NSMakeRange(0, sanitizedName.length)];
    
    NSString *packagePath = [NSTemporaryDirectory() stringByAppendingFormat:@"/%@.zip", sanitizedName];
    
    NSLog(@"[MCDL] Starting download for modpack: %@", name);
    
    // Get game directory for modpack
    NSString *gameDir = [PLProfiles uniqueGameDirForProfileName:name];
    NSString *destPath = [PLProfiles fullPathForProfileWithName:name gameDir:gameDir];
    
    // Store game directory for profile creation
    @synchronized(self) {
        self.metadata[@"gameDir"] = gameDir;
    }
    
    // Create display name for progress
    NSString *displayName = [NSString stringWithFormat:@"Downloading modpack: %@", name];
    
    // Success callback for modpack download
    __weak typeof(self) weakSelf = self;
    void(^modpackSuccess)(void) = ^{
        @synchronized(weakSelf) {
            if (!weakSelf) return;
            
            // Reset progress for extraction phase
            weakSelf.progress.totalUnitCount = 1;
            weakSelf.progress.completedUnitCount = 0;
            weakSelf.textProgress.totalUnitCount = 1;
            weakSelf.textProgress.completedUnitCount = 0;
            
            // Reset counters for mod downloads
            weakSelf.totalDownloads = 0;
            weakSelf.successfulDownloads = 0;
            weakSelf.totalTasksEnqueued = 0;
            weakSelf.tasksLeftGroup = 0;
            weakSelf.isDownloadPhaseComplete = NO;
        }
        
        // Add extraction marker to UI
        @synchronized(weakSelf.fileList) {
            if (!weakSelf) return;
            [weakSelf.fileList removeAllObjects];
            [weakSelf.fileList addObject:[NSString stringWithFormat:@"Preparing modpack %@", name]];
        }
        weakSelf.needsUIUpdate = YES;
        
        NSLog(@"[MCDL] Modpack download complete, proceeding to installation.");
        
        // Use API to handle extraction and installation
        [api downloader:weakSelf submitDownloadTasksFromPackage:packagePath toPath:destPath];
    };
    
    // Failure callback with retry
    void(^modpackFailure)(NSError *error) = ^(NSError *error) {
        if (!weakSelf) return;
        
        NSLog(@"[MCDL] Failed to download modpack: %@. Retrying...", error.localizedDescription);
        
        // Add retry notification to UI
        @synchronized(weakSelf.fileList) {
            if (!weakSelf) return;
            [weakSelf.fileList addObject:[NSString stringWithFormat:@"Retrying download for %@", name]];
        }
        weakSelf.needsUIUpdate = YES;
        
        // Create retry task
        [weakSelf createDownloadTask:url
                                size:size
                                 sha:sha
                             altName:[NSString stringWithFormat:@"Downloading %@ (retry)", name]
                              toPath:packagePath
                             success:modpackSuccess
                             failure:^(NSError *retryError) {
            // Show error if retry fails
            [weakSelf finishDownloadWithErrorString:[NSString stringWithFormat:@"Failed to download modpack after retry: %@", retryError.localizedDescription]];
        }];
    };
    
    // Create download task for modpack zip
    [self createDownloadTask:url
                        size:size
                         sha:sha
                     altName:displayName
                      toPath:packagePath
                     success:modpackSuccess
                     failure:modpackFailure];
    
    // Process the download queue
    dispatch_async(self.downloadQueue, ^{
        [self processNextDownloadInQueue];
    });
}

@end

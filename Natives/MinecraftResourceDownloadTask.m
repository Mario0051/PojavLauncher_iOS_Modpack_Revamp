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

typedef struct {
    NSString *path;
    NSString *sha;
    NSString *altName;
    NSString *url;
    NSUInteger size;
} VerificationItem;

// Class extension to declare private properties
@interface MinecraftResourceDownloadTask ()
@property(nonatomic, readwrite) AFURLSessionManager* manager;
@property(nonatomic, strong) NSLock *progressLock; // Lock for synchronizing progress updates
@property(nonatomic, strong) NSLock *fileListLock; // Lock for synchronizing file list updates
@property(nonatomic, strong) dispatch_queue_t downloadQueue; // Serial queue for managing downloads
@property(nonatomic, strong) NSMutableArray *pendingDownloads; // Queue of pending downloads
@property(nonatomic, assign) NSInteger activeDownloads; // Track active downloads
@property(nonatomic, strong) NSTimer *uiUpdateTimer; // Timer for batched UI updates
@property(nonatomic, assign) BOOL needsUIUpdate; // Flag for pending UI updates
@property (nonatomic, strong) dispatch_group_t downloadCompletionGroup; // Group to track all download tasks
@property (nonatomic, readwrite) BOOL isDownloadPhaseComplete; // Flag to indicate true completion
@property (nonatomic, assign) NSInteger totalTasksEnqueued; // Counter for all tasks added to the group
@property (nonatomic, assign) NSInteger tasksLeftGroup; // Counter for tasks leaving the group
@property (nonatomic, strong) NSLock *completionLock; // Lock for completion status checks
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
        self.pendingVerificationList = [NSMutableArray new];
        self.activeDownloads = 0;

        // Initialize lock objects for thread safety
        self.progressLock = [[NSLock alloc] init];
        self.fileListLock = [[NSLock alloc] init];
        self.completionLock = [[NSLock alloc] init]; // Initialize completion lock

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
        self.textProgress.totalUnitCount = 0; // Start with 0 instead of 1
        self.textProgress.cancellable = YES;

        // Initialize counters for logging
        self.successfulDownloads = 0;
        self.totalDownloads = 0;
        self.verboseLogging = getPrefBool(@"general.debug_logging");

        // Initialize verification flag
        self.deferSHAVerification = !getPrefBool(@"general.check_sha");

        // Flag to prevent duplicate asset processing
        self.hasProcessedAssets = NO;

        // Setup timer for batched UI updates with lower frequency
        self.needsUIUpdate = NO;
        self.uiUpdateTimer = [NSTimer scheduledTimerWithTimeInterval:0.5
                                                             target:self
                                                           selector:@selector(processBatchedUIUpdates)
                                                           userInfo:nil
                                                            repeats:YES];
        // Ensure timer runs even during scrolling
        [[NSRunLoop mainRunLoop] addTimer:self.uiUpdateTimer forMode:NSRunLoopCommonModes];


        // Initialize download completion group
        self.downloadCompletionGroup = dispatch_group_create();
        self.isDownloadPhaseComplete = NO; // Initialize completion flag
        self.totalTasksEnqueued = 0; // Initialize enqueue counter
        self.tasksLeftGroup = 0; // Initialize leave counter
    }
    return self;
}

- (void)dealloc {
    [self.uiUpdateTimer invalidate];
    self.uiUpdateTimer = nil;
    // No need to release dispatch_group_t in ARC
}

// Helper to safely leave the dispatch group and check completion
- (void)safelyLeaveDispatchGroup:(NSString *)reason {
    [self.completionLock lock];
    self.tasksLeftGroup++;
    if (self.verboseLogging) {
        NSLog(@"[MCDL_DEBUG] Task left group (%@). Total Left: %ld, Total Enqueued: %ld", reason, (long)self.tasksLeftGroup, (long)self.totalTasksEnqueued);
    }
    BOOL shouldCheckCompletion = (self.tasksLeftGroup >= self.totalTasksEnqueued && self.totalTasksEnqueued > 0);
    [self.completionLock unlock];

    dispatch_group_leave(self.downloadCompletionGroup);

    if (shouldCheckCompletion) {
        [self checkFinalCompletion];
    }
}

// Final completion check, called only when all enqueued tasks have left the group
- (void)checkFinalCompletion {
     NSLog(@"[MCDL] All enqueued tasks have left the group. Proceeding to final checks.");
    __weak typeof(self) weakSelf = self;
    dispatch_async(dispatch_get_global_queue(DISPATCH_QUEUE_PRIORITY_DEFAULT, 0), ^{
        if (!weakSelf) return; // Check if self is still valid

        BOOL verificationSuccess = YES;
        if (weakSelf.deferSHAVerification) {
            NSLog(@"[MCDL] Verifying deferred files...");
            verificationSuccess = [weakSelf verifyPendingFiles];
             // If verification fails, verifyPendingFiles queues redownloads which re-enter the group,
             // so the final completion will be triggered again later.
             if (!verificationSuccess) {
                 NSLog(@"[MCDL] Deferred verification failed, redownload initiated. Completion delayed.");
                 return; // Don't mark as complete yet
             }
        }

        if (verificationSuccess) {
             BOOL alreadyComplete = NO;
             @synchronized(weakSelf) {
                 if (!weakSelf) return;
                 alreadyComplete = weakSelf.isDownloadPhaseComplete;
                 if (!alreadyComplete) {
                     NSLog(@"[MCDL] All tasks truly complete and verified.");
                     // Ensure progress reflects completion if not already set
                     if (weakSelf.progress.totalUnitCount <= 0) { // Use <= 0 for safety
                          weakSelf.progress.totalUnitCount = 1;
                          weakSelf.textProgress.totalUnitCount = 1;
                     }
                     weakSelf.progress.completedUnitCount = weakSelf.progress.totalUnitCount;
                     weakSelf.textProgress.completedUnitCount = weakSelf.textProgress.totalUnitCount;
                     weakSelf.isDownloadPhaseComplete = YES; // Set the final completion flag

                     // Add completion marker for UI
                     @synchronized(weakSelf.fileList) {
                         if (!weakSelf) return; // Re-check self
                          if (![weakSelf.fileList containsObject:@"Complete"]) {
                               [weakSelf.fileList addObject:@"Complete"];
                          }
                     }
                     // Trigger UI update
                     weakSelf.needsUIUpdate = YES;
                     [weakSelf processBatchedUIUpdates]; // Process immediately for completion
                 }
             }
             if (alreadyComplete && weakSelf.verboseLogging) {
                 NSLog(@"[MCDL] Download phase was already marked complete.");
             }
        }
    });
}

- (void)downloadClientJar:(NSDictionary *)versionMetadata {
    NSDictionary *downloads = versionMetadata[@"downloads"];
    NSDictionary *clientInfo = downloads[@"client"];
    if (!clientInfo) {
        NSLog(@"[MCDL] No client JAR information found in version metadata.");
        return;
    }

    NSString *url = clientInfo[@"url"];
    NSString *sha1 = clientInfo[@"sha1"];
    NSUInteger size = [clientInfo[@"size"] unsignedIntegerValue];
    NSString *versionId = versionMetadata[@"id"]; // Get version ID for path

    if (!versionId || !url || !sha1) {
        NSLog(@"[MCDL] Client JAR information incomplete. Cannot download.");
        return;
    }

    NSString *path = [NSString stringWithFormat:@"%s/versions/%@/%@.jar", getenv("POJAV_GAME_DIR"), versionId, versionId];
    NSString *altName = [NSString stringWithFormat:@"%@.jar", versionId];

    if (self.verboseLogging) {
        NSLog(@"[MCDL] Enqueuing client JAR: %@", altName);
    }

    // Create and enqueue the task (will be handled by the queue)
    [self createDownloadTask:url size:size sha:sha1 altName:altName toPath:path success:nil failure:nil];
}

- (void)processBatchedUIUpdates {
    if (!self.needsUIUpdate) return;

    // Send a notification for UI components to update
    dispatch_async(dispatch_get_main_queue(), ^{
        [NSNotificationCenter.defaultCenter postNotificationName:@"DownloadProgressUpdated" object:self];
        self.needsUIUpdate = NO;

        // Update text progress safely
        [self.progressLock lock];
        if (self.textProgress && self.progress && self.progress.totalUnitCount > 0) {
             // Use the main progress's completed count for text progress
             self.textProgress.completedUnitCount = self.progress.completedUnitCount;
             self.textProgress.totalUnitCount = self.progress.totalUnitCount; // Ensure totals match
        }
        [self.progressLock unlock];
    });
}


- (void)prepareForDownload {
    @synchronized(self) {
        // Create a new progress tracking object starting with 0 units
        self.progress = [NSProgress new];
        self.progress.totalUnitCount = 0; // Start with 0 instead of 1
        self.progress.cancellable = YES;

        // Create a text progress for UI display
        self.textProgress = [NSProgress new];
        self.textProgress.kind = NSProgressKindFile;
        self.textProgress.fileOperationKind = NSProgressFileOperationKindDownloading;
        self.textProgress.totalUnitCount = 0; // Start with 0 instead of 1
        self.textProgress.cancellable = YES;

        // Reset counters
        self.successfulDownloads = 0;
        self.totalDownloads = 0;
        self.totalTasksEnqueued = 0; // Reset enqueue counter
        self.tasksLeftGroup = 0; // Reset leave counter

        // Reset the asset processing flag
        self.hasProcessedAssets = NO;

        // Reset completion flag
        self.isDownloadPhaseComplete = NO;
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

    // Reset verification list
    @synchronized(self.pendingVerificationList) {
        [self.pendingVerificationList removeAllObjects];
    }

    // Flag that UI update is needed
    self.needsUIUpdate = YES;

    // Check if we should defer SHA verification
    self.deferSHAVerification = !getPrefBool(@"general.check_sha");
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
            // Access progress safely within a synchronized block if necessary,
            // but reading `cancelled` is usually atomic.
            isCancelled = self.progress.cancelled;
        } @catch (NSException *exception) {
            NSLog(@"[MCDL] Warning: Exception checking if progress is cancelled: %@", exception);
            isCancelled = NO;
        }

        if (isCancelled) {
            // Clear all pending downloads if cancelled
            NSInteger countToLeave = self.pendingDownloads.count;
            [self.pendingDownloads removeAllObjects];
            self.activeDownloads = 0;
            // Leave the group for any tasks that were entered but not started
            for (NSInteger i = 0; i < countToLeave; i++) {
                [self safelyLeaveDispatchGroup:@"CancelledPendingQueue"];
            }
            return;
        }

        // Get next download task and start it
        NSURLSessionDownloadTask *nextTask = self.pendingDownloads[0];
        [self.pendingDownloads removeObjectAtIndex:0];
        self.activeDownloads++;

        // Resume task on a background queue to avoid blocking
        dispatch_async(dispatch_get_global_queue(DISPATCH_QUEUE_PRIORITY_DEFAULT, 0), ^{
            // Check again for cancellation right before resuming
            BOOL isCancelledBeforeResume = NO;
            @try {
                isCancelledBeforeResume = self.progress.cancelled;
            } @catch (NSException *exception) {}

            if (!isCancelledBeforeResume) {
                // CRITICAL FIX: Actually start the download task
                NSLog(@"[MCDL] Starting download task");
                [nextTask resume];
            } else {
                // If cancelled before resume, ensure we leave the group
                @synchronized(self) {
                    self.activeDownloads--; // Decrement active count
                }
                // Use the helper to leave the group
                [self safelyLeaveDispatchGroup:@"CancelledBeforeResume"];

                // Process next if possible
                dispatch_async(self.downloadQueue, ^{
                    [self processNextDownloadInQueue];
                });
            }
        });

        // If we're still below the concurrent limit and have more tasks, process another one
        if (self.activeDownloads < kMaxConcurrentDownloads && self.pendingDownloads.count > 0) {
            dispatch_async(self.downloadQueue, ^{
                [self processNextDownloadInQueue];
            });
        }
    }
}


// This should match the declaration in the header file
- (NSURLSessionDownloadTask *)createDownloadTask:(NSString *)url
                                           size:(NSUInteger)size
                                            sha:(NSString *)sha
                                        altName:(NSString *)altName
                                         toPath:(NSString *)path
                                        success:(void (^)(void))success
                                        failure:(void (^)(NSError *error))failure {
    @autoreleasepool {
        // Enhanced logging to track who's enqueueing tasks
        if (self.verboseLogging) {
            NSLog(@"[MCDL] TASK ENQUEUED for: %@", altName ?: path.lastPathComponent);
        }

        // Safety check for invalid URL with enhanced logging
        if (!url || url.length == 0) {
            NSLog(@"[MCDL] Error: Invalid or empty download URL");
            NSLog(@"[MCDL] File: %@, Path: %@", altName ?: @"(null)", path ?: @"(null)");

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

        // Enter the group *before* checking cache or existence
        dispatch_group_enter(self.downloadCompletionGroup);
        // Increment the total enqueued count
        [self.completionLock lock];
        self.totalTasksEnqueued++;
        if (self.verboseLogging && self.totalTasksEnqueued % 100 == 0) {
            NSLog(@"[MCDL_DEBUG] Total Tasks Enqueued: %ld", (long)self.totalTasksEnqueued);
        }
        [self.completionLock unlock];

        // Track total downloads early
        self.totalDownloads++;

        // Check if file already exists and has valid SHA
        BOOL fileExists = [NSFileManager.defaultManager fileExistsAtPath:path];

        // Special handling for version files
        BOOL isVersionFile = (altName && [altName hasSuffix:@".json"]) ||
                             (path && [path hasSuffix:@".json"] && [path containsString:@"/versions/"]);

        // Check for latest version files that should be forced to re-download
        BOOL isLatestVersionFile = (altName &&
                                  ([altName containsString:@"latest-release"] ||
                                   [altName containsString:@"latest-snapshot"]));

        // Determine if we should verify SHA now or defer it
        BOOL shouldVerifyNow = !self.deferSHAVerification || isVersionFile || isLatestVersionFile;

        if (shouldVerifyNow && fileExists && sha && sha.length > 0 &&
            [self checkSHA:sha forFile:path altName:altName]) {

            // Use estimated size if actual size is 0
            NSUInteger itemSize = size > 0 ? size : 100000; // Use 100KB estimate if size unknown
            @synchronized(self) {
                // Add to total and mark as complete
                self.progress.totalUnitCount += itemSize;
                self.progress.completedUnitCount += itemSize;
                self.textProgress.totalUnitCount = self.progress.totalUnitCount;
                self.textProgress.completedUnitCount = self.progress.completedUnitCount;
            }

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
                });
            }
            // Leave group for cached file
            [self safelyLeaveDispatchGroup:@"CachedFile"];
            return nil;
        } else if (fileExists && self.deferSHAVerification && sha && sha.length > 0) {
            // File exists, but we're deferring SHA verification
            // Add to verification list for later checking
            [self addFileToVerificationList:path sha:sha altName:altName url:url size:size];

            // Update overall progress
            NSUInteger itemSize = size > 0 ? size : 100000; // Use 100KB estimate if size unknown
            @synchronized(self) {
                self.progress.totalUnitCount += itemSize;
                self.progress.completedUnitCount += itemSize; // Mark as complete
                self.textProgress.totalUnitCount = self.progress.totalUnitCount;
                self.textProgress.completedUnitCount = self.progress.completedUnitCount;
            }

            // Count as successful for UI purposes (will be verified later)
            self.successfulDownloads++;

            if (success) {
                dispatch_async(dispatch_get_global_queue(DISPATCH_QUEUE_PRIORITY_DEFAULT, 0), ^{
                    success();
                });
            }
            // Leave group for deferred verification
            [self safelyLeaveDispatchGroup:@"DeferredVerification"];
            return nil;
        } else if (![self checkAccessWithDialog:YES]) {
            // Leave group for access denied
            [self safelyLeaveDispatchGroup:@"AccessDenied"];
            self.totalDownloads--; // Decrement total count as this wasn't a real task
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
            // Leave group for invalid URL
            [self safelyLeaveDispatchGroup:@"InvalidURL"];
            self.totalDownloads--; // Decrement total count
            return nil;
        }

        NSMutableURLRequest *request = [NSMutableURLRequest requestWithURL:requestURL];
        request.timeoutInterval = 60; // Set a reasonable timeout
        request.cachePolicy = NSURLRequestReloadIgnoringLocalCacheData; // Avoid cache issues

        // Add to file list for UI tracking (before creating the task to avoid race conditions)
        @synchronized(self.fileList) {
            // Check if name is already in the fileList to avoid duplicates
            if (![self.fileList containsObject:name]) {
                [self.fileList addObject:name];
                self.needsUIUpdate = YES; // Flag UI update needed
            } else if (self.verboseLogging) {
                NSLog(@"[MCDL] File %@ already in tracking list, not adding duplicate", name);
            }
        }

        // Estimate size if 0, necessary for adding to totalUnitCount early
        NSUInteger estimatedSize = size > 0 ? size : 100000; // 100KB estimate
        NSProgress *downloadProgress = [NSProgress progressWithTotalUnitCount:estimatedSize];
        downloadProgress.kind = NSProgressKindFile;

        // Add this progress to our tracking list - using synchronization for thread safety
        BOOL progressAdded = NO;

        @synchronized(self) {
            @try {
                @synchronized(self.progressList) {
                    [self.progressList addObject:downloadProgress];
                }

                // Increment total BEFORE adding child
                self.progress.totalUnitCount += downloadProgress.totalUnitCount;
                self.textProgress.totalUnitCount = self.progress.totalUnitCount;

                // Add child progress
                [self.progress addChild:downloadProgress withPendingUnitCount:downloadProgress.totalUnitCount];

                // Mark progress as tracked
                objc_setAssociatedObject(downloadProgress, kIsTrackedByTaskKey, @YES, OBJC_ASSOCIATION_RETAIN_NONATOMIC);
                progressAdded = YES;
            } @catch (NSException *exception) {
                NSLog(@"[MCDL] Exception adding progress: %@", exception);

                // If adding progress fails, remove from fileList to maintain consistency
                @synchronized(self.fileList) {
                    // Only remove if this file was actually the last added
                    if ([self.fileList.lastObject isEqual:name]) {
                        [self.fileList removeLastObject];
                    }
                }
                self.totalDownloads--; // Decrement total count
                // Leave group for progress add failure
                [self safelyLeaveDispatchGroup:@"ProgressAddFail"];
                return nil; // Cannot proceed without progress tracking
            }
        }

        if (!progressAdded) {
            NSLog(@"[MCDL] Failed to add progress for %@", name);
            // Leave group for progress add failure
            [self safelyLeaveDispatchGroup:@"ProgressAddFail2"];
            self.totalDownloads--; // Decrement total count
            return nil;
        }

        // Create weak reference to self to avoid retain cycles
        __weak typeof(self) weakSelf = self;

        // Create download task with proper completion handling
        __block NSURLSessionDownloadTask *task = [self.manager downloadTaskWithRequest:request progress:^(NSProgress * _Nonnull taskProgress) {
            // Only update progress every 10% to reduce overhead
            static NSInteger lastReportedPercent = -1;
            NSInteger currentPercent = (NSInteger)(taskProgress.fractionCompleted * 100);

            // Use a higher frequency for UI updates if needed, e.g., every 5%
            if (currentPercent != lastReportedPercent && currentPercent % 5 == 0) {
                lastReportedPercent = currentPercent;

                // Safely update progress
                @synchronized(weakSelf) {
                    if (!weakSelf) return; // Check weakSelf validity
                    @try {
                        // Update completion amount with safeguards
                        CGFloat fraction = taskProgress.fractionCompleted;
                        if (!isnan(fraction) && fraction >= 0 && fraction <= 1.0) {
                            // Update the child progress's completed count
                            downloadProgress.completedUnitCount = (NSInteger)(downloadProgress.totalUnitCount * fraction);
                        }
                    } @catch (NSException *exception) {
                        // Just log and continue
                        NSLog(@"[MCDL] Exception in progress update: %@", exception);
                    }
                }
            }
        } destination:^NSURL * _Nonnull(NSURL * _Nonnull targetPath, NSURLResponse * _Nonnull response) {
            // Check weakSelf validity and return nil if invalid
            if (!weakSelf) return nil;

            // Log download start
            if (weakSelf.verboseLogging) {
                NSLog(@"[MCDL] Downloading %@", name);
            } else {
                // Log less frequently in non-verbose mode
                static int logCounter = 0;
                if (++logCounter % 100 == 0) {
                    NSLog(@"[MCDL] Downloading file %d: %@", logCounter, name);
                }
            }

            // Update progress size if response has size info and size was initially 0
            if (size == 0 && response.expectedContentLength > 0) {
                NSUInteger actualSize = (NSUInteger)response.expectedContentLength;

                @synchronized(weakSelf) {
                    if (!weakSelf) return nil; // Re-check weakSelf
                    @try {
                        // Update progress size and overall progress total
                        NSUInteger oldSize = downloadProgress.totalUnitCount;
                        downloadProgress.totalUnitCount = actualSize;

                        // Update parent progress total only if the task wasn't cancelled
                        if (weakSelf.progress && !weakSelf.progress.cancelled) {
                            weakSelf.progress.totalUnitCount = MAX(0, weakSelf.progress.totalUnitCount - oldSize + actualSize);
                        }

                        if (weakSelf.textProgress && !weakSelf.textProgress.cancelled) {
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

            if (!dirCreated && dirError.code != NSFileWriteFileExistsError) { // Ignore "already exists" error
                NSLog(@"[MCDL] Warning: Could not create directory at %@: %@",
                      dirPath, dirError ? dirError.localizedDescription : @"Unknown error");
                // Don't fail the whole download for a directory creation issue if it might exist
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
            if (!weakSelf) return; // Check weakSelf validity

            // Decrement active downloads count first
            @synchronized(weakSelf.pendingDownloads) {
                weakSelf.activeDownloads--;
            }

            // Safely check if progress is cancelled to avoid potential crashes
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

            if (isCancelled) {
                NSLog(@"[MCDL] Download cancelled for %@", name);
                // Leave group
                [weakSelf safelyLeaveDispatchGroup:@"Cancelled"];
                return;
            }

            if (error != nil) {
                // Always log errors
                NSLog(@"[MCDL] Download error for %@: %@", name, error.localizedDescription);

                if (failure) {
                    // Call failure callback on background thread
                    dispatch_async(dispatch_get_global_queue(DISPATCH_QUEUE_PRIORITY_DEFAULT, 0), ^{
                        failure(error);
                        // Leave group
                        [weakSelf safelyLeaveDispatchGroup:@"DownloadError"];
                    });
                } else {
                    [weakSelf finishDownloadWithError:error file:name];
                    // Leave group
                    [weakSelf safelyLeaveDispatchGroup:@"DownloadErrorFinish"];
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

            // Verify the downloaded file if checksum is provided and we're not deferring verification
            BOOL shaValid = YES;
            if (sha.length > 0 && !weakSelf.deferSHAVerification) {
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

                        // Decrement success count on SHA failure
                        weakSelf.successfulDownloads--;

                        if (failure) {
                            dispatch_async(dispatch_get_global_queue(DISPATCH_QUEUE_PRIORITY_DEFAULT, 0), ^{
                                failure(shaError);
                                // Leave group
                                [weakSelf safelyLeaveDispatchGroup:@"SHAFailure"];
                            });
                        } else {
                            [weakSelf finishDownloadWithErrorString:[NSString stringWithFormat:@"Failed to verify file %@: SHA1 mismatch", path.lastPathComponent]];
                            // Leave group
                            [weakSelf safelyLeaveDispatchGroup:@"SHAFailureFinish"];
                        }
                        return;
                    }
                }
            } else if (sha.length > 0 && weakSelf.deferSHAVerification) {
                // Add to verification list for later checking
                [weakSelf addFileToVerificationList:path sha:sha altName:altName url:url size:size];
            }

            // Ensure progress is marked as complete
            @synchronized(weakSelf) {
                if (!weakSelf) return;
                @try {
                    // Mark the individual progress complete
                    if (downloadProgress.totalUnitCount > 0) {
                        downloadProgress.completedUnitCount = downloadProgress.totalUnitCount;
                    } else {
                        // If totalUnitCount was 0 (or unknown), ensure completed is at least 1 if successful
                        downloadProgress.completedUnitCount = 1;
                        downloadProgress.totalUnitCount = 1; // Set total to 1 to reflect completion
                    }
                    // Trigger UI update after completion
                    weakSelf.needsUIUpdate = YES;
                } @catch (NSException *exception) {
                    NSLog(@"[MCDL] Exception marking progress complete: %@", exception);
                }
            }

            // Call success callback on background thread if SHA is valid
            if (success && shaValid) {
                dispatch_async(dispatch_get_global_queue(DISPATCH_QUEUE_PRIORITY_DEFAULT, 0), ^{
                    success();
                });
            }

            // Leave the dispatch group for this completed task
            [weakSelf safelyLeaveDispatchGroup:@"Success"];

            // Process next in queue if needed
            dispatch_async(weakSelf.downloadQueue, ^{
                [weakSelf processNextDownloadInQueue];
            });
        }];

        // Add the task to the pending queue
        @synchronized(self.pendingDownloads) {
            [self.pendingDownloads addObject:task];
        }

        // Trigger processing of the queue
        dispatch_async(self.downloadQueue, ^{
            [self processNextDownloadInQueue];
        });

        return task;
    }
}

// Simplified compatibility method with just success callback
- (NSURLSessionDownloadTask *)createDownloadTask:(NSString *)url
                                           size:(NSUInteger)size
                                            sha:(NSString *)sha
                                        altName:(NSString *)altName
                                         toPath:(NSString *)path
                                        success:(void (^)(void))success {
    // Simply forward to the comprehensive method with nil for failure
    return [self createDownloadTask:url size:size sha:sha altName:altName toPath:path success:success failure:nil];
}

// Basic compatibility method with no callbacks
- (NSURLSessionDownloadTask *)createDownloadTask:(NSString *)url
                                          size:(NSUInteger)size
                                           sha:(NSString *)sha
                                       altName:(NSString *)altName
                                        toPath:(NSString *)path {
    // Forward to the comprehensive method with nil for both callbacks
    return [self createDownloadTask:url size:size sha:sha altName:altName toPath:path success:nil failure:nil];
}

// New method to add a file to the verification list
- (void)addFileToVerificationList:(NSString *)path sha:(NSString *)sha altName:(NSString *)altName url:(NSString *)url size:(NSUInteger)size {
    @synchronized(self.pendingVerificationList) {
        // Create a dictionary to store verification info
        NSDictionary *verificationItem = @{
            @"path": path,
            @"sha": sha,
            @"altName": altName ?: [NSNull null],
            @"url": url,
            @"size": @(size)
        };

        // Add to list
        [self.pendingVerificationList addObject:verificationItem];
    }
}

// New method to verify all pending files
- (BOOL)verifyPendingFiles {
    // Return true if no files to verify
     if (self.pendingVerificationList.count == 0) {
         return YES;
     }


    NSLog(@"[MCDL] Starting verification of %lu files", (unsigned long)self.pendingVerificationList.count);

    // Make a copy of the verification list to work with
    NSArray *verificationItems = nil;
    @synchronized(self.pendingVerificationList) {
        verificationItems = [NSArray arrayWithArray:self.pendingVerificationList];
         [self.pendingVerificationList removeAllObjects]; // Clear original list after copying
    }


    // Track failed files
    NSMutableArray *failedItems = [NSMutableArray array];

    // Verify each file
    for (NSDictionary *item in verificationItems) {
        NSString *path = item[@"path"];
        NSString *sha = item[@"sha"];
        NSString *altName = [item[@"altName"] isEqual:[NSNull null]] ? nil : item[@"altName"];

        // Check if file exists and SHA matches
        if (![NSFileManager.defaultManager fileExistsAtPath:path] ||
            ![self checkSHAIgnorePref:sha forFile:path altName:altName logSuccess:YES]) {
            [failedItems addObject:item];
        }
    }

    // If any files failed verification, redownload them
    if (failedItems.count > 0) {
        NSLog(@"[MCDL] %lu files failed verification and will be redownloaded", (unsigned long)failedItems.count);

        // Prepare for redownload phase (reset counters, but keep overall progress total)
         @synchronized(self) {
             // Adjust progress - subtract estimated size of failed files
             NSUInteger sizeToSubtract = 0;
             for (NSDictionary *item in failedItems) {
                 sizeToSubtract += [item[@"size"] unsignedIntegerValue] > 0 ? [item[@"size"] unsignedIntegerValue] : 100000;
             }
             self.progress.completedUnitCount = MAX(0, self.progress.completedUnitCount - sizeToSubtract);

             // Adjust total downloads and success counts
             self.successfulDownloads -= failedItems.count; // Adjust success count
             self.totalDownloads = failedItems.count; // Reset total to only the failed items

             // Reset group counters for the redownload phase
             [self.completionLock lock];
             self.totalTasksEnqueued = 0; // Reset enqueue count for redownload phase
             self.tasksLeftGroup = 0; // Reset leave count for redownload phase
             [self.completionLock unlock];
             self.isDownloadPhaseComplete = NO; // Mark as not complete again
         }



        // Set deferSHAVerification to false to force immediate verification for redownloads
        self.deferSHAVerification = NO;

        // Redownload each failed file
        for (NSDictionary *item in failedItems) {
            NSString *path = item[@"path"];
            NSString *sha = item[@"sha"];
            NSString *altName = [item[@"altName"] isEqual:[NSNull null]] ? nil : item[@"altName"];
            NSString *url = item[@"url"];
            NSUInteger size = [item[@"size"] unsignedIntegerValue];

            // Create download task for this file - this will re-enter the group
            [self redownloadFileWithPath:path sha:sha altName:altName url:url size:size];
        }

        return NO; // Indicate verification failed and redownload is in progress
    }

    // All files verified successfully
    NSLog(@"[MCDL] All %lu files verified successfully", (unsigned long)verificationItems.count);

    return YES; // Indicate all files verified successfully
}


// Method to redownload a specific file
- (void)redownloadFileWithPath:(NSString *)path sha:(NSString *)sha altName:(NSString *)altName url:(NSString *)url size:(NSUInteger)size {
    NSLog(@"[MCDL] Redownloading file: %@", altName ?: path.lastPathComponent);

    // Create a download task for this file - this will re-enter the group and queue
    // Note: Success/failure callbacks are handled by the main completion handler now.
    [self createDownloadTask:url size:size sha:sha altName:altName toPath:path success:nil failure:nil];

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
        self.isDownloadPhaseComplete = YES; // Mark as complete even on error to unblock UI
    }

    // Cancel all active downloads and reset session
    [self.manager invalidateSessionCancelingTasks:YES resetSession:YES];

    // Clear pending downloads
    @synchronized(self.pendingDownloads) {
        NSInteger countToLeave = self.pendingDownloads.count;
        [self.pendingDownloads removeAllObjects];
        self.activeDownloads = 0;
        // Leave the group for any cancelled pending tasks
         for (NSInteger i = 0; i < countToLeave; i++) {
              [self safelyLeaveDispatchGroup:@"CancelledPendingOnError"];
         }
    }


    // Show error dialog on the main thread
     dispatch_async(dispatch_get_main_queue(), ^{
         showDialog(localize(@"Error", nil), error);
     });


    // Call error handler if set
    if (self.handleError) {
        // Call error handler asynchronously on a background thread if needed
        dispatch_async(dispatch_get_global_queue(DISPATCH_QUEUE_PRIORITY_DEFAULT, 0), ^{
             self.handleError();
        });
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
            self.isDownloadPhaseComplete = YES; // Mark complete to unblock
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
             NSLog(@"[MCDL] SHA1 checker: file exists, skipping SHA check as none provided for %@", altName ?: path.lastPathComponent);
        }
        return existence;
    }

    // Get file attributes to check file size
    NSError *attributesError = nil;
    NSDictionary *fileAttributes = [[NSFileManager defaultManager] attributesOfItemAtPath:path error:&attributesError];

    if (attributesError || !fileAttributes) {
        if (self.verboseLogging) {
             NSLog(@"[MCDL] SHA1 checker: couldn't get file attributes for %@: %@", altName ?: path.lastPathComponent, attributesError ? attributesError.localizedDescription : @"Unknown error");
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
     NSData *data = [NSData dataWithContentsOfFile:path options:NSDataReadingMappedIfSafe error:nil]; // Use mapped reading for large files
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
        if (([altName hasSuffix:@".json"] && [path containsString:@"/versions/"]) ||
            ([path containsString:@"/versions/"] && [path hasSuffix:@".jar"])) {

            BOOL fileExists = [NSFileManager.defaultManager fileExistsAtPath:path];
            if (!fileExists) {
                if (self.verboseLogging) {
                    NSLog(@"[MCDL] Version file doesn't exist, downloading: %@", altName);
                }
                return NO;
            }
            // If it exists, fall through to SHA check if enabled
        }
    }

    // For other files or existing version files, perform the SHA check based on preference
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
    @synchronized(self) {
        if (!self.metadata) {
            self.metadata = [NSMutableDictionary dictionary];
        } else {
            [self.metadata removeAllObjects];
        }
        // Critical: Mark this as NOT a modpack installation
        self.metadata[@"isModpackInstall"] = @NO;
        self.isDownloadPhaseComplete = NO; // Reset completion flag
    }

    NSLog(@"[MCDL] Starting download for version: %@", version[@"id"]);

    // --- Setup Final Completion Notification ---
    // This is set up ONCE at the beginning. It will trigger checkFinalCompletion
    // only when ALL tasks added to downloadCompletionGroup have left.
    __weak typeof(self) weakSelf = self;
    dispatch_group_notify(self.downloadCompletionGroup, dispatch_get_global_queue(DISPATCH_QUEUE_PRIORITY_DEFAULT, 0), ^{
        [weakSelf checkFinalCompletion];
    });

    // --- Start the download chain ---
    // Enter the group for the overall process. This ensures notify waits even if early steps fail fast.
    dispatch_group_enter(self.downloadCompletionGroup);
    [self.completionLock lock]; self.totalTasksEnqueued++; [self.completionLock unlock];

    // Stage 1: Download Version Metadata
    [self downloadVersionMetadata:version success:^{
        // Stage 2: Process Libraries, Client Jar, and Assets (triggered by metadata success)
        [self processPostMetadataDownloads];
        // Leave the group for the initial stage completion
        [weakSelf safelyLeaveDispatchGroup:@"OverallProcessStart"];
    }];
}

- (void)processPostMetadataDownloads {
    @synchronized(self) {
        if (!self || self.progress.cancelled) return;

        NSDictionary *localMetadata = [self.metadata copy]; // Use a local copy

        // Enter group for libraries and client JAR
        dispatch_group_enter(self.downloadCompletionGroup);
        [self.completionLock lock]; self.totalTasksEnqueued++; [self.completionLock unlock];

        // Enqueue Libraries and Client JAR
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
            [self.completionLock lock]; self.totalTasksEnqueued++; [self.completionLock unlock];
            
            if (self.verboseLogging) NSLog(@"[MCDL] Downloading Asset Metadata...");
            [self downloadAssetMetadataWithSuccess:^{
                @synchronized(self) {
                    if (!self || self.progress.cancelled) {
                        [self safelyLeaveDispatchGroup:@"AssetIndexCancelled"];
                        return;
                    }
                    // Asset index metadata is now in self.metadata[@"assetIndexObj"]
                    NSDictionary *assetIndexObj = self.metadata[@"assetIndexObj"];
                    if (assetIndexObj && assetIndexObj[@"objects"]) {
                        // Enter group for asset downloads as a whole
                        dispatch_group_enter(self.downloadCompletionGroup);
                        [self.completionLock lock]; self.totalTasksEnqueued++; [self.completionLock unlock];
                        
                        if (self.verboseLogging) NSLog(@"[MCDL] Enqueuing assets...");
                        [self downloadClientAssets:assetIndexObj]; // This enqueues asset downloads
                        
                        // Leave group for asset downloads
                        [self safelyLeaveDispatchGroup:@"AssetDownloads"];
                        
                        [self.metadata removeObjectForKey:@"assetIndexObj"]; // Clean up
                    } else {
                        NSLog(@"[MCDL] No assets found in index or index missing.");
                    }
                    // Leave group after processing assets based on this index
                    [self safelyLeaveDispatchGroup:@"AssetIndexSuccess"];
                }
            }];
        } else {
            NSLog(@"[MCDL] No asset index found. Skipping asset downloads.");
        }

        // Only leave AFTER all other downloads have been queued to prevent premature completion
        [self safelyLeaveDispatchGroup:@"OverallProcessStart"];
    }
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
    if (dirError && dirError.code != NSFileWriteFileExistsError) {
        NSLog(@"[MCDL] Error creating version directory %@: %@", versionDir, dirError.localizedDescription);
        [self finishDownloadWithErrorString:[NSString stringWithFormat:@"Failed to create version directory: %@", dirError.localizedDescription]];
        return;
    }

    // Find it again to resolve latest-*
     NSDictionary* versionInfoToDownload = (id)[MinecraftResourceUtils findVersion:versionStr inList:remoteVersionList];


    // Create wrapped success callback
    __weak typeof(self) weakSelf = self;
    void(^wrappedSuccess)(void) = ^{
        // Safely check if task is cancelled
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
            if (!weakSelf) return;
            // Store version metadata
             // Use mutableCopy to ensure we can modify it later
             weakSelf.metadata = [jsonObject mutableCopy];

            // Explicitly mark as NOT a modpack installation
            weakSelf.metadata[@"isModpackInstall"] = @NO;
        }

        // Handle inheritsFrom for mod versions
        @synchronized(weakSelf) {
             if (!weakSelf) return;
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
                      weakSelf.metadata = inheritsFromDict; // Replace metadata with merged parent
                 } else {
                      // If parent JSON is missing or invalid, try downloading it.
                      // Find the parent version in the remote list
                      NSDictionary *parentVersionInfo = (id)[MinecraftResourceUtils findVersion:inheritsFromVersionId inList:remoteVersionList];
                      if (parentVersionInfo) {
                           NSLog(@"[MCDL] Parent JSON missing, attempting to download: %@", inheritsFromVersionId);
                           // Download the parent JSON recursively. The success block here will re-trigger the merging logic.
                           [weakSelf downloadVersionMetadata:parentVersionInfo success:^{
                                // After parent is downloaded, re-attempt merging with the original child metadata
                                // Need to re-parse the child JSON as self.metadata was overwritten
                                NSMutableDictionary *childJson = parseJSONFromFile(path);
                                NSMutableDictionary *parentJson = parseJSONFromFile(inheritsFromPath);
                                if (childJson && !childJson[@"NSErrorObject"] && parentJson && !parentJson[@"NSErrorObject"]) {
                                     [MinecraftResourceUtils processVersion:childJson inheritsFrom:parentJson];
                                     @synchronized(weakSelf) {
                                         if (!weakSelf) return;
                                         weakSelf.metadata = parentJson; // Replace metadata with merged parent
                                         [MinecraftResourceUtils tweakVersionJson:weakSelf.metadata]; // Tweak merged version
                                     }
                                     // Call original success callback now that merging is complete
                                     if (success) { success(); }
                                } else {
                                     [weakSelf finishDownloadWithErrorString:@"Failed to load or merge inherited version JSON after download."];
                                }
                           }];
                           return; // Return here, the recursive call will handle the final success call
                      } else {
                           [weakSelf finishDownloadWithErrorString:[NSString stringWithFormat:@"Could not find inherited version %@ in remote list.", inheritsFromVersionId]];
                           return;
                      }
                 }
             }

            // Apply version tweaks after potential merging
            [MinecraftResourceUtils tweakVersionJson:weakSelf.metadata];
        }


        // Call original success callback
        if (success) {
            success();
        }
    };

    if (!versionInfoToDownload) {
        // This is likely a local version, check if json exists
         if ([[NSFileManager defaultManager] fileExistsAtPath:path]) {
             NSLog(@"[MCDL] Using existing local/custom version JSON: %@", path.lastPathComponent);
             wrappedSuccess(); // Process existing file
         } else {
             // If JSON doesn't exist locally and wasn't in remote list, it's an error
             [self finishDownloadWithErrorString:[NSString stringWithFormat:@"Version JSON not found locally or remotely: %@", versionStr]];
         }
        return;
    }


    // Re-get version string and URL after resolving latest-* and inheritsFrom
    versionStr = versionInfoToDownload[@"id"];
    NSString *url = versionInfoToDownload[@"url"];
    NSString *sha = versionInfoToDownload[@"sha1"]; // Use sha1 from manifest if available
    NSUInteger size = [versionInfoToDownload[@"size"] unsignedLongLongValue];

    if (self.verboseLogging) {
        NSLog(@"[MCDL] Downloading version JSON from %@", url);
    }

    NSURLSessionDownloadTask *task = [self createDownloadTask:url size:size sha:sha altName:[path lastPathComponent] toPath:path success:wrappedSuccess failure:^(NSError *error){
         // If download fails, try to use existing file if it's valid (less strict for JSON)
         if ([[NSFileManager defaultManager] fileExistsAtPath:path]) {
              NSLog(@"[MCDL] Warning: Version JSON download failed, but using existing file: %@", path.lastPathComponent);
              wrappedSuccess(); // Try to proceed with existing file
         } else {
              [self finishDownloadWithError:error file:[path lastPathComponent]];
         }
    }];


    // If no task was created (e.g., file exists and SHA matches), still call success
    if (!task && !self.progress.cancelled) {
         if ([[NSFileManager defaultManager] fileExistsAtPath:path]) {
              wrappedSuccess();
         } else {
              [self finishDownloadWithErrorString:[NSString stringWithFormat:@"File %@ missing and download task not created.", path.lastPathComponent]];
         }
    } else if (!task && self.progress.cancelled) {
         NSLog(@"[MCDL] Version JSON download cancelled before task creation.");
    }
}


- (void)downloadAssetMetadataWithSuccess:(void (^)(void))success {
    NSDictionary *assetIndex = nil;
    @synchronized(self) {
        if (!self) return;
        assetIndex = [self.metadata[@"assetIndex"] copy]; // Use a copy
    }

    if (!assetIndex) {
        if (success) success(); // Call success immediately if no asset index
        return;
    }

    NSString *assetIndexId = assetIndex[@"id"];
    NSString *name = [NSString stringWithFormat:@"assets/indexes/%@.json", assetIndexId];
    NSString *path = [@(getenv("POJAV_GAME_DIR")) stringByAppendingPathComponent:name];
    NSString *url = assetIndex[@"url"];
    NSString *sha = assetIndex[@"sha1"]; // Use sha1 from assetIndex
    NSUInteger size = [assetIndex[@"size"] unsignedLongLongValue];

    // Create wrapped success callback
    __weak typeof(self) weakSelf = self;
    void(^wrappedSuccess)(void) = ^{
        // Safely check if task is cancelled
        BOOL isCancelled = NO;
        @synchronized(weakSelf) {
            if (!weakSelf) return;
            @try { isCancelled = weakSelf.progress.cancelled; } @catch (NSException *e) {}
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

        // Parse JSON with mutable containers option
        id jsonObject = [NSJSONSerialization JSONObjectWithData:jsonData
                                                       options:NSJSONReadingMutableContainers
                                                         error:&jsonError];
        if (!jsonObject || jsonError) {
            NSLog(@"[MCDL] Error parsing asset index JSON %@: %@", name, jsonError.localizedDescription);
            [weakSelf finishDownloadWithErrorString:[NSString stringWithFormat:@"Error parsing asset index JSON: %@", jsonError.localizedDescription]];
            return;
        }

        // Set asset index object safely
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
    BOOL dirCreated = [[NSFileManager defaultManager] createDirectoryAtPath:dirPath
                                               withIntermediateDirectories:YES
                                                                attributes:nil
                                                                     error:&dirError];
    if (!dirCreated && dirError.code != NSFileWriteFileExistsError) {
        NSLog(@"[MCDL] Error creating asset index directory: %@", dirError.localizedDescription);
        [self finishDownloadWithErrorString:[NSString stringWithFormat:@"Failed to create asset index directory: %@", dirError.localizedDescription]];
        return;
    }

    NSURLSessionDownloadTask *task = [self createDownloadTask:url size:size sha:sha altName:name toPath:path success:wrappedSuccess failure:^(NSError *error) {
         // If download fails, try to use existing file if it's valid
         if ([[NSFileManager defaultManager] fileExistsAtPath:path]) {
              NSLog(@"[MCDL] Warning: Asset index download failed, but using existing file: %@", path.lastPathComponent);
              wrappedSuccess(); // Try to proceed with existing file
         } else {
              [self finishDownloadWithError:error file:name];
         }
    }];


    // If no task was created (e.g., file exists and SHA matches), still call success
    if (!task && !self.progress.cancelled) {
         if ([[NSFileManager defaultManager] fileExistsAtPath:path]) {
              wrappedSuccess();
         } else {
              [self finishDownloadWithErrorString:[NSString stringWithFormat:@"File %@ missing and download task not created.", path.lastPathComponent]];
         }
    } else if (!task && self.progress.cancelled) {
         NSLog(@"[MCDL] Asset index download cancelled before task creation.");
    }
}


// Reintegrated implementation
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

    // Process each library directly without batching
    for (NSDictionary *library in libraries) {
         BOOL isCancelled = NO;
         @synchronized(self) {
             @try { isCancelled = self.progress.cancelled; } @catch(NSException* e){}
         }
        if (isCancelled) break;


        NSString *name = library[@"name"];
        if (!name) continue;

        // Skip Forge/NeoForge client JARs entirely - they're already installed by the installer
        if (([name containsString:@"net.minecraftforge:forge:"] ||
             [name containsString:@"net.neoforged:neoforge:"] ||
             [name containsString:@"net.neoforged.forge:forge:"]) && // Handle older NeoForge naming
            ([name hasSuffix:@":client"] || [name hasSuffix:@":universal"] || [name containsString:@"-installer"])) { // Also skip installers
            if (self.verboseLogging) {
                NSLog(@"[MCDL] Skipping Forge/NeoForge JAR %@ - installed separately", name);
            }
            continue;
        }


        NSMutableDictionary *artifactDict = [library[@"downloads"][@"artifact"] mutableCopy]; // Make mutable
        if (artifactDict == nil && [name containsString:@":"]) {
             if (self.verboseLogging) {
                 NSLog(@"[MCDL] Unknown artifact object for %@, attempting to generate one", name);
             }
             artifactDict = [[NSMutableDictionary alloc] init];

            // Standard library URL construction
             NSString *prefix = library[@"url"] ?: @"https://libraries.minecraft.net/"; // Default to Minecraft libs
             prefix = [prefix stringByReplacingOccurrencesOfString:@"http://" withString:@"https://"]; // Ensure HTTPS
             if (![prefix hasSuffix:@"/"]) {
                 prefix = [prefix stringByAppendingString:@"/"];
             }

            NSArray *libParts = [name componentsSeparatedByString:@":"];

            // Handle library names with more than 3 components (e.g., Forge libraries with classifier)
            if (libParts.count >= 3) {
                NSString *group = [libParts[0] stringByReplacingOccurrencesOfString:@"." withString:@"/"];
                NSString *artifactName = libParts[1];
                NSString *version = libParts[2];

                // Check if we have a classifier (4th component) or extension (if specified after version)
                NSString *classifier = @"";
                NSString *extension = @"jar"; // Default extension

                if (libParts.count > 3) {
                     // Check if the 4th part contains '@' indicating an extension
                     NSRange extRange = [libParts[3] rangeOfString:@"@"];
                     if (extRange.location != NSNotFound) {
                          classifier = [libParts[3] substringToIndex:extRange.location];
                          extension = [libParts[3] substringFromIndex:extRange.location + 1];
                     } else {
                          classifier = libParts[3];
                     }
                     // Append classifier with a hyphen if it exists
                     if (classifier.length > 0) {
                          classifier = [NSString stringWithFormat:@"-%@", classifier];
                     }
                }

                // Construct path and URL correctly
                artifactDict[@"path"] = [NSString stringWithFormat:@"%@/%@/%@/%@-%@%@.%@",
                                     group, artifactName, version, artifactName, version, classifier, extension];
                artifactDict[@"url"] = [NSString stringWithFormat:@"%@%@", prefix, artifactDict[@"path"]];

                // Safely get SHA1 from checksums if available
                id checksums = library[@"checksums"];
                if (checksums && [checksums isKindOfClass:[NSArray class]]) {
                    NSArray *checksumsArray = (NSArray *)checksums;
                    if (checksumsArray.count > 0 && [checksumsArray[0] isKindOfClass:[NSString class]]) {
                        artifactDict[@"sha1"] = checksumsArray[0];
                    }
                } else if (library[@"sha1"] && [library[@"sha1"] isKindOfClass:[NSString class]]) { // Handle direct sha1 property
                     artifactDict[@"sha1"] = library[@"sha1"];
                }
            } else {
                 // Fallback for potential malformed names
                 NSLog(@"[MCDL] Warning: Malformed library name encountered: %@", name);
                 continue; // Skip this library
            }
        }

        // Skip library if marked to skip
         if ([library[@"skip"] boolValue]) {
             if (self.verboseLogging) {
                 NSLog(@"[MCDL] Skipped library %@", name);
             }
             continue;
         }

         // Skip if rules block it (basic OS check for now)
         NSArray* rules = library[@"rules"];
         if (rules) {
             BOOL allow = YES; // Default to allow if no rules match
             for (NSDictionary* rule in rules) {
                 NSString* action = rule[@"action"]; // "allow" or "disallow"
                 NSDictionary* os = rule[@"os"];
                 if (os) {
                      NSString* osName = os[@"name"];
                      // We only care about disallowing non-mac/non-ios or allowing only mac/ios
                      if ([action isEqualToString:@"disallow"] && ![osName isEqualToString:@"osx"] && ![osName isEqualToString:@"ios"]) {
                           allow = NO; break; // Disallow if rule is for other OS
                      } else if ([action isEqualToString:@"allow"] && ![osName isEqualToString:@"osx"] && ![osName isEqualToString:@"ios"]) {
                           allow = NO; break; // Disallow if allow rule is not for mac/ios
                      } else if ([action isEqualToString:@"allow"] && ([osName isEqualToString:@"osx"] || [osName isEqualToString:@"ios"])) {
                           allow = YES; break; // Explicitly allow for mac/ios
                      }
                 } else {
                      // If no OS specified, action applies universally based on the last rule
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


        // Build the download path
        NSString *path = [NSString stringWithFormat:@"%s/libraries/%@", getenv("POJAV_GAME_DIR"), artifactDict[@"path"]];
        NSString *sha = artifactDict[@"sha1"];
        NSUInteger size = [artifactDict[@"size"] unsignedLongLongValue];
        NSString *url = artifactDict[@"url"];

        // Skip if URL is missing - don't create invalid tasks
        if (!url || [url length] == 0) {
            NSLog(@"[MCDL] Warning: Skipping library %@ due to missing URL", name);
            continue;
        }

        // Create download task and add to tasks list
        NSURLSessionDownloadTask *task = [self createDownloadTask:url size:size sha:sha altName:name toPath:path success:nil failure:nil];
        if (task) {
            [tasks addObject:task];
        }
    }

    NSLog(@"[MCDL] Enqueued %ld library downloads", (long)tasks.count);
    return tasks;
}

// Reintegrated implementation
- (NSArray *)downloadClientAssets:(NSDictionary *)assetIndexObj {
    // Use a synchronized block to ensure we only process assets once per session
    @synchronized(self) {
        // If we've already processed assets for this download session, return an empty array
        if (self.hasProcessedAssets) {
            NSLog(@"[MCDL] Assets already processed for this session, skipping");
            return @[];
        }

        // Mark that we've processed assets
        self.hasProcessedAssets = YES;
    }

    NSMutableArray *tasks = [NSMutableArray new];

    if (!assetIndexObj || !assetIndexObj[@"objects"] || ![assetIndexObj[@"objects"] isKindOfClass:[NSDictionary class]]) {
        return tasks;
    }

    NSDictionary *objectsDict = assetIndexObj[@"objects"];
    NSArray *assetNames = objectsDict.allKeys;
    NSInteger totalAssets = assetNames.count;

    NSLog(@"[MCDL] Processing %ld assets for download", (long)totalAssets);

    // Set up asset directories
    NSString *assetsDir = [NSString stringWithFormat:@"%s/assets/objects", getenv("POJAV_GAME_DIR")];
    NSString *resourcesDir = [NSString stringWithFormat:@"%s/resources", getenv("POJAV_GAME_DIR")];
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


    // Process all assets without batching
    for (NSString *name in assetNames) {
         BOOL isCancelled = NO;
         @synchronized(self) {
             @try { isCancelled = self.progress.cancelled; } @catch(NSException *e){}
         }
        if (isCancelled) break;


        NSDictionary *object = assetIndexObj[@"objects"][name];
        NSString *hash = object[@"hash"];
         if (!hash || hash.length < 2) { // Need at least 2 chars for subdir
              NSLog(@"[MCDL] Warning: Skipping asset %@ due to missing or short hash", name);
              continue;
         }
        NSString *pathname = [NSString stringWithFormat:@"%@/%@", [hash substringToIndex:2], hash];
        NSUInteger size = [object[@"size"] unsignedLongLongValue];

        NSString *path;
        if ([assetIndexObj[@"map_to_resources"] boolValue]) {
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
        NSURLSessionDownloadTask *task = [self createDownloadTask:url size:size sha:hash altName:name toPath:path success:nil failure:nil];

        if (task) {
            [tasks addObject:task];
        }
    }

    NSLog(@"[MCDL] Enqueued %ld asset downloads", (long)tasks.count);
    return tasks;
}


- (void)downloadModpackFromAPI:(ModpackAPI *)api detail:(NSDictionary *)modDetail atIndex:(NSUInteger)selectedVersion {
    [self prepareForDownload];

    // Reset counters
    self.successfulDownloads = 0;
    self.totalDownloads = 0;

    // Create metadata dictionary if needed
    @synchronized(self) {
         if (!self.metadata) {
              self.metadata = [NSMutableDictionary dictionary];
         } else {
              [self.metadata removeAllObjects];
         }
         // Explicitly mark this as a modpack installation
         self.metadata[@"isModpackInstall"] = @YES;
         self.isDownloadPhaseComplete = NO; // Reset completion
    }


    NSString *url = modDetail[@"versionUrls"][selectedVersion];
    NSUInteger size = [modDetail[@"versionSizes"][selectedVersion] unsignedLongLongValue];
    NSString *sha = modDetail[@"versionHashes"][selectedVersion];

    // Use the original title without converting to lowercase or replacing spaces with underscores
    NSString *name = [modDetail[@"title"] stringByTrimmingCharactersInSet:NSCharacterSet.whitespaceCharacterSet];

    // For the filesystem paths, create a sanitized version of the name (for the zip file only)
    NSString *sanitizedName = [[name lowercaseString] stringByReplacingOccurrencesOfString:@" " withString:@"_"];
    sanitizedName = [sanitizedName stringByReplacingOccurrencesOfString:@"[^a-z0-9_]+" withString:@"" options:NSRegularExpressionSearch range:NSMakeRange(0, sanitizedName.length)]; // Sanitize further
    NSString *packagePath = [NSTemporaryDirectory() stringByAppendingFormat:@"/%@.zip", sanitizedName];


    NSLog(@"[MCDL] Starting download for modpack: %@", name);

    // Get the game directory for this modpack
    NSString *gameDir = [PLProfiles uniqueGameDirForProfileName:name];

    // Get the full absolute path where we'll extract the modpack
    NSString *destPath = [PLProfiles fullPathForProfileWithName:name gameDir:gameDir];

    // Store the game directory in metadata for proper profile creation
     @synchronized(self) {
         self.metadata[@"gameDir"] = gameDir;
     }


    // Create a display name for progress reporting
    NSString *displayName = [NSString stringWithFormat:@"Downloading modpack: %@", name];

    // Create success callback for modpack download
    __weak typeof(self) weakSelf = self;
    void(^modpackSuccess)(void) = ^{
        @synchronized(weakSelf) {
            if (!weakSelf) return;
            // Reset progress for extraction phase
             weakSelf.progress.totalUnitCount = 1; // Start with 1 unit for extraction
             weakSelf.progress.completedUnitCount = 0;
             weakSelf.textProgress.totalUnitCount = 1;
             weakSelf.textProgress.completedUnitCount = 0;

             weakSelf.totalDownloads = 0; // Reset counts for mod downloads
             weakSelf.successfulDownloads = 0;
             weakSelf.totalTasksEnqueued = 0; // Reset group counts too
             weakSelf.tasksLeftGroup = 0;
             weakSelf.isDownloadPhaseComplete = NO; // Ensure completion is reset
        }

        // Add extraction marker to file list
         @synchronized(weakSelf.fileList) {
             if (!weakSelf) return;
             [weakSelf.fileList removeAllObjects]; // Clear previous download entry
             [weakSelf.fileList addObject:[NSString stringWithFormat:@"Preparing modpack %@", name]];
         }
         weakSelf.needsUIUpdate = YES;


        NSLog(@"[MCDL] Modpack download complete, proceeding to extraction and mod downloads.");

        // Use the API to handle extraction and installation (which includes mod downloads)
        [api downloader:weakSelf submitDownloadTasksFromPackage:packagePath toPath:destPath];
         // The API's downloader method should now enqueue individual mod tasks,
         // which will increment totalDownloads and use the downloadCompletionGroup.
    };

    // Failure callback to handle retries for modpack download
    void(^modpackFailure)(NSError *error) = ^(NSError *error) {
        if (!weakSelf) return;
        NSLog(@"[MCDL] Failed to download modpack: %@. Retrying...", error.localizedDescription);

        // Add retry attempt to file list for UI visibility
        @synchronized(weakSelf.fileList) {
             if (!weakSelf) return;
            [weakSelf.fileList addObject:[NSString stringWithFormat:@"Retrying download for %@", name]];
        }
        weakSelf.needsUIUpdate = YES;

        // Create a retry task - this will re-enter the group
        [weakSelf createDownloadTask:url
                                size:size
                                 sha:sha
                             altName:[NSString stringWithFormat:@"Downloading %@ (retry)", name]
                              toPath:packagePath
                             success:modpackSuccess
                             failure:^(NSError *retryError) {
            // If retry also fails, show error
            [weakSelf finishDownloadWithErrorString:[NSString stringWithFormat:@"Failed to download modpack after retry: %@", retryError.localizedDescription]];
        }];
    };

    // Create initial download task for the modpack zip
    [self createDownloadTask:url
                        size:size
                         sha:sha
                     altName:displayName
                      toPath:packagePath
                     success:modpackSuccess
                     failure:modpackFailure];

     // Start processing the queue (which now contains the modpack zip download)
     dispatch_async(self.downloadQueue, ^{
         [self processNextDownloadInQueue];
     });
}

@end

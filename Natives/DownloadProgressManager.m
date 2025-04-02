// DownloadProgressManager.m

#import "DownloadProgressManager.h"

// Notification names
NSString * const DMDownloadStageChangedNotification = @"DMDownloadStageChangedNotification";
NSString * const DMProgressUpdatedNotification = @"DMProgressUpdatedNotification";
NSString * const DMFileProgressUpdatedNotification = @"DMFileProgressUpdatedNotification";
NSString * const DMDownloadCompletedNotification = @"DMDownloadCompletedNotification";

// Private properties
@interface DownloadProgressManager ()
@property (nonatomic, assign) DownloadStage currentStage;
@property (nonatomic, strong) NSProgress *overallProgress;
@property (nonatomic, strong) NSProgress *currentStageProgress;
@property (nonatomic, strong) NSMutableArray<DownloadFileItem *> *fileItems;
@property (nonatomic, assign) BOOL isComplete;
@property (nonatomic, assign) BOOL isModpackInstall;
@property (nonatomic, assign) BOOL isError;
@property (nonatomic, copy, nullable) NSString *errorMessage;
@property (nonatomic, assign) NSInteger successfulDownloads;
@property (nonatomic, assign) NSInteger totalDownloads;
@property (nonatomic, assign) NSUInteger totalBytes;
@property (nonatomic, assign) NSUInteger completedBytes;
@property (nonatomic, strong) NSDate *startTime;
@property (nonatomic, strong, nullable) NSDate *endTime;
@property (nonatomic, strong) dispatch_queue_t progressQueue;
@property (nonatomic, strong) NSTimer *notificationTimer;
@property (nonatomic, assign) BOOL needsNotification;
@end

@implementation DownloadFileItem
- (instancetype)init {
    self = [super init];
    if (self) {
        _progress = [NSProgress new];
        _progress.totalUnitCount = 1;
        _progress.completedUnitCount = 0;
    }
    return self;
}
@end

@implementation DownloadProgressManager

#pragma mark - Singleton Implementation

+ (instancetype)sharedManager {
    static DownloadProgressManager *sharedInstance = nil;
    static dispatch_once_t onceToken;
    
    dispatch_once(&onceToken, ^{
        sharedInstance = [[self alloc] init];
    });
    
    return sharedInstance;
}

- (instancetype)init {
    self = [super init];
    if (self) {
        _overallProgress = [NSProgress new];
        _currentStageProgress = [NSProgress new];
        _fileItems = [NSMutableArray new];
        _metadata = [NSMutableDictionary new];
        _progressQueue = dispatch_queue_create("net.kdt.pojavlauncher.progressQueue", DISPATCH_QUEUE_SERIAL);
        
        // Setup notification timer - batch notifications for better UI performance
        _notificationTimer = [NSTimer scheduledTimerWithTimeInterval:0.2 
                                                              target:self 
                                                            selector:@selector(processBatchedNotifications) 
                                                            userInfo:nil 
                                                             repeats:YES];
        [[NSRunLoop mainRunLoop] addTimer:_notificationTimer forMode:NSRunLoopCommonModes];
        
        [self reset];
    }
    return self;
}

- (void)dealloc {
    [_notificationTimer invalidate];
    _notificationTimer = nil;
}

#pragma mark - Lifecycle Methods

- (void)beginDownload:(BOOL)isModpack {
    dispatch_async(self.progressQueue, ^{
        [self reset];
        
        self.isModpackInstall = isModpack;
        self.currentStage = DownloadStagePreparation;
        self.startTime = [NSDate date];
        self.statusMessage = @"Preparing download...";
        
        self.needsNotification = YES;
        
        // Post notification on main thread
        [self postNotificationWithName:DMDownloadStageChangedNotification];
    });
}

- (void)advanceToStage:(DownloadStage)stage withTotalItems:(NSInteger)totalItems {
    dispatch_async(self.progressQueue, ^{
        // Skip if we're already in completed or error states
        if (self.isComplete || self.isError) return;
        
        // Update state
        DownloadStage oldStage = self.currentStage;
        self.currentStage = stage;
        
        // Reset stage progress
        self.currentStageProgress.totalUnitCount = MAX(1, totalItems);
        self.currentStageProgress.completedUnitCount = 0;
        
        // Update status message based on stage
        switch (stage) {
            case DownloadStagePreparation:
                self.statusMessage = @"Preparing download...";
                break;
            case DownloadStageMetadata:
                self.statusMessage = @"Downloading metadata...";
                break;
            case DownloadStageLibraries:
                self.statusMessage = @"Downloading libraries...";
                break;
            case DownloadStageAssets:
                self.statusMessage = @"Downloading assets...";
                break;
            case DownloadStageClientJar:
                self.statusMessage = @"Downloading game files...";
                break;
            case DownloadStageExtraction:
                self.statusMessage = @"Extracting files...";
                break;
            case DownloadStageSetup:
                self.statusMessage = @"Setting up game...";
                break;
            case DownloadStageComplete:
                self.statusMessage = @"Download complete";
                [self finishDownloadWithSuccess:YES];
                break;
            case DownloadStageError:
                self.statusMessage = @"Download failed";
                break;
        }
        
        NSLog(@"[ProgressManager] Advanced from stage %ld to %ld with %ld items", 
              (long)oldStage, (long)stage, (long)totalItems);
        
        self.needsNotification = YES;
        
        // Post notification
        [self postNotificationWithName:DMDownloadStageChangedNotification];
    });
}

- (void)completeCurrentStage {
    dispatch_async(self.progressQueue, ^{
        // Ensure stage progress is fully complete
        self.currentStageProgress.completedUnitCount = self.currentStageProgress.totalUnitCount;
        
        // If we're in the final stage, mark the entire download as complete
        if (self.currentStage == DownloadStageSetup) {
            [self finishDownloadWithSuccess:YES];
            return;
        }
        
        // Otherwise, automatically advance to the next stage
        DownloadStage nextStage = (DownloadStage)(self.currentStage + 1);
        [self advanceToStage:nextStage withTotalItems:1];
    });
}

- (void)cancelDownload {
    dispatch_async(self.progressQueue, ^{
        // Skip if already complete or error
        if (self.isComplete || self.isError) return;
        
        // Mark as cancelled
        [self.overallProgress cancel];
        [self.currentStageProgress cancel];
        
        self.isComplete = YES;
        self.endTime = [NSDate date];
        self.statusMessage = @"Download cancelled";
        
        self.needsNotification = YES;
        
        // Post notifications
        [self postNotificationWithName:DMProgressUpdatedNotification];
        [self postNotificationWithName:DMDownloadCompletedNotification];
    });
}

- (void)finishDownloadWithSuccess:(BOOL)success {
    dispatch_async(self.progressQueue, ^{
        // Skip if already complete or error
        if (self.isComplete || self.isError) return;
        
        self.isComplete = YES;
        self.endTime = [NSDate date];
        
        // Mark all progress objects as complete
        self.overallProgress.completedUnitCount = self.overallProgress.totalUnitCount;
        self.currentStageProgress.completedUnitCount = self.currentStageProgress.totalUnitCount;
        
        if (success) {
            self.currentStage = DownloadStageComplete;
            self.statusMessage = @"Download complete";
        } else {
            self.currentStage = DownloadStageError;
            self.statusMessage = self.errorMessage ?: @"Download failed";
        }
        
        NSLog(@"[ProgressManager] Download finished with success: %@", success ? @"YES" : @"NO");
        
        self.needsNotification = YES;
        
        // Post notifications
        [self postNotificationWithName:DMProgressUpdatedNotification];
        [self postNotificationWithName:DMDownloadCompletedNotification];
    });
}

- (void)failWithError:(NSString *)errorMessage {
    dispatch_async(self.progressQueue, ^{
        // Skip if already complete or error
        if (self.isComplete || self.isError) return;
        
        self.isError = YES;
        self.errorMessage = errorMessage;
        self.currentStage = DownloadStageError;
        self.endTime = [NSDate date];
        self.statusMessage = [NSString stringWithFormat:@"Error: %@", errorMessage];
        
        NSLog(@"[ProgressManager] Download failed with error: %@", errorMessage);
        
        self.needsNotification = YES;
        
        // Post notifications
        [self postNotificationWithName:DMProgressUpdatedNotification];
        [self postNotificationWithName:DMDownloadCompletedNotification];
    });
}

- (void)reset {
    dispatch_async(self.progressQueue, ^{
        self.currentStage = DownloadStagePreparation;
        
        [self.fileItems removeAllObjects];
        [self.metadata removeAllObjects];
        
        self.overallProgress = [NSProgress new];
        self.overallProgress.totalUnitCount = 1;
        self.overallProgress.completedUnitCount = 0;
        
        self.currentStageProgress = [NSProgress new];
        self.currentStageProgress.totalUnitCount = 1;
        self.currentStageProgress.completedUnitCount = 0;
        
        self.isComplete = NO;
        self.isError = NO;
        self.errorMessage = nil;
        self.isModpackInstall = NO;
        
        self.successfulDownloads = 0;
        self.totalDownloads = 0;
        self.totalBytes = 0;
        self.completedBytes = 0;
        
        self.startTime = nil;
        self.endTime = nil;
        
        self.statusMessage = @"Ready";
        
        self.needsNotification = YES;
        [self postNotificationWithName:DMProgressUpdatedNotification];
    });
}

#pragma mark - File Tracking Methods

- (DownloadFileItem *)addFileWithPath:(NSString *)path displayName:(NSString *)displayName size:(NSUInteger)size {
    __block DownloadFileItem *fileItem = nil;
    
    dispatch_sync(self.progressQueue, ^{
        // First check if this file is already tracked
        for (DownloadFileItem *item in self.fileItems) {
            if ([item.path isEqualToString:path]) {
                fileItem = item;
                break;
            }
        }
        
        // Create new item if not found
        if (!fileItem) {
            fileItem = [DownloadFileItem new];
            fileItem.path = path;
            fileItem.displayName = displayName;
            fileItem.size = size;
            fileItem.completed = 0;
            fileItem.isComplete = NO;
            fileItem.isWaiting = YES;
            fileItem.hasError = NO;
            
            // Configure progress object
            fileItem.progress.totalUnitCount = MAX(1, size);
            fileItem.progress.completedUnitCount = 0;
            
            [self.fileItems addObject:fileItem];
            
            // Update total downloads and bytes
            self.totalDownloads++;
            self.totalBytes += size;
            
            // Update overall progress
            if (self.overallProgress.totalUnitCount == 1 && self.overallProgress.completedUnitCount == 0) {
                // This is the first file, initialize with actual size
                self.overallProgress.totalUnitCount = size;
            } else {
                // Add to existing total
                self.overallProgress.totalUnitCount += size;
            }
            
            NSLog(@"[ProgressManager] Added file: %@, size: %lu", displayName, (unsigned long)size);
            
            self.needsNotification = YES;
        }
    });
    
    return fileItem;
}

- (void)updateFile:(DownloadFileItem *)item withBytesCompleted:(NSUInteger)bytes {
    if (!item) return;
    
    dispatch_async(self.progressQueue, ^{
        // Calculate the delta to add to overall progress
        NSUInteger previousCompleted = item.completed;
        NSUInteger bytesAdded = 0;
        
        if (bytes > previousCompleted) {
            bytesAdded = bytes - previousCompleted;
            item.completed = bytes;
        }
        
        // Mark as active
        item.isWaiting = NO;
        
        // Update progress
        item.progress.completedUnitCount = MIN(bytes, item.progress.totalUnitCount);
        
        // Update overall progress
        [self updateOverallProgressWithCompletedBytes:bytesAdded];
        
        self.needsNotification = YES;
    });
}

- (void)completeFile:(DownloadFileItem *)item {
    if (!item) return;
    
    dispatch_async(self.progressQueue, ^{
        // Skip if already complete
        if (item.isComplete) return;
        
        // Mark as complete
        item.isComplete = YES;
        item.isWaiting = NO;
        
        // Calculate bytes to add to completed count
        NSUInteger bytesAdded = item.size - item.completed;
        item.completed = item.size;
        
        // Update progress
        item.progress.completedUnitCount = item.progress.totalUnitCount;
        
        // Update statistics
        self.successfulDownloads++;
        
        // Update overall progress
        [self updateOverallProgressWithCompletedBytes:bytesAdded];
        
        // Log periodic updates
        if (self.successfulDownloads % 50 == 0) {
            NSLog(@"[ProgressManager] Progress: %ld of %ld files downloaded",
                  (long)self.successfulDownloads, (long)self.totalDownloads);
        }
        
        self.needsNotification = YES;
    });
}

- (void)failFile:(DownloadFileItem *)item withError:(NSString *)errorMessage {
    if (!item) return;
    
    dispatch_async(self.progressQueue, ^{
        // Skip if already complete or failed
        if (item.isComplete || item.hasError) return;
        
        item.hasError = YES;
        item.errorMessage = errorMessage;
        item.isWaiting = NO;
        
        NSLog(@"[ProgressManager] File failed: %@, error: %@", item.displayName, errorMessage);
        
        self.needsNotification = YES;
    });
}

- (DownloadFileItem *)fileItemForPath:(NSString *)path {
    __block DownloadFileItem *result = nil;
    
    dispatch_sync(self.progressQueue, ^{
        for (DownloadFileItem *item in self.fileItems) {
            if ([item.path isEqualToString:path]) {
                result = item;
                break;
            }
        }
    });
    
    return result;
}

#pragma mark - Progress Methods

- (void)updateOverallProgressWithCompletedBytes:(NSUInteger)bytes {
    if (bytes == 0) return;
    
    self.completedBytes += bytes;
    
    // Update overall progress
    if (self.overallProgress.totalUnitCount > 0) {
        // Ensure we don't exceed the total
        NSUInteger newCompleted = self.overallProgress.completedUnitCount + bytes;
        self.overallProgress.completedUnitCount = MIN(newCompleted, self.overallProgress.totalUnitCount);
    }
    
    // Update stage progress if needed
    if (self.currentStageProgress.totalUnitCount > 0) {
        // For simplicity, use same progress calculation for stage
        double overallFraction = self.overallProgress.fractionCompleted;
        self.currentStageProgress.completedUnitCount = (NSInteger)(self.currentStageProgress.totalUnitCount * overallFraction);
    }
    
    self.needsNotification = YES;
}

- (void)updateStageProgress:(double)fractionCompleted {
    dispatch_async(self.progressQueue, ^{
        if (self.currentStageProgress.totalUnitCount > 0) {
            NSUInteger completed = (NSUInteger)(self.currentStageProgress.totalUnitCount * fractionCompleted);
            self.currentStageProgress.completedUnitCount = MIN(completed, self.currentStageProgress.totalUnitCount);
        }
        
        self.needsNotification = YES;
    });
}

- (NSString *)formattedOverallProgress {
    __block NSString *result = @"0%";
    
    dispatch_sync(self.progressQueue, ^{
        double fraction = 0.0;
        
        @try {
            fraction = self.overallProgress.fractionCompleted;
        } @catch (NSException *exception) {
            NSLog(@"[ProgressManager] Exception getting progress: %@", exception);
            fraction = 0.0;
        }
        
        int percentage = (int)(fraction * 100);
        result = [NSString stringWithFormat:@"%d%%", percentage];
    });
    
    return result;
}

- (NSString *)formattedTimeRemaining {
    __block NSString *result = @"--:--";
    
    dispatch_sync(self.progressQueue, ^{
        if (!self.startTime || self.isComplete || self.isError) {
            return;
        }
        
        NSTimeInterval elapsed = -[self.startTime timeIntervalSinceNow];
        if (elapsed <= 0) {
            return;
        }
        
        double fraction = self.overallProgress.fractionCompleted;
        if (fraction <= 0) {
            return;
        }
        
        // Calculate remaining time
        NSTimeInterval remaining = (elapsed / fraction) - elapsed;
        
        if (remaining <= 0) {
            result = @"< 1 sec";
            return;
        }
        
        // Format time remaining
        if (remaining < 60) {
            result = [NSString stringWithFormat:@"%d sec", (int)remaining];
        } else if (remaining < 3600) {
            int mins = (int)remaining / 60;
            int secs = (int)remaining % 60;
            result = [NSString stringWithFormat:@"%d:%02d", mins, secs];
        } else {
            int hours = (int)remaining / 3600;
            int mins = ((int)remaining % 3600) / 60;
            result = [NSString stringWithFormat:@"%d:%02d hr", hours, mins];
        }
    });
    
    return result;
}

- (NSString *)formattedTransferRate {
    __block NSString *result = @"-- KB/s";
    
    dispatch_sync(self.progressQueue, ^{
        if (!self.startTime || self.completedBytes == 0) {
            return;
        }
        
        NSTimeInterval elapsed = -[self.startTime timeIntervalSinceNow];
        if (elapsed <= 0) {
            return;
        }
        
        // Calculate bytes per second
        double bytesPerSecond = self.completedBytes / elapsed;
        
        // Format transfer rate
        if (bytesPerSecond < 1024) {
            result = [NSString stringWithFormat:@"%.0f B/s", bytesPerSecond];
        } else if (bytesPerSecond < 1024 * 1024) {
            result = [NSString stringWithFormat:@"%.1f KB/s", bytesPerSecond / 1024];
        } else if (bytesPerSecond < 1024 * 1024 * 1024) {
            result = [NSString stringWithFormat:@"%.1f MB/s", bytesPerSecond / (1024 * 1024)];
        } else {
            result = [NSString stringWithFormat:@"%.2f GB/s", bytesPerSecond / (1024 * 1024 * 1024)];
        }
    });
    
    return result;
}

#pragma mark - Notification Methods

- (void)processBatchedNotifications {
    // Skip if no notifications pending
    if (!self.needsNotification) {
        return;
    }
    
    dispatch_async(self.progressQueue, ^{
        self.needsNotification = NO;
        
        // Post main progress notification
        [self postNotificationWithName:DMProgressUpdatedNotification];
    });
}

- (void)postNotificationWithName:(NSString *)name {
    dispatch_async(dispatch_get_main_queue(), ^{
        [NSNotificationCenter.defaultCenter postNotificationName:name 
                                                          object:self 
                                                        userInfo:nil];
    });
}

@end

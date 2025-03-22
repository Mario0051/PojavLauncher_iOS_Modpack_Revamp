#import <dlfcn.h>
#import <objc/runtime.h>
#import "DownloadProgressViewController.h"
#import "WFWorkflowProgressView.h"
#import "utils.h"

// Define static contexts for KVO
static void *CellProgressObserverContext = &CellProgressObserverContext;
static void *TotalProgressObserverContext = &TotalProgressObserverContext;

// Task types for better UI presentation
typedef NS_ENUM(NSInteger, DownloadTaskType) {
    DownloadTaskTypeFile = 0,
    DownloadTaskTypeExtraction = 1,
    DownloadTaskTypeSetup = 2,
    DownloadTaskTypeComplete = 3
};

@interface DownloadProgressViewController ()
@property NSInteger fileListCount;
@property (nonatomic, strong) UILabel *statusLabel;
@property (nonatomic, strong) UIProgressView *overallProgressView;
@property (nonatomic, strong) NSMutableDictionary *cellProgressMap;
@property (nonatomic, strong) NSTimer *refreshTimer;
@property (nonatomic, strong) NSMutableArray *filteredFileList;
@property (nonatomic, strong) NSString *lastCompletedFile; // Track the most recently completed file
@property (nonatomic, strong) NSSet *visibleIndexPaths; // Track visible cells for targeted updates
@property (nonatomic, assign) BOOL needsFullTableReload; // Flag for tracking when full reload is needed
@end

@implementation DownloadProgressViewController

- (instancetype)initWithTask:(MinecraftResourceDownloadTask *)task {
    self = [super init];
    if (self) {
        self.task = task;
        self.cellProgressMap = [NSMutableDictionary dictionary];
        self.filteredFileList = [NSMutableArray array];
        self.lastCompletedFile = nil; // Initialize last completed file to nil
        self.visibleIndexPaths = [NSSet set]; // Initialize with empty set
        self.needsFullTableReload = NO;
        
        // Initialize download speed tracking properties
        self.lastBytesCompleted = 0;
        self.lastSpeedUpdateTime = nil;
        self.currentSpeed = 0;
        
        // Register for progress updates from MinecraftResourceDownloadTask
        [[NSNotificationCenter defaultCenter] addObserver:self
                                                 selector:@selector(downloadProgressUpdated:)
                                                     name:@"DownloadProgressUpdated"
                                                   object:nil];
    }
    return self;
}

- (void)dealloc {
    // Make sure we remove all observers when the view controller is deallocated
    [self.refreshTimer invalidate];
    self.refreshTimer = nil;
    
    // Remove update notification observer
    [[NSNotificationCenter defaultCenter] removeObserver:self
                                                    name:@"DownloadProgressUpdated"
                                                  object:nil];
    
    @try {
        [self.task.textProgress removeObserver:self forKeyPath:@"fractionCompleted"];
    } @catch (NSException *exception) {
        NSLog(@"[ProgressView] Warning: Failed to remove textProgress observer: %@", exception);
    }
    
    [self removeAllProgressObservers];
}

- (void)loadView {
    [super loadView];
    
    // Configure navigation bar
    self.navigationItem.rightBarButtonItem = [[UIBarButtonItem alloc] initWithBarButtonSystemItem:UIBarButtonSystemItemClose 
                                                                                          target:self 
                                                                                          action:@selector(actionClose)];
    
    self.navigationItem.title = @"Download Progress";
    
    // Configure table view
    self.tableView.allowsSelection = NO;
    self.tableView.separatorStyle = UITableViewCellSeparatorStyleSingleLine;
    
    // Create a custom header view for progress tracking
    UIView *headerContainer = [[UIView alloc] init];
    headerContainer.translatesAutoresizingMaskIntoConstraints = NO;
    
    // Status label - this will show just the filename
    _statusLabel = [[UILabel alloc] init];
    _statusLabel.translatesAutoresizingMaskIntoConstraints = NO;
    _statusLabel.font = [UIFont systemFontOfSize:14 weight:UIFontWeightMedium];
    _statusLabel.textColor = [UIColor labelColor];
    _statusLabel.text = @"Preparing download...";
    _statusLabel.numberOfLines = 1;
    _statusLabel.lineBreakMode = NSLineBreakByTruncatingMiddle;
    [headerContainer addSubview:_statusLabel];
    
    // Progress view
    _overallProgressView = [[UIProgressView alloc] initWithProgressViewStyle:UIProgressViewStyleDefault];
    _overallProgressView.translatesAutoresizingMaskIntoConstraints = NO;
    _overallProgressView.progress = 0.0;
    _overallProgressView.progressTintColor = [UIColor systemBlueColor];
    _overallProgressView.trackTintColor = [UIColor systemFillColor];
    _overallProgressView.layer.cornerRadius = 1.0;
    _overallProgressView.clipsToBounds = YES;
    [headerContainer addSubview:_overallProgressView];
    
    // Percentage label with space for download speed
    UILabel *percentLabel = [[UILabel alloc] init];
    percentLabel.translatesAutoresizingMaskIntoConstraints = NO;
    percentLabel.font = [UIFont systemFontOfSize:12];
    percentLabel.textColor = [UIColor secondaryLabelColor];
    percentLabel.textAlignment = NSTextAlignmentRight;
    percentLabel.text = @"0%";
    objc_setAssociatedObject(_overallProgressView, @"percentLabel", percentLabel, OBJC_ASSOCIATION_RETAIN_NONATOMIC);
    [headerContainer addSubview:percentLabel];
    
    // Separator line
    UIView *separatorLine = [[UIView alloc] init];
    separatorLine.translatesAutoresizingMaskIntoConstraints = NO;
    separatorLine.backgroundColor = [UIColor separatorColor];
    [headerContainer addSubview:separatorLine];
    
    // Constraints
    [NSLayoutConstraint activateConstraints:@[
        // Status Label
        [_statusLabel.topAnchor constraintEqualToAnchor:headerContainer.topAnchor constant:10],
        [_statusLabel.leadingAnchor constraintEqualToAnchor:headerContainer.leadingAnchor constant:16],
        [_statusLabel.trailingAnchor constraintEqualToAnchor:headerContainer.trailingAnchor constant:-16],
        
        // Progress View
        [_overallProgressView.topAnchor constraintEqualToAnchor:_statusLabel.bottomAnchor constant:8],
        [_overallProgressView.leadingAnchor constraintEqualToAnchor:headerContainer.leadingAnchor constant:16],
        [_overallProgressView.trailingAnchor constraintEqualToAnchor:headerContainer.trailingAnchor constant:-16],
        [_overallProgressView.heightAnchor constraintEqualToConstant:4],
        
        // Percentage Label - make it wider to accommodate download speed display
        [percentLabel.topAnchor constraintEqualToAnchor:_overallProgressView.bottomAnchor constant:4],
        [percentLabel.leadingAnchor constraintEqualToAnchor:headerContainer.leadingAnchor constant:16],
        [percentLabel.trailingAnchor constraintEqualToAnchor:headerContainer.trailingAnchor constant:-16],
        
        // Separator Line
        [separatorLine.heightAnchor constraintEqualToConstant:0.5],
        [separatorLine.leadingAnchor constraintEqualToAnchor:headerContainer.leadingAnchor],
        [separatorLine.trailingAnchor constraintEqualToAnchor:headerContainer.trailingAnchor],
        [separatorLine.bottomAnchor constraintEqualToAnchor:headerContainer.bottomAnchor],
        
        // Ensure the header has a specific height
        [headerContainer.heightAnchor constraintEqualToConstant:100]
    ]];
    
    // Create a container view to wrap the header with proper sizing
    UIView *headerWrapperView = [[UIView alloc] initWithFrame:CGRectMake(0, 0, self.tableView.bounds.size.width, 100)];
    [headerWrapperView addSubview:headerContainer];
    
    // Constraints for header container
    [NSLayoutConstraint activateConstraints:@[
        [headerContainer.topAnchor constraintEqualToAnchor:headerWrapperView.topAnchor],
        [headerContainer.leadingAnchor constraintEqualToAnchor:headerWrapperView.leadingAnchor],
        [headerContainer.trailingAnchor constraintEqualToAnchor:headerWrapperView.trailingAnchor],
        [headerContainer.bottomAnchor constraintEqualToAnchor:headerWrapperView.bottomAnchor]
    ]];
    
    // Set the table header view
    self.tableView.tableHeaderView = headerWrapperView;
    
    // Initialize filtered file list
    [self updateFilteredFileList];
}

- (void)viewDidAppear:(BOOL)animated {
    [super viewDidAppear:animated];
    
    // Start observing overall progress - observe textProgress for smoother updates
    if (self.task.textProgress) {
        [self.task.textProgress addObserver:self
                forKeyPath:@"fractionCompleted"
                options:NSKeyValueObservingOptionInitial
                context:TotalProgressObserverContext];
                
        // Update overall progress view with current progress
        self.overallProgressView.observedProgress = self.task.textProgress;
    }
    
    // Reset speed tracking values when view appears
    self.lastBytesCompleted = self.task.progress.completedUnitCount;
    self.lastSpeedUpdateTime = [NSDate date];
    self.currentSpeed = 0;
    
    // Setup a refresh timer to periodically update the UI at a controlled rate
    // This helps with smoother updates when individual operations are taking a long time
    self.refreshTimer = [NSTimer scheduledTimerWithTimeInterval:0.5 
                                                       target:self 
                                                     selector:@selector(refreshProgressUI) 
                                                     userInfo:nil 
                                                      repeats:YES];
    
    // Run the timer on a common mode to ensure updates when scrolling
    [[NSRunLoop currentRunLoop] addTimer:self.refreshTimer forMode:NSRunLoopCommonModes];
}

- (void)viewDidDisappear:(BOOL)animated {
    [super viewDidDisappear:animated];
    
    // Stop observing progress
    @try {
        [self.task.textProgress removeObserver:self forKeyPath:@"fractionCompleted"];
    } @catch (NSException *exception) {
        NSLog(@"[ProgressView] Warning: Failed to remove textProgress observer: %@", exception);
    }
    
    // Invalidate refresh timer
    [self.refreshTimer invalidate];
    self.refreshTimer = nil;
    
    // Remove all observers from cell progress
    [self removeAllProgressObservers];
    
    // Clear observed progress to avoid dangling references
    self.overallProgressView.observedProgress = nil;
}

- (void)downloadProgressUpdated:(NSNotification *)notification {
    // Schedule a UI refresh on next timer cycle
    self.needsFullTableReload = YES;
}

- (void)updateFilteredFileList {
    // Clear previous filtered list
    [self.filteredFileList removeAllObjects];
    
    // Defensive copy to prevent mutations during enumeration
    NSArray *fileListCopy = nil;
    @synchronized(self.task.fileList) {
        fileListCopy = [NSArray arrayWithArray:self.task.fileList];
    }
    
    // Create a dictionary to track files by their base name
    NSMutableDictionary *fileMap = [NSMutableDictionary dictionary];
    
    // First pass: group files by base name and track process entries
    NSMutableArray *processEntries = [NSMutableArray array];
    
    for (NSString *filePath in fileListCopy) {
        // Skip nil entries to avoid crashes
        if (!filePath) continue;
        
        // Track extraction and setup entries separately
        if ([filePath hasPrefix:@"Extracting"] || 
            [filePath hasPrefix:@"Setting"] || 
            [filePath hasPrefix:@"Installing"]) {
            [processEntries addObject:filePath];
            continue;
        }
        
        // Include completion indicator
        if ([filePath isEqualToString:@"Complete"]) {
            [self.filteredFileList addObject:filePath];
            continue;
        }
        
        // Get just the file name without path - safely
        NSString *fileName = [filePath lastPathComponent];
        if (!fileName) fileName = filePath; // Fallback if lastPathComponent fails
        
        // Store this path for this file name, preferring longer paths with directory structure
        if (!fileMap[fileName] || [filePath length] > [fileMap[fileName] length]) {
            fileMap[fileName] = filePath;
        }
    }
    
    // Add all processing entries to the filtered list first
    [self.filteredFileList addObjectsFromArray:processEntries];
    
    // Add all unique paths to the filtered list
    NSArray *uniquePaths = [fileMap allValues];
    for (NSString *uniquePath in uniquePaths) {
        // Skip nil entries to avoid crashes
        if (!uniquePath) continue;
        [self.filteredFileList addObject:uniquePath];
    }
    
    // Sort the filtered list for consistent display
    [self.filteredFileList sortUsingComparator:^NSComparisonResult(NSString *path1, NSString *path2) {
        // Handle nil values to prevent crashes
        if (!path1) return NSOrderedDescending;
        if (!path2) return NSOrderedAscending;
        
        // Processing entries (Extracting, Setting, Installing) come first
        BOOL isProcess1 = [path1 hasPrefix:@"Extracting"] || 
                          [path1 hasPrefix:@"Setting"] || 
                          [path1 hasPrefix:@"Installing"];
        BOOL isProcess2 = [path2 hasPrefix:@"Extracting"] || 
                          [path2 hasPrefix:@"Setting"] || 
                          [path2 hasPrefix:@"Installing"];
                          
        if (isProcess1 && !isProcess2) {
            return NSOrderedAscending;
        } else if (!isProcess1 && isProcess2) {
            return NSOrderedDescending;
        } else if (isProcess1 && isProcess2) {
            return [path1 compare:path2]; // Sort processing entries among themselves
        }
        
        // Keep the Complete entry at the end
        if ([path1 isEqualToString:@"Complete"]) {
            return NSOrderedDescending;
        } else if ([path2 isEqualToString:@"Complete"]) {
            return NSOrderedAscending;
        }
        
        // For regular files, sort alphabetically
        return [path1 compare:path2];
    }];
}


- (void)refreshProgressUI {
    // Static variables for maintaining speed display between calls
    static double lastNonZeroSpeed = 0;
    static BOOL hasStartedDownloading = NO;
    
    // Update overall progress for the header
    if (self.task.progress && self.task.progress.totalUnitCount > 0) {
        dispatch_async(dispatch_get_main_queue(), ^{
            // Calculate download speed
            NSDate *now = [NSDate date];
            
            if (self.lastSpeedUpdateTime) {
                // Get the time interval since the last update
                NSTimeInterval interval = [now timeIntervalSinceDate:self.lastSpeedUpdateTime];
                
                if (interval >= 0.5) { // Only update speed every 0.5 seconds to avoid fluctuations
                    int64_t currentBytesCompleted = self.task.progress.completedUnitCount;
                    int64_t bytesDownloadedSinceLastUpdate = currentBytesCompleted - self.lastBytesCompleted;
                    
                    // Only update if we've actually downloaded something
                    if (bytesDownloadedSinceLastUpdate > 0) {
                        // Calculate speed in bytes per second
                        self.currentSpeed = (double)bytesDownloadedSinceLastUpdate / interval;
                        
                        // Store current values for next calculation
                        self.lastBytesCompleted = currentBytesCompleted;
                        self.lastSpeedUpdateTime = now;
                    }
                }
            } else {
                // First time updating, initialize tracking values
                self.lastBytesCompleted = self.task.progress.completedUnitCount;
                self.lastSpeedUpdateTime = now;
                self.currentSpeed = 0;
            }
            
            // Update overall progress with stable value
            float fraction = self.task.progress.fractionCompleted;
            self.overallProgressView.progress = fraction;
            
            // Format download speed - always show speed once we've started downloading
            NSString *speedText = @"";
            
            // Keep showing speed even when current value is 0 (for slow periods)
            if (self.currentSpeed > 0) {
                // Save the last non-zero speed
                lastNonZeroSpeed = self.currentSpeed;
                hasStartedDownloading = YES;
            }
            
            // Format either current speed or last known non-zero speed
            double speedToDisplay = (self.currentSpeed > 0) ? self.currentSpeed : lastNonZeroSpeed;
            
            if (hasStartedDownloading) {
                if (speedToDisplay < 1024) {
                    speedText = [NSString stringWithFormat:@" - %.0f B/s", speedToDisplay];
                } else if (speedToDisplay < 1024 * 1024) {
                    speedText = [NSString stringWithFormat:@" - %.1f KB/s", speedToDisplay / 1024.0];
                } else {
                    speedText = [NSString stringWithFormat:@" - %.2f MB/s", speedToDisplay / (1024.0 * 1024.0)];
                }
            }
            
            // Update percentage label with speed
            UILabel *percentLabel = objc_getAssociatedObject(self.overallProgressView, @"percentLabel");
            int percentage = (int)(fraction * 100);
            
            // Store last percentage to avoid unnecessary updates
            static int lastDisplayedPercentage = -1;
            // Always update if percentage changed or if we need to show/update speed
            if (percentage != lastDisplayedPercentage || hasStartedDownloading) {
                lastDisplayedPercentage = percentage;
                percentLabel.text = [NSString stringWithFormat:@"%d%%%@", percentage, speedText];
            }
        });
    }
    
    // Check if we need a full table reload
    if (self.needsFullTableReload) {
        // Update the filtered file list
        [self updateFilteredFileList];
        
        // Check for any new items that were added first
        if (self.fileListCount != self.filteredFileList.count) {
            self.fileListCount = self.filteredFileList.count;
            [self reloadTableViewPreservingOffset];
            self.needsFullTableReload = NO;
            return; // Don't proceed with other updates in the same refresh cycle
        }
        
        // Update visible cells instead of reloading entire table
        [self updateVisibleCells];
        self.needsFullTableReload = NO;
    }
    
    // Update status label with most recently completed file
    if (self.lastCompletedFile) {
        self.statusLabel.text = self.lastCompletedFile;
    } else if (self.filteredFileList.count > 0) {
        // Show the name of the current file at the top of the list if no completed file
        // Only if it's not an extraction notification
        NSString *currentFile = self.filteredFileList[0];
        if (![currentFile hasPrefix:@"Extracting"] && 
            ![currentFile hasPrefix:@"Setting"]) {
            self.statusLabel.text = currentFile;
        } else {
            self.statusLabel.text = @"Processing...";
        }
    } else {
        self.statusLabel.text = @"Preparing download...";
    }
    
    // Check for completion
    BOOL isComplete = NO;
    
    // Check if allTasksComplete flag is set
    if (self.task.metadata[@"allTasksComplete"]) {
        isComplete = [self.task.metadata[@"allTasksComplete"] boolValue];
    }
    
    // Also check if progress is complete
    if (self.task.progress.fractionCompleted >= 1.0 || self.task.progress.finished) {
        isComplete = YES;
        
        // If complete, reset the download speed tracking
        hasStartedDownloading = NO;
        lastNonZeroSpeed = 0;
    }
    
    // If complete, ensure UI reflects this
    if (isComplete && ![self.filteredFileList containsObject:@"Complete"] && ![self.task.fileList containsObject:@"Complete"]) {
        // Add completion marker if needed
        [self.task.fileList addObject:@"Complete"];
        [self.filteredFileList addObject:@"Complete"];
        
        // Create completion progress
        NSProgress *completeProgress = [NSProgress progressWithTotalUnitCount:1];
        completeProgress.completedUnitCount = 1;
        [self.task.progressList addObject:completeProgress];
        [self.task.progress addChild:completeProgress withPendingUnitCount:1];
        
        [self reloadTableViewPreservingOffset];
        
        // Update status label for completion
        self.statusLabel.text = @"Download complete";
    }
}

- (void)reloadTableViewPreservingOffset {
    // Save current scroll position
    CGPoint contentOffset = self.tableView.contentOffset;
    
    // Reload data
    [self.tableView reloadData];
    
    // Restore scroll position
    [self.tableView setContentOffset:contentOffset animated:NO];
}

// Helper method to update only visible cells to prevent flickering
- (void)updateVisibleCells {
    // Capture which cells are currently visible
    NSArray *visiblePaths = [self.tableView indexPathsForVisibleRows];
    if (!visiblePaths) return;
    
    self.visibleIndexPaths = [NSSet setWithArray:visiblePaths];
    
    for (NSIndexPath *indexPath in visiblePaths) {
        if (indexPath.row < self.filteredFileList.count) {
            UITableViewCell *cell = [self.tableView cellForRowAtIndexPath:indexPath];
            if (!cell) continue;
            
            NSString *fileName = self.filteredFileList[indexPath.row];
            
            // Get the original index for this file name
            NSUInteger originalIndex = NSNotFound;
            
            @synchronized(self.task.fileList) {
                originalIndex = [self.task.fileList indexOfObject:fileName];
            }
            
            if (originalIndex != NSNotFound) {
                // Make sure the progress list index is valid
                NSProgress *progress = nil;
                
                @synchronized(self.task.progressList) {
                    BOOL isValidIndex = originalIndex < self.task.progressList.count;
                    if (isValidIndex) {
                        progress = self.task.progressList[originalIndex];
                    }
                }
                
                if (progress) {
                    [self updateCell:cell withProgress:progress forIndexPath:indexPath];
                }
            }
        }
    }
}

// Helper method to update a cell with the latest progress
- (void)updateCell:(UITableViewCell *)cell withProgress:(NSProgress *)progress forIndexPath:(NSIndexPath *)indexPath {
    if (!cell || !progress || indexPath.row >= self.filteredFileList.count) {
        return;
    }
    
    NSString *fileName = self.filteredFileList[indexPath.row];
    DownloadTaskType taskType = DownloadTaskTypeFile;
    
    if ([fileName hasPrefix:@"Extracting"]) {
        taskType = DownloadTaskTypeExtraction;
    } else if ([fileName hasPrefix:@"Setting"]) {
        taskType = DownloadTaskTypeSetup;
    } else if ([fileName isEqualToString:@"Complete"]) {
        taskType = DownloadTaskTypeComplete;
    }
    
    // Calculate completion percentage safely
    float fractionCompleted = 0.0;
    BOOL isComplete = NO;
    
    @try {
        fractionCompleted = progress.fractionCompleted;
        isComplete = progress.finished || fractionCompleted >= 1.0;
        
        // Ensure value is valid
        if (isnan(fractionCompleted)) fractionCompleted = 0.0;
        if (fractionCompleted < 0.0) fractionCompleted = 0.0;
        if (fractionCompleted > 1.0) fractionCompleted = 1.0;
    } @catch (NSException *exception) {
        NSLog(@"[ProgressView] Warning: Exception getting progress value: %@", exception);
        fractionCompleted = 0.0;
        isComplete = NO;
    }
    
    // Format size as MB/MB for file downloads
    NSString *sizeText;
    if (taskType == DownloadTaskTypeFile && progress.totalUnitCount > 0) {
        double completedBytes = progress.completedUnitCount;
        double totalBytes = progress.totalUnitCount;
        
        // Detect if progress might have a placeholder value
        BOOL isPlaceholder = (totalBytes == 1 || totalBytes == 1000000) && completedBytes > totalBytes;
        
        if (isPlaceholder) {
            // For placeholder values, just show percentage
            int percentage = (int)((completedBytes / (completedBytes + 1000000)) * 100);
            sizeText = [NSString stringWithFormat:@"Downloading... %d%%", percentage];
        } else {
            // Normal formatting with real size data
            double completedMB = completedBytes / 1024.0 / 1024.0;
            double totalMB = totalBytes / 1024.0 / 1024.0;
            
            // Format with appropriate precision based on size
            if (totalMB < 1.0) {
                // Use KB for small files
                double completedKB = completedBytes / 1024.0;
                double totalKB = totalBytes / 1024.0;
                sizeText = [NSString stringWithFormat:@"%.0fKB/%.0fKB", completedKB, totalKB];
            } else if (totalMB < 10.0) {
                // More precision for smaller files
                sizeText = [NSString stringWithFormat:@"%.2fMB/%.2fMB", completedMB, totalMB];
            } else if (totalMB < 100.0) {
                sizeText = [NSString stringWithFormat:@"%.1fMB/%.1fMB", completedMB, totalMB];
            } else {
                sizeText = [NSString stringWithFormat:@"%.0fMB/%.0fMB", completedMB, totalMB];
            }
        }
    } else if (taskType == DownloadTaskTypeExtraction) {
        // Show extraction progress percentage
        int percentage = (int)(fractionCompleted * 100);
        sizeText = [NSString stringWithFormat:@"Extracting... %d%%", percentage];
    } else if (taskType == DownloadTaskTypeSetup) {
        // Show setup progress percentage
        int percentage = (int)(fractionCompleted * 100);
        sizeText = [NSString stringWithFormat:@"Setting up... %d%%", percentage];
    } else if (taskType == DownloadTaskTypeComplete) {
        sizeText = @"Complete!";
        isComplete = YES;
    } else {
        sizeText = progress.totalUnitCount > 0 ? 
                  @"Waiting..." : 
                  [NSString stringWithFormat:@"%d%%", (int)(fractionCompleted * 100)];
    }
    
    // Update detail text
    cell.detailTextLabel.text = sizeText;
    
    // For the accessory view, check if download is complete
    if (isComplete || taskType == DownloadTaskTypeComplete) {
        // Only update if the current accessory view is not already a checkmark
        if (![cell.accessoryView isKindOfClass:[UIImageView class]]) {
            UIImageView *checkmarkView = [[UIImageView alloc] initWithFrame:CGRectMake(0, 0, 30, 30)];
            UIImage *checkmarkImage = [UIImage systemImageNamed:@"checkmark.circle.fill"];
            checkmarkView.image = checkmarkImage;
            checkmarkView.tintColor = [UIColor systemGreenColor];
            cell.accessoryView = checkmarkView;
            
            if (taskType == DownloadTaskTypeFile) {
                cell.detailTextLabel.text = @"Complete";
                // Update the last completed file when a file is completed
                self.lastCompletedFile = fileName;
                // Update the status label immediately
                dispatch_async(dispatch_get_main_queue(), ^{
                    self.statusLabel.text = fileName;
                });
            }
        }
    } else if (taskType == DownloadTaskTypeExtraction || taskType == DownloadTaskTypeSetup) {
        // Show activity indicator for extraction and setup
        if (![cell.accessoryView isKindOfClass:[UIActivityIndicatorView class]]) {
            UIActivityIndicatorView *activityIndicator = [[UIActivityIndicatorView alloc] initWithActivityIndicatorStyle:UIActivityIndicatorViewStyleMedium];
            [activityIndicator startAnimating];
            cell.accessoryView = activityIndicator;
        }
    } else {
        // Ensure progress label is updated for downloads
        UILabel *progressLabel = (UILabel *)cell.accessoryView;
        if (![progressLabel isKindOfClass:[UILabel class]]) {
            progressLabel = [[UILabel alloc] initWithFrame:CGRectMake(0, 0, 80, 30)];
            progressLabel.textAlignment = NSTextAlignmentRight;
            progressLabel.font = [UIFont systemFontOfSize:14];
            cell.accessoryView = progressLabel;
        }
        
        // Associate a stored percentage value with the cell to avoid flickering
        NSNumber *storedPercent = objc_getAssociatedObject(cell, @"lastPercentage");
        int lastPercent = storedPercent ? [storedPercent intValue] : -1;
        
        // Check if we have valid progress information
        if (progress.totalUnitCount > 0 && progress.completedUnitCount <= progress.totalUnitCount) {
            int percentage = (int)(fractionCompleted * 100);
            
            // Only update the percentage text if it has changed by at least 1%
            if (lastPercent != percentage) {
                progressLabel.text = [NSString stringWithFormat:@"%d%%", percentage];
                objc_setAssociatedObject(cell, @"lastPercentage", @(percentage), OBJC_ASSOCIATION_RETAIN_NONATOMIC);
            }
        } else if (progress.completedUnitCount > 0) {
            // Handle the case where completedUnitCount > totalUnitCount (placeholder value case)
            int estimatedPercentage = (int)((progress.completedUnitCount / (progress.completedUnitCount + 1000000)) * 100);
            
            // Only update if percentage has changed
            if (lastPercent != estimatedPercentage) {
                progressLabel.text = [NSString stringWithFormat:@"~%d%%", estimatedPercentage];
                objc_setAssociatedObject(cell, @"lastPercentage", @(estimatedPercentage), OBJC_ASSOCIATION_RETAIN_NONATOMIC);
            }
        } else if (lastPercent != 0) {
            progressLabel.text = @"0%";
            objc_setAssociatedObject(cell, @"lastPercentage", @(0), OBJC_ASSOCIATION_RETAIN_NONATOMIC);
        }
    }
}

- (void)actionClose {
    // Ask for confirmation if download is in progress
    if (self.task.progress.fractionCompleted < 1.0 && !self.task.progress.cancelled) {
        UIAlertController *alert = [UIAlertController alertControllerWithTitle:@"Cancel Download"
                                                                       message:@"Are you sure you want to cancel the current download?"
                                                                preferredStyle:UIAlertControllerStyleAlert];
        
        [alert addAction:[UIAlertAction actionWithTitle:@"Yes" style:UIAlertActionStyleDestructive handler:^(UIAlertAction * _Nonnull action) {
            [self.task.progress cancel];
            [self.navigationController dismissViewControllerAnimated:YES completion:nil];
        }]];
        
        [alert addAction:[UIAlertAction actionWithTitle:@"No" style:UIAlertActionStyleCancel handler:nil]];
        
        [self presentViewController:alert animated:YES completion:nil];
    } else {
        [self.navigationController dismissViewControllerAnimated:YES completion:nil];
    }
}

- (void)removeAllProgressObservers {
    // Clean up KVO observers to prevent leaks
    @synchronized(self) {
        // Make a defensive copy of keys to avoid mutation while enumerating
        NSArray *keys = [self.cellProgressMap allKeys];
        for (id key in keys) {
            NSProgress *progress = [self.cellProgressMap objectForKey:key];
            [self removeProgressObserver:progress];
        }
        [self.cellProgressMap removeAllObjects];
    }
}

- (void)removeProgressObserver:(NSProgress *)progress {
    if (!progress) return;
    
    @synchronized(self) {
        @try {
            [progress removeObserver:self forKeyPath:@"fractionCompleted"];
        } @catch (NSException *exception) {
            // Ignore if not observing
            NSLog(@"[ProgressView] Warning: Failed to remove observer: %@", exception);
        }
        
        // Also clear the association to avoid dangling references
        objc_setAssociatedObject(progress, @"cell", nil, OBJC_ASSOCIATION_ASSIGN);
    }
}

- (void)observeValueForKeyPath:(NSString *)keyPath ofObject:(id)object change:(NSDictionary *)change context:(void *)context {
    NSProgress *progress = object;
    
    if (context == CellProgressObserverContext) {
        UITableViewCell *cell = objc_getAssociatedObject(progress, @"cell");
        if (!cell) return;
        
        // Cap updates to avoid UI thrashing
        static NSTimeInterval lastCellUpdate = 0;
        NSTimeInterval now = [NSDate timeIntervalSinceReferenceDate];
        if (now - lastCellUpdate < 0.1) {
            // Throttle updates to max 10 per second
            return;
        }
        lastCellUpdate = now;
        
        // Handle cell progress updates on main thread
        dispatch_async(dispatch_get_main_queue(), ^{
            // Check if view controller is still active - guard against accessing deallocated objects
            if (!self.view.window) return;
            
            // Find the original file name for this progress
            NSUInteger originalIndex = NSNotFound;
            
            @synchronized(self.task.progressList) {
                originalIndex = [self.task.progressList indexOfObject:progress];
            }
            
            if (originalIndex != NSNotFound) {
                // Get the file name safely
                NSString *originalFileName = nil;
                
                @synchronized(self.task.fileList) {
                    if (originalIndex < self.task.fileList.count) {
                        originalFileName = self.task.fileList[originalIndex];
                    }
                }
                
                if (!originalFileName) return;
                
                // Find this file in our filtered list
                NSUInteger filteredIndex = [self.filteredFileList indexOfObject:originalFileName];
                
                // If not found directly, check if this file might be represented by another path
                if (filteredIndex == NSNotFound) {
                    NSString *baseName = [originalFileName lastPathComponent];
                    for (NSUInteger i = 0; i < self.filteredFileList.count; i++) {
                        NSString *currentPath = self.filteredFileList[i];
                        if ([[currentPath lastPathComponent] isEqualToString:baseName]) {
                            filteredIndex = i;
                            break;
                        }
                    }
                }
                
                // Only update if we found the file in our filtered list and the cell is visible
                if (filteredIndex != NSNotFound) {
                    NSIndexPath *indexPath = [NSIndexPath indexPathForRow:filteredIndex inSection:0];
                    if ([self.visibleIndexPaths containsObject:indexPath]) {
                        UITableViewCell *visibleCell = [self.tableView cellForRowAtIndexPath:indexPath];
                        if (visibleCell) {
                            [self updateCell:visibleCell withProgress:progress forIndexPath:indexPath];
                        }
                    }
                }
            }
        });
    } else if (context == TotalProgressObserverContext) {
        // Cap update rate and store last values to prevent flickering
        static NSTimeInterval lastHeaderUpdate = 0;
        static int64_t lastCompletedBytes = 0;
        static int lastPercentage = -1;
        
        NSTimeInterval now = [NSDate timeIntervalSinceReferenceDate];
        if (now - lastHeaderUpdate < 0.2) {
            // Throttle updates to max 5 per second for header
            return;
        }
        
        // Get current values before update to prevent race conditions
        int64_t currentCompletedBytes = 0;
        int currentPercentage = 0;
        
        @try {
            currentCompletedBytes = progress.completedUnitCount;
            currentPercentage = (int)(progress.fractionCompleted * 100);
            
            // Ensure percentage is valid
            if (currentPercentage < 0) currentPercentage = 0;
            if (currentPercentage > 100) currentPercentage = 100;
        } @catch (NSException *exception) {
            NSLog(@"[ProgressView] Warning: Exception getting progress values: %@", exception);
            return;
        }
        
        // Only update if there is a meaningful change
        if (currentCompletedBytes != lastCompletedBytes || currentPercentage != lastPercentage) {
            lastHeaderUpdate = now;
            lastCompletedBytes = currentCompletedBytes;
            lastPercentage = currentPercentage;
            
            dispatch_async(dispatch_get_main_queue(), ^{
                // Check if view controller is still active - guard against accessing deallocated objects
                if (!self.view.window) return;
                
                // Update percentage label
                UILabel *percentLabel = objc_getAssociatedObject(self.overallProgressView, @"percentLabel");
                if (percentLabel) {
                    percentLabel.text = [NSString stringWithFormat:@"%d%%", currentPercentage];
                }
                
                // Signal need for a filtered list update
                self.needsFullTableReload = YES;
                
                // Check for completion
                BOOL isComplete = NO;
                @try {
                    isComplete = progress.fractionCompleted >= 1.0 || progress.finished;
                } @catch (NSException *exception) {
                    NSLog(@"[ProgressView] Warning: Exception checking completion: %@", exception);
                    isComplete = NO;
                }
                
                if (isComplete) {
                    // Add a completion message if needed - without reloading table if possible
                    BOOL completionEntryPresent = [self.filteredFileList containsObject:@"Complete"];
                    BOOL taskHasCompleteEntry = NO;
                    
                    @synchronized(self.task.fileList) {
                        taskHasCompleteEntry = [self.task.fileList containsObject:@"Complete"];
                    }
                    
                    if (!completionEntryPresent && !taskHasCompleteEntry) {
                        @synchronized(self.task.fileList) {
                            [self.task.fileList addObject:@"Complete"];
                        }
                        
                        // Add a completion progress
                        NSProgress *completeProgress = [NSProgress progressWithTotalUnitCount:1];
                        completeProgress.completedUnitCount = 1;
                        
                        @synchronized(self.task.progressList) {
                            [self.task.progressList addObject:completeProgress];
                        }
                        
                        [self updateFilteredFileList]; // This will add Complete to filteredFileList
                        [self reloadTableViewPreservingOffset];
                    }
                    
                    // Update status text
                    self.statusLabel.text = @"Download complete";
                }
            });
        }
    } else {
        [super observeValueForKeyPath:keyPath ofObject:object change:change context:context];
    }
}

#pragma mark - UIScrollViewDelegate

// Override to track visible cells whenever scroll position changes
- (void)scrollViewDidScroll:(UIScrollView *)scrollView {
    // Update visible index paths on scroll
    NSArray *visiblePaths = [self.tableView indexPathsForVisibleRows];
    self.visibleIndexPaths = [NSSet setWithArray:visiblePaths];
}

#pragma mark - Table View Data Source

- (NSInteger)tableView:(UITableView *)tableView numberOfRowsInSection:(NSInteger)section {
    return self.filteredFileList.count;
}

- (UITableViewCell *)tableView:(UITableView *)tableView cellForRowAtIndexPath:(NSIndexPath *)indexPath {
    static NSString *cellId = @"cell";
    UITableViewCell *cell = [tableView dequeueReusableCellWithIdentifier:cellId];

    if (cell == nil) {
        cell = [[UITableViewCell alloc] initWithStyle:UITableViewCellStyleSubtitle reuseIdentifier:cellId];
        cell.textLabel.font = [UIFont systemFontOfSize:14];
        cell.detailTextLabel.font = [UIFont systemFontOfSize:12];
        cell.detailTextLabel.textColor = [UIColor secondaryLabelColor];
        
        // Create progress label
        UILabel *progressLabel = [[UILabel alloc] initWithFrame:CGRectMake(0, 0, 80, 30)];
        progressLabel.textAlignment = NSTextAlignmentRight;
        progressLabel.font = [UIFont systemFontOfSize:14];
        progressLabel.text = @"0%";
        cell.accessoryView = progressLabel;
    }

    // Get the file name from filtered list
    NSString *fileName = self.filteredFileList[indexPath.row];
    
    // Set cell text to just the filename (not the full path)
    cell.textLabel.text = [fileName lastPathComponent];
    
    // Remove any previous associations when cell is reused
    NSProgress *oldProgress = objc_getAssociatedObject(cell, @"progress");
    if (oldProgress) {
        // Remove the association from the progress to the cell
        objc_setAssociatedObject(oldProgress, @"cell", nil, OBJC_ASSOCIATION_ASSIGN);
        
        // Also make sure we're not observing this progress anymore
        [self removeProgressObserver:oldProgress];
    }
    
    // Get the index of this file in the original list
    NSUInteger originalIndex = [self.task.fileList indexOfObject:fileName];
    
    // Get the NSProgress object for this cell
    NSProgress *progress = nil;
    
    // Generate a unique identifier for this cell
    NSString *identifier = [NSString stringWithFormat:@"cell_%ld", (long)indexPath.row];
    
    // Try to get existing progress from our map
    progress = [self.cellProgressMap objectForKey:identifier];
    
    // If no existing progress, check if available from task
    if (!progress && originalIndex != NSNotFound && originalIndex < self.task.progressList.count) {
        progress = self.task.progressList[originalIndex];
        
        if (progress) {
            // Store in our map to track observation
            [self.cellProgressMap setObject:progress forKey:identifier];
            
            // Set up relationship between cell and progress
            objc_setAssociatedObject(cell, @"progress", progress, OBJC_ASSOCIATION_ASSIGN);
            // Use ASSIGN instead of RETAIN to avoid the progress retaining the cell
            objc_setAssociatedObject(progress, @"cell", cell, OBJC_ASSOCIATION_ASSIGN);
            
            // Avoid re-observing if already observing
            @try {
                [progress removeObserver:self forKeyPath:@"fractionCompleted"];
            } @catch (NSException *exception) {
                // Ignore if not already observing
            }
            
            // Start observing with reduced frequency
            @try {
                [progress addObserver:self
                           forKeyPath:@"fractionCompleted"
                              options:NSKeyValueObservingOptionInitial
                              context:CellProgressObserverContext];
            } @catch (NSException *exception) {
                NSLog(@"[ProgressView] Warning: Failed to add observer: %@", exception);
            }
        }
    } else if (progress) {
        // Maintain the association with the current cell
        objc_setAssociatedObject(cell, @"progress", progress, OBJC_ASSOCIATION_ASSIGN);
        objc_setAssociatedObject(progress, @"cell", cell, OBJC_ASSOCIATION_ASSIGN);
    }
    
    // Update the cell with the latest progress information
    if (progress) {
        [self updateCell:cell withProgress:progress forIndexPath:indexPath];
    } else {
        // Default state for cells without progress data
        DownloadTaskType taskType = DownloadTaskTypeFile;
        
        if ([fileName hasPrefix:@"Extracting"]) {
            taskType = DownloadTaskTypeExtraction;
            cell.detailTextLabel.text = @"Extracting...";
            
            UIActivityIndicatorView *activityIndicator = [[UIActivityIndicatorView alloc] initWithActivityIndicatorStyle:UIActivityIndicatorViewStyleMedium];
            [activityIndicator startAnimating];
            cell.accessoryView = activityIndicator;
        } else if ([fileName hasPrefix:@"Setting"]) {
            taskType = DownloadTaskTypeSetup;
            cell.detailTextLabel.text = @"Setting up...";
            
            UIActivityIndicatorView *activityIndicator = [[UIActivityIndicatorView alloc] initWithActivityIndicatorStyle:UIActivityIndicatorViewStyleMedium];
            [activityIndicator startAnimating];
            cell.accessoryView = activityIndicator;
        } else if ([fileName isEqualToString:@"Complete"]) {
            taskType = DownloadTaskTypeComplete;
            cell.detailTextLabel.text = @"Complete";
            
            UIImageView *checkmarkView = [[UIImageView alloc] initWithFrame:CGRectMake(0, 0, 30, 30)];
            UIImage *checkmarkImage = [UIImage systemImageNamed:@"checkmark.circle.fill"];
            checkmarkView.image = checkmarkImage;
            checkmarkView.tintColor = [UIColor systemGreenColor];
            cell.accessoryView = checkmarkView;
        } else {
            // Regular file download awaiting start
            cell.detailTextLabel.text = @"Waiting...";
            
            UILabel *progressLabel = (UILabel *)cell.accessoryView;
            if (![progressLabel isKindOfClass:[UILabel class]]) {
                progressLabel = [[UILabel alloc] initWithFrame:CGRectMake(0, 0, 80, 30)];
                progressLabel.textAlignment = NSTextAlignmentRight;
                progressLabel.font = [UIFont systemFontOfSize:14];
                cell.accessoryView = progressLabel;
            }
            progressLabel.text = @"0%";
        }
    }

    return cell;
}

@end

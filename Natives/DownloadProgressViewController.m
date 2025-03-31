#import <dlfcn.h>
#import <objc/runtime.h>
#import "DownloadProgressViewController.h"
#import "WFWorkflowProgressView.h"
#import "utils.h"

// Define static contexts for KVO
static void *CellProgressObserverContext = &CellProgressObserverContext;
static void *TotalProgressObserverContext = &TotalProgressObserverContext;

@interface DownloadProgressViewController ()
@property NSInteger fileListCount;
@property (nonatomic, strong) UILabel *statusLabel;
@property (nonatomic, strong) UIProgressView *overallProgressView;
@property (nonatomic, strong) NSMutableDictionary *cellProgressMap;
@property (nonatomic, strong) NSTimer *refreshTimer;
@property (nonatomic, strong) NSMutableArray *filteredFileList;
@property (nonatomic, strong) NSString *lastCompletedFile; // Track the most recently completed file
@property (nonatomic, strong) NSSet *visibleIndexPaths; // Track visible cells for targeted updates
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
    
    // Remove overall progress observer
    @try {
        if (self.task && self.task.textProgress) {
            [self.task.textProgress removeObserver:self forKeyPath:@"fractionCompleted"];
        }
    } @catch (NSException *exception) {
        NSLog(@"[ProgressView] Warning: Failed to remove textProgress observer: %@", exception);
    }
    
    // Remove all cell progress observers
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
        
        // Percentage Label - make it wider to accommodate display
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
        if (self.task && self.task.textProgress) {
            [self.task.textProgress removeObserver:self forKeyPath:@"fractionCompleted"];
        }
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
    
    // Defensive copy
    NSArray *fileListCopy = nil;
    @synchronized(self.task.fileList) {
        fileListCopy = [NSArray arrayWithArray:self.task.fileList];
    }
    
    // Add all items from the task's file list
    for (NSString *filePath in fileListCopy) {
        if (!filePath) continue; // Skip nil entries
        [self.filteredFileList addObject:filePath];
    }
    
    // Sort the filtered list for consistent display
    [self.filteredFileList sortUsingComparator:^NSComparisonResult(NSString *path1, NSString *path2) {
        // Keep "Complete" entry at the end
        if ([path1 isEqualToString:@"Complete"]) {
            return NSOrderedDescending;
        } else if ([path2 isEqualToString:@"Complete"]) {
            return NSOrderedAscending;
        }
        
        // Keep extraction entries at the top
        BOOL isExtract1 = [path1 hasPrefix:@"Extracting"];
        BOOL isExtract2 = [path2 hasPrefix:@"Extracting"];
        if (isExtract1 && !isExtract2) {
            return NSOrderedAscending;
        } else if (!isExtract1 && isExtract2) {
            return NSOrderedDescending;
        }
        
        // Sort by filename for normal entries
        return [[path1 lastPathComponent] compare:[path2 lastPathComponent]];
    }];
}

- (void)refreshProgressUI {
    // Update overall progress for the header
    if (self.task.progress && self.task.progress.totalUnitCount > 0) {
        dispatch_async(dispatch_get_main_queue(), ^{
            // Update overall progress with stable value
            float fraction = self.task.progress.fractionCompleted;
            self.overallProgressView.progress = fraction;
            
            // Update percentage label - without speed
            UILabel *percentLabel = objc_getAssociatedObject(self.overallProgressView, @"percentLabel");
            int percentage = (int)(fraction * 100);
            
            // Store last percentage to avoid unnecessary updates
            static int lastDisplayedPercentage = -1;
            
            // Update only if percentage changed
            if (percentage != lastDisplayedPercentage) {
                lastDisplayedPercentage = percentage;
                percentLabel.text = [NSString stringWithFormat:@"%d%%", percentage];
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
    
    // Simplified Status Label Update
    @synchronized(self.task) {
        if (self.task.progress.cancelled) {
            self.statusLabel.text = @"Download Cancelled";
        } else if (self.task.progress.fractionCompleted >= 1.0 || self.task.progress.finished) {
            self.statusLabel.text = @"Download Complete";
        } else if (self.task.totalDownloads > 0) {
            // Show "Downloading X of Y"
            self.statusLabel.text = [NSString stringWithFormat:@"Downloading %ld of %ld files...",
                                    (long)self.task.successfulDownloads + 1, // Show current file number
                                    (long)self.task.totalDownloads];
        } else {
            self.statusLabel.text = @"Preparing download...";
        }
    }
    
    // Simplified Completion Check
    BOOL isComplete = NO;
    @synchronized(self.task) {
        // Check if progress is complete
        isComplete = self.task.progress.finished || (self.task.progress.totalUnitCount > 0 && self.task.progress.fractionCompleted >= 1.0);
        
        // Also consider successful downloads vs total downloads
        // Since we can't access pendingDownloads and activeDownloads directly
        // (they're private properties), we'll rely on progress and counts
        if (!isComplete && self.task.totalDownloads > 0 && 
            self.task.successfulDownloads >= self.task.totalDownloads) {
            // If all downloads are successful, and there's been some delay in progress update,
            // consider it complete
            isComplete = YES;
        }
    }
    
    // If complete, ensure UI reflects this
    if (isComplete && ![self.filteredFileList containsObject:@"Complete"]) {
        // Add completion marker if needed
        BOOL added = NO;
        @synchronized(self.task.fileList) {
            if (![self.task.fileList containsObject:@"Complete"]) {
                [self.task.fileList addObject:@"Complete"];
                added = YES;
            }
        }
        
        if (added) {
            [self updateFilteredFileList]; // Update filtered list
            [self reloadTableViewPreservingOffset];
            self.statusLabel.text = @"Download complete";
        }
    }
}

- (void)reloadTableViewPreservingOffset {
    // Save current scroll position and content size
    CGPoint contentOffset = self.tableView.contentOffset;
    CGSize contentSize = self.tableView.contentSize;
    
    // Reload data with animation disabled to prevent flickering
    [UIView setAnimationsEnabled:NO];
    [self.tableView reloadData];
    [UIView setAnimationsEnabled:YES];
    
    // After reload, check if content size changed significantly
    CGFloat heightDifference = self.tableView.contentSize.height - contentSize.height;
    
    // If content got taller but we're already scrolled near the bottom,
    // adjust offset to maintain relative position from bottom
    if (heightDifference > 0 && 
        contentOffset.y > (contentSize.height - self.tableView.frame.size.height - 100)) {
        contentOffset.y += heightDifference;
    }
    
    // Restore scroll position safely (make sure it's within bounds)
    contentOffset.y = MIN(MAX(contentOffset.y, 0), 
                          MAX(0, self.tableView.contentSize.height - self.tableView.frame.size.height));
    
    // Apply the adjusted content offset
    [self.tableView setContentOffset:contentOffset animated:NO];
}

// Helper method to update only visible cells to prevent flickering
- (void)updateVisibleCells {
    // Capture which cells are currently visible
    NSArray *visiblePaths = [self.tableView indexPathsForVisibleRows];
    if (!visiblePaths) return;
    
    // Create a dictionary to track cells we've already updated this cycle
    NSMutableDictionary *updatedCells = [NSMutableDictionary dictionary];
    
    self.visibleIndexPaths = [NSSet setWithArray:visiblePaths];
    
    for (NSIndexPath *indexPath in visiblePaths) {
        if (indexPath.row < self.filteredFileList.count) {
            UITableViewCell *cell = [self.tableView cellForRowAtIndexPath:indexPath];
            if (!cell) continue;
            
            // Check if we've already updated this cell in this cycle
            NSString *cellIdentifier = [NSString stringWithFormat:@"%ld", (long)indexPath.row];
            if (updatedCells[cellIdentifier]) continue;
            
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
                    updatedCells[cellIdentifier] = @YES;
                }
            }
        }
    }
}

// Helper method to update a cell with the latest progress
- (void)updateCell:(UITableViewCell *)cell withProgress:(NSProgress *)progress forIndexPath:(NSIndexPath *)indexPath {
    if (!cell || indexPath.row >= self.filteredFileList.count) {
        return;
    }
    
    NSString *fileName = self.filteredFileList[indexPath.row];
    cell.textLabel.text = [fileName lastPathComponent];
    
    // Handle the nil progress case (e.g., file is waiting)
    if (!progress) {
        cell.detailTextLabel.text = @"Waiting...";
        
        // Set accessory to a placeholder label if not already set
        if (![cell.accessoryView isKindOfClass:[UILabel class]]) {
            UILabel *waitingLabel = [[UILabel alloc] initWithFrame:CGRectMake(0, 0, 50, 30)];
            waitingLabel.text = @"--";
            waitingLabel.textAlignment = NSTextAlignmentRight;
            waitingLabel.font = [UIFont systemFontOfSize:13];
            waitingLabel.textColor = [UIColor secondaryLabelColor];
            cell.accessoryView = waitingLabel;
        } else {
            ((UILabel *)cell.accessoryView).text = @"--";
        }
        return;
    }
    
    // Get progress values safely
    float fractionCompleted = 0.0;
    BOOL isComplete = NO;
    long long completedUnits = 0;
    long long totalUnits = 0;
    
    @try {
        completedUnits = progress.completedUnitCount;
        totalUnits = progress.totalUnitCount;
        
        // Ensure totalUnits is not zero before division
        if (totalUnits > 0) {
            fractionCompleted = (float)completedUnits / totalUnits;
        } else if (completedUnits > 0) {
            // Handle case where total is 0 but completed is not
            fractionCompleted = 1.0; // Assume complete if total is 0 but bytes received
        }
        
        // Clamp fraction to valid range
        fractionCompleted = MAX(0.0, MIN(1.0, fractionCompleted));
        
        isComplete = progress.finished || (totalUnits > 0 && completedUnits >= totalUnits);
    } @catch (NSException *exception) {
        NSLog(@"[ProgressView] Warning: Exception getting progress value: %@", exception);
        isComplete = NO;
        fractionCompleted = 0.0;
    }
    
    // Calculate percentage for display
    int percentage = (int)(fractionCompleted * 100);
    NSString *percentString = [NSString stringWithFormat:@"%d%%", percentage];
    
    NSString *detailText = @"";
    
    // Handle different states for UI display
    if (isComplete || [fileName isEqualToString:@"Complete"]) {
        detailText = @"Complete";
        
        // Accessory: Checkmark
        if (![cell.accessoryView isKindOfClass:[UIImageView class]] || ((UIImageView *)cell.accessoryView).tag != 1) {
            UIImageView *checkmarkView = [[UIImageView alloc] initWithImage:[UIImage systemImageNamed:@"checkmark.circle.fill"]];
            checkmarkView.tintColor = [UIColor systemGreenColor];
            checkmarkView.tag = 1; // Tag to identify it
            checkmarkView.frame = CGRectMake(0, 0, 24, 24);
            checkmarkView.contentMode = UIViewContentModeScaleAspectFit;
            cell.accessoryView = checkmarkView;
        }
        
        // Update last completed file if needed
        self.lastCompletedFile = [fileName lastPathComponent];
    } else if ([fileName hasPrefix:@"Extracting"]) {
        detailText = [NSString stringWithFormat:@"Extracting... %d%%", percentage];
        
        // Accessory: Activity Indicator
        if (![cell.accessoryView isKindOfClass:[UIActivityIndicatorView class]]) {
            UIActivityIndicatorView *activityIndicator = [[UIActivityIndicatorView alloc] initWithActivityIndicatorStyle:UIActivityIndicatorViewStyleMedium];
            [activityIndicator startAnimating];
            cell.accessoryView = activityIndicator;
        }
    } else {
        // Regular file download in progress
        if (totalUnits > 0) {
            // Format size: Show MB/MB or KB/KB based on file size
            double completedMB = (double)completedUnits / (1024.0 * 1024.0);
            double totalMB = (double)totalUnits / (1024.0 * 1024.0);
            
            if (totalMB < 0.1) {
                // Show KB if < 0.1 MB
                detailText = [NSString stringWithFormat:@"%.0f/%.0f KB", completedUnits / 1024.0, totalUnits / 1024.0];
            } else if (totalMB < 10.0) {
                detailText = [NSString stringWithFormat:@"%.2f/%.2f MB", completedMB, totalMB];
            } else {
                detailText = [NSString stringWithFormat:@"%.1f/%.1f MB", completedMB, totalMB];
            }
        } else {
            // If total size is unknown, just show percentage or "Waiting..."
            detailText = (completedUnits > 0) ? percentString : @"Waiting...";
        }
        
        // Accessory: Percentage Label
        UILabel *progressLabel = nil;
        if ([cell.accessoryView isKindOfClass:[UILabel class]]) {
            progressLabel = (UILabel *)cell.accessoryView;
        } else {
            progressLabel = [[UILabel alloc] initWithFrame:CGRectMake(0, 0, 50, 30)];
            progressLabel.textAlignment = NSTextAlignmentRight;
            progressLabel.font = [UIFont systemFontOfSize:13];
            progressLabel.textColor = [UIColor secondaryLabelColor];
            cell.accessoryView = progressLabel;
        }
        progressLabel.text = percentString;
    }
    
    // Update detail text label
    cell.detailTextLabel.text = detailText;
    
    // Track the last update time to throttle updates
    NSTimeInterval now = [NSDate timeIntervalSinceReferenceDate];
    objc_setAssociatedObject(cell, "lastUpdateTime", @(now), OBJC_ASSOCIATION_RETAIN_NONATOMIC);
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
            
            // Only attempt to remove if the progress object is valid
            if (progress && [progress isKindOfClass:[NSProgress class]]) {
                [self removeProgressObserver:progress];
            }
        }
        [self.cellProgressMap removeAllObjects];
    }
}

- (void)removeProgressObserver:(NSProgress *)progress {
    if (!progress) return;
    
    @synchronized(self) {
        // Check if this progress is actually in our tracking map
        NSString *progressIdentifier = [NSString stringWithFormat:@"%p", progress];
        NSProgress *trackedProgress = [self.cellProgressMap objectForKey:progressIdentifier];
        
        // Only attempt to remove if we're actually tracking this exact progress instance
        if (trackedProgress == progress) {
            @try {
                [progress removeObserver:self forKeyPath:@"fractionCompleted"];
                
                // Remove from tracking map after successful removal
                [self.cellProgressMap removeObjectForKey:progressIdentifier];
            } @catch (NSException *exception) {
                // Just log the exception but don't crash
                NSLog(@"[ProgressView] Warning: Failed to remove observer: %@", exception);
            }
            
            // Also clear the association to avoid dangling references
            objc_setAssociatedObject(progress, @"cell", nil, OBJC_ASSOCIATION_ASSIGN);
        }
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
        if (now - lastCellUpdate < 0.2) {
            // Throttle updates to max 5 per second
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
                    
                    // Check if cell is visible before attempting update
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
        static int lastPercentage = -1;
        
        NSTimeInterval now = [NSDate timeIntervalSinceReferenceDate];
        if (now - lastHeaderUpdate < 0.5) {
            // Throttle updates to max 2 per second for header
            return;
        }
        
        // Get current values before update to prevent race conditions
        int currentPercentage = 0;
        
        @try {
            currentPercentage = (int)(progress.fractionCompleted * 100);
            
            // Ensure percentage is valid
            if (currentPercentage < 0) currentPercentage = 0;
            if (currentPercentage > 100) currentPercentage = 100;
        } @catch (NSException *exception) {
            NSLog(@"[ProgressView] Warning: Exception getting progress values: %@", exception);
            return;
        }
        
        // Only update if there is a meaningful change in percentage
        if (currentPercentage != lastPercentage) {
            lastHeaderUpdate = now;
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
        // Let updateCell handle the initial accessory view state
        cell.accessoryView = nil;
    }
    
    // Get the file name from filtered list
    NSString *fileName = @"";
    if (indexPath.row < self.filteredFileList.count) {
        fileName = self.filteredFileList[indexPath.row];
    } else {
        // Should not happen, but handle gracefully
        NSLog(@"[ProgressView] Warning: Index out of bounds for filteredFileList.");
        cell.textLabel.text = @"Error";
        cell.detailTextLabel.text = @"";
        cell.accessoryView = nil;
        return cell;
    }
    
    cell.textLabel.text = [fileName lastPathComponent]; // Display base name
    
    // KVO Management: Clean up old observer/association
    NSProgress *oldProgress = objc_getAssociatedObject(cell, @"progress");
    if (oldProgress) {
        objc_setAssociatedObject(oldProgress, @"cell", nil, OBJC_ASSOCIATION_ASSIGN);
        [self removeProgressObserver:oldProgress];
        objc_setAssociatedObject(cell, @"progress", nil, OBJC_ASSOCIATION_ASSIGN);
    }
    
    // Clear accessory view for reuse
    cell.accessoryView = nil;
    cell.detailTextLabel.text = @""; // Clear detail text
    
    // Find the corresponding NSProgress object
    NSProgress *progress = nil;
    NSUInteger originalIndex = NSNotFound;
    
    // Find the item in the original list to get the correct progress index
    @synchronized(self.task.fileList) {
        originalIndex = [self.task.fileList indexOfObject:fileName];
    }
    
    if (originalIndex != NSNotFound) {
        @synchronized(self.task.progressList) {
            if (originalIndex < self.task.progressList.count) {
                progress = self.task.progressList[originalIndex];
            }
        }
    }
    
    if (progress) {
        // Associate progress with cell
        objc_setAssociatedObject(cell, @"progress", progress, OBJC_ASSOCIATION_ASSIGN);
        objc_setAssociatedObject(progress, @"cell", cell, OBJC_ASSOCIATION_ASSIGN);
        
        // Add observer with proper identifier tracking to avoid duplicates
        NSString *progressIdentifier = [NSString stringWithFormat:@"%p", progress];
        NSProgress *trackedProgress = [self.cellProgressMap objectForKey:progressIdentifier];
        
        // Only add observer if not already tracking this exact progress instance
        if (trackedProgress != progress) {
            // If we're tracking a different progress with the same address, remove it first
            if (trackedProgress) {
                [self removeProgressObserver:trackedProgress];
            }
            
            @try {
                [progress addObserver:self
                          forKeyPath:@"fractionCompleted"
                             options:NSKeyValueObservingOptionInitial | NSKeyValueObservingOptionNew
                             context:CellProgressObserverContext];
                [self.cellProgressMap setObject:progress forKey:progressIdentifier];
            } @catch (NSException *exception) {
                NSLog(@"[ProgressView] Warning: Failed to add observer for %@: %@", fileName, exception);
            }
        } else {
            // Already observing, manually trigger update
            [self updateCell:cell withProgress:progress forIndexPath:indexPath];
        }
    } else {
        // No progress object found - set default "Waiting..." state
        [self updateCell:cell withProgress:nil forIndexPath:indexPath];
    }
    
    return cell;
}

@end

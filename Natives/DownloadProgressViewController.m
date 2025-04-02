#import <dlfcn.h>
#import <objc/runtime.h>
#import "DownloadProgressViewController.h"
#import "LauncherNavigationController.h"
#import "PLProfiles.h"
#import "WFWorkflowProgressView.h"
#import "DownloadProgressManager.h"
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
        
        // Register for progress notifications from manager
        [[NSNotificationCenter defaultCenter] addObserver:self
                                                 selector:@selector(progressUpdated:)
                                                     name:DMProgressUpdatedNotification
                                                   object:nil];
                                                   
        [[NSNotificationCenter defaultCenter] addObserver:self
                                                 selector:@selector(downloadCompleted:)
                                                     name:DMDownloadCompletedNotification
                                                   object:nil];
    }
    return self;
}

- (void)dealloc {
    // Remove progress observers
    [self removeAllProgressObservers];
    
    // Remove notification observers
    [[NSNotificationCenter defaultCenter] removeObserver:self];
    
    // Stop timers
    [self.refreshTimer invalidate];
    self.refreshTimer = nil;
}

- (void)viewDidLoad {
    [super viewDidLoad];
    
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
    
    // Connect to progress manager
    DownloadProgressManager *manager = [DownloadProgressManager sharedManager];
    
    // Initial UI update
    self.statusLabel.text = manager.statusMessage;
    
    // Setup a refresh timer to periodically update the UI at a controlled rate
    self.refreshTimer = [NSTimer scheduledTimerWithTimeInterval:0.5 
                                                         target:self 
                                                       selector:@selector(refreshProgressUI) 
                                                       userInfo:nil 
                                                        repeats:YES];
    
    // Run the timer on a common mode to ensure updates when scrolling
    [[NSRunLoop currentRunLoop] addTimer:self.refreshTimer forMode:NSRunLoopCommonModes];
}

- (void)viewDidAppear:(BOOL)animated {
    [super viewDidAppear:animated];
    
    // Initial refresh
    [self refreshProgressUI];
}

- (void)viewDidDisappear:(BOOL)animated {
    [super viewDidDisappear:animated];
    
    // No need to stop the timer here anymore - we'll handle it via notifications
}

- (void)progressUpdated:(NSNotification *)notification {
    // Get the progress manager
    DownloadProgressManager *manager = notification.object;
    
    // Mark that UI needs refresh
    self.needsFullTableReload = YES;
    
    // Update UI immediately
    [self refreshProgressUI];
}

- (void)downloadCompleted:(NSNotification *)notification {
    // Get the progress manager
    DownloadProgressManager *manager = notification.object;
    
    // Only handle if truly complete
    if (!manager.isComplete) return;
    
    // Final UI update
    self.needsFullTableReload = YES;
    [self refreshProgressUI];
    
    // Log completion
    NSLog(@"[ProgressVC] Download completed, isError: %d", manager.isError);
    
    // Handle UI restoration if appropriate
    if (!manager.isError && !manager.isModpackInstall) {
        // For regular Minecraft downloads, signal UI restoration
        [self forceReenableUI];
    }
}

- (void)updateFilteredFileList {
    // Clear previous filtered list
    [self.filteredFileList removeAllObjects];
    
    // Get progress manager
    DownloadProgressManager *manager = [DownloadProgressManager sharedManager];
    
    // Add all items from the manager's file list
    for (DownloadFileItem *fileItem in manager.fileItems) {
        if (!fileItem.displayName) continue; // Skip items without display name
        [self.filteredFileList addObject:fileItem];
    }
    
    // Sort the filtered list for consistent display
    [self.filteredFileList sortUsingComparator:^NSComparisonResult(DownloadFileItem *item1, DownloadFileItem *item2) {
        // Keep extraction entries at the top
        BOOL isExtract1 = [item1.displayName hasPrefix:@"Extracting"];
        BOOL isExtract2 = [item2.displayName hasPrefix:@"Extracting"];
        if (isExtract1 && !isExtract2) {
            return NSOrderedAscending;
        } else if (!isExtract1 && isExtract2) {
            return NSOrderedDescending;
        }
        
        // Sort completed items to the bottom
        if (item1.isComplete && !item2.isComplete) {
            return NSOrderedDescending;
        } else if (!item1.isComplete && item2.isComplete) {
            return NSOrderedAscending;
        }
        
        // Sort by display name for normal entries
        return [item1.displayName compare:item2.displayName];
    }];
    
    // Add a completion marker if download is complete
    if (manager.isComplete && !manager.isError) {
        DownloadFileItem *completeItem = [DownloadFileItem new];
        completeItem.displayName = @"Complete";
        completeItem.isComplete = YES;
        [completeItem.progress setCompletedUnitCount:1];
        
        [self.filteredFileList addObject:completeItem];
    }
}

- (void)refreshProgressUI {
    // Get the progress manager
    DownloadProgressManager *manager = [DownloadProgressManager sharedManager];
    
    // Update header information
    dispatch_async(dispatch_get_main_queue(), ^{
        // Update overall progress
        self.overallProgressView.progress = manager.overallProgress.fractionCompleted;
        
        // Update percentage label
        UILabel *percentLabel = objc_getAssociatedObject(self.overallProgressView, @"percentLabel");
        if (percentLabel) {
            percentLabel.text = [manager formattedOverallProgress];
            
            // Add transfer rate if available
            if (manager.startTime && !manager.isComplete) {
                NSString *timeRemaining = [manager formattedTimeRemaining];
                NSString *transferRate = [manager formattedTransferRate];
                percentLabel.text = [NSString stringWithFormat:@"%@ • %@ • %@", 
                                   [manager formattedOverallProgress], 
                                   transferRate, 
                                   timeRemaining];
            }
        }
        
        // Update status text
        self.statusLabel.text = manager.statusMessage;
    });
    
    // Check if we need a full table reload
    if (self.needsFullTableReload) {
        // Update the filtered file list
        [self updateFilteredFileList];
        
        // Reload table view
        [self reloadTableViewPreservingOffset];
        self.needsFullTableReload = NO;
    } else {
        // Update visible cells instead of reloading entire table
        [self updateVisibleCells];
    }
}

- (void)forceReenableUI {
    dispatch_async(dispatch_get_main_queue(), ^{
        // Find LauncherNavigationController
        UIViewController *rootVC = nil;
        
        // Get key window using the appropriate API
        UIWindow *keyWindow = nil;
        NSArray<UIWindow *> *windows = nil;
            
        if (@available(iOS 13.0, *)) {
            for (UIScene *scene in UIApplication.sharedApplication.connectedScenes) {
                if ([scene isKindOfClass:[UIWindowScene class]] && 
                    ((UIWindowScene *)scene).activationState == UISceneActivationStateForegroundActive) {
                    windows = ((UIWindowScene *)scene).windows;
                    break;
                }
            }
        } else {
            windows = UIApplication.sharedApplication.windows;
        }
            
        for (UIWindow *window in windows) {
            if (window.isKeyWindow) {
                keyWindow = window;
                break;
            }
        }
        
        if (keyWindow) {
            rootVC = keyWindow.rootViewController;
        }
        
        // Find LauncherNavigationController
        LauncherNavigationController *navVC = nil;
        if ([rootVC isKindOfClass:[UISplitViewController class]]) {
            UISplitViewController *splitVC = (UISplitViewController *)rootVC;
            if (splitVC.viewControllers.count > 1) {
                if ([splitVC.viewControllers[1] isKindOfClass:[LauncherNavigationController class]]) {
                    navVC = (LauncherNavigationController *)splitVC.viewControllers[1];
                }
            }
        }
        
        // Re-enable the UI
        if (navVC) {
            NSLog(@"[ProgressView] Found LauncherNavigationController, re-enabling UI");
            [navVC setInteractionEnabled:YES forDownloading:NO];
            [navVC fetchLocalVersionList];
            [PLProfiles updateCurrent];
        } else {
            NSLog(@"[ProgressView] Could not find LauncherNavigationController");
        }
    });
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
    
    // Update visible cells
    for (NSIndexPath *indexPath in visiblePaths) {
        UITableViewCell *cell = [self.tableView cellForRowAtIndexPath:indexPath];
        if (!cell || indexPath.row >= self.filteredFileList.count) continue;
        
        DownloadFileItem *fileItem = self.filteredFileList[indexPath.row];
        
        // Update cell content based on current file state
        [self updateCell:cell withFileItem:fileItem forIndexPath:indexPath];
    }
}

// Helper method to update a cell with file item data
- (void)updateCell:(UITableViewCell *)cell withFileItem:(DownloadFileItem *)fileItem forIndexPath:(NSIndexPath *)indexPath {
    // Configure cell based on file item
    cell.textLabel.text = [fileItem.displayName lastPathComponent];
    
    // Determine detail text and accessory view based on file state
    if (fileItem.isComplete || [fileItem.displayName isEqualToString:@"Complete"]) {
        cell.detailTextLabel.text = @"Complete";
        
        UIImageView *checkmarkView = [[UIImageView alloc] initWithImage:[UIImage systemImageNamed:@"checkmark.circle.fill"]];
        checkmarkView.tintColor = [UIColor systemGreenColor];
        checkmarkView.frame = CGRectMake(0, 0, 24, 24);
        cell.accessoryView = checkmarkView;
    } else if (fileItem.hasError) {
        cell.detailTextLabel.text = fileItem.errorMessage ?: @"Failed";
        
        UIImageView *errorView = [[UIImageView alloc] initWithImage:[UIImage systemImageNamed:@"exclamationmark.circle.fill"]];
        errorView.tintColor = [UIColor systemRedColor];
        errorView.frame = CGRectMake(0, 0, 24, 24);
        cell.accessoryView = errorView;
    } else if ([fileItem.displayName hasPrefix:@"Extracting"]) {
        cell.detailTextLabel.text = @"Extracting...";
        
        UIActivityIndicatorView *activityIndicator = [[UIActivityIndicatorView alloc] initWithActivityIndicatorStyle:UIActivityIndicatorViewStyleMedium];
        [activityIndicator startAnimating];
        cell.accessoryView = activityIndicator;
    } else if (fileItem.isWaiting) {
        cell.detailTextLabel.text = @"Waiting...";
        
        UILabel *waitingLabel = [[UILabel alloc] initWithFrame:CGRectMake(0, 0, 50, 30)];
        waitingLabel.text = @"--";
        waitingLabel.textAlignment = NSTextAlignmentRight;
        waitingLabel.font = [UIFont systemFontOfSize:13];
        waitingLabel.textColor = [UIColor secondaryLabelColor];
        cell.accessoryView = waitingLabel;
    } else {
        // Active download
        if (fileItem.size > 0) {
            // Format size: Show MB/MB or KB/KB based on file size
            double completedMB = (double)fileItem.completed / (1024.0 * 1024.0);
            double totalMB = (double)fileItem.size / (1024.0 * 1024.0);
            
            if (totalMB < 0.1) {
                // Show KB if < 0.1 MB
                cell.detailTextLabel.text = [NSString stringWithFormat:@"%.0f/%.0f KB", 
                                           fileItem.completed / 1024.0, 
                                           fileItem.size / 1024.0];
            } else if (totalMB < 10.0) {
                cell.detailTextLabel.text = [NSString stringWithFormat:@"%.2f/%.2f MB", 
                                           completedMB, totalMB];
            } else {
                cell.detailTextLabel.text = [NSString stringWithFormat:@"%.1f/%.1f MB", 
                                           completedMB, totalMB];
            }
        } else {
            // If total size is unknown
            double fraction = 0.0;
            @try {
                fraction = fileItem.progress.fractionCompleted;
            } @catch (NSException *exception) {}
            
            int percentage = (int)(fraction * 100);
            cell.detailTextLabel.text = [NSString stringWithFormat:@"%d%%", percentage];
        }
        
        // Create percentage label
        UILabel *progressLabel = [[UILabel alloc] initWithFrame:CGRectMake(0, 0, 50, 30)];
        progressLabel.textAlignment = NSTextAlignmentRight;
        progressLabel.font = [UIFont systemFontOfSize:13];
        progressLabel.textColor = [UIColor secondaryLabelColor];
        
        // Calculate percentage
        double fraction = 0.0;
        @try {
            fraction = fileItem.progress.fractionCompleted;
        } @catch (NSException *exception) {}
        
        int percentage = (int)(fraction * 100);
        progressLabel.text = [NSString stringWithFormat:@"%d%%", percentage];
        
        cell.accessoryView = progressLabel;
    }
}

- (void)actionClose {
    // Ask for confirmation if download is in progress
    DownloadProgressManager *manager = [DownloadProgressManager sharedManager];
    
    if (!manager.isComplete) {
        UIAlertController *alert = [UIAlertController alertControllerWithTitle:@"Cancel Download"
                                                                       message:@"Are you sure you want to cancel the current download?"
                                                                preferredStyle:UIAlertControllerStyleAlert];
        
        [alert addAction:[UIAlertAction actionWithTitle:@"Yes" style:UIAlertActionStyleDestructive handler:^(UIAlertAction * _Nonnull action) {
            // Cancel the download
            [manager cancelDownload];
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

#pragma mark - Table View Data Source

- (NSInteger)tableView:(UITableView *)tableView numberOfRowsInSection:(NSInteger)section {
    // Account for empty state
    if (self.filteredFileList.count == 0) {
        DownloadProgressManager *manager = [DownloadProgressManager sharedManager];
        return manager.isComplete ? 1 : 0;
    }
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
        cell.accessoryView = nil;
    }
    
    // Get the progress manager
    DownloadProgressManager *manager = [DownloadProgressManager sharedManager];
    
    // Handle empty state
    if (self.filteredFileList.count == 0) {
        if (manager.isComplete) {
            cell.textLabel.text = manager.isError ? @"Download Failed" : @"Download Complete";
            cell.detailTextLabel.text = manager.isError ? manager.errorMessage : @"";
            
            if (manager.isError) {
                UIImageView *errorIcon = [[UIImageView alloc] initWithImage:[UIImage systemImageNamed:@"exclamationmark.circle.fill"]];
                errorIcon.tintColor = [UIColor systemRedColor];
                errorIcon.frame = CGRectMake(0, 0, 24, 24);
                cell.accessoryView = errorIcon;
            } else {
                UIImageView *checkmark = [[UIImageView alloc] initWithImage:[UIImage systemImageNamed:@"checkmark.circle.fill"]];
                checkmark.tintColor = [UIColor systemGreenColor];
                checkmark.frame = CGRectMake(0, 0, 24, 24);
                cell.accessoryView = checkmark;
            }
        } else {
            cell.textLabel.text = @"Preparing download...";
            cell.detailTextLabel.text = @"";
            cell.accessoryView = nil;
        }
        return cell;
    }
    
    // Get the file item
    DownloadFileItem *fileItem = self.filteredFileList[indexPath.row];
    
    // Update cell with file item data
    [self updateCell:cell withFileItem:fileItem forIndexPath:indexPath];
    
    return cell;
}

#pragma mark - UIScrollViewDelegate

// Override to track visible cells whenever scroll position changes
- (void)scrollViewDidScroll:(UIScrollView *)scrollView {
    // Update visible index paths on scroll
    NSArray *visiblePaths = [self.tableView indexPathsForVisibleRows];
    self.visibleIndexPaths = [NSSet setWithArray:visiblePaths];
}

#pragma mark - KVO Handling

- (void)observeValueForKeyPath:(NSString *)keyPath ofObject:(id)object change:(NSDictionary *)change context:(void *)context {
    // Handle any KVO notifications that might still arrive from legacy code
    if (context == CellProgressObserverContext) {
        NSLog(@"[ProgressView] Received legacy KVO notification for cell progress");
        // We can safely ignore these as we've moved to notification-based updates
    } else if (context == TotalProgressObserverContext) {
        NSLog(@"[ProgressView] Received legacy KVO notification for total progress");
        // We can safely ignore these as we've moved to notification-based updates
    } else {
        [super observeValueForKeyPath:keyPath ofObject:object change:change context:context];
    }
}

@end

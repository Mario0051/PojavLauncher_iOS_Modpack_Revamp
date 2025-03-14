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
@end

@implementation DownloadProgressViewController

- (instancetype)initWithTask:(MinecraftResourceDownloadTask *)task {
    self = [super init];
    if (self) {
        self.task = task;
        self.cellProgressMap = [NSMutableDictionary dictionary];
        self.filteredFileList = [NSMutableArray array];
        self.lastCompletedFile = nil; // Initialize last completed file to nil
    }
    return self;
}

- (void)dealloc {
    // Make sure we remove all observers when the view controller is deallocated
    [self.refreshTimer invalidate];
    self.refreshTimer = nil;
    
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
    
    // Percentage label
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
        
        // Percentage Label
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
    
    // Setup a refresh timer to periodically update the UI
    // This helps with smoother updates when individual operations are taking a long time
    self.refreshTimer = [NSTimer scheduledTimerWithTimeInterval:0.5 
                                                        target:self 
                                                      selector:@selector(refreshProgressUI) 
                                                      userInfo:nil 
                                                       repeats:YES];
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

- (void)updateFilteredFileList {
    // Clear previous filtered list
    [self.filteredFileList removeAllObjects];
    
    // Create a defensive copy of the file list to avoid mutation during enumeration
    NSArray *fileListCopy = [NSArray arrayWithArray:self.task.fileList];
    
    // Create a dictionary to track files by their base name
    NSMutableDictionary *fileMap = [NSMutableDictionary dictionary];
    
    // First pass: group files by base name and filter out extraction entries
    for (NSString *filePath in fileListCopy) {
        // Skip extraction entries completely
        if ([filePath hasPrefix:@"Extracting"] || 
            [filePath hasPrefix:@"Setting"] || 
            [filePath hasPrefix:@"Installing"]) {
            // Don't add these to the filtered list
            continue;
        }
        
        // Include completion indicator
        if ([filePath isEqualToString:@"Complete"]) {
            [self.filteredFileList addObject:filePath];
            continue;
        }
        
        // Get just the file name without path
        NSString *fileName = [filePath lastPathComponent];
        
        // Store this path for this file name, preferring longer paths with directory structure
        if (!fileMap[fileName] || [filePath length] > [fileMap[fileName] length]) {
            fileMap[fileName] = filePath;
        }
    }
    
    // Add all unique paths to the filtered list
    NSArray *uniquePaths = [fileMap allValues];
    for (NSString *uniquePath in uniquePaths) {
        [self.filteredFileList addObject:uniquePath];
    }
    
    // Sort the filtered list for consistent display
    [self.filteredFileList sortUsingComparator:^NSComparisonResult(NSString *path1, NSString *path2) {
        // Keep the Complete entry at the top
        if ([path1 isEqualToString:@"Complete"]) {
            return NSOrderedAscending;
        } else if ([path2 isEqualToString:@"Complete"]) {
            return NSOrderedDescending;
        }
        
        // For regular files, sort alphabetically
        return [path1 compare:path2];
    }];
}

- (void)reloadTableViewPreservingOffset {
    // Save current scroll position
    CGPoint contentOffset = self.tableView.contentOffset;
    
    // Reload data
    [self.tableView reloadData];
    
    // Restore scroll position
    [self.tableView setContentOffset:contentOffset animated:NO];
}

- (void)refreshProgressUI {
    // Update overall progress for the header
    if (self.task.progress && self.task.progress.totalUnitCount > 0) {
        dispatch_async(dispatch_get_main_queue(), ^{
            // Update overall progress
            float fraction = self.task.progress.fractionCompleted;
            self.overallProgressView.progress = fraction;
            
            // Update percentage label
            UILabel *percentLabel = objc_getAssociatedObject(self.overallProgressView, @"percentLabel");
            int percentage = (int)(fraction * 100);
            percentLabel.text = [NSString stringWithFormat:@"%d%%", percentage];
        });
    }
    
    // Update the filtered file list
    [self updateFilteredFileList];
    
    // Check for any new items that were added first
    if (self.fileListCount != self.filteredFileList.count) {
        self.fileListCount = self.filteredFileList.count;
        [self reloadTableViewPreservingOffset];
        return; // Don't proceed with other updates in the same refresh cycle
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
    }
    
    // Force progress completion for extraction and setup tasks that may be stuck
    if (isComplete) {
        // Make a defensive copy to avoid mutation issues
        NSArray *progressListCopy = [NSArray arrayWithArray:self.task.progressList];
        for (NSInteger i = 0; i < progressListCopy.count; i++) {
            NSProgress *progress = progressListCopy[i];
            if (progress.fractionCompleted < 1.0) {
                progress.completedUnitCount = progress.totalUnitCount;
            }
        }
    }
    
    // If complete, ensure UI reflects this
    if (isComplete && ![self.filteredFileList containsObject:@"Complete"] && ![self.task.fileList containsObject:@"Complete"]) {
        // Add completion marker if needed
        [self.task.fileList addObject:@"Complete"];
        [self.filteredFileList addObject:@"Complete"];
        
        // Create completion progress
        NSProgress *completeProgress = [NSProgress progressWithTotalUnitCount:1];
        completeProgress.completedUnitCount = 1;
        completeProgress.kind = NSProgressKindFile;
        [self.task.progressList addObject:completeProgress];
        [self.task.progress addChild:completeProgress withPendingUnitCount:1];
        
        [self reloadTableViewPreservingOffset];
        
        // Update status label for completion
        self.statusLabel.text = @"Download complete";
    } else {
        // Instead of reloading the entire table, update visible cells
        [self updateVisibleCells];
    }
}

// Helper method to update only visible cells to prevent flickering
- (void)updateVisibleCells {
    NSArray *visiblePaths = [self.tableView indexPathsForVisibleRows];
    for (NSIndexPath *indexPath in visiblePaths) {
        if (indexPath.row < self.filteredFileList.count) {
            UITableViewCell *cell = [self.tableView cellForRowAtIndexPath:indexPath];
            NSString *fileName = self.filteredFileList[indexPath.row];
            NSUInteger originalIndex = [self.task.fileList indexOfObject:fileName];
            
            if (originalIndex != NSNotFound && originalIndex < self.task.progressList.count) {
                NSProgress *progress = self.task.progressList[originalIndex];
                [self updateCell:cell withProgress:progress forIndexPath:indexPath];
            }
        }
    }
}

// Helper method to update a cell with the latest progress
- (void)updateCell:(UITableViewCell *)cell withProgress:(NSProgress *)progress forIndexPath:(NSIndexPath *)indexPath {
    if (!cell || !progress) return;
    
    NSString *fileName = self.filteredFileList[indexPath.row];
    DownloadTaskType taskType = DownloadTaskTypeFile;
    
    if ([fileName hasPrefix:@"Extracting"]) {
        taskType = DownloadTaskTypeExtraction;
    } else if ([fileName hasPrefix:@"Setting"]) {
        taskType = DownloadTaskTypeSetup;
    } else if ([fileName isEqualToString:@"Complete"]) {
        taskType = DownloadTaskTypeComplete;
    }
    
    // Format size as MB/MB for file downloads
    NSString *sizeText;
    if (taskType == DownloadTaskTypeFile && progress.totalUnitCount > 0) {
        double completedMB = progress.completedUnitCount / 1024.0 / 1024.0;
        double totalMB = progress.totalUnitCount / 1024.0 / 1024.0;
        
        // Format with appropriate precision based on size
        if (totalMB < 1.0) {
            // Use KB for small files
            double completedKB = progress.completedUnitCount / 1024.0;
            double totalKB = progress.totalUnitCount / 1024.0;
            sizeText = [NSString stringWithFormat:@"%.0fKB/%.0fKB", completedKB, totalKB];
        } else if (totalMB < 10.0) {
            // More precision for smaller files
            sizeText = [NSString stringWithFormat:@"%.2fMB/%.2fMB", completedMB, totalMB];
        } else if (totalMB < 100.0) {
            sizeText = [NSString stringWithFormat:@"%.1fMB/%.1fMB", completedMB, totalMB];
        } else {
            sizeText = [NSString stringWithFormat:@"%.0fMB/%.0fMB", completedMB, totalMB];
        }
    } else if (taskType == DownloadTaskTypeExtraction) {
        // Show extraction progress percentage
        int percentage = (int)(progress.fractionCompleted * 100);
        sizeText = [NSString stringWithFormat:@"Extracting... %d%%", percentage];
    } else if (taskType == DownloadTaskTypeSetup) {
        // Show setup progress percentage
        int percentage = (int)(progress.fractionCompleted * 100);
        sizeText = [NSString stringWithFormat:@"Setting up... %d%%", percentage];
    } else if (taskType == DownloadTaskTypeComplete) {
        sizeText = @"Complete!";
    } else {
        sizeText = progress.totalUnitCount > 0 ? 
                  @"Waiting..." : 
                  [NSString stringWithFormat:@"%d%%", (int)(progress.fractionCompleted * 100)];
    }
    
    // Update detail text
    cell.detailTextLabel.text = sizeText;
    
    // For the accessory view, check if download is complete
    BOOL isComplete = progress.finished || progress.fractionCompleted >= 1.0 || taskType == DownloadTaskTypeComplete;
    
    if (isComplete) {
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
                self.statusLabel.text = fileName;
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
        int percentage = (int)(progress.fractionCompleted * 100);
        progressLabel.text = [NSString stringWithFormat:@"%d%%", percentage];
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
        
        // Handle cell progress updates on main thread
        dispatch_async(dispatch_get_main_queue(), ^{
            // Check if view controller is still active - guard against accessing deallocated objects
            if (!self.view.window) return;
            
            // Find the original file name for this progress
            NSUInteger originalIndex = [self.task.progressList indexOfObject:progress];
            if (originalIndex != NSNotFound && originalIndex < self.task.fileList.count) {
                NSString *originalFileName = self.task.fileList[originalIndex];
                
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
                    if ([self.tableView.indexPathsForVisibleRows containsObject:indexPath]) {
                        UITableViewCell *visibleCell = [self.tableView cellForRowAtIndexPath:indexPath];
                        [self updateCell:visibleCell withProgress:progress forIndexPath:indexPath];
                    }
                }
            }
        });
    } else if (context == TotalProgressObserverContext) {
        dispatch_async(dispatch_get_main_queue(), ^{
            // Check if view controller is still active - guard against accessing deallocated objects
            if (!self.view.window) return;
            
            // Update overall progress bar (handled by observed progress now)
            // and percentage label
            UILabel *percentLabel = objc_getAssociatedObject(self.overallProgressView, @"percentLabel");
            int percentage = (int)(progress.fractionCompleted * 100);
            percentLabel.text = [NSString stringWithFormat:@"%d%%", percentage];
            
            // Check if we need to update the filtered list
            [self updateFilteredFileList];
            
            // Check if file list count changed - use our own method to maintain scroll position
            if (self.fileListCount != self.filteredFileList.count) {
                [self reloadTableViewPreservingOffset];
                self.fileListCount = self.filteredFileList.count;
            }
            
            // Check for completion
            if (progress.fractionCompleted >= 1.0) {
                // Add a completion message if needed - without reloading table if possible
                if (![self.filteredFileList containsObject:@"Complete"] && ![self.task.fileList containsObject:@"Complete"]) {
                    [self.task.fileList addObject:@"Complete"];
                    [self updateFilteredFileList]; // This will add Complete to filteredFileList
                    [self reloadTableViewPreservingOffset];
                }
                self.statusLabel.text = @"Download complete";
            }
        });
    } else {
        [super observeValueForKeyPath:keyPath ofObject:object change:change context:context];
    }
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
            
            // Start observing
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

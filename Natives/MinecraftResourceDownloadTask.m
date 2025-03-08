#import <dlfcn.h>
#import <objc/runtime.h>
#import "DownloadProgressViewController.h"
#import "WFWorkflowProgressView.h"

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
@property (nonatomic, assign) BOOL isModpackInstall;
@property (nonatomic, strong) NSMutableDictionary *cellProgressMap;
@property (nonatomic, strong) NSTimer *refreshTimer;
@end

@implementation DownloadProgressViewController

- (instancetype)initWithTask:(MinecraftResourceDownloadTask *)task {
    self = [super init];
    if (self) {
        self.task = task;
        self.cellProgressMap = [NSMutableDictionary dictionary];
    }
    return self;
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
    
    // Status label
    _statusLabel = [[UILabel alloc] init];
    _statusLabel.translatesAutoresizingMaskIntoConstraints = NO;
    _statusLabel.font = [UIFont systemFontOfSize:14 weight:UIFontWeightMedium];
    _statusLabel.textColor = [UIColor labelColor];
    _statusLabel.text = @"Preparing download...";
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
    
    // Detect if this is a modpack install based on task properties
    self.isModpackInstall = NO;
    for (NSString *fileName in self.task.fileList) {
        if ([fileName hasPrefix:@"Installing"] || 
            [fileName hasPrefix:@"Extracting"] || 
            [fileName hasPrefix:@"Setting"]) {
            self.isModpackInstall = YES;
            break;
        }
    }
}

- (void)viewDidAppear:(BOOL)animated {
    [super viewDidAppear:animated];
    
    // Start observing overall progress
    [self.task.textProgress addObserver:self
            forKeyPath:@"fractionCompleted"
            options:NSKeyValueObservingOptionInitial
            context:TotalProgressObserverContext];
    
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
    [self.task.textProgress removeObserver:self forKeyPath:@"fractionCompleted"];
    
    // Invalidate refresh timer
    [self.refreshTimer invalidate];
    self.refreshTimer = nil;
    
    // Remove all observers from cell progress
    [self removeAllProgressObservers];
}

- (void)refreshProgressUI {
    // Update the UI to show the latest progress
    [self.tableView reloadData];
    
    // Check for any new items that were added
    if (self.fileListCount != self.task.fileList.count) {
        self.fileListCount = self.task.fileList.count;
        
        // Make sure the new rows are visible
        if (self.task.fileList.count > 0) {
            NSIndexPath *lastRowPath = [NSIndexPath indexPathForRow:self.task.fileList.count - 1 inSection:0];
            [self.tableView scrollToRowAtIndexPath:lastRowPath 
                                 atScrollPosition:UITableViewScrollPositionBottom 
                                         animated:YES];
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
    for (id key in self.cellProgressMap) {
        NSProgress *progress = [self.cellProgressMap objectForKey:key];
        [self removeProgressObserver:progress];
    }
    [self.cellProgressMap removeAllObjects];
}

- (void)removeProgressObserver:(NSProgress *)progress {
    if (!progress) return;
    
    @try {
        [progress removeObserver:self forKeyPath:@"fractionCompleted"];
    } @catch (NSException *exception) {
        // Ignore if not observing
        NSLog(@"[ProgressView] Warning: Failed to remove observer: %@", exception);
    }
}

- (void)observeValueForKeyPath:(NSString *)keyPath ofObject:(id)object change:(NSDictionary *)change context:(void *)context {
    NSProgress *progress = object;
    
    if (context == CellProgressObserverContext) {
        UITableViewCell *cell = objc_getAssociatedObject(progress, @"cell");
        if (!cell) return;
        
        dispatch_async(dispatch_get_main_queue(), ^{
            // Determine task type
            DownloadTaskType taskType = DownloadTaskTypeFile;
            NSString *fileName = cell.textLabel.text;
            
            if ([fileName hasPrefix:@"Extracting"]) {
                taskType = DownloadTaskTypeExtraction;
            } else if ([fileName hasPrefix:@"Setting"]) {
                taskType = DownloadTaskTypeSetup;
            } else if ([fileName isEqualToString:@"Complete"]) {
                taskType = DownloadTaskTypeComplete;
            }
            
            // Format size as MB/MB for file downloads with improved formatting
            NSString *sizeText;
            if (taskType == DownloadTaskTypeFile && progress.totalUnitCount > 0) {
                double completedMB = progress.completedUnitCount / 1024.0 / 1024.0;
                double totalMB = progress.totalUnitCount / 1024.0 / 1024.0;
                
                // Format with appropriate precision based on size
                if (totalMB < 1.0) {
                    // Use KB for small files
                    double completedKB = progress.completedUnitCount / 1024.0;
                    double totalKB = progress.totalUnitCount / 1024.0;
                    sizeText = [NSString stringWithFormat:@"%.0f KB / %.0f KB", completedKB, totalKB];
                } else if (totalMB < 10.0) {
                    // More precision for smaller files
                    sizeText = [NSString stringWithFormat:@"%.2f MB / %.2f MB", completedMB, totalMB];
                } else if (totalMB < 100.0) {
                    sizeText = [NSString stringWithFormat:@"%.1f MB / %.1f MB", completedMB, totalMB];
                } else {
                    sizeText = [NSString stringWithFormat:@"%.0f MB / %.0f MB", completedMB, totalMB];
                }
                
                // Add speed information if available
                if (progress.throughput != nil) {
                    NSNumber *throughputValue = progress.throughput;
                    double kbps = [throughputValue doubleValue] / 1024.0;
                    if (kbps > 1024) {
                        double mbps = kbps / 1024.0;
                        sizeText = [sizeText stringByAppendingFormat:@" (%.1f MB/s)", mbps];
                    } else {
                        sizeText = [sizeText stringByAppendingFormat:@" (%.0f KB/s)", kbps];
                    }
                }
                
                // Add estimated time if available
                if (progress.estimatedTimeRemaining != nil) {
                    NSTimeInterval timeRemaining = [progress.estimatedTimeRemaining doubleValue];
                    if (timeRemaining > 0 && timeRemaining < 3600) {  // Reasonable time estimate (less than an hour)
                        int minutes = (int)timeRemaining / 60;
                        int seconds = (int)timeRemaining % 60;
                        sizeText = [sizeText stringByAppendingFormat:@" - %d:%02d remaining", minutes, seconds];
                    }
                }
            } else if (taskType == DownloadTaskTypeExtraction) {
                // Show extraction progress percentage with more detail
                int percentage = (int)(progress.fractionCompleted * 100);
                sizeText = [NSString stringWithFormat:@"Extracting files... %d%%", percentage];
            } else if (taskType == DownloadTaskTypeSetup) {
                // Show setup progress percentage with more detail
                int percentage = (int)(progress.fractionCompleted * 100);
                sizeText = [NSString stringWithFormat:@"Setting up profile... %d%%", percentage];
            } else if (taskType == DownloadTaskTypeComplete) {
                sizeText = @"Complete!";
            } else {
                sizeText = progress.totalUnitCount > 0 ? 
                          @"Starting download..." : 
                          [NSString stringWithFormat:@"Preparing... %d%%", (int)(progress.fractionCompleted * 100)];
            }
            
            // Update detail text
            cell.detailTextLabel.text = sizeText;
            
            // For the accessory view, check if download is complete
            if (progress.finished || progress.fractionCompleted >= 1.0 || taskType == DownloadTaskTypeComplete) {
                // Show checkmark as accessory
                UIImageView *checkmarkView = [[UIImageView alloc] initWithFrame:CGRectMake(0, 0, 30, 30)];
                UIImage *checkmarkImage = [UIImage systemImageNamed:@"checkmark.circle.fill"];
                checkmarkView.image = checkmarkImage;
                checkmarkView.tintColor = [UIColor systemGreenColor];
                cell.accessoryView = checkmarkView;
                
                if (taskType == DownloadTaskTypeFile) {
                    cell.detailTextLabel.text = @"Download complete";
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
        });
    } else if (context == TotalProgressObserverContext) {
        dispatch_async(dispatch_get_main_queue(), ^{
            // Update title with current task description
            self.title = progress.localizedDescription ?: @"Download Progress";
            
            // Update status label with more descriptive text based on the progress
            if (self.isModpackInstall) {
                if (progress.fractionCompleted < 0.2) {
                    self.statusLabel.text = @"Preparing modpack installation...";
                } else if (progress.fractionCompleted < 0.5) {
                    self.statusLabel.text = @"Downloading modpack files...";
                } else if (progress.fractionCompleted < 0.8) {
                    self.statusLabel.text = @"Extracting modpack contents...";
                } else if (progress.fractionCompleted < 0.95) {
                    self.statusLabel.text = @"Setting up modpack profile...";
                } else {
                    self.statusLabel.text = @"Completing installation...";
                }
            } else {
                // Regular Minecraft download with better descriptions
                if (progress.fractionCompleted < 0.3) {
                    self.statusLabel.text = @"Downloading game files...";
                } else if (progress.fractionCompleted < 0.6) {
                    self.statusLabel.text = @"Downloading libraries...";
                } else if (progress.fractionCompleted < 0.9) {
                    self.statusLabel.text = @"Downloading assets...";
                } else {
                    self.statusLabel.text = @"Finalizing installation...";
                }
            }
            
            // Update overall progress bar
            self.overallProgressView.progress = progress.fractionCompleted;
            
            // Update percentage label with more information
            UILabel *percentLabel = objc_getAssociatedObject(self.overallProgressView, @"percentLabel");
            int percentage = (int)(progress.fractionCompleted * 100);
            
            // Add estimated time if available
            NSString *percentText = [NSString stringWithFormat:@"%d%%", percentage];
            if (progress.estimatedTimeRemaining != nil) {
                NSTimeInterval timeRemaining = [progress.estimatedTimeRemaining doubleValue];
                if (timeRemaining > 0 && timeRemaining < 3600) {  // Reasonable time estimate
                    int minutes = (int)timeRemaining / 60;
                    int seconds = (int)timeRemaining % 60;
                    percentText = [percentText stringByAppendingFormat:@" (%d:%02d remaining)", minutes, seconds];
                }
            }
            
            percentLabel.text = percentText;
            
            // Check if file list count changed
            if (self.fileListCount != self.task.fileList.count) {
                [self.tableView reloadData];
                
                // Auto-scroll to bottom to show newest item
                if (self.task.fileList.count > 0) {
                    NSIndexPath *lastRowPath = [NSIndexPath indexPathForRow:self.task.fileList.count - 1 inSection:0];
                    [self.tableView scrollToRowAtIndexPath:lastRowPath 
                                         atScrollPosition:UITableViewScrollPositionBottom 
                                                 animated:YES];
                }
            }
            self.fileListCount = self.task.fileList.count;
            
            // Check for completion
            if (progress.fractionCompleted >= 1.0) {
                // Add a completion message if needed
                if (![self.task.fileList containsObject:@"Complete"]) {
                    [self.task.fileList addObject:@"Complete"];
                    [self.tableView reloadData];
                    
                    // Scroll to show the completion message
                    NSIndexPath *lastRowPath = [NSIndexPath indexPathForRow:self.task.fileList.count - 1 inSection:0];
                    [self.tableView scrollToRowAtIndexPath:lastRowPath 
                                         atScrollPosition:UITableViewScrollPositionBottom 
                                                 animated:YES];
                }
            }
        });
    } else {
        [super observeValueForKeyPath:keyPath ofObject:object change:change context:context];
    }
}

#pragma mark - Table View Data Source

- (NSInteger)tableView:(UITableView *)tableView numberOfRowsInSection:(NSInteger)section {
    return self.task.fileList.count;
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

    // Get the file name and determine the type
    NSString *fileName = self.task.fileList[indexPath.row];
    DownloadTaskType taskType = DownloadTaskTypeFile;
    
    if ([fileName hasPrefix:@"Extracting"]) {
        taskType = DownloadTaskTypeExtraction;
    } else if ([fileName hasPrefix:@"Setting"]) {
        taskType = DownloadTaskTypeSetup;
    } else if ([fileName isEqualToString:@"Complete"]) {
        taskType = DownloadTaskTypeComplete;
    }
    
    // Improve filename formatting for better readability if needed
    NSString *displayName = fileName;
    if ([fileName hasPrefix:@"[Modrinth]"] || [fileName hasPrefix:@"[CurseForge]"]) {
        // Format source-specific names differently
        cell.textLabel.textColor = [UIColor systemBlueColor];
    } else {
        cell.textLabel.textColor = [UIColor labelColor];
    }
    
    // Set cell text
    cell.textLabel.text = displayName;
    
    // Get the NSProgress object for this cell
    NSProgress *progress = nil;
    
    // Look for existing progress first to avoid re-observation
    NSString *identifier = [NSString stringWithFormat:@"cell_%ld", (long)indexPath.row];
    progress = [self.cellProgressMap objectForKey:identifier];
    
    // If no existing progress, check if available from task
    if (!progress && indexPath.row < self.task.progressList.count) {
        progress = self.task.progressList[indexPath.row];
        
        if (progress) {
            // Store in our map to track observation
            [self.cellProgressMap setObject:progress forKey:identifier];
            
            // Set up relationship between cell and progress
            objc_setAssociatedObject(cell, @"progress", progress, OBJC_ASSOCIATION_ASSIGN);
            objc_setAssociatedObject(progress, @"cell", cell, OBJC_ASSOCIATION_RETAIN_NONATOMIC);
            
            // Start observing
            [progress addObserver:self
                       forKeyPath:@"fractionCompleted"
                          options:NSKeyValueObservingOptionInitial
                          context:CellProgressObserverContext];
        }
    } else if (progress) {
        // Maintain the association with the current cell
        objc_setAssociatedObject(cell, @"progress", progress, OBJC_ASSOCIATION_ASSIGN);
        objc_setAssociatedObject(progress, @"cell", cell, OBJC_ASSOCIATION_RETAIN_NONATOMIC);
    }
    
    // Configure cell based on task type and progress state with improved styling
    if (taskType == DownloadTaskTypeComplete) {
        // Show completion status
        cell.detailTextLabel.text = @"Installation complete";
        UIImageView *checkmarkView = [[UIImageView alloc] initWithFrame:CGRectMake(0, 0, 30, 30)];
        UIImage *checkmarkImage = [UIImage systemImageNamed:@"checkmark.circle.fill"];
        checkmarkView.image = checkmarkImage;
        checkmarkView.tintColor = [UIColor systemGreenColor];
        cell.accessoryView = checkmarkView;
    } else if (taskType == DownloadTaskTypeExtraction) {
        // Show activity indicator for extraction with more detailed information
        if (progress) {
            cell.detailTextLabel.text = [NSString stringWithFormat:@"Extracting files... %d%%", (int)(progress.fractionCompleted * 100)];
            
            if (progress.fractionCompleted >= 1.0) {
                UIImageView *checkmarkView = [[UIImageView alloc] initWithFrame:CGRectMake(0, 0, 30, 30)];
                UIImage *checkmarkImage = [UIImage systemImageNamed:@"checkmark.circle.fill"];
                checkmarkView.image = checkmarkImage;
                checkmarkView.tintColor = [UIColor systemGreenColor];
                cell.accessoryView = checkmarkView;
            } else {
                UIActivityIndicatorView *activityIndicator = [[UIActivityIndicatorView alloc] initWithActivityIndicatorStyle:UIActivityIndicatorViewStyleMedium];
                [activityIndicator startAnimating];
                cell.accessoryView = activityIndicator;
            }
        } else {
            cell.detailTextLabel.text = @"Preparing extraction...";
            UIActivityIndicatorView *activityIndicator = [[UIActivityIndicatorView alloc] initWithActivityIndicatorStyle:UIActivityIndicatorViewStyleMedium];
            [activityIndicator startAnimating];
            cell.accessoryView = activityIndicator;
        }
    } else if (taskType == DownloadTaskTypeSetup) {
        // Show activity indicator for setup with more detailed information
        if (progress) {
            cell.detailTextLabel.text = [NSString stringWithFormat:@"Setting up profile... %d%%", (int)(progress.fractionCompleted * 100)];
            
            if (progress.fractionCompleted >= 1.0) {
                UIImageView *checkmarkView = [[UIImageView alloc] initWithFrame:CGRectMake(0, 0, 30, 30)];
                UIImage *checkmarkImage = [UIImage systemImageNamed:@"checkmark.circle.fill"];
                checkmarkView.image = checkmarkImage;
                checkmarkView.tintColor = [UIColor systemGreenColor];
                cell.accessoryView = checkmarkView;
            } else {
                UIActivityIndicatorView *activityIndicator = [[UIActivityIndicatorView alloc] initWithActivityIndicatorStyle:UIActivityIndicatorViewStyleMedium];
                [activityIndicator startAnimating];
                cell.accessoryView = activityIndicator;
            }
        } else {
            cell.detailTextLabel.text = @"Preparing setup...";
            UIActivityIndicatorView *activityIndicator = [[UIActivityIndicatorView alloc] initWithActivityIndicatorStyle:UIActivityIndicatorViewStyleMedium];
            [activityIndicator startAnimating];
            cell.accessoryView = activityIndicator;
        }
    } else {
        // Regular file download with improved information
        if (progress) {
            // Update label with progress percentage
            UILabel *progressLabel = (UILabel *)cell.accessoryView;
            if (![progressLabel isKindOfClass:[UILabel class]]) {
                progressLabel = [[UILabel alloc] initWithFrame:CGRectMake(0, 0, 80, 30)];
                progressLabel.textAlignment = NSTextAlignmentRight;
                progressLabel.font = [UIFont systemFontOfSize:14];
                cell.accessoryView = progressLabel;
            }
            
            if (progress.finished || progress.fractionCompleted >= 1.0) {
                // Show checkmark for completed downloads
                UIImageView *checkmarkView = [[UIImageView alloc] initWithFrame:CGRectMake(0, 0, 30, 30)];
                UIImage *checkmarkImage = [UIImage systemImageNamed:@"checkmark.circle.fill"];
                checkmarkView.image = checkmarkImage;
                checkmarkView.tintColor = [UIColor systemGreenColor];
                cell.accessoryView = checkmarkView;
                cell.detailTextLabel.text = @"Download complete";
            } else {
                // Update percentage display
                int percentage = (int)(progress.fractionCompleted * 100);
                progressLabel.text = [NSString stringWithFormat:@"%d%%", percentage];
                
                // Show size information if available with more readable formatting
                if (progress.totalUnitCount > 0) {
                    double completedMB = progress.completedUnitCount / 1024.0 / 1024.0;
                    double totalMB = progress.totalUnitCount / 1024.0 / 1024.0;
                    
                    // Format with appropriate precision based on size
                    NSString *sizeText;
                    if (totalMB < 1.0) {
                        // Use KB for small files
                        double completedKB = progress.completedUnitCount / 1024.0;
                        double totalKB = progress.totalUnitCount / 1024.0;
                        sizeText = [NSString stringWithFormat:@"%.0f KB / %.0f KB", completedKB, totalKB];
                    } else if (totalMB < 10.0) {
                        // More precision for smaller files
                        sizeText = [NSString stringWithFormat:@"%.2f MB / %.2f MB", completedMB, totalMB];
                    } else if (totalMB < 100.0) {
                        sizeText = [NSString stringWithFormat:@"%.1f MB / %.1f MB", completedMB, totalMB];
                    } else {
                        sizeText = [NSString stringWithFormat:@"%.0f MB / %.0f MB", completedMB, totalMB];
                    }
                    
                    // Add estimated time if available
                    if (progress.estimatedTimeRemaining != nil) {
                        NSTimeInterval timeRemaining = [progress.estimatedTimeRemaining doubleValue];
                        if (timeRemaining > 0 && timeRemaining < 3600) {  // Reasonable time estimate (less than an hour)
                            int minutes = (int)timeRemaining / 60;
                            int seconds = (int)timeRemaining % 60;
                            sizeText = [sizeText stringByAppendingFormat:@" - %d:%02d remaining", minutes, seconds];
                        }
                    }
                    
                    cell.detailTextLabel.text = sizeText;
                } else {
                    // For indeterminate progress
                    cell.detailTextLabel.text = @"Downloading...";
                }
            }
        } else {
            // No progress yet
            cell.detailTextLabel.text = @"Waiting to start...";
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

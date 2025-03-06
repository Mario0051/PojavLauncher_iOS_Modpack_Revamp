#import <dlfcn.h>
#import <objc/runtime.h>
#import "DownloadProgressViewController.h"
#import "WFWorkflowProgressView.h"

static void *CellProgressObserverContext = &CellProgressObserverContext;
static void *TotalProgressObserverContext = &TotalProgressObserverContext;

// New enum for task types
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
@end

@implementation DownloadProgressViewController

- (instancetype)initWithTask:(MinecraftResourceDownloadTask *)task {
    self = [super init];
    self.task = task;
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
    
    // Add overall progress header with proper layout
    CGFloat headerHeight = 100;
    UIView *headerView = [[UIView alloc] initWithFrame:CGRectMake(0, 0, self.tableView.bounds.size.width, headerHeight)];
    headerView.autoresizingMask = UIViewAutoresizingFlexibleWidth;
    headerView.backgroundColor = [UIColor systemBackgroundColor];
    
    // Status label - positioned at the top with proper margins
    _statusLabel = [[UILabel alloc] init];
    _statusLabel.frame = CGRectMake(16, 10, headerView.bounds.size.width - 32, 20);
    _statusLabel.autoresizingMask = UIViewAutoresizingFlexibleWidth;
    _statusLabel.font = [UIFont systemFontOfSize:14 weight:UIFontWeightMedium];
    _statusLabel.textColor = [UIColor labelColor];
    _statusLabel.text = @"Preparing download...";
    [headerView addSubview:_statusLabel];
    
    // Progress view - positioned below the status label with proper height
    // Note: UIProgressView has a fixed height of 2 points (4 for .bar style)
    _overallProgressView = [[UIProgressView alloc] initWithProgressViewStyle:UIProgressViewStyleDefault];
    _overallProgressView.frame = CGRectMake(16, 40, headerView.bounds.size.width - 32, 2); // Only width matters for UIProgressView
    _overallProgressView.autoresizingMask = UIViewAutoresizingFlexibleWidth;
    _overallProgressView.progress = 0.0;
    _overallProgressView.progressTintColor = [UIColor systemBlueColor];
    _overallProgressView.trackTintColor = [UIColor systemFillColor];
    _overallProgressView.layer.cornerRadius = 1.0; // Optional: rounded corners
    _overallProgressView.clipsToBounds = YES;      // Required for corner radius
    [headerView addSubview:_overallProgressView];
    
    // Percentage label - positioned below the progress view
    UILabel *percentLabel = [[UILabel alloc] init];
    percentLabel.frame = CGRectMake(16, 50, headerView.bounds.size.width - 32, 20);
    percentLabel.autoresizingMask = UIViewAutoresizingFlexibleWidth;
    percentLabel.font = [UIFont systemFontOfSize:12];
    percentLabel.textColor = [UIColor secondaryLabelColor];
    percentLabel.textAlignment = NSTextAlignmentRight;
    percentLabel.text = @"0%";
    objc_setAssociatedObject(_overallProgressView, @"percentLabel", percentLabel, OBJC_ASSOCIATION_RETAIN_NONATOMIC);
    [headerView addSubview:percentLabel];
    
    // Add a separator line at the bottom of the header
    UIView *separatorLine = [[UIView alloc] init];
    separatorLine.frame = CGRectMake(0, headerHeight - 0.5, headerView.bounds.size.width, 0.5);
    separatorLine.autoresizingMask = UIViewAutoresizingFlexibleWidth;
    separatorLine.backgroundColor = [UIColor separatorColor];
    [headerView addSubview:separatorLine];
    
    self.tableView.tableHeaderView = headerView;
    
    // Make sure the header view has a valid size
    [headerView setNeedsLayout];
    [headerView layoutIfNeeded];
    CGSize headerSize = [headerView systemLayoutSizeFittingSize:UILayoutFittingCompressedSize];
    CGRect headerFrame = headerView.frame;
    headerFrame.size.height = headerHeight;
    headerView.frame = headerFrame;
    self.tableView.tableHeaderView = headerView;
    
    // Detect if this is a modpack install based on initial file list
    self.isModpackInstall = NO;
    for (NSString *fileName in self.task.fileList) {
        if ([fileName hasPrefix:@"Installing"] || [fileName hasPrefix:@"Extracting"] || [fileName hasPrefix:@"Setting"]) {
            self.isModpackInstall = YES;
            break;
        }
    }
}

- (void)viewDidAppear:(BOOL)animated {
    [super viewDidAppear:animated];
    
    [self.task.textProgress addObserver:self
            forKeyPath:@"fractionCompleted"
            options:NSKeyValueObservingOptionInitial
            context:TotalProgressObserverContext];
}

- (void)viewDidDisappear:(BOOL)animated {
    [super viewDidDisappear:animated];
    
    [self.task.textProgress removeObserver:self forKeyPath:@"fractionCompleted"];
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
                sizeText = @"Extracting files...";
            } else if (taskType == DownloadTaskTypeSetup) {
                sizeText = @"Setting up profile...";
            } else if (taskType == DownloadTaskTypeComplete) {
                sizeText = @"Complete!";
            } else {
                sizeText = @"Pending...";
            }
            
            // Update detail text
            cell.detailTextLabel.text = sizeText;
            
            // For the accessory view, check if download is complete
            if (progress.finished || taskType == DownloadTaskTypeComplete) {
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
                UIActivityIndicatorView *activityIndicator = [[UIActivityIndicatorView alloc] initWithActivityIndicatorStyle:UIActivityIndicatorViewStyleMedium];
                [activityIndicator startAnimating];
                cell.accessoryView = activityIndicator;
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
            self.title = progress.localizedDescription;
            
            // Update status label with more descriptive text
            if (self.isModpackInstall) {
                if (progress.fractionCompleted < 0.7) {
                    self.statusLabel.text = @"Downloading modpack files...";
                } else if (progress.fractionCompleted < 0.9) {
                    self.statusLabel.text = @"Extracting modpack contents...";
                } else {
                    self.statusLabel.text = @"Setting up modpack profile...";
                }
            } else {
                self.statusLabel.text = progress.localizedDescription ?: @"Downloading files...";
            }
            
            // Update overall progress bar
            self.overallProgressView.progress = progress.fractionCompleted;
            
            // Update percentage label
            UILabel *percentLabel = objc_getAssociatedObject(self.overallProgressView, @"percentLabel");
            int percentage = (int)(progress.fractionCompleted * 100);
            percentLabel.text = [NSString stringWithFormat:@"%d%%", percentage];
            
            // Reload the table if file list count changed
            if (self.fileListCount != self.task.fileList.count) {
                [self.tableView reloadData];
            }
            self.fileListCount = self.task.fileList.count;
            
            // Check for completion
            if (progress.fractionCompleted >= 1.0) {
                // Add a completion message if needed
                if (![self.task.fileList containsObject:@"Complete"]) {
                    [self.task.fileList addObject:@"Complete"];
                    [self.tableView reloadData];
                }
            }
        });
    } else {
        [super observeValueForKeyPath:keyPath ofObject:object change:change context:context];
    }
}

- (NSInteger)tableView:(UITableView *)tableView numberOfRowsInSection:(NSInteger)section
{
    return self.task.fileList.count;
}

- (UITableViewCell *)tableView:(UITableView *)tableView cellForRowAtIndexPath:(NSIndexPath *)indexPath
{
    UITableViewCell *cell = [tableView dequeueReusableCellWithIdentifier:@"cell"];

    if (cell == nil) {
        cell = [[UITableViewCell alloc] initWithStyle:UITableViewCellStyleSubtitle reuseIdentifier:@"cell"];
        cell.textLabel.font = [UIFont systemFontOfSize:14];
        cell.detailTextLabel.font = [UIFont systemFontOfSize:12];
        cell.detailTextLabel.textColor = [UIColor secondaryLabelColor];
        
        // Create progress label instead of WFWorkflowProgressView
        UILabel *progressLabel = [[UILabel alloc] initWithFrame:CGRectMake(0, 0, 80, 30)];
        progressLabel.textAlignment = NSTextAlignmentRight;
        progressLabel.font = [UIFont systemFontOfSize:14];
        progressLabel.text = @"0%";
        cell.accessoryView = progressLabel;
    }

    // Unset the last cell displaying the progress
    NSProgress *lastProgress = objc_getAssociatedObject(cell, @"progress");
    if (lastProgress) {
        objc_setAssociatedObject(lastProgress, @"cell", nil, OBJC_ASSOCIATION_ASSIGN);
        @try {
            [lastProgress removeObserver:self forKeyPath:@"fractionCompleted"];
        } @catch(id anException) {}
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
    
    // Set cell text
    cell.textLabel.text = fileName;
    
    // Initialize cell style based on task type
    if (taskType == DownloadTaskTypeComplete) {
        // Show completion status
        cell.detailTextLabel.text = @"Installation complete";
        UIImageView *checkmarkView = [[UIImageView alloc] initWithFrame:CGRectMake(0, 0, 30, 30)];
        UIImage *checkmarkImage = [UIImage systemImageNamed:@"checkmark.circle.fill"];
        checkmarkView.image = checkmarkImage;
        checkmarkView.tintColor = [UIColor systemGreenColor];
        cell.accessoryView = checkmarkView;
        return cell;
    } else if (taskType == DownloadTaskTypeExtraction || taskType == DownloadTaskTypeSetup) {
        // Show activity indicator for extraction and setup stages
        cell.detailTextLabel.text = (taskType == DownloadTaskTypeExtraction) ? 
                                   @"Extracting files..." : @"Setting up profile...";
        
        UIActivityIndicatorView *activityIndicator = [[UIActivityIndicatorView alloc] initWithActivityIndicatorStyle:UIActivityIndicatorViewStyleMedium];
        [activityIndicator startAnimating];
        cell.accessoryView = activityIndicator;
        return cell;
    }

    // For file downloads, get progress and observe it
    NSProgress *progress = indexPath.row < self.task.progressList.count ? 
                          self.task.progressList[indexPath.row] : nil;
    
    if (!progress) {
        cell.detailTextLabel.text = @"Pending...";
        return cell;
    }
    
    objc_setAssociatedObject(cell, @"progress", progress, OBJC_ASSOCIATION_ASSIGN);
    objc_setAssociatedObject(progress, @"cell", cell, OBJC_ASSOCIATION_RETAIN_NONATOMIC);
    [progress addObserver:self
        forKeyPath:@"fractionCompleted"
        options:NSKeyValueObservingOptionInitial
        context:CellProgressObserverContext];

    // Initialize accessory based on progress state
    if (progress.finished) {
        // Show checkmark for completed downloads
        UIImageView *checkmarkView = [[UIImageView alloc] initWithFrame:CGRectMake(0, 0, 30, 30)];
        UIImage *checkmarkImage = [UIImage systemImageNamed:@"checkmark.circle.fill"];
        checkmarkView.image = checkmarkImage;
        checkmarkView.tintColor = [UIColor systemGreenColor];
        cell.accessoryView = checkmarkView;
        cell.detailTextLabel.text = @"Download complete";
    } else {
        // Ensure progress label is set up correctly
        UILabel *progressLabel = (UILabel *)cell.accessoryView;
        if (![progressLabel isKindOfClass:[UILabel class]]) {
            progressLabel = [[UILabel alloc] initWithFrame:CGRectMake(0, 0, 80, 30)];
            progressLabel.textAlignment = NSTextAlignmentRight;
            progressLabel.font = [UIFont systemFontOfSize:14];
            cell.accessoryView = progressLabel;
        }
        
        // Set initial progress text
        int percentage = (int)(progress.fractionCompleted * 100);
        progressLabel.text = [NSString stringWithFormat:@"%d%%", percentage];
        
        // Format size as MB/MB for detail text
        if (progress.totalUnitCount > 0) {
            double completedMB = progress.completedUnitCount / 1024.0 / 1024.0;
            double totalMB = progress.totalUnitCount / 1024.0 / 1024.0;
            
            // Format with appropriate precision based on size
            if (totalMB < 1.0) {
                // Use KB for small files
                double completedKB = progress.completedUnitCount / 1024.0;
                double totalKB = progress.totalUnitCount / 1024.0;
                cell.detailTextLabel.text = [NSString stringWithFormat:@"%.0fKB/%.0fKB", completedKB, totalKB];
            } else if (totalMB < 10.0) {
                // More precision for smaller files
                cell.detailTextLabel.text = [NSString stringWithFormat:@"%.2fMB/%.2fMB", completedMB, totalMB];
            } else if (totalMB < 100.0) {
                cell.detailTextLabel.text = [NSString stringWithFormat:@"%.1fMB/%.1fMB", completedMB, totalMB];
            } else {
                cell.detailTextLabel.text = [NSString stringWithFormat:@"%.0fMB/%.0fMB", completedMB, totalMB];
            }
        } else {
            cell.detailTextLabel.text = @"Pending...";
        }
    }

    return cell;
}

@end

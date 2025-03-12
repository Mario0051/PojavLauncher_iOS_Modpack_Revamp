#import <dlfcn.h>
#import <objc/runtime.h>
#import "DownloadProgressViewController.h"
#import "WFWorkflowProgressView.h"
#import "utils.h"

static void *CellProgressObserverContext = &CellProgressObserverContext;
static void *TotalProgressObserverContext = &TotalProgressObserverContext;

@interface DownloadProgressViewController ()
@property NSInteger fileListCount;
@property (nonatomic, strong) UILabel *statusLabel;
@property (nonatomic, strong) UIProgressView *overallProgressView;
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
    self.navigationItem.rightBarButtonItem = [[UIBarButtonItem alloc] initWithBarButtonSystemItem:UIBarButtonSystemItemClose target:self action:@selector(actionClose)];
    self.tableView.allowsSelection = NO;

    // Load WFWorkflowProgressView
    dlopen("/System/Library/PrivateFrameworks/WorkflowUIServices.framework/WorkflowUIServices", RTLD_GLOBAL);
    
    // Create header view for overall progress
    UIView *headerView = [[UIView alloc] initWithFrame:CGRectMake(0, 0, self.tableView.bounds.size.width, 80)];
    
    // Status label
    self.statusLabel = [[UILabel alloc] init];
    self.statusLabel.translatesAutoresizingMaskIntoConstraints = NO;
    self.statusLabel.font = [UIFont systemFontOfSize:14 weight:UIFontWeightMedium];
    self.statusLabel.textColor = [UIColor labelColor];
    self.statusLabel.text = @"Downloading...";
    [headerView addSubview:self.statusLabel];
    
    // Progress bar
    self.overallProgressView = [[UIProgressView alloc] initWithProgressViewStyle:UIProgressViewStyleDefault];
    self.overallProgressView.translatesAutoresizingMaskIntoConstraints = NO;
    self.overallProgressView.progress = 0.0;
    [headerView addSubview:self.overallProgressView];
    
    // Percentage label
    UILabel *percentLabel = [[UILabel alloc] init];
    percentLabel.translatesAutoresizingMaskIntoConstraints = NO;
    percentLabel.font = [UIFont systemFontOfSize:12];
    percentLabel.textColor = [UIColor secondaryLabelColor];
    percentLabel.text = @"0%";
    percentLabel.textAlignment = NSTextAlignmentRight;
    objc_setAssociatedObject(self.overallProgressView, @"percentLabel", percentLabel, OBJC_ASSOCIATION_RETAIN_NONATOMIC);
    [headerView addSubview:percentLabel];
    
    // Setup constraints
    [NSLayoutConstraint activateConstraints:@[
        [self.statusLabel.topAnchor constraintEqualToAnchor:headerView.topAnchor constant:15],
        [self.statusLabel.leadingAnchor constraintEqualToAnchor:headerView.leadingAnchor constant:16],
        [self.statusLabel.trailingAnchor constraintEqualToAnchor:headerView.trailingAnchor constant:-16],
        
        [self.overallProgressView.topAnchor constraintEqualToAnchor:self.statusLabel.bottomAnchor constant:10],
        [self.overallProgressView.leadingAnchor constraintEqualToAnchor:headerView.leadingAnchor constant:16],
        [self.overallProgressView.trailingAnchor constraintEqualToAnchor:headerView.trailingAnchor constant:-16],
        
        [percentLabel.topAnchor constraintEqualToAnchor:self.overallProgressView.bottomAnchor constant:5],
        [percentLabel.trailingAnchor constraintEqualToAnchor:headerView.trailingAnchor constant:-16],
        [percentLabel.bottomAnchor constraintEqualToAnchor:headerView.bottomAnchor constant:-10]
    ]];
    
    self.tableView.tableHeaderView = headerView;
}

- (void)viewDidAppear:(BOOL)animated {
    [super viewDidAppear:animated];
    
    [self.task.textProgress addObserver:self
            forKeyPath:@"fractionCompleted"
            options:NSKeyValueObservingOptionInitial
            context:TotalProgressObserverContext];
    
    // Setup refresh timer for UI updates
    self.refreshTimer = [NSTimer scheduledTimerWithTimeInterval:0.5 
                                                        target:self 
                                                      selector:@selector(refreshProgressUI) 
                                                      userInfo:nil 
                                                       repeats:YES];
}

- (void)viewDidDisappear:(BOOL)animated {
    [super viewDidDisappear:animated];
    
    [self.task.textProgress removeObserver:self forKeyPath:@"fractionCompleted"];
    
    // Invalidate timer
    [self.refreshTimer invalidate];
    self.refreshTimer = nil;
    
    // Clean up observers
    [self removeAllProgressObservers];
}

- (void)refreshProgressUI {
    // Update UI to show latest progress
    if (self.fileListCount != self.task.fileList.count) {
        [self.tableView reloadData];
        self.fileListCount = self.task.fileList.count;
    }
    
    // Check for completion
    BOOL isComplete = self.task.progress.fractionCompleted >= 1.0 || self.task.progress.finished;
    if (isComplete) {
        self.statusLabel.text = @"Download Complete";
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
    // Clean up all KVO observers to prevent leaks
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
        // Observer might not exist, ignore
        NSLog(@"Warning: Failed to remove observer: %@", exception);
    }
}

- (void)observeValueForKeyPath:(NSString *)keyPath ofObject:(id)object change:(NSDictionary *)change context:(void *)context {
    NSProgress *progress = object;
    if (context == CellProgressObserverContext) {
        UITableViewCell *cell = objc_getAssociatedObject(progress, @"cell");
        if (!cell) return;
        dispatch_async(dispatch_get_main_queue(), ^{
            // Determine if this is a special task
            NSString *fileName = cell.textLabel.text;
            BOOL isExtraction = [fileName hasPrefix:@"Extracting"];
            BOOL isSetup = [fileName hasPrefix:@"Setting"];
            BOOL isComplete = [fileName isEqualToString:@"Complete"];
            
            // Format file size for display
            if (!isExtraction && !isSetup && !isComplete && progress.totalUnitCount > 0) {
                double completedMB = progress.completedUnitCount / 1024.0 / 1024.0;
                double totalMB = progress.totalUnitCount / 1024.0 / 1024.0;
                
                if (totalMB < 1.0) {
                    // Show in KB for small files
                    double completedKB = progress.completedUnitCount / 1024.0;
                    double totalKB = progress.totalUnitCount / 1024.0;
                    cell.detailTextLabel.text = [NSString stringWithFormat:@"%.0fKB/%.0fKB", completedKB, totalKB];
                } else if (totalMB < 10) {
                    cell.detailTextLabel.text = [NSString stringWithFormat:@"%.2fMB/%.2fMB", completedMB, totalMB];
                } else {
                    cell.detailTextLabel.text = [NSString stringWithFormat:@"%.1fMB/%.1fMB", completedMB, totalMB];
                }
            } else {
                cell.detailTextLabel.text = progress.localizedAdditionalDescription;
            }
            
            // Update progress indicator
            WFWorkflowProgressView *progressView = (id)cell.accessoryView;
            progressView.fractionCompleted = progress.fractionCompleted;
            
            if (progress.finished || progress.fractionCompleted >= 1.0) {
                [progressView transitionCompletedLayerToVisible:YES animated:YES haptic:NO];
            }
        });
    } else if (context == TotalProgressObserverContext) {
        dispatch_async(dispatch_get_main_queue(), ^{
            self.title = progress.localizedDescription;
            
            // Update overall progress bar
            self.overallProgressView.progress = progress.fractionCompleted;
            
            // Update percentage label
            UILabel *percentLabel = objc_getAssociatedObject(self.overallProgressView, @"percentLabel");
            int percentage = (int)(progress.fractionCompleted * 100);
            percentLabel.text = [NSString stringWithFormat:@"%d%%", percentage];
            
            // Update status label based on progress
            if (progress.fractionCompleted < 0.3) {
                self.statusLabel.text = @"Downloading files...";
            } else if (progress.fractionCompleted < 0.7) {
                self.statusLabel.text = @"Processing files...";
            } else if (progress.fractionCompleted < 1.0) {
                self.statusLabel.text = @"Finalizing...";
            } else {
                self.statusLabel.text = @"Download Complete";
            }
            
            if (self.fileListCount != self.task.fileList.count) {
                [self.tableView reloadData];
            }
            self.fileListCount = self.task.fileList.count;
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
    UITableViewCell *cell = [tableView dequeueReusableCellWithIdentifier:@"cell"];

    if (cell == nil) {
        cell = [[UITableViewCell alloc] initWithStyle:UITableViewCellStyleSubtitle reuseIdentifier:@"cell"];
        WFWorkflowProgressView *progressView = [[NSClassFromString(@"WFWorkflowProgressView") alloc] initWithFrame:CGRectMake(0, 0, 30, 30)];
        progressView.resolvedTintColor = self.view.tintColor;
        progressView.stopSize = 0;
        cell.accessoryView = progressView;
    }

    // Unset the last cell displaying the progress
    NSProgress *lastProgress = objc_getAssociatedObject(cell, @"progress");
    if (lastProgress) {
        objc_setAssociatedObject(lastProgress, @"cell", nil, OBJC_ASSOCIATION_ASSIGN);
        [self removeProgressObserver:lastProgress];
    }

    // Set new progress
    NSString *identifier = [NSString stringWithFormat:@"cell_%ld", (long)indexPath.row];
    NSProgress *progress = nil;
    
    // Check if we have the progress in our map
    progress = [self.cellProgressMap objectForKey:identifier];
    
    // If not, get from task
    if (!progress && indexPath.row < self.task.progressList.count) {
        progress = self.task.progressList[indexPath.row];
        
        if (progress) {
            // Store in our map to track observation
            [self.cellProgressMap setObject:progress forKey:identifier];
        }
    }
    
    if (progress) {
        objc_setAssociatedObject(cell, @"progress", progress, OBJC_ASSOCIATION_ASSIGN);
        objc_setAssociatedObject(progress, @"cell", cell, OBJC_ASSOCIATION_RETAIN_NONATOMIC);
        [progress addObserver:self
            forKeyPath:@"fractionCompleted"
            options:NSKeyValueObservingOptionInitial
            context:CellProgressObserverContext];

        WFWorkflowProgressView *progressView = (id)cell.accessoryView;
        if (lastProgress.finished) {
            [progressView reset];
        }
        progressView.fractionCompleted = progress.fractionCompleted;
        [progressView transitionCompletedLayerToVisible:progress.finished animated:NO haptic:NO];
        [progressView transitionRunningLayerToVisible:!progress.finished animated:NO];
    }

    // Set cell text
    if (indexPath.row < self.task.fileList.count) {
        cell.textLabel.text = self.task.fileList[indexPath.row];
        
        // If we have progress info, set detail text
        if (progress) {
            NSString *fileName = cell.textLabel.text;
            BOOL isExtraction = [fileName hasPrefix:@"Extracting"];
            BOOL isSetup = [fileName hasPrefix:@"Setting"];
            BOOL isComplete = [fileName isEqualToString:@"Complete"];
            
            // Format file size for display
            if (!isExtraction && !isSetup && !isComplete && progress.totalUnitCount > 0) {
                double completedMB = progress.completedUnitCount / 1024.0 / 1024.0;
                double totalMB = progress.totalUnitCount / 1024.0 / 1024.0;
                
                if (totalMB < 1.0) {
                    // Show in KB for small files
                    double completedKB = progress.completedUnitCount / 1024.0;
                    double totalKB = progress.totalUnitCount / 1024.0;
                    cell.detailTextLabel.text = [NSString stringWithFormat:@"%.0fKB/%.0fKB", completedKB, totalKB];
                } else if (totalMB < 10) {
                    cell.detailTextLabel.text = [NSString stringWithFormat:@"%.2fMB/%.2fMB", completedMB, totalMB];
                } else {
                    cell.detailTextLabel.text = [NSString stringWithFormat:@"%.1fMB/%.1fMB", completedMB, totalMB];
                }
            } else {
                cell.detailTextLabel.text = progress.localizedAdditionalDescription;
            }
        } else {
            cell.detailTextLabel.text = @"Waiting...";
        }
    }
    
    return cell;
}

@end

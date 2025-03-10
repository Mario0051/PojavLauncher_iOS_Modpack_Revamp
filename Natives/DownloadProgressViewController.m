#import <dlfcn.h>
#import <objc/runtime.h>
#import "DownloadProgressViewController.h"
#import "WFWorkflowProgressView.h"

static void *CellProgressObserverContext = &CellProgressObserverContext;
static void *TotalProgressObserverContext = &TotalProgressObserverContext;

@interface DownloadProgressViewController ()
@property NSInteger fileListCount;
@end

@implementation DownloadProgressViewController

- (instancetype)initWithTask:(MinecraftResourceDownloadTask *)task {
    self = [super init];
    self.task = task;
    return self;
}

- (void)viewDidLoad {
    [super viewDidLoad];
    self.navigationItem.rightBarButtonItem = [[UIBarButtonItem alloc] initWithBarButtonSystemItem:UIBarButtonSystemItemClose target:self action:@selector(actionClose)];
    self.tableView.allowsSelection = NO;
    
    // Add a refresh button to update the list if needed
    UIRefreshControl *refreshControl = [[UIRefreshControl alloc] init];
    [refreshControl addTarget:self action:@selector(refreshTableView) forControlEvents:UIControlEventValueChanged];
    self.tableView.refreshControl = refreshControl;
    
    // Set a more descriptive title
    self.title = @"Download Progress";
}

- (void)refreshTableView {
    [self.tableView reloadData];
    [self.tableView.refreshControl endRefreshing];
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
    [self.navigationController dismissViewControllerAnimated:YES completion:nil];
}

- (void)observeValueForKeyPath:(NSString *)keyPath ofObject:(id)object change:(NSDictionary *)change context:(void *)context {
    NSProgress *progress = object;
    if (context == CellProgressObserverContext) {
        UITableViewCell *cell = objc_getAssociatedObject(progress, @"cell");
        if (!cell) return;
        dispatch_async(dispatch_get_main_queue(), ^{
            // Calculate progress details for display
            NSUInteger completed = progress.completedUnitCount;
            NSUInteger total = progress.totalUnitCount;
            float fraction = progress.fractionCompleted;
            
            // Format sizes in MB with 2 decimal places
            float completedMB = completed / 1048576.0; // Convert bytes to MB
            float totalMB = total / 1048576.0;
            
            NSString *progressText;
            UIImageView *statusImageView = (UIImageView *)cell.accessoryView;
            
            if (progress.finished) {
                // Show "Done" when download is complete
                progressText = [NSString stringWithFormat:@"Done (%.2f MB)", totalMB];
                
                // Replace with checkmark
                if (![statusImageView.image.accessibilityIdentifier isEqualToString:@"checkmark"]) {
                    UIImage *checkmarkImage = [UIImage systemImageNamed:@"checkmark.circle.fill"];
                    checkmarkImage.accessibilityIdentifier = @"checkmark";
                    statusImageView.image = checkmarkImage;
                    statusImageView.tintColor = [UIColor systemGreenColor];
                }
            } else {
                // Show progress as "X.XX MB / Y.YY MB"
                progressText = [NSString stringWithFormat:@"%.2f MB / %.2f MB (%.0f%%)", 
                               completedMB, totalMB, fraction * 100];
                
                // Update download indicator if needed
                if (![statusImageView.image.accessibilityIdentifier isEqualToString:@"downloading"]) {
                    UIImage *downloadImage = [UIImage systemImageNamed:@"arrow.down.circle"];
                    downloadImage.accessibilityIdentifier = @"downloading";
                    statusImageView.image = downloadImage;
                    statusImageView.tintColor = self.view.tintColor;
                }
            }
            
            cell.detailTextLabel.text = progressText;
        });
    } else if (context == TotalProgressObserverContext) {
        dispatch_async(dispatch_get_main_queue(), ^{
            // Ensure we're updating the title on the main thread
            NSString *currentTask = @"Downloading";
            if (self.task.currentStage) {
                currentTask = self.task.currentStage;
            }
            
            // Format the title to show current task and percentage
            if (progress.fractionCompleted < 1.0) {
                self.title = [NSString stringWithFormat:@"%@ - %.0f%%", 
                             currentTask, progress.fractionCompleted * 100];
                
                // Update navigation bar progress indicator if available
                if (@available(iOS 15.0, *)) {
                    UINavigationBarAppearance *appearance = [UINavigationBarAppearance new];
                    [appearance configureWithDefaultBackground];
                    self.navigationItem.scrollEdgeAppearance = appearance;
                    self.navigationItem.standardAppearance = appearance;
                }
            } else {
                self.title = @"Download Complete";
            }
            
            // Check if we need to reload the table
            if (self.fileListCount != self.task.fileList.count) {
                [self.tableView reloadData];
            }
            self.fileListCount = self.task.fileList.count;
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
        
        // Create status image view instead of progress circle
        UIImageView *statusImageView = [[UIImageView alloc] initWithFrame:CGRectMake(0, 0, 30, 30)];
        statusImageView.contentMode = UIViewContentModeScaleAspectFit;
        statusImageView.tintColor = self.view.tintColor;
        
        // Default to downloading icon
        UIImage *downloadImage = [UIImage systemImageNamed:@"arrow.down.circle"];
        downloadImage.accessibilityIdentifier = @"downloading";
        statusImageView.image = downloadImage;
        
        cell.accessoryView = statusImageView;
    }

    // Unset the last cell displaying the progress
    NSProgress *lastProgress = objc_getAssociatedObject(cell, @"progress");
    if (lastProgress) {
        objc_setAssociatedObject(lastProgress, @"cell", nil, OBJC_ASSOCIATION_ASSIGN);
        @try {
            [lastProgress removeObserver:self forKeyPath:@"fractionCompleted"];
        } @catch(id anException) {}
    }

    NSProgress *progress = self.task.progressList[indexPath.row];
    objc_setAssociatedObject(cell, @"progress", progress, OBJC_ASSOCIATION_ASSIGN);
    objc_setAssociatedObject(progress, @"cell", cell, OBJC_ASSOCIATION_RETAIN_NONATOMIC);
    [progress addObserver:self
        forKeyPath:@"fractionCompleted"
        options:NSKeyValueObservingOptionInitial
        context:CellProgressObserverContext];

    // Update image based on download status
    UIImageView *statusImageView = (UIImageView *)cell.accessoryView;
    if (progress.finished) {
        UIImage *checkmarkImage = [UIImage systemImageNamed:@"checkmark.circle.fill"];
        checkmarkImage.accessibilityIdentifier = @"checkmark";
        statusImageView.image = checkmarkImage;
        statusImageView.tintColor = [UIColor systemGreenColor];
    } else {
        UIImage *downloadImage = [UIImage systemImageNamed:@"arrow.down.circle"];
        downloadImage.accessibilityIdentifier = @"downloading";
        statusImageView.image = downloadImage;
        statusImageView.tintColor = self.view.tintColor;
    }

    cell.textLabel.text = self.task.fileList[indexPath.row];
    
    // Initial progress text
    float completedMB = progress.completedUnitCount / 1048576.0;
    float totalMB = progress.totalUnitCount / 1048576.0;
    
    if (progress.finished) {
        cell.detailTextLabel.text = [NSString stringWithFormat:@"Done (%.2f MB)", totalMB];
    } else {
        cell.detailTextLabel.text = [NSString stringWithFormat:@"%.2f MB / %.2f MB (%.0f%%)", 
                                   completedMB, totalMB, progress.fractionCompleted * 100];
    }
    
    return cell;
}

@end

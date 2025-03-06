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

- (void)loadView {
    [super loadView];
    self.navigationItem.rightBarButtonItem = [[UIBarButtonItem alloc] initWithBarButtonSystemItem:UIBarButtonSystemItemClose target:self action:@selector(actionClose)];
    self.tableView.allowsSelection = NO;
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
            // Format size as MB/MB
            NSString *sizeText;
            if (progress.totalUnitCount > 0) {
                double completedMB = progress.completedUnitCount / 1024.0 / 1024.0;
                double totalMB = progress.totalUnitCount / 1024.0 / 1024.0;
                sizeText = [NSString stringWithFormat:@"%.2fMB/%.2fMB", completedMB, totalMB];
            } else {
                sizeText = @"Pending...";
            }
            
            // Update detail text
            cell.detailTextLabel.text = sizeText;
            
            // For the accessory view, check if download is complete
            if (progress.finished) {
                // Show checkmark as accessory
                UIImageView *checkmarkView = [[UIImageView alloc] initWithFrame:CGRectMake(0, 0, 30, 30)];
                UIImage *checkmarkImage = [UIImage systemImageNamed:@"checkmark.circle.fill"];
                checkmarkView.image = checkmarkImage;
                checkmarkView.tintColor = [UIColor systemGreenColor];
                cell.accessoryView = checkmarkView;
                cell.detailTextLabel.text = @"Done";
            } else {
                // Ensure progress label is updated
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
            self.title = progress.localizedDescription;
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

    NSProgress *progress = self.task.progressList[indexPath.row];
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
        cell.detailTextLabel.text = @"Done";
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
            cell.detailTextLabel.text = [NSString stringWithFormat:@"%.2fMB/%.2fMB", completedMB, totalMB];
        } else {
            cell.detailTextLabel.text = @"Pending...";
        }
    }

    cell.textLabel.text = self.task.fileList[indexPath.row];
    return cell;
}

@end

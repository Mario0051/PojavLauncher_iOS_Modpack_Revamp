#import "FileListViewController.h"

@interface FileListViewController () {
}

@property(nonatomic) NSMutableArray *fileList;

@end

@implementation FileListViewController

- (void)viewDidLoad {
    [super viewDidLoad];

    if (self.fileList == nil) {
        self.fileList = [NSMutableArray array];
    } else {
        [self.fileList removeAllObjects];
    }

    // List files
    NSFileManager *fm = [NSFileManager defaultManager];
    NSArray *files = [fm contentsOfDirectoryAtPath:self.listPath error:nil];
    for(NSString *file in files) {
        NSString *path = [self.listPath stringByAppendingPathComponent:file];
        BOOL isDir = NO;
        [fm fileExistsAtPath:path isDirectory:(&isDir)];
        if(!isDir && [file hasSuffix:@".json"]) {
            [self.fileList addObject:[file stringByDeletingPathExtension]];
        }
    }

    [self.tableView setSeparatorStyle:UITableViewCellSeparatorStyleSingleLine];
}

- (NSInteger)tableView:(UITableView *)tableView numberOfRowsInSection:(NSInteger)section
{
    return self.fileList.count;
}

- (UITableViewCell *)tableView:(UITableView *)tableView cellForRowAtIndexPath:(NSIndexPath *)indexPath
{
    UITableViewCell *cell = [tableView dequeueReusableCellWithIdentifier:@"cell"];

    if (cell == nil) {
        cell = [[UITableViewCell alloc] initWithStyle:UITableViewCellStyleDefault reuseIdentifier:@"cell"];
    }

    // Safely access the array with bounds checking
    if (indexPath.row >= 0 && indexPath.row < self.fileList.count) {
        cell.textLabel.text = [self.fileList objectAtIndex:indexPath.row];
        
        // Add proper image handling for icons
        UIImage *icon = [UIImage systemImageNamed:@"doc.fill"];
        if (icon) {
            // Configure system icons with consistent sizing that works on iOS 14-18
            if (@available(iOS 14.0, *)) {
                UIImageSymbolConfiguration *config = [UIImageSymbolConfiguration configurationWithPointSize:24 weight:UIImageSymbolWeightRegular];
                UIImage *configuredImage = [icon imageByApplyingSymbolConfiguration:config];
                cell.imageView.image = [configuredImage imageWithRenderingMode:UIImageRenderingModeAlwaysTemplate];
            } else {
                // Fallback for earlier iOS versions if needed
                UIGraphicsImageRenderer *renderer = [[UIGraphicsImageRenderer alloc] initWithSize:CGSizeMake(40, 40)];
                UIImage *image = [renderer imageWithActions:^(UIGraphicsImageRendererContext*_Nonnull myContext) {
                    CGFloat scaleFactor = 40/icon.size.height;
                    [icon drawInRect:CGRectMake(20 - icon.size.width*scaleFactor/2, 0, icon.size.width*scaleFactor, 40)];
                }];
                cell.imageView.image = [image imageWithRenderingMode:UIImageRenderingModeAlwaysTemplate];
            }
        }
        
        // Ensure proper sizing and content mode
        cell.imageView.contentMode = UIViewContentModeScaleAspectFit;
    } else {
        // If we're somehow out of bounds, set a placeholder text
        cell.textLabel.text = @"";
        NSLog(@"Warning: Index out of bounds in FileListViewController: %ld, fileList count: %lu", 
              (long)indexPath.row, (unsigned long)self.fileList.count);
    }
    
    return cell;
}
- (void)tableView:(UITableView *)tableView commitEditingStyle:(UITableViewCellEditingStyle)editingStyle forRowAtIndexPath:(NSIndexPath *)indexPath {
    if (editingStyle == UITableViewCellEditingStyleDelete) {
        // Safely access the array with bounds checking
        if (indexPath.row >= 0 && indexPath.row < self.fileList.count) {
            NSString *str = [self.fileList objectAtIndex:indexPath.row];
            NSFileManager *fm = [NSFileManager defaultManager];
            NSString *path = [NSString stringWithFormat:@"%@/%@.json", self.listPath, str];
            if (self.whenDelete != nil) {
                self.whenDelete(path);
            }
            [fm removeItemAtPath:path error:nil];
            [self.fileList removeObjectAtIndex:indexPath.row];
            [tableView deleteRowsAtIndexPaths:@[indexPath] withRowAnimation:UITableViewRowAnimationFade];
        } else {
            NSLog(@"Warning: Index out of bounds in FileListViewController commitEditingStyle: %ld, fileList count: %lu", 
                  (long)indexPath.row, (unsigned long)self.fileList.count);
        }
    }
}

@end

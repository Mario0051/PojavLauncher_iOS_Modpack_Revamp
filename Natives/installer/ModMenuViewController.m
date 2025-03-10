#import "ModMenuViewController.h"
#import "modpack/ModrinthAPI.h"
#import "modpack/CurseForgeAPI.h"
#import "modpack/ModpackUtils.h"
#import "config.h"
#import "UIKit+AFNetworking.h"
#import "utils.h"
#import "PLProfiles.h"

#pragma mark - Alert Dialog Helper
static inline void presentAlertDialog(NSString *title, NSString *message) {
    NSLog(@"Presenting alert: %@ - %@", title, message);
    UIAlertController *alert = [UIAlertController alertControllerWithTitle:title
                                                                   message:message
                                                            preferredStyle:UIAlertControllerStyleAlert];
    [alert addAction:[UIAlertAction actionWithTitle:localize(@"OK", nil)
                                              style:UIAlertActionStyleDefault
                                            handler:nil]];
    UIWindow *window = nil;
    if (@available(iOS 13.0, *)) {
        window = [UIApplication sharedApplication].windows.firstObject;
    } else {
        window = [UIApplication sharedApplication].keyWindow;
    }
    [window.rootViewController presentViewController:alert animated:YES completion:nil];
}

#pragma mark - Helper Function
static inline NSString *SafeStringFromVersion(id rawVersion) {
    if ([rawVersion isKindOfClass:[NSString class]]) {
        return rawVersion;
    } else if ([rawVersion respondsToSelector:@selector(stringValue)]) {
        return [rawVersion stringValue];
    } else {
        return [rawVersion description];
    }
}

#pragma mark - ModQueueViewController Interface
@interface ModQueueViewController : UITableViewController
@property (nonatomic, strong) NSMutableArray *queue; // @{@"mod": modDictionary, @"versionIndex": @(index)}
@property (nonatomic, copy) void (^didFinishInstallation)(void);
@end

#pragma mark - ModQueueViewController Implementation
@implementation ModQueueViewController

- (void)viewDidLoad {
    [super viewDidLoad];
    self.title = @"Mod Installation Queue";
    
    // Add a nice background color if the table is empty
    UIView *emptyView = [[UIView alloc] initWithFrame:self.tableView.bounds];
    UILabel *emptyLabel = [[UILabel alloc] initWithFrame:CGRectMake(0, 0, self.view.bounds.size.width, 80)];
    emptyLabel.text = @"Your installation queue is empty.\nSearch for mods to add them here.";
    emptyLabel.textAlignment = NSTextAlignmentCenter;
    emptyLabel.numberOfLines = 0;
    emptyLabel.textColor = [UIColor grayColor];
    emptyLabel.center = emptyView.center;
    [emptyView addSubview:emptyLabel];
    self.tableView.backgroundView = self.queue.count == 0 ? emptyView : nil;
    
    // Modern toolbar buttons
    UIBarButtonItem *flexSpace = [[UIBarButtonItem alloc] initWithBarButtonSystemItem:UIBarButtonSystemItemFlexibleSpace target:nil action:nil];
    UIBarButtonItem *installButton = [[UIBarButtonItem alloc] initWithTitle:@"Install All" 
                                                                      style:UIBarButtonItemStyleDone 
                                                                     target:self 
                                                                     action:@selector(installQueueAction)];
    
    self.toolbarItems = @[flexSpace, installButton, flexSpace];
    self.navigationController.toolbarHidden = NO;
    
    // Editing capabilities
    self.navigationItem.leftBarButtonItem = self.editButtonItem;
    
    // Close button
    self.navigationItem.rightBarButtonItem = [[UIBarButtonItem alloc] initWithBarButtonSystemItem:UIBarButtonSystemItemClose 
                                                                                           target:self 
                                                                                           action:@selector(dismissAction)];
}

- (void)dismissAction {
    [self dismissViewControllerAnimated:YES completion:nil];
}

- (void)installQueueAction {
    if (self.queue.count == 0) {
        presentAlertDialog(localize(@"Queue Empty", nil), @"There are no mods in the install queue.");
        return;
    }
    
    // Confirm installation with count
    UIAlertController *confirmAlert = [UIAlertController alertControllerWithTitle:@"Install All Mods" 
                                                                          message:[NSString stringWithFormat:@"Install %lu mods from the queue?", (unsigned long)self.queue.count] 
                                                                   preferredStyle:UIAlertControllerStyleAlert];
    
    [confirmAlert addAction:[UIAlertAction actionWithTitle:@"Install" 
                                                     style:UIAlertActionStyleDefault 
                                                   handler:^(UIAlertAction * _Nonnull action) {
        // Show a progress indicator
        UIActivityIndicatorView *indicator = [[UIActivityIndicatorView alloc] initWithActivityIndicatorStyle:UIActivityIndicatorViewStyleMedium];
        [indicator startAnimating];
        self.navigationItem.titleView = indicator;
        self.navigationItem.title = nil;
        
        // Create a ModrinthAPI for mod downloads
        ModrinthAPI *modrinthAPI = [ModrinthAPI new];
        
        // Install each mod with a slight delay to prevent notification overlap
        dispatch_async(dispatch_get_global_queue(DISPATCH_QUEUE_PRIORITY_DEFAULT, 0), ^{
            for (NSUInteger i = 0; i < self.queue.count; i++) {
                NSDictionary *entry = self.queue[i];
                NSDictionary *mod = entry[@"mod"];
                NSUInteger versionIndex = [entry[@"versionIndex"] unsignedIntegerValue];
                NSNumber *apiSource = mod[@"apiSource"];
                
                dispatch_async(dispatch_get_main_queue(), ^{
                    if ([apiSource integerValue] == 1) {
                        [[NSNotificationCenter defaultCenter] postNotificationName:@"InstallMod"
                                                                            object:modrinthAPI
                                                                          userInfo:@{@"detail": mod, @"index": @(versionIndex)}];
                    } else {
                        if ([mod[@"isModpack"] boolValue]) {
                            [[NSNotificationCenter defaultCenter] postNotificationName:@"InstallModpack"
                                                                                object:nil
                                                                              userInfo:@{@"detail": mod, @"index": @(versionIndex)}];
                        } else {
                            [[NSNotificationCenter defaultCenter] postNotificationName:@"InstallMod"
                                                                                object:nil
                                                                              userInfo:@{@"detail": mod, @"index": @(versionIndex)}];
                        }
                    }
                    
                    // Wait a moment before posting the next notification
                    [NSThread sleepForTimeInterval:0.5];
                });
            }
            
            dispatch_async(dispatch_get_main_queue(), ^{
                [self.queue removeAllObjects];
                if (self.didFinishInstallation) {
                    self.didFinishInstallation();
                }
                
                [self dismissViewControllerAnimated:YES completion:^{
                    presentAlertDialog(@"Installation Started", 
                                      @"Mod installations have been initiated. You can monitor progress in the downloads window.");
                }];
            });
        });
    }]];
    
    [confirmAlert addAction:[UIAlertAction actionWithTitle:localize(@"Cancel", nil) 
                                                     style:UIAlertActionStyleCancel 
                                                   handler:nil]];
    
    [self presentViewController:confirmAlert animated:YES completion:nil];
}

- (NSInteger)tableView:(UITableView *)tableView numberOfRowsInSection:(NSInteger)section {
    return self.queue.count;
}

- (UITableViewCell *)tableView:(UITableView *)tableView cellForRowAtIndexPath:(NSIndexPath *)indexPath {
    UITableViewCell *cell = [tableView dequeueReusableCellWithIdentifier:@"QueueCell"];
    if (!cell) {
        cell = [[UITableViewCell alloc] initWithStyle:UITableViewCellStyleSubtitle reuseIdentifier:@"QueueCell"];
        cell.accessoryType = UITableViewCellAccessoryDetailButton;
    }
    
    NSDictionary *entry = self.queue[indexPath.row];
    NSDictionary *mod = entry[@"mod"];
    NSUInteger versionIndex = [entry[@"versionIndex"] unsignedIntegerValue];
    
    // Set main title to mod name
    cell.textLabel.text = mod[@"title"];
    
    // Format subtitle with version info
    NSArray *versionNames = mod[@"versionNames"];
    NSString *verStr = (versionIndex < versionNames.count) ? SafeStringFromVersion(versionNames[versionIndex]) : @"";
    NSDictionary *parsed = [ModpackUtils parseVersionString:verStr];
    
    // Check if we can get MC version info
    NSString *mcVersion = @"";
    NSArray *mcVersionNames = mod[@"mcVersionNames"];
    if (mcVersionNames && versionIndex < mcVersionNames.count) {
        mcVersion = [NSString stringWithFormat:@" (MC %@)", SafeStringFromVersion(mcVersionNames[versionIndex])];
    }
    
    cell.detailTextLabel.text = [NSString stringWithFormat:@"%@%@", 
                                 parsed[@"loaderVersion"] ?: verStr,
                                 mcVersion];
    
    return cell;
}

- (void)tableView:(UITableView *)tableView commitEditingStyle:(UITableViewCellEditingStyle)editingStyle 
 forRowAtIndexPath:(NSIndexPath *)indexPath {
    if (editingStyle == UITableViewCellEditingStyleDelete) {
        [self.queue removeObjectAtIndex:indexPath.row];
        [tableView deleteRowsAtIndexPaths:@[indexPath] withRowAnimation:UITableViewRowAnimationAutomatic];
    }
}

@end

#pragma mark - Private Method Declarations
@interface ModMenuViewController ()
- (NSString *)stringFromVersionObject:(id)rawVersion;
- (void)updateProfileFromSavedSettings;
- (UIImage *)standardizeImage:(UIImage *)originalImage;
@end

#pragma mark - ModMenuViewController Interface
@interface ModMenuViewController () <UISearchResultsUpdating, UITableViewDelegate, UITableViewDataSource>
@property (nonatomic, strong) UISearchController *searchController;
@property (nonatomic, strong) UISegmentedControl *apiSegmentedControl;
@property (nonatomic, strong) NSMutableArray *modsList;
@property (nonatomic, strong) ModrinthAPI *modrinth;
@property (nonatomic, strong) CurseForgeAPI *curseForge;
@property (nonatomic, strong) NSMutableDictionary *searchFilters;
@property (nonatomic, strong) NSString *selectedProfileName;
@property (nonatomic, strong) NSString *selectedMCVersion;
@property (nonatomic, strong) NSString *selectedModLoader;
@property (nonatomic, strong) NSMutableArray *installQueue; // @{@"mod": modDictionary, @"versionIndex": @(index)}
@end

#pragma mark - ModMenuViewController Implementation
@implementation ModMenuViewController

// Helper method to standardize images
- (UIImage *)standardizeImage:(UIImage *)originalImage {
    if (!originalImage) {
        return [UIImage imageNamed:@"DefaultProfile"];
    }
    
    // Create a standard size for all images
    CGFloat standardSize = 60.0;
    CGSize size = CGSizeMake(standardSize, standardSize);
    
    UIGraphicsBeginImageContextWithOptions(size, NO, 0);
    
    // Create a rounded rect path
    UIBezierPath *path = [UIBezierPath bezierPathWithRoundedRect:CGRectMake(0, 0, size.width, size.height) 
                                                cornerRadius:10.0];
    [path addClip]; // Clip to the rounded rect
    
    // Calculate aspect ratio to maintain proportions
    CGFloat widthRatio = size.width / originalImage.size.width;
    CGFloat heightRatio = size.height / originalImage.size.height;
    CGFloat ratio = MAX(widthRatio, heightRatio);
    
    CGFloat newWidth = originalImage.size.width * ratio;
    CGFloat newHeight = originalImage.size.height * ratio;
    
    // Center the image
    CGFloat xOffset = (size.width - newWidth) / 2.0;
    CGFloat yOffset = (size.height - newHeight) / 2.0;
    
    [originalImage drawInRect:CGRectMake(xOffset, yOffset, newWidth, newHeight)];
    
    // Draw a border
    [[UIColor lightGrayColor] setStroke];
    [path setLineWidth:1.0];
    [path stroke];
    
    UIImage *standardizedImage = UIGraphicsGetImageFromCurrentImageContext();
    UIGraphicsEndImageContext();
    
    return standardizedImage;
}

// Auto-update from saved profile settings if available.
- (void)updateProfileFromSavedSettings {
    NSString *savedProfile = [PLProfiles current].selectedProfileName;
    if (savedProfile) {
        NSDictionary *profile = [PLProfiles current].profiles[savedProfile];
        if (profile) {
            self.selectedProfileName = savedProfile;
            NSString *lastVersionId = profile[@"lastVersionId"];
            if (![lastVersionId isKindOfClass:[NSString class]]) {
                lastVersionId = [lastVersionId description];
            }
            NSDictionary *parsed = [ModpackUtils parseVersionString:lastVersionId];
            self.selectedMCVersion = parsed[@"mcVersion"] ?: lastVersionId;
            self.selectedModLoader = parsed[@"loader"] ?: @"";
            NSLog(@"Auto-selected profile: %@, mod loader: %@, MC version: %@", self.selectedProfileName, self.selectedModLoader, self.selectedMCVersion);
            self.searchFilters[@"mcVersion"] = self.selectedMCVersion;
        }
    }
}

// Helper: Return a safe string from a version object.
- (NSString *)stringFromVersionObject:(id)rawVersion {
    return SafeStringFromVersion(rawVersion);
}

// Method to handle mod installation when a version is selected.
- (void)installModNow:(NSDictionary *)mod versionIndex:(NSUInteger)index {
    // Post notification for download task to handle
    NSDictionary *userInfo = @{@"detail": mod, @"index": @(index)};
    [[NSNotificationCenter defaultCenter] postNotificationName:@"InstallMod" object:nil userInfo:userInfo];
    
    // Dismiss any presented view controllers like version selection
    if (self.presentedViewController) {
        [self.presentedViewController dismissViewControllerAnimated:YES completion:nil];
    }
}

- (void)viewDidLoad {
    [super viewDidLoad];
    
    self.title = @"Mods";
    self.modrinth = [ModrinthAPI new];
    self.curseForge = [[CurseForgeAPI alloc] initWithAPIKey:@""];
    self.searchFilters = [@{@"isModpack": @(NO), @"name": @""} mutableCopy];
    self.modsList = [NSMutableArray new];
    self.installQueue = [NSMutableArray new];
    
    // Auto-select saved profile if available
    [self updateProfileFromSavedSettings];
    
    // Setup modern search controller
    self.searchController = [[UISearchController alloc] initWithSearchResultsController:nil];
    self.searchController.searchResultsUpdater = self;
    self.searchController.obscuresBackgroundDuringPresentation = NO;
    self.searchController.searchBar.placeholder = @"Search mods...";
    self.navigationItem.searchController = self.searchController;
    self.navigationItem.hidesSearchBarWhenScrolling = NO;
    
    // Create a more modern segmented control for API selection
    self.apiSegmentedControl = [[UISegmentedControl alloc] initWithItems:@[@"Modrinth", @"CurseForge"]];
    self.apiSegmentedControl.selectedSegmentIndex = 0;
    [self.apiSegmentedControl addTarget:self action:@selector(updateModsList) forControlEvents:UIControlEventValueChanged];
    
    // Create a header view with the segmented control centered
    UIView *headerView = [[UIView alloc] initWithFrame:CGRectMake(0, 0, self.view.bounds.size.width, 50)];
    self.apiSegmentedControl.translatesAutoresizingMaskIntoConstraints = NO;
    [headerView addSubview:self.apiSegmentedControl];
    
    // Center the segmented control in the header view
    [NSLayoutConstraint activateConstraints:@[
        [self.apiSegmentedControl.centerXAnchor constraintEqualToAnchor:headerView.centerXAnchor],
        [self.apiSegmentedControl.centerYAnchor constraintEqualToAnchor:headerView.centerYAnchor],
        [self.apiSegmentedControl.widthAnchor constraintEqualToConstant:240]
    ]];
    
    self.tableView.tableHeaderView = headerView;
    
    // More descriptive button titles
    self.navigationItem.leftBarButtonItem = [[UIBarButtonItem alloc] initWithTitle:@"Profile"
                                                                             style:UIBarButtonItemStylePlain
                                                                            target:self
                                                                            action:@selector(actionChooseProfile)];
    
    // Modern right bar button with badge for queue count
    [self updateQueueButtonTitle];
    
    // Set up table view for a modern look
    self.tableView.separatorStyle = UITableViewCellSeparatorStyleSingleLine;
    self.tableView.tableFooterView = [UIView new]; // Hide empty cells
    
    if (@available(iOS 15.0, *)) {
        self.tableView.sectionHeaderTopPadding = 0;
    }
    
    // Register for notifications
    [[NSNotificationCenter defaultCenter] addObserver:self selector:@selector(handleInstallModNotification:) name:@"InstallMod" object:nil];
    [[NSNotificationCenter defaultCenter] addObserver:self selector:@selector(handleInstallModpackNotification:) name:@"InstallModpack" object:nil];
    
    // Add a refresh control for pull-to-refresh
    UIRefreshControl *refreshControl = [[UIRefreshControl alloc] init];
    [refreshControl addTarget:self action:@selector(refreshModsList) forControlEvents:UIControlEventValueChanged];
    self.tableView.refreshControl = refreshControl;
    
    [self updateModsList];
}

- (void)refreshModsList {
    [self.modsList removeAllObjects];
    [self refreshModsListWithPrevList:NO];
    [self.tableView.refreshControl endRefreshing];
}

// Profile selection: Presents a sorted list of profiles for the user to choose from.
- (void)actionChooseProfile {
    NSDictionary *profiles = [PLProfiles current].profiles;
    if (!profiles || profiles.count == 0) {
        presentAlertDialog(localize(@"Error", nil), @"No profiles available.");
        return;
    }
    NSArray *sortedProfiles = [[profiles allValues] sortedArrayUsingComparator:^NSComparisonResult(NSDictionary *p1, NSDictionary *p2) {
        return [p1[@"name"] compare:p2[@"name"] options:NSCaseInsensitiveSearch];
    }];
    UIAlertController *alert = [UIAlertController alertControllerWithTitle:@"Select Profile"
                                                                   message:nil
                                                            preferredStyle:UIAlertControllerStyleActionSheet];
    for (NSDictionary *profile in sortedProfiles) {
        NSString *profileName = profile[@"name"];
        NSString *lastVersionId = profile[@"lastVersionId"];
        if (![lastVersionId isKindOfClass:[NSString class]]) {
            lastVersionId = [lastVersionId description];
        }
        
        // Parse version information for display
        NSDictionary *parsed = [ModpackUtils parseVersionString:lastVersionId];
        NSString *mcVersion = parsed[@"mcVersion"] ?: lastVersionId;
        NSString *loaderType = parsed[@"loader"] ?: @"";
        NSString *loaderVersion = parsed[@"loaderVersion"] ?: @"";
        
        // Create a descriptive title that includes the version info
        NSString *displayTitle = profileName;
        if (loaderType.length > 0) {
            displayTitle = [NSString stringWithFormat:@"%@ (MC %@, %@ %@)", 
                           profileName, 
                           mcVersion, 
                           [loaderType capitalizedString], 
                           loaderVersion];
        } else {
            displayTitle = [NSString stringWithFormat:@"%@ (MC %@)", 
                           profileName, 
                           mcVersion];
        }
        
        [alert addAction:[UIAlertAction actionWithTitle:displayTitle
                                                  style:UIAlertActionStyleDefault
                                                handler:^(UIAlertAction * _Nonnull action) {
            self.selectedProfileName = profileName;
            self.selectedMCVersion = mcVersion;
            self.selectedModLoader = loaderType;
            NSLog(@"Selected profile: %@, mod loader: %@, MC version: %@", self.selectedProfileName, self.selectedModLoader, self.selectedMCVersion);
            
            // Update the selected profile in PLProfiles
            [PLProfiles current].selectedProfileName = profileName;
            [[PLProfiles current] save];
            
            // Update search filters and reload
            self.searchFilters[@"mcVersion"] = self.selectedMCVersion;
            [self refreshModsList];
        }]];
    }
    [alert addAction:[UIAlertAction actionWithTitle:localize(@"Cancel", nil)
                                              style:UIAlertActionStyleCancel
                                            handler:nil]];
    alert.popoverPresentationController.sourceView = self.view;
    alert.popoverPresentationController.sourceRect = CGRectMake(CGRectGetMidX(self.view.bounds),
                                                                CGRectGetMidY(self.view.bounds),
                                                                1, 1);
    [self presentViewController:alert animated:YES completion:nil];
}

// Always prompt for CurseForge API key when the CurseForge segment is active.
- (void)viewDidAppear:(BOOL)animated {
    [super viewDidAppear:animated];
    if (self.apiSegmentedControl.selectedSegmentIndex == 1) {
         UIAlertController *alert = [UIAlertController alertControllerWithTitle:@"Enter CurseForge API Key"
                message:@"Please enter your CurseForge API key to search mods on CurseForge."
                preferredStyle:UIAlertControllerStyleAlert];
         [alert addTextFieldWithConfigurationHandler:^(UITextField * _Nonnull textField) {
             textField.placeholder = @"API Key";
         }];
         [alert addAction:[UIAlertAction actionWithTitle:@"OK" style:UIAlertActionStyleDefault handler:^(UIAlertAction * _Nonnull action) {
             NSString *enteredKey = alert.textFields.firstObject.text;
             if (enteredKey.length > 0) {
                 [self.curseForge setValue:enteredKey forKey:@"apiKey"];
             } else {
                 presentAlertDialog(@"API Key Missing", @"No API key entered. Some functionality may not work.");
             }
         }]];
         [self presentViewController:alert animated:YES completion:nil];
    }
}

- (void)dealloc {
    [[NSNotificationCenter defaultCenter] removeObserver:self];
}

- (void)viewWillTransitionToSize:(CGSize)size withTransitionCoordinator:(id<UIViewControllerTransitionCoordinator>)coordinator {
    [super viewWillTransitionToSize:size withTransitionCoordinator:coordinator];
    [coordinator animateAlongsideTransition:^(id<UIViewControllerTransitionCoordinatorContext>  _Nonnull context) {
        [self.tableView reloadData];
    } completion:nil];
}

#pragma mark - Notification Handlers
- (void)handleInstallModNotification:(NSNotification *)notification {
    // LauncherNavigationController now handles the actual download
    // Just close any presented view controllers
    if (self.presentedViewController) {
        [self.presentedViewController dismissViewControllerAnimated:YES completion:nil];
    }
}

- (void)handleInstallModpackNotification:(NSNotification *)notification {
    // LauncherNavigationController now handles the actual download
    // Just close any presented view controllers
    if (self.presentedViewController) {
        [self.presentedViewController dismissViewControllerAnimated:YES completion:nil];
    }
}

#pragma mark - Installation Methods
- (void)installModpackNow:(NSDictionary *)mod versionIndex:(NSUInteger)index {
    // Post notification for download task to handle
    NSDictionary *userInfo = @{@"detail": mod, @"index": @(index)};
    [[NSNotificationCenter defaultCenter] postNotificationName:@"InstallModpack" object:nil userInfo:userInfo];
    
    // Dismiss any presented view controllers
    if (self.presentedViewController) {
        [self.presentedViewController dismissViewControllerAnimated:YES completion:nil];
    }
}

#pragma mark - Mod Search
- (void)updateModsList {
    NSString *name = self.searchController.searchBar.text;
    self.searchFilters[@"name"] = name ?: @"";
    if (self.selectedMCVersion && self.selectedMCVersion.length > 0) {
        self.searchFilters[@"mcVersion"] = self.selectedMCVersion;
    }
    
    if (self.apiSegmentedControl.selectedSegmentIndex == 1) {
        UIAlertController *alert = [UIAlertController alertControllerWithTitle:@"Enter CurseForge API Key"
                                                                       message:@"Please enter your CurseForge API key to search mods on CurseForge."
                                                                preferredStyle:UIAlertControllerStyleAlert];
        [alert addTextFieldWithConfigurationHandler:^(UITextField * _Nonnull textField) {
            textField.placeholder = @"API Key";
        }];
        [alert addAction:[UIAlertAction actionWithTitle:@"OK" style:UIAlertActionStyleDefault handler:^(UIAlertAction * _Nonnull action) {
            NSString *enteredKey = alert.textFields.firstObject.text;
            if (enteredKey.length > 0) {
                [self.curseForge setValue:enteredKey forKey:@"apiKey"];
            } else {
                presentAlertDialog(@"API Key Missing", @"No API key entered. Some functionality may not work.");
            }
            [self refreshModsListWithPrevList:NO];
        }]];
        [self presentViewController:alert animated:YES completion:nil];
    } else {
        [self.modsList removeAllObjects];
        [self refreshModsListWithPrevList:NO];
    }
}

- (void)refreshModsListWithPrevList:(BOOL)prevList {
    if (self.apiSegmentedControl.selectedSegmentIndex == 0) {
        __weak typeof(self) weakSelf = self;
        dispatch_async(dispatch_get_global_queue(DISPATCH_QUEUE_PRIORITY_DEFAULT, 0), ^{
            NSMutableArray *results = [weakSelf.modrinth searchModWithFilters:weakSelf.searchFilters previousPageResult:(prevList ? weakSelf.modsList : nil)];
            dispatch_async(dispatch_get_main_queue(), ^{
                __strong typeof(weakSelf) strongSelf = weakSelf;
                if (results) {
                    strongSelf.modsList = results;
                    [strongSelf.tableView reloadData];
                } else {
                    presentAlertDialog(localize(@"Error", nil), strongSelf.modrinth.lastError.localizedDescription);
                }
            });
        });
    } else {
        [self.curseForge searchModWithFilters:self.searchFilters previousPageResult:(prevList ? self.modsList : nil) completion:^(NSMutableArray *results, NSError *error) {
            dispatch_async(dispatch_get_main_queue(), ^{
                if (results) {
                    self.modsList = results;
                    [self.tableView reloadData];
                } else {
                    presentAlertDialog(localize(@"Error", nil), error.localizedDescription);
                }
            });
        }];
    }
}

- (void)updateSearchResultsForSearchController:(UISearchController *)searchController {
    [NSObject cancelPreviousPerformRequestsWithTarget:self selector:@selector(updateModsList) object:nil];
    [self performSelector:@selector(updateModsList) withObject:nil afterDelay:0.5];
}

#pragma mark - UITableView DataSource
- (NSInteger)numberOfSectionsInTableView:(UITableView *)tableView {
    return 1;
}
- (NSInteger)tableView:(UITableView *)tableView numberOfRowsInSection:(NSInteger)section {
    return self.modsList.count;
}

- (UITableViewCell *)tableView:(UITableView *)tableView cellForRowAtIndexPath:(NSIndexPath *)indexPath {
    UITableViewCell *cell = [tableView dequeueReusableCellWithIdentifier:@"modCell"];
    if (!cell) {
        cell = [[UITableViewCell alloc] initWithStyle:UITableViewCellStyleSubtitle reuseIdentifier:@"modCell"];
        
        // Set up subtitle text properties
        cell.detailTextLabel.numberOfLines = 2;
        cell.detailTextLabel.textColor = [UIColor grayColor];
        cell.accessoryType = UITableViewCellAccessoryDisclosureIndicator;
    }
    
    NSDictionary *mod = self.modsList[indexPath.row];
    cell.textLabel.text = mod[@"title"];
    cell.detailTextLabel.text = mod[@"description"];
    
    // Modern image loading with placeholder and standardization
    UIImage *placeholder = [UIImage imageNamed:@"DefaultProfile"];
    
    NSURL *imageURL = [NSURL URLWithString:mod[@"imageUrl"]];
    [cell.imageView setImageWithURLRequest:[NSURLRequest requestWithURL:imageURL]
                          placeholderImage:placeholder
                                   success:^(NSURLRequest *request, NSHTTPURLResponse *response, UIImage *image) {
        // Standardize the image to ensure consistent appearance
        cell.imageView.image = [self standardizeImage:image];
        [cell setNeedsLayout];
    } failure:^(NSURLRequest *request, NSHTTPURLResponse *response, NSError *error) {
        cell.imageView.image = [self standardizeImage:placeholder];
        [cell setNeedsLayout];
    }];
    
    // Check if we're at the end of the list and should load more
    if (indexPath.row == self.modsList.count - 3 && !self.modrinth.reachedLastPage) {
        [self refreshModsListWithPrevList:YES];
    }
    
    return cell;
}

#pragma mark - UITableView Delegate
- (void)tableView:(UITableView *)tableView didSelectRowAtIndexPath:(NSIndexPath *)indexPath {
    NSDictionary *mod = self.modsList[indexPath.row];
    if ([mod[@"versionDetailsLoaded"] boolValue]) {
        [self showModDetails:mod atIndexPath:indexPath];
    } else {
        [tableView deselectRowAtIndexPath:indexPath animated:YES];
        [self loadModDetailsForMod:mod atIndexPath:indexPath];
    }
}

- (void)loadModDetailsForMod:(NSDictionary *)mod atIndexPath:(NSIndexPath *)indexPath {
    NSMutableDictionary *modMutable = [mod mutableCopy];
    __weak typeof(self) weakSelf = self;
    if (self.apiSegmentedControl.selectedSegmentIndex == 0) {
        dispatch_async(dispatch_get_global_queue(DISPATCH_QUEUE_PRIORITY_DEFAULT, 0), ^{
            [weakSelf.modrinth loadDetailsOfMod:modMutable completion:^(NSError *error) {
                dispatch_async(dispatch_get_main_queue(), ^{
                    __strong typeof(weakSelf) strongSelf = weakSelf;
                    if ([modMutable[@"versionDetailsLoaded"] boolValue]) {
                        [strongSelf.modsList replaceObjectAtIndex:indexPath.row withObject:modMutable];
                        [strongSelf showModDetails:modMutable atIndexPath:indexPath];
                    } else {
                        presentAlertDialog(localize(@"Error", nil), strongSelf.modrinth.lastError.localizedDescription);
                    }
                });
            }];
        });
    } else {
        [self.curseForge loadDetailsOfMod:modMutable completion:^(NSError *error) {
            dispatch_async(dispatch_get_main_queue(), ^{
                __strong typeof(weakSelf) strongSelf = weakSelf;
                if ([modMutable[@"versionDetailsLoaded"] boolValue]) {
                    [strongSelf.modsList replaceObjectAtIndex:indexPath.row withObject:modMutable];
                    [strongSelf showModDetails:modMutable atIndexPath:indexPath];
                } else {
                    presentAlertDialog(localize(@"Error", nil), strongSelf.curseForge.lastError.localizedDescription);
                }
            });
        }];
    }
}

#pragma mark - Version Filtering and Action Sheet
- (void)showModDetails:(NSDictionary *)mod atIndexPath:(NSIndexPath *)indexPath {
    // Extract all needed arrays upfront instead of accessing dictionary repeatedly
    NSArray *versionNames = mod[@"versionNames"];
    NSArray *gameVersionsArray = mod[@"gameVersions"] ?: mod[@"mcVersionNames"];
    NSArray *loadersArray = mod[@"versionLoaders"];
    
    // Pre-process profile information once instead of in each loop iteration
    NSString *profileMCVer = [[self.selectedMCVersion stringByTrimmingCharactersInSet:[NSCharacterSet whitespaceAndNewlineCharacterSet]] lowercaseString];
    NSString *profileLoader = [[self.selectedModLoader stringByTrimmingCharactersInSet:[NSCharacterSet whitespaceAndNewlineCharacterSet]] lowercaseString];
    NSLog(@"Filtering for MC version: %@ and loader: %@", profileMCVer, profileLoader);
    
    // Arrays to store filtered versions
    NSMutableArray<NSNumber *> *supportedIndices = [NSMutableArray array];
    NSMutableArray<NSString *> *supportedDisplayNames = [NSMutableArray array];
    
    // Optimize by handling the no-filter case separately
    if (profileMCVer.length == 0 || profileLoader.length == 0) {
        // No filtering needed, include all versions
        for (NSUInteger i = 0; i < versionNames.count; i++) {
            [supportedIndices addObject:@(i)];
            NSString *verStr = SafeStringFromVersion(versionNames[i]);
            NSDictionary *parsed = [ModpackUtils parseVersionString:verStr];
            NSString *modFileVersion = parsed[@"loaderVersion"] ?: verStr;
            
            // Add game version to display name for clarity if available
            if (i < gameVersionsArray.count) {
                id gameVerObj = gameVersionsArray[i];
                NSString *gameVer = [gameVerObj isKindOfClass:[NSArray class]] ? 
                                   [gameVerObj firstObject] : 
                                   [self stringFromVersionObject:gameVerObj];
                modFileVersion = [NSString stringWithFormat:@"%@ (MC %@)", modFileVersion, gameVer];
            }
            
            [supportedDisplayNames addObject:modFileVersion];
        }
    } else {
        // Full filtering needed
        for (NSUInteger i = 0; i < versionNames.count; i++) {
            // Check MC version match first
            BOOL mcMatch = NO;
            if (i < gameVersionsArray.count) {
                id gameVerItem = gameVersionsArray[i];
                NSArray *gameVers = [gameVerItem isKindOfClass:[NSArray class]] ? gameVerItem : @[gameVerItem];
                
                for (NSString *gv in gameVers) {
                    NSString *trimmedGV = [[gv stringByTrimmingCharactersInSet:[NSCharacterSet whitespaceAndNewlineCharacterSet]] lowercaseString];
                    if ([trimmedGV isEqualToString:profileMCVer] ||
                        [trimmedGV hasPrefix:profileMCVer] ||
                        [profileMCVer hasPrefix:trimmedGV]) {
                        mcMatch = YES;
                        break;
                    }
                }
            }
            
            // Skip to next version if MC version doesn't match (early rejection)
            if (!mcMatch) continue;
            
            // Only check loader match if MC version matches
            BOOL loaderMatch = NO;
            if (loadersArray && i < loadersArray.count) {
                id loaderItem = loadersArray[i];
                NSArray *versionLoaders = [loaderItem isKindOfClass:[NSArray class]] ? loaderItem : (loaderItem ? @[loaderItem] : @[]);
                
                for (NSString *ld in versionLoaders) {
                    NSString *trimmedLD = [[ld stringByTrimmingCharactersInSet:[NSCharacterSet whitespaceAndNewlineCharacterSet]] lowercaseString];
                    if ([trimmedLD isEqualToString:profileLoader]) {
                        loaderMatch = YES;
                        break;
                    }
                }
            }
            
            // Add to supported versions if both MC and loader match
            if (mcMatch && loaderMatch) {
                [supportedIndices addObject:@(i)];
                NSString *verStr = SafeStringFromVersion(versionNames[i]);
                NSDictionary *parsed = [ModpackUtils parseVersionString:verStr];
                NSString *modFileVersion = parsed[@"loaderVersion"] ?: verStr;
                
                // Add game version for clarity
                id gameVerObj = gameVersionsArray[i];
                NSString *gameVer = [gameVerObj isKindOfClass:[NSArray class]] ? 
                                   [gameVerObj firstObject] : 
                                   [self stringFromVersionObject:gameVerObj];
                modFileVersion = [NSString stringWithFormat:@"%@ (MC %@)", modFileVersion, gameVer];
                
                [supportedDisplayNames addObject:modFileVersion];
            }
        }
    }
    
    // Handle empty results
    if (supportedIndices.count == 0) {
        presentAlertDialog(@"No Compatible Versions", 
                           [NSString stringWithFormat:@"No versions of %@ are compatible with your selected profile (MC %@, %@).", 
                            mod[@"title"], 
                            self.selectedMCVersion ?: @"any", 
                            self.selectedModLoader ?: @"any"]);
        return;
    }
    
    // Create a modern action sheet for version selection
    UIAlertController *versionAlert = [UIAlertController alertControllerWithTitle:@"Select Version"
                                                                          message:[NSString stringWithFormat:@"%@ - Compatible Versions", mod[@"title"]]
                                                                   preferredStyle:UIAlertControllerStyleActionSheet];
    
    // Add version options with clear labels
    for (NSUInteger j = 0; j < supportedIndices.count; j++) {
        NSUInteger idx = [supportedIndices[j] unsignedIntegerValue];
        NSString *displayName = supportedDisplayNames[j];
        
        [versionAlert addAction:[UIAlertAction actionWithTitle:displayName
                                                         style:UIAlertActionStyleDefault
                                                       handler:^(UIAlertAction * _Nonnull action) {
            // Modern install options dialog
            UIAlertController *choiceAlert = [UIAlertController alertControllerWithTitle:@"Install or Queue?"
                                                                                 message:[NSString stringWithFormat:@"Choose how to handle %@", mod[@"title"]]
                                                                          preferredStyle:UIAlertControllerStyleAlert];
            
            [choiceAlert addAction:[UIAlertAction actionWithTitle:@"Install Now"
                                                            style:UIAlertActionStyleDefault
                                                          handler:^(UIAlertAction * _Nonnull action) {
                [self installModNow:mod versionIndex:idx];
            }]];
            
            [choiceAlert addAction:[UIAlertAction actionWithTitle:@"Add to Queue"
                                                            style:UIAlertActionStyleDefault
                                                          handler:^(UIAlertAction * _Nonnull action) {
                NSDictionary *queueEntry = @{@"mod": mod, @"versionIndex": @(idx)};
                [self.installQueue addObject:queueEntry];
                [self updateQueueButtonTitle];
                
                // Show toast-style feedback
                UIAlertController *toast = [UIAlertController alertControllerWithTitle:nil
                                                                               message:[NSString stringWithFormat:@"Added %@ to queue", mod[@"title"]]
                                                                        preferredStyle:UIAlertControllerStyleAlert];
                [self presentViewController:toast animated:YES completion:^{
                    dispatch_after(dispatch_time(DISPATCH_TIME_NOW, (int64_t)(1.0 * NSEC_PER_SEC)), dispatch_get_main_queue(), ^{
                        [toast dismissViewControllerAnimated:YES completion:nil];
                    });
                }];
            }]];
            
            [choiceAlert addAction:[UIAlertAction actionWithTitle:localize(@"Cancel", nil)
                                                            style:UIAlertActionStyleCancel
                                                          handler:nil]];
            
            [self presentViewController:choiceAlert animated:YES completion:nil];
        }]];
    }
    
    [versionAlert addAction:[UIAlertAction actionWithTitle:localize(@"Cancel", nil)
                                                     style:UIAlertActionStyleCancel
                                                   handler:nil]];
    
    // Configure popover presentation on iPad
    UITableViewCell *cell = [self.tableView cellForRowAtIndexPath:indexPath];
    versionAlert.popoverPresentationController.sourceView = cell ?: self.view;
    versionAlert.popoverPresentationController.sourceRect = cell ? cell.bounds : CGRectMake(CGRectGetMidX(self.view.bounds), CGRectGetMidY(self.view.bounds), 1, 1);
    
    [self presentViewController:versionAlert animated:YES completion:nil];
}

#pragma mark - Install Queue
- (void)updateQueueButtonTitle {
    NSUInteger count = self.installQueue.count;
    
    // Create a badge-style button for iOS 14+ compatibility
    UIButton *queueButton = [UIButton buttonWithType:UIButtonTypeSystem];
    [queueButton setTitle:[NSString stringWithFormat:@"Queue (%lu)", (unsigned long)count] forState:UIControlStateNormal];
    [queueButton addTarget:self action:@selector(actionShowQueue) forControlEvents:UIControlEventTouchUpInside];
    
    if (count > 0) {
        queueButton.backgroundColor = self.view.tintColor;
        queueButton.layer.cornerRadius = 12;
        [queueButton setTitleColor:[UIColor whiteColor] forState:UIControlStateNormal];
        queueButton.contentEdgeInsets = UIEdgeInsetsMake(5, 10, 5, 10);
    }
    
    // Create a custom bar button with our styled button
    self.navigationItem.rightBarButtonItem = [[UIBarButtonItem alloc] initWithCustomView:queueButton];
}

- (void)actionShowQueue {
    ModQueueViewController *queueVC = [ModQueueViewController new];
    queueVC.queue = self.installQueue;
    __weak typeof(self) weakSelf = self;
    queueVC.didFinishInstallation = ^{
        __strong typeof(weakSelf) strongSelf = weakSelf;
        [strongSelf.installQueue removeAllObjects];
        [strongSelf updateQueueButtonTitle];
    };
    
    // Use a more modern presentation style
    UINavigationController *nav = [[UINavigationController alloc] initWithRootViewController:queueVC];
    nav.modalPresentationStyle = UIModalPresentationFormSheet;
    [self presentViewController:nav animated:YES completion:nil];
}

@end

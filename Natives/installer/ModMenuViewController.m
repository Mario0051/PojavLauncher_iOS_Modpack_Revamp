#import "ModMenuViewController.h"
#import "modpack/ModrinthAPI.h"
#import "modpack/CurseForgeAPI.h"
#import "modpack/ModpackUtils.h"
#import "config.h"
#import "UIKit+AFNetworking.h"
#import "utils.h"
#import "PLProfiles.h"
#import "UIAlertUtilities.h"

@class ModMenuViewController;

// Add protocol definition for version selection
@protocol VersionSelectorDelegate <NSObject>
- (void)handleVersionSelection:(NSDictionary *)mod selectedVersion:(NSUInteger)idx;
@property (nonatomic, readonly) UIViewController *presentedViewController;
@end

@interface VersionSelectorDataSource : NSObject <UITableViewDataSource, UITableViewDelegate>
@property (nonatomic, strong) NSArray<NSString *> *versions;
@property (nonatomic, strong) NSArray<NSNumber *> *indices;
@property (nonatomic, strong) NSDictionary *mod;
@property (nonatomic, weak) id<VersionSelectorDelegate> delegate;

- (instancetype)initWithVersions:(NSArray<NSString *> *)versions 
                             mod:(NSDictionary *)mod 
                         indices:(NSArray<NSNumber *> *)indices 
                        delegate:(id<VersionSelectorDelegate>)delegate;
@end

#pragma mark - Alert Dialog Helper
static inline void presentAlertDialog(NSString *title, NSString *message) {
    NSLog(@"Presenting alert: %@ - %@", title, message);
    [UIAlertUtilities presentAlertWithTitle:title message:message viewController:nil];
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

#pragma mark - Private Method Declarations
@interface ModMenuViewController ()
- (void)downloadModFromURL:(NSString *)urlString toDestination:(NSString *)destinationPath completion:(void(^)(BOOL success, NSError *error))completion;
- (NSString *)stringFromVersionObject:(id)rawVersion;
- (void)updateProfileFromSavedSettings;
@end

#pragma mark - ModQueueViewController Interface
@interface ModQueueViewController : UITableViewController
@property (nonatomic, strong) NSMutableArray *queue; // @{@"mod": modDictionary, @"versionIndex": @(index)}
@property (nonatomic, copy) void (^didFinishInstallation)(void);
@end

#pragma mark - ModQueueViewController Implementation
@implementation ModQueueViewController
- (void)viewDidLoad {
    [super viewDidLoad];
    self.title = @"Install Queue";
    self.tableView.tableFooterView = [UIView new];
    self.navigationItem.rightBarButtonItem = [[UIBarButtonItem alloc] initWithTitle:@"Install"
                                                                              style:UIBarButtonItemStyleDone
                                                                             target:self
                                                                             action:@selector(installQueueAction)];
    self.navigationItem.leftBarButtonItem = self.editButtonItem;
}
- (void)installQueueAction {
    if (self.queue.count == 0) {
        presentAlertDialog(localize(@"Queue Empty", nil), @"There are no mods in the install queue.");
        return;
    }
    for (NSDictionary *entry in self.queue) {
        NSDictionary *mod = entry[@"mod"];
        NSUInteger versionIndex = [entry[@"versionIndex"] unsignedIntegerValue];
        NSNumber *apiSource = mod[@"apiSource"];
        if ([apiSource integerValue] == 1) {
            [[NSNotificationCenter defaultCenter] postNotificationName:@"InstallMod"
                                                                object:nil
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
    }
    [self.queue removeAllObjects];
    if (self.didFinishInstallation) {
        self.didFinishInstallation();
    }
    [self.tableView reloadData];
    presentAlertDialog(@"Installation Started", @"Queued mod installations have been triggered.");
}
- (NSInteger)tableView:(UITableView *)tableView numberOfRowsInSection:(NSInteger)section {
    return self.queue.count;
}
- (UITableViewCell *)tableView:(UITableView *)tableView cellForRowAtIndexPath:(NSIndexPath *)indexPath {
    UITableViewCell *cell = [tableView dequeueReusableCellWithIdentifier:@"QueueCell"];
    if (!cell) {
        cell = [[UITableViewCell alloc] initWithStyle:UITableViewCellStyleSubtitle reuseIdentifier:@"QueueCell"];
    }
    NSDictionary *entry = self.queue[indexPath.row];
    NSDictionary *mod = entry[@"mod"];
    NSUInteger versionIndex = [entry[@"versionIndex"] unsignedIntegerValue];
    cell.textLabel.text = mod[@"title"];
    NSArray *versionNames = mod[@"versionNames"];
    NSString *verStr = (versionIndex < versionNames.count) ? SafeStringFromVersion(versionNames[versionIndex]) : @"";
    NSDictionary *parsed = [ModpackUtils parseVersionString:verStr];
    cell.detailTextLabel.text = parsed[@"loaderVersion"] ?: verStr;
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

#pragma mark - VersionSelectorDataSource Implementation
@implementation VersionSelectorDataSource

- (instancetype)initWithVersions:(NSArray<NSString *> *)versions 
                             mod:(NSDictionary *)mod 
                         indices:(NSArray<NSNumber *> *)indices 
                        delegate:(id<VersionSelectorDelegate>)delegate {
    if (self = [super init]) {
        _versions = versions;
        _mod = mod;
        _indices = indices;
        _delegate = delegate;
    }
    return self;
}

- (NSInteger)tableView:(UITableView *)tableView numberOfRowsInSection:(NSInteger)section {
    return self.versions.count;
}

- (UITableViewCell *)tableView:(UITableView *)tableView cellForRowAtIndexPath:(NSIndexPath *)indexPath {
    UITableViewCell *cell = [tableView dequeueReusableCellWithIdentifier:@"VersionCell"];
    if (!cell) {
        cell = [[UITableViewCell alloc] initWithStyle:UITableViewCellStyleDefault reuseIdentifier:@"VersionCell"];
    }
    
    if (indexPath.row < self.versions.count) {
        cell.textLabel.text = self.versions[indexPath.row];
    }
    
    return cell;
}

- (void)tableView:(UITableView *)tableView didSelectRowAtIndexPath:(NSIndexPath *)indexPath {
    [tableView deselectRowAtIndexPath:indexPath animated:YES];
    
    if (indexPath.row < self.indices.count) {
        NSUInteger versionIndex = [self.indices[indexPath.row] unsignedIntegerValue];
        
        [self.delegate.presentedViewController dismissViewControllerAnimated:YES completion:^{
            [self.delegate handleVersionSelection:self.mod selectedVersion:versionIndex];
        }];
    }
}

@end

#pragma mark - ModMenuViewController Interface
@interface ModMenuViewController () <UISearchResultsUpdating, UITableViewDelegate, UITableViewDataSource, VersionSelectorDelegate>
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
- (void)showVersionSelectorTableForMod:(NSDictionary *)mod withVersions:(NSArray<NSString *> *)versions indices:(NSArray<NSNumber *> *)indices;
@end

#pragma mark - ModMenuViewController Implementation
@implementation ModMenuViewController

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

// Implementation of the download method with file conflict resolution.
- (void)downloadModFromURL:(NSString *)urlString toDestination:(NSString *)destinationPath completion:(void(^)(BOOL success, NSError *error))completion {
    NSURL *url = [NSURL URLWithString:urlString];
    NSURLSessionDownloadTask *downloadTask = [[NSURLSession sharedSession] downloadTaskWithURL:url
        completionHandler:^(NSURL *location, NSURLResponse *response, NSError *error) {
            if (error) {
                if (completion) completion(NO, error);
                return;
            }
            NSFileManager *fm = [NSFileManager defaultManager];
            if ([fm fileExistsAtPath:destinationPath]) {
                NSError *removeError = nil;
                [fm removeItemAtPath:destinationPath error:&removeError];
                if (removeError) {
                    if (completion) completion(NO, removeError);
                    return;
                }
            }
            NSError *fileError = nil;
            [fm moveItemAtURL:location toURL:[NSURL fileURLWithPath:destinationPath] error:&fileError];
            if (fileError) {
                if (completion) completion(NO, fileError);
            } else {
                if (completion) completion(YES, nil);
            }
    }];
    [downloadTask resume];
}

// Method to handle mod installation when a version is selected.
- (void)installModNow:(NSDictionary *)mod versionIndex:(NSUInteger)index {
    NSArray *urls = mod[@"versionUrls"];
    if (index >= urls.count) {
        presentAlertDialog(localize(@"Error", nil), @"Invalid version index for installation.");
        return;
    }
    NSString *urlString = urls[index];
    // Use the lastPathComponent of the URL to preserve the original file name.
    NSString *fileName = [[NSURL URLWithString:urlString] lastPathComponent];
    
    // Retrieve the actual gameDir path for the current profile
    NSString *profileName = [PLProfiles current].selectedProfileName;
    NSMutableDictionary *profile = [PLProfiles current].selectedProfile;
    NSString *gameDir = profile[@"gameDir"];
    
    // Ensure the profile directory exists
    [PLProfiles ensureProfileDirectoryExists:profileName gameDir:gameDir];
    
    // Get the full path to the profile directory
    NSString *profileDir = [PLProfiles fullPathForProfileWithName:profileName gameDir:gameDir];
    NSString *modsDir = [profileDir stringByAppendingPathComponent:@"mods"];
    
    // Create the mods directory if it doesn't exist
    if (![[NSFileManager defaultManager] fileExistsAtPath:modsDir]) {
        NSError *createError = nil;
        [[NSFileManager defaultManager] createDirectoryAtPath:modsDir withIntermediateDirectories:YES attributes:nil error:&createError];
        if (createError) {
            presentAlertDialog(localize(@"Error", nil), [NSString stringWithFormat:@"Failed to create mods directory: %@", createError.localizedDescription]);
            return;
        }
    }
    
    NSString *destinationPath = [modsDir stringByAppendingPathComponent:fileName];
    
    [self downloadModFromURL:urlString toDestination:destinationPath completion:^(BOOL success, NSError *error) {
        if (success) {
            presentAlertDialog(@"Installation Complete", [NSString stringWithFormat:@"%@ installed successfully.", fileName]);
        } else {
            presentAlertDialog(localize(@"Error", nil), [NSString stringWithFormat:@"Failed to install %@: %@", fileName, error.localizedDescription]);
        }
    }];
}

- (void)viewDidLoad {
    [super viewDidLoad];
    
    self.title = @"Mods";
    self.modrinth = [ModrinthAPI defaultAPI];
    // Initialize CurseForgeAPI with an empty key so the user is always prompted.
    self.curseForge = [[CurseForgeAPI alloc] initWithAPIKey:@""];
    self.searchFilters = [@{@"isModpack": @(NO), @"name": @""} mutableCopy];
    self.modsList = [NSMutableArray new];
    self.installQueue = [NSMutableArray new];
    
    // Auto-select saved profile if available.
    [self updateProfileFromSavedSettings];
    
    self.searchController = [[UISearchController alloc] initWithSearchResultsController:nil];
    self.searchController.searchResultsUpdater = self;
    self.searchController.obscuresBackgroundDuringPresentation = NO;
    self.navigationItem.searchController = self.searchController;
    
    self.apiSegmentedControl = [[UISegmentedControl alloc] initWithItems:@[@"Modrinth", @"CurseForge"]];
    self.apiSegmentedControl.selectedSegmentIndex = 0;
    [self.apiSegmentedControl addTarget:self action:@selector(updateModsList) forControlEvents:UIControlEventValueChanged];
    self.tableView.tableHeaderView = self.apiSegmentedControl;
    
    self.navigationItem.leftBarButtonItem = [[UIBarButtonItem alloc] initWithTitle:@"Profile"
                                                                             style:UIBarButtonItemStylePlain
                                                                            target:self
                                                                            action:@selector(actionChooseProfile)];
    self.navigationItem.rightBarButtonItem = [[UIBarButtonItem alloc] initWithTitle:@"Queue (0)"
                                                                              style:UIBarButtonItemStylePlain
                                                                             target:self
                                                                             action:@selector(actionShowQueue)];
    
    self.tableView.delegate = self;
    self.tableView.dataSource = self;
    
    [[NSNotificationCenter defaultCenter] addObserver:self selector:@selector(handleInstallModNotification:) name:@"InstallMod" object:nil];
    [[NSNotificationCenter defaultCenter] addObserver:self selector:@selector(handleInstallModpackNotification:) name:@"InstallModpack" object:nil];
    
    [self updateModsList];
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
        [alert addAction:[UIAlertAction actionWithTitle:profileName
                                                  style:UIAlertActionStyleDefault
                                                handler:^(UIAlertAction * _Nonnull action) {
            self.selectedProfileName = profileName;
            NSString *lastVersionId = profile[@"lastVersionId"];
            if (![lastVersionId isKindOfClass:[NSString class]]) {
                lastVersionId = [lastVersionId description];
            }
            NSDictionary *parsed = [ModpackUtils parseVersionString:lastVersionId];
            self.selectedMCVersion = parsed[@"mcVersion"] ?: lastVersionId;
            self.selectedModLoader = parsed[@"loader"] ?: @"";
            NSLog(@"Selected profile: %@, mod loader: %@, MC version: %@", self.selectedProfileName, self.selectedModLoader, self.selectedMCVersion);
            self.searchFilters[@"mcVersion"] = self.selectedMCVersion;
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
    NSDictionary *userInfo = notification.userInfo;
    NSDictionary *mod = userInfo[@"detail"];
    NSUInteger index = [userInfo[@"index"] unsignedIntegerValue];
    [self installModNow:mod versionIndex:index];
}

- (void)handleInstallModpackNotification:(NSNotification *)notification {
    NSDictionary *userInfo = notification.userInfo;
    NSDictionary *mod = userInfo[@"detail"];
    NSUInteger index = [userInfo[@"index"] unsignedIntegerValue];
    [self installModpackNow:mod versionIndex:index];
}

#pragma mark - Installation Methods
- (void)installModpackNow:(NSDictionary *)mod versionIndex:(NSUInteger)index {
    NSString *modTitle = mod[@"title"] ?: @"Modpack";
    dispatch_after(dispatch_time(DISPATCH_TIME_NOW, (int64_t)(1 * NSEC_PER_SEC)), dispatch_get_main_queue(), ^{
        presentAlertDialog(@"Installation Complete", [NSString stringWithFormat:@"%@ installed successfully.", modTitle]);
    });
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
        cell.imageView.contentMode = UIViewContentModeScaleAspectFill;
        cell.imageView.clipsToBounds = YES;
    }
    NSDictionary *mod = self.modsList[indexPath.row];
    cell.textLabel.text = mod[@"title"];
    cell.detailTextLabel.text = mod[@"description"];
    UIImage *placeholder = [UIImage imageNamed:@"DefaultProfile"];
    NSURLRequest *request = [NSURLRequest requestWithURL:[NSURL URLWithString:mod[@"imageUrl"]]];
    __weak UITableViewCell *weakCell = cell;
    [cell.imageView setImageWithURLRequest:request placeholderImage:placeholder success:^(NSURLRequest *request, NSHTTPURLResponse *response, UIImage *image) {
        if (image.size.width < 50 || image.size.height < 50) {
            weakCell.imageView.image = placeholder;
        } else {
            weakCell.imageView.image = image;
        }
        [weakCell setNeedsLayout];
    } failure:^(NSURLRequest *request, NSHTTPURLResponse *response, NSError *error) {
        weakCell.imageView.image = placeholder;
        [weakCell setNeedsLayout];
    }];
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
    NSArray *versionNames = mod[@"versionNames"];
    NSArray *gameVersionsArray = mod[@"gameVersions"] ?: mod[@"mcVersionNames"];
    NSArray *loadersArray = mod[@"versionLoaders"];
    
    NSLog(@"[DEBUG] About to show version selector with %lu versions", (unsigned long)versionNames.count);
    
    // Limit number of versions to prevent UI freezing
    const NSUInteger MAX_VERSIONS_TO_SHOW = 50;
    
    NSString *profileMCVer = [[self.selectedMCVersion stringByTrimmingCharactersInSet:[NSCharacterSet whitespaceAndNewlineCharacterSet]] lowercaseString];
    NSString *profileLoader = [[self.selectedModLoader stringByTrimmingCharactersInSet:[NSCharacterSet whitespaceAndNewlineCharacterSet]] lowercaseString];
    NSLog(@"Filtering for MC version: %@ and loader: %@", profileMCVer, profileLoader);
    
    NSMutableArray<NSNumber *> *supportedIndices = [NSMutableArray array];
    NSMutableArray<NSString *> *supportedDisplayNames = [NSMutableArray array];
    
    if (profileMCVer.length == 0 || profileLoader.length == 0) {
        for (NSUInteger i = 0; i < MIN(versionNames.count, MAX_VERSIONS_TO_SHOW); i++) {
            NSString *verStr = [self stringFromVersionObject:versionNames[i]];
            NSDictionary *parsed = [ModpackUtils parseVersionString:verStr];
            NSString *modFileVersion = parsed[@"loaderVersion"] ?: verStr;
            [supportedIndices addObject:@(i)];
            [supportedDisplayNames addObject:modFileVersion];
        }
    } else {
        for (NSUInteger i = 0; i < versionNames.count; i++) {
            NSArray *gameVers = @[];
            if (i < gameVersionsArray.count) {
                id gameVerItem = gameVersionsArray[i];
                gameVers = [gameVerItem isKindOfClass:[NSArray class]] ? gameVerItem : @[gameVerItem];
            }
            BOOL mcMatch = NO;
            for (NSString *gv in gameVers) {
                if (![gv isKindOfClass:[NSString class]]) continue;
                
                NSString *trimmedGV = [[gv stringByTrimmingCharactersInSet:[NSCharacterSet whitespaceAndNewlineCharacterSet]] lowercaseString];
                if ([trimmedGV isEqualToString:profileMCVer] ||
                    [trimmedGV hasPrefix:profileMCVer] ||
                    [profileMCVer hasPrefix:trimmedGV]) {
                    mcMatch = YES;
                    break;
                }
            }
            NSArray *versionLoaders = @[];
            if (loadersArray && i < loadersArray.count) {
                id loaderItem = loadersArray[i];
                versionLoaders = [loaderItem isKindOfClass:[NSArray class]] ? loaderItem : (loaderItem ? @[loaderItem] : @[]);
            }
            BOOL loaderMatch = NO;
            for (NSString *ld in versionLoaders) {
                if (![ld isKindOfClass:[NSString class]]) continue;
                
                NSString *trimmedLD = [[ld stringByTrimmingCharactersInSet:[NSCharacterSet whitespaceAndNewlineCharacterSet]] lowercaseString];
                if ([trimmedLD isEqualToString:profileLoader]) {
                    loaderMatch = YES;
                    break;
                }
            }
            NSLog(@"Version %lu: mcMatch=%d, loaderMatch=%d", (unsigned long)i, mcMatch, loaderMatch);
            if (mcMatch && loaderMatch) {
                [supportedIndices addObject:@(i)];
                NSString *verStr = [self stringFromVersionObject:versionNames[i]];
                NSDictionary *parsed = [ModpackUtils parseVersionString:verStr];
                NSString *modFileVersion = parsed[@"loaderVersion"] ?: verStr;
                [supportedDisplayNames addObject:modFileVersion];
                
                // Limit to prevent UI freezing with too many options
                if (supportedIndices.count >= MAX_VERSIONS_TO_SHOW) {
                    break;
                }
            }
        }
        if (supportedIndices.count == 0) {
            NSLog(@"No supported versions found for mod: %@", mod[@"title"]);
            [UIAlertUtilities presentAlertWithTitle:localize(@"Error", nil) 
                                           message:@"No supported versions available for your selected profile." 
                                   viewController:self];
            return;
        }
    }
    
    NSLog(@"[DEBUG] Found %lu filtered versions to display", (unsigned long)supportedIndices.count);
    
    // Use action sheet for iPad
    if ([[UIDevice currentDevice] userInterfaceIdiom] == UIUserInterfaceIdiomPad) {
        UIAlertController *versionAlert = [UIAlertController alertControllerWithTitle:@"Select Version"
                                                                             message:nil
                                                                      preferredStyle:UIAlertControllerStyleActionSheet];
        
        for (NSUInteger j = 0; j < supportedIndices.count; j++) {
            NSUInteger idx = [supportedIndices[j] unsignedIntegerValue];
            NSString *displayName = supportedDisplayNames[j];
            
            [versionAlert addAction:[UIAlertAction actionWithTitle:displayName
                                                         style:UIAlertActionStyleDefault
                                                       handler:^(UIAlertAction * _Nonnull action) {
                [self handleVersionSelection:mod selectedVersion:idx];
            }]];
        }
        
        [versionAlert addAction:[UIAlertAction actionWithTitle:localize(@"Cancel", nil)
                                                     style:UIAlertActionStyleCancel
                                                   handler:nil]];
        
        UITableViewCell *cell = [self.tableView cellForRowAtIndexPath:indexPath];
        if (cell) {
            versionAlert.popoverPresentationController.sourceView = cell;
            versionAlert.popoverPresentationController.sourceRect = cell.bounds;
        } else {
            versionAlert.popoverPresentationController.sourceView = self.view;
            versionAlert.popoverPresentationController.sourceRect = CGRectMake(CGRectGetMidX(self.view.bounds),
                                                                                CGRectGetMidY(self.view.bounds), 1, 1);
        }
        
        [self presentViewController:versionAlert animated:YES completion:^{
            NSLog(@"Version selection alert presented for mod: %@", mod[@"title"]);
        }];
    } else {
        // For iPhone and smaller devices, use a table-based approach
        [self showVersionSelectorTableForMod:mod withVersions:supportedDisplayNames indices:supportedIndices];
    }
}

#pragma mark - VersionSelectorDelegate Implementation
- (void)handleVersionSelection:(NSDictionary *)mod selectedVersion:(NSUInteger)idx {
    UIAlertController *choiceAlert = [UIAlertController alertControllerWithTitle:@"Install or Queue?"
                                                                        message:@"Choose to install now or add to the install queue."
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
        [UIAlertUtilities presentAlertWithTitle:@"Added to Queue" 
                                       message:[NSString stringWithFormat:@"\"%@\" has been added to the install queue.", mod[@"title"]]
                               viewController:self];
    }]];
    [choiceAlert addAction:[UIAlertAction actionWithTitle:localize(@"Cancel", nil)
                                                style:UIAlertActionStyleCancel
                                              handler:nil]];
    [self presentViewController:choiceAlert animated:YES completion:nil];
}

// Table-based version selection for iPhone
- (void)showVersionSelectorTableForMod:(NSDictionary *)mod 
                          withVersions:(NSArray<NSString *> *)versions 
                               indices:(NSArray<NSNumber *> *)indices {
    UITableViewController *versionTableVC = [[UITableViewController alloc] initWithStyle:UITableViewStylePlain];
    versionTableVC.title = @"Select Version";
    
    VersionSelectorDataSource *dataSource = [[VersionSelectorDataSource alloc] 
                                         initWithVersions:versions 
                                                      mod:mod 
                                                  indices:indices 
                                                 delegate:self];
    
    versionTableVC.tableView.dataSource = dataSource;
    versionTableVC.tableView.delegate = dataSource;
    
    UINavigationController *navController = [[UINavigationController alloc] initWithRootViewController:versionTableVC];
    [self presentViewController:navController animated:YES completion:nil];
}

#pragma mark - Install Queue
- (void)updateQueueButtonTitle {
    NSUInteger count = self.installQueue.count;
    self.navigationItem.rightBarButtonItem.title = [NSString stringWithFormat:@"Queue (%lu)", (unsigned long)count];
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
    UINavigationController *nav = [[UINavigationController alloc] initWithRootViewController:queueVC];
    nav.modalPresentationStyle = UIModalPresentationPopover;
    if (nav.popoverPresentationController) {
        nav.popoverPresentationController.barButtonItem = self.navigationItem.rightBarButtonItem;
    }
    [self presentViewController:nav animated:YES completion:nil];
}
@end

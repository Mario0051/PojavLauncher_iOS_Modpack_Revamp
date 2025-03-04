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

#pragma mark - ModQueueViewController Interface
@interface ModQueueViewController : UITableViewController
@property (nonatomic, strong) NSMutableArray *queue; // Array of dictionaries: @{@"mod": modDictionary, @"versionIndex": @(index)}
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
    // Display only the mod file version (parsed loaderVersion)
    if (versionIndex < versionNames.count) {
        NSDictionary *parsed = [ModpackUtils parseVersionString:versionNames[versionIndex]];
        cell.detailTextLabel.text = parsed[@"loaderVersion"] ?: versionNames[versionIndex];
    } else {
        cell.detailTextLabel.text = @"Unknown Version";
    }
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
@property (nonatomic, strong) NSMutableArray *installQueue; // Array of dictionaries: @{@"mod": modDictionary, @"versionIndex": @(index)}
@end

#pragma mark - ModMenuViewController Implementation
@implementation ModMenuViewController

// This method handles mod installation when a version is selected.
- (void)installModNow:(NSDictionary *)mod versionIndex:(NSUInteger)index {
    NSArray *urls = mod[@"versionUrls"];
    if (index >= urls.count) {
        presentAlertDialog(localize(@"Error", nil), @"Invalid version index for installation.");
        return;
    }
    NSString *urlString = urls[index];
    NSString *modTitle = mod[@"title"] ?: @"Mod";
    NSString *fileName = [NSString stringWithFormat:@"%@.jar", modTitle];
    NSString *docsPath = NSSearchPathForDirectoriesInDomains(NSDocumentDirectory, NSUserDomainMask, YES).firstObject;
    NSString *modsDir = [docsPath stringByAppendingPathComponent:@"mods"];
    if (![[NSFileManager defaultManager] fileExistsAtPath:modsDir]) {
        [[NSFileManager defaultManager] createDirectoryAtPath:modsDir withIntermediateDirectories:YES attributes:nil error:nil];
    }
    NSString *destinationPath = [modsDir stringByAppendingPathComponent:fileName];
    
    [self downloadModFromURL:urlString toDestination:destinationPath completion:^(BOOL success, NSError *error) {
        if (success) {
            presentAlertDialog(@"Installation Complete", [NSString stringWithFormat:@"%@ installed successfully.", modTitle]);
        } else {
            presentAlertDialog(localize(@"Error", nil), [NSString stringWithFormat:@"Failed to install %@: %@", modTitle, error.localizedDescription]);
        }
    }];
}

- (void)viewDidLoad {
    [super viewDidLoad];
    
    self.title = @"Mods";
    self.modrinth = [ModrinthAPI new];
    // Initialize CurseForgeAPI with an empty key so the user is always prompted.
    self.curseForge = [[CurseForgeAPI alloc] initWithAPIKey:@""];
    self.searchFilters = [@{@"isModpack": @(NO), @"name": @""} mutableCopy];
    self.modsList = [NSMutableArray new];
    self.installQueue = [NSMutableArray new];
    
    self.searchController = [[UISearchController alloc] initWithSearchResultsController:nil];
    self.searchController.searchResultsUpdater = self;
    self.searchController.obscuresBackgroundDuringPresentation = NO;
    self.navigationItem.searchController = self.searchController;
    
    self.apiSegmentedControl = [[UISegmentedControl alloc] initWithItems:@[@"Modrinth", @"CurseForge"]];
    self.apiSegmentedControl.selectedSegmentIndex = 0;
    // When the segmented control changes, update the mods list.
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

// When updateModsList is called, if CurseForge is selected, prompt for API key before refreshing.
- (void)updateModsList {
    NSString *name = self.searchController.searchBar.text;
    self.searchFilters[@"name"] = name ?: @"";
    if (self.selectedMCVersion && self.selectedMCVersion.length > 0) {
        self.searchFilters[@"mcVersion"] = self.selectedMCVersion;
    }
    
    if (self.apiSegmentedControl.selectedSegmentIndex == 1) {
        // Always prompt for API key when using CurseForge.
        UIAlertController *alert = [UIAlertController alertControllerWithTitle:@"Enter CurseForge API Key"
                                                                       message:@"Please enter your CurseForge API key to search mods on CurseForge."
                                                                preferredStyle:UIAlertControllerStyleAlert];
        [alert addTextFieldWithConfigurationHandler:^(UITextField * _Nonnull textField) {
            textField.placeholder = @"API Key";
        }];
        [alert addAction:[UIAlertAction actionWithTitle:@"OK" style:UIAlertActionStyleDefault handler:^(UIAlertAction * _Nonnull action) {
            NSString *enteredKey = alert.textFields.firstObject.text;
            if (enteredKey.length > 0) {
                // Update the API key using KVC.
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
    
    NSLog(@"[DEBUG] versionNames count: %lu", (unsigned long)versionNames.count);
    NSLog(@"[DEBUG] gameVersionsArray count: %lu", (unsigned long)gameVersionsArray.count);
    NSLog(@"[DEBUG] loadersArray count: %lu", (unsigned long)loadersArray.count);
    
    NSString *profileMCVer = [[self.selectedMCVersion stringByTrimmingCharactersInSet:[NSCharacterSet whitespaceAndNewlineCharacterSet]] lowercaseString];
    NSString *profileLoader = [[self.selectedModLoader stringByTrimmingCharactersInSet:[NSCharacterSet whitespaceAndNewlineCharacterSet]] lowercaseString];
    NSLog(@"Filtering for MC version: %@ and loader: %@", profileMCVer, profileLoader);
    
    NSMutableArray<NSNumber *> *supportedIndices = [NSMutableArray array];
    NSMutableArray<NSString *> *supportedDisplayNames = [NSMutableArray array];
    
    if (profileMCVer.length == 0 || profileLoader.length == 0) {
        for (NSUInteger i = 0; i < versionNames.count; i++) {
            NSDictionary *parsed = [ModpackUtils parseVersionString:versionNames[i]];
            NSString *modFileVersion = parsed[@"loaderVersion"] ?: versionNames[i];
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
                NSString *trimmedLD = [[ld stringByTrimmingCharactersInSet:[NSCharacterSet whitespaceAndNewlineCharacterSet]] lowercaseString];
                if ([trimmedLD isEqualToString:profileLoader]) {
                    loaderMatch = YES;
                    break;
                }
            }
            NSLog(@"Version %lu: mcMatch=%d, loaderMatch=%d", (unsigned long)i, mcMatch, loaderMatch);
            if (mcMatch && loaderMatch) {
                [supportedIndices addObject:@(i)];
                NSDictionary *parsed = [ModpackUtils parseVersionString:versionNames[i]];
                NSString *modFileVersion = parsed[@"loaderVersion"] ?: versionNames[i];
                [supportedDisplayNames addObject:modFileVersion];
            }
        }
        if (supportedIndices.count == 0) {
            NSLog(@"No supported versions found for mod: %@", mod[@"title"]);
            presentAlertDialog(localize(@"Error", nil), @"No supported versions available for your selected profile.");
            return;
        }
    }
    
    UIAlertController *versionAlert = [UIAlertController alertControllerWithTitle:@"Select Version"
                                                                          message:nil
                                                                   preferredStyle:UIAlertControllerStyleActionSheet];
    for (NSUInteger j = 0; j < supportedIndices.count; j++) {
        NSUInteger idx = [supportedIndices[j] unsignedIntegerValue];
        NSString *displayName = supportedDisplayNames[j];
        [versionAlert addAction:[UIAlertAction actionWithTitle:displayName
                                                         style:UIAlertActionStyleDefault
                                                       handler:^(UIAlertAction * _Nonnull action) {
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
                presentAlertDialog(@"Added to Queue", [NSString stringWithFormat:@"\"%@\" has been added to the install queue.", mod[@"title"]]);
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
    if (versionAlert.popoverPresentationController) {
        UITableViewCell *cell = [self.tableView cellForRowAtIndexPath:indexPath];
        if (cell) {
            versionAlert.popoverPresentationController.sourceView = cell;
            versionAlert.popoverPresentationController.sourceRect = cell.bounds;
        } else {
            versionAlert.popoverPresentationController.sourceView = self.view;
            versionAlert.popoverPresentationController.sourceRect = CGRectMake(CGRectGetMidX(self.view.bounds),
                                                                             CGRectGetMidY(self.view.bounds), 1, 1);
        }
    }
    [self presentViewController:versionAlert animated:YES completion:^{
        NSLog(@"Version selection alert presented for mod: %@", mod[@"title"]);
    }];
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

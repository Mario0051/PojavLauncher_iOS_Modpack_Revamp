#import "ModMenuViewController.h"
#import "modpack/ModrinthAPI.h"
#import "modpack/CurseForgeAPI.h"
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
    NSLog(@"ModQueueViewController loaded.");
    
    self.navigationItem.rightBarButtonItem = [[UIBarButtonItem alloc] initWithTitle:@"Install"
                                                                              style:UIBarButtonItemStyleDone
                                                                             target:self
                                                                             action:@selector(installQueueAction)];
    self.navigationItem.leftBarButtonItem = self.editButtonItem;
}
- (void)installQueueAction {
    NSLog(@"Install queue action triggered. Queue count: %lu", (unsigned long)self.queue.count);
    if (self.queue.count == 0) {
        presentAlertDialog(localize(@"Queue Empty", nil), @"There are no mods in the install queue.");
        return;
    }
    for (NSDictionary *entry in self.queue) {
        NSDictionary *mod = entry[@"mod"];
        NSUInteger versionIndex = [entry[@"versionIndex"] unsignedIntegerValue];
        NSNumber *apiSource = mod[@"apiSource"];
        NSLog(@"Installing mod: %@ at version index: %lu", mod[@"title"], (unsigned long)versionIndex);
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
    NSLog(@"Queue table rows: %lu", (unsigned long)self.queue.count);
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
    cell.detailTextLabel.text = (versionIndex < versionNames.count ? versionNames[versionIndex] : @"Unknown Version");
    return cell;
}
- (void)tableView:(UITableView *)tableView commitEditingStyle:(UITableViewCellEditingStyle)editingStyle 
 forRowAtIndexPath:(NSIndexPath *)indexPath {
    if (editingStyle == UITableViewCellEditingStyleDelete) {
        NSLog(@"Deleting queue entry at index: %ld", (long)indexPath.row);
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
// New properties for both Minecraft version and mod loader.
@property (nonatomic, strong) NSString *selectedMCVersion;
@property (nonatomic, strong) NSString *selectedModLoader;
@property (nonatomic, strong) NSMutableArray *installQueue; // Array of dictionaries: @{@"mod": modDictionary, @"versionIndex": @(index)}
@end

#pragma mark - ModMenuViewController Implementation
@implementation ModMenuViewController
- (void)viewDidLoad {
    [super viewDidLoad];
    
    NSLog(@"ModMenuViewController loaded.");
    self.title = @"Mods";
    self.modrinth = [ModrinthAPI new];
    self.curseForge = [[CurseForgeAPI alloc] initWithAPIKey:(CONFIG_CURSEFORGE_API_KEY ?: @"")];
    self.searchFilters = [@{@"isModpack": @(NO), @"name": @""} mutableCopy];
    self.modsList = [NSMutableArray new];
    self.installQueue = [NSMutableArray new];
    
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
    
    [self updateModsList];
}
#pragma mark - Profile Selection
- (void)actionChooseProfile {
    NSDictionary *profiles = [PLProfiles current].profiles;
    if (!profiles || profiles.count == 0) {
        presentAlertDialog(localize(@"Error", nil), @"No profiles available.");
        return;
    }
    NSLog(@"Available profiles: %@", profiles);
    
    UIAlertController *alert = [UIAlertController alertControllerWithTitle:@"Select Profile"
                                                                   message:nil
                                                            preferredStyle:UIAlertControllerStyleActionSheet];
    for (NSDictionary *profile in profiles.allValues) {
        NSString *name = profile[@"name"];
        [alert addAction:[UIAlertAction actionWithTitle:name
                                                  style:UIAlertActionStyleDefault
                                                handler:^(UIAlertAction * _Nonnull action) {
            self.selectedProfileName = name;
            // Parse lastVersionId with different logic for Forge and Fabric.
            // If it has three components (e.g. "1.20-forge-46.0.14"), treat as Forge.
            // If it has four or more components (e.g. "fabric-loader-0.16.10-1.20.1"), treat as Fabric.
            NSString *lastVersionId = [[[profile[@"lastVersionId"] stringByTrimmingCharactersInSet:[NSCharacterSet whitespaceAndNewlineCharacterSet]] lowercaseString] copy];
            NSArray *components = [lastVersionId componentsSeparatedByString:@"-"];
            if (components.count == 3) {
                // Forge format.
                self.selectedMCVersion = components[0];
                self.selectedModLoader = components[1];
            } else if (components.count >= 4) {
                // Fabric format.
                self.selectedModLoader = components[0];
                self.selectedMCVersion = [components lastObject];
            } else {
                self.selectedModLoader = @"";
                self.selectedMCVersion = lastVersionId;
            }
            NSLog(@"Selected profile: %@, mod loader: %@, Minecraft version: %@", self.selectedProfileName, self.selectedModLoader, self.selectedMCVersion);
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
    [self presentViewController:alert animated:YES completion:^{
        NSLog(@"Profile selection alert presented.");
    }];
}
#pragma mark - Mod Search
- (void)updateModsList {
    NSString *name = self.searchController.searchBar.text;
    NSLog(@"Updating mods list with search term: %@", name);
    self.searchFilters[@"name"] = name ?: @"";
    if (self.selectedMCVersion && self.selectedMCVersion.length > 0) {
        self.searchFilters[@"mcVersion"] = self.selectedMCVersion;
    }
    [self.modsList removeAllObjects];
    [self refreshModsListWithPrevList:NO];
}
- (void)refreshModsListWithPrevList:(BOOL)prevList {
    NSLog(@"Refreshing mods list. Previous list: %@", prevList ? @"YES" : @"NO");
    if (self.apiSegmentedControl.selectedSegmentIndex == 0) {
        __weak typeof(self) weakSelf = self;
        dispatch_async(dispatch_get_global_queue(DISPATCH_QUEUE_PRIORITY_DEFAULT, 0), ^{
            NSMutableArray *results = [weakSelf.modrinth searchModWithFilters:weakSelf.searchFilters previousPageResult:(prevList ? weakSelf.modsList : nil)];
            NSLog(@"Modrinth search returned %lu results", (unsigned long)results.count);
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
            NSLog(@"CurseForge search returned %lu results", (unsigned long)results.count);
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
    NSLog(@"Table view number of mods: %lu", (unsigned long)self.modsList.count);
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
    [cell.imageView setImageWithURL:[NSURL URLWithString:mod[@"imageUrl"]] placeholderImage:placeholder];
    NSLog(@"Configured mod cell: %@", mod[@"title"]);
    return cell;
}
#pragma mark - UITableView Delegate
- (void)tableView:(UITableView *)tableView didSelectRowAtIndexPath:(NSIndexPath *)indexPath {
    NSDictionary *mod = self.modsList[indexPath.row];
    NSLog(@"Selected mod: %@", mod[@"title"]);
    if ([mod[@"versionDetailsLoaded"] boolValue]) {
        [self showModDetails:mod atIndexPath:indexPath];
    } else {
        [tableView deselectRowAtIndexPath:indexPath animated:YES];
        [self loadModDetailsForMod:mod atIndexPath:indexPath];
    }
}
- (void)loadModDetailsForMod:(NSDictionary *)mod atIndexPath:(NSIndexPath *)indexPath {
    NSMutableDictionary *modMutable = [mod mutableCopy];
    NSLog(@"Loading details for mod: %@", mod[@"title"]);
    __weak typeof(self) weakSelf = self;
    if (self.apiSegmentedControl.selectedSegmentIndex == 0) {
        dispatch_async(dispatch_get_global_queue(DISPATCH_QUEUE_PRIORITY_DEFAULT, 0), ^{
            [weakSelf.modrinth loadDetailsOfMod:modMutable completion:^(NSError *error) {
                dispatch_async(dispatch_get_main_queue(), ^{
                    __strong typeof(weakSelf) strongSelf = weakSelf;
                    if ([modMutable[@"versionDetailsLoaded"] boolValue]) {
                        NSLog(@"Loaded %lu versions for mod: %@", (unsigned long)[modMutable[@"versionNames"] count], mod[@"title"]);
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
                    NSLog(@"Loaded %lu versions for mod: %@", (unsigned long)[modMutable[@"versionNames"] count], mod[@"title"]);
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
    NSLog(@"Mod %@ has versionNames: %@", mod[@"title"], versionNames);
    NSLog(@"Game versions: %@", gameVersionsArray);
    NSLog(@"Loaders: %@", loadersArray);
    
    NSMutableArray<NSNumber *> *supportedIndices = [NSMutableArray array];
    NSMutableArray<NSString *> *supportedDisplayNames = [NSMutableArray array];
    
    if (self.selectedMCVersion.length == 0 || self.selectedModLoader.length == 0) {
        for (NSUInteger i = 0; i < versionNames.count; i++) {
            [supportedIndices addObject:@(i)];
            [supportedDisplayNames addObject:versionNames[i]];
        }
    } else {
        NSString *profileMCVer = [[self.selectedMCVersion stringByTrimmingCharactersInSet:[NSCharacterSet whitespaceAndNewlineCharacterSet]] lowercaseString];
        NSString *profileLoader = [[self.selectedModLoader stringByTrimmingCharactersInSet:[NSCharacterSet whitespaceAndNewlineCharacterSet]] lowercaseString];
        NSLog(@"Filtering for MC version: %@ and loader: %@", profileMCVer, profileLoader);
        for (NSUInteger i = 0; i < versionNames.count; i++) {
            id gameVerItem = gameVersionsArray[i];
            NSArray *gameVers = [gameVerItem isKindOfClass:[NSArray class]] ? gameVerItem : (@[gameVerItem]);
            BOOL mcMatch = NO;
            for (NSString *gv in gameVers) {
                NSString *trimmedGV = [[gv stringByTrimmingCharactersInSet:[NSCharacterSet whitespaceAndNewlineCharacterSet]] lowercaseString];
                // Relax matching: check if one is a prefix of the other.
                if ([trimmedGV isEqualToString:profileMCVer] || [trimmedGV hasPrefix:profileMCVer] || [profileMCVer hasPrefix:trimmedGV]) {
                    mcMatch = YES;
                    break;
                }
            }
            id loaderItem = (loadersArray && loadersArray.count > i) ? loadersArray[i] : nil;
            NSArray *versionLoaders = [loaderItem isKindOfClass:[NSArray class]] ? loaderItem : (loaderItem ? @[loaderItem] : @[]);
            BOOL loaderMatch = NO;
            for (NSString *ld in versionLoaders) {
                NSString *trimmedLD = [[ld stringByTrimmingCharactersInSet:[NSCharacterSet whitespaceAndNewlineCharacterSet]] lowercaseString];
                if ([trimmedLD isEqualToString:profileLoader]) {
                    loaderMatch = YES;
                    break;
                }
            }
            if (mcMatch && loaderMatch) {
                [supportedIndices addObject:@(i)];
                NSString *displayName = [versionNames[i] stringByAppendingFormat:@" (%@ / %@)",
                                          [gameVers componentsJoinedByString:@", "],
                                          (versionLoaders.count > 0 ? [versionLoaders componentsJoinedByString:@", "] : @"")];
                [supportedDisplayNames addObject:displayName];
            }
        }
        if (supportedIndices.count == 0) {
            NSLog(@"No supported versions found for mod: %@", mod[@"title"]);
            presentAlertDialog(localize(@"Error", nil), @"No supported versions available for your selected profile.");
            return;
        }
    }
    
    NSLog(@"Supported indices: %@", supportedIndices);
    NSLog(@"Supported display names: %@", supportedDisplayNames);
    
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
                NSLog(@"User chose to install mod: %@, version index: %lu", mod[@"title"], (unsigned long)idx);
                if (self.apiSegmentedControl.selectedSegmentIndex == 0) {
                    [self.modrinth installModFromDetail:mod atIndex:idx];
                } else {
                    if ([mod[@"isModpack"] boolValue]) {
                        [self.curseForge installModpackFromDetail:mod atIndex:idx completion:^(NSError *error) {
                            if (error) {
                                presentAlertDialog(localize(@"Error", nil), error.localizedDescription);
                            }
                        }];
                    } else {
                        [self.curseForge installModFromDetail:mod atIndex:idx];
                    }
                }
            }]];
            [choiceAlert addAction:[UIAlertAction actionWithTitle:@"Add to Queue"
                                                            style:UIAlertActionStyleDefault
                                                          handler:^(UIAlertAction * _Nonnull action) {
                NSDictionary *queueEntry = @{@"mod": mod, @"versionIndex": @(idx)};
                [self.installQueue addObject:queueEntry];
                [self updateQueueButtonTitle];
                presentAlertDialog(@"Added to Queue", [NSString stringWithFormat:@"\"%@\" has been added to the install queue.", mod[@"title"]]);
                NSLog(@"Mod added to install queue: %@, version index: %lu", mod[@"title"], (unsigned long)idx);
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
    NSLog(@"Queue button updated, count: %lu", (unsigned long)count);
}
- (void)actionShowQueue {
    ModQueueViewController *queueVC = [ModQueueViewController new];
    queueVC.queue = self.installQueue;
    __weak typeof(self) weakSelf = self;
    queueVC.didFinishInstallation = ^{
        __strong typeof(weakSelf) strongSelf = weakSelf;
        [strongSelf.installQueue removeAllObjects];
        [strongSelf updateQueueButtonTitle];
        NSLog(@"Install queue cleared after installation.");
    };
    UINavigationController *nav = [[UINavigationController alloc] initWithRootViewController:queueVC];
    nav.modalPresentationStyle = UIModalPresentationPopover;
    if (nav.popoverPresentationController) {
        nav.popoverPresentationController.barButtonItem = self.navigationItem.rightBarButtonItem;
    }
    [self presentViewController:nav animated:YES completion:^{
        NSLog(@"Install queue view presented.");
    }];
}
@end

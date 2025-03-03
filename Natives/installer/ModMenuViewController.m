#import "ModMenuViewController.h"
#import "modpack/ModrinthAPI.h"
#import "modpack/CurseForgeAPI.h"
#import "config.h"
#import "UIKit+AFNetworking.h"
#import "utils.h"
#import "PLProfiles.h"

#pragma mark - Debug Logging to File
// Writes debug logs to console and appends them to Documents/debug.log.
static void DebugLogToFile(NSString *format, ...) {
    va_list args;
    va_start(args, format);
    NSString *logMsg = [[NSString alloc] initWithFormat:format arguments:args];
    va_end(args);
    
    NSLog(@"DEBUG: %@", logMsg);
    
    NSDateFormatter *formatter = [[NSDateFormatter alloc] init];
    [formatter setDateFormat:@"yyyy-MM-dd HH:mm:ss"];
    NSString *timeStamp = [formatter stringFromDate:[NSDate date]];
    NSString *timeStampedLog = [NSString stringWithFormat:@"%@: %@\n", timeStamp, logMsg];
    
    NSArray *paths = NSSearchPathForDirectoriesInDomains(NSDocumentDirectory, NSUserDomainMask, YES);
    NSString *documentsDirectory = [paths firstObject];
    NSString *filePath = [documentsDirectory stringByAppendingPathComponent:@"debug.log"];
    
    NSFileHandle *fileHandle = [NSFileHandle fileHandleForWritingAtPath:filePath];
    if (!fileHandle) {
        NSError *error = nil;
        BOOL success = [[NSFileManager defaultManager] createFileAtPath:filePath contents:[timeStampedLog dataUsingEncoding:NSUTF8StringEncoding] attributes:nil];
        if (!success || error) {
            NSLog(@"Failed to create debug log file: %@", error.localizedDescription);
        }
    } else {
        [fileHandle seekToEndOfFile];
        [fileHandle writeData:[timeStampedLog dataUsingEncoding:NSUTF8StringEncoding]];
        [fileHandle closeFile];
    }
}

#ifdef DEBUG
    #define DEBUG_LOG(fmt, ...) DebugLogToFile((@"DEBUG: " fmt), ##__VA_ARGS__)
#else
    #define DEBUG_LOG(...)
#endif

#pragma mark - Alert Dialog Helper
static inline void presentAlertDialog(NSString *title, NSString *message) {
    DEBUG_LOG(@"Presenting alert: %@ - %@", title, message);
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
    DEBUG_LOG(@"ModQueueViewController loaded.");
    
    self.navigationItem.rightBarButtonItem = [[UIBarButtonItem alloc] initWithTitle:@"Install"
                                                                              style:UIBarButtonItemStyleDone
                                                                             target:self
                                                                             action:@selector(installQueueAction)];
    self.navigationItem.leftBarButtonItem = self.editButtonItem;
}
- (void)installQueueAction {
    DEBUG_LOG(@"Install queue action triggered. Queue count: %lu", (unsigned long)self.queue.count);
    if (self.queue.count == 0) {
        presentAlertDialog(localize(@"Queue Empty", nil), @"There are no mods in the install queue.");
        return;
    }
    for (NSDictionary *entry in self.queue) {
        NSDictionary *mod = entry[@"mod"];
        NSUInteger versionIndex = [entry[@"versionIndex"] unsignedIntegerValue];
        NSNumber *apiSource = mod[@"apiSource"];
        DEBUG_LOG(@"Installing mod: %@ at version index: %lu", mod[@"title"], (unsigned long)versionIndex);
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
    DEBUG_LOG(@"Queue table number of rows: %lu", (unsigned long)self.queue.count);
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
    if (versionIndex < versionNames.count) {
        cell.detailTextLabel.text = versionNames[versionIndex];
    } else {
        cell.detailTextLabel.text = @"Unknown Version";
    }
    DEBUG_LOG(@"Queue cell configured for mod: %@, version: %@", mod[@"title"], cell.detailTextLabel.text);
    return cell;
}
- (void)tableView:(UITableView *)tableView commitEditingStyle:(UITableViewCellEditingStyle)editingStyle 
 forRowAtIndexPath:(NSIndexPath *)indexPath {
    if (editingStyle == UITableViewCellEditingStyleDelete) {
        DEBUG_LOG(@"Deleting queue entry at index: %ld", (long)indexPath.row);
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
// Install queue for mods awaiting installation.
@property (nonatomic, strong) NSMutableArray *installQueue; // Array of dictionaries: @{@"mod": modDictionary, @"versionIndex": @(index)}
@end

#pragma mark - ModMenuViewController Implementation
@implementation ModMenuViewController
- (void)viewDidLoad {
    [super viewDidLoad];
    
    DEBUG_LOG(@"ModMenuViewController loaded.");
    self.title = @"Mods";
    self.modrinth = [ModrinthAPI new];
    self.curseForge = [[CurseForgeAPI alloc] initWithAPIKey:(CONFIG_CURSEFORGE_API_KEY ?: @"")];
    self.searchFilters = [@{@"isModpack": @(NO), @"name": @""} mutableCopy];
    self.modsList = [NSMutableArray new];
    self.installQueue = [NSMutableArray new];
    
    // Setup modern search controller.
    self.searchController = [[UISearchController alloc] initWithSearchResultsController:nil];
    self.searchController.searchResultsUpdater = self;
    self.searchController.obscuresBackgroundDuringPresentation = NO;
    self.navigationItem.searchController = self.searchController;
    
    // Setup API segmented control.
    self.apiSegmentedControl = [[UISegmentedControl alloc] initWithItems:@[@"Modrinth", @"CurseForge"]];
    self.apiSegmentedControl.selectedSegmentIndex = 0;
    [self.apiSegmentedControl addTarget:self action:@selector(updateModsList) forControlEvents:UIControlEventValueChanged];
    self.tableView.tableHeaderView = self.apiSegmentedControl;
    
    // Left: Profile selection; Right: Install queue.
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
    DEBUG_LOG(@"Available profiles: %@", profiles);
    
    UIAlertController *alert = [UIAlertController alertControllerWithTitle:@"Select Profile"
                                                                   message:nil
                                                            preferredStyle:UIAlertControllerStyleActionSheet];
    for (NSDictionary *profile in profiles.allValues) {
        NSString *name = profile[@"name"];
        [alert addAction:[UIAlertAction actionWithTitle:name
                                                  style:UIAlertActionStyleDefault
                                                handler:^(UIAlertAction * _Nonnull action) {
            self.selectedProfileName = name;
            // Parse lastVersionId in the format: "<gameVersion>-<loader>-<loaderVersion>"
            NSString *lastVersionId = [[[profile[@"lastVersionId"] stringByTrimmingCharactersInSet:[NSCharacterSet whitespaceAndNewlineCharacterSet]] lowercaseString] copy];
            NSRange dashRange = [lastVersionId rangeOfString:@"-"];
            if (dashRange.location != NSNotFound) {
                self.selectedMCVersion = [lastVersionId substringToIndex:dashRange.location];
            } else {
                self.selectedMCVersion = lastVersionId;
            }
            DEBUG_LOG(@"Selected profile: %@, parsed Minecraft version: %@", self.selectedProfileName, self.selectedMCVersion);
            // Update search filters with the selected Minecraft version.
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
        DEBUG_LOG(@"Profile selection alert presented.");
    }];
}
#pragma mark - Mod Search
- (void)updateModsList {
    NSString *name = self.searchController.searchBar.text;
    DEBUG_LOG(@"Updating mods list with search term: %@", name);
    self.searchFilters[@"name"] = name ?: @"";
    // Ensure the selected MC version is in the filters.
    if (self.selectedMCVersion && self.selectedMCVersion.length > 0) {
        self.searchFilters[@"mcVersion"] = self.selectedMCVersion;
    }
    [self.modsList removeAllObjects];
    [self refreshModsListWithPrevList:NO];
}
- (void)refreshModsListWithPrevList:(BOOL)prevList {
    DEBUG_LOG(@"Refreshing mods list. Previous list: %@", prevList ? @"YES" : @"NO");
    if (self.apiSegmentedControl.selectedSegmentIndex == 0) {
        __weak typeof(self) weakSelf = self;
        dispatch_async(dispatch_get_global_queue(DISPATCH_QUEUE_PRIORITY_DEFAULT, 0), ^{
            NSMutableArray *results = [weakSelf.modrinth searchModWithFilters:weakSelf.searchFilters previousPageResult:(prevList ? weakSelf.modsList : nil)];
            DEBUG_LOG(@"Modrinth search returned %lu results", (unsigned long)results.count);
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
            DEBUG_LOG(@"CurseForge search returned %lu results", (unsigned long)results.count);
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
    DEBUG_LOG(@"Table view number of mods: %lu", (unsigned long)self.modsList.count);
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
    DEBUG_LOG(@"Configured mod cell: %@", mod[@"title"]);
    return cell;
}
#pragma mark - UITableView Delegate
- (void)tableView:(UITableView *)tableView didSelectRowAtIndexPath:(NSIndexPath *)indexPath {
    NSDictionary *mod = self.modsList[indexPath.row];
    DEBUG_LOG(@"Selected mod: %@", mod[@"title"]);
    if ([mod[@"versionDetailsLoaded"] boolValue]) {
        [self showModDetails:mod atIndexPath:indexPath];
    } else {
        [tableView deselectRowAtIndexPath:indexPath animated:YES];
        [self loadModDetailsForMod:mod atIndexPath:indexPath];
    }
}
- (void)loadModDetailsForMod:(NSDictionary *)mod atIndexPath:(NSIndexPath *)indexPath {
    NSMutableDictionary *modMutable = [mod mutableCopy];
    DEBUG_LOG(@"Loading details for mod: %@", mod[@"title"]);
    __weak typeof(self) weakSelf = self;
    if (self.apiSegmentedControl.selectedSegmentIndex == 0) {
        dispatch_async(dispatch_get_global_queue(DISPATCH_QUEUE_PRIORITY_DEFAULT, 0), ^{
            [weakSelf.modrinth loadDetailsOfMod:modMutable completion:^(NSError *error) {
                dispatch_async(dispatch_get_main_queue(), ^{
                    __strong typeof(weakSelf) strongSelf = weakSelf;
                    if ([modMutable[@"versionDetailsLoaded"] boolValue]) {
                        DEBUG_LOG(@"Loaded %lu versions for mod: %@", (unsigned long)[modMutable[@"versionNames"] count], mod[@"title"]);
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
                    DEBUG_LOG(@"Loaded %lu versions for mod: %@", (unsigned long)[modMutable[@"versionNames"] count], mod[@"title"]);
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
    // Use 'gameVersions' for Modrinth; fallback to 'mcVersionNames' for CurseForge.
    NSArray *gameVersionsArray = mod[@"gameVersions"] ?: mod[@"mcVersionNames"];
    DEBUG_LOG(@"Mod %@ has versionNames: %@", mod[@"title"], versionNames);
    DEBUG_LOG(@"Game versions: %@", gameVersionsArray);
    
    NSMutableArray<NSNumber *> *supportedIndices = [NSMutableArray array];
    NSMutableArray<NSString *> *supportedDisplayNames = [NSMutableArray array];
    
    if (self.selectedMCVersion.length == 0) {
        for (NSUInteger i = 0; i < versionNames.count; i++) {
            [supportedIndices addObject:@(i)];
            [supportedDisplayNames addObject:versionNames[i]];
        }
    } else {
        // Use exact, case-insensitive matching per Modrinth API.
        NSString *profileVersion = [[[self.selectedMCVersion stringByTrimmingCharactersInSet:[NSCharacterSet whitespaceAndNewlineCharacterSet]] lowercaseString] copy];
        DEBUG_LOG(@"Filtering versions for profile version: %@", profileVersion);
        for (NSUInteger i = 0; i < versionNames.count; i++) {
            id gvItem = gameVersionsArray[i];
            NSArray *gv = [gvItem isKindOfClass:[NSArray class]] ? gvItem : (@[gvItem]);
            if (gv.count == 0) continue;
            BOOL match = NO;
            for (NSString *gameVer in gv) {
                NSString *trimmedGameVer = [[[gameVer stringByTrimmingCharactersInSet:[NSCharacterSet whitespaceAndNewlineCharacterSet]] lowercaseString] copy];
                DEBUG_LOG(@"Comparing game version '%@' with profile version '%@'", trimmedGameVer, profileVersion);
                if ([trimmedGameVer isEqualToString:profileVersion]) {
                    match = YES;
                    break;
                }
            }
            if (match) {
                [supportedIndices addObject:@(i)];
                NSString *displayName = [versionNames[i] stringByAppendingFormat:@" (%@)", [gv componentsJoinedByString:@", "]];
                [supportedDisplayNames addObject:displayName];
            }
        }
        if (supportedIndices.count == 0) {
            DEBUG_LOG(@"No supported versions found for mod: %@", mod[@"title"]);
            presentAlertDialog(localize(@"Error", nil), @"No supported versions available for your selected profile.");
            return;
        }
    }
    
    DEBUG_LOG(@"Supported indices: %@", supportedIndices);
    DEBUG_LOG(@"Supported display names: %@", supportedDisplayNames);
    
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
                DEBUG_LOG(@"User chose to install mod: %@, version index: %lu", mod[@"title"], (unsigned long)idx);
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
                DEBUG_LOG(@"Mod added to install queue: %@, version index: %lu", mod[@"title"], (unsigned long)idx);
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
        DEBUG_LOG(@"Version selection alert presented for mod: %@", mod[@"title"]);
    }];
}
#pragma mark - Install Queue
- (void)updateQueueButtonTitle {
    NSUInteger count = self.installQueue.count;
    self.navigationItem.rightBarButtonItem.title = [NSString stringWithFormat:@"Queue (%lu)", (unsigned long)count];
    DEBUG_LOG(@"Queue button updated, count: %lu", (unsigned long)count);
}
- (void)actionShowQueue {
    ModQueueViewController *queueVC = [ModQueueViewController new];
    queueVC.queue = self.installQueue;
    __weak typeof(self) weakSelf = self;
    queueVC.didFinishInstallation = ^{
        __strong typeof(weakSelf) strongSelf = weakSelf;
        [strongSelf.installQueue removeAllObjects];
        [strongSelf updateQueueButtonTitle];
        DEBUG_LOG(@"Install queue cleared after installation.");
    };
    UINavigationController *nav = [[UINavigationController alloc] initWithRootViewController:queueVC];
    nav.modalPresentationStyle = UIModalPresentationPopover;
    if (nav.popoverPresentationController) {
        nav.popoverPresentationController.barButtonItem = self.navigationItem.rightBarButtonItem;
    }
    [self presentViewController:nav animated:YES completion:^{
        DEBUG_LOG(@"Install queue view presented.");
    }];
}
@end

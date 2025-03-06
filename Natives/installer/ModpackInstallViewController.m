#import "ModpackInstallViewController.h"
#import "modpack/ModrinthAPI.h"
#import "modpack/CurseForgeAPI.h"
#import "ModpackUtils.h"
#import "AFNetworking.h"
#import "LauncherNavigationController.h"
#import "UIKit+AFNetworking.h"
#import "UIKit+hook.h"
#import "WFWorkflowProgressView.h"
#import "config.h"
#import "ios_uikit_bridge.h"
#import "utils.h"
#import "PLProfiles.h"
#import "UIAlertUtilities.h"
#include <dlfcn.h>

#pragma mark - ModpackVersionSelectorDataSource Interface and Implementation
@interface ModpackVersionSelectorDataSource : NSObject <UITableViewDataSource, UITableViewDelegate>
@property (nonatomic, strong) NSArray<UIAction *> *versionActions;
@property (nonatomic, strong) NSDictionary *modpack;
@property (nonatomic, weak) ModpackInstallViewController *delegate;
@end

@implementation ModpackVersionSelectorDataSource

- (instancetype)initWithVersionActions:(NSArray<UIAction *> *)versionActions 
                               modpack:(NSDictionary *)modpack 
                              delegate:(ModpackInstallViewController *)delegate {
    if (self = [super init]) {
        _versionActions = versionActions;
        _modpack = modpack;
        _delegate = delegate;
    }
    return self;
}

- (NSInteger)tableView:(UITableView *)tableView numberOfRowsInSection:(NSInteger)section {
    return self.versionActions.count;
}

- (UITableViewCell *)tableView:(UITableView *)tableView cellForRowAtIndexPath:(NSIndexPath *)indexPath {
    UITableViewCell *cell = [tableView dequeueReusableCellWithIdentifier:@"VersionCell"];
    if (!cell) {
        cell = [[UITableViewCell alloc] initWithStyle:UITableViewCellStyleDefault reuseIdentifier:@"VersionCell"];
    }
    
    if (indexPath.row < self.versionActions.count) {
        cell.textLabel.text = self.versionActions[indexPath.row].title;
    }
    
    return cell;
}

- (void)tableView:(UITableView *)tableView didSelectRowAtIndexPath:(NSIndexPath *)indexPath {
    [tableView deselectRowAtIndexPath:indexPath animated:YES];
    
    if (indexPath.row < self.versionActions.count) {
        [self.delegate.presentedViewController dismissViewControllerAnimated:YES completion:^{
            [self.delegate installModpackFromDetail:self.modpack atIndex:indexPath.row];
        }];
    }
}

@end

@interface ModpackInstallViewController () <UISearchResultsUpdating, UIContextMenuInteractionDelegate>
@property (nonatomic, strong) UISearchController *searchController;
@property (nonatomic, strong) UISegmentedControl *apiSegmentedControl;
@property (nonatomic, strong) NSMutableArray *list;
@property (nonatomic, strong) NSMutableDictionary *filters;
@property (nonatomic, strong) ModrinthAPI *modrinth;
@property (nonatomic, strong) CurseForgeAPI *curseForge;
@property (nonatomic, assign) BOOL hasPromptedForAPIKey;
- (void)installModpackFromDetail:(NSDictionary *)details atIndex:(NSUInteger)index;
- (void)showVersionSelectorTableForModpack:(NSDictionary *)modpack withVersions:(NSArray<UIAction *> *)versionActions;
@end

@implementation ModpackInstallViewController

- (void)viewDidLoad {
    [super viewDidLoad];
    
    // Initialize our modpack APIs
    self.modrinth = [ModrinthAPI defaultAPI];
    self.curseForge = [[CurseForgeAPI alloc] initWithAPIKey:@""];
    self.hasPromptedForAPIKey = NO;
    
    // Setup search controller
    self.searchController = [[UISearchController alloc] initWithSearchResultsController:nil];
    self.searchController.searchResultsUpdater = self;
    self.searchController.obscuresBackgroundDuringPresentation = NO;
    self.navigationItem.searchController = self.searchController;
    
    // Add API selection segmented control
    self.apiSegmentedControl = [[UISegmentedControl alloc] initWithItems:@[@"Modrinth", @"CurseForge"]];
    self.apiSegmentedControl.selectedSegmentIndex = 0;
    [self.apiSegmentedControl addTarget:self action:@selector(apiSourceChanged:) forControlEvents:UIControlEventValueChanged];
    self.tableView.tableHeaderView = self.apiSegmentedControl;
    
    // Set filter for modpacks only
    self.filters = [@{@"isModpack": @(YES), @"name": @" "} mutableCopy];
    
    [self updateSearchResults];
}

- (void)apiSourceChanged:(UISegmentedControl *)sender {
    // Reset list and prompt for CurseForge API key if needed
    if (sender.selectedSegmentIndex == 1 && !self.hasPromptedForAPIKey) {
        self.hasPromptedForAPIKey = YES;
        UIAlertController *alert = [UIAlertController alertControllerWithTitle:@"Enter CurseForge API Key"
                                                                       message:@"Please enter your CurseForge API key to search modpacks on CurseForge."
                                                                preferredStyle:UIAlertControllerStyleAlert];
        [alert addTextFieldWithConfigurationHandler:^(UITextField * _Nonnull textField) {
            textField.placeholder = @"API Key";
        }];
        [alert addAction:[UIAlertAction actionWithTitle:@"OK" style:UIAlertActionStyleDefault handler:^(UIAlertAction * _Nonnull action) {
            NSString *enteredKey = alert.textFields.firstObject.text;
            if (enteredKey.length > 0) {
                [self.curseForge setValue:enteredKey forKey:@"apiKey"];
            } else {
                [UIAlertUtilities presentAlertWithTitle:@"API Key Missing" message:@"No API key entered. Some functionality may not work." viewController:self];
            }
            [self updateSearchResults];
        }]];
        [alert addAction:[UIAlertAction actionWithTitle:@"Cancel" style:UIAlertActionStyleCancel handler:^(UIAlertAction * _Nonnull action) {
            // Switch back to Modrinth if they cancel
            self.apiSegmentedControl.selectedSegmentIndex = 0;
        }]];
        [self presentViewController:alert animated:YES completion:nil];
    } else {
        [self updateSearchResults];
    }
}

- (void)updateSearchResults {
    [self loadModpackResultsWithPrevList:NO];
}

- (void)updateSearchResultsForSearchController:(UISearchController *)searchController {
    [NSObject cancelPreviousPerformRequestsWithTarget:self selector:@selector(updateSearchResults) object:nil];
    [self performSelector:@selector(updateSearchResults) withObject:nil afterDelay:0.5];
}

- (void)loadModpackResultsWithPrevList:(BOOL)prevList {
    NSString *name = self.searchController.searchBar.text;
    if (!prevList && [self.filters[@"name"] isEqualToString:name]) {
        return;
    }
    
    [self switchToLoadingState];
    self.filters[@"name"] = name ?: @"";
    
    if (self.apiSegmentedControl.selectedSegmentIndex == 0) {
        // Modrinth API
        dispatch_async(dispatch_get_global_queue(DISPATCH_QUEUE_PRIORITY_DEFAULT, 0), ^{
            self.list = [self.modrinth searchModWithFilters:self.filters previousPageResult:prevList ? self.list : nil];
            dispatch_async(dispatch_get_main_queue(), ^{
                if (self.list) {
                    [self switchToReadyState];
                    [self.tableView reloadData];
                } else {
                    [UIAlertUtilities presentAlertWithTitle:localize(@"Error", nil) 
                                                   message:self.modrinth.lastError.localizedDescription 
                                           viewController:self];
                    [self actionClose];
                }
            });
        });
    } else {
        // CurseForge API
        [self.curseForge searchModWithFilters:self.filters previousPageResult:prevList ? self.list : nil completion:^(NSMutableArray *results, NSError *error) {
            dispatch_async(dispatch_get_main_queue(), ^{
                if (results) {
                    self.list = results;
                    [self switchToReadyState];
                    [self.tableView reloadData];
                } else {
                    [UIAlertUtilities presentAlertWithTitle:localize(@"Error", nil) 
                                                   message:error.localizedDescription 
                                           viewController:self];
                    [self actionClose];
                }
            });
        }];
    }
}

- (void)actionClose {
    [self.navigationController dismissViewControllerAnimated:YES completion:nil];
}

- (void)switchToLoadingState {
    UIActivityIndicatorView *indicator = [[UIActivityIndicatorView alloc] initWithActivityIndicatorStyle:UIActivityIndicatorViewStyleMedium];
    self.navigationItem.rightBarButtonItem = [[UIBarButtonItem alloc] initWithCustomView:indicator];
    [indicator startAnimating];
    self.navigationController.modalInPresentation = YES;
    self.tableView.allowsSelection = NO;
}

- (void)switchToReadyState {
    UIActivityIndicatorView *indicator = (id)self.navigationItem.rightBarButtonItem.customView;
    [indicator stopAnimating];
    self.navigationItem.rightBarButtonItem = [[UIBarButtonItem alloc] initWithBarButtonSystemItem:UIBarButtonSystemItemClose target:self action:@selector(actionClose)];
    self.navigationController.modalInPresentation = NO;
    self.tableView.allowsSelection = YES;
}

#pragma mark - UITableViewDataSource

- (NSInteger)numberOfSectionsInTableView:(UITableView *)tableView {
    return 1;
}

- (NSInteger)tableView:(UITableView *)tableView numberOfRowsInSection:(NSInteger)section {
    return self.list.count;
}

- (UITableViewCell *)tableView:(UITableView *)tableView cellForRowAtIndexPath:(NSIndexPath *)indexPath {
    UITableViewCell *cell = [tableView dequeueReusableCellWithIdentifier:@"modpackCell"];
    if (!cell) {
        cell = [[UITableViewCell alloc] initWithStyle:UITableViewCellStyleSubtitle reuseIdentifier:@"modpackCell"];
        cell.imageView.contentMode = UIViewContentModeScaleToFill;
        cell.imageView.clipsToBounds = YES;
    }
    
    NSDictionary *item = self.list[indexPath.row];
    cell.textLabel.text = item[@"title"];
    cell.detailTextLabel.text = item[@"description"];
    UIImage *fallbackImage = [UIImage imageNamed:@"DefaultProfile"];
    [cell.imageView setImageWithURL:[NSURL URLWithString:item[@"imageUrl"]] placeholderImage:fallbackImage];
    
    // Auto-load more if at end
    if (indexPath.row == self.list.count - 1) {
        BOOL shouldLoadMore = NO;
        if (self.apiSegmentedControl.selectedSegmentIndex == 0) {
            shouldLoadMore = !self.modrinth.reachedLastPage;
        } else {
            shouldLoadMore = !self.curseForge.reachedLastPage;
        }
        
        if (shouldLoadMore) {
            [self loadModpackResultsWithPrevList:YES];
        }
    }
    
    return cell;
}

#pragma mark - UITableView Delegate
- (void)tableView:(UITableView *)tableView didSelectRowAtIndexPath:(NSIndexPath *)indexPath {
    NSDictionary *item = self.list[indexPath.row];
    if ([item[@"versionDetailsLoaded"] boolValue]) {
        [self showModpackDetails:item atIndexPath:indexPath];
    } else {
        [tableView deselectRowAtIndexPath:indexPath animated:NO];
        [self switchToLoadingState];
        
        // Load details using the appropriate API
        if (self.apiSegmentedControl.selectedSegmentIndex == 0) {
            // Modrinth
            dispatch_async(dispatch_get_global_queue(DISPATCH_QUEUE_PRIORITY_DEFAULT, 0), ^{
                [self.modrinth loadDetailsOfMod:self.list[indexPath.row] completion:^(NSError *error) {
                    dispatch_async(dispatch_get_main_queue(), ^{
                        [self switchToReadyState];
                        if ([item[@"versionDetailsLoaded"] boolValue]) {
                            [self showModpackDetails:item atIndexPath:indexPath];
                        } else {
                            [UIAlertUtilities presentAlertWithTitle:localize(@"Error", nil) 
                                                           message:self.modrinth.lastError.localizedDescription 
                                                   viewController:self];
                        }
                    });
                }];
            });
        } else {
            // CurseForge
            [self.curseForge loadDetailsOfMod:self.list[indexPath.row] completion:^(NSError *error) {
                dispatch_async(dispatch_get_main_queue(), ^{
                    [self switchToReadyState];
                    if ([item[@"versionDetailsLoaded"] boolValue]) {
                        [self showModpackDetails:item atIndexPath:indexPath];
                    } else {
                        [UIAlertUtilities presentAlertWithTitle:localize(@"Error", nil) 
                                                       message:self.curseForge.lastError.localizedDescription 
                                               viewController:self];
                    }
                });
            }];
        }
    }
}

- (void)showModpackDetails:(NSDictionary *)details atIndexPath:(NSIndexPath *)indexPath {
    UITableViewCell *cell = [self.tableView cellForRowAtIndexPath:indexPath];
    
    // Check for valid version data
    NSArray *versionNames = details[@"versionNames"];
    NSArray *mcVersionNames = details[@"mcVersionNames"];
    
    if (!versionNames || ![versionNames isKindOfClass:[NSArray class]] || versionNames.count == 0) {
        [UIAlertUtilities presentAlertWithTitle:@"Error" 
                                      message:@"No versions available for this modpack." 
                              viewController:self];
        return;
    }

    // Limit number of versions to prevent UI freezing
    const NSUInteger MAX_VERSIONS_TO_SHOW = 50;
    NSUInteger versionsToShow = MIN(versionNames.count, MAX_VERSIONS_TO_SHOW);
    
    NSLog(@"[DEBUG] About to show modpack version selector with %lu versions (limiting to %lu)", 
          (unsigned long)versionNames.count, (unsigned long)versionsToShow);
    
    NSMutableArray<UIAction *> *versionActions = [NSMutableArray new];
    
    for (NSUInteger i = 0; i < versionsToShow; i++) {
        NSString *version = versionNames[i];
        if (![version isKindOfClass:[NSString class]]) {
            continue;
        }
        
        NSString *displayName = version;
        if (i < mcVersionNames.count && [mcVersionNames[i] isKindOfClass:[NSString class]]) {
            NSString *mcVersion = mcVersionNames[i];
            if (![version hasSuffix:mcVersion]) {
                displayName = [NSString stringWithFormat:@"%@ - %@", version, mcVersion];
            }
        }
        
        NSUInteger capturedIndex = i; // Capture i for the block
        [versionActions addObject:[UIAction actionWithTitle:displayName 
                                                     image:nil 
                                                identifier:nil 
                                                   handler:^(UIAction *action) {
            [self installModpackFromDetail:details atIndex:capturedIndex];
        }]];
    }
    
    // For iPad and large displays, use action sheet
    if (UI_USER_INTERFACE_IDIOM() == UIUserInterfaceIdiomPad) {
        UIAlertController *alert = [UIAlertController alertControllerWithTitle:@"Select Version" 
                                                                      message:nil 
                                                               preferredStyle:UIAlertControllerStyleActionSheet];
        
        for (UIAction *action in versionActions) {
            [alert addAction:[UIAlertAction actionWithTitle:action.title 
                                                     style:UIAlertActionStyleDefault 
                                                   handler:^(UIAlertAction * _Nonnull alertAction) {
                NSUInteger index = [versionActions indexOfObject:action];
                [self installModpackFromDetail:details atIndex:index];
            }]];
        }
        
        [alert addAction:[UIAlertAction actionWithTitle:localize(@"Cancel", nil) 
                                                 style:UIAlertActionStyleCancel 
                                               handler:nil]];
        
        alert.popoverPresentationController.sourceView = cell ?: self.view;
        alert.popoverPresentationController.sourceRect = cell ? cell.bounds : CGRectMake(CGRectGetMidX(self.view.bounds), CGRectGetMidY(self.view.bounds), 1, 1);
        
        [self presentViewController:alert animated:YES completion:nil];
    } else {
        // For iPhone and smaller displays, use a table view controller
        [self showVersionSelectorTableForModpack:details withVersions:versionActions];
    }
}

// Table-based version selection for iPhone
- (void)showVersionSelectorTableForModpack:(NSDictionary *)modpack withVersions:(NSArray<UIAction *> *)versionActions {
    UITableViewController *versionTableVC = [[UITableViewController alloc] initWithStyle:UITableViewStylePlain];
    versionTableVC.title = @"Select Version";
    
    ModpackVersionSelectorDataSource *dataSource = [[ModpackVersionSelectorDataSource alloc] 
                                                  initWithVersionActions:versionActions 
                                                                modpack:modpack 
                                                               delegate:self];
    
    versionTableVC.tableView.dataSource = dataSource;
    versionTableVC.tableView.delegate = dataSource;
    
    UINavigationController *navController = [[UINavigationController alloc] initWithRootViewController:versionTableVC];
    navController.modalPresentationStyle = UIModalPresentationFullScreen;
    
    [self presentViewController:navController animated:YES completion:nil];
}

// Handle installation of modpack
- (void)installModpackFromDetail:(NSDictionary *)details atIndex:(NSUInteger)index {
    [self actionClose];
    
    // Use the appropriate API based on the source
    if ([details[@"apiSource"] integerValue] == 1) {
        // Modrinth API (source = 1)
        [self.modrinth installModpackFromDetail:details atIndex:index];
    } else {
        // CurseForge API (source = 0 or anything else)
        [self.curseForge installModpackFromDetail:details atIndex:index completion:^(NSError *error) {
            if (error) {
                dispatch_async(dispatch_get_main_queue(), ^{
                    [UIAlertUtilities presentAlertWithTitle:@"Installation Error" 
                                                   message:error.localizedDescription 
                                           viewController:nil];
                });
            }
        }];
    }
}

@end

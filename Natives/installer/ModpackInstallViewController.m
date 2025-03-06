#import "ModpackInstallViewController.h"
#import "modpack/ModrinthAPI.h"
#import "modpack/CurseForgeAPI.h"
#import "modpack/ModpackUtils.h"
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

#pragma mark - Constants

typedef NS_ENUM(NSInteger, ModpackSource) {
    ModpackSourceModrinth = 0,
    ModpackSourceCurseForge = 1
};

#pragma mark - ModpackVersionSelectorDataSource

@interface ModpackVersionSelectorDataSource : NSObject <UITableViewDataSource, UITableViewDelegate>
@property (nonatomic, strong) NSArray<NSString *> *versions;
@property (nonatomic, strong) NSArray<NSString *> *mcVersions;
@property (nonatomic, strong) NSDictionary *modpack;
@property (nonatomic, assign) ModpackSource source;
@property (nonatomic, weak) ModpackInstallViewController *delegate;

- (instancetype)initWithVersions:(NSArray<NSString *> *)versions 
                      mcVersions:(NSArray<NSString *> *)mcVersions
                         modpack:(NSDictionary *)modpack 
                          source:(ModpackSource)source
                        delegate:(ModpackInstallViewController *)delegate;
@end

@implementation ModpackVersionSelectorDataSource

- (instancetype)initWithVersions:(NSArray<NSString *> *)versions 
                      mcVersions:(NSArray<NSString *> *)mcVersions
                         modpack:(NSDictionary *)modpack 
                          source:(ModpackSource)source
                        delegate:(ModpackInstallViewController *)delegate {
    if (self = [super init]) {
        _versions = versions;
        _mcVersions = mcVersions;
        _modpack = modpack;
        _source = source;
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
        cell = [[UITableViewCell alloc] initWithStyle:UITableViewCellStyleSubtitle reuseIdentifier:@"VersionCell"];
    }
    
    if (indexPath.row < self.versions.count) {
        NSString *version = self.versions[indexPath.row];
        NSString *mcVersion = (indexPath.row < self.mcVersions.count) ? self.mcVersions[indexPath.row] : @"";
        
        cell.textLabel.text = version;
        if (mcVersion.length > 0) {
            cell.detailTextLabel.text = [NSString stringWithFormat:@"Minecraft %@", mcVersion];
        } else {
            cell.detailTextLabel.text = nil;
        }
    }
    
    return cell;
}

- (void)tableView:(UITableView *)tableView didSelectRowAtIndexPath:(NSIndexPath *)indexPath {
    [tableView deselectRowAtIndexPath:indexPath animated:YES];
    
    if (indexPath.row < self.versions.count) {
        [self.delegate.presentedViewController dismissViewControllerAnimated:YES completion:^{
            [self.delegate installModpackWithDetails:self.modpack 
                                            atIndex:indexPath.row 
                                             source:self.source];
        }];
    }
}

@end

#pragma mark - ModpackInstallViewController

@interface ModpackInstallViewController () <UISearchResultsUpdating>
@property (nonatomic, strong) UISearchController *searchController;
@property (nonatomic, strong) UISegmentedControl *apiSegmentedControl;
@property (nonatomic, strong) NSMutableArray *modpackList;
@property (nonatomic, strong) NSMutableDictionary *searchFilters;
@property (nonatomic, strong) ModrinthAPI *modrinthAPI;
@property (nonatomic, strong) CurseForgeAPI *curseForgeAPI;
@property (nonatomic, assign) BOOL hasPromptedForAPIKey;
@property (nonatomic, assign) BOOL isSearching;
@end

@implementation ModpackInstallViewController

#pragma mark - Lifecycle Methods

- (void)viewDidLoad {
    [super viewDidLoad];
    
    // Title
    self.title = @"Modpack Installer";
    
    // Initialize APIs
    self.modrinthAPI = [ModrinthAPI defaultAPI];
    self.curseForgeAPI = [[CurseForgeAPI alloc] initWithAPIKey:@""];
    self.hasPromptedForAPIKey = NO;
    self.isSearching = NO;
    
    // Setup search controller
    self.searchController = [[UISearchController alloc] initWithSearchResultsController:nil];
    self.searchController.searchResultsUpdater = self;
    self.searchController.obscuresBackgroundDuringPresentation = NO;
    self.navigationItem.searchController = self.searchController;
    self.navigationItem.hidesSearchBarWhenScrolling = NO;
    
    // Add API selection segmented control
    self.apiSegmentedControl = [[UISegmentedControl alloc] initWithItems:@[@"Modrinth", @"CurseForge"]];
    self.apiSegmentedControl.selectedSegmentIndex = ModpackSourceModrinth;
    [self.apiSegmentedControl addTarget:self action:@selector(apiSourceChanged:) forControlEvents:UIControlEventValueChanged];
    
    // Configure table header
    UIView *headerView = [[UIView alloc] initWithFrame:CGRectMake(0, 0, self.view.bounds.size.width, 50)];
    self.apiSegmentedControl.frame = CGRectInset(headerView.bounds, 10, 10);
    self.apiSegmentedControl.autoresizingMask = UIViewAutoresizingFlexibleWidth;
    [headerView addSubview:self.apiSegmentedControl];
    self.tableView.tableHeaderView = headerView;
    
    // Set filter for modpacks only
    self.searchFilters = [@{@"isModpack": @(YES), @"name": @" "} mutableCopy];
    
    // Initialize empty list
    self.modpackList = [NSMutableArray new];
    
    // Add close button
    self.navigationItem.rightBarButtonItem = [[UIBarButtonItem alloc] initWithBarButtonSystemItem:UIBarButtonSystemItemClose 
                                                                                           target:self 
                                                                                           action:@selector(actionClose)];
    
    // Initial search
    [self searchModpacks];
}

- (void)viewWillAppear:(BOOL)animated {
    [super viewWillAppear:animated];
    
    // Ensure proper segmented control width
    CGRect frame = self.tableView.tableHeaderView.frame;
    frame.size.height = 50;
    self.tableView.tableHeaderView.frame = frame;
    [self.tableView.tableHeaderView setNeedsLayout];
    [self.tableView.tableHeaderView layoutIfNeeded];
}

- (void)dealloc {
    [[NSNotificationCenter defaultCenter] removeObserver:self];
}

#pragma mark - User Actions

- (void)apiSourceChanged:(UISegmentedControl *)sender {
    // Reset search results
    [self.modpackList removeAllObjects];
    [self.tableView reloadData];
    
    if (sender.selectedSegmentIndex == ModpackSourceCurseForge && !self.hasPromptedForAPIKey) {
        self.hasPromptedForAPIKey = YES;
        [self promptForCurseForgeAPIKey];
    } else {
        [self searchModpacks];
    }
}

- (void)promptForCurseForgeAPIKey {
    UIAlertController *alert = [UIAlertController alertControllerWithTitle:@"CurseForge API Key Required"
                                                                   message:@"Please enter your CurseForge API key to search and install modpacks."
                                                            preferredStyle:UIAlertControllerStyleAlert];
    
    [alert addTextFieldWithConfigurationHandler:^(UITextField * _Nonnull textField) {
        textField.placeholder = @"API Key";
        textField.secureTextEntry = YES;
    }];
    
    [alert addAction:[UIAlertAction actionWithTitle:@"OK" style:UIAlertActionStyleDefault handler:^(UIAlertAction * _Nonnull action) {
        NSString *enteredKey = alert.textFields.firstObject.text;
        if (enteredKey.length > 0) {
            [self.curseForgeAPI setValue:enteredKey forKey:@"apiKey"];
            [self searchModpacks];
        } else {
            [UIAlertUtilities presentAlertWithTitle:@"API Key Missing" 
                                           message:@"No API key entered. Some functionality may not work."
                                   viewController:self];
            // Switch back to Modrinth if no key provided
            self.apiSegmentedControl.selectedSegmentIndex = ModpackSourceModrinth;
            [self searchModpacks];
        }
    }]];
    
    [alert addAction:[UIAlertAction actionWithTitle:@"Cancel" style:UIAlertActionStyleCancel handler:^(UIAlertAction * _Nonnull action) {
        // Switch back to Modrinth if they cancel
        self.apiSegmentedControl.selectedSegmentIndex = ModpackSourceModrinth;
        [self searchModpacks];
    }]];
    
    [self presentViewController:alert animated:YES completion:nil];
}

- (void)actionClose {
    [self.navigationController dismissViewControllerAnimated:YES completion:nil];
}

#pragma mark - Search Handling

- (void)updateSearchResultsForSearchController:(UISearchController *)searchController {
    // Debounce search updates
    [NSObject cancelPreviousPerformRequestsWithTarget:self selector:@selector(searchModpacks) object:nil];
    [self performSelector:@selector(searchModpacks) withObject:nil afterDelay:0.5];
}

- (void)searchModpacks {
    // Avoid concurrent searches
    if (self.isSearching) {
        return;
    }
    
    NSString *searchText = self.searchController.searchBar.text;
    self.searchFilters[@"name"] = searchText ?: @"";
    
    [self switchToLoadingState];
    self.isSearching = YES;
    
    ModpackSource source = (ModpackSource)self.apiSegmentedControl.selectedSegmentIndex;
    
    if (source == ModpackSourceModrinth) {
        [self searchModrinthModpacks];
    } else {
        [self searchCurseForgeModpacks];
    }
}

- (void)searchModrinthModpacks {
    dispatch_async(dispatch_get_global_queue(DISPATCH_QUEUE_PRIORITY_DEFAULT, 0), ^{
        NSMutableArray *results = [self.modrinthAPI searchModWithFilters:self.searchFilters previousPageResult:nil];
        
        dispatch_async(dispatch_get_main_queue(), ^{
            [self handleSearchResults:results source:ModpackSourceModrinth error:self.modrinthAPI.lastError];
        });
    });
}

- (void)searchCurseForgeModpacks {
    [self.curseForgeAPI searchModWithFilters:self.searchFilters previousPageResult:nil completion:^(NSMutableArray *results, NSError *error) {
        dispatch_async(dispatch_get_main_queue(), ^{
            [self handleSearchResults:results source:ModpackSourceCurseForge error:error];
        });
    }];
}

- (void)handleSearchResults:(NSMutableArray *)results source:(ModpackSource)source error:(NSError *)error {
    self.isSearching = NO;
    
    if (results) {
        self.modpackList = results;
        [self switchToReadyState];
        [self.tableView reloadData];
    } else {
        [self switchToReadyState];
        NSString *sourceName = (source == ModpackSourceModrinth) ? @"Modrinth" : @"CurseForge";
        NSString *errorMessage = error ? error.localizedDescription : [NSString stringWithFormat:@"Failed to fetch %@ modpacks", sourceName];
        
        [UIAlertUtilities presentAlertWithTitle:localize(@"Error", nil) 
                                       message:errorMessage 
                               viewController:self];
    }
}

- (void)loadMore {
    if (self.isSearching) {
        return;
    }
    
    self.isSearching = YES;
    ModpackSource source = (ModpackSource)self.apiSegmentedControl.selectedSegmentIndex;
    
    if (source == ModpackSourceModrinth) {
        dispatch_async(dispatch_get_global_queue(DISPATCH_QUEUE_PRIORITY_DEFAULT, 0), ^{
            NSMutableArray *results = [self.modrinthAPI searchModWithFilters:self.searchFilters previousPageResult:self.modpackList];
            
            dispatch_async(dispatch_get_main_queue(), ^{
                self.isSearching = NO;
                if (results) {
                    self.modpackList = results;
                    [self.tableView reloadData];
                }
            });
        });
    } else {
        [self.curseForgeAPI searchModWithFilters:self.searchFilters previousPageResult:self.modpackList completion:^(NSMutableArray *results, NSError *error) {
            dispatch_async(dispatch_get_main_queue(), ^{
                self.isSearching = NO;
                if (results) {
                    self.modpackList = results;
                    [self.tableView reloadData];
                }
            });
        }];
    }
}

#pragma mark - UI State Management

- (void)switchToLoadingState {
    UIActivityIndicatorView *indicator = [[UIActivityIndicatorView alloc] initWithActivityIndicatorStyle:UIActivityIndicatorViewStyleMedium];
    [indicator startAnimating];
    self.navigationItem.leftBarButtonItem = [[UIBarButtonItem alloc] initWithCustomView:indicator];
    self.tableView.allowsSelection = NO;
}

- (void)switchToReadyState {
    self.navigationItem.leftBarButtonItem = nil;
    self.tableView.allowsSelection = YES;
}

#pragma mark - UITableViewDataSource

- (NSInteger)numberOfSectionsInTableView:(UITableView *)tableView {
    return 1;
}

- (NSInteger)tableView:(UITableView *)tableView numberOfRowsInSection:(NSInteger)section {
    return self.modpackList.count;
}

- (UITableViewCell *)tableView:(UITableView *)tableView cellForRowAtIndexPath:(NSIndexPath *)indexPath {
    UITableViewCell *cell = [tableView dequeueReusableCellWithIdentifier:@"ModpackCell"];
    if (!cell) {
        cell = [[UITableViewCell alloc] initWithStyle:UITableViewCellStyleSubtitle reuseIdentifier:@"ModpackCell"];
        cell.imageView.contentMode = UIViewContentModeScaleAspectFit;
        cell.imageView.clipsToBounds = YES;
        cell.accessoryType = UITableViewCellAccessoryDisclosureIndicator;
    }
    
    NSDictionary *modpack = self.modpackList[indexPath.row];
    cell.textLabel.text = modpack[@"title"];
    cell.detailTextLabel.text = modpack[@"description"];
    
    // Load image with a placeholder
    UIImage *placeholder = [UIImage imageNamed:@"DefaultProfile"];
    [cell.imageView setImageWithURL:[NSURL URLWithString:modpack[@"imageUrl"]] 
                   placeholderImage:placeholder];
    
    // Auto-load more content when approaching the end of the list
    if (indexPath.row >= self.modpackList.count - 3) {
        ModpackSource source = (ModpackSource)self.apiSegmentedControl.selectedSegmentIndex;
        BOOL hasMoreContent = (source == ModpackSourceModrinth) ? 
            !self.modrinthAPI.reachedLastPage : 
            !self.curseForgeAPI.reachedLastPage;
        
        if (hasMoreContent && !self.isSearching) {
            [self loadMore];
        }
    }
    
    return cell;
}

#pragma mark - UITableViewDelegate

- (void)tableView:(UITableView *)tableView didSelectRowAtIndexPath:(NSIndexPath *)indexPath {
    [tableView deselectRowAtIndexPath:indexPath animated:YES];
    
    NSDictionary *modpack = self.modpackList[indexPath.row];
    ModpackSource source = (ModpackSource)self.apiSegmentedControl.selectedSegmentIndex;
    
    // Check if version details are already loaded
    if ([modpack[@"versionDetailsLoaded"] boolValue]) {
        [self showVersionSelectionForModpack:modpack source:source];
    } else {
        [self loadVersionDetailsForModpack:modpack indexPath:indexPath source:source];
    }
}

#pragma mark - Version Details Loading

- (void)loadVersionDetailsForModpack:(NSDictionary *)modpack indexPath:(NSIndexPath *)indexPath source:(ModpackSource)source {
    [self switchToLoadingState];
    
    if (source == ModpackSourceModrinth) {
        [self loadModrinthVersionDetails:modpack indexPath:indexPath];
    } else {
        [self loadCurseForgeVersionDetails:modpack indexPath:indexPath];
    }
}

- (void)loadModrinthVersionDetails:(NSMutableDictionary *)modpack indexPath:(NSIndexPath *)indexPath {
    dispatch_async(dispatch_get_global_queue(DISPATCH_QUEUE_PRIORITY_DEFAULT, 0), ^{
        [self.modrinthAPI loadDetailsOfMod:self.modpackList[indexPath.row] completion:^(NSError *error) {
            dispatch_async(dispatch_get_main_queue(), ^{
                [self switchToReadyState];
                
                if ([modpack[@"versionDetailsLoaded"] boolValue]) {
                    [self showVersionSelectionForModpack:modpack source:ModpackSourceModrinth];
                } else {
                    [UIAlertUtilities presentAlertWithTitle:localize(@"Error", nil)
                                                   message:@"Failed to load modpack version details"
                                           viewController:self];
                }
            });
        }];
    });
}

- (void)loadCurseForgeVersionDetails:(NSMutableDictionary *)modpack indexPath:(NSIndexPath *)indexPath {
    [self.curseForgeAPI loadDetailsOfMod:self.modpackList[indexPath.row] completion:^(NSError *error) {
        dispatch_async(dispatch_get_main_queue(), ^{
            [self switchToReadyState];
            
            if ([modpack[@"versionDetailsLoaded"] boolValue]) {
                [self showVersionSelectionForModpack:modpack source:ModpackSourceCurseForge];
            } else {
                [UIAlertUtilities presentAlertWithTitle:localize(@"Error", nil)
                                               message:@"Failed to load modpack version details"
                                       viewController:self];
            }
        });
    }];
}

#pragma mark - Version Selection

- (void)showVersionSelectionForModpack:(NSDictionary *)modpack source:(ModpackSource)source {
    // Extract version data
    NSArray *versionNames = modpack[@"versionNames"];
    NSArray *mcVersionNames = modpack[@"mcVersionNames"];
    
    if (!versionNames || ![versionNames isKindOfClass:[NSArray class]] || versionNames.count == 0) {
        [UIAlertUtilities presentAlertWithTitle:@"Error"
                                      message:@"No versions available for this modpack."
                              viewController:self];
        return;
    }
    
    // Limit to prevent UI issues
    const NSUInteger MAX_VERSIONS = 50;
    NSUInteger versionsToShow = MIN(versionNames.count, MAX_VERSIONS);
    
    NSMutableArray<NSString *> *displayVersions = [NSMutableArray arrayWithCapacity:versionsToShow];
    NSMutableArray<NSString *> *displayMcVersions = [NSMutableArray arrayWithCapacity:versionsToShow];
    
    // Prepare display data
    for (NSUInteger i = 0; i < versionsToShow; i++) {
        id versionObj = versionNames[i];
        NSString *version = [versionObj isKindOfClass:[NSString class]] ? versionObj : [versionObj description];
        [displayVersions addObject:version];
        
        NSString *mcVersion = @"";
        if (i < mcVersionNames.count) {
            id mcVersionObj = mcVersionNames[i];
            
            if ([mcVersionObj isKindOfClass:[NSArray class]]) {
                // Handle array of versions
                NSArray *versions = (NSArray *)mcVersionObj;
                if (versions.count > 0) {
                    mcVersion = [versions[0] isKindOfClass:[NSString class]] ? versions[0] : [versions[0] description];
                }
            } else if ([mcVersionObj isKindOfClass:[NSString class]]) {
                // Handle string version
                mcVersion = mcVersionObj;
            } else if (mcVersionObj) {
                // Handle other types
                mcVersion = [mcVersionObj description];
            }
        }
        [displayMcVersions addObject:mcVersion];
    }
    
    // Choose presentation style based on device
    if (UI_USER_INTERFACE_IDIOM() == UIUserInterfaceIdiomPad) {
        [self showActionSheetForModpack:modpack
                              versions:displayVersions
                            mcVersions:displayMcVersions
                                source:source];
    } else {
        [self showTableForModpack:modpack
                         versions:displayVersions
                       mcVersions:displayMcVersions
                           source:source];
    }
}

- (void)showActionSheetForModpack:(NSDictionary *)modpack
                         versions:(NSArray<NSString *> *)versions
                       mcVersions:(NSArray<NSString *> *)mcVersions
                           source:(ModpackSource)source {
    
    UIAlertController *alert = [UIAlertController alertControllerWithTitle:@"Select Version"
                                                                   message:nil
                                                            preferredStyle:UIAlertControllerStyleActionSheet];
    
    for (NSUInteger i = 0; i < versions.count; i++) {
        NSString *version = versions[i];
        NSString *mcVersion = i < mcVersions.count ? mcVersions[i] : @"";
        
        NSString *title = version;
        if (mcVersion.length > 0) {
            title = [NSString stringWithFormat:@"%@ (MC %@)", version, mcVersion];
        }
        
        NSUInteger capturedIndex = i;
        [alert addAction:[UIAlertAction actionWithTitle:title
                                                  style:UIAlertActionStyleDefault
                                                handler:^(UIAlertAction * _Nonnull action) {
            [self installModpackWithDetails:modpack atIndex:capturedIndex source:source];
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

- (void)showTableForModpack:(NSDictionary *)modpack
                    versions:(NSArray<NSString *> *)versions
                  mcVersions:(NSArray<NSString *> *)mcVersions
                      source:(ModpackSource)source {
    
    UITableViewController *versionTableVC = [[UITableViewController alloc] initWithStyle:UITableViewStylePlain];
    versionTableVC.title = @"Select Version";
    
    ModpackVersionSelectorDataSource *dataSource = [[ModpackVersionSelectorDataSource alloc]
                                                  initWithVersions:versions
                                                        mcVersions:mcVersions
                                                           modpack:modpack
                                                            source:source
                                                          delegate:self];
    
    versionTableVC.tableView.dataSource = dataSource;
    versionTableVC.tableView.delegate = dataSource;
    
    UINavigationController *navController = [[UINavigationController alloc] initWithRootViewController:versionTableVC];
    navController.modalPresentationStyle = UIModalPresentationFullScreen;
    
    [self presentViewController:navController animated:YES completion:nil];
}

#pragma mark - Installation

- (void)installModpackWithDetails:(NSDictionary *)details atIndex:(NSUInteger)index source:(ModpackSource)source {
    // Show activity indicator
    UIAlertController *progressAlert = [UIAlertController alertControllerWithTitle:@"Installing Modpack"
                                                                           message:@"Preparing installation..."
                                                                    preferredStyle:UIAlertControllerStyleAlert];
    
    UIActivityIndicatorView *indicator = [[UIActivityIndicatorView alloc] initWithActivityIndicatorStyle:UIActivityIndicatorViewStyleMedium];
    indicator.center = CGPointMake(130, 30);
    [progressAlert.view addSubview:indicator];
    [indicator startAnimating];
    
    [self presentViewController:progressAlert animated:YES completion:^{
        dispatch_async(dispatch_get_global_queue(DISPATCH_QUEUE_PRIORITY_DEFAULT, 0), ^{
            if (source == ModpackSourceModrinth) {
                [self installModrinthModpack:details atIndex:index];
            } else {
                [self installCurseForgeModpack:details atIndex:index];
            }
            
            dispatch_async(dispatch_get_main_queue(), ^{
                [progressAlert dismissViewControllerAnimated:YES completion:^{
                    [self actionClose];
                }];
            });
        });
    }];
}

- (void)installModrinthModpack:(NSDictionary *)details atIndex:(NSUInteger)index {
    [self.modrinthAPI installModpackFromDetail:details atIndex:index];
}

- (void)installCurseForgeModpack:(NSDictionary *)details atIndex:(NSUInteger)index {
    [self.curseForgeAPI installModpackFromDetail:details atIndex:index completion:^(NSError *error) {
        if (error) {
            dispatch_async(dispatch_get_main_queue(), ^{
                [UIAlertUtilities presentAlertWithTitle:@"Installation Error" 
                                               message:error.localizedDescription 
                                       viewController:nil];
            });
        }
    }];
}

@end

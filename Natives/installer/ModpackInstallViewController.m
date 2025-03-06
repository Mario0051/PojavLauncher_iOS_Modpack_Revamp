#import "ModpackInstallViewController.h"
#import "modpack/ModrinthAPI.h"
#import "modpack/CurseForgeAPI.h"
#import "modpack/ModpackUtils.h"
#import "AFNetworking.h"
#import "UIKit+AFNetworking.h"
#import "config.h"
#import "utils.h"
#import "PLProfiles.h"
#import "UIAlertUtilities.h"
#import "DownloadProgressViewController.h"
#import "MinecraftResourceDownloadTask.h"

typedef NS_ENUM(NSInteger, ModpackSource) {
    ModpackSourceModrinth = 0,
    ModpackSourceCurseForge = 1
};

@interface ModpackInstallViewController () <UITableViewDelegate, UITableViewDataSource, UISearchBarDelegate>
@property (nonatomic, strong) UISegmentedControl *sourceSegment;
@property (nonatomic, strong) UISearchBar *searchBar;
@property (nonatomic, strong) NSMutableArray *modpackList;
@property (nonatomic, strong) ModrinthAPI *modrinthAPI;
@property (nonatomic, strong) CurseForgeAPI *curseForgeAPI;
@property (nonatomic, assign) BOOL isLoading;
@property (nonatomic, assign) BOOL hasPromptedForAPIKey;
@end

@implementation ModpackInstallViewController

#pragma mark - Lifecycle

- (void)viewDidLoad {
    [super viewDidLoad];
    
    // Set title
    self.title = @"Modpack Installer";
    
    // Initialize empty list
    self.modpackList = [NSMutableArray array];
    self.isLoading = NO;
    self.hasPromptedForAPIKey = NO;
    
    // Basic configuration
    self.tableView.rowHeight = UITableViewAutomaticDimension;
    self.tableView.estimatedRowHeight = 80;
    self.tableView.separatorStyle = UITableViewCellSeparatorStyleSingleLine;
    self.tableView.tableFooterView = [UIView new];
    
    // Create header view with source segment
    [self setupHeaderView];
    
    // Add a search bar
    [self setupSearchBar];
    
    // Setup APIs (lazily)
    self.modrinthAPI = [ModrinthAPI defaultAPI];
    self.curseForgeAPI = [[CurseForgeAPI alloc] initWithAPIKey:@""];
    
    // Add close button
    self.navigationItem.rightBarButtonItem = [[UIBarButtonItem alloc] initWithBarButtonSystemItem:UIBarButtonSystemItemClose 
                                                                                          target:self 
                                                                                          action:@selector(actionClose)];
    
    // Delay initial search until view appears 
    // This prevents UI freezing during initial load
}

- (void)viewDidAppear:(BOOL)animated {
    [super viewDidAppear:animated];
    
    // Start initial search if we don't have data yet
    if (self.modpackList.count == 0 && !self.isLoading) {
        dispatch_async(dispatch_get_main_queue(), ^{
            // Delay the search to ensure UI is visible first
            [self performSearch:@""];
        });
    }
}

- (void)setupHeaderView {
    // Simple header view with fixed height
    UIView *headerView = [[UIView alloc] initWithFrame:CGRectMake(0, 0, self.view.bounds.size.width, 50)];
    headerView.backgroundColor = [UIColor clearColor];
    
    // Initialize and add segmented control
    self.sourceSegment = [[UISegmentedControl alloc] initWithItems:@[@"Modrinth", @"CurseForge"]];
    self.sourceSegment.frame = CGRectMake(10, 10, headerView.frame.size.width - 20, 30);
    self.sourceSegment.selectedSegmentIndex = 0;
    self.sourceSegment.autoresizingMask = UIViewAutoresizingFlexibleWidth;
    [self.sourceSegment addTarget:self action:@selector(sourceChanged:) forControlEvents:UIControlEventValueChanged];
    
    [headerView addSubview:self.sourceSegment];
    self.tableView.tableHeaderView = headerView;
}

- (void)setupSearchBar {
    self.searchBar = [[UISearchBar alloc] initWithFrame:CGRectMake(0, 0, self.view.bounds.size.width, 44)];
    self.searchBar.delegate = self;
    self.searchBar.placeholder = @"Search Modpacks";
    self.searchBar.autoresizingMask = UIViewAutoresizingFlexibleWidth;
    
    self.tableView.tableHeaderView = [self createCombinedHeaderView];
}

- (UIView *)createCombinedHeaderView {
    // Create a combined view with both the segment and search bar
    UIView *headerView = [[UIView alloc] initWithFrame:CGRectMake(0, 0, self.view.bounds.size.width, 100)];
    
    // Set up the segmented control
    self.sourceSegment.frame = CGRectMake(10, 10, headerView.frame.size.width - 20, 30);
    [headerView addSubview:self.sourceSegment];
    
    // Set up the search bar below the segment
    self.searchBar.frame = CGRectMake(0, 50, headerView.frame.size.width, 44);
    [headerView addSubview:self.searchBar];
    
    return headerView;
}

#pragma mark - Actions

- (void)sourceChanged:(UISegmentedControl *)sender {
    // Clear the current list
    [self.modpackList removeAllObjects];
    [self.tableView reloadData];
    
    if (sender.selectedSegmentIndex == ModpackSourceCurseForge && !self.hasPromptedForAPIKey) {
        [self promptForCurseForgeAPIKey];
    } else {
        // Re-do the search with the current term
        [self performSearch:self.searchBar.text];
    }
}

- (void)promptForCurseForgeAPIKey {
    self.hasPromptedForAPIKey = YES;
    
    UIAlertController *alert = [UIAlertController alertControllerWithTitle:@"CurseForge API Key Required"
                                                                   message:@"Please enter your CurseForge API key"
                                                            preferredStyle:UIAlertControllerStyleAlert];
    
    [alert addTextFieldWithConfigurationHandler:^(UITextField *textField) {
        textField.placeholder = @"API Key";
        textField.secureTextEntry = YES;
    }];
    
    [alert addAction:[UIAlertAction actionWithTitle:@"OK" style:UIAlertActionStyleDefault handler:^(UIAlertAction *action) {
        NSString *apiKey = alert.textFields.firstObject.text;
        if (apiKey.length > 0) {
            [self.curseForgeAPI setValue:apiKey forKey:@"apiKey"];
            [self performSearch:self.searchBar.text];
        } else {
            // Switch back to Modrinth if no key provided
            self.sourceSegment.selectedSegmentIndex = ModpackSourceModrinth;
            [self performSearch:self.searchBar.text];
        }
    }]];
    
    [alert addAction:[UIAlertAction actionWithTitle:@"Cancel" style:UIAlertActionStyleCancel handler:^(UIAlertAction *action) {
        // Switch back to Modrinth
        self.sourceSegment.selectedSegmentIndex = ModpackSourceModrinth;
    }]];
    
    [self presentViewController:alert animated:YES completion:nil];
}

- (void)actionClose {
    [self.navigationController dismissViewControllerAnimated:YES completion:nil];
}

#pragma mark - Search

- (void)searchBar:(UISearchBar *)searchBar textDidChange:(NSString *)searchText {
    [NSObject cancelPreviousPerformRequestsWithTarget:self selector:@selector(performDelayedSearch:) object:searchBar];
    [self performSelector:@selector(performDelayedSearch:) withObject:searchBar afterDelay:0.5];
}

- (void)searchBarSearchButtonClicked:(UISearchBar *)searchBar {
    [searchBar resignFirstResponder];
    [self performSearch:searchBar.text];
}

- (void)performDelayedSearch:(UISearchBar *)searchBar {
    [self performSearch:searchBar.text];
}

- (void)performSearch:(NSString *)searchText {
    // Don't perform concurrent searches
    if (self.isLoading) {
        return;
    }
    
    self.isLoading = YES;
    [self showLoadingIndicator];
    
    ModpackSource source = (ModpackSource)self.sourceSegment.selectedSegmentIndex;
    
    // Create search filters
    NSMutableDictionary *filters = [@{
        @"isModpack": @(YES),
        @"name": searchText ?: @""
    } mutableCopy];
    
    // Perform search on background thread
    dispatch_async(dispatch_get_global_queue(DISPATCH_QUEUE_PRIORITY_DEFAULT, 0), ^{
        if (source == ModpackSourceModrinth) {
            // Modrinth search
            NSMutableArray *results = [self.modrinthAPI searchModWithFilters:filters previousPageResult:nil];
            
            dispatch_async(dispatch_get_main_queue(), ^{
                self.isLoading = NO;
                [self hideLoadingIndicator];
                
                if (results) {
                    self.modpackList = results;
                    [self.tableView reloadData];
                } else if (self.modrinthAPI.lastError) {
                    [self showErrorAlert:self.modrinthAPI.lastError.localizedDescription];
                }
            });
        } else {
            // CurseForge search
            [self.curseForgeAPI searchModWithFilters:filters previousPageResult:nil completion:^(NSMutableArray *results, NSError *error) {
                dispatch_async(dispatch_get_main_queue(), ^{
                    self.isLoading = NO;
                    [self hideLoadingIndicator];
                    
                    if (results) {
                        self.modpackList = results;
                        [self.tableView reloadData];
                    } else if (error) {
                        [self showErrorAlert:error.localizedDescription];
                    }
                });
            }];
        }
    });
}

- (void)showLoadingIndicator {
    UIActivityIndicatorView *indicator = [[UIActivityIndicatorView alloc] initWithActivityIndicatorStyle:UIActivityIndicatorViewStyleMedium];
    [indicator startAnimating];
    self.navigationItem.leftBarButtonItem = [[UIBarButtonItem alloc] initWithCustomView:indicator];
}

- (void)hideLoadingIndicator {
    self.navigationItem.leftBarButtonItem = nil;
}

- (void)showErrorAlert:(NSString *)message {
    UIAlertController *alert = [UIAlertController alertControllerWithTitle:@"Error"
                                                                   message:message
                                                            preferredStyle:UIAlertControllerStyleAlert];
    
    [alert addAction:[UIAlertAction actionWithTitle:@"OK" style:UIAlertActionStyleDefault handler:nil]];
    [self presentViewController:alert animated:YES completion:nil];
}

#pragma mark - Table View Data Source

- (NSInteger)numberOfSectionsInTableView:(UITableView *)tableView {
    return 1;
}

- (NSInteger)tableView:(UITableView *)tableView numberOfRowsInSection:(NSInteger)section {
    if (self.modpackList.count == 0 && !self.isLoading) {
        return 1; // Show "No results" cell
    }
    return self.modpackList.count;
}

- (UITableViewCell *)tableView:(UITableView *)tableView cellForRowAtIndexPath:(NSIndexPath *)indexPath {
    static NSString *CellIdentifier = @"ModpackCell";
    UITableViewCell *cell = [tableView dequeueReusableCellWithIdentifier:CellIdentifier];
    
    if (!cell) {
        cell = [[UITableViewCell alloc] initWithStyle:UITableViewCellStyleSubtitle reuseIdentifier:CellIdentifier];
        cell.imageView.contentMode = UIViewContentModeScaleAspectFit;
        cell.accessoryType = UITableViewCellAccessoryDisclosureIndicator;
    }
    
    // Clear any existing image to prevent flicker
    cell.imageView.image = [UIImage imageNamed:@"DefaultProfile"];
    
    if (self.modpackList.count == 0 && !self.isLoading) {
        // Show "No results" cell
        cell.textLabel.text = @"No modpacks found";
        cell.detailTextLabel.text = @"Try a different search or switch sources";
        cell.accessoryType = UITableViewCellAccessoryNone;
        cell.selectionStyle = UITableViewCellSelectionStyleNone;
        return cell;
    }
    
    // Configure cell with modpack info
    NSDictionary *modpack = self.modpackList[indexPath.row];
    cell.textLabel.text = modpack[@"title"];
    cell.detailTextLabel.text = modpack[@"description"];
    cell.selectionStyle = UITableViewCellSelectionStyleDefault;
    
    // Load image asynchronously
    NSString *imageUrl = modpack[@"imageUrl"];
    if (imageUrl.length > 0) {
        [cell.imageView setImageWithURL:[NSURL URLWithString:imageUrl] 
                       placeholderImage:[UIImage imageNamed:@"DefaultProfile"]];
    }
    
    return cell;
}

#pragma mark - Table View Delegate

- (void)tableView:(UITableView *)tableView didSelectRowAtIndexPath:(NSIndexPath *)indexPath {
    [tableView deselectRowAtIndexPath:indexPath animated:YES];
    
    // No action on empty state cell
    if (self.modpackList.count == 0) {
        return;
    }
    
    NSDictionary *modpack = self.modpackList[indexPath.row];
    ModpackSource source = (ModpackSource)self.sourceSegment.selectedSegmentIndex;
    
    // Check if details are already loaded
    if ([modpack[@"versionDetailsLoaded"] boolValue]) {
        [self showVersionSelectionForModpack:modpack source:source];
    } else {
        [self loadVersionDetailsForModpack:modpack atIndexPath:indexPath source:source];
    }
}

#pragma mark - Version Details

- (void)loadVersionDetailsForModpack:(NSDictionary *)modpack atIndexPath:(NSIndexPath *)indexPath source:(ModpackSource)source {
    [self showLoadingIndicator];
    self.isLoading = YES;
    
    // Disable selection during loading
    self.tableView.allowsSelection = NO;
    
    if (source == ModpackSourceModrinth) {
        [self.modrinthAPI loadDetailsOfMod:self.modpackList[indexPath.row] completion:^(NSError *error) {
            dispatch_async(dispatch_get_main_queue(), ^{
                [self hideLoadingIndicator];
                self.isLoading = NO;
                self.tableView.allowsSelection = YES;
                
                NSDictionary *updatedModpack = self.modpackList[indexPath.row];
                if ([updatedModpack[@"versionDetailsLoaded"] boolValue]) {
                    [self showVersionSelectionForModpack:updatedModpack source:source];
                } else {
                    [self showErrorAlert:@"Failed to load modpack versions"];
                }
            });
        }];
    } else {
        [self.curseForgeAPI loadDetailsOfMod:self.modpackList[indexPath.row] completion:^(NSError *error) {
            dispatch_async(dispatch_get_main_queue(), ^{
                [self hideLoadingIndicator];
                self.isLoading = NO;
                self.tableView.allowsSelection = YES;
                
                NSDictionary *updatedModpack = self.modpackList[indexPath.row];
                if ([updatedModpack[@"versionDetailsLoaded"] boolValue]) {
                    [self showVersionSelectionForModpack:updatedModpack source:source];
                } else {
                    [self showErrorAlert:@"Failed to load modpack versions"];
                }
            });
        }];
    }
}

- (void)showVersionSelectionForModpack:(NSDictionary *)modpack source:(ModpackSource)source {
    NSArray *versionNames = modpack[@"versionNames"];
    if (!versionNames || versionNames.count == 0) {
        [self showErrorAlert:@"No versions available for this modpack"];
        return;
    }
    
    // Limit versions to show to prevent UI issues
    NSUInteger maxVersions = 50;
    NSUInteger versionsToShow = MIN(versionNames.count, maxVersions);
    
    UIAlertController *versionAlert = [UIAlertController alertControllerWithTitle:@"Select Version"
                                                                         message:nil
                                                                  preferredStyle:UIAlertControllerStyleActionSheet];
    
    for (NSUInteger i = 0; i < versionsToShow; i++) {
        NSString *versionName = versionNames[i];
        NSString *mcVersion = @"";
        
        // Try to get Minecraft version if available
        NSArray *mcVersions = modpack[@"mcVersionNames"];
        if (mcVersions && i < mcVersions.count) {
            id mcVersionObj = mcVersions[i];
            if ([mcVersionObj isKindOfClass:[NSArray class]] && [(NSArray*)mcVersionObj count] > 0) {
                mcVersion = [(NSArray*)mcVersionObj firstObject];
            } else if ([mcVersionObj isKindOfClass:[NSString class]]) {
                mcVersion = mcVersionObj;
            }
        }
        
        NSString *title = versionName;
        if (mcVersion.length > 0) {
            title = [NSString stringWithFormat:@"%@ (MC %@)", versionName, mcVersion];
        }
        
        NSUInteger capturedIndex = i;
        [versionAlert addAction:[UIAlertAction actionWithTitle:title
                                                       style:UIAlertActionStyleDefault
                                                     handler:^(UIAlertAction * _Nonnull action) {
            [self installModpackWithDetails:modpack atIndex:capturedIndex source:source];
        }]];
    }
    
    // Add cancel button
    [versionAlert addAction:[UIAlertAction actionWithTitle:@"Cancel"
                                                  style:UIAlertActionStyleCancel
                                                handler:nil]];
    
    // For iPad, set the source for the popover
    versionAlert.popoverPresentationController.sourceView = self.view;
    versionAlert.popoverPresentationController.sourceRect = CGRectMake(self.view.bounds.size.width/2, self.view.bounds.size.height/2, 1, 1);
    
    [self presentViewController:versionAlert animated:YES completion:nil];
}

#pragma mark - Installation

- (void)installModpackWithDetails:(NSDictionary *)modpack atIndex:(NSUInteger)index source:(ModpackSource)source {
    NSLog(@"[ModpackInstall] Starting installation for modpack %@ (version index: %lu)", modpack[@"title"], (unsigned long)index);
    
    // Create a download task
    MinecraftResourceDownloadTask *downloadTask = [[MinecraftResourceDownloadTask alloc] init];
    
    // Present download progress view controller
    DownloadProgressViewController *progressVC = [[DownloadProgressViewController alloc] initWithTask:downloadTask];
    UINavigationController *navController = [[UINavigationController alloc] initWithRootViewController:progressVC];
    [self presentViewController:navController animated:YES completion:nil];
    
    // Start the actual installation
    if (source == ModpackSourceModrinth) {
        [self.modrinthAPI installModpackFromDetail:modpack atIndex:index];
    } else {
        [self.curseForgeAPI installModpackFromDetail:modpack atIndex:index completion:^(NSError *error) {
            if (error) {
                dispatch_async(dispatch_get_main_queue(), ^{
                    [UIAlertUtilities presentAlertWithTitle:@"Installation Error" 
                                                    message:error.localizedDescription 
                                            viewController:self];
                });
            }
        }];
    }
}

@end

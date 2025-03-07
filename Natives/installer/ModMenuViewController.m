#import "ModMenuViewController.h"
#import "modpack/ModrinthAPI.h"
#import "modpack/CurseForgeAPI.h"
#import "modpack/ModpackUtils.h"
#import "AFNetworking.h"
#import "UIKit+AFNetworking.h"
#import "LauncherPreferences.h"
#import "PLProfiles.h"
#import "UIAlertUtilities.h"
#import "utils.h"
#import <objc/runtime.h>

// Constants for better code maintenance
static NSString * const kCurseForgeAPIKeyPrefKey = @"curseforge.api_key";
static NSString * const kFilterByProfilePrefKey = @"mods.filter_by_profile";
static NSTimeInterval const kSearchDebounceDelay = 0.5;
static NSUInteger const kDefaultPageSize = 50;
static NSUInteger const kMaxVersionsToShow = 100;

// Define the protocol first
@protocol VersionSelectorDelegate <NSObject>
- (void)handleVersionSelection:(NSDictionary *)mod selectedVersion:(NSUInteger)idx;
- (UIViewController *)presentedViewController;
@end

// Profile Data Management
@interface ProfileData : NSObject

@property (nonatomic, strong, readonly) NSString *name;
@property (nonatomic, strong, readonly) NSString *mcVersion;
@property (nonatomic, strong, readonly) NSString *modLoader;
@property (nonatomic, strong, readonly) NSString *gameDir;
@property (nonatomic, strong, readonly) NSString *versionId;

+ (instancetype)fromDictionary:(NSDictionary *)profileDict withName:(NSString *)name;
+ (instancetype)defaultProfile;

@end

@implementation ProfileData {
    NSString *_name;
    NSString *_mcVersion;
    NSString *_modLoader;
    NSString *_gameDir;
    NSString *_versionId;
}

+ (instancetype)fromDictionary:(NSDictionary *)profileDict withName:(NSString *)name {
    if (!profileDict || !name) {
        return [self defaultProfile];
    }
    
    ProfileData *data = [[ProfileData alloc] init];
    data->_name = [name copy];
    data->_gameDir = profileDict[@"gameDir"] ?: @"";
    data->_versionId = profileDict[@"lastVersionId"] ?: @"latest-release";
    
    // Parse version information
    NSDictionary *parsed = [ModpackUtils parseVersionString:data->_versionId];
    data->_mcVersion = parsed[@"mcVersion"] ?: data->_versionId;
    data->_modLoader = parsed[@"loader"] ?: @"";
    
    return data;
}

+ (instancetype)defaultProfile {
    ProfileData *data = [[ProfileData alloc] init];
    data->_name = @"Default";
    data->_mcVersion = @"latest-release";
    data->_modLoader = @"";
    data->_gameDir = @"";
    data->_versionId = @"latest-release";
    return data;
}

@end

// Version selector data source
@interface VersionSelectorDataSource : NSObject <UITableViewDataSource, UITableViewDelegate>
@property (nonatomic, strong) NSArray<NSString *> *versions;
@property (nonatomic, strong) NSArray<NSNumber *> *indices;
@property (nonatomic, strong) NSDictionary *mod;
@property (nonatomic, weak) id<VersionSelectorDelegate> delegate;
@property (nonatomic, strong) UIActivityIndicatorView *activityIndicator;

- (instancetype)initWithVersions:(NSArray<NSString *> *)versions 
                             mod:(NSDictionary *)mod 
                         indices:(NSArray<NSNumber *> *)indices 
                        delegate:(id<VersionSelectorDelegate>)delegate;
@end

// Helper class for managing mod installation queue
@interface ModQueueViewController : UITableViewController
@property (nonatomic, strong) NSMutableArray *queue; // @{@"mod": modDictionary, @"versionIndex": @(index)}
@property (nonatomic, copy) void (^didFinishInstallation)(void);
@end

@interface ModMenuViewController () <UISearchResultsUpdating, UITableViewDelegate, UITableViewDataSource, VersionSelectorDelegate>
// UI Components
@property (nonatomic, strong) UISearchController *searchController;
@property (nonatomic, strong) UISegmentedControl *apiSegmentedControl;
@property (nonatomic, strong) UIBarButtonItem *filterButton;
@property (nonatomic, strong) UIBarButtonItem *queueButton;
@property (nonatomic, strong) UIActivityIndicatorView *loadingIndicator;

// Data Sources
@property (nonatomic, strong) NSMutableArray *modsList;
@property (nonatomic, strong) ModrinthAPI *modrinth;
@property (nonatomic, strong) CurseForgeAPI *curseForge;
@property (nonatomic, strong) NSMutableDictionary *searchFilters;
@property (nonatomic, strong) ProfileData *currentProfile;
@property (nonatomic, strong) NSMutableArray *installQueue;

// State Management
@property (nonatomic, assign) BOOL isLoading;
@property (nonatomic, assign) BOOL hasPromptedForAPIKey;
@property (nonatomic, assign) BOOL isFilterByCurrentProfileEnabled;
@property (nonatomic, assign) BOOL isInitialLoad;
@property (nonatomic, strong) NSString *defaultInstance;
@end

@implementation ModMenuViewController

#pragma mark - Lifecycle Methods

- (void)viewDidLoad {
    [super viewDidLoad];
    
    self.isInitialLoad = YES;
    self.title = @"Mods";
    
    // Initialize APIs
    self.modrinth = [ModrinthAPI defaultAPI];
    
    // Get saved API key if available
    NSString *savedApiKey = [getPrefObject(kCurseForgeAPIKeyPrefKey) isKindOfClass:[NSString class]] ? 
                             getPrefObject(kCurseForgeAPIKeyPrefKey) : @"";
    self.curseForge = [[CurseForgeAPI alloc] initWithAPIKey:savedApiKey];
    self.curseForge.parentViewController = self;
    
    // Initialize state variables
    self.searchFilters = [@{@"isModpack": @(NO), @"name": @""} mutableCopy];
    self.modsList = [NSMutableArray new];
    self.installQueue = [NSMutableArray new];
    self.isLoading = NO;
    self.hasPromptedForAPIKey = NO;
    self.isFilterByCurrentProfileEnabled = getPrefBool(kFilterByProfilePrefKey);
    
    // Initialize profile data with default
    self.currentProfile = [ProfileData defaultProfile];
    
    // Set up the search controller
    self.searchController = [[UISearchController alloc] initWithSearchResultsController:nil];
    self.searchController.searchResultsUpdater = self;
    self.searchController.obscuresBackgroundDuringPresentation = NO;
    self.searchController.hidesNavigationBarDuringPresentation = NO;
    
    if (@available(iOS 16.0, *)) {
        self.navigationItem.preferredSearchBarPlacement = UINavigationItemSearchBarPlacementStacked;
    }
    
    self.navigationItem.searchController = self.searchController;
    self.navigationItem.hidesSearchBarWhenScrolling = NO;
    
    // Create loading indicator
    self.loadingIndicator = [[UIActivityIndicatorView alloc] initWithActivityIndicatorStyle:UIActivityIndicatorViewStyleMedium];
    
    // Set up the segmented control for API source
    self.apiSegmentedControl = [[UISegmentedControl alloc] initWithItems:@[@"Modrinth", @"CurseForge"]];
    self.apiSegmentedControl.selectedSegmentIndex = 0;
    [self.apiSegmentedControl addTarget:self action:@selector(apiSourceChanged:) forControlEvents:UIControlEventValueChanged];
    
    // Create a container for the segmented control with proper padding
    UIView *headerView = [[UIView alloc] initWithFrame:CGRectMake(0, 0, self.view.bounds.size.width, 60)];
    headerView.backgroundColor = [UIColor clearColor];
    
    self.apiSegmentedControl.frame = CGRectMake(16, 15, headerView.frame.size.width - 32, 30);
    self.apiSegmentedControl.autoresizingMask = UIViewAutoresizingFlexibleWidth;
    [headerView addSubview:self.apiSegmentedControl];
    
    self.tableView.tableHeaderView = headerView;
    
    // Set up navigation items
    self.filterButton = [[UIBarButtonItem alloc] initWithImage:[UIImage systemImageNamed:@"line.3.horizontal.decrease.circle"] 
                                                        style:UIBarButtonItemStylePlain 
                                                       target:self 
                                                       action:@selector(actionToggleFilter:)];
    
    self.queueButton = [[UIBarButtonItem alloc] initWithTitle:@"Queue (0)" 
                                                       style:UIBarButtonItemStylePlain 
                                                      target:self 
                                                      action:@selector(actionShowQueue)];
    
    UIBarButtonItem *profileButton = [[UIBarButtonItem alloc] initWithTitle:@"Profile" 
                                                                     style:UIBarButtonItemStylePlain 
                                                                    target:self 
                                                                    action:@selector(actionChooseProfile)];
    
    self.navigationItem.leftBarButtonItem = profileButton;
    self.navigationItem.rightBarButtonItems = @[self.queueButton, self.filterButton];
    
    // Set up table view
    self.tableView.rowHeight = UITableViewAutomaticDimension;
    self.tableView.estimatedRowHeight = 80;
    
    // Register notification handlers
    [[NSNotificationCenter defaultCenter] addObserver:self 
                                             selector:@selector(handleInstallModNotification:) 
                                                 name:@"InstallMod" 
                                               object:nil];
    
    // Update filter button state
    [self updateFilterButtonAppearance];
    
    // Update profile from saved settings
    [self updateProfileFromSavedSettings];
}

- (void)viewWillAppear:(BOOL)animated {
    [super viewWillAppear:animated];
    
    // If profile may have changed, reload
    if (!self.isInitialLoad) {
        [self updateProfileFromSavedSettings];
    }
    
    // Start initial search if we don't have data yet
    if (self.modsList.count == 0 && !self.isLoading) {
        [self performSearch:@""];
    }
    
    self.isInitialLoad = NO;
}

- (void)viewWillTransitionToSize:(CGSize)size withTransitionCoordinator:(id<UIViewControllerTransitionCoordinator>)coordinator {
    [super viewWillTransitionToSize:size withTransitionCoordinator:coordinator];
    [coordinator animateAlongsideTransition:^(id<UIViewControllerTransitionCoordinatorContext> context) {
        // Update layout for new size
        [self.tableView reloadData];
        
        // Update header view size
        UIView *headerView = self.tableView.tableHeaderView;
        headerView.frame = CGRectMake(0, 0, size.width, 60);
        self.tableView.tableHeaderView = headerView;
    } completion:nil];
}

- (void)dealloc {
    [[NSNotificationCenter defaultCenter] removeObserver:self];
}

#pragma mark - Profile Management

- (void)updateProfileFromSavedSettings {
    NSLog(@"[ModMenu] Updating profile from saved settings");
    
    // Step 1: Determine which profile to use (default instance or current selection)
    NSString *profileName = nil;
    NSDictionary *profileDict = nil;
    NSDictionary *allProfiles = [PLProfiles current].profiles;
    
    // Check if we should use a specified instance
    if (self.defaultInstance && self.defaultInstance.length > 0) {
        profileDict = allProfiles[self.defaultInstance];
        profileName = self.defaultInstance;
        
        if (!profileDict) {
            NSLog(@"[ModMenu] Warning: Specified instance '%@' not found", self.defaultInstance);
        }
    }
    
    // If no default instance or it wasn't found, use current selection
    if (!profileDict) {
        profileName = [PLProfiles current].selectedProfileName;
        profileDict = allProfiles[profileName];
    }
    
    // Step 2: Create profile data object
    ProfileData *profile;
    if (profileDict) {
        profile = [ProfileData fromDictionary:profileDict withName:profileName];
        NSLog(@"[ModMenu] Selected profile: %@, MC version: %@, mod loader: %@", 
              profile.name, profile.mcVersion, profile.modLoader);
    } else {
        // Fallback to default profile if nothing was found
        profile = [ProfileData defaultProfile];
        NSLog(@"[ModMenu] No valid profile found, using default");
    }
    
    // Step 3: Update current profile
    self.currentProfile = profile;
    
    // Step 4: Update search filters if filtering is enabled
    [self updateSearchFiltersFromCurrentProfile];
}

- (void)updateSearchFiltersFromCurrentProfile {
    if (!self.isFilterByCurrentProfileEnabled || !self.currentProfile) {
        // Remove profile-specific filters if not filtering
        [self.searchFilters removeObjectForKey:@"mcVersion"];
        [self.searchFilters removeObjectForKey:@"loader"];
        return;
    }
    
    // Add profile-specific filters
    if (self.currentProfile.mcVersion.length > 0) {
        self.searchFilters[@"mcVersion"] = self.currentProfile.mcVersion;
    } else {
        [self.searchFilters removeObjectForKey:@"mcVersion"];
    }
    
    if (self.currentProfile.modLoader.length > 0) {
        self.searchFilters[@"loader"] = self.currentProfile.modLoader;
    } else {
        [self.searchFilters removeObjectForKey:@"loader"];
    }
    
    NSLog(@"[ModMenu] Updated search filters: %@", self.searchFilters);
}

#pragma mark - VersionSelectorDelegate Implementation

- (void)handleVersionSelection:(NSDictionary *)mod selectedVersion:(NSUInteger)idx {
    // Directly install the mod instead of showing a popup
    [self installModNow:mod versionIndex:idx];
}

- (UIViewController *)presentedViewController {
    return [super presentedViewController];
}

#pragma mark - Public Methods

- (void)setDefaultInstance:(NSString *)instanceName {
    self.defaultInstance = instanceName;
    // If instance name is provided, attempt to load its profile
    if (instanceName) {
        [self updateProfileFromSavedSettings];
    }
}

- (void)setFilterByCurrentProfile:(BOOL)filterEnabled {
    if (self.isFilterByCurrentProfileEnabled == filterEnabled) {
        return; // No change needed
    }
    
    self.isFilterByCurrentProfileEnabled = filterEnabled;
    setPrefBool(kFilterByProfilePrefKey, filterEnabled);
    [self updateFilterButtonAppearance];
    
    // Update search filters
    [self updateSearchFiltersFromCurrentProfile];
    
    // Refresh the list with the new filter setting
    [self performSearch:self.searchController.searchBar.text];
}

#pragma mark - UI Actions

- (void)actionToggleFilter:(UIBarButtonItem *)sender {
    [self setFilterByCurrentProfile:!self.isFilterByCurrentProfileEnabled];
}

- (void)actionChooseProfile {
    NSDictionary *profiles = [PLProfiles current].profiles;
    if (!profiles || profiles.count == 0) {
        [UIAlertUtilities presentAlertWithTitle:@"Error" 
                                       message:@"No profiles available." 
                               viewController:self];
        return;
    }
    
    // Sort profiles by name for better user experience
    NSArray *sortedProfiles = [[profiles allValues] sortedArrayUsingComparator:^NSComparisonResult(NSDictionary *p1, NSDictionary *p2) {
        return [p1[@"name"] compare:p2[@"name"] options:NSCaseInsensitiveSearch];
    }];
    
    UIAlertController *alert = [UIAlertController alertControllerWithTitle:@"Select Profile"
                                                                  message:nil
                                                           preferredStyle:UIAlertControllerStyleActionSheet];
    
    // Add all profiles as options
    for (NSDictionary *profile in sortedProfiles) {
        NSString *profileName = profile[@"name"];
        
        // Get display name with version info
        NSString *versionId = profile[@"lastVersionId"] ?: @"latest-release";
        NSString *displayName = [NSString stringWithFormat:@"%@ (%@)", profileName, versionId];
        
        [alert addAction:[UIAlertAction actionWithTitle:displayName
                                                style:UIAlertActionStyleDefault
                                              handler:^(UIAlertAction * _Nonnull action) {
            // Get profile name from dictionary keys
            NSString *key = nil;
            for (NSString *k in profiles) {
                if (profiles[k] == profile) {
                    key = k;
                    break;
                }
            }
            
            if (!key) {
                NSLog(@"[ModMenu] Error: Couldn't find profile key for %@", profileName);
                return;
            }
            
            // Create profile data from selection
            ProfileData *selectedProfile = [ProfileData fromDictionary:profile withName:key];
            self.currentProfile = selectedProfile;
            
            NSLog(@"[ModMenu] User selected profile: %@, MC version: %@, mod loader: %@", 
                  selectedProfile.name, selectedProfile.mcVersion, selectedProfile.modLoader);
            
            // Update search filters and refresh content
            [self updateSearchFiltersFromCurrentProfile];
            
            if (self.isFilterByCurrentProfileEnabled) {
                [self performSearch:self.searchController.searchBar.text];
            }
        }]];
    }
    
    [alert addAction:[UIAlertAction actionWithTitle:@"Cancel"
                                            style:UIAlertActionStyleCancel
                                          handler:nil]];
    
    // Set up popover for iPad
    alert.popoverPresentationController.barButtonItem = self.navigationItem.leftBarButtonItem;
    
    [self presentViewController:alert animated:YES completion:nil];
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
    
    // Configure properly for iPad
    if (UIDevice.currentDevice.userInterfaceIdiom == UIUserInterfaceIdiomPad) {
        nav.modalPresentationStyle = UIModalPresentationFormSheet;
        nav.preferredContentSize = CGSizeMake(540, 620);
    } else {
        nav.modalPresentationStyle = UIModalPresentationPageSheet;
    }
    
    [self presentViewController:nav animated:YES completion:nil];
}

- (void)apiSourceChanged:(UISegmentedControl *)sender {
    // Clear the current list
    [self.modsList removeAllObjects];
    [self.tableView reloadData];
    
    // Only prompt for API key if switching to CurseForge and key is not already set
    if (sender.selectedSegmentIndex == 1) {
        NSString *savedApiKey = nil;
        id apiKeyObj = getPrefObject(kCurseForgeAPIKeyPrefKey);
        if ([apiKeyObj isKindOfClass:[NSString class]]) {
            savedApiKey = (NSString *)apiKeyObj;
        }
        
        if (!savedApiKey || savedApiKey.length == 0) {
            [self promptForCurseForgeAPIKey];
        } else {
            // Use saved API key
            [self.curseForge setValue:savedApiKey forKey:@"apiKey"];
            [self performSearch:self.searchController.searchBar.text];
        }
    } else {
        // Re-do the search with the current term
        [self performSearch:self.searchController.searchBar.text];
    }
}

#pragma mark - API Key Management

- (void)promptForCurseForgeAPIKey {
    self.hasPromptedForAPIKey = YES;
    
    UIAlertController *alert = [UIAlertController alertControllerWithTitle:@"CurseForge API Key Required"
                                                                  message:@"Please enter your CurseForge API key to search mods on CurseForge."
                                                           preferredStyle:UIAlertControllerStyleAlert];
    
    [alert addTextFieldWithConfigurationHandler:^(UITextField * _Nonnull textField) {
        textField.placeholder = @"API Key";
        textField.secureTextEntry = YES;
        
        // Pre-fill with saved API key if available
        id apiKeyObj = getPrefObject(kCurseForgeAPIKeyPrefKey);
        NSString *savedApiKey = nil;
        if ([apiKeyObj isKindOfClass:[NSString class]]) {
            savedApiKey = (NSString *)apiKeyObj;
            if (savedApiKey.length > 0) {
                textField.text = savedApiKey;
            }
        }
    }];
    
    [alert addAction:[UIAlertAction actionWithTitle:@"OK" style:UIAlertActionStyleDefault handler:^(UIAlertAction * _Nonnull action) {
        NSString *enteredKey = alert.textFields.firstObject.text;
        if (enteredKey.length > 0) {
            // Save the API key
            setPrefObject(kCurseForgeAPIKeyPrefKey, enteredKey);
            [self.curseForge setValue:enteredKey forKey:@"apiKey"];
            [self performSearch:self.searchController.searchBar.text];
        } else {
            // Switch back to Modrinth if no key provided
            self.apiSegmentedControl.selectedSegmentIndex = 0;
            [UIAlertUtilities presentAlertWithTitle:@"API Key Missing" 
                                           message:@"No API key entered. Switching back to Modrinth." 
                                   viewController:self];
        }
    }]];
    
    [alert addAction:[UIAlertAction actionWithTitle:@"Cancel" style:UIAlertActionStyleCancel handler:^(UIAlertAction * _Nonnull action) {
        // Switch back to Modrinth
        self.apiSegmentedControl.selectedSegmentIndex = 0;
    }]];
    
    [self presentViewController:alert animated:YES completion:nil];
}

#pragma mark - Version Selection

- (void)showVersionSelectorForMod:(NSDictionary *)mod atIndexPath:(NSIndexPath *)indexPath {
    NSArray *versionNames = mod[@"versionNames"];
    NSArray *gameVersionsArray = mod[@"gameVersions"] ?: mod[@"mcVersionNames"];
    NSArray *loadersArray = mod[@"versionLoaders"];
    
    if (!versionNames || ![versionNames isKindOfClass:[NSArray class]] || versionNames.count == 0) {
        [UIAlertUtilities presentAlertWithTitle:@"Error" 
                                       message:@"No versions available for this mod." 
                               viewController:self];
        return;
    }
    
    // Filter versions based on compatibility with selected profile
    NSMutableArray<NSString *> *compatibleVersions = [NSMutableArray array];
    NSMutableArray<NSNumber *> *compatibleIndices = [NSMutableArray array];
    
    NSString *profileMCVer = self.isFilterByCurrentProfileEnabled ? self.currentProfile.mcVersion : nil;
    NSString *profileLoader = self.isFilterByCurrentProfileEnabled ? self.currentProfile.modLoader : nil;
    
    if (profileMCVer.length == 0) profileMCVer = nil;
    if (profileLoader.length == 0) profileLoader = nil;
    
    // If no filtering, just use all versions
    if (!profileMCVer && !profileLoader) {
        for (NSUInteger i = 0; i < MIN(versionNames.count, kMaxVersionsToShow); i++) {
            NSString *verStr = [self safeStringFromObject:versionNames[i]];
            NSDictionary *parsed = [ModpackUtils parseVersionString:verStr];
            NSString *displayName = parsed[@"loaderVersion"] ?: verStr;
            
            [compatibleVersions addObject:displayName];
            [compatibleIndices addObject:@(i)];
        }
    } else {
        // Apply filtering
        for (NSUInteger i = 0; i < versionNames.count; i++) {
            // Check MC version compatibility
            BOOL mcMatch = !profileMCVer;  // If no MC version filter, all match
            
            if (profileMCVer && i < gameVersionsArray.count) {
                id gameVerItem = gameVersionsArray[i];
                NSArray *gameVers = [gameVerItem isKindOfClass:[NSArray class]] ? gameVerItem : @[gameVerItem];
                
                for (NSString *gv in gameVers) {
                    if (![gv isKindOfClass:[NSString class]]) continue;
                    
                    NSString *trimmedGV = [[gv stringByTrimmingCharactersInSet:[NSCharacterSet whitespaceAndNewlineCharacterSet]] lowercaseString];
                    NSString *trimmedProfileVer = [[profileMCVer stringByTrimmingCharactersInSet:[NSCharacterSet whitespaceAndNewlineCharacterSet]] lowercaseString];
                    
                    // More relaxed version matching
                    if ([trimmedGV isEqualToString:trimmedProfileVer] ||
                        [trimmedGV hasPrefix:trimmedProfileVer] ||
                        [trimmedProfileVer hasPrefix:trimmedGV]) {
                        mcMatch = YES;
                        break;
                    }
                }
            }
            
            // Check loader compatibility
            BOOL loaderMatch = !profileLoader;  // If no loader filter, all match
            
            if (profileLoader && loadersArray && i < loadersArray.count) {
                id loaderItem = loadersArray[i];
                NSArray *versionLoaders = [loaderItem isKindOfClass:[NSArray class]] ? loaderItem : @[loaderItem];
                
                for (NSString *ld in versionLoaders) {
                    if (![ld isKindOfClass:[NSString class]]) continue;
                    
                    NSString *trimmedLD = [[ld stringByTrimmingCharactersInSet:[NSCharacterSet whitespaceAndNewlineCharacterSet]] lowercaseString];
                    NSString *trimmedProfileLoader = [[profileLoader stringByTrimmingCharactersInSet:[NSCharacterSet whitespaceAndNewlineCharacterSet]] lowercaseString];
                    
                    // More relaxed loader matching
                    if ([trimmedLD isEqualToString:trimmedProfileLoader] ||
                        [trimmedLD containsString:trimmedProfileLoader] ||
                        [trimmedProfileLoader containsString:trimmedLD]) {
                        loaderMatch = YES;
                        break;
                    }
                }
            }
            
            // Add compatible versions to the list
            if (mcMatch && loaderMatch) {
                NSString *verStr = [self safeStringFromObject:versionNames[i]];
                NSDictionary *parsed = [ModpackUtils parseVersionString:verStr];
                NSString *displayName = parsed[@"loaderVersion"] ?: verStr;
                
                [compatibleVersions addObject:displayName];
                [compatibleIndices addObject:@(i)];
                
                // Limit to prevent UI freezing
                if (compatibleVersions.count >= kMaxVersionsToShow) {
                    break;
                }
            }
        }
    }
    
    // If no compatible versions found, show a message
    if (compatibleVersions.count == 0) {
        if (self.isFilterByCurrentProfileEnabled) {
            // Offer to disable filtering
            UIAlertController *alert = [UIAlertController alertControllerWithTitle:@"No Compatible Versions"
                                                                          message:@"No versions compatible with your current profile were found. Would you like to disable filtering to see all versions?"
                                                                   preferredStyle:UIAlertControllerStyleAlert];
            
            [alert addAction:[UIAlertAction actionWithTitle:@"Yes" style:UIAlertActionStyleDefault handler:^(UIAlertAction * _Nonnull action) {
                [self setFilterByCurrentProfile:NO];
                [self showVersionSelectorForMod:mod atIndexPath:indexPath];
            }]];
            
            [alert addAction:[UIAlertAction actionWithTitle:@"No" style:UIAlertActionStyleCancel handler:nil]];
            
            [self presentViewController:alert animated:YES completion:nil];
        } else {
            [UIAlertUtilities presentAlertWithTitle:@"No Compatible Versions" 
                                           message:@"No versions available for installation." 
                                   viewController:self];
        }
        return;
    }
    
    // Present the version selector UI based on device type
    if (UIDevice.currentDevice.userInterfaceIdiom == UIUserInterfaceIdiomPad) {
        [self showVersionSelectorTableForMod:mod withVersions:compatibleVersions indices:compatibleIndices];
    } else {
        [self showVersionSelectorAlertForMod:mod withVersions:compatibleVersions indices:compatibleIndices];
    }
}

- (void)showVersionSelectorAlertForMod:(NSDictionary *)mod withVersions:(NSArray<NSString *> *)versions indices:(NSArray<NSNumber *> *)indices {
    UIAlertController *alert = [UIAlertController alertControllerWithTitle:@"Select Version"
                                                                  message:nil
                                                           preferredStyle:UIAlertControllerStyleActionSheet];
    
    for (NSUInteger i = 0; i < versions.count; i++) {
        NSString *displayName = versions[i];
        NSUInteger originalIndex = [indices[i] unsignedIntegerValue];
        
        [alert addAction:[UIAlertAction actionWithTitle:displayName
                                                style:UIAlertActionStyleDefault
                                              handler:^(UIAlertAction * _Nonnull action) {
            [self handleVersionSelection:mod selectedVersion:originalIndex];
        }]];
    }
    
    [alert addAction:[UIAlertAction actionWithTitle:@"Cancel"
                                            style:UIAlertActionStyleCancel
                                          handler:nil]];
    
    // Set up popover presentation for iPad (fallback)
    if (UIDevice.currentDevice.userInterfaceIdiom == UIUserInterfaceIdiomPad) {
        UITableViewCell *cell = [self.tableView cellForRowAtIndexPath:[NSIndexPath indexPathForRow:[self.modsList indexOfObject:mod] inSection:0]];
        if (cell) {
            alert.popoverPresentationController.sourceView = cell;
            alert.popoverPresentationController.sourceRect = cell.bounds;
        } else {
            alert.popoverPresentationController.sourceView = self.view;
            alert.popoverPresentationController.sourceRect = CGRectMake(self.view.bounds.size.width / 2, self.view.bounds.size.height / 2, 1, 1);
        }
    }
    
    [self presentViewController:alert animated:YES completion:nil];
}

- (void)showVersionSelectorTableForMod:(NSDictionary *)mod withVersions:(NSArray<NSString *> *)versions indices:(NSArray<NSNumber *> *)indices {
    // Create a table view controller for version selection
    UITableViewController *versionTableVC = [[UITableViewController alloc] initWithStyle:UITableViewStyleInsetGrouped];
    versionTableVC.title = @"Select Version";
    
    // Create and configure the data source
    VersionSelectorDataSource *dataSource = [[VersionSelectorDataSource alloc] 
                                         initWithVersions:versions 
                                                      mod:mod 
                                                  indices:indices 
                                                 delegate:self];
    
    versionTableVC.tableView.dataSource = dataSource;
    versionTableVC.tableView.delegate = dataSource;
    
    // Create a navigation controller
    UINavigationController *navController = [[UINavigationController alloc] initWithRootViewController:versionTableVC];
    
    // Configure presentation style based on device type
    if (UIDevice.currentDevice.userInterfaceIdiom == UIUserInterfaceIdiomPad) {
        navController.modalPresentationStyle = UIModalPresentationFormSheet;
        navController.preferredContentSize = CGSizeMake(400, 600);
    } else {
        navController.modalPresentationStyle = UIModalPresentationPageSheet;
    }
    
    // Add close button
    versionTableVC.navigationItem.leftBarButtonItem = [[UIBarButtonItem alloc] 
                                                    initWithBarButtonSystemItem:UIBarButtonSystemItemCancel 
                                                                       target:self 
                                                                       action:@selector(dismissVersionSelector)];
    
    // The data source is retained by the navController through the table view association
    objc_setAssociatedObject(navController, "dataSource", dataSource, OBJC_ASSOCIATION_RETAIN_NONATOMIC);
    
    [self presentViewController:navController animated:YES completion:nil];
}

- (void)dismissVersionSelector {
    [self dismissViewControllerAnimated:YES completion:nil];
}

#pragma mark - Mod Installation

- (void)installModNow:(NSDictionary *)mod versionIndex:(NSUInteger)index {
    // Validate inputs
    NSArray *urls = mod[@"versionUrls"];
    if (index >= urls.count) {
        [UIAlertUtilities presentAlertWithTitle:@"Error" 
                                       message:@"Invalid version index for installation." 
                               viewController:self];
        return;
    }
    
    // Get the profile to install into
    ProfileData *targetProfile = self.currentProfile;
    if (!targetProfile) {
        [UIAlertUtilities presentAlertWithTitle:@"Error" 
                                       message:@"No profile selected. Please select a profile first." 
                               viewController:self];
        return;
    }
    
    NSString *urlString = urls[index];
    
    // Show loading indicator
    [self showLoadingIndicator];
    
    // Get the file name for the mod
    NSString *fileName = [[NSURL URLWithString:urlString] lastPathComponent];
    if (!fileName || fileName.length == 0) {
        // Generate a default name if URL doesn't have one
        fileName = [NSString stringWithFormat:@"mod_%@.jar", mod[@"title"]];
    }
    
    // Get profile information
    NSString *profileName = targetProfile.name;
    NSMutableDictionary *profile = [PLProfiles current].profiles[profileName];
    
    if (!profile) {
        [self hideLoadingIndicator];
        [UIAlertUtilities presentAlertWithTitle:@"Error" 
                                       message:@"Profile information is invalid." 
                               viewController:self];
        return;
    }
    
    NSString *gameDir = profile[@"gameDir"];
    
    // Ensure the profile directory exists
    [PLProfiles ensureProfileDirectoryExists:profileName gameDir:gameDir];
    
    // Get the full path to the profile directory
    NSString *profileDir = [PLProfiles fullPathForProfileWithName:profileName gameDir:gameDir];
    NSString *modsDir = [profileDir stringByAppendingPathComponent:@"mods"];
    
    // Create the mods directory if it doesn't exist
    if (![[NSFileManager defaultManager] fileExistsAtPath:modsDir]) {
        NSError *createError = nil;
        [[NSFileManager defaultManager] createDirectoryAtPath:modsDir 
                                  withIntermediateDirectories:YES 
                                                   attributes:nil 
                                                        error:&createError];
        if (createError) {
            [self hideLoadingIndicator];
            [UIAlertUtilities presentAlertWithTitle:@"Error" 
                                           message:[NSString stringWithFormat:@"Failed to create mods directory: %@", createError.localizedDescription] 
                                   viewController:self];
            return;
        }
    }
    
    NSString *destinationPath = [modsDir stringByAppendingPathComponent:fileName];
    
    // Download the mod file
    NSURLSession *session = [NSURLSession sharedSession];
    NSURLSessionDownloadTask *downloadTask = [session downloadTaskWithURL:[NSURL URLWithString:urlString] 
                                                        completionHandler:^(NSURL *location, NSURLResponse *response, NSError *error) {
        // Hide loading indicator on main thread
        dispatch_async(dispatch_get_main_queue(), ^{
            [self hideLoadingIndicator];
        });
        
        if (error) {
            NSLog(@"Download error: %@", error);
            dispatch_async(dispatch_get_main_queue(), ^{
                [UIAlertUtilities presentAlertWithTitle:@"Error" 
                                               message:[NSString stringWithFormat:@"Failed to download mod: %@", error.localizedDescription] 
                                       viewController:self];
            });
            return;
        }
        
        // Move the downloaded file to destination
        NSError *moveError = nil;
        
        // Remove existing file if needed
        if ([[NSFileManager defaultManager] fileExistsAtPath:destinationPath]) {
            [[NSFileManager defaultManager] removeItemAtPath:destinationPath error:nil];
        }
        
        [[NSFileManager defaultManager] moveItemAtURL:location toURL:[NSURL fileURLWithPath:destinationPath] error:&moveError];
        
        if (moveError) {
            NSLog(@"File move error: %@", moveError);
            dispatch_async(dispatch_get_main_queue(), ^{
                [UIAlertUtilities presentAlertWithTitle:@"Error" 
                                               message:[NSString stringWithFormat:@"Failed to save mod: %@", moveError.localizedDescription] 
                                       viewController:self];
            });
            return;
        }
        
        // Show success message
        dispatch_async(dispatch_get_main_queue(), ^{
            [UIAlertUtilities presentAlertWithTitle:@"Installation Complete" 
                                           message:[NSString stringWithFormat:@"%@ installed successfully to %@.", fileName, profileName] 
                                   viewController:self];
        });
    }];
    
    [downloadTask resume];
}

#pragma mark - Notification Handlers

- (void)handleInstallModNotification:(NSNotification *)notification {
    NSDictionary *userInfo = notification.userInfo;
    NSDictionary *mod = userInfo[@"detail"];
    NSUInteger index = [userInfo[@"index"] unsignedIntegerValue];
    
    // Validate input
    if (!mod) {
        [UIAlertUtilities presentAlertWithTitle:@"Error" 
                                       message:@"Invalid mod data received." 
                               viewController:self];
        return;
    }
    
    [self installModNow:mod versionIndex:index];
}

#pragma mark - Search Handling

- (void)updateSearchResultsForSearchController:(UISearchController *)searchController {
    [NSObject cancelPreviousPerformRequestsWithTarget:self selector:@selector(performDelayedSearch:) object:nil];
    [self performSelector:@selector(performDelayedSearch:) withObject:searchController.searchBar.text afterDelay:kSearchDebounceDelay];
}

- (void)performDelayedSearch:(NSString *)searchText {
    [self performSearch:searchText];
}

- (void)performSearch:(NSString *)searchText {
    // Don't perform concurrent searches
    if (self.isLoading) {
        return;
    }
    
    self.isLoading = YES;
    [self showSearchLoadingIndicator];
    
    // Update search filters
    self.searchFilters[@"name"] = searchText ?: @"";
    
    // Make sure filters are applied correctly
    [self updateSearchFiltersFromCurrentProfile];
    
    // Perform search on background thread
    dispatch_async(dispatch_get_global_queue(DISPATCH_QUEUE_PRIORITY_DEFAULT, 0), ^{
        if (self.apiSegmentedControl.selectedSegmentIndex == 0) {
            // Modrinth search
            NSMutableArray *results = [self.modrinth searchModWithFilters:self.searchFilters previousPageResult:nil];
            
            dispatch_async(dispatch_get_main_queue(), ^{
                self.isLoading = NO;
                [self hideSearchLoadingIndicator];
                
                if (results) {
                    self.modsList = results;
                    [self.tableView reloadData];
                } else if (self.modrinth.lastError) {
                    [UIAlertUtilities presentAlertWithTitle:@"Error" 
                                                   message:self.modrinth.lastError.localizedDescription 
                                           viewController:self];
                }
            });
        } else {
            // CurseForge search
            [self.curseForge searchModWithFilters:self.searchFilters previousPageResult:nil completion:^(NSMutableArray *results, NSError *error) {
                dispatch_async(dispatch_get_main_queue(), ^{
                    self.isLoading = NO;
                    [self hideSearchLoadingIndicator];
                    
                    if (results) {
                        self.modsList = results;
                        [self.tableView reloadData];
                    } else if (error) {
                        [UIAlertUtilities presentAlertWithTitle:@"Error" 
                                                       message:error.localizedDescription 
                                               viewController:self];
                    }
                });
            }];
        }
    });
}

#pragma mark - Loading Indicators

- (void)showLoadingIndicator {
    if (!self.loadingIndicator.isAnimating) {
        UIActivityIndicatorView *indicator = [[UIActivityIndicatorView alloc] initWithActivityIndicatorStyle:UIActivityIndicatorViewStyleMedium];
        [indicator startAnimating];
        self.navigationItem.leftBarButtonItem = [[UIBarButtonItem alloc] initWithCustomView:indicator];
    }
}

- (void)hideLoadingIndicator {
    if (self.navigationItem.leftBarButtonItem.customView == self.loadingIndicator) {
        UIBarButtonItem *profileButton = [[UIBarButtonItem alloc] initWithTitle:@"Profile" 
                                                                         style:UIBarButtonItemStylePlain 
                                                                        target:self 
                                                                        action:@selector(actionChooseProfile)];
        self.navigationItem.leftBarButtonItem = profileButton;
    }
}

- (void)showSearchLoadingIndicator {
    if (!self.loadingIndicator.isAnimating) {
        [self.loadingIndicator startAnimating];
        UIBarButtonItem *loadingItem = [[UIBarButtonItem alloc] initWithCustomView:self.loadingIndicator];
        self.navigationItem.rightBarButtonItems = @[self.queueButton, loadingItem];
    }
}

- (void)hideSearchLoadingIndicator {
    [self.loadingIndicator stopAnimating];
    self.navigationItem.rightBarButtonItems = @[self.queueButton, self.filterButton];
}

#pragma mark - Helper Methods

- (void)updateQueueButtonTitle {
    NSUInteger count = self.installQueue.count;
    self.queueButton.title = [NSString stringWithFormat:@"Queue (%lu)", (unsigned long)count];
}

- (void)updateFilterButtonAppearance {
    if (self.isFilterByCurrentProfileEnabled) {
        self.filterButton.image = [UIImage systemImageNamed:@"line.3.horizontal.decrease.circle.fill"];
        self.filterButton.tintColor = self.view.tintColor;
    } else {
        self.filterButton.image = [UIImage systemImageNamed:@"line.3.horizontal.decrease.circle"];
        self.filterButton.tintColor = [UIColor systemGrayColor];
    }
}

- (void)updateModsList {
    [self performSearch:self.searchController.searchBar.text];
}

- (NSString *)safeStringFromObject:(id)obj {
    if ([obj isKindOfClass:[NSString class]]) {
        return obj;
    } else if ([obj respondsToSelector:@selector(stringValue)]) {
        return [obj stringValue];
    } else {
        return [obj description];
    }
}

#pragma mark - UITableView DataSource & Delegate

- (NSInteger)tableView:(UITableView *)tableView numberOfRowsInSection:(NSInteger)section {
    if (self.modsList.count == 0 && !self.isLoading) {
        return 1; // Show "No results" cell
    }
    return self.modsList.count;
}

- (UITableViewCell *)tableView:(UITableView *)tableView cellForRowAtIndexPath:(NSIndexPath *)indexPath {
    static NSString *cellIdentifier = @"ModCell";
    UITableViewCell *cell = [tableView dequeueReusableCellWithIdentifier:cellIdentifier];
    
    if (!cell) {
        cell = [[UITableViewCell alloc] initWithStyle:UITableViewCellStyleSubtitle reuseIdentifier:cellIdentifier];
        cell.accessoryType = UITableViewCellAccessoryDisclosureIndicator;
        
        // Configure cell appearance
        cell.imageView.contentMode = UIViewContentModeScaleAspectFill;
        cell.imageView.clipsToBounds = YES;
        cell.imageView.layer.cornerRadius = 4;
        
        // Ensure text doesn't get truncated in narrow layouts
        cell.textLabel.numberOfLines = 1;
        cell.textLabel.adjustsFontSizeToFitWidth = YES;
        cell.textLabel.minimumScaleFactor = 0.75;
        
        cell.detailTextLabel.numberOfLines = 2;
    }
    
    // Handle empty state
    if (self.modsList.count == 0 && !self.isLoading) {
        cell.textLabel.text = @"No mods found";
        cell.detailTextLabel.text = @"Try a different search or switch sources";
        cell.imageView.image = nil;
        cell.accessoryType = UITableViewCellAccessoryNone;
        cell.selectionStyle = UITableViewCellSelectionStyleNone;
        return cell;
    }
    
    // Configure cell with mod data
    NSDictionary *mod = self.modsList[indexPath.row];
    
    cell.textLabel.text = mod[@"title"];
    cell.detailTextLabel.text = mod[@"description"];
    cell.selectionStyle = UITableViewCellSelectionStyleDefault;
    cell.accessoryType = UITableViewCellAccessoryDisclosureIndicator;
    
    // Load image with placeholder
    UIImage *placeholder = [UIImage imageNamed:@"DefaultProfile"];
    if (mod[@"imageUrl"] && [mod[@"imageUrl"] length] > 0) {
        [cell.imageView setImageWithURL:[NSURL URLWithString:mod[@"imageUrl"]] 
                       placeholderImage:placeholder];
    } else {
        cell.imageView.image = placeholder;
    }
    
    return cell;
}

- (void)tableView:(UITableView *)tableView didSelectRowAtIndexPath:(NSIndexPath *)indexPath {
    [tableView deselectRowAtIndexPath:indexPath animated:YES];
    
    // Handle empty state selection
    if (self.modsList.count == 0) {
        return;
    }
    
    NSDictionary *mod = self.modsList[indexPath.row];
    
    // Show loading indicator
    [self showLoadingIndicator];
    
    // Check if details are already loaded
    if ([mod[@"versionDetailsLoaded"] boolValue]) {
        [self hideLoadingIndicator];
        [self showVersionSelectorForMod:mod atIndexPath:indexPath];
    } else {
        // Need to load details first
        if (self.apiSegmentedControl.selectedSegmentIndex == 0) {
            [self.modrinth loadDetailsOfMod:[mod mutableCopy] completion:^(NSError *error) {
                dispatch_async(dispatch_get_main_queue(), ^{
                    [self hideLoadingIndicator];
                    
                    if (error) {
                        [UIAlertUtilities presentAlertWithTitle:@"Error" 
                                                       message:error.localizedDescription 
                                               viewController:self];
                        return;
                    }
                    
                    // Get the updated mod with loaded details
                    NSDictionary *updatedMod = [mod mutableCopy];
                    if ([updatedMod[@"versionDetailsLoaded"] boolValue]) {
                        // Replace in the list so it doesn't need to be reloaded
                        [self.modsList replaceObjectAtIndex:indexPath.row withObject:updatedMod];
                        [self showVersionSelectorForMod:updatedMod atIndexPath:indexPath];
                    } else {
                        [UIAlertUtilities presentAlertWithTitle:@"Error" 
                                                       message:@"Failed to load mod versions" 
                                               viewController:self];
                    }
                });
            }];
        } else {
            [self.curseForge loadDetailsOfMod:[mod mutableCopy] completion:^(NSError *error) {
                dispatch_async(dispatch_get_main_queue(), ^{
                    [self hideLoadingIndicator];
                    
                    if (error) {
                        [UIAlertUtilities presentAlertWithTitle:@"Error" 
                                                       message:error.localizedDescription 
                                               viewController:self];
                        return;
                    }
                    
                    // Get the updated mod with loaded details
                    NSDictionary *updatedMod = [mod mutableCopy];
                    if ([updatedMod[@"versionDetailsLoaded"] boolValue]) {
                        // Replace in the list so it doesn't need to be reloaded
                        [self.modsList replaceObjectAtIndex:indexPath.row withObject:updatedMod];
                        [self showVersionSelectorForMod:updatedMod atIndexPath:indexPath];
                    } else {
                        [UIAlertUtilities presentAlertWithTitle:@"Error" 
                                                       message:@"Failed to load mod versions" 
                                               viewController:self];
                    }
                });
            }];
        }
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
        
        // Create activity indicator for loading state
        _activityIndicator = [[UIActivityIndicatorView alloc] initWithActivityIndicatorStyle:UIActivityIndicatorViewStyleMedium];
    }
    return self;
}

- (NSInteger)tableView:(UITableView *)tableView numberOfRowsInSection:(NSInteger)section {
    return self.versions.count;
}

- (UITableViewCell *)tableView:(UITableView *)tableView cellForRowAtIndexPath:(NSIndexPath *)indexPath {
    static NSString *cellId = @"VersionCell";
    UITableViewCell *cell = [tableView dequeueReusableCellWithIdentifier:cellId];
    
    if (!cell) {
        cell = [[UITableViewCell alloc] initWithStyle:UITableViewCellStyleSubtitle reuseIdentifier:cellId];
    }
    
    if (indexPath.row < self.versions.count) {
        cell.textLabel.text = self.versions[indexPath.row];
        
        // Add additional information if available
        NSUInteger originalIndex = [self.indices[indexPath.row] unsignedIntegerValue];
        NSArray *mcVersions = self.mod[@"mcVersionNames"];
        if (mcVersions && originalIndex < mcVersions.count) {
            id versionArray = mcVersions[originalIndex];
            if ([versionArray isKindOfClass:[NSArray class]] && [(NSArray *)versionArray count] > 0) {
                NSString *mcVersionText = [(NSArray *)versionArray componentsJoinedByString:@", "];
                cell.detailTextLabel.text = [NSString stringWithFormat:@"Minecraft: %@", mcVersionText];
            }
        }
    }
    
    return cell;
}

- (void)tableView:(UITableView *)tableView didSelectRowAtIndexPath:(NSIndexPath *)indexPath {
    [tableView deselectRowAtIndexPath:indexPath animated:YES];
    
    if (indexPath.row < self.indices.count) {
        // Show loading state
        UITableViewCell *cell = [tableView cellForRowAtIndexPath:indexPath];
        cell.accessoryView = self.activityIndicator;
        [self.activityIndicator startAnimating];
        
        NSUInteger versionIndex = [self.indices[indexPath.row] unsignedIntegerValue];
        
        // Small delay to show loading state before dismissing
        dispatch_after(dispatch_time(DISPATCH_TIME_NOW, (int64_t)(0.3 * NSEC_PER_SEC)), dispatch_get_main_queue(), ^{
            UIViewController *vc = [self.delegate presentedViewController];
            [vc dismissViewControllerAnimated:YES completion:^{
                [self.delegate handleVersionSelection:self.mod selectedVersion:versionIndex];
            }];
        });
    }
}

@end

#pragma mark - ModQueueViewController Implementation

@implementation ModQueueViewController

- (void)viewDidLoad {
    [super viewDidLoad];
    
    self.title = @"Install Queue";
    
    // Configure table view
    self.tableView.tableFooterView = [UIView new];
    
    // Add navigation items
    self.navigationItem.rightBarButtonItem = [[UIBarButtonItem alloc] initWithTitle:@"Install All"
                                                                             style:UIBarButtonItemStyleDone
                                                                            target:self
                                                                            action:@selector(installQueueAction)];
    
    self.navigationItem.leftBarButtonItem = self.editButtonItem;
    
    // Initialize empty queue if needed
    if (!self.queue) {
        self.queue = [NSMutableArray array];
    }
}

- (void)installQueueAction {
    if (self.queue.count == 0) {
        [UIAlertUtilities presentAlertWithTitle:@"Queue Empty" 
                                       message:@"There are no mods in the install queue." 
                               viewController:self];
        return;
    }
    
    // Show confirmation
    UIAlertController *alert = [UIAlertController alertControllerWithTitle:@"Install All Mods"
                                                                  message:[NSString stringWithFormat:@"Are you sure you want to install all %lu mods?", (unsigned long)self.queue.count]
                                                           preferredStyle:UIAlertControllerStyleAlert];
    
    [alert addAction:[UIAlertAction actionWithTitle:@"Yes" style:UIAlertActionStyleDefault handler:^(UIAlertAction * _Nonnull action) {
        // Process all queued mods
        for (NSDictionary *entry in self.queue) {
            NSDictionary *mod = entry[@"mod"];
            NSUInteger versionIndex = [entry[@"versionIndex"] unsignedIntegerValue];
            
            // Dispatch notification to handle installation
            [[NSNotificationCenter defaultCenter] postNotificationName:@"InstallMod"
                                                                object:nil
                                                              userInfo:@{@"detail": mod, @"index": @(versionIndex)}];
        }
        
        // Clear the queue
        [self.queue removeAllObjects];
        
        // Refresh the table
        [self.tableView reloadData];
        
        // Call completion handler if set
        if (self.didFinishInstallation) {
            self.didFinishInstallation();
        }
        
        // Dismiss the view controller
        [self dismissViewControllerAnimated:YES completion:nil];
    }]];
    
    [alert addAction:[UIAlertAction actionWithTitle:@"No" style:UIAlertActionStyleCancel handler:nil]];
    
    [self presentViewController:alert animated:YES completion:nil];
}

#pragma mark - UITableViewDataSource

- (NSInteger)tableView:(UITableView *)tableView numberOfRowsInSection:(NSInteger)section {
    return self.queue.count;
}

- (UITableViewCell *)tableView:(UITableView *)tableView cellForRowAtIndexPath:(NSIndexPath *)indexPath {
    static NSString *cellId = @"QueueCell";
    UITableViewCell *cell = [tableView dequeueReusableCellWithIdentifier:cellId];
    
    if (!cell) {
        cell = [[UITableViewCell alloc] initWithStyle:UITableViewCellStyleSubtitle reuseIdentifier:cellId];
    }
    
    if (indexPath.row < self.queue.count) {
        NSDictionary *entry = self.queue[indexPath.row];
        NSDictionary *mod = entry[@"mod"];
        NSUInteger versionIndex = [entry[@"versionIndex"] unsignedIntegerValue];
        
        cell.textLabel.text = mod[@"title"];
        
        // Get version information
        NSArray *versionNames = mod[@"versionNames"];
        if (versionIndex < versionNames.count) {
            id versionObj = versionNames[versionIndex];
            NSString *verStr = nil;
            
            if ([versionObj isKindOfClass:[NSString class]]) {
                verStr = versionObj;
                // Parse version for better display
                NSDictionary *parsed = [ModpackUtils parseVersionString:verStr];
                cell.detailTextLabel.text = parsed[@"loaderVersion"] ?: verStr;
            } else {
                cell.detailTextLabel.text = [NSString stringWithFormat:@"%@", versionObj];
            }
        } else {
            cell.detailTextLabel.text = @"Unknown version";
        }
    }
    
    return cell;
}

- (void)tableView:(UITableView *)tableView commitEditingStyle:(UITableViewCellEditingStyle)editingStyle 
forRowAtIndexPath:(NSIndexPath *)indexPath {
    if (editingStyle == UITableViewCellEditingStyleDelete && indexPath.row < self.queue.count) {
        [self.queue removeObjectAtIndex:indexPath.row];
        [tableView deleteRowsAtIndexPaths:@[indexPath] withRowAnimation:UITableViewRowAnimationAutomatic];
        
        // Call completion handler to update queue button
        if (self.didFinishInstallation) {
            self.didFinishInstallation();
        }
    }
}

- (void)tableView:(UITableView *)tableView didSelectRowAtIndexPath:(NSIndexPath *)indexPath {
    [tableView deselectRowAtIndexPath:indexPath animated:YES];
    
    if (indexPath.row < self.queue.count) {
        NSDictionary *entry = self.queue[indexPath.row];
        NSDictionary *mod = entry[@"mod"];
        NSUInteger versionIndex = [entry[@"versionIndex"] unsignedIntegerValue];
        
        // Show options alert
        UIAlertController *alert = [UIAlertController alertControllerWithTitle:@"Mod Options"
                                                                      message:mod[@"title"]
                                                               preferredStyle:UIAlertControllerStyleActionSheet];
        
        [alert addAction:[UIAlertAction actionWithTitle:@"Install Now" style:UIAlertActionStyleDefault handler:^(UIAlertAction * _Nonnull action) {
            // Post notification to handle installation
            [[NSNotificationCenter defaultCenter] postNotificationName:@"InstallMod"
                                                                object:nil
                                                              userInfo:@{@"detail": mod, @"index": @(versionIndex)}];
            
            // Remove from queue
            [self.queue removeObjectAtIndex:indexPath.row];
            [tableView deleteRowsAtIndexPaths:@[indexPath] withRowAnimation:UITableViewRowAnimationAutomatic];
            
            // Call completion handler
            if (self.didFinishInstallation) {
                self.didFinishInstallation();
            }
        }]];
        
        [alert addAction:[UIAlertAction actionWithTitle:@"Remove from Queue" style:UIAlertActionStyleDestructive handler:^(UIAlertAction * _Nonnull action) {
            [self.queue removeObjectAtIndex:indexPath.row];
            [tableView deleteRowsAtIndexPaths:@[indexPath] withRowAnimation:UITableViewRowAnimationAutomatic];
            
            // Call completion handler
            if (self.didFinishInstallation) {
                self.didFinishInstallation();
            }
        }]];
        
        [alert addAction:[UIAlertAction actionWithTitle:@"Cancel" style:UIAlertActionStyleCancel handler:nil]];
        
        // Set up popover for iPad
        if (UIDevice.currentDevice.userInterfaceIdiom == UIUserInterfaceIdiomPad) {
            UITableViewCell *cell = [tableView cellForRowAtIndexPath:indexPath];
            alert.popoverPresentationController.sourceView = cell;
            alert.popoverPresentationController.sourceRect = cell.bounds;
        }
        
        [self presentViewController:alert animated:YES completion:nil];
    }
}

@end

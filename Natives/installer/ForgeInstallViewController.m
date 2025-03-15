#import "AFNetworking.h"
#import "ForgeInstallViewController.h"
#import "LauncherNavigationController.h"
#import "WFWorkflowProgressView.h"
#import "ios_uikit_bridge.h"
#import "utils.h"
#include <dlfcn.h>

@interface ForgeInstallViewController()<NSXMLParserDelegate>
@property(atomic) AFURLSessionManager *afManager;
@property(nonatomic) WFWorkflowProgressView *progressView;

@property(nonatomic) NSDictionary *endpoints;
@property(nonatomic) NSMutableArray<NSNumber *> *visibilityList;
@property(nonatomic) NSMutableArray<NSString *> *versionList;
@property(nonatomic) NSMutableArray<NSMutableArray *> *forgeList;
@property(nonatomic, assign) BOOL isVersionElement;
@property(nonatomic, strong) NSMutableString *currentVersionValue;
@end

@implementation ForgeInstallViewController

- (void)viewDidLoad {
    [super viewDidLoad];
    UISegmentedControl *segment = [[UISegmentedControl alloc] initWithItems:@[@"Forge", @"NeoForge"]];
    segment.selectedSegmentIndex = 0;
    [segment addTarget:self action:@selector(segmentChanged:) forControlEvents:UIControlEventValueChanged];
    self.navigationItem.titleView = segment;

    // Load WFWorkflowProgressView
    dlopen("/System/Library/PrivateFrameworks/WorkflowUIServices.framework/WorkflowUIServices", RTLD_GLOBAL);
    self.progressView = [[NSClassFromString(@"WFWorkflowProgressView") alloc] initWithFrame:CGRectMake(0, 0, 30, 30)];
    self.progressView.resolvedTintColor = self.view.tintColor;
    [self.progressView addTarget:self
        action:@selector(actionCancelDownload) forControlEvents:UIControlEventTouchUpInside];

    self.endpoints = @{
        @"Forge": @{
            @"installer": @"https://maven.minecraftforge.net/net/minecraftforge/forge/%1$@/forge-%1$@-installer.jar",
            @"metadata": @"https://maven.minecraftforge.net/net/minecraftforge/forge/maven-metadata.xml"
        },
        @"NeoForge": @{
            @"installer": @"https://maven.neoforged.net/releases/net/neoforged/neoforge/%1$@/neoforge-%1$@-installer.jar",
            @"metadata": @"https://maven.neoforged.net/releases/net/neoforged/neoforge/maven-metadata.xml"
        }
    };
    self.visibilityList = [NSMutableArray new];
    self.versionList = [NSMutableArray new];
    self.forgeList = [NSMutableArray new];
    [self loadMetadataFromVendor:@"Forge"];
}

- (void)actionCancelDownload {
    [self.afManager invalidateSessionCancelingTasks:YES resetSession:NO];
}

- (void)actionClose {
    [self.navigationController dismissViewControllerAnimated:YES completion:nil];
}

- (void)loadMetadataFromVendor:(NSString *)vendor {
    [self switchToLoadingState];
    dispatch_async(dispatch_get_global_queue(DISPATCH_QUEUE_PRIORITY_DEFAULT, 0), ^{
        NSURL *url = [[NSURL alloc] initWithString:self.endpoints[vendor][@"metadata"]];
        NSXMLParser *parser = [[NSXMLParser alloc] initWithContentsOfURL:url];
        parser.delegate = self;
        // Initialize current version value buffer
        self.currentVersionValue = [NSMutableString new];
        if (![parser parse]) {
            dispatch_async(dispatch_get_main_queue(), ^{
                showDialog(localize(@"Error", nil), parser.parserError.localizedDescription);
                [self actionClose];
            });
        }
    });
}

- (void)switchToLoadingState {
    UIActivityIndicatorView *indicator = [[UIActivityIndicatorView alloc] initWithActivityIndicatorStyle:UIActivityIndicatorViewStyleMedium];
    self.navigationItem.rightBarButtonItem = [[UIBarButtonItem alloc] initWithCustomView:indicator];
    [indicator startAnimating];
    self.navigationController.modalInPresentation = YES;
}

- (void)switchToReadyState {
    UIActivityIndicatorView *indicator = (id)self.navigationItem.rightBarButtonItem.customView;
    [indicator stopAnimating];
    self.navigationItem.rightBarButtonItem = [[UIBarButtonItem alloc] initWithBarButtonSystemItem:UIBarButtonSystemItemClose target:self action:@selector(actionClose)];
    self.navigationController.modalInPresentation = NO;
}

- (void)segmentChanged:(UISegmentedControl *)segment {
    [self.visibilityList removeAllObjects];
    [self.versionList removeAllObjects];
    [self.forgeList removeAllObjects];
    [self.tableView reloadData];
    NSString *vendor = [segment titleForSegmentAtIndex:segment.selectedSegmentIndex];
    [self loadMetadataFromVendor:vendor];
}

// Helper methods for version parsing and comparison
- (NSArray<NSString *> *)parseVersionComponents:(NSString *)version {
    NSString *versionString = version;
    UISegmentedControl *segment = (id)self.navigationItem.titleView;
    NSString *vendor = [segment titleForSegmentAtIndex:segment.selectedSegmentIndex];
    
    // Get version numbers only
    if ([vendor isEqualToString:@"NeoForge"]) {
        // For NeoForge: extract the numeric parts XX.Y.ZZZ from XX.Y.ZZZ-suffix
        NSRange hyphenRange = [version rangeOfString:@"-"];
        if (hyphenRange.location != NSNotFound) {
            versionString = [version substringToIndex:hyphenRange.location];
        }
    } else {
        // For Forge: extract the numeric parts after the hyphen ("1.16.5-36.2.39" -> "36.2.39")
        NSRange hyphenRange = [version rangeOfString:@"-"];
        if (hyphenRange.location != NSNotFound) {
            versionString = [version substringFromIndex:hyphenRange.location + 1];
        }
    }
    
    // Split into numeric components
    NSArray<NSString *> *components = [versionString componentsSeparatedByString:@"."];
    
    // Return array of numeric components
    return components;
}

- (NSString *)extractVersionSuffix:(NSString *)version {
    NSRange hyphenRange = [version rangeOfString:@"-"];
    if (hyphenRange.location != NSNotFound && hyphenRange.location < version.length - 1) {
        return [version substringFromIndex:hyphenRange.location + 1];
    }
    return @"";
}

#pragma mark UITableViewDataSource

- (NSInteger)numberOfSectionsInTableView:(UITableView *)tableView {
    return self.versionList.count;
}

- (UIView *)tableView:(UITableView *)tableView viewForHeaderInSection:(NSInteger)section {
    UITableViewHeaderFooterView *view = [self.tableView dequeueReusableHeaderFooterViewWithIdentifier:@"section"];
    if (!view) {
        view = [[UITableViewHeaderFooterView alloc] initWithReuseIdentifier:@"section"];
        UITapGestureRecognizer *tapGesture = [[UITapGestureRecognizer alloc] initWithTarget:self action:@selector(tableViewDidSelectSection:)];
        [view addGestureRecognizer:tapGesture];
    }
    return view;
}

- (NSString *)tableView:(UITableView *)tableView titleForHeaderInSection:(NSInteger)section {
    return self.versionList[section];
}

- (void)tableViewDidSelectSection:(UITapGestureRecognizer *)sender {
    UITableViewHeaderFooterView *view = (id)sender.view;
    int section = [self.versionList indexOfObject:view.textLabel.text];
    self.visibilityList[section] = @(!self.visibilityList[section].boolValue);
    [self.tableView reloadSections:[NSIndexSet indexSetWithIndex:section] withRowAnimation:UITableViewRowAnimationAutomatic];
}

- (NSInteger)tableView:(UITableView *)tableView numberOfRowsInSection:(NSInteger)section {
    return self.visibilityList[section].boolValue ? self.forgeList[section].count : 0;
}

- (UITableViewCell *)tableView:(UITableView *)tableView cellForRowAtIndexPath:(NSIndexPath *)indexPath {
    UITableViewCell *cell = [tableView dequeueReusableCellWithIdentifier:@"cell"];
    if (!cell) {
        cell = [[UITableViewCell alloc] initWithStyle:UITableViewCellStyleDefault reuseIdentifier:@"cell"];
    }

    cell.textLabel.text = self.forgeList[indexPath.section][indexPath.row];
    return cell;
}

- (void)tableView:(UITableView *)tableView didSelectRowAtIndexPath:(NSIndexPath *)indexPath {
    [tableView deselectRowAtIndexPath:indexPath animated:NO];
    tableView.allowsSelection = NO;

    [self switchToLoadingState];
    self.progressView.fractionCompleted = 0;

    UITableViewCell *cell = [tableView cellForRowAtIndexPath:indexPath];
    cell.accessoryView = self.progressView;

    UISegmentedControl *segment = (id)self.navigationItem.titleView;
    NSString *vendor = [segment titleForSegmentAtIndex:segment.selectedSegmentIndex];
    NSString *jarURL = [NSString stringWithFormat:self.endpoints[vendor][@"installer"], cell.textLabel.text];
    NSString *outPath = [NSTemporaryDirectory() stringByAppendingPathComponent:@"tmp.jar"];
    NSDebugLog(@"[Forge Installer] Downloading %@", jarURL);

    self.afManager = [AFURLSessionManager new];
    NSURLRequest *request = [NSURLRequest requestWithURL:[NSURL URLWithString:jarURL]];
    NSURLSessionDownloadTask *downloadTask = [self.afManager downloadTaskWithRequest:request progress:^(NSProgress * _Nonnull progress){
        dispatch_async(dispatch_get_main_queue(), ^{
            self.progressView.fractionCompleted = progress.fractionCompleted;
        });
    } destination:^NSURL *(NSURL *targetPath, NSURLResponse *response) {
        [NSFileManager.defaultManager removeItemAtPath:outPath error:nil];
        return [NSURL fileURLWithPath:outPath];
    } completionHandler:^(NSURLResponse *response, NSURL *filePath, NSError *error) {
        dispatch_async(dispatch_get_main_queue(), ^{
            tableView.allowsSelection = YES;
            cell.accessoryView = nil;
            if (error) {
                if (error.code != NSURLErrorCancelled) {
                    NSDebugLog(@"Error: %@", error);
                    showDialog(localize(@"Error", nil), error.localizedDescription);
                }
                [self switchToReadyState];
                return;
            }
            LauncherNavigationController *navVC = (id)((UISplitViewController *)self.presentingViewController).viewControllers[1];
            [self dismissViewControllerAnimated:YES completion:^{
                [navVC enterModInstallerWithPath:outPath hitEnterAfterWindowShown:YES];
            }];
        });
    }];
    dispatch_async(dispatch_get_global_queue(DISPATCH_QUEUE_PRIORITY_DEFAULT, 0), ^{
        [downloadTask resume];
    });
}

- (void)addVersionToList:(NSString *)version {
    UISegmentedControl *segment = (id)self.navigationItem.titleView;
    NSString *vendor = [segment titleForSegmentAtIndex:segment.selectedSegmentIndex];
    
    if (![version containsString:@"-"] && ![vendor isEqualToString:@"NeoForge"]) {
        return; // Skip if no hyphen (except for NeoForge which may not have one)
    }
    
    NSString *gameVersion = nil;
    
    if ([vendor isEqualToString:@"NeoForge"]) {
        // NeoForge version parsing
        NSArray *components = [version componentsSeparatedByString:@"-"];
        
        if (components.count > 0) {
            // Check if this is the format without "1." prefix (e.g., "21.4.94-something")
            NSString *firstComponent = components[0];
            NSArray *versionParts = [firstComponent componentsSeparatedByString:@"."];
            
            // Only process if it has multiple parts and first part is numeric
            if (versionParts.count >= 2 && 
                [[NSScanner scannerWithString:versionParts[0]] scanInt:NULL] && 
                [[NSScanner scannerWithString:versionParts[1]] scanInt:NULL]) {
                
                // Check if first component could be a Minecraft version without "1."
                // Typically major versions will be under 30 (we don't expect MC 1.31+)
                if ([versionParts[0] intValue] < 30) {
                    NSString *majorMinor = [NSString stringWithFormat:@"%@.%@", versionParts[0], versionParts[1]];
                    gameVersion = [NSString stringWithFormat:@"1.%@", majorMinor];
                    NSLog(@"[ForgeInstall] NeoForge version: %@ → Minecraft %@", version, gameVersion);
                }
            }
            
            // Also check if the components after the first hyphen contain a MC version
            if (!gameVersion && components.count > 1) {
                for (NSInteger i = 1; i < components.count; i++) {
                    NSString *component = components[i];
                    if ([component hasPrefix:@"1."] && 
                        [component componentsSeparatedByString:@"."].count >= 3) {
                        gameVersion = component;
                        NSLog(@"[ForgeInstall] Found MC version in NeoForge suffix: %@", gameVersion);
                        break;
                    }
                }
            }
        }
        
        // Final fallback
        if (!gameVersion) {
            // Unable to determine Minecraft version clearly
            gameVersion = @"Other";
            NSLog(@"[ForgeInstall] Could not determine MC version for: %@", version);
        }
    } else {
        // Standard Forge format: "1.16.5-36.2.39"
        NSRange range = [version rangeOfString:@"-"];
        gameVersion = [version substringToIndex:range.location];
    }
    
    // Skip if we couldn't determine a game version
    if (!gameVersion || gameVersion.length == 0) {
        return;
    }
    
    // Find or create the appropriate section
    NSUInteger index = [self.versionList indexOfObject:gameVersion];
    if (index == NSNotFound) {
        // Add a new section
        [self.visibilityList addObject:@(NO)];
        [self.versionList addObject:gameVersion];
        [self.forgeList addObject:[NSMutableArray new]];
        index = self.versionList.count - 1;
    }
    
    // Check if this exact version is already in the list (avoid duplicates)
    if (![self.forgeList[index] containsObject:version]) {
        // Add the version to the correct section
        [self.forgeList[index] addObject:version];
    }
}

#pragma mark NSXMLParser

- (void)parserDidEndDocument:(NSXMLParser *)unused {
    dispatch_async(dispatch_get_main_queue(), ^{
        // Sort the version lists for better organization
        UISegmentedControl *segment = (id)self.navigationItem.titleView;
        NSString *vendor = [segment titleForSegmentAtIndex:segment.selectedSegmentIndex];
        
        // Sort MC versions by semantic versioning (newest first)
        [self.versionList sortUsingComparator:^NSComparisonResult(NSString *version1, NSString *version2) {
            // Handle "Other" category - always at the end
            if ([version1 isEqualToString:@"Other"]) return NSOrderedDescending;
            if ([version2 isEqualToString:@"Other"]) return NSOrderedAscending;
            
            // Compare version components
            NSArray *components1 = [version1 componentsSeparatedByString:@"."];
            NSArray *components2 = [version2 componentsSeparatedByString:@"."];
            
            // Compare major version first
            NSInteger major1 = components1.count > 0 ? [components1[0] integerValue] : 0;
            NSInteger major2 = components2.count > 0 ? [components2[0] integerValue] : 0;
            if (major1 != major2) return major2 - major1; // Higher major version first
            
            // Compare minor version next
            NSInteger minor1 = components1.count > 1 ? [components1[1] integerValue] : 0;
            NSInteger minor2 = components2.count > 1 ? [components2[1] integerValue] : 0;
            if (minor1 != minor2) return minor2 - minor1; // Higher minor version first
            
            // Compare patch version last
            NSInteger patch1 = components1.count > 2 ? [components1[2] integerValue] : 0;
            NSInteger patch2 = components2.count > 2 ? [components2[2] integerValue] : 0;
            return patch2 - patch1; // Higher patch version first
        }];
        
        // Reorder forgeList and visibilityList to match the new version order
        NSMutableArray *newForgeList = [NSMutableArray arrayWithCapacity:self.versionList.count];
        NSMutableArray *newVisibilityList = [NSMutableArray arrayWithCapacity:self.versionList.count];
        
        for (NSString *version in self.versionList) {
            NSUInteger oldIndex = [self.versionList indexOfObject:version];
            if (oldIndex < self.forgeList.count) {
                [newForgeList addObject:self.forgeList[oldIndex]];
                [newVisibilityList addObject:self.visibilityList[oldIndex]];
            }
        }
        
        self.forgeList = newForgeList;
        self.visibilityList = newVisibilityList;
        
        // For each section, sort the Forge/NeoForge versions (newest first)
        for (NSUInteger i = 0; i < self.forgeList.count; i++) {
            NSMutableArray *sectionVersions = self.forgeList[i];
            
            // Universal version sorting that works for both Forge and NeoForge
            [sectionVersions sortUsingComparator:^NSComparisonResult(NSString *version1, NSString *version2) {
                // Parse version components from the version strings
                NSArray *versionComponents1 = [self parseVersionComponents:version1];
                NSArray *versionComponents2 = [self parseVersionComponents:version2];
                
                // Compare each component numerically
                NSInteger minLength = MIN(versionComponents1.count, versionComponents2.count);
                for (NSInteger j = 0; j < minLength; j++) {
                    NSInteger num1 = [versionComponents1[j] integerValue];
                    NSInteger num2 = [versionComponents2[j] integerValue];
                    
                    if (num1 != num2) {
                        return num2 - num1; // Higher values first (newer versions)
                    }
                }
                
                // If they match up to this point, longer version is usually newer
                if (versionComponents1.count != versionComponents2.count) {
                    return versionComponents2.count - versionComponents1.count;
                }
                
                // Final fallback - handle any suffix sorting (e.g., beta, alpha)
                NSString *suffix1 = [self extractVersionSuffix:version1];
                NSString *suffix2 = [self extractVersionSuffix:version2];
                
                if (suffix1.length == 0 && suffix2.length > 0) return NSOrderedAscending; // Release before beta/etc
                if (suffix1.length > 0 && suffix2.length == 0) return NSOrderedDescending;
                
                // Both have suffixes or neither has - compare normally
                return [version2 compare:version1];
            }];
        }
        
        // No automatic expansion of any section
        
        [self switchToReadyState];
        [self.tableView reloadData];
    });
}

- (void)parser:(NSXMLParser *)parser didStartElement:(NSString *)elementName namespaceURI:(NSString *)namespaceURI qualifiedName:(NSString *)qualifiedName attributes:(NSDictionary *)attributeDict {
    self.isVersionElement = [elementName isEqualToString:@"version"];
    if (self.isVersionElement) {
        // Clear the buffer at the start of a version element
        [self.currentVersionValue setString:@""];
    }
}

- (void)parser:(NSXMLParser *)parser foundCharacters:(NSString *)string {
    if (self.isVersionElement) {
        // Append to buffer instead of processing immediately
        [self.currentVersionValue appendString:string];
    }
}

- (void)parser:(NSXMLParser *)parser didEndElement:(NSString *)elementName namespaceURI:(NSString *)namespaceURI qualifiedName:(NSString *)qName {
    if ([elementName isEqualToString:@"version"]) {
        // Process the complete version string when the element ends
        NSString *versionString = [self.currentVersionValue stringByTrimmingCharactersInSet:[NSCharacterSet whitespaceAndNewlineCharacterSet]];
        if (versionString.length > 0) {
            [self addVersionToList:versionString];
        }
        self.isVersionElement = NO;
    }
}

@end

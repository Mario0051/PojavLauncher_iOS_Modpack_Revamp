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
@property(nonatomic, strong) NSString *currentVendor;
@end

@implementation ForgeInstallViewController

#pragma mark - Lifecycle Methods

- (void)viewDidLoad {
    [super viewDidLoad];
    
    // Setup segmented control for vendor selection
    UISegmentedControl *segment = [[UISegmentedControl alloc] initWithItems:@[@"Forge", @"NeoForge"]];
    segment.selectedSegmentIndex = 0;
    [segment addTarget:self action:@selector(segmentChanged:) forControlEvents:UIControlEventValueChanged];
    self.navigationItem.titleView = segment;
    self.currentVendor = @"Forge";

    // Load WorkflowProgressView for download progress
    dlopen("/System/Library/PrivateFrameworks/WorkflowUIServices.framework/WorkflowUIServices", RTLD_GLOBAL);
    self.progressView = [[NSClassFromString(@"WFWorkflowProgressView") alloc] initWithFrame:CGRectMake(0, 0, 30, 30)];
    self.progressView.resolvedTintColor = self.view.tintColor;
    [self.progressView addTarget:self action:@selector(actionCancelDownload) forControlEvents:UIControlEventTouchUpInside];

    // Configure endpoints for both Forge and NeoForge
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
    
    // Initialize data structures
    self.visibilityList = [NSMutableArray new];
    self.versionList = [NSMutableArray new];
    self.forgeList = [NSMutableArray new];
    self.currentVersionValue = [NSMutableString new];
    
    // Load initial data
    [self loadMetadataFromVendor:@"Forge"];
}

#pragma mark - Action Methods

- (void)actionCancelDownload {
    [self.afManager invalidateSessionCancelingTasks:YES resetSession:NO];
}

- (void)actionClose {
    [self.navigationController dismissViewControllerAnimated:YES completion:nil];
}

- (void)segmentChanged:(UISegmentedControl *)segment {
    // Clear existing data
    [self.visibilityList removeAllObjects];
    [self.versionList removeAllObjects];
    [self.forgeList removeAllObjects];
    [self.tableView reloadData];
    
    // Get selected vendor and load data
    NSString *vendor = [segment titleForSegmentAtIndex:segment.selectedSegmentIndex];
    self.currentVendor = vendor;
    [self loadMetadataFromVendor:vendor];
}

#pragma mark - Data Loading

- (void)loadMetadataFromVendor:(NSString *)vendor {
    [self switchToLoadingState];
    
    dispatch_async(dispatch_get_global_queue(DISPATCH_QUEUE_PRIORITY_DEFAULT, 0), ^{
        NSURL *url = [[NSURL alloc] initWithString:self.endpoints[vendor][@"metadata"]];
        NSXMLParser *parser = [[NSXMLParser alloc] initWithContentsOfURL:url];
        parser.delegate = self;
        
        // Initialize version value buffer
        self.currentVersionValue = [NSMutableString new];
        
        if (![parser parse]) {
            dispatch_async(dispatch_get_main_queue(), ^{
                showDialog(localize(@"Error", nil), parser.parserError.localizedDescription);
                [self actionClose];
            });
        }
    });
}

#pragma mark - UI State Management

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

#pragma mark - Version Parsing and Management

- (NSString *)extractMinecraftVersionFromForgeVersion:(NSString *)version {
    // For Forge, we want to use a simpler approach similar to the older implementation
    // First check for a valid format like "1.X.Y-forgeVersion" or "1.X-forgeVersion"
    NSRange hyphenRange = [version rangeOfString:@"-"];
    if (hyphenRange.location != NSNotFound) {
        NSString *mcPortion = [version substringToIndex:hyphenRange.location];
        
        // Simple validation for Minecraft version format (1.X or 1.X.Y)
        NSRegularExpression *mcRegex = [NSRegularExpression 
            regularExpressionWithPattern:@"^1\\.[0-9]+(\\.[0-9]+)?$" 
            options:0 error:nil];
            
        NSRange fullRange = NSMakeRange(0, mcPortion.length);
        if ([mcRegex firstMatchInString:mcPortion options:0 range:fullRange]) {
            return mcPortion;
        }
    }
    
    return @"Unknown";
}

- (NSString *)extractMinecraftVersionFromNeoForgeVersion:(NSString *)version {
    // NeoForge versioning scheme:
    // Format: [Minecraft version without 1.].[NeoForge version][-beta/alpha]
    // Example: "21.4.114-beta" for Minecraft 1.21.4
    
    // First remove any beta/alpha/etc. suffix
    NSString *cleanVersion = version;
    NSRange hyphenRange = [version rangeOfString:@"-"];
    if (hyphenRange.location != NSNotFound) {
        cleanVersion = [version substringToIndex:hyphenRange.location];
    }
    
    // Extract the first part (Minecraft version without the leading "1.")
    NSArray *components = [cleanVersion componentsSeparatedByString:@"."];
    if (components.count >= 2) {
        // Take first two components which represent Minecraft version (without the 1.)
        NSString *majorComponent = components[0];
        NSString *minorComponent = components[1];
        
        // Validate components are numeric
        if ([self isNumeric:majorComponent] && [self isNumeric:minorComponent]) {
            // Reconstruct as 1.x.y
            NSString *mcVersion = [NSString stringWithFormat:@"1.%@.%@", majorComponent, minorComponent];
            return mcVersion;
        }
    }
    
    // Fallback: Look for version pattern that might indicate Minecraft version
    NSRegularExpression *versionRegex = [NSRegularExpression 
        regularExpressionWithPattern:@"(\\d+\\.\\d+)" 
        options:0 error:nil];
    
    NSTextCheckingResult *match = [versionRegex firstMatchInString:version options:0 range:NSMakeRange(0, version.length)];
    if (match) {
        NSString *extractedPart = [version substringWithRange:match.range];
        return [NSString stringWithFormat:@"1.%@", extractedPart];
    }
    
    return @"Unknown";
}

- (NSString *)getDisplayName:(NSString *)version {
    if ([self.currentVendor isEqualToString:@"NeoForge"]) {
        // For NeoForge, we need a clear display format that shows both version components
        NSString *mcVersion = [self extractMinecraftVersionFromNeoForgeVersion:version];
        
        // Format: "NeoForge [Version] (Minecraft [mcVersion])"
        if (![mcVersion isEqualToString:@"Unknown"]) {
            return [NSString stringWithFormat:@"NeoForge %@ (Minecraft %@)", 
                    version, mcVersion];
        } else {
            return [NSString stringWithFormat:@"NeoForge %@", version];
        }
    } else {
        // For Forge, extract the forge version part after the hyphen
        NSString *mcVersion = [self extractMinecraftVersionFromForgeVersion:version];
        NSRange hyphenRange = [version rangeOfString:@"-"];
        
        if (hyphenRange.location != NSNotFound && ![mcVersion isEqualToString:@"Unknown"]) {
            NSString *forgeVersion = [version substringFromIndex:hyphenRange.location + 1];
            return [NSString stringWithFormat:@"Forge %@ (Minecraft %@)", forgeVersion, mcVersion];
        } else {
            return version;
        }
    }
}

- (BOOL)isNumeric:(NSString *)string {
    if (!string || string.length == 0) return NO;
    
    NSCharacterSet *nonNumbers = [[NSCharacterSet decimalDigitCharacterSet] invertedSet];
    return [string rangeOfCharacterFromSet:nonNumbers].location == NSNotFound;
}

- (void)addVersionToList:(NSString *)version {
    // Skip invalid versions
    if (version.length == 0) {
        return;
    }
    
    // Handle Forge and NeoForge differently
    if ([self.currentVendor isEqualToString:@"NeoForge"]) {
        // Skip NeoForge versions with problematic patterns
        NSArray *skipPatterns = @[
            @"sources", @"userdev", @"javadoc", @"universal", @"slim", 
            @"-javadoc", @"-sources", @"-all", @"-changelog", 
            @"-installer-win", @"-mdk"
        ];
        
        for (NSString *pattern in skipPatterns) {
            if ([version containsString:pattern]) {
                NSLog(@"[ForgeInstall] Skipping problematic NeoForge version: %@", version);
                return;
            }
        }
        
        // Extract NeoForge minecraft version
        NSString *minecraftVersion = [self extractMinecraftVersionFromNeoForgeVersion:version];
        
        // Skip versions with unknown Minecraft version
        if ([minecraftVersion isEqualToString:@"Unknown"]) {
            NSLog(@"[ForgeInstall] Skipping NeoForge version with unknown MC version: %@", version);
            return;
        }
        
        // Add to section - do exact string matching for section headers
        NSUInteger sectionIndex = NSNotFound;
        for (NSUInteger i = 0; i < self.versionList.count; i++) {
            if ([self.versionList[i] isEqualToString:minecraftVersion]) {
                sectionIndex = i;
                break;
            }
        }
        
        if (sectionIndex == NSNotFound) {
            [self.versionList addObject:minecraftVersion];
            [self.visibilityList addObject:@NO]; // Start collapsed
            [self.forgeList addObject:[NSMutableArray new]];
            sectionIndex = self.versionList.count - 1;
        }
        
        // Add version to this section if not already present
        if (![self.forgeList[sectionIndex] containsObject:version]) {
            [self.forgeList[sectionIndex] addObject:version];
            NSLog(@"[ForgeInstall] Added NeoForge %@ to %@ section", version, minecraftVersion);
        }
    } else {
        // FORGE SPECIFIC HANDLING - SIMPLIFIED VERSION
        // Skip versions without a hyphen (need mcVersion-forgeVersion format)
        if (![version containsString:@"-"]) {
            NSLog(@"[ForgeInstall] Skipping invalid Forge version format: %@", version);
            return;
        }
        
        // Skip Forge versions with these known problematic patterns
        NSArray *skipPatterns = @[
            @"mdk", @"userdev", @"javadoc", @"src", @"sources", @"universal",
            @"-all", @"-changelog", @"-client", @"-server", @"-launcher"
        ];
        
        for (NSString *pattern in skipPatterns) {
            if ([version containsString:pattern]) {
                NSLog(@"[ForgeInstall] Skipping problematic Forge version: %@", version);
                return;
            }
        }
        
        // Simply get minecraft version - part before the hyphen
        NSRange hyphenRange = [version rangeOfString:@"-"];
        NSString *minecraftVersion = [version substringToIndex:hyphenRange.location];
        
        // Add to section - do exact string matching for section headers
        NSUInteger sectionIndex = NSNotFound;
        for (NSUInteger i = 0; i < self.versionList.count; i++) {
            if ([self.versionList[i] isEqualToString:minecraftVersion]) {
                sectionIndex = i;
                break;
            }
        }
        
        if (sectionIndex == NSNotFound) {
            [self.versionList addObject:minecraftVersion];
            [self.visibilityList addObject:@NO]; // Start collapsed
            [self.forgeList addObject:[NSMutableArray new]];
            sectionIndex = self.versionList.count - 1;
        }
        
        // Add version to this section if not already present
        if (![self.forgeList[sectionIndex] containsObject:version]) {
            [self.forgeList[sectionIndex] addObject:version];
            NSLog(@"[ForgeInstall] Added Forge %@ to %@ section", version, minecraftVersion);
        }
    }
}

#pragma mark - UITableViewDataSource

- (NSInteger)numberOfSectionsInTableView:(UITableView *)tableView {
    return self.versionList.count;
}

- (UIView *)tableView:(UITableView *)tableView viewForHeaderInSection:(NSInteger)section {
    UITableViewHeaderFooterView *view = [self.tableView dequeueReusableHeaderFooterViewWithIdentifier:@"section"];
    if (!view) {
        view = [[UITableViewHeaderFooterView alloc] initWithReuseIdentifier:@"section"];
        view.textLabel.font = [UIFont boldSystemFontOfSize:16];
        
        UITapGestureRecognizer *tapGesture = [[UITapGestureRecognizer alloc] initWithTarget:self action:@selector(tableViewDidSelectSection:)];
        [view addGestureRecognizer:tapGesture];
        
        // Add a disclosure indicator
        UIImageView *disclosureIndicator = [[UIImageView alloc] initWithImage:[UIImage systemImageNamed:@"chevron.right"]];
        disclosureIndicator.tag = 1001;
        disclosureIndicator.tintColor = [UIColor systemGrayColor];
        [view.contentView addSubview:disclosureIndicator];
        
        // Add constraints for the disclosure indicator
        disclosureIndicator.translatesAutoresizingMaskIntoConstraints = NO;
        [NSLayoutConstraint activateConstraints:@[
            [disclosureIndicator.trailingAnchor constraintEqualToAnchor:view.contentView.trailingAnchor constant:-16],
            [disclosureIndicator.centerYAnchor constraintEqualToAnchor:view.contentView.centerYAnchor]
        ]];
    }
    
    // Update disclosure indicator rotation based on section state
    UIImageView *indicator = [view viewWithTag:1001];
    indicator.transform = self.visibilityList[section].boolValue ? 
        CGAffineTransformMakeRotation(M_PI_2) : CGAffineTransformIdentity;
    
    return view;
}

- (NSString *)tableView:(UITableView *)tableView titleForHeaderInSection:(NSInteger)section {
    NSString *mcVersion = self.versionList[section];
    
    // Enhance the section title for better readability
    if ([mcVersion hasPrefix:@"1."]) {
        return [NSString stringWithFormat:@"Minecraft %@", mcVersion];
    } else {
        return mcVersion;
    }
}

- (void)tableViewDidSelectSection:(UITapGestureRecognizer *)sender {
    UITableViewHeaderFooterView *view = (id)sender.view;
    NSString *sectionTitle = view.textLabel.text;
    
    // Extract the actual Minecraft version from the enhanced section title
    NSString *mcVersion = sectionTitle;
    if ([sectionTitle hasPrefix:@"Minecraft "]) {
        mcVersion = [sectionTitle substringFromIndex:10]; // Remove "Minecraft " prefix
    }
    
    // Find the section by doing exact match on the version string
    NSInteger section = NSNotFound;
    for (NSInteger i = 0; i < self.versionList.count; i++) {
        if ([self.versionList[i] isEqualToString:mcVersion]) {
            section = i;
            break;
        }
    }
    
    if (section != NSNotFound) {
        // Toggle section visibility
        self.visibilityList[section] = @(!self.visibilityList[section].boolValue);
        
        // Animate the disclosure indicator
        UIImageView *indicator = [view viewWithTag:1001];
        [UIView animateWithDuration:0.3 animations:^{
            indicator.transform = self.visibilityList[section].boolValue ? 
                CGAffineTransformMakeRotation(M_PI_2) : CGAffineTransformIdentity;
        }];
        
        [self.tableView reloadSections:[NSIndexSet indexSetWithIndex:section] withRowAnimation:UITableViewRowAnimationAutomatic];
    }
}

- (NSInteger)tableView:(UITableView *)tableView numberOfRowsInSection:(NSInteger)section {
    return self.visibilityList[section].boolValue ? self.forgeList[section].count : 0;
}

- (UITableViewCell *)tableView:(UITableView *)tableView cellForRowAtIndexPath:(NSIndexPath *)indexPath {
    UITableViewCell *cell = [tableView dequeueReusableCellWithIdentifier:@"cell"];
    if (!cell) {
        cell = [[UITableViewCell alloc] initWithStyle:UITableViewCellStyleSubtitle reuseIdentifier:@"cell"];
        cell.accessoryType = UITableViewCellAccessoryDisclosureIndicator;
    }

    NSString *version = self.forgeList[indexPath.section][indexPath.row];
    cell.textLabel.text = [self getDisplayName:version];
    
    // Add release type info as subtitle
    if ([version containsString:@"beta"] || [version containsString:@"-beta"]) {
        cell.detailTextLabel.text = @"Beta version";
        cell.detailTextLabel.textColor = [UIColor systemOrangeColor];
    } else if ([version containsString:@"alpha"] || [version containsString:@"-alpha"]) {
        cell.detailTextLabel.text = @"Alpha version";
        cell.detailTextLabel.textColor = [UIColor systemRedColor];
    } else if ([version containsString:@"recommended"]) {
        cell.detailTextLabel.text = @"Recommended version";
        cell.detailTextLabel.textColor = [UIColor systemGreenColor];
    } else {
        cell.detailTextLabel.text = @"Release version";
        cell.detailTextLabel.textColor = [UIColor systemGrayColor];
    }
    
    return cell;
}

#pragma mark - UITableViewDelegate

- (void)tableView:(UITableView *)tableView didSelectRowAtIndexPath:(NSIndexPath *)indexPath {
    [tableView deselectRowAtIndexPath:indexPath animated:YES];
    tableView.allowsSelection = NO;

    [self switchToLoadingState];
    self.progressView.fractionCompleted = 0;

    UITableViewCell *cell = [tableView cellForRowAtIndexPath:indexPath];
    cell.accessoryView = self.progressView;

    // Get the raw version string (not the display name)
    NSString *versionString = self.forgeList[indexPath.section][indexPath.row];
    NSString *jarURL = [NSString stringWithFormat:self.endpoints[self.currentVendor][@"installer"], versionString];
    NSString *outPath = [NSTemporaryDirectory() stringByAppendingPathComponent:@"tmp.jar"];
    NSLog(@"[%@ Installer] Downloading %@", self.currentVendor, jarURL);

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
                    NSLog(@"Error: %@", error);
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

#pragma mark - NSXMLParserDelegate

- (void)parserDidEndDocument:(NSXMLParser *)parser {
    dispatch_async(dispatch_get_main_queue(), ^{
        // Log all version sections for debugging
        NSLog(@"[ForgeInstall] Before sorting, version sections: %@", self.versionList);
        for (NSInteger i = 0; i < self.versionList.count; i++) {
            NSLog(@"[ForgeInstall] Section %@ has %lu versions", 
                  self.versionList[i], (unsigned long)self.forgeList[i].count);
        }
        
        // Sort Minecraft versions (sections) with newest first
        [self sortVersionSections];
        
        // Sort versions within each section with newest first
        [self sortVersionsWithinSections];
        
        // Log all version sections after sorting for debugging
        NSLog(@"[ForgeInstall] After sorting, version sections: %@", self.versionList);
        for (NSInteger i = 0; i < self.versionList.count; i++) {
            NSLog(@"[ForgeInstall] Section %@ has %lu versions", 
                  self.versionList[i], (unsigned long)self.forgeList[i].count);
        }
        
        // Expand the first (newest) section by default
        if (self.versionList.count > 0) {
            self.visibilityList[0] = @YES;
        }
        
        [self switchToReadyState];
        [self.tableView reloadData];
    });
}

- (void)parser:(NSXMLParser *)parser didStartElement:(NSString *)elementName namespaceURI:(NSString *)namespaceURI qualifiedName:(NSString *)qualifiedName attributes:(NSDictionary *)attributeDict {
    self.isVersionElement = [elementName isEqualToString:@"version"];
    if (self.isVersionElement) {
        [self.currentVersionValue setString:@""];
    }
}

- (void)parser:(NSXMLParser *)parser foundCharacters:(NSString *)string {
    if (self.isVersionElement) {
        [self.currentVersionValue appendString:string];
    }
}

- (void)parser:(NSXMLParser *)parser didEndElement:(NSString *)elementName namespaceURI:(NSString *)namespaceURI qualifiedName:(NSString *)qName {
    if ([elementName isEqualToString:@"version"]) {
        NSString *versionString = [self.currentVersionValue stringByTrimmingCharactersInSet:[NSCharacterSet whitespaceAndNewlineCharacterSet]];
        if (versionString.length > 0) {
            [self addVersionToList:versionString];
        }
        self.isVersionElement = NO;
    }
}

#pragma mark - Sorting Methods

- (void)sortVersionSections {
    // Create maps to maintain the relationship between versions and their data
    NSMutableDictionary *versionToForgeList = [NSMutableDictionary new];
    NSMutableDictionary *versionToVisibility = [NSMutableDictionary new];
    
    // Store the current data in the dictionaries
    for (NSInteger i = 0; i < self.versionList.count; i++) {
        NSString *version = self.versionList[i];
        versionToForgeList[version] = self.forgeList[i];
        versionToVisibility[version] = self.visibilityList[i];
    }
    
    // Sort the version list
    NSArray *sortedVersions = [self.versionList sortedArrayUsingComparator:^NSComparisonResult(NSString *version1, NSString *version2) {
        // Handle special categories
        if ([version1 isEqualToString:@"Unknown"]) return NSOrderedDescending;
        if ([version2 isEqualToString:@"Unknown"]) return NSOrderedAscending;
        
        return [self compareMinecraftVersions:version2 to:version1]; // Reversed for newest first
    }];
    
    // Clear and refill the arrays in the sorted order
    [self.versionList removeAllObjects];
    [self.forgeList removeAllObjects];
    [self.visibilityList removeAllObjects];
    
    for (NSString *version in sortedVersions) {
        [self.versionList addObject:version];
        [self.forgeList addObject:versionToForgeList[version]];
        [self.visibilityList addObject:versionToVisibility[version]];
    }
    
    // Debug log to verify correct sorting
    NSLog(@"[ForgeInstall] Sorted sections: %@", self.versionList);
}

- (void)sortVersionsWithinSections {
    // Sort versions within each section with newest first
    for (NSUInteger i = 0; i < self.forgeList.count; i++) {
        NSMutableArray *sectionVersions = self.forgeList[i];
        
        [sectionVersions sortUsingComparator:^NSComparisonResult(NSString *version1, NSString *version2) {
            // For Forge versions, compare version numbers
            if ([self.currentVendor isEqualToString:@"Forge"]) {
                // Extract forge version numbers
                NSRange hyphen1 = [version1 rangeOfString:@"-"];
                NSRange hyphen2 = [version2 rangeOfString:@"-"];
                
                if (hyphen1.location != NSNotFound && hyphen2.location != NSNotFound) {
                    NSString *forgeVersion1 = [version1 substringFromIndex:hyphen1.location + 1];
                    NSString *forgeVersion2 = [version2 substringFromIndex:hyphen2.location + 1];
                    
                    // Compare by recommended/latest first, then release type, then version number
                    BOOL isRecommended1 = [forgeVersion1 containsString:@"recommended"];
                    BOOL isRecommended2 = [forgeVersion2 containsString:@"recommended"];
                    
                    if (isRecommended1 && !isRecommended2) return NSOrderedAscending;
                    if (!isRecommended1 && isRecommended2) return NSOrderedDescending;
                    
                    // Check for beta/alpha
                    BOOL isBeta1 = [forgeVersion1 containsString:@"beta"];
                    BOOL isBeta2 = [forgeVersion2 containsString:@"beta"];
                    BOOL isAlpha1 = [forgeVersion1 containsString:@"alpha"];
                    BOOL isAlpha2 = [forgeVersion2 containsString:@"alpha"];
                    
                    // Stable releases first
                    if (!isBeta1 && !isAlpha1 && (isBeta2 || isAlpha2)) return NSOrderedAscending;
                    if ((isBeta1 || isAlpha1) && !isBeta2 && !isAlpha2) return NSOrderedDescending;
                    
                    // Beta comes before alpha
                    if (isBeta1 && isAlpha2) return NSOrderedAscending;
                    if (isAlpha1 && isBeta2) return NSOrderedDescending;
                    
                    // Now compare version numbers - extract numbers and compare
                    NSArray *components1 = [forgeVersion1 componentsSeparatedByString:@"."];
                    NSArray *components2 = [forgeVersion2 componentsSeparatedByString:@"."];
                    
                    NSInteger minCount = MIN(components1.count, components2.count);
                    
                    for (NSInteger j = 0; j < minCount; j++) {
                        NSString *comp1 = components1[j];
                        NSString *comp2 = components2[j];
                        
                        // Extract just the numeric part if there's text
                        NSScanner *scanner1 = [NSScanner scannerWithString:comp1];
                        NSInteger num1 = 0;
                        [scanner1 scanInteger:&num1];
                        
                        NSScanner *scanner2 = [NSScanner scannerWithString:comp2];
                        NSInteger num2 = 0;
                        [scanner2 scanInteger:&num2];
                        
                        if (num1 != num2) {
                            return (num1 > num2) ? NSOrderedAscending : NSOrderedDescending;
                        }
                    }
                    
                    // If equal to this point, more components usually means newer
                    if (components1.count != components2.count) {
                        return (components1.count > components2.count) ? NSOrderedAscending : NSOrderedDescending;
                    }
                }
            }
            
            // Default sorting - newer versions typically have higher version numbers
            return [version2 compare:version1]; // Reversed for descending order
        }];
    }
}

- (NSComparisonResult)compareMinecraftVersions:(NSString *)version1 to:(NSString *)version2 {
    // Handle exact string equality case first
    if ([version1 isEqualToString:version2]) {
        return NSOrderedSame;
    }
    
    // Split versions into components
    NSArray *components1 = [version1 componentsSeparatedByString:@"."];
    NSArray *components2 = [version2 componentsSeparatedByString:@"."];
    
    // Compare each component numerically
    NSInteger minComponents = MIN(components1.count, components2.count);
    for (NSInteger i = 0; i < minComponents; i++) {
        NSInteger num1 = [components1[i] integerValue];
        NSInteger num2 = [components2[i] integerValue];
        
        if (num1 != num2) {
            return num1 > num2 ? NSOrderedDescending : NSOrderedAscending;
        }
    }
    
    // If all components so far are equal, the version with MORE components is newer
    // (e.g., 1.21.4 is newer than 1.21)
    if (components1.count != components2.count) {
        return components1.count > components2.count ? NSOrderedDescending : NSOrderedAscending;
    }
    
    // If we get here, then the versions have same numeric value but possibly different string representation
    // In this case, preserve string comparison to ensure uniqueness and predictable sorting
    return [version1 compare:version2];
}

@end

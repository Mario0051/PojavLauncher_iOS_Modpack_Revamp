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
    if (![version containsString:@"-"]) {
        return @"Other";
    }
    
    NSRange hyphenRange = [version rangeOfString:@"-"];
    return [version substringToIndex:hyphenRange.location];
}

- (NSString *)extractMinecraftVersionFromNeoForgeVersion:(NSString *)version {
    // Get the part before any hyphen first
    NSString *versionBase = version;
    NSRange hyphenRange = [version rangeOfString:@"-"];
    if (hyphenRange.location != NSNotFound) {
        versionBase = [version substringToIndex:hyphenRange.location];
    }
    
    // Split into components
    NSArray *components = [versionBase componentsSeparatedByString:@"."];
    
    // NeoForge usually has format XX.Y.ZZ where XX.Y corresponds to 1.XX.Y in Minecraft
    if (components.count >= 2) {
        NSString *major = components[0];
        NSString *minor = components[1];
        
        // Validate these are numbers
        if ([self isNumeric:major] && [self isNumeric:minor]) {
            // Check if it's likely a Minecraft version (major version < 30)
            if ([major intValue] < 30) {
                return [NSString stringWithFormat:@"1.%@.%@", major, minor];
            }
        }
    }
    
    // Fallback: Also check if the full version contains a standard Minecraft version format
    NSRegularExpression *regex = [NSRegularExpression regularExpressionWithPattern:@"1\\.[0-9]+\\.[0-9]+" options:0 error:nil];
    NSTextCheckingResult *match = [regex firstMatchInString:version options:0 range:NSMakeRange(0, version.length)];
    
    if (match) {
        return [version substringWithRange:match.range];
    }
    
    // Last resort
    return @"Other";
}

- (BOOL)isNumeric:(NSString *)string {
    NSScanner *scanner = [NSScanner scannerWithString:string];
    return [scanner scanInteger:NULL] && [scanner isAtEnd];
}

- (NSArray *)extractVersionComponents:(NSString *)version {
    if ([self.currentVendor isEqualToString:@"NeoForge"]) {
        // For NeoForge, get the build number parts (before any hyphen)
        NSString *versionBase = version;
        NSRange hyphenRange = [version rangeOfString:@"-"];
        if (hyphenRange.location != NSNotFound) {
            versionBase = [version substringToIndex:hyphenRange.location];
        }
        
        return [versionBase componentsSeparatedByString:@"."];
    } else {
        // For Forge, get everything after the hyphen: "1.16.5-36.2.39" → "36.2.39"
        NSRange hyphenRange = [version rangeOfString:@"-"];
        if (hyphenRange.location != NSNotFound && hyphenRange.location < version.length - 1) {
            NSString *forgeVersion = [version substringFromIndex:hyphenRange.location + 1];
            return [forgeVersion componentsSeparatedByString:@"."];
        }
        return @[];
    }
}

- (NSString *)extractSuffix:(NSString *)version {
    NSRange hyphenRange = [version rangeOfString:@"-"];
    if (hyphenRange.location != NSNotFound && hyphenRange.location < version.length - 1) {
        return [version substringFromIndex:hyphenRange.location + 1];
    }
    return @"";
}

- (void)addVersionToList:(NSString *)version {
    // Skip invalid versions
    if (version.length == 0) {
        return;
    }
    
    // Extract minecraft version based on vendor
    NSString *minecraftVersion;
    
    if ([self.currentVendor isEqualToString:@"NeoForge"]) {
        minecraftVersion = [self extractMinecraftVersionFromNeoForgeVersion:version];
    } else {
        // For standard Forge
        if (![version containsString:@"-"]) {
            return; // Skip if not in expected format
        }
        minecraftVersion = [self extractMinecraftVersionFromForgeVersion:version];
    }
    
    // If we couldn't determine a version, skip
    if (!minecraftVersion || minecraftVersion.length == 0) {
        return;
    }
    
    // Find or create section for this Minecraft version
    NSUInteger sectionIndex = [self.versionList indexOfObject:minecraftVersion];
    if (sectionIndex == NSNotFound) {
        [self.versionList addObject:minecraftVersion];
        [self.visibilityList addObject:@NO]; // Start collapsed
        [self.forgeList addObject:[NSMutableArray new]];
        sectionIndex = self.versionList.count - 1;
    }
    
    // Add version to this section if not already present
    if (![self.forgeList[sectionIndex] containsObject:version]) {
        [self.forgeList[sectionIndex] addObject:version];
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
    NSInteger section = [self.versionList indexOfObject:view.textLabel.text];
    if (section != NSNotFound) {
        self.visibilityList[section] = @(!self.visibilityList[section].boolValue);
        [self.tableView reloadSections:[NSIndexSet indexSetWithIndex:section] withRowAnimation:UITableViewRowAnimationAutomatic];
    }
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

#pragma mark - UITableViewDelegate

- (void)tableView:(UITableView *)tableView didSelectRowAtIndexPath:(NSIndexPath *)indexPath {
    [tableView deselectRowAtIndexPath:indexPath animated:NO];
    tableView.allowsSelection = NO;

    [self switchToLoadingState];
    self.progressView.fractionCompleted = 0;

    UITableViewCell *cell = [tableView cellForRowAtIndexPath:indexPath];
    cell.accessoryView = self.progressView;

    NSString *jarURL = [NSString stringWithFormat:self.endpoints[self.currentVendor][@"installer"], cell.textLabel.text];
    NSString *outPath = [NSTemporaryDirectory() stringByAppendingPathComponent:@"tmp.jar"];
    NSDebugLog(@"[%@ Installer] Downloading %@", self.currentVendor, jarURL);

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

#pragma mark - NSXMLParserDelegate

- (void)parserDidEndDocument:(NSXMLParser *)parser {
    dispatch_async(dispatch_get_main_queue(), ^{
        // Sort Minecraft versions (sections) with newest first
        [self sortVersionSections];
        
        // Sort versions within each section with newest first
        [self sortVersionsWithinSections];
        
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
    // Sort Minecraft versions with newest first
    [self.versionList sortUsingComparator:^NSComparisonResult(NSString *version1, NSString *version2) {
        // Handle "Other" category
        if ([version1 isEqualToString:@"Other"]) return NSOrderedDescending;
        if ([version2 isEqualToString:@"Other"]) return NSOrderedAscending;
        
        return [self compareVersions:version2 to:version1]; // Reverse order for newest first
    }];
    
    // Reorder section arrays to match sorted version list
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
}

- (void)sortVersionsWithinSections {
    // Sort versions within each section with newest first
    for (NSUInteger i = 0; i < self.forgeList.count; i++) {
        NSMutableArray *sectionVersions = self.forgeList[i];
        
        [sectionVersions sortUsingComparator:^NSComparisonResult(NSString *version1, NSString *version2) {
            NSArray *components1 = [self extractVersionComponents:version1];
            NSArray *components2 = [self extractVersionComponents:version2];
            
            // Compare each component
            NSInteger minComponents = MIN(components1.count, components2.count);
            for (NSInteger j = 0; j < minComponents; j++) {
                NSInteger num1 = [components1[j] integerValue];
                NSInteger num2 = [components2[j] integerValue];
                
                if (num1 != num2) {
                    return num2 - num1; // Higher numbers first
                }
            }
            
            // If equal up to now, longer version is usually newer
            if (components1.count != components2.count) {
                return components2.count - components1.count;
            }
            
            // Fallback to suffix comparison (release vs beta/alpha)
            NSString *suffix1 = [self extractSuffix:version1];
            NSString *suffix2 = [self extractSuffix:version2];
            
            // Release versions (no suffix) come before pre-release versions
            BOOL isRelease1 = [self isReleaseVersion:suffix1];
            BOOL isRelease2 = [self isReleaseVersion:suffix2];
            
            if (isRelease1 && !isRelease2) return NSOrderedAscending;
            if (!isRelease1 && isRelease2) return NSOrderedDescending;
            
            // Both release or both pre-release, compare normally
            return [version2 compare:version1];
        }];
    }
}

- (BOOL)isReleaseVersion:(NSString *)suffix {
    // Check if this is a release version (no suffix or a stable suffix)
    if (suffix.length == 0) return YES;
    
    NSArray *preReleaseKeywords = @[@"alpha", @"beta", @"rc", @"pre", @"snapshot"];
    NSString *lowerSuffix = [suffix lowercaseString];
    
    for (NSString *keyword in preReleaseKeywords) {
        if ([lowerSuffix containsString:keyword]) {
            return NO;
        }
    }
    
    return YES;
}

- (NSComparisonResult)compareVersions:(NSString *)version1 to:(NSString *)version2 {
    // Split versions into components
    NSArray *components1 = [version1 componentsSeparatedByString:@"."];
    NSArray *components2 = [version2 componentsSeparatedByString:@"."];
    
    // Compare each component numerically
    NSInteger minComponents = MIN(components1.count, components2.count);
    for (NSInteger i = 0; i < minComponents; i++) {
        NSInteger num1 = [components1[i] integerValue];
        NSInteger num2 = [components2[i] integerValue];
        
        if (num1 != num2) {
            return num1 > num2 ? NSOrderedAscending : NSOrderedDescending;
        }
    }
    
    // If equal so far, more components usually means newer
    if (components1.count != components2.count) {
        return components1.count > components2.count ? NSOrderedAscending : NSOrderedDescending;
    }
    
    // Exactly equal
    return NSOrderedSame;
}

@end

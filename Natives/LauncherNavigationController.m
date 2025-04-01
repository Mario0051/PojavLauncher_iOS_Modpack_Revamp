#import <UniformTypeIdentifiers/UniformTypeIdentifiers.h>
#import <objc/runtime.h>
#import "authenticator/BaseAuthenticator.h"
#import "AFNetworking.h"
#import "ALTServerConnection.h"
#import "CustomControlsViewController.h"
#import "DownloadProgressViewController.h"
#import "JavaGUIViewController.h"
#import "LauncherMenuViewController.h"
#import "LauncherNewsViewController.h"
#import "LauncherNavigationController.h"
#import "LauncherPreferences.h"
#import "MinecraftResourceDownloadTask.h"
#import "MinecraftResourceUtils.h"
#import "PickTextField.h"
#import "PLPickerView.h"
#import "PLProfiles.h"
#import "UIKit+AFNetworking.h"
#import "UIKit+hook.h"
#import "ios_uikit_bridge.h"
#import "utils.h"

#include <sys/time.h>

#define AUTORESIZE_MASKS UIViewAutoresizingFlexibleWidth | UIViewAutoresizingFlexibleLeftMargin | UIViewAutoresizingFlexibleRightMargin
#define VERSION_LIST_REFRESH_INTERVAL 300 // Refresh lists if older than 5 minutes

static void *ProgressObserverContext = &ProgressObserverContext;

// Lock for thread-safe access to version lists
static NSLock *versionListLock;
static NSDate *lastLocalVersionRefresh;
static NSDate *lastRemoteVersionRefresh;

@interface LauncherNavigationController () <UIDocumentPickerDelegate, UIPickerViewDataSource, PLPickerViewDelegate, UIPopoverPresentationControllerDelegate>

@property(nonatomic, strong) MinecraftResourceDownloadTask* task;
@property(nonatomic, strong) DownloadProgressViewController* progressVC;
@property(nonatomic, strong) PLPickerView* versionPickerView;
@property(nonatomic, strong) UITextField* versionTextField;
@property(nonatomic, assign) int profileSelectedAt;
@property(nonatomic, strong) NSTimer *progressUpdateTimer;

@end

@implementation LauncherNavigationController

#pragma mark - View Lifecycle

- (void)viewDidLoad {
    [super viewDidLoad];
    
    // Initialize or ensure lock for thread-safe access to version lists
    if (!versionListLock) {
        versionListLock = [[NSLock alloc] init];
    }
    
    if ([self respondsToSelector:@selector(setNeedsUpdateOfScreenEdgesDeferringSystemGestures)]) {
        [self setNeedsUpdateOfScreenEdgesDeferringSystemGestures];
    }
    
    // Setup version field with picker
    [self setupVersionSelectionUI];
    
    // Setup progress UI elements
    [self setupProgressUI];
    
    // Load version lists
    [self fetchLocalVersionList];
    [self fetchRemoteVersionList];
    
    // Register for notifications
    [NSNotificationCenter.defaultCenter addObserver:self
                                          selector:@selector(receiveNotification:)
                                              name:@"InstallModpack"
                                            object:nil];
    
    // Register for modpack installation completion notification
    [NSNotificationCenter.defaultCenter addObserver:self
                                          selector:@selector(handleModpackInstallationComplete:)
                                              name:@"ModpackInstallationComplete"
                                            object:nil];
    
    // Handle authentication if needed
    [self refreshAuthenticationIfNeeded];
}

- (void)setupVersionSelectionUI {
    // Create version text field
    self.versionTextField = [[PickTextField alloc] initWithFrame:CGRectMake(4, 4, self.toolbar.frame.size.width * 0.8 - 8, self.toolbar.frame.size.height - 8)];
    [self.versionTextField addTarget:self.versionTextField action:@selector(resignFirstResponder) forControlEvents:UIControlEventEditingDidEndOnExit];
    self.versionTextField.autoresizingMask = AUTORESIZE_MASKS;
    self.versionTextField.placeholder = @"Specify version...";
    self.versionTextField.leftView = [[UIImageView alloc] initWithFrame:CGRectMake(0, 0, 40, 40)];
    self.versionTextField.rightView = [[UIImageView alloc] initWithImage:[[UIImage imageNamed:@"SpinnerArrow"] _imageWithSize:CGSizeMake(30, 30)]];
    self.versionTextField.rightView.frame = CGRectMake(0, 0, self.versionTextField.frame.size.height * 0.9, self.versionTextField.frame.size.height * 0.9);
    self.versionTextField.leftViewMode = UITextFieldViewModeAlways;
    self.versionTextField.rightViewMode = UITextFieldViewModeAlways;
    self.versionTextField.textAlignment = NSTextAlignmentCenter;
    
    // Create version picker
    self.versionPickerView = [[PLPickerView alloc] init];
    self.versionPickerView.delegate = self;
    self.versionPickerView.dataSource = self;
    
    // Add toolbar to picker
    UIToolbar *versionPickToolbar = [[UIToolbar alloc] initWithFrame:CGRectMake(0.0, 0.0, self.view.frame.size.width, 44.0)];
    UIBarButtonItem *versionFlexibleSpace = [[UIBarButtonItem alloc] initWithBarButtonSystemItem:UIBarButtonSystemItemFlexibleSpace target:self action:nil];
    UIBarButtonItem *versionDoneButton = [[UIBarButtonItem alloc] initWithBarButtonSystemItem:UIBarButtonSystemItemDone target:self action:@selector(versionClosePicker)];
    versionPickToolbar.items = @[versionFlexibleSpace, versionDoneButton];
    
    // Configure text field input
    self.versionTextField.inputAccessoryView = versionPickToolbar;
    self.versionTextField.inputView = self.versionPickerView;
    
    // Add to toolbar
    [self.toolbar addSubview:self.versionTextField];
    
    // Load profiles
    [self reloadProfileList];
}

- (void)setupProgressUI {
    // Main progress view
    self.progressViewMain = [[UIProgressView alloc] initWithFrame:CGRectMake(0, 0, self.toolbar.frame.size.width, 4)];
    self.progressViewMain.autoresizingMask = AUTORESIZE_MASKS;
    self.progressViewMain.hidden = YES;
    [self.toolbar addSubview:self.progressViewMain];
    
    // Secondary progress view
    self.progressViewSub = [[UIProgressView alloc] initWithFrame:CGRectMake(0, 4, self.toolbar.frame.size.width, 2)];
    self.progressViewSub.autoresizingMask = AUTORESIZE_MASKS;
    self.progressViewSub.hidden = YES;
    self.progressViewSub.progressTintColor = [UIColor systemGreenColor];
    [self.toolbar addSubview:self.progressViewSub];
    
    // Progress text label
    self.progressText = [[UILabel alloc] initWithFrame:self.versionTextField.frame];
    self.progressText.adjustsFontSizeToFitWidth = YES;
    self.progressText.autoresizingMask = AUTORESIZE_MASKS;
    self.progressText.font = [self.progressText.font fontWithSize:16];
    self.progressText.textAlignment = NSTextAlignmentCenter;
    self.progressText.userInteractionEnabled = NO;
    [self.toolbar addSubview:self.progressText];
    
    // Install button
    self.buttonInstall = [UIButton buttonWithType:UIButtonTypeSystem];
    setButtonPointerInteraction(self.buttonInstall);
    [self.buttonInstall setTitle:localize(@"Play", nil) forState:UIControlStateNormal];
    self.buttonInstall.autoresizingMask = AUTORESIZE_MASKS;
    self.buttonInstall.backgroundColor = [UIColor colorWithRed:54/255.0 green:176/255.0 blue:48/255.0 alpha:1.0];
    self.buttonInstall.layer.cornerRadius = 5;
    self.buttonInstall.frame = CGRectMake(self.toolbar.frame.size.width * 0.8, 4, self.toolbar.frame.size.width * 0.2, self.toolbar.frame.size.height - 8);
    self.buttonInstall.tintColor = UIColor.whiteColor;
    self.buttonInstall.enabled = NO;
    [self.buttonInstall addTarget:self action:@selector(performInstallOrShowDetails:) forControlEvents:UIControlEventPrimaryActionTriggered];
    [self.toolbar addSubview:self.buttonInstall];
}

- (void)dealloc {
    // Clean up KVO observers
    @try {
        if (self.task && self.task.progress) {
            [self.task.progress removeObserver:self forKeyPath:@"fractionCompleted"];
        }
    } @catch (NSException *exception) {
        NSLog(@"Exception removing observer in dealloc: %@", exception);
    }
    
    // Clean up timer
    [self.progressUpdateTimer invalidate];
    self.progressUpdateTimer = nil;
    
    // Remove notification observers
    [[NSNotificationCenter defaultCenter] removeObserver:self name:@"InstallModpack" object:nil];
    [[NSNotificationCenter defaultCenter] removeObserver:self name:@"ModpackInstallationComplete" object:nil];
}

#pragma mark - Version List Management

- (BOOL)isVersionInstalled:(NSString *)versionId {
    NSString *localPath = [NSString stringWithFormat:@"%s/versions/%@", getenv("POJAV_GAME_DIR"), versionId];
    BOOL isDirectory;
    return [NSFileManager.defaultManager fileExistsAtPath:localPath isDirectory:&isDirectory] && isDirectory;
}

- (void)fetchLocalVersionList {
    // Check if we should reload the list
    BOOL shouldRefresh = YES;
    
    if (lastLocalVersionRefresh) {
        NSTimeInterval timeSinceLastRefresh = -[lastLocalVersionRefresh timeIntervalSinceNow];
        shouldRefresh = (timeSinceLastRefresh > VERSION_LIST_REFRESH_INTERVAL);
    }
    
    if (!shouldRefresh && localVersionList && localVersionList.count > 0) {
        return; // Use cached list if recent
    }
    
    // Perform refresh on background thread
    dispatch_async(dispatch_get_global_queue(DISPATCH_QUEUE_PRIORITY_DEFAULT, 0), ^{
        // Create or initialize list
        [versionListLock lock];
        if (!localVersionList) {
            localVersionList = [NSMutableArray new];
        }
        
        // Create a temporary array
        NSMutableArray *tempVersionList = [NSMutableArray array];
        
        // Get the directory contents safely
        NSFileManager *fileManager = [NSFileManager defaultManager];
        NSString *versionPath = [NSString stringWithFormat:@"%s/versions/", getenv("POJAV_GAME_DIR")];
        
        NSError *dirError = nil;
        NSArray *list = [fileManager contentsOfDirectoryAtPath:versionPath error:&dirError];
        
        if (dirError) {
            NSLog(@"[MCDL] Error reading versions directory: %@", dirError.localizedDescription);
            list = @[];
        }
        
        // Process each version
        for (NSString *versionId in list) {
            // Skip invalid entries
            if (!versionId || ![versionId isKindOfClass:[NSString class]]) {
                continue;
            }
            
            if (![self isVersionInstalled:versionId]) continue;
            
            // Determine type based on name
            NSString *type = @"custom"; // Default
            if ([versionId containsString:@"-alpha"]) type = @"old_alpha";
            else if ([versionId containsString:@"-beta"]) type = @"old_beta";
            else if ([versionId containsString:@"w"] || [versionId containsString:@"-pre"] || [versionId containsString:@"-rc"]) type = @"snapshot";
            else {
                // Check for release format (e.g., 1.X.Y or 1.X)
                NSRegularExpression *releaseRegex = [NSRegularExpression regularExpressionWithPattern:@"^\\d+\\.\\d+(\\.\\d+)?$" options:0 error:nil];
                if ([releaseRegex firstMatchInString:versionId options:0 range:NSMakeRange(0, versionId.length)]) {
                    type = @"release";
                }
            }
            
            [tempVersionList addObject:@{
                @"id": versionId,
                @"type": type
            }];
        }
        
        // Sort versions
        [tempVersionList sortUsingComparator:^NSComparisonResult(NSDictionary* obj1, NSDictionary* obj2) {
            return [obj2[@"id"] compare:obj1[@"id"] options:NSNumericSearch];
        }];
        
        // Update the shared list safely
        [localVersionList removeAllObjects];
        [localVersionList addObjectsFromArray:tempVersionList];
        
        // Update refresh time
        lastLocalVersionRefresh = [NSDate date];
        [versionListLock unlock];
        
        // Update UI on main thread
        dispatch_async(dispatch_get_main_queue(), ^{
            [self.versionPickerView reloadAllComponents];
        });
    });
}

- (void)fetchRemoteVersionList {
    self.buttonInstall.enabled = NO;
    
    // Check if we should reload the list
    BOOL shouldRefresh = YES;
    
    if (lastRemoteVersionRefresh) {
        NSTimeInterval timeSinceLastRefresh = -[lastRemoteVersionRefresh timeIntervalSinceNow];
        shouldRefresh = (timeSinceLastRefresh > VERSION_LIST_REFRESH_INTERVAL);
    }
    
    if (!shouldRefresh && remoteVersionList && remoteVersionList.count > 2) {
        self.buttonInstall.enabled = YES;
        return; // Use cached list if recent
    }
    
    // Initialize or update list safely
    [versionListLock lock];
    if (!remoteVersionList) {
        remoteVersionList = @[
            @{@"id": @"latest-release", @"type": @"release"},
            @{@"id": @"latest-snapshot", @"type": @"snapshot"}
        ].mutableCopy;
    } else {
        // Clear existing remote versions except latest markers
        if (remoteVersionList.count > 2) {
            [remoteVersionList removeObjectsInRange:NSMakeRange(2, remoteVersionList.count - 2)];
        }
    }
    [versionListLock unlock];
    
    // Fetch version manifest from Mojang
    AFHTTPSessionManager *manager = [AFHTTPSessionManager manager];
    [manager GET:@"https://piston-meta.mojang.com/mc/game/version_manifest_v2.json" 
      parameters:nil 
         headers:nil 
        progress:^(NSProgress * _Nonnull progress) {
            dispatch_async(dispatch_get_main_queue(), ^{
                self.progressViewMain.progress = progress.fractionCompleted;
            });
        } 
         success:^(NSURLSessionTask *task, NSDictionary *responseObject) {
            [versionListLock lock];
            
            // Add version list
            NSArray *versions = responseObject[@"versions"];
            if (versions && [versions isKindOfClass:[NSArray class]]) {
                [remoteVersionList addObjectsFromArray:versions];
            }
            NSLog(@"[VersionList] Got %lu remote versions", (unsigned long)(versions ? versions.count : 0));
            
            // Update latest version info
            NSDictionary* latest = responseObject[@"latest"];
            if (latest && [latest isKindOfClass:[NSDictionary class]]) {
                setPrefObject(@"internal.latest_version.release", latest[@"release"]);
                setPrefObject(@"internal.latest_version.snapshot", latest[@"snapshot"]);
            }
            
            // Update refresh time
            lastRemoteVersionRefresh = [NSDate date];
            [versionListLock unlock];
            
            // Update UI
            dispatch_async(dispatch_get_main_queue(), ^{
                self.buttonInstall.enabled = YES;
                [self.versionPickerView reloadAllComponents];
            });
        } 
         failure:^(NSURLSessionTask *operation, NSError *error) {
            NSLog(@"[VersionList] Warning: Unable to fetch version list: %@", error.localizedDescription);
            
            dispatch_async(dispatch_get_main_queue(), ^{
                self.buttonInstall.enabled = YES;
                // Optionally show an error to the user
            });
        }];
}

- (void)reloadProfileList {
    // Reload local version list
    [self fetchLocalVersionList];
    
    // Reload launcher_profiles.json
    [PLProfiles updateCurrent];
    
    // Update UI on main thread
    dispatch_async(dispatch_get_main_queue(), ^{
        [self.versionPickerView reloadAllComponents];
        
        // Get selected profile index
        self.profileSelectedAt = [PLProfiles.current.profiles.allKeys indexOfObject:PLProfiles.current.selectedProfileName];
        
        if (self.profileSelectedAt == NSNotFound) {
            // If selected profile not found, select the first one
            self.profileSelectedAt = 0;
            
            if (PLProfiles.current.profiles.count > 0) {
                PLProfiles.current.selectedProfileName = PLProfiles.current.profiles.allKeys[0];
                [PLProfiles.current save];
            } else {
                // Handle case with no profiles
                self.versionTextField.text = @"";
                ((UIImageView *)self.versionTextField.leftView).image = [UIImage imageNamed:@"DefaultProfile"];
                self.buttonInstall.enabled = NO;
                return;
            }
        }
        
        // Select the appropriate row
        if (self.profileSelectedAt < PLProfiles.current.profiles.count) {
            [self.versionPickerView selectRow:self.profileSelectedAt inComponent:0 animated:NO];
            [self pickerView:self.versionPickerView didSelectRow:self.profileSelectedAt inComponent:0];
            self.buttonInstall.enabled = YES;
        } else {
            // Handle inconsistency
            self.versionTextField.text = @"";
            ((UIImageView *)self.versionTextField.leftView).image = [UIImage imageNamed:@"DefaultProfile"];
            self.buttonInstall.enabled = NO;
            NSLog(@"[LauncherNav] Warning: profileSelectedAt index out of bounds after reload.");
        }
    });
}

#pragma mark - UI State Management

- (void)setInteractionEnabled:(BOOL)enabled forDownloading:(BOOL)downloading {
    dispatch_async(dispatch_get_main_queue(), ^{
        // Update control states
        for (UIControl *view in self.toolbar.subviews) {
            if ([view isKindOfClass:UIControl.class]) {
                view.alpha = enabled ? 1 : 0.2;
                view.enabled = enabled;
            }
        }
        
        // Update progress visibility
        self.progressViewMain.hidden = enabled;
        self.progressViewSub.hidden = enabled;
        self.progressText.text = nil;
        
        if (downloading) {
            // Keep details button enabled during download
            [self.buttonInstall setTitle:localize(enabled ? @"Play" : @"Details", nil) forState:UIControlStateNormal];
            self.buttonInstall.alpha = 1;
            self.buttonInstall.enabled = YES;
        }
        
        // Prevent device sleep during downloads/launches
        UIApplication.sharedApplication.idleTimerDisabled = !enabled;
    });
}

- (void)handleModpackInstallationComplete:(NSNotification *)notification {
    dispatch_async(dispatch_get_main_queue(), ^{
        NSLog(@"[MCDL] Received ModpackInstallationComplete notification, ensuring UI is restored");
        
        // Force UI restoration
        [self setInteractionEnabled:YES forDownloading:NO];
        
        // Refresh version lists and profiles
        [self fetchLocalVersionList];
        [PLProfiles updateCurrent];
        
        // Force layout update for UI consistency
        [self.view setNeedsLayout];
        [self.view layoutIfNeeded];
        
        // Ensure progress views are hidden
        self.progressViewMain.hidden = YES;
        self.progressViewSub.hidden = YES;
        self.progressText.text = nil;
        
        // Reset button title
        [self.buttonInstall setTitle:localize(@"Play", nil) forState:UIControlStateNormal];
        
        // Clean up any remaining task references
        @synchronized(self) {
            self.task = nil;
            self.progressVC = nil;
        }
    });
}

#pragma mark - Launch and Download Management

- (void)performInstallOrShowDetails:(UIButton *)sender {
    // Prevent multiple taps
    sender.enabled = NO;
    
    // Add a slight delay for UI feedback
    dispatch_after(dispatch_time(DISPATCH_TIME_NOW, (int64_t)(0.1 * NSEC_PER_SEC)), dispatch_get_main_queue(), ^{
        // Check for active task
        BOOL taskIsActive = NO;
        
        @synchronized(self) {
            if (self.task && self.task.progress && !self.task.progress.cancelled) {
                taskIsActive = YES;
            }
        }
        
        if (taskIsActive) {
            // Show download details
            if (!self.progressVC) {
                @synchronized(self) {
                    if (self.task) {
                        self.progressVC = [[DownloadProgressViewController alloc] initWithTask:self.task];
                    }
                }
            }
            
            if (self.progressVC) {
                // Present in popover
                UINavigationController *nav = [[UINavigationController alloc] initWithRootViewController:self.progressVC];
                nav.modalPresentationStyle = UIModalPresentationPopover;
                
                if (sender && sender.window) {
                    nav.popoverPresentationController.sourceView = sender;
                    nav.popoverPresentationController.sourceRect = sender.bounds;
                    
                    [self presentViewController:nav animated:YES completion:^{
                        sender.enabled = YES;
                    }];
                } else {
                    NSLog(@"[LauncherNav] Warning: Cannot present progress VC, source button is invalid.");
                    sender.enabled = YES;
                }
            } else {
                NSLog(@"[LauncherNav] Warning: Failed to create progressVC.");
                sender.enabled = YES;
            }
        } else {
            // Start new download
            @synchronized(self) {
                self.task = nil;
                self.progressVC = nil;
            }
            
            [self launchMinecraft:sender];
            // Button will be re-enabled by completion handler
        }
    });
}

- (void)launchMinecraft:(UIButton *)sender {
    // Validate input
    if (!self.versionTextField.hasText) {
        [self.versionTextField becomeFirstResponder];
        return;
    }
    
    // Check for valid account
    if (BaseAuthenticator.current == nil) {
        // Present account selector
        LauncherMenuViewController *sidebarVC = sidebarViewController;
        if (sidebarVC) {
            [sidebarVC selectAccount:sender];
        } else {
            NSLog(@"[LauncherNav] Error: Could not find sidebarViewController to present account selection.");
            showDialog(@"Account Error", @"Please select an account first.");
        }
        return;
    }
    
    // Disable UI during download
    [self setInteractionEnabled:NO forDownloading:YES];
    
    // Get version ID from selected profile
    NSString *selectedProfileName = self.versionTextField.text;
    NSString *versionId = nil;
    
    @try {
        NSDictionary *profile = PLProfiles.current.profiles[selectedProfileName];
        if (profile) {
            versionId = profile[@"lastVersionId"];
        }
    } @catch (NSException *exception) {
        NSLog(@"[LauncherNav] Error accessing profile '%@': %@", selectedProfileName, exception);
        [self setInteractionEnabled:YES forDownloading:NO];
        showDialog(@"Profile Error", @"Could not load profile data.");
        return;
    }
    
    if (!versionId || versionId.length == 0) {
        NSLog(@"[LauncherNav] Error: No version ID found for profile '%@'", selectedProfileName);
        [self setInteractionEnabled:YES forDownloading:NO];
        showDialog(@"Version Error", @"No version selected for this profile.");
        return;
    }
    
    // Find version in remote list
    NSDictionary *object = nil;
    
    [versionListLock lock];
    if (remoteVersionList) {
        NSArray *safeRemoteList = [remoteVersionList copy];
        object = [safeRemoteList filteredArrayUsingPredicate:
                 [NSPredicate predicateWithFormat:@"(id == %@)", versionId]].firstObject;
    }
    [versionListLock unlock];
    
    // If not found in remote list, create a custom version object
    if (!object) {
        object = @{
            @"id": versionId,
            @"type": @"custom"
        };
    }
    
    NSLog(@"[MCDL] Starting download for version: %@", versionId);
    
    // Create the download task with cleanup
    @synchronized(self) {
        // Clean up any previous task
        if (self.task && self.task.progress) {
            @try {
                [self.task.progress removeObserver:self forKeyPath:@"fractionCompleted"];
            } @catch(NSException *e) {}
        }
        
        // Create new task
        self.task = [MinecraftResourceDownloadTask new];
    }
    
    // Setup error handler
    __weak LauncherNavigationController *weakSelf = self;
    self.task.handleError = ^{
        dispatch_async(dispatch_get_main_queue(), ^{
            if (!weakSelf) return;
            
            [weakSelf setInteractionEnabled:YES forDownloading:YES];
            
            @synchronized(weakSelf) {
                weakSelf.task = nil;
                weakSelf.progressVC = nil;
            }
        });
    };
    
    // Start download on background thread
    dispatch_async(dispatch_get_global_queue(DISPATCH_QUEUE_PRIORITY_DEFAULT, 0), ^{
        @synchronized(weakSelf.task) {
            if (!weakSelf.task) return;
            
            if (!weakSelf.task.metadata) {
                weakSelf.task.metadata = [NSMutableDictionary dictionary];
            }
            weakSelf.task.metadata[@"isModpackInstall"] = @NO;
        }
        
        // Start the download
        [weakSelf.task downloadVersion:object];
        
        // Setup progress tracking on main thread
        dispatch_async(dispatch_get_main_queue(), ^{
            if (!weakSelf) return;
            
            @synchronized(weakSelf) {
                if (!weakSelf.task || !weakSelf.task.progress) return;
                
                // Connect progress bars to task
                weakSelf.progressViewMain.observedProgress = weakSelf.task.progress;
                weakSelf.progressViewSub.observedProgress = weakSelf.task.textProgress;
                
                // Add KVO observer
                @try {
                    [weakSelf.task.progress addObserver:weakSelf
                                            forKeyPath:@"fractionCompleted"
                                               options:NSKeyValueObservingOptionInitial | NSKeyValueObservingOptionNew
                                               context:ProgressObserverContext];
                } @catch (NSException *exception) {
                    NSLog(@"[MCDL] Exception adding progress observer: %@", exception);
                    
                    [weakSelf setInteractionEnabled:YES forDownloading:YES];
                    weakSelf.task = nil;
                    weakSelf.progressVC = nil;
                }
                
                // Setup a timer for more frequent UI updates
                if (weakSelf.progressUpdateTimer) {
                    [weakSelf.progressUpdateTimer invalidate];
                }
                
                weakSelf.progressUpdateTimer = [NSTimer scheduledTimerWithTimeInterval:0.2
                                                                               target:weakSelf
                                                                             selector:@selector(updateProgressText)
                                                                             userInfo:nil
                                                                              repeats:YES];
                [NSRunLoop.mainRunLoop addTimer:weakSelf.progressUpdateTimer forMode:NSRunLoopCommonModes];
            }
        });
    });
}

- (void)updateProgressText {
    // Update progress text on timer to reduce KVO overhead
    @synchronized(self) {
        if (!self.task || !self.task.textProgress) {
            [self.progressUpdateTimer invalidate];
            self.progressUpdateTimer = nil;
            return;
        }
        
        // Update progress text display
        self.progressText.text = self.task.textProgress.localizedAdditionalDescription;
    }
}

- (void)observeValueForKeyPath:(NSString *)keyPath ofObject:(id)object change:(NSDictionary *)change context:(void *)context {
    if (context != ProgressObserverContext) {
        [super observeValueForKeyPath:keyPath ofObject:object change:change context:context];
        return;
    }
    
    __weak typeof(self) weakSelf = self;
    
    dispatch_async(dispatch_get_main_queue(), ^{
        if (!weakSelf) return;
        
        // Check if object matches current task's progress
        MinecraftResourceDownloadTask *observedTask = nil;
        NSProgress *observedProgress = nil;
        
        @synchronized(weakSelf) {
            observedTask = weakSelf.task;
            if (observedTask) {
                observedProgress = observedTask.progress;
            }
        }
        
        if (!observedTask || object != observedProgress) {
            NSLog(@"[MCDL] Received progress update for an old or invalid task. Ignoring.");
            return;
        }
        
        // Check if download is complete - check multiple indicators
        BOOL isTrulyFinished = observedTask.isDownloadPhaseComplete;
        BOOL isProgressFinished = NO;
        BOOL isModpackInstall = NO;
        BOOL allTasksComplete = NO;
        
        @synchronized(observedTask) {
            // Check progress completion
            @try {
                isProgressFinished = (observedProgress.fractionCompleted >= 1.0 || observedProgress.finished);
            } @catch (NSException *e) {
                isProgressFinished = NO;
            }
            
            // Check modpack flags
            if (observedTask.metadata) {
                isModpackInstall = [observedTask.metadata[@"isModpackInstall"] boolValue];
                allTasksComplete = [observedTask.metadata[@"allTasksComplete"] boolValue];
            }
        }
        
        // Log detailed state for debugging
        NSLog(@"[MCDL] Download status: isDownloadPhaseComplete=%d, isProgressFinished=%d, isModpackInstall=%d, allTasksComplete=%d",
              isTrulyFinished, isProgressFinished, isModpackInstall, allTasksComplete);
        
        // Only proceed if truly finished or we detect modpack completion
        if (!isTrulyFinished && !(isModpackInstall && allTasksComplete)) {
            return;
        }
        
        NSLog(@"[MCDL] Download phase reported as complete.");
        
        // Dismiss progress view if open
        if (weakSelf.progressVC) {
            NSLog(@"[MCDL] Trying to dismiss progress view controller");
            
            // Create a strong reference to prevent deallocation during dismissal
            UIViewController *progressVC = weakSelf.progressVC;
            
            // Check if the progress VC is presented before trying to dismiss
            if (progressVC.presentedViewController) {
                [progressVC.presentedViewController dismissViewControllerAnimated:NO completion:nil];
            } else if (progressVC.presentingViewController) {
                [progressVC.presentingViewController dismissViewControllerAnimated:NO completion:nil];
            }
        }
        
        // Clean up progress observation
        @try {
            if (observedProgress) {
                [observedProgress removeObserver:weakSelf forKeyPath:@"fractionCompleted"];
            }
        } @catch (NSException *exception) {
            NSLog(@"[MCDL] Exception removing progress observer: %@", exception);
        }
        
        // Clear progress observations
        weakSelf.progressViewMain.observedProgress = nil;
        weakSelf.progressViewSub.observedProgress = nil;
        
        // Stop progress update timer
        [weakSelf.progressUpdateTimer invalidate];
        weakSelf.progressUpdateTimer = nil;
        
        // Thoroughly validate metadata
        BOOL metadataValid = NO;
        NSDictionary *metadataCopy = nil;
        
        @synchronized(observedTask) {
            if (observedTask.metadata && observedTask.metadata[@"isModpackInstall"]) {
                isModpackInstall = [observedTask.metadata[@"isModpackInstall"] boolValue];
            }
            
            if (observedTask.metadata) {
                metadataCopy = [observedTask.metadata copy];
                NSLog(@"[MCDL] Metadata copy created successfully");
            } else {
                NSLog(@"[MCDL] Warning: Task metadata is nil at completion");
            }
        }
        
        NSLog(@"[MCDL] isModpackInstall: %d, has metadata: %@",
              isModpackInstall, metadataCopy ? @"YES" : @"NO");
        
        // For modpack installs, re-enable UI immediately 
        if (isModpackInstall) {
            NSLog(@"[MCDL] Modpack installation detected, re-enabling UI");
            [weakSelf setInteractionEnabled:YES forDownloading:NO];
            [weakSelf fetchLocalVersionList];
            [PLProfiles updateCurrent];
            
            // Force layout update
            [weakSelf.view setNeedsLayout];
            [weakSelf.view layoutIfNeeded];
        }
        
        // Validate metadata for non-modpack launches
        if (!isModpackInstall) {
            if (!metadataCopy) {
                NSLog(@"[MCDL] Error: No metadata available for launch.");
                [weakSelf setInteractionEnabled:YES forDownloading:YES];
                showDialog(@"Launch Error", @"Failed to prepare game data for launch: Missing metadata.");
                return;
            }
            
            if (![metadataCopy isKindOfClass:[NSDictionary class]]) {
                NSLog(@"[MCDL] Error: Metadata is not a dictionary. Type: %@", NSStringFromClass([metadataCopy class]));
                [weakSelf setInteractionEnabled:YES forDownloading:YES];
                showDialog(@"Launch Error", @"Failed to prepare game data for launch: Invalid metadata type.");
                return;
            }
            
            if (!metadataCopy[@"id"]) {
                NSLog(@"[MCDL] Error: Metadata missing 'id' key.");
                [weakSelf setInteractionEnabled:YES forDownloading:YES];
                showDialog(@"Launch Error", @"Failed to prepare game data for launch: Missing version ID.");
                return;
            }
        }
        
        // Store a final copy of metadata before clearing task
        NSDictionary *finalMetadataCopy = [metadataCopy copy];
        
        // Clean up task references
        @synchronized(weakSelf) {
            weakSelf.task = nil;
            weakSelf.progressVC = nil;
        }
        
        // Launch the game for non-modpack installations
        if (finalMetadataCopy && !isModpackInstall) {
            // Launch with slight delay to ensure cleanup completes
            dispatch_after(dispatch_time(DISPATCH_TIME_NOW, (int64_t)(0.5 * NSEC_PER_SEC)), dispatch_get_main_queue(), ^{
                [weakSelf invokeAfterJITEnabled:^{
                    if (weakSelf && weakSelf.view.window) {
                        NSLog(@"[MCDL] Launching game with metadata: %@", finalMetadataCopy[@"id"]);
                        UIKit_launchMinecraftSurfaceVC(weakSelf.view.window, finalMetadataCopy);
                    } else {
                        NSLog(@"[MCDL] Error: View hierarchy invalid for launch");
                        [weakSelf setInteractionEnabled:YES forDownloading:YES];
                    }
                }];
            });
        } else if (!isModpackInstall) {
            // For non-modpack case not handled above, re-enable UI
            [weakSelf setInteractionEnabled:YES forDownloading:NO];
        }
    });
}

#pragma mark - Notifications

- (void)receiveNotification:(NSNotification *)notification {
    if (![notification.name isEqualToString:@"InstallModpack"]) {
        return;
    }
    
    // Disable UI during download
    [self setInteractionEnabled:NO forDownloading:YES];
    
    // Create a new download task
    @synchronized(self) {
        // Clean up any previous task
        if (self.task && self.task.progress) {
            @try {
                [self.task.progress removeObserver:self forKeyPath:@"fractionCompleted"];
            } @catch (NSException *exception) {}
        }
        
        // Create new task
        self.task = [MinecraftResourceDownloadTask new];
    }
    
    // Setup error handler
    __weak LauncherNavigationController *weakSelf = self;
    self.task.handleError = ^{
        dispatch_async(dispatch_get_main_queue(), ^{
            if (!weakSelf) return;
            
            [weakSelf setInteractionEnabled:YES forDownloading:YES];
            
            @synchronized(weakSelf) {
                weakSelf.task = nil;
                weakSelf.progressVC = nil;
            }
        });
    };
    
    // Setup progress tracking
    self.progressViewMain.observedProgress = self.task.progress;
    self.progressViewSub.observedProgress = self.task.textProgress;
    
    // Add KVO observer
    @try {
        [self.task.progress addObserver:self
                            forKeyPath:@"fractionCompleted"
                               options:NSKeyValueObservingOptionInitial | NSKeyValueObservingOptionNew
                               context:ProgressObserverContext];
    } @catch (NSException *exception) {
        NSLog(@"[MCDL] Exception adding progress observer for modpack: %@", exception);
        [self setInteractionEnabled:YES forDownloading:YES];
        self.task = nil;
        return;
    }
    
    // Setup progress update timer
    if (self.progressUpdateTimer) {
        [self.progressUpdateTimer invalidate];
    }
    
    self.progressUpdateTimer = [NSTimer scheduledTimerWithTimeInterval:0.2
                                                                target:self
                                                              selector:@selector(updateProgressText)
                                                              userInfo:nil
                                                               repeats:YES];
    [NSRunLoop.mainRunLoop addTimer:self.progressUpdateTimer forMode:NSRunLoopCommonModes];
    
    // Get data from notification
    NSDictionary *userInfo = [notification.userInfo copy];
    id notificationObject = notification.object;
    
    // Start modpack download in background
    dispatch_async(dispatch_get_global_queue(DISPATCH_QUEUE_PRIORITY_DEFAULT, 0), ^{
        @synchronized(weakSelf.task) {
            if (!weakSelf.task) {
                NSLog(@"[MCDL] Modpack download cancelled before starting.");
                return;
            }
            
            // Mark this as a modpack installation
            if (!weakSelf.task.metadata) {
                weakSelf.task.metadata = [NSMutableDictionary dictionary];
            }
            weakSelf.task.metadata[@"isModpackInstall"] = @YES;
        }
        
        // Start the download
        [weakSelf.task downloadModpackFromAPI:notificationObject
                                       detail:userInfo[@"detail"]
                                      atIndex:[userInfo[@"index"] unsignedLongValue]];
    });
}

#pragma mark - Helper Methods

- (void)refreshAuthenticationIfNeeded {
    if ([BaseAuthenticator.current isKindOfClass:MicrosoftAuthenticator.class]) {
        // Perform token refreshment on startup
        [self setInteractionEnabled:NO forDownloading:NO];
        
        id callback = ^(id status, BOOL success) {
            self.progressText.text = status;
            if (status == nil) {
                [self setInteractionEnabled:YES forDownloading:NO];
            } else if (!success) {
                showDialog(localize(@"Error", nil), [status localizedDescription]);
            }
        };
        
        [BaseAuthenticator.current refreshTokenWithCallback:callback];
    }
}


#pragma mark - Mod Installation Methods

- (void)enterCustomControls {
    CustomControlsViewController *vc = [[CustomControlsViewController alloc] init];
    vc.modalPresentationStyle = UIModalPresentationOverFullScreen;
    
    vc.setDefaultCtrl = ^(NSString *name){
        setPrefObject(@"control.default_ctrl", name);
    };
    
    vc.getDefaultCtrl = ^{
        return getPrefObject(@"control.default_ctrl");
    };
    
    [self presentViewController:vc animated:YES completion:nil];
}

- (void)enterModInstaller {
    UIDocumentPickerViewController *documentPicker = [[UIDocumentPickerViewController alloc]
        initForOpeningContentTypes:@[[UTType typeWithMIMEType:@"application/java-archive"]]
        asCopy:YES];
    documentPicker.delegate = self;
    documentPicker.modalPresentationStyle = UIModalPresentationFormSheet;
    [self presentViewController:documentPicker animated:YES completion:nil];
}

- (void)enterModInstallerWithPath:(NSString *)path hitEnterAfterWindowShown:(BOOL)hitEnter {
    JavaGUIViewController *vc = [[JavaGUIViewController alloc] init];
    vc.filepath = path;
    [vc setHitEnterAfterWindowShown:hitEnter];
    
    if (!vc.requiredJavaVersion) {
        return;
    }
    
    [self invokeAfterJITEnabled:^{
        vc.modalPresentationStyle = UIModalPresentationFullScreen;
        NSLog(@"[ModInstaller] launching %@", vc.filepath);
        [self presentViewController:vc animated:YES completion:nil];
    }];
}

- (void)documentPicker:(UIDocumentPickerViewController *)controller didPickDocumentAtURL:(NSURL *)url {
    [self enterModInstallerWithPath:url.path hitEnterAfterWindowShown:NO];
}

#pragma mark - JIT and Launch Helper Methods

- (void)invokeAfterJITEnabled:(void(^)(void))handler {
    BOOL hasTrollStoreJIT = getEntitlementValue(@"com.apple.private.local.sandboxed-jit");

    if (isJITEnabled(false)) {
        [ALTServerManager.sharedManager stopDiscovering];
        handler();
        return;
    } else if (hasTrollStoreJIT) {
        NSURL *jitURL = [NSURL URLWithString:[NSString stringWithFormat:@"apple-magnifier://enable-jit?bundle-id=%@", NSBundle.mainBundle.bundleIdentifier]];
        [UIApplication.sharedApplication openURL:jitURL options:@{} completionHandler:nil];
        // Do not return, wait for TrollStore to enable JIT and jump back
    } else if (getPrefBool(@"debug.debug_skip_wait_jit")) {
        NSLog(@"Debug option skipped waiting for JIT. Java might not work.");
        handler();
        return;
    }

    self.progressText.text = localize(@"launcher.wait_jit.title", nil);

    UIAlertController* alert = [UIAlertController alertControllerWithTitle:localize(@"launcher.wait_jit.title", nil)
        message:hasTrollStoreJIT ? localize(@"launcher.wait_jit_trollstore.message", nil) : localize(@"launcher.wait_jit.message", nil)
        preferredStyle:UIAlertControllerStyleAlert];

    [self presentViewController:alert animated:YES completion:nil];

    dispatch_async(dispatch_get_global_queue(DISPATCH_QUEUE_PRIORITY_DEFAULT, 0), ^{
        while (!isJITEnabled(false)) {
            // Perform check for every 200ms
            usleep(1000*200);
        }
        dispatch_async(dispatch_get_main_queue(), ^{
            [alert dismissViewControllerAnimated:YES completion:handler];
        });
    });
}

#pragma mark - Version Picker Management

- (void)versionClosePicker {
    [self.versionTextField endEditing:YES];
    
    // Get selected row
    NSInteger selectedRow = [self.versionPickerView selectedRowInComponent:0];
    
    // Validate selection
    if (selectedRow >= 0 && selectedRow < [self pickerView:self.versionPickerView numberOfRowsInComponent:0]) {
        [self pickerView:self.versionPickerView didSelectRow:selectedRow inComponent:0];
    } else {
        // Handle invalid selection
        if ([self pickerView:self.versionPickerView numberOfRowsInComponent:0] > 0) {
            [self.versionPickerView selectRow:0 inComponent:0 animated:NO];
            [self pickerView:self.versionPickerView didSelectRow:0 inComponent:0];
        } else {
            // No available profiles
            self.versionTextField.text = @"";
            ((UIImageView *)self.versionTextField.leftView).image = [UIImage imageNamed:@"DefaultProfile"];
        }
    }
}

#pragma mark - UIPickerView Data Source & Delegate

- (void)pickerView:(PLPickerView *)pickerView didSelectRow:(NSInteger)row inComponent:(NSInteger)component {
    if (row >= PLProfiles.current.profiles.count) {
        NSLog(@"[LauncherNav] Warning: Selected row %ld is out of bounds for profiles (%lu)", 
              (long)row, (unsigned long)PLProfiles.current.profiles.count);
        return;
    }
    
    // Update selected profile
    self.profileSelectedAt = row;
    NSString *profileName = PLProfiles.current.profiles.allKeys[row];
    self.versionTextField.text = profileName;
    ((UIImageView *)self.versionTextField.leftView).image = [pickerView imageAtRow:row column:component];
    
    // Save selection
    PLProfiles.current.selectedProfileName = profileName;
}

- (NSInteger)numberOfComponentsInPickerView:(UIPickerView *)pickerView {
    return 1;
}

- (NSInteger)pickerView:(UIPickerView *)pickerView numberOfRowsInComponent:(NSInteger)component {
    return PLProfiles.current.profiles.count;
}

- (NSString *)pickerView:(UIPickerView *)pickerView titleForRow:(NSInteger)row forComponent:(NSInteger)component {
    if (row >= PLProfiles.current.profiles.count) {
        return @"Error";
    }
    return PLProfiles.current.profiles.allValues[row][@"name"];
}

- (void)pickerView:(UIPickerView *)pickerView enumerateImageView:(UIImageView *)imageView forRow:(NSInteger)row forComponent:(NSInteger)component {
    if (row >= PLProfiles.current.profiles.count) {
        imageView.image = [[UIImage imageNamed:@"DefaultProfile"] _imageWithSize:CGSizeMake(40, 40)];
        return;
    }
    
    // Load profile icon image
    UIImage *fallbackImage = [[UIImage imageNamed:@"DefaultProfile"] _imageWithSize:CGSizeMake(40, 40)];
    NSString *urlString = PLProfiles.current.profiles.allValues[row][@"icon"];
    [imageView setImageWithURL:[NSURL URLWithString:urlString] placeholderImage:fallbackImage];
}

#pragma mark - UIPopoverPresentationControllerDelegate

- (UIModalPresentationStyle)adaptivePresentationStyleForPresentationController:(UIPresentationController *)controller traitCollection:(UITraitCollection *)traitCollection {
    return UIModalPresentationNone;
}

#pragma mark - View Controller UI Mode

- (BOOL)prefersHomeIndicatorAutoHidden {
    return YES;
}

- (void)viewDidLayoutSubviews {
    [super viewDidLayoutSubviews];
    
    // Update account info in sidebar
    LauncherMenuViewController *sidebarVC = sidebarViewController;
    if (sidebarVC && [sidebarVC isKindOfClass:[LauncherMenuViewController class]]) {
        [sidebarVC updateAccountInfo];
    } else {
        NSLog(@"[LauncherNav] Warning: Could not find or cast sidebarViewController to update account info.");
    }
}

@end

#import <dlfcn.h>
#import <UniformTypeIdentifiers/UniformTypeIdentifiers.h>
#import "authenticator/BaseAuthenticator.h"
#import "AFNetworking.h"
#import "ALTServerConnection.h"
#import "CustomControlsViewController.h"
#import "DownloadProgressViewController.h"
#import "JavaGUIViewController.h"
#import "LauncherMenuViewController.h"
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

static void *ProgressObserverContext = &ProgressObserverContext;

// Lock for thread-safe access to version lists
static NSLock *versionListLock;

@interface LauncherNavigationController () <UIDocumentPickerDelegate, UIPickerViewDataSource, PLPickerViewDelegate, UIPopoverPresentationControllerDelegate> {
}

@property(nonatomic) MinecraftResourceDownloadTask* task;
@property(nonatomic) DownloadProgressViewController* progressVC;
@property(nonatomic) PLPickerView* versionPickerView;
@property(nonatomic) UITextField* versionTextField;
@property(nonatomic) int profileSelectedAt;

@end

@implementation LauncherNavigationController

- (void)viewDidLoad
{
    [super viewDidLoad];

    // Initialize lock for thread-safe access to version lists
    versionListLock = [[NSLock alloc] init];

    if ([self respondsToSelector:@selector(setNeedsUpdateOfScreenEdgesDeferringSystemGestures)]) {
        [self setNeedsUpdateOfScreenEdgesDeferringSystemGestures];
    }

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

    self.versionPickerView = [[PLPickerView alloc] init];
    self.versionPickerView.delegate = self;
    self.versionPickerView.dataSource = self;
    UIToolbar *versionPickToolbar = [[UIToolbar alloc] initWithFrame:CGRectMake(0.0, 0.0, self.view.frame.size.width, 44.0)];

    [self reloadProfileList];

    UIBarButtonItem *versionFlexibleSpace = [[UIBarButtonItem alloc] initWithBarButtonSystemItem:UIBarButtonSystemItemFlexibleSpace target:self action:nil];
    UIBarButtonItem *versionDoneButton = [[UIBarButtonItem alloc] initWithBarButtonSystemItem:UIBarButtonSystemItemDone target:self action:@selector(versionClosePicker)];
    versionPickToolbar.items = @[versionFlexibleSpace, versionDoneButton];
    self.versionTextField.inputAccessoryView = versionPickToolbar;
    self.versionTextField.inputView = self.versionPickerView;

    UIView *targetToolbar = self.toolbar;
    [targetToolbar addSubview:self.versionTextField];

    self.progressViewMain = [[UIProgressView alloc] initWithFrame:CGRectMake(0, 0, self.toolbar.frame.size.width, 4)];
    self.progressViewMain.autoresizingMask = AUTORESIZE_MASKS;
    self.progressViewMain.hidden = YES;
    [targetToolbar addSubview:self.progressViewMain];

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
    [targetToolbar addSubview:self.buttonInstall];

    self.progressText = [[UILabel alloc] initWithFrame:self.versionTextField.frame];
    self.progressText.adjustsFontSizeToFitWidth = YES;
    self.progressText.autoresizingMask = AUTORESIZE_MASKS;
    self.progressText.font = [self.progressText.font fontWithSize:16];
    self.progressText.textAlignment = NSTextAlignmentCenter;
    self.progressText.userInteractionEnabled = NO;
    [targetToolbar addSubview:self.progressText];

    [self fetchRemoteVersionList];
    [NSNotificationCenter.defaultCenter addObserver:self
        selector:@selector(receiveNotification:) 
        name:@"InstallModpack"
        object:nil];

    if ([BaseAuthenticator.current isKindOfClass:MicrosoftAuthenticator.class]) {
        // Perform token refreshment on startup
        [self setInteractionEnabled:NO forDownloading:NO];
        id callback = ^(NSString* status, BOOL success) {
            self.progressText.text = status;
            if (status == nil) {
                [self setInteractionEnabled:YES forDownloading:NO];
            } else if (!success) {
                showDialog(localize(@"Error", nil), status);
            }
        };
        [BaseAuthenticator.current refreshTokenWithCallback:callback];
    }
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
    
    // Remove notification observers
    [[NSNotificationCenter defaultCenter] removeObserver:self name:@"InstallModpack" object:nil];
}

- (BOOL)isVersionInstalled:(NSString *)versionId {
    NSString *localPath = [NSString stringWithFormat:@"%s/versions/%@", getenv("POJAV_GAME_DIR"), versionId];
    BOOL isDirectory;
    [NSFileManager.defaultManager fileExistsAtPath:localPath isDirectory:&isDirectory];
    return isDirectory;
}

- (void)fetchLocalVersionList {
    if (!localVersionList) {
        localVersionList = [NSMutableArray new];
    }
    
    // Create a temporary array to hold results while we're building it
    NSMutableArray *tempVersionList = [NSMutableArray array];

    NSFileManager *fileManager = [NSFileManager defaultManager];
    NSString *versionPath = [NSString stringWithFormat:@"%s/versions/", getenv("POJAV_GAME_DIR")];
    
    // Get the directory contents safely
    NSError *dirError = nil;
    NSArray *list = [fileManager contentsOfDirectoryAtPath:versionPath error:&dirError];
    
    if (dirError) {
        NSLog(@"[MCDL] Error reading versions directory: %@", dirError.localizedDescription);
        // Still proceed with an empty list
        list = @[];
    }
    
    // Process each version
    for (NSString *versionId in list) {
        // Skip invalid entries
        if (!versionId || ![versionId isKindOfClass:[NSString class]]) {
            continue;
        }
        
        if (![self isVersionInstalled:versionId]) continue;
        
        // Create version dictionary
        NSDictionary *versionDict = @{
            @"id": versionId,
            @"type": @"custom"
        };
        
        [tempVersionList addObject:versionDict];
    }
    
    // Now safely update the shared global array
    [versionListLock lock];
    [localVersionList removeAllObjects];
    [localVersionList addObjectsFromArray:tempVersionList];
    [versionListLock unlock];
}

- (void)fetchRemoteVersionList {
    self.buttonInstall.enabled = NO;
    
    [versionListLock lock];
    remoteVersionList = @[
        @{@"id": @"latest-release", @"type": @"release"},
        @{@"id": @"latest-snapshot", @"type": @"snapshot"}
    ].mutableCopy;
    [versionListLock unlock];

    AFHTTPSessionManager *manager = [AFHTTPSessionManager manager];
    [manager GET:@"https://piston-meta.mojang.com/mc/game/version_manifest_v2.json" parameters:nil headers:nil progress:^(NSProgress * _Nonnull progress) {
        self.progressViewMain.progress = progress.fractionCompleted;
    } success:^(NSURLSessionTask *task, NSDictionary *responseObject) {
        [versionListLock lock];
        [remoteVersionList addObjectsFromArray:responseObject[@"versions"]];
        NSDebugLog(@"[VersionList] Got %d versions", remoteVersionList.count);
        setPrefObject(@"internal.latest_version", responseObject[@"latest"]);
        [versionListLock unlock];
        
        self.buttonInstall.enabled = YES;
    } failure:^(NSURLSessionTask *operation, NSError *error) {
        NSDebugLog(@"[VersionList] Warning: Unable to fetch version list: %@", error.localizedDescription);
        self.buttonInstall.enabled = YES;
    }];
}

// Invoked by: startup, instance change event
- (void)reloadProfileList {
    // Reload local version list
    [self fetchLocalVersionList];
    // Reload launcher_profiles.json
    [PLProfiles updateCurrent];
    [self.versionPickerView reloadAllComponents];
    // Reload selected profile info
    self.profileSelectedAt = [PLProfiles.current.profiles.allKeys indexOfObject:PLProfiles.current.selectedProfileName];
    if (self.profileSelectedAt == -1) {
        // This instance has no profiles?
        return;
    }
    [self.versionPickerView selectRow:self.profileSelectedAt inComponent:0 animated:NO];
    [self pickerView:self.versionPickerView didSelectRow:self.profileSelectedAt inComponent:0];
}

#pragma mark - Options
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
    vc.hitEnterAfterWindowShown = hitEnter;
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

- (void)setInteractionEnabled:(BOOL)enabled forDownloading:(BOOL)downloading {
    for (UIControl *view in self.toolbar.subviews) {
        if ([view isKindOfClass:UIControl.class]) {
            view.alpha = enabled ? 1 : 0.2;
            view.enabled = enabled;
        }
    }
    self.progressViewMain.hidden = enabled;
    self.progressText.text = nil;
    if (downloading) {
        [self.buttonInstall setTitle:localize(enabled ? @"Play" : @"Details", nil) forState:UIControlStateNormal];
        self.buttonInstall.alpha = 1;
        self.buttonInstall.enabled = YES;
    }
    UIApplication.sharedApplication.idleTimerDisabled = !enabled;
}

- (void)launchMinecraft:(UIButton *)sender {
    // Basic validation
    if (!self.versionTextField.hasText) {
        [self.versionTextField becomeFirstResponder];
        return;
    }

    // Check if we have an account
    if (BaseAuthenticator.current == nil) {
        // Present the account selector if none selected
        UIViewController *view = [(UINavigationController *)self.splitViewController.viewControllers[0]
        viewControllers][0];
        [view performSelector:@selector(selectAccount:) withObject:sender];
        return;
    }

    // Disable UI during download
    [self setInteractionEnabled:NO forDownloading:YES];

    // Get the version ID from the selected profile
    NSString *versionId = PLProfiles.current.profiles[self.versionTextField.text][@"lastVersionId"];
    
    // Thread-safely access the version list
    [versionListLock lock];
    NSDictionary *object = [remoteVersionList filteredArrayUsingPredicate:
                          [NSPredicate predicateWithFormat:@"(id == %@)", versionId]].firstObject;
    [versionListLock unlock];
    
    // If not found in remote list, create a custom version object
    if (!object) {
        object = @{
            @"id": versionId,
            @"type": @"custom"
        };
    }

    NSLog(@"[MCDL] Starting download for version: %@", versionId);
    
    // Create the download task
    self.task = [MinecraftResourceDownloadTask new];
    
    // Set up error handler with weak self reference to avoid memory leaks
    __weak LauncherNavigationController *weakSelf = self;
    self.task.handleError = ^{
        dispatch_async(dispatch_get_main_queue(), ^{
            [weakSelf setInteractionEnabled:YES forDownloading:YES];
            weakSelf.task = nil;
            weakSelf.progressVC = nil;
        });
    };
    
    // Start download process in background
    dispatch_async(dispatch_get_global_queue(DISPATCH_QUEUE_PRIORITY_DEFAULT, 0), ^{
        // Explicitly mark this as NOT a modpack installation
        if (!self.task.metadata) {
            self.task.metadata = [NSMutableDictionary dictionary];
        }
        self.task.metadata[@"isModpackInstall"] = @NO;
        
        // Start the download process
        [self.task downloadVersion:object];
        
        // Set up progress tracking on main thread
        dispatch_async(dispatch_get_main_queue(), ^{
            // Skip if task was cancelled or cleared
            if (!self.task || !self.task.progress) return;
            
            // Connect progress bar to task progress
            self.progressViewMain.observedProgress = self.task.progress;
            
            // Add observer for progress updates
            @try {
                [self.task.progress addObserver:self
                                     forKeyPath:@"fractionCompleted"
                                        options:NSKeyValueObservingOptionInitial
                                        context:ProgressObserverContext];
            } @catch (NSException *exception) {
                NSLog(@"[MCDL] Exception adding progress observer: %@", exception);
            }
        });
    });
}

- (void)performInstallOrShowDetails:(UIButton *)sender {
    // Disable button to prevent multiple taps
    sender.enabled = NO;
    
    // Add a slight delay to allow UI to update
    dispatch_after(dispatch_time(DISPATCH_TIME_NOW, (int64_t)(0.1 * NSEC_PER_SEC)), dispatch_get_main_queue(), ^{
        // Check if we have an active task
        if (self.task && self.task.progress && !self.task.progress.cancelled) {
            // Show download details view
            if (!self.progressVC) {
                self.progressVC = [[DownloadProgressViewController alloc] initWithTask:self.task];
            }
            
            // Present progress view in a popover
            UINavigationController *nav = [[UINavigationController alloc] initWithRootViewController:self.progressVC];
            nav.modalPresentationStyle = UIModalPresentationPopover;
            nav.popoverPresentationController.sourceView = sender;
            
            [self presentViewController:nav animated:YES completion:^{
                // Re-enable button after presentation completes
                sender.enabled = YES;
            }];
        } else {
            // If there's no active task or the task is cancelled, start a new download
            self.task = nil;
            self.progressVC = nil;
            
            // Launch Minecraft
            [self launchMinecraft:sender];
            
            // Button will be re-enabled by completion handler or error handler
        }
    });
}


- (void)observeValueForKeyPath:(NSString *)keyPath ofObject:(id)object change:(NSDictionary *)change context:(void *)context {
    if (context != ProgressObserverContext) {
        [super observeValueForKeyPath:keyPath ofObject:object change:change context:context];
        return;
    }
    
    // Calculate download speed and ETA
    static CGFloat lastMsTime;
    static NSUInteger lastSecTime, lastCompletedUnitCount;
    NSProgress *progress = self.task.textProgress;
    struct timeval tv;
    gettimeofday(&tv, NULL); 
    NSInteger completedUnitCount = self.task.progress.totalUnitCount * self.task.progress.fractionCompleted;
    progress.completedUnitCount = completedUnitCount;
    if (lastSecTime < tv.tv_sec) {
        CGFloat currentTime = tv.tv_sec + tv.tv_usec / 1000000.0;
        NSInteger throughput = (completedUnitCount - lastCompletedUnitCount) / (currentTime - lastMsTime);
        progress.throughput = @(throughput);
        progress.estimatedTimeRemaining = @((progress.totalUnitCount - completedUnitCount) / MAX(1, throughput));
        lastCompletedUnitCount = completedUnitCount;
        lastSecTime = tv.tv_sec;
        lastMsTime = currentTime;
    }

    dispatch_async(dispatch_get_main_queue(), ^{
        // Update progress text display
        self.progressText.text = progress.localizedAdditionalDescription;

        // Check if download has finished
        BOOL isFinished = NO;
        @try {
            isFinished = progress.finished || progress.fractionCompleted >= 1.0;
        } @catch (NSException *exception) {
            NSLog(@"[MCDL] Exception checking progress status: %@", exception);
            isFinished = NO;
        }
        
        // If not finished, exit early
        if (!isFinished) return;
        
        NSLog(@"[MCDL] Download completed");
        
        // Dismiss progress view controller if it's open
        if (self.progressVC) {
            [self.progressVC dismissViewControllerAnimated:NO completion:nil];
        }

        // Clear progress observation
        self.progressViewMain.observedProgress = nil;
        
        // Critical: Check if this was a modpack installation
        BOOL isModpackInstall = NO;
        if (self.task.metadata && self.task.metadata[@"isModpackInstall"]) {
            isModpackInstall = [self.task.metadata[@"isModpackInstall"] boolValue];
        }
        
        NSLog(@"[MCDL] isModpackInstall: %d, has metadata: %@", 
              isModpackInstall, self.task.metadata ? @"YES" : @"NO");
        
        // Make a copy of the metadata before clearing the task
        NSDictionary *metadata = nil;
        if (self.task.metadata) {
            metadata = [self.task.metadata copy];
        }
        
        // Get a reference to the progress before clearing the task
        NSProgress *taskProgress = self.task.progress;
        
        // Clear task reference
        MinecraftResourceDownloadTask *completedTask = self.task;
        self.task = nil;
        self.progressVC = nil;
        
        // Remove observer safely
        @try {
            [taskProgress removeObserver:self forKeyPath:@"fractionCompleted"];
        } @catch (NSException *exception) {
            NSLog(@"[MCDL] Exception removing progress observer: %@", exception);
        }
        
        // Launch the game if it's not a modpack installation and we have metadata
        if (metadata && !isModpackInstall) {
            [self invokeAfterJITEnabled:^{
                UIKit_launchMinecraftSurfaceVC(self.view.window, metadata);
            }];
        } else {
            // Otherwise just re-enable UI
            [self setInteractionEnabled:YES forDownloading:YES];
            [self reloadProfileList];
        }
    });
}

- (void)receiveNotification:(NSNotification *)notification {
    if (![notification.name isEqualToString:@"InstallModpack"]) {
        return;
    }
    
    // Disable UI during download
    [self setInteractionEnabled:NO forDownloading:YES];
    
    // Create a new download task
    self.task = [MinecraftResourceDownloadTask new];
    
    // Set up error handler
    __weak LauncherNavigationController *weakSelf = self;
    self.task.handleError = ^{
        dispatch_async(dispatch_get_main_queue(), ^{
            [weakSelf setInteractionEnabled:YES forDownloading:YES];
            weakSelf.task = nil;
            weakSelf.progressVC = nil;
        });
    };
    
    // Set up progress tracking
    self.progressViewMain.observedProgress = self.task.progress;
    
    // Add observer for progress updates
    @try {
        [self.task.progress addObserver:self
                            forKeyPath:@"fractionCompleted"
                               options:NSKeyValueObservingOptionInitial
                               context:ProgressObserverContext];
    } @catch (NSException *exception) {
        NSLog(@"[MCDL] Exception adding progress observer: %@", exception);
    }
    
    // Get data from notification
    NSDictionary *userInfo = [notification.userInfo copy];
    id notificationObject = notification.object;
    
    // Start modpack download in background
    dispatch_async(dispatch_get_global_queue(DISPATCH_QUEUE_PRIORITY_DEFAULT, 0), ^{
        // Safety check that task hasn't been cleared
        if (!weakSelf.task) {
            return;
        }
        
        // Explicitly mark this as a modpack installation
        if (!self.task.metadata) {
            self.task.metadata = [NSMutableDictionary dictionary];
        }
        self.task.metadata[@"isModpackInstall"] = @YES;
        
        // Start the download
        [weakSelf.task downloadModpackFromAPI:notificationObject 
                               detail:userInfo[@"detail"] 
                              atIndex:[userInfo[@"index"] unsignedLongValue]];
    });
}

- (void)invokeAfterJITEnabled:(void(^)(void))handler {
    localVersionList = remoteVersionList = nil;
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
/* TODO:
    UIAlertAction *cancel = [UIAlertAction actionWithTitle:localize(@"Cancel", nil) style:UIAlertActionStyleCancel handler:^{
        
    }];
    [alert addAction:cancel];
*/
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

#pragma mark - UIPopoverPresentationControllerDelegate
- (UIModalPresentationStyle)adaptivePresentationStyleForPresentationController:(UIPresentationController *)controller traitCollection:(UITraitCollection *)traitCollection {
    return UIModalPresentationNone;
}

#pragma mark - UIPickerView stuff
- (void)pickerView:(PLPickerView *)pickerView didSelectRow:(NSInteger)row inComponent:(NSInteger)component {
    self.profileSelectedAt = row;
    //((UIImageView *)self.versionTextField.leftView).image = [pickerView imageAtRow:row column:component];
    ((UIImageView *)self.versionTextField.leftView).image = [pickerView imageAtRow:row column:component];
    self.versionTextField.text = [self pickerView:pickerView titleForRow:row forComponent:component];
    PLProfiles.current.selectedProfileName = self.versionTextField.text;
}

- (NSInteger)numberOfComponentsInPickerView:(UIPickerView *)pickerView {
    return 1;
}

- (NSInteger)pickerView:(UIPickerView *)pickerView numberOfRowsInComponent:(NSInteger)component {
    return PLProfiles.current.profiles.count;
}

- (NSString *)pickerView:(UIPickerView *)pickerView titleForRow:(NSInteger)row forComponent:(NSInteger)component {
    return PLProfiles.current.profiles.allValues[row][@"name"];
}

- (void)pickerView:(UIPickerView *)pickerView enumerateImageView:(UIImageView *)imageView forRow:(NSInteger)row forComponent:(NSInteger)component {
    UIImage *fallbackImage = [[UIImage imageNamed:@"DefaultProfile"] _imageWithSize:CGSizeMake(40, 40)];
    NSString *urlString = PLProfiles.current.profiles.allValues[row][@"icon"];
    [imageView setImageWithURL:[NSURL URLWithString:urlString] placeholderImage:fallbackImage];
}

- (void)versionClosePicker {
    [self.versionTextField endEditing:YES];
    [self pickerView:self.versionPickerView didSelectRow:[self.versionPickerView selectedRowInComponent:0] inComponent:0];
}

#pragma mark - View controller UI mode

- (BOOL)prefersHomeIndicatorAutoHidden {
    return YES;
}

- (void)viewDidLayoutSubviews {
    [super viewDidLayoutSubviews];
    [sidebarViewController updateAccountInfo];
}

@end

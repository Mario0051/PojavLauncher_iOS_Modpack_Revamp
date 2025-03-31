#import <UniformTypeIdentifiers/UniformTypeIdentifiers.h>
#import <objc/runtime.h>
#import "authenticator/BaseAuthenticator.h"
#import "AFNetworking.h"
#import "ALTServerConnection.h"
#import "CustomControlsViewController.h"
#import "DownloadProgressViewController.h"
#import "JavaGUIViewController.h"
#import "LauncherMenuViewController.h" // Import the specific header
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
     if (!versionListLock) {
         versionListLock = [[NSLock alloc] init];
     }


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

     // Add sub progress view below main one
     self.progressViewSub = [[UIProgressView alloc] initWithFrame:CGRectMake(0, 4, self.toolbar.frame.size.width, 2)]; // Positioned below main
     self.progressViewSub.autoresizingMask = AUTORESIZE_MASKS;
     self.progressViewSub.hidden = YES;
     self.progressViewSub.progressTintColor = [UIColor systemGreenColor]; // Different color for sub-tasks
     [targetToolbar addSubview:self.progressViewSub];

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
         // Determine type based on name (crude but works for basic distinction)
         NSString *type = @"custom"; // Default to custom
         if ([versionId containsString:@"-alpha"]) type = @"old_alpha";
         else if ([versionId containsString:@"-beta"]) type = @"old_beta";
         else if ([versionId containsString:@"w"] || [versionId containsString:@"-pre"] || [versionId containsString:@"-rc"]) type = @"snapshot";
         else {
             // Simple check for release format (e.g., 1.X.Y or 1.X)
             NSRegularExpression *releaseRegex = [NSRegularExpression regularExpressionWithPattern:@"^\\d+\\.\\d+(\\.\\d+)?$" options:0 error:nil];
             if ([releaseRegex firstMatchInString:versionId options:0 range:NSMakeRange(0, versionId.length)]) {
                 type = @"release";
             }
         }


         NSDictionary *versionDict = @{
             @"id": versionId,
             @"type": type
         };

         [tempVersionList addObject:versionDict];
     }

     // Now safely update the shared global array
     [versionListLock lock];
     [localVersionList removeAllObjects];
     [localVersionList addObjectsFromArray:tempVersionList];
     // Sort local versions by release time (newest first) - requires reading JSON, defer if too slow
     [localVersionList sortUsingComparator:^NSComparisonResult(NSDictionary* obj1, NSDictionary* obj2) {
         // Basic string comparison as fallback if releaseTime isn't available
         return [obj2[@"id"] compare:obj1[@"id"] options:NSNumericSearch];
     }];
     [versionListLock unlock];

     // Request UI reload on main thread
     dispatch_async(dispatch_get_main_queue(), ^{
         [self.versionPickerView reloadAllComponents];
     });
}


- (void)fetchRemoteVersionList {
    self.buttonInstall.enabled = NO;

    [versionListLock lock];
     if (!remoteVersionList) {
         remoteVersionList = @[
             @{@"id": @"latest-release", @"type": @"release"},
             @{@"id": @"latest-snapshot", @"type": @"snapshot"}
         ].mutableCopy;
     } else {
         // Clear existing remote versions except latest markers
         if (remoteVersionList.count > 2) { // Ensure we don't remove the markers
            [remoteVersionList removeObjectsInRange:NSMakeRange(2, remoteVersionList.count - 2)];
         }
     }
    [versionListLock unlock];


    AFHTTPSessionManager *manager = [AFHTTPSessionManager manager];
    [manager GET:@"https://piston-meta.mojang.com/mc/game/version_manifest_v2.json" parameters:nil headers:nil progress:^(NSProgress * _Nonnull progress) {
         dispatch_async(dispatch_get_main_queue(), ^{
             self.progressViewMain.progress = progress.fractionCompleted;
         });
    } success:^(NSURLSessionTask *task, NSDictionary *responseObject) {
        [versionListLock lock];
        NSArray *versions = responseObject[@"versions"];
        if (versions && [versions isKindOfClass:[NSArray class]]) {
            [remoteVersionList addObjectsFromArray:versions];
        }
        NSLog(@"[VersionList] Got %lu remote versions", (unsigned long)(versions ? versions.count : 0));

        NSDictionary* latest = responseObject[@"latest"];
        if (latest && [latest isKindOfClass:[NSDictionary class]]) {
             setPrefObject(@"internal.latest_version.release", latest[@"release"]);
             setPrefObject(@"internal.latest_version.snapshot", latest[@"snapshot"]);
        }
        [versionListLock unlock];

        dispatch_async(dispatch_get_main_queue(), ^{
             self.buttonInstall.enabled = YES;
             [self.versionPickerView reloadAllComponents]; // Reload picker after fetching
        });
    } failure:^(NSURLSessionTask *operation, NSError *error) {
        NSLog(@"[VersionList] Warning: Unable to fetch version list: %@", error.localizedDescription);
        dispatch_async(dispatch_get_main_queue(), ^{
            self.buttonInstall.enabled = YES;
            // Optionally show an error to the user here
        });
    }];
}


// Invoked by: startup, instance change event
- (void)reloadProfileList {
    // Reload local version list
    [self fetchLocalVersionList];
    // Reload launcher_profiles.json
    [PLProfiles updateCurrent];

     // Ensure picker view and text field are updated on the main thread
     dispatch_async(dispatch_get_main_queue(), ^{
         [self.versionPickerView reloadAllComponents];
         // Reload selected profile info
         self.profileSelectedAt = [PLProfiles.current.profiles.allKeys indexOfObject:PLProfiles.current.selectedProfileName];
         if (self.profileSelectedAt == NSNotFound) {
             // If selected profile not found (e.g., deleted), select the first one
             self.profileSelectedAt = 0;
             if (PLProfiles.current.profiles.count > 0) {
                 PLProfiles.current.selectedProfileName = PLProfiles.current.profiles.allKeys[0];
                 [PLProfiles.current save]; // Save the change
             } else {
                 // Handle case with no profiles at all
                 self.versionTextField.text = @"";
                 ((UIImageView *)self.versionTextField.leftView).image = [UIImage imageNamed:@"DefaultProfile"];
                 self.buttonInstall.enabled = NO; // Disable play if no profiles
                 return;
             }
         }

         // Ensure selection is valid before proceeding
         if (self.profileSelectedAt < PLProfiles.current.profiles.count) {
             [self.versionPickerView selectRow:self.profileSelectedAt inComponent:0 animated:NO];
             // Manually trigger the update logic after selecting the row
             [self pickerView:self.versionPickerView didSelectRow:self.profileSelectedAt inComponent:0];
             self.buttonInstall.enabled = YES; // Re-enable button if a profile is selected
         } else {
             // Handle inconsistency if profileSelectedAt is out of bounds
             self.versionTextField.text = @"";
             ((UIImageView *)self.versionTextField.leftView).image = [UIImage imageNamed:@"DefaultProfile"];
             self.buttonInstall.enabled = NO;
             NSLog(@"[LauncherNav] Warning: profileSelectedAt index out of bounds after reload.");
         }
     });
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
    [vc setHitEnterAfterWindowShown:hitEnter]; // Use setter method
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
    dispatch_async(dispatch_get_main_queue(), ^{
         for (UIControl *view in self.toolbar.subviews) {
             if ([view isKindOfClass:UIControl.class]) {
                 view.alpha = enabled ? 1 : 0.2;
                 view.enabled = enabled;
             }
         }
         self.progressViewMain.hidden = enabled;
         self.progressViewSub.hidden = enabled; // Hide sub progress as well
         self.progressText.text = nil;
         if (downloading) {
             [self.buttonInstall setTitle:localize(enabled ? @"Play" : @"Details", nil) forState:UIControlStateNormal];
             self.buttonInstall.alpha = 1;
             self.buttonInstall.enabled = YES; // Keep details button enabled during download
         }
         // Allow idle timer only when not downloading/launching
         UIApplication.sharedApplication.idleTimerDisabled = !enabled;
    });
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
         // Ensure sidebarViewController is correctly obtained
         LauncherMenuViewController *sidebarVC = sidebarViewController; // Use the macro which should cast correctly
         if (sidebarVC) {
             [sidebarVC selectAccount:sender]; // Call the method directly
         } else {
             NSLog(@"[LauncherNav] Error: Could not find sidebarViewController to present account selection.");
             showDialog(@"Account Error", @"Please select an account first.");
         }
        return;
    }


    // Disable UI during download
    [self setInteractionEnabled:NO forDownloading:YES];

    // Get the version ID from the selected profile
    NSString *selectedProfileName = self.versionTextField.text;
    NSString *versionId = nil;

     // Safely access profile data
     @try {
         NSDictionary *profile = PLProfiles.current.profiles[selectedProfileName];
         if (profile) {
             versionId = profile[@"lastVersionId"];
         }
     } @catch (NSException *exception) {
         NSLog(@"[LauncherNav] Error accessing profile '%@': %@", selectedProfileName, exception);
         [self setInteractionEnabled:YES forDownloading:NO]; // Re-enable UI on error
         showDialog(@"Profile Error", @"Could not load profile data.");
         return;
     }


    if (!versionId || versionId.length == 0) {
         NSLog(@"[LauncherNav] Error: No version ID found for profile '%@'", selectedProfileName);
         [self setInteractionEnabled:YES forDownloading:NO]; // Re-enable UI
         showDialog(@"Version Error", @"No version selected for this profile.");
         return;
     }

    // Thread-safely access the version list
    NSDictionary *object = nil;
    [versionListLock lock];
     if (remoteVersionList) {
         // Create a safe copy for filtering
         NSArray *safeRemoteList = [remoteVersionList copy];
         object = [safeRemoteList filteredArrayUsingPredicate:
                   [NSPredicate predicateWithFormat:@"(id == %@)", versionId]].firstObject;
     }
    [versionListLock unlock];


    // If not found in remote list, create a custom version object
    if (!object) {
        object = @{
            @"id": versionId,
            @"type": @"custom" // Assume custom if not found remotely
        };
    }

    NSLog(@"[MCDL] Starting download for version: %@", versionId);

    // Create the download task
     // Use synchronized block for task creation/access
     @synchronized(self) {
         // Ensure any previous task observer is removed first
         if (self.task && self.task.progress) {
             @try {
                 [self.task.progress removeObserver:self forKeyPath:@"fractionCompleted"];
             } @catch(NSException *e) {}
         }
         self.task = [MinecraftResourceDownloadTask new];
     }


    // Set up error handler with weak self reference to avoid memory leaks
    __weak LauncherNavigationController *weakSelf = self;
    self.task.handleError = ^{
        dispatch_async(dispatch_get_main_queue(), ^{
             // Check if weakSelf is still valid
             if (!weakSelf) return;
            [weakSelf setInteractionEnabled:YES forDownloading:YES]; // Re-enable interaction fully
             @synchronized(weakSelf) { // Synchronize access
                 weakSelf.task = nil;
                 weakSelf.progressVC = nil;
             }
        });
    };

    // Start download process in background
    dispatch_async(dispatch_get_global_queue(DISPATCH_QUEUE_PRIORITY_DEFAULT, 0), ^{
        // Explicitly mark this as NOT a modpack installation
         @synchronized(weakSelf.task) { // Synchronize access to task properties
             if (!weakSelf.task) return; // Check if task was cleared
             if (!weakSelf.task.metadata) {
                 weakSelf.task.metadata = [NSMutableDictionary dictionary];
             }
             weakSelf.task.metadata[@"isModpackInstall"] = @NO;
         }


        // Start the download process
        [weakSelf.task downloadVersion:object];

        // Set up progress tracking on main thread
        dispatch_async(dispatch_get_main_queue(), ^{
            // Skip if task was cancelled or cleared
             // Check weakSelf and task validity again
             if (!weakSelf) return;
             @synchronized(weakSelf) {
                 if (!weakSelf.task || !weakSelf.task.progress) return;

                 // Connect progress bar to task progress
                 weakSelf.progressViewMain.observedProgress = weakSelf.task.progress;
                  weakSelf.progressViewSub.observedProgress = weakSelf.task.textProgress; // Observe textProgress for sub view


                 // Add observer for progress updates
                 @try {
                     [weakSelf.task.progress addObserver:weakSelf
                                          forKeyPath:@"fractionCompleted"
                                             options:NSKeyValueObservingOptionInitial | NSKeyValueObservingOptionNew // Add New option
                                             context:ProgressObserverContext];
                 } @catch (NSException *exception) {
                     NSLog(@"[MCDL] Exception adding progress observer: %@", exception);
                      // Attempt cleanup if observer fails
                      [weakSelf setInteractionEnabled:YES forDownloading:YES]; // Re-enable fully
                      weakSelf.task = nil;
                      weakSelf.progressVC = nil;
                 }
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
         BOOL taskIsActive = NO;
         @synchronized(self) { // Synchronize access to self.task
             if (self.task && self.task.progress && !self.task.progress.cancelled) {
                 taskIsActive = YES;
             }
         }


        if (taskIsActive) {
            // Show download details view
            if (!self.progressVC) {
                // Ensure task is valid before creating VC
                 @synchronized(self) {
                     if (self.task) {
                         self.progressVC = [[DownloadProgressViewController alloc] initWithTask:self.task];
                     }
                 }
            }

            if (self.progressVC) {
                 // Present progress view in a popover
                 UINavigationController *nav = [[UINavigationController alloc] initWithRootViewController:self.progressVC];
                 nav.modalPresentationStyle = UIModalPresentationPopover;
                 // Ensure sender (button) is valid before accessing its properties
                 if (sender && sender.window) {
                     nav.popoverPresentationController.sourceView = sender;
                     nav.popoverPresentationController.sourceRect = sender.bounds;
                     [self presentViewController:nav animated:YES completion:^{
                          // Re-enable button after presentation completes
                          sender.enabled = YES;
                     }];
                 } else {
                     NSLog(@"[LauncherNav] Warning: Cannot present progress VC, source button is invalid.");
                     sender.enabled = YES; // Re-enable button if presentation fails
                 }
            } else {
                 NSLog(@"[LauncherNav] Warning: Failed to create progressVC.");
                 sender.enabled = YES; // Re-enable button if progressVC creation fails
            }
        } else {
            // If there's no active task or the task is cancelled, start a new download
             @synchronized(self) {
                 self.task = nil;
                 self.progressVC = nil;
             }


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

     // Use weakSelf pattern inside the block
     __weak typeof(self) weakSelf = self;

    dispatch_async(dispatch_get_main_queue(), ^{
         // Ensure self is still valid
         if (!weakSelf) return;

         // Safely access task and progress
         MinecraftResourceDownloadTask *observedTask = nil;
         NSProgress *observedProgress = nil;
         @synchronized(weakSelf) {
             observedTask = weakSelf.task;
             if (observedTask) {
                 observedProgress = observedTask.progress;
             }
         }

         // Check if the observed object matches the current task's progress
         if (!observedTask || object != observedProgress) {
             NSLog(@"[MCDL] Received progress update for an old or invalid task. Ignoring.");
             return; // Ignore updates from old tasks
         }

         // Calculate download speed and ETA - Use textProgress for UI text
         NSProgress *textProgress = observedTask.textProgress;
         if (textProgress) {
             static CGFloat lastMsTime;
             static NSUInteger lastSecTime, lastCompletedUnitCount;
             struct timeval tv;
             gettimeofday(&tv, NULL);
             // Use the main progress's completed count for calculations
             NSInteger completedUnitCount = (NSInteger)(observedProgress.totalUnitCount * observedProgress.fractionCompleted);
             // Update textProgress completed count safely
             @try { textProgress.completedUnitCount = completedUnitCount; } @catch(NSException* e){}


             // Calculate throughput only if time has passed
             CGFloat currentTime = tv.tv_sec + tv.tv_usec / 1000000.0;
             if (lastSecTime < tv.tv_sec && currentTime > lastMsTime) { // Prevent division by zero or negative time diff
                 NSInteger throughput = (completedUnitCount - lastCompletedUnitCount) / (currentTime - lastMsTime);
                 @try { textProgress.throughput = @(throughput); } @catch(NSException* e){}
                 // Avoid division by zero for ETA
                  @try { textProgress.estimatedTimeRemaining = (throughput > 0) ? @((textProgress.totalUnitCount - completedUnitCount) / throughput) : @(DBL_MAX); } @catch(NSException* e){}
                 lastCompletedUnitCount = completedUnitCount;
                 lastSecTime = tv.tv_sec;
                 lastMsTime = currentTime;
             } else if (lastSecTime == 0) { // Initialize times on first update
                  lastCompletedUnitCount = completedUnitCount;
                  lastSecTime = tv.tv_sec;
                  lastMsTime = currentTime;
             }
             // Update progress text display
             weakSelf.progressText.text = textProgress.localizedAdditionalDescription;
         }


        // Check if download has finished using the more reliable flag
        BOOL isTrulyFinished = NO;
         @synchronized(observedTask) {
             isTrulyFinished = observedTask.isDownloadPhaseComplete; // Use the new flag
         }


        // If not finished, exit early
        if (!isTrulyFinished) return;

        NSLog(@"[MCDL] Download phase reported as complete.");

        // Dismiss progress view controller if it's open
        if (weakSelf.progressVC) {
            // Ensure dismissal happens on the main thread
             dispatch_async(dispatch_get_main_queue(), ^{
                 [weakSelf.progressVC dismissViewControllerAnimated:NO completion:nil];
             });
        }


        // Clear progress observation
         dispatch_async(dispatch_get_main_queue(), ^{
             weakSelf.progressViewMain.observedProgress = nil;
             weakSelf.progressViewSub.observedProgress = nil;
         });


        // Critical: Check if this was a modpack installation
        BOOL isModpackInstall = NO;
        NSDictionary *metadataCopy = nil; // Copy metadata *before* clearing task

         @synchronized(observedTask) {
             if (observedTask.metadata && observedTask.metadata[@"isModpackInstall"]) {
                 isModpackInstall = [observedTask.metadata[@"isModpackInstall"] boolValue];
             }
             // Make a deep copy if metadata is complex, otherwise shallow copy is okay for simple dictionaries
             metadataCopy = [observedTask.metadata copy];
         }


        NSLog(@"[MCDL] isModpackInstall: %d, has metadata: %@",
              isModpackInstall, metadataCopy ? @"YES" : @"NO");

        // Clear task reference *after* copying metadata
         MinecraftResourceDownloadTask *completedTask = nil;
         @synchronized(weakSelf) {
             completedTask = weakSelf.task; // Keep ref for observer removal
             weakSelf.task = nil;
             weakSelf.progressVC = nil;
         }


        // Remove observer safely using the completedTask reference
        @try {
            if (completedTask && completedTask.progress) {
                [completedTask.progress removeObserver:weakSelf forKeyPath:@"fractionCompleted"];
            }
        } @catch (NSException *exception) {
            NSLog(@"[MCDL] Exception removing progress observer: %@", exception);
        }

        // Launch the game if it's not a modpack installation and we have metadata
        if (metadataCopy && !isModpackInstall) {
             // Ensure we have metadata before launching
             if (metadataCopy[@"id"]) { // Check for a key expected in Minecraft metadata
                 [weakSelf invokeAfterJITEnabled:^{
                      UIKit_launchMinecraftSurfaceVC(weakSelf.view.window, metadataCopy);
                 }];
             } else {
                 NSLog(@"[MCDL] Error: Metadata missing required information for launch.");
                 [weakSelf setInteractionEnabled:YES forDownloading:YES]; // Re-enable UI
                 showDialog(@"Launch Error", @"Failed to prepare game data for launch.");
             }
        } else {
            // Otherwise just re-enable UI
            [weakSelf setInteractionEnabled:YES forDownloading:YES]; // Re-enable fully
            [weakSelf reloadProfileList];
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
     @synchronized(self) {
         // Ensure any previous task's observer is removed first
         if (self.task && self.task.progress) {
             @try {
                 [self.task.progress removeObserver:self forKeyPath:@"fractionCompleted"];
             } @catch (NSException *exception) {}
         }
         self.task = [MinecraftResourceDownloadTask new];
     }


    // Set up error handler
    __weak LauncherNavigationController *weakSelf = self;
    self.task.handleError = ^{
        dispatch_async(dispatch_get_main_queue(), ^{
             if (!weakSelf) return;
            [weakSelf setInteractionEnabled:YES forDownloading:YES]; // Re-enable fully
             @synchronized(weakSelf) { // Synchronize access
                 weakSelf.task = nil;
                 weakSelf.progressVC = nil;
             }
        });
    };

    // Set up progress tracking
    self.progressViewMain.observedProgress = self.task.progress;
     self.progressViewSub.observedProgress = self.task.textProgress;


    // Add observer for progress updates
    @try {
        [self.task.progress addObserver:self
                            forKeyPath:@"fractionCompleted"
                               options:NSKeyValueObservingOptionInitial | NSKeyValueObservingOptionNew
                               context:ProgressObserverContext];
    } @catch (NSException *exception) {
        NSLog(@"[MCDL] Exception adding progress observer for modpack: %@", exception);
         // Cleanup on failure
         [self setInteractionEnabled:YES forDownloading:YES];
         self.task = nil;
         return;
    }


    // Get data from notification
    NSDictionary *userInfo = [notification.userInfo copy];
    id notificationObject = notification.object;

    // Start modpack download in background
    dispatch_async(dispatch_get_global_queue(DISPATCH_QUEUE_PRIORITY_DEFAULT, 0), ^{
        // Safety check that task hasn't been cleared
         @synchronized(weakSelf.task) {
             if (!weakSelf.task) {
                 NSLog(@"[MCDL] Modpack download cancelled before starting.");
                 return;
             }
             // Explicitly mark this as a modpack installation
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


- (void)invokeAfterJITEnabled:(void(^)(void))handler {
     // Clear version lists immediately to prevent access during launch prep
     [versionListLock lock];
     localVersionList = nil;
     remoteVersionList = nil;
     [versionListLock unlock];


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
/* TODO: Cancel button? Would need to cancel the launchMinecraft flow.
    UIAlertAction *cancel = [UIAlertAction actionWithTitle:localize(@"Cancel", nil) style:UIAlertActionStyleCancel handler:^(UIAlertAction * _Nonnull action) {
         [self setInteractionEnabled:YES forDownloading:YES]; // Re-enable UI if cancelled
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
     if (row >= PLProfiles.current.profiles.count) {
         NSLog(@"[LauncherNav] Warning: Selected row %ld is out of bounds for profiles (%lu)", (long)row, (unsigned long)PLProfiles.current.profiles.count);
         return;
     }
    self.profileSelectedAt = row;
     // Safely get profile name
     NSString *profileName = PLProfiles.current.profiles.allKeys[row];
     self.versionTextField.text = profileName;
     ((UIImageView *)self.versionTextField.leftView).image = [pickerView imageAtRow:row column:component];
    PLProfiles.current.selectedProfileName = profileName; // Update selected profile name
}


- (NSInteger)numberOfComponentsInPickerView:(UIPickerView *)pickerView {
    return 1;
}

- (NSInteger)pickerView:(UIPickerView *)pickerView numberOfRowsInComponent:(NSInteger)component {
    return PLProfiles.current.profiles.count;
}

- (NSString *)pickerView:(UIPickerView *)pickerView titleForRow:(NSInteger)row forComponent:(NSInteger)component {
     if (row >= PLProfiles.current.profiles.count) {
         return @"Error"; // Should not happen
     }
    return PLProfiles.current.profiles.allValues[row][@"name"];
}

- (void)pickerView:(UIPickerView *)pickerView enumerateImageView:(UIImageView *)imageView forRow:(NSInteger)row forComponent:(NSInteger)component {
     if (row >= PLProfiles.current.profiles.count) {
         imageView.image = [[UIImage imageNamed:@"DefaultProfile"] _imageWithSize:CGSizeMake(40, 40)];
         return; // Avoid out-of-bounds access
     }
    UIImage *fallbackImage = [[UIImage imageNamed:@"DefaultProfile"] _imageWithSize:CGSizeMake(40, 40)];
    NSString *urlString = PLProfiles.current.profiles.allValues[row][@"icon"];
    [imageView setImageWithURL:[NSURL URLWithString:urlString] placeholderImage:fallbackImage];
}

- (void)versionClosePicker {
    [self.versionTextField endEditing:YES];
    // Ensure the selected row is valid before calling didSelectRow
     NSInteger selectedRow = [self.versionPickerView selectedRowInComponent:0];
     if (selectedRow >= 0 && selectedRow < [self pickerView:self.versionPickerView numberOfRowsInComponent:0]) {
         [self pickerView:self.versionPickerView didSelectRow:selectedRow inComponent:0];
     } else {
         // Handle case where selection might be invalid (e.g., list reloaded)
         // Select the first row if available
         if ([self pickerView:self.versionPickerView numberOfRowsInComponent:0] > 0) {
             [self.versionPickerView selectRow:0 inComponent:0 animated:NO];
             [self pickerView:self.versionPickerView didSelectRow:0 inComponent:0];
         } else {
             // Handle case where there are no rows
             self.versionTextField.text = @"";
             ((UIImageView *)self.versionTextField.leftView).image = [UIImage imageNamed:@"DefaultProfile"];
         }
     }
}


#pragma mark - View controller UI mode

- (BOOL)prefersHomeIndicatorAutoHidden {
    return YES;
}

- (void)viewDidLayoutSubviews {
    [super viewDidLayoutSubviews];
     // Update account info in the sidebar safely
     LauncherMenuViewController *sidebarVC = sidebarViewController; // Use the macro
     if (sidebarVC && [sidebarVC isKindOfClass:[LauncherMenuViewController class]]) {
         [sidebarVC updateAccountInfo];
     } else {
        NSLog(@"[LauncherNav] Warning: Could not find or cast sidebarViewController to update account info.");
     }
}


@end

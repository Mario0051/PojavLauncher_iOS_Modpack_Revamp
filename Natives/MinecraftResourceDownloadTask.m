#import "authenticator/BaseAuthenticator.h"
#import "installer/modpack/ModpackAPI.h"
#import "AFNetworking.h"
#import "LauncherNavigationController.h"
#import "LauncherPreferences.h"
#import "MinecraftResourceDownloadTask.h"
#import "MinecraftResourceUtils.h"
#import "ios_uikit_bridge.h"
#import "PLProfiles.h"
#import "utils.h"

#include <CommonCrypto/CommonDigest.h>

// Define constants for better code maintenance
static NSTimeInterval const kDownloadTimeout = 60.0; // 60 seconds timeout
static NSUInteger const kDefaultPlaceholderSize = 100 * 1024; // 100KB default size
static NSTimeInterval const kProgressUpdateInterval = 0.25; // Update progress every 250ms

@interface MinecraftResourceDownloadTask ()
@property (nonatomic, strong) AFURLSessionManager* manager;
@property (nonatomic, assign) DownloadSource currentDownloadSource;
@property (nonatomic, strong) NSMutableDictionary *downloadMetadata;
@property (nonatomic, strong) dispatch_queue_t progressQueue;
@property (nonatomic, strong) NSOperationQueue *backgroundQueue;
@property (nonatomic, strong) NSMutableSet *observedTasks;
@end

@implementation MinecraftResourceDownloadTask

- (instancetype)init {
    self = [super init];
    if (self) {
        // Improve session configuration with better timeout and connectivity settings
        NSURLSessionConfiguration *configuration = [NSURLSessionConfiguration defaultSessionConfiguration];
        configuration.timeoutIntervalForRequest = 300; // 5 minutes
        configuration.timeoutIntervalForResource = 3600; // 1 hour for large downloads
        configuration.waitsForConnectivity = YES;
        configuration.HTTPMaximumConnectionsPerHost = 8; // Increase parallel connections
        configuration.networkServiceType = NSURLNetworkServiceTypeBackground;
        
        self.manager = [[AFURLSessionManager alloc] initWithSessionConfiguration:configuration];
        self.fileList = [NSMutableArray new];
        self.progressList = [NSMutableArray new];
        self.downloadMetadata = [NSMutableDictionary new];
        self.currentDownloadSource = DownloadSourceMinecraft;
        
        // Create dedicated queues for progress tracking and background operations
        self.progressQueue = dispatch_queue_create("com.minecraft.progress", DISPATCH_QUEUE_SERIAL);
        self.backgroundQueue = [[NSOperationQueue alloc] init];
        self.backgroundQueue.maxConcurrentOperationCount = 4;
        
        self.observedTasks = [NSMutableSet new];
    }
    return self;
}

- (void)prepareForDownload {
    // Create a fake progress which is used to update completedUnitCount properly
    self.textProgress = [NSProgress new];
    self.textProgress.kind = NSProgressKindFile;
    self.textProgress.fileOperationKind = NSProgressFileOperationKindDownloading;
    self.textProgress.totalUnitCount = 0; // Start at 0 instead of -1
    self.textProgress.localizedDescription = @"Preparing download...";

    self.progress = [NSProgress new];
    // Don't push 1 byte anymore - start at 0 and adjust properly
    self.progress.totalUnitCount = 0;
    [self.fileList removeAllObjects];
    [self.progressList removeAllObjects];
    
    // Reset download metadata
    [self.downloadMetadata removeAllObjects];
    
    // Reset observed tasks set
    [self.observedTasks removeAllObjects];
}

// New method to provide better file name formatting
- (NSString *)formatDisplayNameForFile:(NSString *)fileName fromSource:(DownloadSource)source {
    // Skip if already formatted
    if ([fileName hasPrefix:@"Downloading"] || 
        [fileName hasPrefix:@"Extracting"] || 
        [fileName hasPrefix:@"Setting"]) {
        return fileName;
    }
    
    NSString *sourcePrefix = @"";
    switch (source) {
        case DownloadSourceModrinth:
            sourcePrefix = @"[Modrinth] ";
            break;
        case DownloadSourceCurseForge:
            sourcePrefix = @"[CurseForge] ";
            break;
        default:
            break;
    }
    
    // Format based on file type
    NSString *fileExt = [fileName pathExtension].lowercaseString;
    if ([fileExt isEqualToString:@"jar"]) {
        return [NSString stringWithFormat:@"%@Mod: %@", sourcePrefix, fileName];
    } else if ([fileExt isEqualToString:@"json"]) {
        return [NSString stringWithFormat:@"%@Config: %@", sourcePrefix, fileName];
    } else {
        return [NSString stringWithFormat:@"%@%@", sourcePrefix, fileName];
    }
}

// Add file to the queue with improved error handling and progress tracking
- (NSURLSessionDownloadTask *)createDownloadTask:(NSString *)url size:(NSUInteger)size sha:(NSString *)sha altName:(NSString *)altName toPath:(NSString *)path {
    return [self createDownloadTask:url size:size sha:sha altName:altName toPath:path success:nil];
}

// Add file to the queue with success callback - significantly improved implementation
- (NSURLSessionDownloadTask *)createDownloadTask:(NSString *)url size:(NSUInteger)size sha:(NSString *)sha altName:(NSString *)altName toPath:(NSString *)path success:(void (^)())success {
    // Safety check for nil URL
    if (!url || url.length == 0) {
        NSLog(@"[MCDL] Error: Attempted to create download task with empty URL for %@", altName ?: path.lastPathComponent);
        return nil;
    }
    
    // Check if file already exists and has valid SHA
    BOOL fileExists = [NSFileManager.defaultManager fileExistsAtPath:path];
    if (fileExists && [self checkSHA:sha forFile:path altName:altName]) {
        NSLog(@"[MCDL] File already exists with matching SHA: %@", altName ?: path.lastPathComponent);
        if (success) success();
        return nil;
    } else if (![self checkAccessWithDialog:YES]) {
        NSLog(@"[MCDL] Access check failed for downloading");
        return nil;
    }

    NSString *displayName = altName ?: path.lastPathComponent;
    displayName = [self formatDisplayNameForFile:displayName fromSource:self.currentDownloadSource];
    
    // Improved URL validation
    NSURL *requestURL = [NSURL URLWithString:url];
    if (!requestURL) {
        NSLog(@"[MCDL] Error: Invalid URL format: %@", url);
        return nil;
    }
    
    NSURLRequest *request = [NSURLRequest requestWithURL:requestURL];
    __block NSProgress *progress;
    __weak typeof(self) weakSelf = self;
    __block NSInteger retryCount = 0;
    
    // Create the download task with improved error handling
    __block NSURLSessionDownloadTask *task = [self.manager downloadTaskWithRequest:request progress:nil
    destination:^NSURL * _Nonnull(NSURL * _Nonnull targetPath, NSURLResponse * _Nonnull response) {
        NSLog(@"[MCDL] Downloading %@", displayName);
        
        // Get progress for the task
        progress = [weakSelf.manager downloadProgressForTask:task];
        
        // If size wasn't provided, get it from the response
        if (!size && task) {
            NSUInteger responseSize = response.expectedContentLength > 0 ? 
                                     (NSUInteger)response.expectedContentLength : 
                                     kDefaultPlaceholderSize;
            
            [weakSelf addDownloadTaskToProgress:task size:responseSize];
            [weakSelf.fileList addObject:displayName];
        }
        
        // Ensure directory exists before trying to write file
        NSString *dirPath = path.stringByDeletingLastPathComponent;
        NSError *dirError = nil;
        if (![NSFileManager.defaultManager fileExistsAtPath:dirPath]) {
            [NSFileManager.defaultManager createDirectoryAtPath:dirPath 
                                   withIntermediateDirectories:YES 
                                                    attributes:nil 
                                                         error:&dirError];
            if (dirError) {
                NSLog(@"[MCDL] Error creating directory for %@: %@", path, dirError);
            }
        }
        
        // Remove existing file to prevent issues
        [NSFileManager.defaultManager removeItemAtPath:path error:nil];
        return [NSURL fileURLWithPath:path];
    } completionHandler:^(NSURLResponse * _Nonnull response, NSURL * _Nullable filePath, NSError * _Nullable error) {
        if (weakSelf.progress.cancelled) {
            // Ignore any further errors if cancelled
            NSLog(@"[MCDL] Download cancelled for %@", displayName);
            return;
        } else if (error != nil) {
            // Check if we should retry (up to 3 times)
            if (retryCount < 3 && (error.code == NSURLErrorTimedOut || 
                                   error.code == NSURLErrorNetworkConnectionLost ||
                                   error.code == NSURLErrorNotConnectedToInternet)) {
                retryCount++;
                NSLog(@"[MCDL] Retrying download for %@ (attempt %ld): %@", displayName, (long)retryCount, error);
                
                // Wait before retrying (exponential backoff)
                NSTimeInterval delay = pow(2.0, retryCount - 1) * 0.5;
                
                dispatch_after(dispatch_time(DISPATCH_TIME_NOW, (int64_t)(delay * NSEC_PER_SEC)), 
                               dispatch_get_global_queue(DISPATCH_QUEUE_PRIORITY_DEFAULT, 0), ^{
                    NSURLSessionDownloadTask *retryTask = [weakSelf.manager downloadTaskWithRequest:request progress:nil destination:^NSURL * _Nonnull(NSURL * _Nonnull targetPath, NSURLResponse * _Nonnull response) {
                        return [NSURL fileURLWithPath:path];
                    } completionHandler:^(NSURLResponse * _Nonnull response, NSURL * _Nullable filePath, NSError * _Nullable error) {
                        [weakSelf removeTaskObserver:task];
                        
                        if (error) {
                            [weakSelf finishDownloadWithError:error file:displayName];
                        } else if (![weakSelf checkSHA:sha forFile:path altName:altName]) {
                            [weakSelf finishDownloadWithErrorString:[NSString stringWithFormat:@"Failed to verify file %@: SHA1 mismatch", path.lastPathComponent]];
                        } else {
                            dispatch_async(weakSelf.progressQueue, ^{
                                // Mark progress as complete
                                if (progress) {
                                    progress.totalUnitCount = progress.completedUnitCount;
                                }
                                if (success) success();
                            });
                        }
                    }];
                    [retryTask resume];
                });
                return;
            }
            
            [weakSelf finishDownloadWithError:error file:displayName];
        } else if (![weakSelf checkSHA:sha forFile:path altName:altName]) {
            [weakSelf finishDownloadWithErrorString:[NSString stringWithFormat:@"Failed to verify file %@: SHA1 mismatch", path.lastPathComponent]];
        } else {
            // Success - mark progress as complete
            dispatch_async(weakSelf.progressQueue, ^{
                if (progress) {
                    progress.totalUnitCount = progress.completedUnitCount;
                }
                if (success) success();
            });
        }
        
        // Remove task observer on completion or error
        [weakSelf removeTaskObserver:task];
    }];

    // After task is created, add it to progress tracking
    if (size && task) {
        [self addDownloadTaskToProgress:task size:size];
        [self.fileList addObject:displayName];
    }

    // Track additional download metadata
    if (task) {
        NSMutableDictionary *taskInfo = [NSMutableDictionary dictionary];
        taskInfo[@"url"] = url;
        taskInfo[@"size"] = @(size);
        taskInfo[@"sha"] = sha ?: @"";
        taskInfo[@"altName"] = displayName;
        taskInfo[@"path"] = path;
        taskInfo[@"source"] = @(self.currentDownloadSource);
        taskInfo[@"originalName"] = altName ?: path.lastPathComponent;
        
        @synchronized(self.downloadMetadata) {
            [self.downloadMetadata setObject:taskInfo forKey:task];
        }
    }

    return task;
}

// Improved progress tracking for download tasks
- (void)addDownloadTaskToProgress:(NSURLSessionDownloadTask *)task size:(NSInteger)size {
    // Work on the progress queue to avoid threading issues
    dispatch_async(self.progressQueue, ^{
        NSProgress *progress = [self.manager downloadProgressForTask:task];
        
        progress.kind = NSProgressKindFile;
        progress.fileOperationKind = NSProgressFileOperationKindDownloading;
        
        // Use a more reasonable initial size estimate if actual size is unavailable
        NSUInteger initialSize = size > 0 ? size : kDefaultPlaceholderSize;
        progress.totalUnitCount = initialSize;
        
        [self.progressList addObject:progress];
        [self.progress addChild:progress withPendingUnitCount:initialSize];
        self.progress.totalUnitCount += initialSize;
        self.textProgress.totalUnitCount = self.progress.totalUnitCount;
        
        // Add observer to update size when Content-Length becomes available
        @synchronized(self.observedTasks) {
            if (![self.observedTasks containsObject:task]) {
                [task addObserver:self forKeyPath:@"countOfBytesExpectedToReceive" options:NSKeyValueObservingOptionNew context:NULL];
                [task addObserver:self forKeyPath:@"response" options:NSKeyValueObservingOptionNew context:NULL];
                [self.observedTasks addObject:task];
            }
        }
    });
}

// Improved progress size update with proper synchronization and error handling
- (void)updateProgressSize:(NSProgress *)progress forTask:(NSURLSessionDownloadTask *)task withSize:(NSUInteger)newSize {
    if (!progress || newSize == 0) {
        return;
    }
    
    // Ensure we're on the progress queue
    dispatch_async(self.progressQueue, ^{
        // Avoid unnecessary updates if size hasn't changed significantly
        if (progress.totalUnitCount == newSize) {
            return;
        }
        
        // Calculate the size difference
        NSInteger sizeDifference = (NSInteger)newSize - (NSInteger)progress.totalUnitCount;
        
        // Log the adjustment we're making
        NSLog(@"[MCDL] Updating size for download: %@ from %lld to %lu bytes", 
              [task.originalRequest.URL lastPathComponent], 
              progress.totalUnitCount, 
              (unsigned long)newSize);
        
        // Update progress size
        progress.totalUnitCount = newSize;
        
        // Update parent progress
        if (self.progress && sizeDifference != 0) {
            // Adjust the parent's total by the difference
            self.progress.totalUnitCount += sizeDifference;
            self.textProgress.totalUnitCount = self.progress.totalUnitCount;
        }
    });
}

// Better KVO handling with proper error management
- (void)observeValueForKeyPath:(NSString *)keyPath ofObject:(id)object change:(NSDictionary<NSKeyValueChangeKey,id> *)change context:(void *)context {
    if ([object isKindOfClass:[NSURLSessionDownloadTask class]]) {
        NSURLSessionDownloadTask *task = (NSURLSessionDownloadTask *)object;
        NSProgress *progress = [self.manager downloadProgressForTask:task];
        
        if (!progress) {
            return;
        }
        
        // Handle size updates from different sources
        if ([keyPath isEqualToString:@"countOfBytesExpectedToReceive"] && task.countOfBytesExpectedToReceive > 0) {
            [self updateProgressSize:progress forTask:task withSize:task.countOfBytesExpectedToReceive];
        }
        else if ([keyPath isEqualToString:@"response"] && [task.response isKindOfClass:[NSHTTPURLResponse class]]) {
            NSHTTPURLResponse *httpResponse = (NSHTTPURLResponse *)task.response;
            NSString *contentLength = [httpResponse.allHeaderFields objectForKey:@"Content-Length"];
            if (contentLength) {
                NSUInteger responseSize = [contentLength longLongValue];
                if (responseSize > 0) {
                    [self updateProgressSize:progress forTask:task withSize:responseSize];
                }
            }
        }
    } else {
        [super observeValueForKeyPath:keyPath ofObject:object change:change context:context];
    }
}

// Cleanup to avoid KVO crashes
- (void)removeTaskObserver:(NSURLSessionDownloadTask *)task {
    @synchronized(self.observedTasks) {
        if ([self.observedTasks containsObject:task]) {
            @try {
                [task removeObserver:self forKeyPath:@"countOfBytesExpectedToReceive"];
                [task removeObserver:self forKeyPath:@"response"];
                [self.observedTasks removeObject:task];
            } @catch (NSException *exception) {
                NSLog(@"[MCDL] Warning: Failed to remove observer: %@", exception);
            }
        }
    }
}

// Improved version metadata download with better error handling
- (void)downloadVersionMetadata:(NSDictionary *)version success:(void (^)())success {
    // Download base json
    NSString *versionStr = version[@"id"];
    if ([versionStr isEqualToString:@"latest-release"]) {
        versionStr = getPrefObject(@"internal.latest_version.release");
    } else if ([versionStr isEqualToString:@"latest-snapshot"]) {
        versionStr = getPrefObject(@"internal.latest_version.snapshot");
    }

    NSString *path = [NSString stringWithFormat:@"%1$s/versions/%2$@/%2$@.json", getenv("POJAV_GAME_DIR"), versionStr];
    // Find it again to resolve latest-*
    version = (id)[MinecraftResourceUtils findVersion:versionStr inList:remoteVersionList];

    void(^completionBlock)(void) = ^{
        self.metadata = parseJSONFromFile(path);
        if (self.metadata[@"NSErrorObject"]) {
            [self finishDownloadWithErrorString:[self.metadata[@"NSErrorObject"] localizedDescription]];
            return;
        }
        if (self.metadata[@"inheritsFrom"]) {
            NSMutableDictionary *inheritsFromDict = parseJSONFromFile([NSString stringWithFormat:@"%1$s/versions/%2$@/%2$@.json", getenv("POJAV_GAME_DIR"), self.metadata[@"inheritsFrom"]]);
            if (inheritsFromDict) {
                [MinecraftResourceUtils processVersion:self.metadata inheritsFrom:inheritsFromDict];
                self.metadata = inheritsFromDict;
            }
        }
        [MinecraftResourceUtils tweakVersionJson:self.metadata];
        success();
    };

    if (!version) {
        // This is likely local version, check if json exists and has inheritsFrom
        NSMutableDictionary *json = parseJSONFromFile(path);
        if (json[@"NSErrorObject"]) {
            [self finishDownloadWithErrorString:[json[@"NSErrorObject"] localizedDescription]];
            return;
        } else if (json[@"inheritsFrom"]) {
            version = (id)[MinecraftResourceUtils findVersion:json[@"inheritsFrom"] inList:remoteVersionList];
            path = [NSString stringWithFormat:@"%1$s/versions/%2$@/%2$@.json", getenv("POJAV_GAME_DIR"), json[@"inheritsFrom"]];
        } else {
            completionBlock();
            return;
        }
    }

    versionStr = version[@"id"];
    NSString *url = version[@"url"];
    NSString *sha = url.stringByDeletingLastPathComponent.lastPathComponent;
    NSUInteger size = [version[@"size"] unsignedLongLongValue];

    NSURLSessionDownloadTask *task = [self createDownloadTask:url size:size sha:sha altName:nil toPath:path success:completionBlock];
    [task resume];
}

// Improved asset metadata download
- (void)downloadAssetMetadataWithSuccess:(void (^)())success {
    NSDictionary *assetIndex = self.metadata[@"assetIndex"];
    if (!assetIndex) {
        success();
        return;
    }
    NSString *name = [NSString stringWithFormat:@"assets/indexes/%@.json", assetIndex[@"id"]];
    NSString *path = [@(getenv("POJAV_GAME_DIR")) stringByAppendingPathComponent:name];
    NSString *url = assetIndex[@"url"];
    NSString *sha = url.stringByDeletingLastPathComponent.lastPathComponent;
    NSUInteger size = [assetIndex[@"size"] unsignedLongLongValue];
    
    NSURLSessionDownloadTask *task = [self createDownloadTask:url size:size sha:sha altName:name toPath:path success:^{
        self.metadata[@"assetIndexObj"] = parseJSONFromFile(path);
        success();
    }];
    [task resume];
}

- (NSArray *)downloadClientLibraries {
    NSMutableArray *tasks = [NSMutableArray new];
    for (NSDictionary *library in self.metadata[@"libraries"]) {
        NSString *name = library[@"name"];

        NSMutableDictionary *artifact = library[@"downloads"][@"artifact"];
        if (artifact == nil && [name containsString:@":"]) {
            NSLog(@"[MCDL] Unknown artifact object for %@, attempting to generate one", name);
            artifact = [[NSMutableDictionary alloc] init];
            NSString *prefix = library[@"url"] == nil ? @"https://libraries.minecraft.net/" : [library[@"url"] stringByReplacingOccurrencesOfString:@"http://" withString:@"https://"];
            NSArray *libParts = [name componentsSeparatedByString:@":"];
            artifact[@"path"] = [NSString stringWithFormat:@"%1$@/%2$@/%3$@/%2$@-%3$@.jar", [libParts[0] stringByReplacingOccurrencesOfString:@"." withString:@"/"], libParts[1], libParts[2]];
            artifact[@"url"] = [NSString stringWithFormat:@"%@%@", prefix, artifact[@"path"]];
            artifact[@"sha1"] = library[@"checksums"][0];
        }

        NSString *path = [NSString stringWithFormat:@"%s/libraries/%@", getenv("POJAV_GAME_DIR"), artifact[@"path"]];
        NSString *sha = artifact[@"sha1"];
        NSUInteger size = [artifact[@"size"] unsignedLongLongValue];
        NSString *url = artifact[@"url"];
        if ([library[@"skip"] boolValue]) {
            NSLog(@"[MDCL] Skipped library %@", name);
            continue;
        }

        NSURLSessionDownloadTask *task = [self createDownloadTask:url size:size sha:sha altName:name toPath:path success:nil];
        if (task) {
            [tasks addObject:task];
        } else if (self.progress.cancelled) {
            return nil;
        }
    }
    return tasks;
}

- (NSArray *)downloadClientAssets {
    NSMutableArray *tasks = [NSMutableArray new];
    NSDictionary *assets = self.metadata[@"assetIndexObj"];
    if (!assets) {
        return @[];
    }
    for (NSString *name in assets[@"objects"]) {
        NSDictionary *object = assets[@"objects"][name];
        NSString *hash = object[@"hash"];
        NSString *pathname = [NSString stringWithFormat:@"%@/%@", [hash substringToIndex:2], hash];
        NSUInteger size = [object[@"size"] unsignedLongLongValue];

        NSString *path;
        if ([assets[@"map_to_resources"] boolValue]) {
            path = [NSString stringWithFormat:@"%s/resources/%@", getenv("POJAV_GAME_DIR"), name];
        } else {
            path = [NSString stringWithFormat:@"%s/assets/objects/%@", getenv("POJAV_GAME_DIR"), pathname];
        }

        /* Special case for 1.19+
         * Since 1.19-pre1, setting the window icon on macOS invokes ObjC.
         * However, if an IOException occurs, it won't try to set.
         * We skip downloading the icon file to workaround this. */
        if ([name hasSuffix:@"/minecraft.icns"]) {
            [NSFileManager.defaultManager removeItemAtPath:path error:nil];
            continue;
        }

        NSString *url = [NSString stringWithFormat:@"https://resources.download.minecraft.net/%@", pathname];
        NSURLSessionDownloadTask *task = [self createDownloadTask:url size:size sha:hash altName:name toPath:path success:nil];
        if (task) {
            [tasks addObject:task];
        } else if (self.progress.cancelled) {
            return nil;
        }
    }
    return tasks;
}

- (void)downloadVersion:(NSDictionary *)version {
    // Set download source to Minecraft
    self.currentDownloadSource = DownloadSourceMinecraft;
    
    [self prepareForDownload];
    [self downloadVersionMetadata:version success:^{
        [self downloadAssetMetadataWithSuccess:^{
            NSArray *libTasks = [self downloadClientLibraries];
            NSArray *assetTasks = [self downloadClientAssets];
            
            // Drop the 1 byte we set initially if we had set it, but now we start at 0 so nothing to drop
            
            if (self.progress.totalUnitCount == 0) {
                // We have nothing to download, invoke completion observer
                self.progress.totalUnitCount = 1;
                self.progress.completedUnitCount = 1;
                self.textProgress.totalUnitCount = 1;
                self.textProgress.completedUnitCount = 1;
                return;
            }
            [libTasks makeObjectsPerformSelector:@selector(resume)];
            [assetTasks makeObjectsPerformSelector:@selector(resume)];
            [self.metadata removeObjectForKey:@"assetIndexObj"];
        }];
    }];
}

- (void)downloadModpackFromAPI:(ModpackAPI *)api detail:(NSDictionary *)modDetail atIndex:(NSUInteger)selectedVersion {
    // Determine the source based on the API type
    if ([api isKindOfClass:NSClassFromString(@"CurseForgeAPI")]) {
        self.currentDownloadSource = DownloadSourceCurseForge;
    } else if ([api isKindOfClass:NSClassFromString(@"ModrinthAPI")]) {
        self.currentDownloadSource = DownloadSourceModrinth;
    } else {
        self.currentDownloadSource = DownloadSourceMinecraft;
    }
    
    [self prepareForDownload];

    NSString *url = modDetail[@"versionUrls"][selectedVersion];
    NSUInteger size = [modDetail[@"versionSizes"][selectedVersion] unsignedLongLongValue];
    NSString *sha = modDetail[@"versionHashes"][selectedVersion];
    NSString *name = [[modDetail[@"title"] lowercaseString] stringByTrimmingCharactersInSet:NSCharacterSet.whitespaceCharacterSet];
    name = [name stringByReplacingOccurrencesOfString:@" " withString:@"_"];
    NSString *packagePath = [NSTemporaryDirectory() stringByAppendingFormat:@"/%@.zip", name];

    // Generate a safe profile name
    NSString *safeProfileName = name;
    // Get the unique game directory path for this profile
    NSString *gameDir = [PLProfiles uniqueGameDirForProfileName:safeProfileName];
    // Get the full installation path
    NSString *path = [PLProfiles fullPathForProfileWithName:safeProfileName gameDir:gameDir];
    // Ensure the directory exists
    [PLProfiles ensureProfileDirectoryExists:safeProfileName gameDir:gameDir];

    NSURLSessionDownloadTask *task = [self createDownloadTask:url size:size sha:sha altName:nil toPath:packagePath success:^{
        [api downloader:self submitDownloadTasksFromPackage:packagePath toPath:path];
    }];
    [task resume];
}

// Better error handling and cleanup
- (void)finishDownloadWithErrorString:(NSString *)error {
    [self.progress cancel];
    
    // Stop all tasks
    [self.manager invalidateSessionCancelingTasks:YES resetSession:YES];
    
    // Always show error dialog on main thread
    dispatch_async(dispatch_get_main_queue(), ^{
        showDialog(localize(@"Error", nil), error);
        
        if (self.handleError) {
            self.handleError();
        }
    });
}

- (void)finishDownloadWithError:(NSError *)error file:(NSString *)file {
    NSString *errorStr = [NSString stringWithFormat:localize(@"launcher.mcl.error_download", NULL), file, error.localizedDescription];
    NSLog(@"[MCDL] Error: %@ %@", errorStr, NSThread.callStackSymbols);
    [self finishDownloadWithErrorString:errorStr];
}

// Check if the account has permission to download
- (BOOL)checkAccessWithDialog:(BOOL)show {
    // for now
    BOOL accessible = [BaseAuthenticator.current.authData[@"username"] hasPrefix:@"Demo."] || BaseAuthenticator.current.authData[@"xboxGamertag"] != nil;
    if (!accessible) {
        [self.progress cancel];
        if (show) {
            [self finishDownloadWithErrorString:@"Minecraft can't be legally installed when logged in with a local account. Please switch to an online account to continue."];
        }
    }
    return accessible;
}

// Check SHA of the file
- (BOOL)checkSHAIgnorePref:(NSString *)sha forFile:(NSString *)path altName:(NSString *)altName logSuccess:(BOOL)logSuccess {
    if (sha.length == 0) {
        // When sha = skip, only check for file existence
        BOOL existence = [NSFileManager.defaultManager fileExistsAtPath:path];
        if (existence) {
            NSLog(@"[MCDL] Warning: couldn't find SHA for %@, have to assume it's good.", path);
        }
        return existence;
    }

    NSData *data = [NSData dataWithContentsOfFile:path];
    if (data == nil) {
        NSLog(@"[MCDL] SHA1 checker: file doesn't exist: %@", altName ? altName : path.lastPathComponent);
        return NO;
    }

    unsigned char digest[CC_SHA1_DIGEST_LENGTH];
    CC_SHA1(data.bytes, (CC_LONG)data.length, digest);
    NSMutableString *localSHA = [NSMutableString stringWithCapacity:CC_SHA1_DIGEST_LENGTH * 2];
    for(int i = 0; i < CC_SHA1_DIGEST_LENGTH; i++) {
        [localSHA appendFormat:@"%02x", digest[i]];
    }

    BOOL check = [sha isEqualToString:localSHA];
    if (!check || (getPrefBool(@"general.debug_logging") && logSuccess)) {
        NSLog(@"[MCDL] SHA1 %@ for %@%@",
          (check ? @"passed" : @"failed"), 
          (altName ? altName : path.lastPathComponent),
          (check ? @"" : [NSString stringWithFormat:@" (expected: %@, got: %@)", sha, localSHA]));
    }
    return check;
}

- (BOOL)checkSHA:(NSString *)sha forFile:(NSString *)path altName:(NSString *)altName logSuccess:(BOOL)logSuccess {
    if (getPrefBool(@"general.check_sha")) {
        return [self checkSHAIgnorePref:sha forFile:path altName:altName logSuccess:logSuccess];
    } else {
        return [NSFileManager.defaultManager fileExistsAtPath:path];
    }
}

- (BOOL)checkSHA:(NSString *)sha forFile:(NSString *)path altName:(NSString *)altName {
    return [self checkSHA:sha forFile:path altName:altName logSuccess:altName==nil];
}

// Tracking and utility methods
- (NSDictionary *)getDownloadTaskInfo:(NSURLSessionDownloadTask *)task {
    return self.downloadMetadata[task];
}

- (NSArray<NSDictionary *> *)getAllDownloadedFiles {
    NSMutableArray *downloadedFiles = [NSMutableArray array];
    
    @synchronized(self.downloadMetadata) {
        for (NSURLSessionDownloadTask *task in self.downloadMetadata.allKeys) {
            NSDictionary *taskInfo = self.downloadMetadata[task];
            if (taskInfo) {
                [downloadedFiles addObject:taskInfo];
            }
        }
    }
    
    return [downloadedFiles copy];
}

- (void)logDownloadSource:(DownloadSource)source {
    NSString *sourceString;
    switch (source) {
        case DownloadSourceMinecraft:
            sourceString = @"Minecraft";
            break;
        case DownloadSourceCurseForge:
            sourceString = @"CurseForge";
            break;
        case DownloadSourceModrinth:
            sourceString = @"Modrinth";
            break;
        default:
            sourceString = @"Unknown";
            break;
    }
    
    NSLog(@"[DownloadTask] Current Download Source: %@", sourceString);
}

// Cleanup on dealloc to prevent KVO crashes
- (void)dealloc {
    // Remove any remaining observers to prevent crashes
    @synchronized(self.observedTasks) {
        for (NSURLSessionDownloadTask *task in self.observedTasks) {
            @try {
                [task removeObserver:self forKeyPath:@"countOfBytesExpectedToReceive"];
                [task removeObserver:self forKeyPath:@"response"];
            } @catch (NSException *exception) {
                // Ignore if observer wasn't registered
            }
        }
        [self.observedTasks removeAllObjects];
    }
}

@end

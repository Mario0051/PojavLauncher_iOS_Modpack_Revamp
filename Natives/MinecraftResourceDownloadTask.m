#include <CommonCrypto/CommonDigest.h>

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

@interface MinecraftResourceDownloadTask ()
@property(nonatomic, readwrite) AFURLSessionManager* manager;
@end

@implementation MinecraftResourceDownloadTask

- (instancetype)init {
    self = [super init];
    // TODO: implement background download
    NSURLSessionConfiguration *configuration = [NSURLSessionConfiguration defaultSessionConfiguration];
    configuration.timeoutIntervalForRequest = 86400;
    //backgroundSessionConfigurationWithIdentifier:@"net.kdt.pojavlauncher.downloadtask"];
    self.manager = [[AFURLSessionManager alloc] initWithSessionConfiguration:configuration];
    self.fileList = [NSMutableArray new];
    self.progressList = [NSMutableArray new];
    
    // Initialize progress tracking
    self.progress = [NSProgress new];
    self.progress.totalUnitCount = 0;
    self.progress.cancellable = YES;
    
    // Initialize text progress for UI updates
    self.textProgress = [NSProgress new];
    self.textProgress.totalUnitCount = 0;
    self.textProgress.cancellable = YES;
    
    return self;
}

- (void)prepareForDownload {
    @synchronized(self) {
        // Reset progress tracking
        self.progress = [NSProgress new];
        self.progress.totalUnitCount = 0; // Start with 0 and add as we go
        self.progress.cancellable = YES;
        
        // Reset text progress for UI
        self.textProgress = [NSProgress new];
        self.textProgress.totalUnitCount = 0;
        self.textProgress.cancellable = YES;
        
        // Reset tracking lists
        [self.fileList removeAllObjects];
        [self.progressList removeAllObjects];
    }
}

- (NSURLSessionDownloadTask *)createDownloadTask:(NSString *)url 
                                           size:(NSUInteger)size 
                                            sha:(NSString *)sha 
                                        altName:(NSString *)altName 
                                         toPath:(NSString *)path 
                                        success:(void (^)(void))success
                                        failure:(void (^)(NSError *error))failure {
    // Check if file already exists and has correct SHA1
    BOOL fileExists = [NSFileManager.defaultManager fileExistsAtPath:path];
    
    if (fileExists && [self checkSHA:sha forFile:path altName:altName]) {
        if (success) {
            success();
        }
        return nil;
    } else if (![self checkAccessWithDialog:YES]) {
        return nil;
    }

    // Use filename as display name if no alternate name provided
    NSString *name = altName ?: path.lastPathComponent;
    
    // Create URL request
    NSURL *requestURL = [NSURL URLWithString:url];
    if (!requestURL) {
        NSLog(@"[MCDL] Error: Invalid download URL: %@", url);
        NSError *urlError = [NSError errorWithDomain:@"net.kdt.pojavlauncher" 
                                                code:1001 
                                            userInfo:@{NSLocalizedDescriptionKey: @"Invalid download URL"}];
        if (failure) {
            failure(urlError);
        } else {
            [self finishDownloadWithErrorString:@"Invalid download URL"];
        }
        return nil;
    }
    
    NSURLRequest *request = [NSURLRequest requestWithURL:requestURL];
    __block NSProgress *progress;
    __block BOOL sizeUpdated = NO;
    
    // Log detailed file information for debugging
    NSLog(@"[MCDL] Creating download task for %@, size: %lu, path: %@", name, (unsigned long)size, path);
    
    // Create download task with proper completion handling
    __block NSURLSessionDownloadTask *task = [self.manager downloadTaskWithRequest:request progress:nil
    destination:^NSURL * _Nonnull(NSURL * _Nonnull targetPath, NSURLResponse * _Nonnull response) {
        NSLog(@"[MCDL] Downloading %@, expected length: %lld", name, response.expectedContentLength);
        
        // Get progress for this task
        progress = [self.manager downloadProgressForTask:task];
        if (!progress) {
            NSLog(@"[MCDL] Warning: Could not get progress for download task %@, creating a new one", name);
            progress = [NSProgress progressWithTotalUnitCount:1];
        }

        // Add to progress tracking with size information
        if (size > 0) {
            [self addDownloadTaskToProgress:task size:size];
            [self.fileList addObject:name];
        } 
        // If no size provided, but response has size info
        else if (response.expectedContentLength > 0) {
            NSUInteger actualSize = (NSUInteger)response.expectedContentLength;
            [self addDownloadTaskToProgress:task size:actualSize];
            [self.fileList addObject:name];
            sizeUpdated = YES;
            NSLog(@"[MCDL] Using response size: %lu for %@", (unsigned long)actualSize, name);
        }
        // If still no size, use a minimum value but we'll update it later
        else {
            [self addDownloadTaskToProgress:task size:1000000]; // Use 1MB as placeholder
            [self.fileList addObject:name];
            NSLog(@"[MCDL] No size available for %@, using placeholder", name);
        }
        
        // Create directory structure if needed
        NSError *dirError;
        BOOL success = [NSFileManager.defaultManager createDirectoryAtPath:path.stringByDeletingLastPathComponent 
                                                withIntermediateDirectories:YES 
                                                                 attributes:nil 
                                                                      error:&dirError];
        if (!success) {
            NSLog(@"[MCDL] Warning: Could not create directory for %@: %@", name, dirError.localizedDescription);
        }
        
        // Remove existing file if it exists
        if ([NSFileManager.defaultManager fileExistsAtPath:path]) {
            NSError *removeError;
            [NSFileManager.defaultManager removeItemAtPath:path error:&removeError];
            if (removeError) {
                NSLog(@"[MCDL] Warning: Could not remove existing file %@: %@", path, removeError.localizedDescription);
            }
        }
        
        return [NSURL fileURLWithPath:path];
    } completionHandler:^(NSURLResponse * _Nonnull response, NSURL * _Nullable filePath, NSError * _Nullable error) {
        // Safely check if progress is cancelled
        BOOL isCancelled = NO;
        @try {
            isCancelled = self.progress.cancelled;
        } @catch (NSException *exception) {
            NSLog(@"[MCDL] Warning: Exception checking if progress is cancelled: %@", exception);
            isCancelled = NO;
        }
        
        if (isCancelled) {
            // Ignore any further errors when cancelled
        } else if (error != nil) {
            NSLog(@"[MCDL] Download error for %@: %@", name, error.localizedDescription);
            if (failure) {
                failure(error);
            } else {
                [self finishDownloadWithError:error file:name];
            }
        } else if (![self checkSHA:sha forFile:path altName:altName]) {
            NSError *shaError = [NSError errorWithDomain:@"net.kdt.pojavlauncher" 
                                                    code:1000 
                                                userInfo:@{NSLocalizedDescriptionKey: [NSString stringWithFormat:@"Failed to verify file %@: SHA1 mismatch", path.lastPathComponent]}];
            if (failure) {
                failure(shaError);
            } else {
                [self finishDownloadWithErrorString:[NSString stringWithFormat:@"Failed to verify file %@: SHA1 mismatch", path.lastPathComponent]];
            }
        } else {
            // If we didn't have an accurate size initially and didn't update it from the response
            if (!sizeUpdated && size == 0 && progress) {
                // Get the actual file size for more accurate progress reporting
                NSError *fileError;
                NSDictionary *fileAttrs = [NSFileManager.defaultManager attributesOfItemAtPath:path error:&fileError];
                if (!fileError && fileAttrs) {
                    NSUInteger fileSize = [fileAttrs fileSize];
                    NSLog(@"[MCDL] Updating progress with actual file size: %lu for %@", (unsigned long)fileSize, name);
                    
                    // Update progress with actual file size - safely
                    @try {
                        if (fileSize > 0 && fileSize != progress.totalUnitCount && self.progress) {
                            // Add the difference to total progress
                            self.progress.totalUnitCount += (fileSize - progress.totalUnitCount);
                            
                            if (self.textProgress) {
                                self.textProgress.totalUnitCount = self.progress.totalUnitCount;
                            }
                            
                            progress.totalUnitCount = fileSize;
                        }
                    } @catch (NSException *exception) {
                        NSLog(@"[MCDL] Warning: Exception updating progress size: %@", exception);
                    }
                }
            }
            
            // Ensure progress is marked as complete
            @try {
                progress.completedUnitCount = progress.totalUnitCount;
            } @catch (NSException *exception) {
                NSLog(@"[MCDL] Warning: Exception setting progress as complete: %@", exception);
            }
            
            NSLog(@"[MCDL] Download completed for %@", name);
            if (success) {
                success();
            }
        }
    }];

    return task;
}

// Compatibility method that calls the full version without failure callback
- (NSURLSessionDownloadTask *)createDownloadTask:(NSString *)url 
                                           size:(NSUInteger)size 
                                            sha:(NSString *)sha 
                                        altName:(NSString *)altName 
                                         toPath:(NSString *)path 
                                        success:(void (^)(void))success {
    return [self createDownloadTask:url size:size sha:sha altName:altName toPath:path success:success failure:nil];
}

// Compatibility method for older code
- (NSURLSessionDownloadTask *)createDownloadTask:(NSString *)url 
                                           size:(NSUInteger)size 
                                            sha:(NSString *)sha 
                                        altName:(NSString *)altName 
                                         toPath:(NSString *)path {
    return [self createDownloadTask:url size:size sha:sha altName:altName toPath:path success:nil failure:nil];
}

- (void)addDownloadTaskToProgress:(NSURLSessionDownloadTask *)task size:(NSUInteger)size {
    // Safety check for nil task
    if (!task) {
        NSLog(@"[MCDL] Warning: Cannot add nil task to progress tracking");
        return;
    }
    
    NSProgress *progress = [self.manager downloadProgressForTask:task];
    // Safety check for nil progress
    if (!progress) {
        NSLog(@"[MCDL] Warning: Could not get progress for download task, creating a new one");
        progress = [NSProgress progressWithTotalUnitCount:1];
    }
    
    // Check if this progress is already a child of another progress
    // This can be done by checking a custom property we can associate with the progress
    NSNumber *isTracked = objc_getAssociatedObject(progress, "isTrackedByTask");
    if (isTracked && [isTracked boolValue]) {
        NSLog(@"[MCDL] Warning: Progress is already being tracked, skipping");
        return;
    }
    
    NSUInteger fileSize = size > 0 ? size : 1000000; // Use 1MB as minimum placeholder
    progress.kind = NSProgressKindFile;
    progress.totalUnitCount = fileSize;
    [self.progressList addObject:progress];
    
    // Create main progress if it doesn't exist yet
    if (!self.progress) {
        self.progress = [NSProgress progressWithTotalUnitCount:fileSize];
    }
    
    // Safely check if progress is cancelled
    BOOL isCancelled = NO;
    @try {
        isCancelled = self.progress.cancelled;
    } @catch (NSException *exception) {
        NSLog(@"[MCDL] Warning: Exception checking if progress is cancelled: %@", exception);
        isCancelled = NO;
    }
    
    if (!isCancelled) {
        // Try-catch to handle case where progress is already a child
        @try {
            [self.progress addChild:progress withPendingUnitCount:fileSize];
            self.progress.totalUnitCount += fileSize;
            
            // Mark this progress as tracked to avoid double-adding
            objc_setAssociatedObject(progress, "isTrackedByTask", @YES, OBJC_ASSOCIATION_RETAIN_NONATOMIC);
        } @catch (NSException *exception) {
            NSLog(@"[MCDL] Warning: Exception adding child progress: %@", exception);
            // Don't rethrow the exception, just log it
        }
    }
    
    // Simplify the text progress - only track fractionCompleted
    if (!self.textProgress) {
        self.textProgress = [NSProgress progressWithTotalUnitCount:1];
    }
    self.textProgress.totalUnitCount = self.progress.totalUnitCount;
}

- (void)finishDownloadWithError:(NSError *)error file:(NSString *)file {
    NSString *errorStr = [NSString stringWithFormat:localize(@"launcher.mcl.error_download", NULL), file, error.localizedDescription];
    NSLog(@"[MCDL] Error: %@ %@", errorStr, NSThread.callStackSymbols);
    [self finishDownloadWithErrorString:errorStr];
}

- (void)finishDownloadWithErrorString:(NSString *)error {
    // Safely cancel progress
    @try {
        [self.progress cancel];
    } @catch (NSException *exception) {
        NSLog(@"[MCDL] Warning: Exception cancelling progress: %@", exception);
    }
    
    [self.manager invalidateSessionCancelingTasks:YES resetSession:YES];
    showDialog(localize(@"Error", nil), error);
    if (self.handleError) {
        self.handleError();
    }
}

// Check if the account has permission to download
- (BOOL)checkAccessWithDialog:(BOOL)show {
    // for now
    BOOL accessible = [BaseAuthenticator.current.authData[@"username"] hasPrefix:@"Demo."] || BaseAuthenticator.current.authData[@"xboxGamertag"] != nil;
    if (!accessible) {
        [self.progress cancel];
        [self.textProgress cancel];
        if (show) {
            [self finishDownloadWithErrorString:@"Minecraft can't be legally installed when logged in with a local account. Please switch to an online account to continue."];
        }
    }
    return accessible;
}

// Check SHA of the file with logging option
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

// Check SHA of the file respecting user preferences
- (BOOL)checkSHA:(NSString *)sha forFile:(NSString *)path altName:(NSString *)altName logSuccess:(BOOL)logSuccess {
    if (getPrefBool(@"general.check_sha")) {
        return [self checkSHAIgnorePref:sha forFile:path altName:altName logSuccess:logSuccess];
    } else {
        return [NSFileManager.defaultManager fileExistsAtPath:path];
    }
}

// Simplified SHA check with default logging behavior
- (BOOL)checkSHA:(NSString *)sha forFile:(NSString *)path altName:(NSString *)altName {
    return [self checkSHA:sha forFile:path altName:altName logSuccess:altName==nil];
}

- (void)downloadVersion:(NSDictionary *)version {
    [self prepareForDownload];
    [self downloadVersionMetadata:version success:^{
        [self downloadAssetMetadataWithSuccess:^{
            NSArray *libTasks = [self downloadClientLibraries];
            NSArray *assetTasks = [self downloadClientAssets];
            
            @synchronized(self) {
                // If we have nothing to download, add a completed marker
                if (self.progress.totalUnitCount == 0) {
                    self.progress.totalUnitCount = 1;
                    self.progress.completedUnitCount = 1;
                    self.textProgress.totalUnitCount = 1;
                    self.textProgress.completedUnitCount = 1;
                    
                    // Add completion marker
                    [self.fileList addObject:@"Complete"];
                    NSProgress *completeProgress = [NSProgress progressWithTotalUnitCount:1];
                    completeProgress.completedUnitCount = 1;
                    [self.progressList addObject:completeProgress];
                    return;
                }
            }
            
            // Start all download tasks
            [libTasks makeObjectsPerformSelector:@selector(resume)];
            [assetTasks makeObjectsPerformSelector:@selector(resume)];
            
            // Clean up large metadata we don't need anymore
            [self.metadata removeObjectForKey:@"assetIndexObj"];
        }];
    }];
}

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

    // Create a wrapped success callback
    void(^wrappedSuccess)(void) = ^{
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
            wrappedSuccess();
            return;
        }
    }

    versionStr = version[@"id"];
    NSString *url = version[@"url"];
    NSString *sha = url.stringByDeletingLastPathComponent.lastPathComponent;
    NSUInteger size = [version[@"size"] unsignedLongLongValue];

    NSURLSessionDownloadTask *task = [self createDownloadTask:url size:size sha:sha altName:versionStr toPath:path success:wrappedSuccess];
    if (task) {
        [task resume];
    }
}

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
    
    // Create a wrapped success callback to update phase
    void(^wrappedSuccess)(void) = ^{
        self.metadata[@"assetIndexObj"] = parseJSONFromFile(path);
        success();
    };
    
    NSURLSessionDownloadTask *task = [self createDownloadTask:url size:size sha:sha altName:name toPath:path success:wrappedSuccess];
    if (task) {
        [task resume];
    } else {
        // If no task was created (file already exists), continue
        wrappedSuccess();
    }
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

- (void)downloadModpackFromAPI:(ModpackAPI *)api detail:(NSDictionary *)modDetail atIndex:(NSUInteger)selectedVersion {
    [self prepareForDownload];
    
    // Set flag in metadata that this is a modpack installation
    if (!self.metadata) {
        self.metadata = [NSMutableDictionary dictionary];
    }
    self.metadata[@"isModpackInstall"] = @YES;

    NSString *url = modDetail[@"versionUrls"][selectedVersion];
    NSUInteger size = [modDetail[@"versionSizes"][selectedVersion] unsignedLongLongValue];
    NSString *sha = modDetail[@"versionHashes"][selectedVersion];
    
    // Use the original title without converting to lowercase or replacing spaces with underscores
    NSString *name = [modDetail[@"title"] stringByTrimmingCharactersInSet:NSCharacterSet.whitespaceCharacterSet];
    // For the filesystem paths, create a sanitized version of the name (for the zip file only)
    NSString *sanitizedName = [[name lowercaseString] stringByReplacingOccurrencesOfString:@" " withString:@"_"];
    NSString *packagePath = [NSTemporaryDirectory() stringByAppendingFormat:@"/%@.zip", sanitizedName];
    
    // Get the game directory for this modpack
    NSString *gameDir = [PLProfiles uniqueGameDirForProfileName:name];
    
    // Get the full absolute path where we'll extract the modpack
    NSString *destPath = [PLProfiles fullPathForProfileWithName:name gameDir:gameDir];
    
    // Store the game directory in metadata for proper profile creation
    self.metadata[@"gameDir"] = gameDir;
    
    // Create a clear display name for progress reporting
    NSString *displayName = [NSString stringWithFormat:@"Downloading modpack: %@", name];
    
    // Set progress for the primary modpack download
    @synchronized(self) {
        self.progress.totalUnitCount = size > 0 ? size : 1000000; // Use reasonable placeholder if size unknown
        self.textProgress.totalUnitCount = self.progress.totalUnitCount;
    }
    
    // Add the package as the first item in the file list for UI reporting
    [self.fileList addObject:displayName];
    NSProgress *packageProgress = [NSProgress progressWithTotalUnitCount:size > 0 ? size : 1000000];
    [self.progressList addObject:packageProgress];
    
    // Create a wrapped success callback that transitions to extraction phase
    void(^modpackSuccess)(void) = ^{
        // Make sure progress is properly shown as complete for the download phase
        packageProgress.completedUnitCount = packageProgress.totalUnitCount;
        
        // Add placeholder progress for extraction phase - reset overall progress
        @synchronized(self) {
            self.progress.totalUnitCount = 1;
            self.progress.completedUnitCount = 0;
            self.textProgress.totalUnitCount = 1;
            self.textProgress.completedUnitCount = 0;
        }
        
        NSLog(@"[MCDL] Modpack download complete, proceeding to extraction.");
        // Use the API to handle extraction and installation
        [api downloader:self submitDownloadTasksFromPackage:packagePath toPath:destPath];
    };
    
    // Failure callback to handle retries for modpack download
    void(^modpackFailure)(NSError *error) = ^(NSError *error) {
        NSLog(@"[MCDL] Failed to download modpack: %@. Retrying...", error.localizedDescription);
        
        // Update file list to show retry attempt
        [self.fileList addObject:[NSString stringWithFormat:@"Retrying download for %@", name]];
        NSProgress *retryProgress = [NSProgress progressWithTotalUnitCount:size > 0 ? size : 1000000];
        [self.progressList addObject:retryProgress];
        
        // Create a retry task
        NSURLSessionDownloadTask *retryTask = [self createDownloadTask:url 
                                                                 size:size 
                                                                  sha:sha 
                                                              altName:[NSString stringWithFormat:@"Downloading %@ (retry)", name]
                                                               toPath:packagePath 
                                                              success:modpackSuccess
                                                              failure:^(NSError *retryError) {
            // If retry also fails, show error
            [self finishDownloadWithErrorString:[NSString stringWithFormat:@"Failed to download modpack after retry: %@", retryError.localizedDescription]];
        }];
        
        if (retryTask) {
            // The retryTask's progress is already added to the parent progress by createDownloadTask
            // so we don't need to call addDownloadTaskToProgress here
            [retryTask resume];
        } else {
            [self finishDownloadWithErrorString:@"Failed to create retry download task for modpack"];
        }
    };

    NSURLSessionDownloadTask *task = [self createDownloadTask:url 
                                                        size:size 
                                                         sha:sha 
                                                     altName:displayName
                                                      toPath:packagePath 
                                                     success:modpackSuccess
                                                     failure:modpackFailure];
    if (task) {
        [task resume];
    }
}

@end

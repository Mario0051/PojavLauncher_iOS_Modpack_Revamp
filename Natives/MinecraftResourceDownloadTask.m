#import "MinecraftResourceDownloadTask.h"
#import "LauncherNavigationController.h"
#import "installer/modpack/ModpackAPI.h"
#import "MinecraftResourceUtils.h"
#import <CommonCrypto/CommonDigest.h>
#import "utils.h"

@interface MinecraftResourceDownloadTask ()
@property (nonatomic, strong) NSURLSession *session;
@property (nonatomic, strong) NSMutableDictionary *downloadTasks;
@property (nonatomic, strong) NSMutableDictionary *urlToPathMap;
@property (nonatomic, strong) NSMutableDictionary *taskInfoMap;
@property (nonatomic, strong) NSMutableArray *downloadedFiles;
@property (nonatomic, strong) dispatch_queue_t downloadQueue;
@property (nonatomic, strong) dispatch_semaphore_t downloadSemaphore;
- (void)checkForCompletionAndFinalize;
@end

@implementation MinecraftResourceDownloadTask

- (instancetype)init {
    self = [super init];
    if (self) {
        _fileList = [NSMutableArray new];
        _progressList = [NSMutableArray new];
        _metadata = [NSMutableDictionary new];
        _downloadTasks = [NSMutableDictionary new];
        _urlToPathMap = [NSMutableDictionary new];
        _taskInfoMap = [NSMutableDictionary new];
        _downloadedFiles = [NSMutableArray new];
        
        // Create dispatch queue and semaphore for concurrent download management
        _downloadQueue = dispatch_queue_create("com.pojavlauncher.download", DISPATCH_QUEUE_CONCURRENT);
        _downloadSemaphore = dispatch_semaphore_create(5); // Limit concurrent downloads to 5
        
        // Create the session with default configuration
        NSURLSessionConfiguration *config = [NSURLSessionConfiguration defaultSessionConfiguration];
        config.timeoutIntervalForRequest = 60.0;
        config.HTTPMaximumConnectionsPerHost = 10;
        _session = [NSURLSession sessionWithConfiguration:config 
                                                 delegate:nil 
                                            delegateQueue:[NSOperationQueue mainQueue]];
    }
    return self;
}

- (void)markAsCompleted {
    // Create a flag file to indicate all tasks are truly complete
    self.metadata[@"allTasksComplete"] = @YES;
    
    // Add completion marker for UI
    if (![self.fileList containsObject:@"Complete"]) {
        [self.fileList addObject:@"Complete"];
        
        // Create completion progress
        NSProgress *completeProgress = [NSProgress progressWithTotalUnitCount:1];
        completeProgress.completedUnitCount = 1;
        completeProgress.kind = NSProgressKindFile;
        [self.progressList addObject:completeProgress];
        [self.progress addChild:completeProgress withPendingUnitCount:1];
    }
    
    // Ensure overall progress shows as complete
    self.progress.completedUnitCount = self.progress.totalUnitCount;
    
    NSLog(@"[ResourceDownload] Task marked as fully completed");
}

- (void)checkForCompletionAndFinalize {
    // Check if all tasks are complete
    BOOL allComplete = YES;
    @synchronized(self.downloadTasks) {
        for (NSURLSessionDownloadTask *task in [self.downloadTasks allValues]) {
            if (task.state != NSURLSessionTaskStateCompleted) {
                allComplete = NO;
                break;
            }
        }
    }
    
    if (allComplete) {
        NSLog(@"[ResourceDownload] All download tasks completed, finalizing");
        
        // Mark progress as complete
        self.progress.completedUnitCount = self.progress.totalUnitCount;
        
        // Update task metadata for launch
        self.metadata[@"allTasksComplete"] = @YES;
        
        // Add completion indicator to file list
        if (![self.fileList containsObject:@"Complete"]) {
            [self.fileList addObject:@"Complete"];
            
            // Create completion progress
            NSProgress *completeProgress = [NSProgress progressWithTotalUnitCount:1];
            completeProgress.completedUnitCount = 1;
            completeProgress.kind = NSProgressKindFile;
            [self.progressList addObject:completeProgress];
            [self.progress addChild:completeProgress withPendingUnitCount:1];
        }
    } else {
        // Not all tasks are complete, check again after a delay
        NSLog(@"[ResourceDownload] Some tasks still in progress, checking again later");
        dispatch_after(dispatch_time(DISPATCH_TIME_NOW, (int64_t)(3 * NSEC_PER_SEC)), dispatch_get_main_queue(), ^{
            [self checkForCompletionAndFinalize];
        });
    }
}

- (void)prepareForDownload {
    // Initialize master progress trackers with better initial values
    self.progress = [NSProgress progressWithTotalUnitCount:100]; // Use percentage style for overall progress
    self.textProgress = [NSProgress progressWithTotalUnitCount:1]; // Will be updated with actual file count
    self.textProgress.localizedDescription = @"Preparing download...";
    
    // Clear previous download state
    [self.fileList removeAllObjects];
    [self.progressList removeAllObjects];
    [self.downloadTasks removeAllObjects];
    [self.urlToPathMap removeAllObjects];
    [self.taskInfoMap removeAllObjects];
    [self.downloadedFiles removeAllObjects];
    
    NSLog(@"[ResourceDownload] Prepared for download");
}

- (NSString *)formatDisplayNameForFile:(NSString *)fileName fromSource:(DownloadSource)source {
    NSString *prefix = @"";
    
    switch (source) {
        case DownloadSourceMinecraft:
            prefix = @"[Minecraft] ";
            break;
        case DownloadSourceCurseForge:
            prefix = @"[CurseForge] ";
            break;
        case DownloadSourceModrinth:
            prefix = @"[Modrinth] ";
            break;
    }
    
    return [prefix stringByAppendingString:fileName];
}

- (NSURLSessionDownloadTask *)createDownloadTask:(NSString *)url size:(NSUInteger)size sha:(NSString *)sha altName:(NSString *)altName toPath:(NSString *)path {
    return [self createDownloadTask:url size:size sha:sha altName:altName toPath:path success:nil];
}

- (NSURLSessionDownloadTask *)createDownloadTask:(NSString *)url size:(NSUInteger)size sha:(NSString *)sha altName:(NSString *)altName toPath:(NSString *)path success:(void (^)())success {
    // Validate inputs
    if (!url || url.length == 0) {
        NSLog(@"[ResourceDownload] Invalid URL provided");
        return nil;
    }
    
    if (!path || path.length == 0) {
        NSLog(@"[ResourceDownload] Invalid destination path");
        return nil;
    }
    
    // Ensure destination directory exists
    NSString *directory = [path stringByDeletingLastPathComponent];
    NSError *dirError = nil;
    [[NSFileManager defaultManager] createDirectoryAtPath:directory 
                              withIntermediateDirectories:YES 
                                               attributes:nil 
                                                    error:&dirError];
    if (dirError) {
        NSLog(@"[ResourceDownload] Failed to create directory %@: %@", directory, dirError);
        return nil;
    }
    
    // Add file to the tracking list with appropriate names
    NSString *displayName = altName ?: [url lastPathComponent];
    if (!displayName) {
        displayName = @"Unknown file";
    }
    
    // Create progress for the file
    NSProgress *fileProgress = [NSProgress progressWithTotalUnitCount:size > 0 ? size : 1];
    fileProgress.kind = NSProgressKindFile;
    fileProgress.fileOperationKind = NSProgressFileOperationKindDownloading;
    
    // Synchronize access to shared resources
    @synchronized(self) {
        [self.fileList addObject:displayName];
        [self.progressList addObject:fileProgress];
        
        // Add to the overall progress
        [self.progress addChild:fileProgress withPendingUnitCount:1];
    }
    
    // Create download task
    NSURL *downloadURL = [NSURL URLWithString:url];
    NSURLRequest *request = [NSURLRequest requestWithURL:downloadURL];
    
    __weak typeof(self) weakSelf = self;
    NSURLSessionDownloadTask *task = [self.session downloadTaskWithRequest:request completionHandler:^(NSURL *location, NSURLResponse *response, NSError *error) {
        __strong typeof(weakSelf) strongSelf = weakSelf;
        if (!strongSelf) return;
        
        if (error) {
            NSLog(@"[ResourceDownload] Failed to download %@: %@", url, error);
            
            // Mark progress as failed
            fileProgress.completedUnitCount = 0;
            [fileProgress cancel];
            
            if (strongSelf.handleError) {
                dispatch_async(dispatch_get_main_queue(), ^{
                    strongSelf.handleError();
                });
            }
            return;
        }
        
        // Move file to destination
        NSError *moveError = nil;
        
        // Make sure the destination directory exists
        [[NSFileManager defaultManager] createDirectoryAtPath:[path stringByDeletingLastPathComponent] 
                                  withIntermediateDirectories:YES 
                                                   attributes:nil 
                                                        error:nil];
        
        // If file already exists at destination, remove it first
        if ([[NSFileManager defaultManager] fileExistsAtPath:path]) {
            [[NSFileManager defaultManager] removeItemAtPath:path error:nil];
        }
        
        // Move the file to its destination
        [[NSFileManager defaultManager] moveItemAtURL:location 
                                                toURL:[NSURL fileURLWithPath:path] 
                                                error:&moveError];
        
        if (moveError) {
            NSLog(@"[ResourceDownload] Failed to move file: %@", moveError);
            
            fileProgress.completedUnitCount = 0;
            [fileProgress cancel];
            
            if (strongSelf.handleError) {
                dispatch_async(dispatch_get_main_queue(), ^{
                    strongSelf.handleError();
                });
            }
            return;
        }
        
        // Verify SHA if provided
        if (sha.length > 0) {
            BOOL shaValid = [strongSelf checkSHA:sha forFile:path altName:displayName];
            if (!shaValid) {
                NSLog(@"[ResourceDownload] SHA verification failed for %@", path);
                
                // Remove the invalid file
                [[NSFileManager defaultManager] removeItemAtPath:path error:nil];
                
                fileProgress.completedUnitCount = 0;
                [fileProgress cancel];
                
                if (strongSelf.handleError) {
                    dispatch_async(dispatch_get_main_queue(), ^{
                        strongSelf.handleError();
                    });
                }
                return;
            }
        }
        
        // Create file info for tracking
        NSMutableDictionary *fileInfo = [NSMutableDictionary dictionary];
        fileInfo[@"path"] = path;
        fileInfo[@"url"] = url;
        fileInfo[@"name"] = displayName;
        fileInfo[@"size"] = @(fileProgress.totalUnitCount);
        
        if (sha.length > 0) {
            fileInfo[@"sha"] = sha;
        }
        
        // Add to downloaded files list
        @synchronized (strongSelf.downloadedFiles) {
            [strongSelf.downloadedFiles addObject:fileInfo];
        }
        
        // Mark progress as complete
        fileProgress.completedUnitCount = fileProgress.totalUnitCount;
        
        // Call success callback if provided
        if (success) {
            dispatch_async(dispatch_get_main_queue(), ^{
                success();
            });
        }
        
        NSLog(@"[ResourceDownload] Successfully downloaded %@ to %@", displayName, path);
    }];
    
    // Set task description for tracking
    task.taskDescription = displayName;
    
    // Store task and mapping info
    @synchronized(self) {
        self.downloadTasks[displayName] = task;
        self.urlToPathMap[url] = path;
        
        // Store task info
        NSMutableDictionary *taskInfo = [NSMutableDictionary dictionary];
        taskInfo[@"url"] = url;
        taskInfo[@"path"] = path;
        taskInfo[@"name"] = displayName;
        taskInfo[@"size"] = @(size);
        if (sha.length > 0) {
            taskInfo[@"sha"] = sha;
        }
        taskInfo[@"task"] = task;
        taskInfo[@"progress"] = fileProgress;
        self.taskInfoMap[task.taskDescription] = taskInfo;
    }
    
    return task;
}

// Fix for finishDownloadWithErrorString to use cancel method
- (void)finishDownloadWithErrorString:(NSString *)error {
    NSLog(@"[ResourceDownload] Error: %@", error);
    
    // Update text progress
    self.textProgress.localizedDescription = [@"Error: " stringByAppendingString:error];
    
    // Cancel all pending tasks
    @synchronized(self.downloadTasks) {
        for (NSURLSessionDownloadTask *task in [self.downloadTasks allValues]) {
            [task cancel];
        }
        [self.downloadTasks removeAllObjects];
    }
    
    // Cancel overall progress - use cancel method instead of setting property
    [self.progress cancel];
    
    // Call error handler
    if (self.handleError) {
        dispatch_async(dispatch_get_main_queue(), ^{
            self.handleError();
        });
    }
}

- (void)fetchAdditionalVersionInfoForId:(NSString *)versionId completion:(void (^)(NSDictionary *updatedVersion))completion {
    // Try to fetch detailed version information from Mojang's version manifest
    NSString *versionUrl = [NSString stringWithFormat:@"https://piston-meta.mojang.com/v1/packages/%@/%@.json", versionId, versionId];
    NSString *manifestUrl = @"https://launchermeta.mojang.com/mc/game/version_manifest_v2.json";
    
    // First try direct version URL
    NSURLSessionDataTask *task = [[NSURLSession sharedSession] dataTaskWithURL:[NSURL URLWithString:versionUrl] 
                                                             completionHandler:^(NSData *data, NSURLResponse *response, NSError *error) {
        if (data) {
            NSError *jsonError;
            NSDictionary *versionData = [NSJSONSerialization JSONObjectWithData:data options:0 error:&jsonError];
            
            if (versionData && !jsonError) {
                NSLog(@"[ResourceDownload] Successfully fetched additional version info for %@", versionId);
                if (completion) completion(versionData);
                return;
            }
        }
        
        // If direct URL fails, try to look up in manifest
        NSURLSessionDataTask *manifestTask = [[NSURLSession sharedSession] dataTaskWithURL:[NSURL URLWithString:manifestUrl] 
                                                                        completionHandler:^(NSData *manifestData, NSURLResponse *manifestResponse, NSError *manifestError) {
            if (manifestData) {
                NSError *manifestJsonError;
                NSDictionary *manifest = [NSJSONSerialization JSONObjectWithData:manifestData options:0 error:&manifestJsonError];
                
                if (manifest && !manifestJsonError && manifest[@"versions"]) {
                    // Find the version in the manifest
                    for (NSDictionary *version in manifest[@"versions"]) {
                        if ([version[@"id"] isEqualToString:versionId] && version[@"url"]) {
                            // Found version, fetch its details
                            NSURLSessionDataTask *versionDetailTask = [[NSURLSession sharedSession] dataTaskWithURL:[NSURL URLWithString:version[@"url"]] 
                                                                                                 completionHandler:^(NSData *versionDetailData, NSURLResponse *versionDetailResponse, NSError *versionDetailError) {
                                if (versionDetailData) {
                                    NSError *versionDetailJsonError;
                                    NSDictionary *versionDetail = [NSJSONSerialization JSONObjectWithData:versionDetailData options:0 error:&versionDetailJsonError];
                                    
                                    if (versionDetail && !versionDetailJsonError) {
                                        NSLog(@"[ResourceDownload] Successfully fetched version details from manifest for %@", versionId);
                                        if (completion) completion(versionDetail);
                                        return;
                                    }
                                }
                                
                                NSLog(@"[ResourceDownload] Failed to fetch version details from manifest URL");
                                if (completion) completion(nil);
                            }];
                            
                            [versionDetailTask resume];
                            return;
                        }
                    }
                }
            }
            
            NSLog(@"[ResourceDownload] Could not find version in manifest");
            if (completion) completion(nil);
        }];
        
        [manifestTask resume];
    }];
    
    [task resume];
}

- (void)processLibrariesAndAssets:(NSDictionary *)version forVersion:(NSString *)versionId {
    // Process libraries if needed
    NSArray *libraries = version[@"libraries"];
    if (libraries && [libraries isKindOfClass:[NSArray class]]) {
        for (NSDictionary *library in libraries) {
            if (![library isKindOfClass:[NSDictionary class]]) continue;
            
            // Process library downloads
            [self processLibraryDownload:library forVersion:versionId];
        }
    }
    
    // Process assets if needed
    NSDictionary *assetIndex = version[@"assetIndex"];
    if (assetIndex && [assetIndex isKindOfClass:[NSDictionary class]]) {
        [self processAssetIndex:assetIndex forVersion:versionId];
    }
    
    // Set up a timer to periodically check for completion
    dispatch_after(dispatch_time(DISPATCH_TIME_NOW, (int64_t)(3 * NSEC_PER_SEC)), dispatch_get_main_queue(), ^{
        [self checkForCompletionAndFinalize];
    });
}

- (void)processDownloadsSection:(NSDictionary *)downloads forVersion:(NSString *)versionId clientJarPath:(NSString *)clientJarPath {
    NSDictionary *clientInfo = downloads[@"client"];
    if (clientInfo && [clientInfo isKindOfClass:[NSDictionary class]]) {
        NSString *clientURL = clientInfo[@"url"];
        NSString *clientSHA1 = clientInfo[@"sha1"];
        NSNumber *clientSize = clientInfo[@"size"];
        
        if (clientURL && [clientURL isKindOfClass:[NSString class]]) {
            // Download client JAR
            NSString *displayName = [NSString stringWithFormat:@"Minecraft %@ client", versionId];
            NSURLSessionDownloadTask *clientTask = [self createDownloadTask:clientURL 
                                                                        size:[clientSize unsignedIntegerValue] 
                                                                         sha:clientSHA1 
                                                                     altName:displayName 
                                                                      toPath:clientJarPath 
                                                                     success:^{
                // Once client is downloaded, check if we should mark as completed
                [self checkForCompletionAndFinalize];                                                
            }];
            
            if (clientTask) {
                [clientTask resume];
            }
        }
    }
}

- (void)downloadVersion:(NSDictionary *)version {
    if (!version || ![version isKindOfClass:[NSDictionary class]]) {
        [self finishDownloadWithErrorString:@"Invalid version data"];
        return;
    }
    
    NSString *versionId = version[@"id"];
    if (!versionId || ![versionId isKindOfClass:[NSString class]]) {
        [self finishDownloadWithErrorString:@"Invalid version ID"];
        return;
    }
    
    NSLog(@"[ResourceDownload] Downloading Minecraft version: %@", versionId);
    
    // Prepare for download
    [self prepareForDownload];
    
    // Store version info in metadata
    self.metadata[@"versionId"] = versionId;
    
    // Set progress description
    self.textProgress.localizedDescription = [NSString stringWithFormat:@"Downloading Minecraft %@", versionId];
    
    // Set up download destinations
    NSString *versionsDir = [NSString stringWithFormat:@"%s/versions/%@", getenv("POJAV_GAME_DIR"), versionId];
    NSString *clientJarPath = [NSString stringWithFormat:@"%@/%@.jar", versionsDir, versionId];
    NSString *clientJsonPath = [NSString stringWithFormat:@"%@/%@.json", versionsDir, versionId];
    
    // Create directory
    NSError *dirError = nil;
    [[NSFileManager defaultManager] createDirectoryAtPath:versionsDir 
                              withIntermediateDirectories:YES 
                                               attributes:nil 
                                                    error:&dirError];
    if (dirError) {
        [self finishDownloadWithErrorString:[NSString stringWithFormat:@"Failed to create versions directory: %@", dirError.localizedDescription]];
        return;
    }
    
    // Save version JSON
    NSError *jsonError = saveJSONToFile(version, clientJsonPath);
    if (jsonError) {
        [self finishDownloadWithErrorString:[NSString stringWithFormat:@"Failed to save version JSON: %@", jsonError.localizedDescription]];
        return;
    }

    // Check if this is a modded version that inherits from vanilla
    NSString *inheritsFrom = version[@"inheritsFrom"];
    BOOL isModdedVersion = (inheritsFrom != nil);
    
    // Modded versions may not have direct download URLs
    if (isModdedVersion) {
        NSLog(@"[ResourceDownload] Detected modded version inheriting from %@", inheritsFrom);
        
        // For modded versions, we may just need to download libraries and assets
        // The client JAR will be inherited from the base version
        
        // Check if base version's jar needs to be downloaded
        BOOL baseJarExists = [[NSFileManager defaultManager] fileExistsAtPath:
                             [NSString stringWithFormat:@"%s/versions/%@/%@.jar", 
                              getenv("POJAV_GAME_DIR"), inheritsFrom, inheritsFrom]];
        
        if (!baseJarExists) {
            NSLog(@"[ResourceDownload] Base version JAR not found, downloading it");
            // Find the base version in the remote list - with proper casting
            NSDictionary *baseVersion = (NSDictionary *)[MinecraftResourceUtils findVersion:inheritsFrom inList:remoteVersionList];
            if (baseVersion) {
                // Download the base version first (recursively)
                [self downloadVersion:baseVersion];
            } else {
                NSLog(@"[ResourceDownload] Warning: Base version info not found, client may not launch properly");
            }
        }
        
        // Process libraries and assets from the modded version
        [self processLibrariesAndAssets:version forVersion:versionId];
    } else {
        // Standard vanilla version
        NSDictionary *downloads = version[@"downloads"];
        if (!downloads || ![downloads isKindOfClass:[NSDictionary class]]) {
            // Try to check if it's an alternative format version data or get additional version information
            NSLog(@"[ResourceDownload] No downloads section found in version data, attempting alternative sources");
            
            // Try to fetch the detailed version info from Mojang's servers if needed
            [self fetchAdditionalVersionInfoForId:versionId completion:^(NSDictionary *updatedVersion) {
                if (updatedVersion && updatedVersion[@"downloads"] && [updatedVersion[@"downloads"] isKindOfClass:[NSDictionary class]]) {
                    // Process the downloads from the updated version info
                    [self processDownloadsSection:updatedVersion[@"downloads"] forVersion:versionId clientJarPath:clientJarPath];
                    
                    // Process libraries and assets
                    [self processLibrariesAndAssets:updatedVersion forVersion:versionId];
                } else {
                    // Use fallback URL based on version ID
                    NSString *fallbackURL = @"https://launcher.mojang.com/mc/game/version_manifest_v2.json";
                    NSLog(@"[ResourceDownload] Attempting to get URL from manifest for %@", versionId);
                    
                    // Try to find the correct download URL from the manifest
                    NSURLSessionDataTask *manifestTask = [[NSURLSession sharedSession] dataTaskWithURL:[NSURL URLWithString:fallbackURL] 
                                                                                    completionHandler:^(NSData *data, NSURLResponse *response, NSError *error) {
                        if (data) {
                            NSError *jsonError;
                            NSDictionary *manifest = [NSJSONSerialization JSONObjectWithData:data options:0 error:&jsonError];
                            
                            if (!jsonError && manifest && manifest[@"versions"]) {
                                // Look for our version
                                NSString *versionURL = nil;
                                for (NSDictionary *manifestVersion in manifest[@"versions"]) {
                                    if ([manifestVersion[@"id"] isEqualToString:versionId]) {
                                        versionURL = manifestVersion[@"url"];
                                        break;
                                    }
                                }
                                
                                if (versionURL) {
                                    // Now get the version details
                                    NSURLSessionDataTask *versionTask = [[NSURLSession sharedSession] dataTaskWithURL:[NSURL URLWithString:versionURL] 
                                                                                                     completionHandler:^(NSData *versionData, NSURLResponse *versionResponse, NSError *versionError) {
                                        if (versionData) {
                                            NSError *versionJsonError;
                                            NSDictionary *versionDetails = [NSJSONSerialization JSONObjectWithData:versionData options:0 error:&versionJsonError];
                                            
                                            if (!versionJsonError && versionDetails && versionDetails[@"downloads"] && versionDetails[@"downloads"][@"client"]) {
                                                NSDictionary *client = versionDetails[@"downloads"][@"client"];
                                                NSString *clientURL = client[@"url"];
                                                
                                                if (clientURL) {
                                                    dispatch_async(dispatch_get_main_queue(), ^{
                                                        NSString *displayName = [NSString stringWithFormat:@"Minecraft %@ client", versionId];
                                                        NSURLSessionDownloadTask *clientTask = [self createDownloadTask:clientURL 
                                                                                                                   size:[client[@"size"] unsignedIntegerValue] 
                                                                                                                    sha:client[@"sha1"] 
                                                                                                                altName:displayName 
                                                                                                                 toPath:clientJarPath 
                                                                                                                success:^{
                                                            [self checkForCompletionAndFinalize];
                                                        }];
                                                        
                                                        if (clientTask) {
                                                            [clientTask resume];
                                                        }
                                                    });
                                                    
                                                    // Also process libraries and assets
                                                    dispatch_async(dispatch_get_main_queue(), ^{
                                                        [self processLibrariesAndAssets:versionDetails forVersion:versionId];
                                                    });
                                                    return;
                                                }
                                            }
                                        }
                                        
                                        // If everything failed, use a hardcoded fallback
                                        dispatch_async(dispatch_get_main_queue(), ^{
                                            NSString *hardcodedURL = @"https://launcher.mojang.com/v1/objects/8dd1a28015f5bda1061b5cef5a08d5a4b56926f4/client.jar";
                                            NSLog(@"[ResourceDownload] Using hardcoded client download URL as last resort");
                                            
                                            NSString *displayName = [NSString stringWithFormat:@"Minecraft %@ client (fallback)", versionId];
                                            NSURLSessionDownloadTask *clientTask = [self createDownloadTask:hardcodedURL 
                                                                                                       size:0 
                                                                                                        sha:nil 
                                                                                                    altName:displayName 
                                                                                                     toPath:clientJarPath 
                                                                                                    success:^{
                                                [self checkForCompletionAndFinalize];
                                            }];
                                            
                                            if (clientTask) {
                                                [clientTask resume];
                                            }
                                            
                                            // Try to process libraries and assets anyway
                                            [self processLibrariesAndAssets:version forVersion:versionId];
                                        });
                                    }];
                                    
                                    [versionTask resume];
                                    return;
                                }
                            }
                            
                            // If we can't find the version or parse the manifest, use hardcoded fallback
                            dispatch_async(dispatch_get_main_queue(), ^{
                                NSString *hardcodedURL = @"https://launcher.mojang.com/v1/objects/8dd1a28015f5bda1061b5cef5a08d5a4b56926f4/client.jar";
                                NSLog(@"[ResourceDownload] Using hardcoded client download URL as last resort");
                                
                                NSString *displayName = [NSString stringWithFormat:@"Minecraft %@ client (fallback)", versionId];
                                NSURLSessionDownloadTask *clientTask = [self createDownloadTask:hardcodedURL 
                                                                                           size:0 
                                                                                            sha:nil 
                                                                                        altName:displayName 
                                                                                         toPath:clientJarPath 
                                                                                        success:^{
                                    [self checkForCompletionAndFinalize];
                                }];
                                
                                if (clientTask) {[clientTask resume];
                               }
                               
                               // Try to process libraries and assets anyway
                               [self processLibrariesAndAssets:version forVersion:versionId];
                           });
                       }
                   }];
                   
                   [manifestTask resume];
               }
           }];
       } else {
           // Process the downloads section directly
           [self processDownloadsSection:downloads forVersion:versionId clientJarPath:clientJarPath];
           
           // Process libraries and assets
           [self processLibrariesAndAssets:version forVersion:versionId];
       }
   }
}

- (void)processLibraryDownload:(NSDictionary *)library forVersion:(NSString *)versionId {
   // Library download processing logic would go here
   // This is a simplified stub implementation
   NSDictionary *downloads = library[@"downloads"];
   if (!downloads || ![downloads isKindOfClass:[NSDictionary class]]) {
       return;
   }
   
   NSDictionary *artifact = downloads[@"artifact"];
   if (!artifact || ![artifact isKindOfClass:[NSDictionary class]]) {
       return;
   }
   
   NSString *libraryURL = artifact[@"url"];
   NSString *libraryPath = artifact[@"path"];
   NSString *librarySHA1 = artifact[@"sha1"];
   NSNumber *librarySize = artifact[@"size"];
   
   if (!libraryURL || !libraryPath) {
       return;
   }
   
   NSString *libraryDestPath = [NSString stringWithFormat:@"%s/libraries/%@", getenv("POJAV_GAME_DIR"), libraryPath];
   NSString *displayName = [NSString stringWithFormat:@"Library: %@", libraryPath.lastPathComponent];
   
   NSURLSessionDownloadTask *libraryTask = [self createDownloadTask:libraryURL 
                                                              size:[librarySize unsignedIntegerValue] 
                                                               sha:librarySHA1 
                                                           altName:displayName 
                                                            toPath:libraryDestPath];
   
   if (libraryTask) {
       [libraryTask resume];
   }
}

- (void)processAssetIndex:(NSDictionary *)assetIndex forVersion:(NSString *)versionId {
   // Asset index processing logic would go here
   // This is a simplified stub implementation
   NSString *assetIndexURL = assetIndex[@"url"];
   NSString *assetIndexId = assetIndex[@"id"];
   NSString *assetIndexSHA1 = assetIndex[@"sha1"];
   NSNumber *assetIndexSize = assetIndex[@"size"];
   
   if (!assetIndexURL || !assetIndexId) {
       return;
   }
   
   NSString *assetIndexPath = [NSString stringWithFormat:@"%s/assets/indexes/%@.json", getenv("POJAV_GAME_DIR"), assetIndexId];
   NSString *displayName = [NSString stringWithFormat:@"Asset Index: %@", assetIndexId];
   
   NSURLSessionDownloadTask *assetIndexTask = [self createDownloadTask:assetIndexURL 
                                                                  size:[assetIndexSize unsignedIntegerValue] 
                                                                   sha:assetIndexSHA1 
                                                               altName:displayName 
                                                                toPath:assetIndexPath 
                                                               success:^{
       // After asset index is downloaded, process assets
       [self processAssetsFromIndex:assetIndexPath];
   }];
   
   if (assetIndexTask) {
       [assetIndexTask resume];
   }
}

- (void)processAssetsFromIndex:(NSString *)assetIndexPath {
   // Asset downloading logic would go here
   // This is a simplified stub implementation
   NSData *indexData = [NSData dataWithContentsOfFile:assetIndexPath];
   if (!indexData) {
       return;
   }
   
   NSError *jsonError = nil;
   NSDictionary *indexDict = [NSJSONSerialization JSONObjectWithData:indexData options:0 error:&jsonError];
   if (jsonError || !indexDict) {
       return;
   }
   
   NSDictionary *objects = indexDict[@"objects"];
   if (!objects || ![objects isKindOfClass:[NSDictionary class]]) {
       return;
   }
   
   for (NSString *assetName in objects) {
       NSDictionary *assetInfo = objects[assetName];
       if (![assetInfo isKindOfClass:[NSDictionary class]]) continue;
       
       NSString *hash = assetInfo[@"hash"];
       NSNumber *size = assetInfo[@"size"];
       
       if (!hash || !size) continue;
       
       NSString *hashPrefix = [hash substringToIndex:2];
       NSString *assetURL = [NSString stringWithFormat:@"https://resources.download.minecraft.net/%@/%@", hashPrefix, hash];
       NSString *assetPath = [NSString stringWithFormat:@"%s/assets/objects/%@/%@", getenv("POJAV_GAME_DIR"), hashPrefix, hash];
       
       NSURLSessionDownloadTask *assetTask = [self createDownloadTask:assetURL 
                                                                  size:[size unsignedIntegerValue] 
                                                                   sha:hash 
                                                               altName:[NSString stringWithFormat:@"Asset: %@", assetName] 
                                                                toPath:assetPath];
       
       if (assetTask) {
           [assetTask resume];
       }
   }
}

- (void)downloadModpackFromAPI:(ModpackAPI *)api detail:(NSDictionary *)modDetail atIndex:(NSUInteger)selectedVersion {
   if (!api || !modDetail) {
       [self finishDownloadWithErrorString:@"Invalid modpack API or details"];
       return;
   }
   
   NSString *modpackName = modDetail[@"title"] ?: @"Unknown Modpack";
   NSLog(@"[ResourceDownload] Starting modpack download: %@", modpackName);
   
   // Prepare for download
   [self prepareForDownload];
   
   // Set progress description
   self.textProgress.localizedDescription = [NSString stringWithFormat:@"Downloading %@", modpackName];
   
   // Extract necessary information
   NSArray *versionUrls = modDetail[@"versionUrls"];
   if (!versionUrls || ![versionUrls isKindOfClass:[NSArray class]] || selectedVersion >= versionUrls.count) {
       [self finishDownloadWithErrorString:@"Invalid modpack version information"];
       return;
   }
   
   NSString *downloadUrl = versionUrls[selectedVersion];
   if (!downloadUrl || ![downloadUrl isKindOfClass:[NSString class]] || downloadUrl.length == 0) {
       [self finishDownloadWithErrorString:@"Invalid modpack download URL"];
       return;
   }
   
   // Create a temporary directory for modpack download
   NSString *tempDir = NSTemporaryDirectory();
   NSString *safeName = [[modpackName stringByReplacingOccurrencesOfString:@" " withString:@"_"] 
                        stringByReplacingOccurrencesOfString:@"/" withString:@"_"];
   safeName = [safeName stringByReplacingOccurrencesOfString:@"\\" withString:@"_"];
   safeName = [safeName stringByReplacingOccurrencesOfString:@":" withString:@"_"];
   
   NSString *packagePath = [tempDir stringByAppendingPathComponent:[NSString stringWithFormat:@"%@.zip", safeName]];
   NSString *extractPath = [NSString stringWithFormat:@"%s/profiles/%@", getenv("POJAV_GAME_DIR"), safeName];
   
   // Ensure the destination directory exists
   NSError *dirError = nil;
   [[NSFileManager defaultManager] createDirectoryAtPath:extractPath 
                             withIntermediateDirectories:YES 
                                              attributes:nil 
                                                   error:&dirError];
   if (dirError) {
       [self finishDownloadWithErrorString:[NSString stringWithFormat:@"Failed to create destination directory: %@", dirError.localizedDescription]];
       return;
   }
   
   // Download the modpack package
   NSString *displayName = [NSString stringWithFormat:@"Downloading %@", modpackName];
   NSArray *versionSizes = modDetail[@"versionSizes"];
   NSUInteger size = 0;
   
   if (versionSizes && [versionSizes isKindOfClass:[NSArray class]] && selectedVersion < versionSizes.count) {
       id sizeObj = versionSizes[selectedVersion];
       if ([sizeObj isKindOfClass:[NSNumber class]]) {
           size = [sizeObj unsignedIntegerValue];
       }
   }
   
   __weak typeof(self) weakSelf = self;
   NSURLSessionDownloadTask *packageTask = [self createDownloadTask:downloadUrl 
                                                                size:size 
                                                                 sha:nil 
                                                             altName:displayName 
                                                              toPath:packagePath 
                                                             success:^{
       __strong typeof(weakSelf) strongSelf = weakSelf;
                                                                 
       // Once the package is downloaded, let the API handle the extraction and processing
       [api downloader:strongSelf submitDownloadTasksFromPackage:packagePath toPath:extractPath];
   }];
   
   if (!packageTask) {
       [self finishDownloadWithErrorString:@"Failed to create modpack download task"];
       return;
   }
   
   // Start the download
   [packageTask resume];
}

- (NSDictionary *)getDownloadTaskInfo:(NSURLSessionDownloadTask *)task {
   if (!task) {
       return @{};
   }
   
   @synchronized(self.taskInfoMap) {
       NSDictionary *taskInfo = self.taskInfoMap[task.taskDescription];
       if (taskInfo) {
           NSMutableDictionary *info = [NSMutableDictionary dictionaryWithDictionary:taskInfo];
           
           // Remove task reference to avoid retain cycles
           [info removeObjectForKey:@"task"];
           
           // Add progress information
           NSProgress *progress = taskInfo[@"progress"];
           if (progress) {
               info[@"progress"] = @(progress.fractionCompleted);
               info[@"completed"] = @(progress.completedUnitCount);
               info[@"total"] = @(progress.totalUnitCount);
               info[@"finished"] = @(progress.finished);
           }
           
           return info;
       }
   }
   
   // Fallback: return basic info based on task
   return @{
       @"url": task.originalRequest.URL.absoluteString ?: @"",
       @"progress": @(task.progress.fractionCompleted),
       @"name": task.taskDescription ?: @"Unknown"
   };
}

- (NSArray<NSDictionary *> *)getAllDownloadedFiles {
   @synchronized(self.downloadedFiles) {
       return [self.downloadedFiles copy];
   }
}

- (void)logDownloadSource:(DownloadSource)source {
   NSString *sourceName = @"Unknown";
   
   switch (source) {
       case DownloadSourceMinecraft:
           sourceName = @"Minecraft";
           break;
       case DownloadSourceCurseForge:
           sourceName = @"CurseForge";
           break;
       case DownloadSourceModrinth:
           sourceName = @"Modrinth";
           break;
   }
   
   NSLog(@"[ResourceDownload] Source: %@", sourceName);
}

- (BOOL)checkSHA:(NSString *)sha forFile:(NSString *)path altName:(NSString *)altName {
   if (!sha || sha.length == 0 || !path || path.length == 0) {
       NSLog(@"[ResourceDownload] Invalid SHA or path provided");
       return NO;
   }
   
   // Check if file exists
   if (![[NSFileManager defaultManager] fileExistsAtPath:path]) {
       NSLog(@"[ResourceDownload] File not found for SHA check: %@", path);
       return NO;
   }
   
   NSFileHandle *fileHandle = [NSFileHandle fileHandleForReadingAtPath:path];
   if (!fileHandle) {
       NSLog(@"[ResourceDownload] Failed to open file for SHA check: %@", path);
       return NO;
   }
   
   CC_SHA1_CTX ctx;
   CC_SHA1_Init(&ctx);
   
   NSData *fileData;
   @try {
       const NSUInteger bufferSize = 4096;
       [fileHandle seekToFileOffset:0];
       
       while ((fileData = [fileHandle readDataOfLength:bufferSize]) && [fileData length] > 0) {
           CC_SHA1_Update(&ctx, [fileData bytes], (CC_LONG)[fileData length]);
       }
   } @catch (NSException *exception) {
       NSLog(@"[ResourceDownload] Exception during SHA calculation: %@", exception);
       [fileHandle closeFile];
       return NO;
   }
   
   [fileHandle closeFile];
   
   unsigned char digest[CC_SHA1_DIGEST_LENGTH];
   CC_SHA1_Final(digest, &ctx);
   
   NSMutableString *calculatedSHA = [NSMutableString stringWithCapacity:CC_SHA1_DIGEST_LENGTH * 2];
   for (int i = 0; i < CC_SHA1_DIGEST_LENGTH; i++) {
       [calculatedSHA appendFormat:@"%02x", digest[i]];
   }
   
   BOOL isMatch = [calculatedSHA.lowercaseString isEqualToString:sha.lowercaseString];
   
   if (!isMatch) {
       NSLog(@"[ResourceDownload] SHA mismatch for %@", altName ?: path.lastPathComponent);
       NSLog(@"[ResourceDownload] Expected: %@, Calculated: %@", sha, calculatedSHA);
   } else {
       NSLog(@"[ResourceDownload] SHA verified for %@", altName ?: path.lastPathComponent);
   }
   
   return isMatch;
}

@end

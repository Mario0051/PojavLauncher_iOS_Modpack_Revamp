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
@property (nonatomic, strong) NSOperationQueue *operationQueue;
@property (nonatomic, assign) NSUInteger activeDownloadsCount;
@property (nonatomic, strong) NSCache *fileCache;
@property (nonatomic, strong) dispatch_source_t progressUpdateTimer;
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
        _activeDownloadsCount = 0;
        
        // Set up a throttled update timer to reduce UI load
        _progressUpdateTimer = dispatch_source_create(DISPATCH_SOURCE_TYPE_TIMER, 0, 0, dispatch_get_main_queue());
        dispatch_source_set_timer(_progressUpdateTimer, dispatch_time(DISPATCH_TIME_NOW, 0), 250 * NSEC_PER_MSEC, 50 * NSEC_PER_MSEC);
        dispatch_source_set_event_handler(_progressUpdateTimer, ^{
            [self updateAllProgressIndicators];
        });
        dispatch_resume(_progressUpdateTimer);
        
        // Create dispatch queue and semaphore for concurrent download management
        // Use an adaptive semaphore limit based on device capabilities
        int maxConcurrentTasks = MAX(3, MIN(10, NSProcessInfo.processInfo.processorCount * 2));
        _downloadQueue = dispatch_queue_create("com.pojavlauncher.download", DISPATCH_QUEUE_CONCURRENT);
        _downloadSemaphore = dispatch_semaphore_create(maxConcurrentTasks);
        _operationQueue = [[NSOperationQueue alloc] init];
        _operationQueue.maxConcurrentOperationCount = maxConcurrentTasks;
        
        // Create file cache for small data items
        _fileCache = [[NSCache alloc] init];
        _fileCache.countLimit = 100;
        _fileCache.totalCostLimit = 10 * 1024 * 1024; // 10MB cache limit
        
        // Create the session with optimized configuration
        NSURLSessionConfiguration *config = [NSURLSessionConfiguration defaultSessionConfiguration];
        config.timeoutIntervalForRequest = 60.0;
        config.timeoutIntervalForResource = 300.0; // 5 minutes timeout for total resource
        config.HTTPMaximumConnectionsPerHost = maxConcurrentTasks;
        config.requestCachePolicy = NSURLRequestUseProtocolCachePolicy;
        config.networkServiceType = NSURLNetworkServiceTypeDefault;
        
        if (@available(iOS 13.0, *)) {
            // Use more aggressive connection settings on newer iOS
            config.multipathServiceType = NSURLSessionMultipathServiceTypeHandover;
        }
        
        _session = [NSURLSession sessionWithConfiguration:config 
                                                delegate:nil 
                                           delegateQueue:_operationQueue];
    }
    return self;
}

- (void)dealloc {
    // Clean up timer and any pending operations
    if (_progressUpdateTimer) {
        dispatch_source_cancel(_progressUpdateTimer);
        _progressUpdateTimer = nil;
    }
    
    // Cancel all downloads
    [self cancelAllTasks];
    
    // Invalidate the session
    [_session invalidateAndCancel];
}

- (void)updateAllProgressIndicators {
    // This method is called on a timer to update progress indicators
    // instead of updating for every byte downloaded
    
    // Update overall progress based on tasks completion
    if (self.progress) {
        NSUInteger totalCompleted = 0;
        NSUInteger total = 0;
        
        @synchronized(self.progressList) {
            for (NSProgress *progress in self.progressList) {
                totalCompleted += progress.completedUnitCount;
                total += progress.totalUnitCount;
            }
        }
        
        // Update main progress to reflect overall status
        if (total > 0) {
            self.progress.completedUnitCount = totalCompleted;
            self.progress.totalUnitCount = total;
        }
        
        // Update text description
        self.textProgress.localizedDescription = [NSString stringWithFormat:@"Downloading files: %lu of %lu", 
                                                 (unsigned long)self.downloadedFiles.count, 
                                                 (unsigned long)self.downloadTasks.count];
    }
}

- (void)cancelAllTasks {
    // Stop the progress update timer
    if (_progressUpdateTimer) {
        dispatch_source_cancel(_progressUpdateTimer);
        _progressUpdateTimer = nil;
    }
    
    // Cancel all pending tasks
    @synchronized(self.downloadTasks) {
        for (NSURLSessionDownloadTask *task in [self.downloadTasks allValues]) {
            [task cancel];
        }
        [self.downloadTasks removeAllObjects];
    }
    
    // Cancel overall progress
    [self.progress cancel];
    
    // Update progress text
    self.textProgress.localizedDescription = @"Download cancelled";
    
    NSLog(@"[ResourceDownload] All tasks cancelled");
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
    
    // Make sure all in-progress tasks are marked as complete
    @synchronized(self.progressList) {
        for (NSProgress *progress in self.progressList) {
            if (progress.fractionCompleted < 1.0) {
                progress.completedUnitCount = progress.totalUnitCount;
            }
        }
    }
    
    // Stop the progress update timer
    if (_progressUpdateTimer) {
        dispatch_source_cancel(_progressUpdateTimer);
        _progressUpdateTimer = nil;
    }
    
    NSLog(@"[ResourceDownload] Task marked as fully completed");
}

- (void)finishDownloadWithErrorString:(NSString *)error {
    NSLog(@"[ResourceDownload] Error: %@", error);
    
    // Update progress to show error
    dispatch_async(dispatch_get_main_queue(), ^{
        self.textProgress.localizedDescription = [NSString stringWithFormat:@"Error: %@", error];
        
        // Mark progress as failed
        [self.progress cancel];
        
        // Call the error handler if provided
        if (self.handleError) {
            self.handleError();
        }
    });
}

- (void)downloadVersion:(NSDictionary *)version {
    [self prepareForDownload];
    
    NSString *versionId = version[@"id"];
    if (!versionId) {
        [self finishDownloadWithErrorString:@"Invalid version: missing ID"];
        return;
    }
    
    NSLog(@"[ResourceDownload] Starting download for version %@", versionId);
    
    // Update metadata
    self.metadata[@"versionId"] = versionId;
    
    // Prepare paths
    NSString *versionDir = [NSString stringWithFormat:@"%s/versions/%@", getenv("POJAV_GAME_DIR"), versionId];
    NSString *versionJsonPath = [NSString stringWithFormat:@"%@/%@.json", versionDir, versionId];
    
    // Check if we need to download the JSON
    BOOL jsonExists = [[NSFileManager defaultManager] fileExistsAtPath:versionJsonPath];
    
    // If the version is a special template (latest-release or latest-snapshot), get the actual version
    if ([versionId isEqualToString:@"latest-release"] || [versionId isEqualToString:@"latest-snapshot"]) {
        NSDictionary *versionInfo = getPrefObject(@"internal.latest_version");
        if (versionInfo) {
            versionId = versionInfo[[versionId isEqualToString:@"latest-release"] ? @"release" : @"snapshot"];
            self.metadata[@"versionId"] = versionId;
            
            // Update paths with the resolved version
            versionDir = [NSString stringWithFormat:@"%s/versions/%@", getenv("POJAV_GAME_DIR"), versionId];
            versionJsonPath = [NSString stringWithFormat:@"%@/%@.json", versionDir, versionId];
            jsonExists = [[NSFileManager defaultManager] fileExistsAtPath:versionJsonPath];
        }
    }
    
    // Add inheritance handling
    if ([versionId containsString:@"forge"] || [versionId containsString:@"fabric"] || [versionId containsString:@"quilt"]) {
        self.metadata[@"hasModLoader"] = @YES;
    }
    
    // Create version directory if it doesn't exist
    if (![[NSFileManager defaultManager] fileExistsAtPath:versionDir]) {
        [[NSFileManager defaultManager] createDirectoryAtPath:versionDir withIntermediateDirectories:YES attributes:nil error:nil];
    }
    
    // Step 1: Get the version JSON
    NSString *jsonUrl = [NSString stringWithFormat:@"https://piston-meta.mojang.com/v1/packages/%@/%@.json", versionId, versionId];
    if (!jsonExists) {
        NSURLSessionDownloadTask *jsonTask = [self createDownloadTask:jsonUrl
                                                                 size:0
                                                                  sha:nil
                                                              altName:@"Downloading version info"
                                                               toPath:versionJsonPath
                                                              success:^{
            // Process the version JSON to download dependencies
            [self processVersionJSON:versionJsonPath];
        }];
        
        if (jsonTask) {
            [jsonTask resume];
        } else {
            [self finishDownloadWithErrorString:@"Failed to create download task for version JSON"];
        }
    } else {
        // JSON already exists, process it directly
        [self processVersionJSON:versionJsonPath];
    }
}

- (void)processVersionJSON:(NSString *)jsonPath {
    // Parse the JSON file
    NSError *error = nil;
    NSData *jsonData = [NSData dataWithContentsOfFile:jsonPath options:0 error:&error];
    if (!jsonData) {
        [self finishDownloadWithErrorString:[NSString stringWithFormat:@"Failed to read version JSON: %@", error.localizedDescription]];
        return;
    }
    
    NSDictionary *versionJson = [NSJSONSerialization JSONObjectWithData:jsonData options:0 error:&error];
    if (!versionJson) {
        [self finishDownloadWithErrorString:[NSString stringWithFormat:@"Failed to parse version JSON: %@", error.localizedDescription]];
        return;
    }
    
    // Handle inheritsFrom if present
    if (versionJson[@"inheritsFrom"]) {
        NSString *parentId = versionJson[@"inheritsFrom"];
        NSString *parentJsonPath = [NSString stringWithFormat:@"%s/versions/%@/%@.json", getenv("POJAV_GAME_DIR"), parentId, parentId];
        
        if (![[NSFileManager defaultManager] fileExistsAtPath:parentJsonPath]) {
            // Need to download the parent version first
            NSDictionary *parentVersion = @{@"id": parentId, @"type": @"release"};
            [self downloadVersion:parentVersion];
            return;
        }
        
        // Load parent JSON
        NSData *parentJsonData = [NSData dataWithContentsOfFile:parentJsonPath options:0 error:&error];
        if (!parentJsonData) {
            [self finishDownloadWithErrorString:[NSString stringWithFormat:@"Failed to read parent version JSON: %@", error.localizedDescription]];
            return;
        }
        
        NSMutableDictionary *parentVersionJson = [[NSJSONSerialization JSONObjectWithData:parentJsonData options:NSJSONReadingMutableContainers error:&error] mutableCopy];
        if (!parentVersionJson) {
            [self finishDownloadWithErrorString:[NSString stringWithFormat:@"Failed to parse parent version JSON: %@", error.localizedDescription]];
            return;
        }
        
        // Process inheritance
        [MinecraftResourceUtils processVersion:versionJson.mutableCopy inheritsFrom:parentVersionJson];
        versionJson = parentVersionJson;
    }
    
    // Tweak version JSON for PojavLauncher
    NSMutableDictionary *tweakedJson = [versionJson mutableCopy];
    [MinecraftResourceUtils tweakVersionJson:tweakedJson];
    
    // Save the tweaked JSON back if needed
    if (![tweakedJson isEqual:versionJson]) {
        NSError *saveError = nil;
        NSData *tweakedData = [NSJSONSerialization dataWithJSONObject:tweakedJson options:NSJSONWritingPrettyPrinted error:&saveError];
        if (!tweakedData) {
            NSLog(@"[ResourceDownload] Warning: Failed to serialize tweaked JSON: %@", saveError.localizedDescription);
        } else {
            [tweakedData writeToFile:jsonPath options:NSDataWritingAtomic error:&saveError];
            if (saveError) {
                NSLog(@"[ResourceDownload] Warning: Failed to write tweaked JSON: %@", saveError.localizedDescription);
            }
        }
    }
    
    // Start downloading libraries, assets, and client JAR
    [self downloadLibraries:tweakedJson];
    [self downloadAssets:tweakedJson];
    [self downloadClient:tweakedJson];
    
    // Mark metadata for launching
    self.metadata[@"allTasksComplete"] = @YES;
}

- (void)downloadLibraries:(NSDictionary *)versionJson {
    NSArray *libraries = versionJson[@"libraries"];
    if (!libraries || ![libraries isKindOfClass:[NSArray class]]) {
        NSLog(@"[ResourceDownload] No libraries to download");
        return;
    }
    
    for (NSDictionary *library in libraries) {
        // Skip libraries marked for skipping
        if ([library[@"skip"] boolValue]) {
            continue;
        }
        
        NSDictionary *downloads = library[@"downloads"];
        NSDictionary *artifact = downloads[@"artifact"];
        
        if (!artifact) {
            continue;
        }
        
        NSString *path = artifact[@"path"];
        NSString *url = artifact[@"url"];
        NSNumber *size = artifact[@"size"];
        NSString *sha1 = artifact[@"sha1"];
        
        if (!url || !path) {
            continue;
        }
        
        NSString *destPath = [NSString stringWithFormat:@"%s/libraries/%@", getenv("POJAV_GAME_DIR"), path];
        
        // Create download task
        NSURLSessionDownloadTask *libraryTask = [self createDownloadTask:url
                                                                    size:[size unsignedIntegerValue]
                                                                     sha:sha1
                                                                 altName:[NSString stringWithFormat:@"Library: %@", [path lastPathComponent]]
                                                                  toPath:destPath];
        
        if (libraryTask) {
            [libraryTask resume];
        }
    }
}

- (void)downloadAssets:(NSDictionary *)versionJson {
    NSDictionary *assetIndex = versionJson[@"assetIndex"];
    if (!assetIndex) {
        NSLog(@"[ResourceDownload] No asset index to download");
        return;
    }
    
    NSString *indexId = assetIndex[@"id"];
    NSString *indexUrl = assetIndex[@"url"];
    NSNumber *indexSize = assetIndex[@"size"];
    NSString *indexSha1 = assetIndex[@"sha1"];
    
    if (!indexId || !indexUrl) {
        return;
    }
    
    NSString *indexPath = [NSString stringWithFormat:@"%s/assets/indexes/%@.json", getenv("POJAV_GAME_DIR"), indexId];
    
    // Create necessary directories
    [[NSFileManager defaultManager] createDirectoryAtPath:[indexPath stringByDeletingLastPathComponent]
                               withIntermediateDirectories:YES
                                                attributes:nil
                                                     error:nil];
    
    // Download asset index
    NSURLSessionDownloadTask *indexTask = [self createDownloadTask:indexUrl
                                                             size:[indexSize unsignedIntegerValue]
                                                              sha:indexSha1
                                                          altName:[NSString stringWithFormat:@"Asset Index: %@", indexId]
                                                           toPath:indexPath
                                                          success:^{
        // Parse the asset index and download assets
        [self downloadAssetsFromIndex:indexPath];
    }];
    
    if (indexTask) {
        [indexTask resume];
    }
}

- (void)downloadAssetsFromIndex:(NSString *)indexPath {
    NSError *error = nil;
    NSData *indexData = [NSData dataWithContentsOfFile:indexPath options:0 error:&error];
    if (!indexData) {
        NSLog(@"[ResourceDownload] Failed to read asset index: %@", error.localizedDescription);
        return;
    }
    
    NSDictionary *assetIndex = [NSJSONSerialization JSONObjectWithData:indexData options:0 error:&error];
    if (!assetIndex) {
        NSLog(@"[ResourceDownload] Failed to parse asset index: %@", error.localizedDescription);
        return;
    }
    
    NSDictionary *objects = assetIndex[@"objects"];
    if (!objects || ![objects isKindOfClass:[NSDictionary class]]) {
        NSLog(@"[ResourceDownload] No assets to download");
        return;
    }
    
    for (NSString *assetName in objects) {
        NSDictionary *asset = objects[assetName];
        NSString *hash = asset[@"hash"];
        NSNumber *size = asset[@"size"];
        
        if (!hash) {
            continue;
        }
        
        NSString *hashPrefix = [hash substringToIndex:2];
        NSString *assetUrl = [NSString stringWithFormat:@"https://resources.download.minecraft.net/%@/%@", hashPrefix, hash];
        NSString *assetPath = [NSString stringWithFormat:@"%s/assets/objects/%@/%@", getenv("POJAV_GAME_DIR"), hashPrefix, hash];
        
        // Create download task
        NSURLSessionDownloadTask *assetTask = [self createDownloadTask:assetUrl
                                                                  size:[size unsignedIntegerValue]
                                                                   sha:hash
                                                               altName:[NSString stringWithFormat:@"Asset: %@", assetName]
                                                                toPath:assetPath];
        
        if (assetTask) {
            [assetTask resume];
        }
    }
}

- (void)downloadClient:(NSDictionary *)versionJson {
    NSDictionary *clientDownload = versionJson[@"downloads"][@"client"];
    if (!clientDownload) {
        NSLog(@"[ResourceDownload] No client to download");
        return;
    }
    
    NSString *clientUrl = clientDownload[@"url"];
    NSNumber *clientSize = clientDownload[@"size"];
    NSString *clientSha1 = clientDownload[@"sha1"];
    NSString *versionId = versionJson[@"id"];
    
    if (!clientUrl || !versionId) {
        return;
    }
    
    NSString *clientPath = [NSString stringWithFormat:@"%s/versions/%@/%@.jar", getenv("POJAV_GAME_DIR"), versionId, versionId];
    
    // Download client JAR
    NSURLSessionDownloadTask *clientTask = [self createDownloadTask:clientUrl
                                                              size:[clientSize unsignedIntegerValue]
                                                               sha:clientSha1
                                                           altName:[NSString stringWithFormat:@"Client JAR: %@", versionId]
                                                            toPath:clientPath];
    
    if (clientTask) {
        [clientTask resume];
    }
}

- (void)downloadModpackFromAPI:(ModpackAPI *)api detail:(NSDictionary *)modDetail atIndex:(NSUInteger)selectedVersion {
    [self prepareForDownload];
    
    // Get URL for the selected version
    NSArray *versionUrls = modDetail[@"versionUrls"];
    if (!versionUrls || selectedVersion >= versionUrls.count) {
        [self finishDownloadWithErrorString:@"Invalid modpack version selected"];
        return;
    }
    
    // Log the selected version and source
    NSString *modpackName = modDetail[@"title"] ?: @"Unknown Modpack";
    NSLog(@"[ResourceDownload] Starting download for modpack: %@ (version index: %lu)", 
          modpackName, (unsigned long)selectedVersion);
    
    // Update metadata
    self.metadata[@"modpackName"] = modpackName;
    self.metadata[@"isModpack"] = @YES;
    
    // Get URL and create temporary path
    NSString *urlString = versionUrls[selectedVersion];
    NSString *tempDir = NSTemporaryDirectory();
    NSString *safeModpackName = [modpackName stringByReplacingOccurrencesOfString:@" " withString:@"_"];
    safeModpackName = [safeModpackName stringByReplacingOccurrencesOfString:@"/" withString:@"_"];
    NSString *zipPath = [tempDir stringByAppendingPathComponent:[NSString stringWithFormat:@"%@.zip", safeModpackName]];
    
    // Download the modpack ZIP
    NSURLSessionDownloadTask *downloadTask = [self createDownloadTask:urlString
                                                                 size:0 // Size will be determined from response
                                                                  sha:nil
                                                              altName:[NSString stringWithFormat:@"Downloading %@", modpackName]
                                                               toPath:zipPath
                                                              success:^{
        // Have the API handle the modpack extraction and installation
        [api downloader:self submitDownloadTasksFromPackage:zipPath toPath:nil];
    }];
    
    if (downloadTask) {
        [downloadTask resume];
    } else {
        [self finishDownloadWithErrorString:@"Failed to create download task for modpack"];
    }
}

- (NSDictionary *)getDownloadTaskInfo:(NSURLSessionDownloadTask *)task {
    if (!task) {
        return @{};
    }
    
    @synchronized(self.taskInfoMap) {
        return [self.taskInfoMap[task.taskDescription] copy] ?: @{};
    }
}

- (NSArray<NSDictionary *> *)getAllDownloadedFiles {
    @synchronized(self.downloadedFiles) {
        return [self.downloadedFiles copy];
    }
}

- (void)logDownloadSource:(DownloadSource)source {
    NSString *sourceName;
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
        default:
            sourceName = @"Unknown";
            break;
    }
    
    NSLog(@"[ResourceDownload] Download source: %@", sourceName);
}

- (void)checkForCompletionAndFinalize {
    // Check if all tasks are complete
    BOOL allComplete = YES;
    
    @synchronized(self.downloadTasks) {
        if (self.downloadTasks.count == 0) {
            allComplete = YES;
        } else {
            for (NSURLSessionDownloadTask *task in [self.downloadTasks allValues]) {
                if (task.state != NSURLSessionTaskStateCompleted && 
                    task.state != NSURLSessionTaskStateCanceling &&
                    task.state != NSURLSessionTaskStateCompleted) {
                    allComplete = NO;
                    break;
                }
            }
        }
    }
    
    // Also check if there are any active downloads
    @synchronized(self) {
        if (self.activeDownloadsCount > 0) {
            allComplete = NO;
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
        
        // Ensure the task is explicitly marked as completed
        [self markAsCompleted];
    } else {
        // Not all tasks are complete, check again after a delay
        NSLog(@"[ResourceDownload] Some tasks still in progress, checking again later");
        
        // Continue checking until completion or timeout
        static NSInteger checkCount = 0;
        if (checkCount < 60) { // Maximum of ~3 minutes of checking
            checkCount++;
            dispatch_after(dispatch_time(DISPATCH_TIME_NOW, (int64_t)(3 * NSEC_PER_SEC)), dispatch_get_main_queue(), ^{
                [self checkForCompletionAndFinalize];
            });
        } else {
            // If we've checked too many times, force completion
            NSLog(@"[ResourceDownload] Forcing completion after timeout");
            self.metadata[@"allTasksComplete"] = @YES;
            [self markAsCompleted];
        }
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
    self.activeDownloadsCount = 0;
    
    // Reset the progress update timer
    if (self.progressUpdateTimer) {
        dispatch_source_cancel(self.progressUpdateTimer);
    }
    
    self.progressUpdateTimer = dispatch_source_create(DISPATCH_SOURCE_TYPE_TIMER, 0, 0, dispatch_get_main_queue());
    dispatch_source_set_timer(self.progressUpdateTimer, dispatch_time(DISPATCH_TIME_NOW, 0), 250 * NSEC_PER_MSEC, 50 * NSEC_PER_MSEC);
    dispatch_source_set_event_handler(self.progressUpdateTimer, ^{
        [self updateAllProgressIndicators];
    });
    dispatch_resume(self.progressUpdateTimer);
    
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
    
    // Check if file already exists and has correct SHA (if provided)
    if ([[NSFileManager defaultManager] fileExistsAtPath:path]) {
        if (!sha || sha.length == 0 || [self checkSHA:sha forFile:path altName:altName]) {
            NSLog(@"[ResourceDownload] File already exists with correct SHA: %@", path);
            
            // Create a completed progress object for tracking
            NSProgress *fileProgress = [NSProgress progressWithTotalUnitCount:size > 0 ? size : 1];
            fileProgress.completedUnitCount = fileProgress.totalUnitCount; // Already complete
            fileProgress.kind = NSProgressKindFile;
            fileProgress.fileOperationKind = NSProgressFileOperationKindDownloading;
            
            @synchronized(self) {
                [self.fileList addObject:altName ?: [url lastPathComponent]];
                [self.progressList addObject:fileProgress];
                [self.progress addChild:fileProgress withPendingUnitCount:1];
                
                // Add to downloaded files list
                NSMutableDictionary *fileInfo = [NSMutableDictionary dictionary];
                fileInfo[@"path"] = path;
                fileInfo[@"url"] = url;
                fileInfo[@"name"] = altName ?: [url lastPathComponent];
                fileInfo[@"size"] = @(size);
                if (sha.length > 0) {
                    fileInfo[@"sha"] = sha;
                }
                [self.downloadedFiles addObject:fileInfo];
            }
            
            // Call success callback if provided
            if (success) {
                dispatch_async(dispatch_get_main_queue(), ^{
                    success();
                });
            }
            
            // Create a task that's already "complete" for consistent tracking
            NSURLSessionDownloadTask *dummyTask = [self.session downloadTaskWithURL:[NSURL URLWithString:url] completionHandler:^(NSURL *location, NSURLResponse *response, NSError *error) {
                // This task never actually executes since we're not resuming it
            }];
            
            return dummyTask;
        } else {
            // SHA doesn't match, delete the existing file
            NSError *removeError = nil;
            [[NSFileManager defaultManager] removeItemAtPath:path error:&removeError];
            if (removeError) {
                NSLog(@"[ResourceDownload] Failed to remove existing file with incorrect SHA: %@", removeError);
            }
        }
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
        
        // Increment active downloads counter
        self.activeDownloadsCount++;
    }
    
    // Create download task with optimized request
    NSURL *downloadURL = [NSURL URLWithString:url];
    NSMutableURLRequest *request = [NSMutableURLRequest requestWithURL:downloadURL];
    request.timeoutInterval = 60.0;
    request.cachePolicy = NSURLRequestUseProtocolCachePolicy;
    
    // Set up header fields for better caching
    [request setValue:@"gzip, deflate" forHTTPHeaderField:@"Accept-Encoding"];
    
    // Use Etag or Last-Modified if available
    NSString *cachedEtag = [self.fileCache objectForKey:[NSString stringWithFormat:@"etag-%@", url]];
    if (cachedEtag) {
        [request setValue:cachedEtag forHTTPHeaderField:@"If-None-Match"];
    }
    
    NSString *cachedLastModified = [self.fileCache objectForKey:[NSString stringWithFormat:@"lastmod-%@", url]];
    if (cachedLastModified) {
        [request setValue:cachedLastModified forHTTPHeaderField:@"If-Modified-Since"];
    }
    
    __weak typeof(self) weakSelf = self;
    NSURLSessionDownloadTask *task = [self.session downloadTaskWithRequest:request completionHandler:^(NSURL *location, NSURLResponse *response, NSError *error) {
        __strong typeof(weakSelf) strongSelf = weakSelf;
        if (!strongSelf) return;
        
        @synchronized(strongSelf) {
            // Decrement active downloads counter
            strongSelf.activeDownloadsCount--;
        }
        
        if (error) {
            NSLog(@"[ResourceDownload] Failed to download %@: %@", url, error);
            
            // Mark progress as failed
            fileProgress.completedUnitCount = 0;
            [fileProgress cancel];
            
            // Return semaphore token
            dispatch_semaphore_signal(strongSelf.downloadSemaphore);
            
            if (strongSelf.handleError) {
                dispatch_async(dispatch_get_main_queue(), ^{
                    strongSelf.handleError();
                });
            }
            return;
        }
        
        // Check for HTTP status code
        if ([response isKindOfClass:[NSHTTPURLResponse class]]) {
            NSHTTPURLResponse *httpResponse = (NSHTTPURLResponse *)response;
            
            if (httpResponse.statusCode == 304) {
                // Not modified, use cached file
                NSLog(@"[ResourceDownload] Using cached file for %@", url);
                fileProgress.completedUnitCount = fileProgress.totalUnitCount;
                
                // Return semaphore token
                dispatch_semaphore_signal(strongSelf.downloadSemaphore);
                
                if (success) {
                    dispatch_async(dispatch_get_main_queue(), ^{
                        success();
                    });
                }
                return;
            }
            
            // Update cache headers for future requests
            NSString *etag = [httpResponse.allHeaderFields objectForKey:@"Etag"];
            if (etag) {
                [strongSelf.fileCache setObject:etag forKey:[NSString stringWithFormat:@"etag-%@", url]];
            }
            
            NSString *lastModified = [httpResponse.allHeaderFields objectForKey:@"Last-Modified"];
            if (lastModified) {
                [strongSelf.fileCache setObject:lastModified forKey:[NSString stringWithFormat:@"lastmod-%@", url]];
            }
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
            
            // Return semaphore token
            dispatch_semaphore_signal(strongSelf.downloadSemaphore);
            
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
                
                // Return semaphore token
                dispatch_semaphore_signal(strongSelf.downloadSemaphore);
                
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
        
        // Return semaphore token
        dispatch_semaphore_signal(strongSelf.downloadSemaphore);
        
        // Call success callback if provided
        if (success) {
            dispatch_async(dispatch_get_main_queue(), ^{
                success();
            });
        }
        
        NSLog(@"[ResourceDownload] Successfully downloaded %@ to %@", displayName, path);
    }];
    
    // Wait for a semaphore token before starting the download
    dispatch_async(dispatch_get_global_queue(DISPATCH_QUEUE_PRIORITY_DEFAULT, 0), ^{
        dispatch_semaphore_wait(self.downloadSemaphore, DISPATCH_TIME_FOREVER);
        [task resume];
    });
    
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

// Optimized SHA verification - using buffered reading for large files
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
    
    // Get file attributes to check size
    NSError *attributesError = nil;
    NSDictionary *attributes = [[NSFileManager defaultManager] attributesOfItemAtPath:path error:&attributesError];
    if (attributesError) {
        NSLog(@"[ResourceDownload] Failed to get file attributes: %@", attributesError);
        return NO;
    }
    
    // For very small files (< 1KB), use the simple approach
    if ([attributes fileSize] < 1024) {
        NSData *fileData = [NSData dataWithContentsOfFile:path];
        if (!fileData) {
            NSLog(@"[ResourceDownload] Failed to read file for SHA check: %@", path);
            return NO;
        }
        
        unsigned char digest[CC_SHA1_DIGEST_LENGTH];
        CC_SHA1(fileData.bytes, (CC_LONG)fileData.length, digest);
        
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
    
    // For larger files, use buffered reading
    NSFileHandle *fileHandle = [NSFileHandle fileHandleForReadingAtPath:path];
    if (!fileHandle) {
        NSLog(@"[ResourceDownload] Failed to open file for SHA check: %@", path);
        return NO;
    }
    
    CC_SHA1_CTX ctx;
    CC_SHA1_Init(&ctx);
    
    @try {
        const NSUInteger bufferSize = 65536; // 64KB buffer
        [fileHandle seekToFileOffset:0];
        
        NSData *fileData;
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

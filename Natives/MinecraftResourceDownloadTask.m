#include <CommonCrypto/CommonDigest.h>

#import "authenticator/BaseAuthenticator.h"
#import "installer/modpack/ModpackAPI.h"
#import "installer/modpack/ModrinthAPI.h"
#import "AFNetworking.h"
#import "LauncherNavigationController.h"
#import "LauncherPreferences.h"
#import "MinecraftResourceDownloadTask.h"
#import "PLProfiles.h"
#import "MinecraftResourceUtils.h"
#import "ios_uikit_bridge.h"
#import "utils.h"

@interface MinecraftResourceDownloadTask ()
@property AFURLSessionManager* manager;
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
    self.currentStage = @"Initializing";
    return self;
}

// Add file to the queue
- (NSURLSessionDownloadTask *)createDownloadTask:(NSString *)url size:(NSUInteger)size sha:(NSString *)sha altName:(NSString *)altName toPath:(NSString *)path success:(void (^)(void))success {
    NSLog(@"[DownloadTask] Creating download task - URL: %@, Path: %@, Size: %lu", url, path, (unsigned long)size);
    
    // Validate URL
    if (!url || url.length == 0 || ![NSURL URLWithString:url]) {
        NSLog(@"[DownloadTask] Invalid URL provided: %@", url);
        if (success) success();
        return nil;
    }
    
    BOOL fileExists = [NSFileManager.defaultManager fileExistsAtPath:path];
    NSLog(@"[DownloadTask] File exists at destination: %@", fileExists ? @"YES" : @"NO");
    
    // Check if file already exists and SHA matches
    if (fileExists && [self checkSHA:sha forFile:path altName:altName]) {
        NSLog(@"[DownloadTask] File already exists and SHA matches. Skipping download.");
        if (success) success();
        return nil;
    } else if (![self checkAccessWithDialog:YES]) {
        NSLog(@"[DownloadTask] Access check failed. Cancelling download.");
        return nil;
    }

    NSString *name = altName ?: path.lastPathComponent;
    NSLog(@"[DownloadTask] Display name for download: %@", name);
    
    NSURLRequest *request = [NSURLRequest requestWithURL:[NSURL URLWithString:url]];
    NSLog(@"[DownloadTask] Created URL request for: %@", url);
    
    __block NSProgress *progress;
    __block NSURLSessionDownloadTask *task = [self.manager downloadTaskWithRequest:request progress:nil
    destination:^NSURL * _Nonnull(NSURL * _Nonnull targetPath, NSURLResponse * _Nonnull response) {
        NSLog(@"[DownloadTask] Download started for: %@", name);
        self.currentStage = [NSString stringWithFormat:@"Downloading %@", name];
        progress = [self.manager downloadProgressForTask:task];
        
        if (!size && task) {
            NSLog(@"[DownloadTask] No size provided, using response size: %lld", response.expectedContentLength);
            [self addDownloadTaskToProgress:task size:response.expectedContentLength];
            [self.fileList addObject:name];
        }
        
        NSString *dirPath = path.stringByDeletingLastPathComponent;
        NSLog(@"[DownloadTask] Creating directory at: %@", dirPath);
        NSError *dirError = nil;
        BOOL dirCreated = [NSFileManager.defaultManager createDirectoryAtPath:dirPath 
                                                   withIntermediateDirectories:YES 
                                                                    attributes:nil 
                                                                         error:&dirError];
        if (!dirCreated) {
            NSLog(@"[DownloadTask] Failed to create directory: %@", dirError.localizedDescription);
        }
        
        [NSFileManager.defaultManager removeItemAtPath:path error:nil];
        return [NSURL fileURLWithPath:path];
    } completionHandler:^(NSURLResponse * _Nonnull response, NSURL * _Nullable filePath, NSError * _Nullable error) {
        if (self.progress.cancelled) {
            NSLog(@"[DownloadTask] Download cancelled for: %@", name);
            // Ignore any further errors
        } else if (error != nil) {
            NSLog(@"[DownloadTask] Download error for %@: %@", name, error.localizedDescription);
            [self finishDownloadWithError:error file:name];
        } else if (![self checkSHA:sha forFile:path altName:altName]) {
            NSLog(@"[DownloadTask] SHA verification failed for: %@", name);
            [self finishDownloadWithErrorString:[NSString stringWithFormat:@"Failed to verify file %@: SHA1 mismatch", path.lastPathComponent]];
        } else {
            NSLog(@"[DownloadTask] Download completed successfully for: %@", name);
            progress.totalUnitCount = progress.completedUnitCount;
            self.currentStage = [NSString stringWithFormat:@"Completed %@", name];
            if (success) success();
        }
    }];

    if (size && task) {
        NSLog(@"[DownloadTask] Added task to progress tracker with size: %lu", (unsigned long)size);
        [self addDownloadTaskToProgress:task size:size];
        [self.fileList addObject:name];
    } else if (!task) {
        NSLog(@"[DownloadTask] Failed to create download task");
    }

    NSLog(@"[DownloadTask] Returning download task: %@", task ? @"Valid task" : @"nil");
    return task;
}

- (NSURLSessionDownloadTask *)createDownloadTask:(NSString *)url size:(NSUInteger)size sha:(NSString *)sha altName:(NSString *)altName toPath:(NSString *)path {
    return [self createDownloadTask:url size:size sha:sha altName:altName toPath:path success:nil];
}

- (void)addDownloadTaskToProgress:(NSURLSessionDownloadTask *)task size:(NSInteger)size {
    NSProgress *progress = [self.manager downloadProgressForTask:task];
    NSUInteger fileSize = size>0 ? size : 1;
    progress.kind = NSProgressKindFile;
    if (size > 0) {
        progress.totalUnitCount = fileSize;
    }
    [self.progressList addObject:progress];
    [self.progress addChild:progress withPendingUnitCount:fileSize];
    self.progress.totalUnitCount += fileSize;
    self.textProgress.totalUnitCount = self.progress.totalUnitCount;
}

- (void)downloadVersionMetadata:(NSDictionary *)version success:(void (^)())success {
    // Download base json
    self.currentStage = @"Preparing version metadata";
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
            self.currentStage = @"Processing inherited version";
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

- (void)downloadAssetMetadataWithSuccess:(void (^)())success {
    self.currentStage = @"Downloading asset index";
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

#pragma mark - Minecraft installation

- (NSArray *)downloadClientLibraries {
    self.currentStage = @"Downloading libraries";
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
    self.currentStage = @"Downloading game assets";
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
    [self prepareForDownload];
    self.currentStage = @"Starting download";
    [self downloadVersionMetadata:version success:^{
        [self downloadAssetMetadataWithSuccess:^{
            NSArray *libTasks = [self downloadClientLibraries];
            NSArray *assetTasks = [self downloadClientAssets];
            // Drop the 1 byte we set initially
            self.progress.totalUnitCount--;
            self.textProgress.totalUnitCount--;
            if (self.progress.totalUnitCount == 0) {
                // We have nothing to download, invoke completion observer
                self.progress.totalUnitCount = 1;
                self.progress.completedUnitCount = 1;
                self.textProgress.totalUnitCount = 1;
                self.textProgress.completedUnitCount = 1;
                self.currentStage = @"Download completed";
                return;
            }
            [libTasks makeObjectsPerformSelector:@selector(resume)];
            [assetTasks makeObjectsPerformSelector:@selector(resume)];
            [self.metadata removeObjectForKey:@"assetIndexObj"];
        }];
    }];
}

#pragma mark - Modpack installation

- (void)downloadModpackFromAPI:(ModpackAPI *)api detail:(NSDictionary *)modDetail atIndex:(NSUInteger)selectedVersion {
    [self prepareForDownload];
    self.currentStage = @"Preparing modpack download";

    NSString *url = modDetail[@"versionUrls"][selectedVersion];
    NSUInteger size = [modDetail[@"versionSizes"][selectedVersion] unsignedLongLongValue];
    NSString *sha = modDetail[@"versionHashes"][selectedVersion];
    NSString *name = [[modDetail[@"title"] lowercaseString] stringByTrimmingCharactersInSet:NSCharacterSet.whitespaceCharacterSet];
    name = [name stringByReplacingOccurrencesOfString:@" " withString:@"_"];
    NSString *packagePath = [NSTemporaryDirectory() stringByAppendingFormat:@"/%@.zip", name];

    NSURLSessionDownloadTask *task = [self createDownloadTask:url size:size sha:sha altName:nil toPath:packagePath success:^{
        self.currentStage = @"Extracting modpack";
        NSString *path = [NSString stringWithFormat:@"%s/custom_gamedir/%@", getenv("POJAV_GAME_DIR"), name];
        [api downloader:self submitDownloadTasksFromPackage:packagePath toPath:path];
    }];
    [task resume];
}

#pragma mark - Mod installation

- (void)downloadModFromDetail:(NSDictionary *)modDetail atIndex:(NSUInteger)selectedVersion {
    [self prepareForDownload];
    self.currentStage = @"Preparing mod download";
    
    // Initialize dependency tracking
    if (!self.dependencyQueue) {
        self.dependencyQueue = [NSMutableArray new];
    } else {
        [self.dependencyQueue removeAllObjects];
    }
    
    if (!self.processedDependencyIds) {
        self.processedDependencyIds = [NSMutableSet new];
    } else {
        [self.processedDependencyIds removeAllObjects];
    }
    
    self.processingDependencies = NO;
    
    NSString *url = modDetail[@"versionUrls"][selectedVersion];
    NSUInteger size = [modDetail[@"versionSizes"][selectedVersion] unsignedLongLongValue];
    NSString *sha = modDetail[@"versionHashes"][selectedVersion];
    NSString *modName = modDetail[@"title"];
    
    NSLog(@"[ModDownload] Starting download for mod: %@, URL: %@, size: %lu", modName, url, (unsigned long)size);
    
    // Get the profile information
    NSString *profileName = [PLProfiles current].selectedProfileName;
    NSLog(@"[ModDownload] Selected profile name: %@", profileName);
    
    NSMutableDictionary *profile = [PLProfiles current].selectedProfile;
    NSString *gameDir = profile[@"gameDir"];
    NSLog(@"[ModDownload] Game directory from profile: %@", gameDir);
    
    // Ensure the profile directory exists
    [PLProfiles ensureProfileDirectoryExists:profileName gameDir:gameDir];
    NSLog(@"[ModDownload] Profile directory created or exists");
    
    // Get the full path to the profile directory
    NSString *profileDir = [PLProfiles fullPathForProfileWithName:profileName gameDir:gameDir];
    NSLog(@"[ModDownload] Full profile directory path: %@", profileDir);
    
    NSString *modsDir = [profileDir stringByAppendingPathComponent:@"mods"];
    NSLog(@"[ModDownload] Mods directory path: %@", modsDir);
    
    // Create the mods directory if it doesn't exist
    if (![[NSFileManager defaultManager] fileExistsAtPath:modsDir]) {
        NSError *createError = nil;
        [[NSFileManager defaultManager] createDirectoryAtPath:modsDir 
                                  withIntermediateDirectories:YES 
                                                   attributes:nil 
                                                        error:&createError];
        if (createError) {
            NSLog(@"[ModDownload] Failed to create mods directory: %@", createError.localizedDescription);
            [self finishDownloadWithErrorString:[NSString stringWithFormat:@"Failed to create mods directory: %@", createError.localizedDescription]];
            return;
        }
        NSLog(@"[ModDownload] Created mods directory at: %@", modsDir);
    } else {
        NSLog(@"[ModDownload] Mods directory already exists at: %@", modsDir);
    }
    
    // Use the URL's last path component as the filename
    NSURL *fileURL = [NSURL URLWithString:url];
    if (!fileURL) {
        NSLog(@"[ModDownload] Invalid URL: %@", url);
        [self finishDownloadWithErrorString:[NSString stringWithFormat:@"Invalid download URL for mod: %@", modName]];
        return;
    }
    
    NSString *fileName = fileURL.lastPathComponent;
    if (fileName.length == 0) {
        fileName = [NSString stringWithFormat:@"%@.jar", modName];
        NSLog(@"[ModDownload] Using fallback filename: %@", fileName);
    }
    
    NSString *destinationPath = [modsDir stringByAppendingPathComponent:fileName];
    NSLog(@"[ModDownload] Final destination path: %@", destinationPath);
    
    // Check for dependencies
    NSArray *versionDependencies = modDetail[@"versionDependencies"];
    if (versionDependencies && [versionDependencies isKindOfClass:[NSArray class]] && selectedVersion < versionDependencies.count) {
        NSArray *dependencies = versionDependencies[selectedVersion];
        
        if (dependencies && [dependencies isKindOfClass:[NSArray class]] && dependencies.count > 0) {
            NSLog(@"[ModDownload] Found %lu dependencies for %@", (unsigned long)dependencies.count, modName);
            
            for (NSDictionary *dependency in dependencies) {
                NSString *depType = dependency[@"dependency_type"];
                NSString *depId = dependency[@"project_id"];
                NSString *depName = dependency[@"project_name"] ?: @"Unknown Dependency";
                
                if (!depId || ![depId isKindOfClass:[NSString class]] || depId.length == 0) {
                    NSLog(@"[ModDownload] Skipping dependency with missing project_id: %@", dependency);
                    continue;
                }
                
                // Only add required dependencies to the queue
                if ([depType isEqualToString:@"required"] && ![self.processedDependencyIds containsObject:depId]) {
                    [self.dependencyQueue addObject:@{
                        @"id": depId,
                        @"name": depName,
                        @"type": depType
                    }];
                    [self.processedDependencyIds addObject:depId];
                    NSLog(@"[ModDownload] Added required dependency to queue: %@", depName);
                }
            }
            
            // Update progress total to include dependencies
            self.progress.totalUnitCount += self.dependencyQueue.count;
            self.textProgress.totalUnitCount += self.dependencyQueue.count;
        }
    }
    
    __weak typeof(self) weakSelf = self;
    NSURLSessionDownloadTask *task = [self createDownloadTask:url size:size sha:sha altName:modName toPath:destinationPath success:^{
        __strong typeof(weakSelf) strongSelf = weakSelf;
        NSLog(@"[ModDownload] Download completed successfully for mod: %@", modName);
        
        // Check if we have dependencies to process
        if (strongSelf.dependencyQueue.count > 0 && !strongSelf.processingDependencies) {
            [strongSelf processNextDependency:modsDir];
        } else {
            // No dependencies, complete the download
            dispatch_async(dispatch_get_main_queue(), ^{
                strongSelf.progress.completedUnitCount = strongSelf.progress.totalUnitCount;
                strongSelf.textProgress.completedUnitCount = strongSelf.textProgress.totalUnitCount;
                strongSelf.currentStage = @"Download completed";
            });
        }
    }];
    
    if (task) {
        NSLog(@"[ModDownload] Starting download task for mod: %@", modName);
        [task resume];
    } else {
        NSLog(@"[ModDownload] Failed to create download task for mod: %@", modName);
        [self finishDownloadWithErrorString:[NSString stringWithFormat:@"Failed to create download task for mod: %@", modName]];
    }
}

- (void)processNextDependency:(NSString *)modsDir {
    if (self.dependencyQueue.count == 0) {
        // All dependencies processed
        self.processingDependencies = NO;
        dispatch_async(dispatch_get_main_queue(), ^{
            self.progress.completedUnitCount = self.progress.totalUnitCount;
            self.textProgress.completedUnitCount = self.textProgress.totalUnitCount;
            self.currentStage = @"Download completed";
        });
        return;
    }
    
    self.processingDependencies = YES;
    NSDictionary *dependency = [self.dependencyQueue firstObject];
    [self.dependencyQueue removeObjectAtIndex:0];
    
    NSString *depId = dependency[@"id"];
    NSString *depName = dependency[@"name"];
    
    self.currentStage = [NSString stringWithFormat:@"Downloading dependency: %@", depName];
    NSLog(@"[ModDownload] Processing dependency: %@", depName);
    
    // Get the current Minecraft version and loader from the selected profile
    NSString *profileName = [PLProfiles current].selectedProfileName;
    NSMutableDictionary *profile = [PLProfiles current].selectedProfile;
    NSString *lastVersionId = profile[@"lastVersionId"];
    
    // Parse the version ID to extract game version and loader
    NSDictionary *parsed = [ModpackUtils parseVersionString:lastVersionId];
    NSString *mcVersion = parsed[@"mcVersion"] ?: @"";
    NSString *loader = parsed[@"loader"] ?: @"";
    
    // Use the ModrinthAPI to fetch dependency details
    ModrinthAPI *api = [ModrinthAPI new];
    NSMutableDictionary *depItem = [@{
        @"id": depId,
        @"title": depName
    } mutableCopy];
    
    [api loadDetailsOfModSync:depItem];
    
    if (![depItem[@"versionDetailsLoaded"] boolValue]) {
        NSLog(@"[ModDownload] Failed to load details for dependency: %@", depName);
        // Continue with next dependency
        [self processNextDependency:modsDir];
        return;
    }
    
    // Verify we have version information
    NSArray *versionNames = depItem[@"versionNames"];
    NSArray *gameVersions = depItem[@"gameVersions"];
    NSArray *versionUrls = depItem[@"versionUrls"];
    NSArray *versionSizes = depItem[@"versionSizes"];
    NSArray *versionHashes = depItem[@"versionHashes"];
    NSArray *versionLoaders = depItem[@"versionLoaders"];
    
    if (versionNames.count == 0 || versionUrls.count == 0) {
        NSLog(@"[ModDownload] No versions found for dependency: %@", depName);
        // Continue with next dependency
        [self processNextDependency:modsDir];
        return;
    }
    
    // Find a compatible version based on game version and loader
    NSInteger versionIndex = [self findCompatibleVersionIndex:gameVersions 
                                                  loaderArray:versionLoaders 
                                            selectedMCVersion:mcVersion 
                                                selectedLoader:loader];
    
    // Get the version details
    NSString *url = versionUrls[versionIndex];
    NSUInteger size = [versionSizes[versionIndex] unsignedLongLongValue];
    NSString *sha = versionHashes[versionIndex];
    NSString *versionName = versionNames[versionIndex];
    
    NSLog(@"[ModDownload] Selected version %@ for dependency %@", versionName, depName);
    
    // Use the URL's last path component as the filename
    NSURL *fileURL = [NSURL URLWithString:url];
    if (!fileURL) {
        NSLog(@"[ModDownload] Invalid URL for dependency: %@", url);
        // Continue with next dependency
        [self processNextDependency:modsDir];
        return;
    }
    
    NSString *fileName = fileURL.lastPathComponent;
    if (fileName.length == 0) {
        fileName = [NSString stringWithFormat:@"%@.jar", depName];
    }
    
    NSString *destinationPath = [modsDir stringByAppendingPathComponent:fileName];
    NSLog(@"[ModDownload] Dependency destination path: %@", destinationPath);
    
    // Check if file already exists and has correct SHA
    if ([NSFileManager.defaultManager fileExistsAtPath:destinationPath]) {
        if ([self checkSHA:sha forFile:destinationPath altName:depName]) {
            NSLog(@"[ModDownload] Dependency %@ already exists with correct SHA, skipping download", depName);
            // Process next dependency
            [self processNextDependency:modsDir];
            return;
        }
    }
    
    __weak typeof(self) weakSelf = self;
    NSURLSessionDownloadTask *task = [self createDownloadTask:url size:size sha:sha altName:depName toPath:destinationPath success:^{
        __strong typeof(weakSelf) strongSelf = weakSelf;
        NSLog(@"[ModDownload] Downloaded dependency: %@", depName);
        
        // Check for nested dependencies
        NSArray *depDependencies = depItem[@"versionDependencies"];
        if (depDependencies && [depDependencies isKindOfClass:[NSArray class]] && versionIndex < depDependencies.count) {
            NSArray *nestedDeps = depDependencies[versionIndex];
            
            if (nestedDeps && [nestedDeps isKindOfClass:[NSArray class]] && nestedDeps.count > 0) {
                NSLog(@"[ModDownload] Found %lu nested dependencies for %@", (unsigned long)nestedDeps.count, depName);
                
                for (NSDictionary *nestedDep in nestedDeps) {
                    NSString *nestedType = nestedDep[@"dependency_type"];
                    NSString *nestedId = nestedDep[@"project_id"];
                    NSString *nestedName = nestedDep[@"project_name"] ?: @"Unknown Dependency";
                    
                    if (!nestedId || ![nestedId isKindOfClass:[NSString class]] || nestedId.length == 0) {
                        NSLog(@"[ModDownload] Skipping nested dependency with missing project_id: %@", nestedDep);
                        continue;
                    }
                    
                    // Only add required dependencies that we haven't processed yet
                    if ([nestedType isEqualToString:@"required"] && ![strongSelf.processedDependencyIds containsObject:nestedId]) {
                        [strongSelf.dependencyQueue addObject:@{
                            @"id": nestedId,
                            @"name": nestedName,
                            @"type": nestedType
                        }];
                        [strongSelf.processedDependencyIds addObject:nestedId];
                        
                        // Update progress total to include nested dependency
                        dispatch_async(dispatch_get_main_queue(), ^{
                            strongSelf.progress.totalUnitCount += 1;
                            strongSelf.textProgress.totalUnitCount += 1;
                        });
                        
                        NSLog(@"[ModDownload] Added nested dependency to queue: %@", nestedName);
                    }
                }
            }
        }
        
        // Process next dependency
        [strongSelf processNextDependency:modsDir];
    }];
    
    if (task) {
        NSLog(@"[ModDownload] Starting download task for dependency: %@", depName);
        [task resume];
    } else if (self.progress.cancelled) {
        NSLog(@"[ModDownload] Download cancelled for dependency: %@", depName);
        // Don't process more dependencies if cancelled
    } else {
        NSLog(@"[ModDownload] Failed to create download task for dependency: %@", depName);
        // Continue with next dependency
        [self processNextDependency:modsDir];
    }
}

- (NSInteger)findCompatibleVersionIndex:(NSArray *)gameVersions loaderArray:(NSArray *)loaderArray selectedMCVersion:(NSString *)mcVersion selectedLoader:(NSString *)loader {
    // If no game versions available, use the first (most recent) version
    if (!gameVersions || gameVersions.count == 0) {
        return 0;
    }
    
    // Normalize MC version and loader for comparison
    NSString *normalizedMCVersion = [[mcVersion stringByTrimmingCharactersInSet:[NSCharacterSet whitespaceAndNewlineCharacterSet]] lowercaseString];
    NSString *normalizedLoader = [[loader stringByTrimmingCharactersInSet:[NSCharacterSet whitespaceAndNewlineCharacterSet]] lowercaseString];
    
    // Loop through versions to find a compatible one
    for (NSInteger i = 0; i < gameVersions.count; i++) {
        id gameVersionItem = gameVersions[i];
        NSArray *versions = [gameVersionItem isKindOfClass:[NSArray class]] ? gameVersionItem : @[gameVersionItem];
        
        BOOL mcMatch = NO;
        // Check for MC version match
        for (id versionObj in versions) {
            NSString *version = [versionObj isKindOfClass:[NSString class]] ? versionObj : [versionObj description];
            NSString *trimmedVersion = [[version stringByTrimmingCharactersInSet:[NSCharacterSet whitespaceAndNewlineCharacterSet]] lowercaseString];
            
            if ([trimmedVersion isEqualToString:normalizedMCVersion] || 
                [trimmedVersion hasPrefix:normalizedMCVersion] || 
                [normalizedMCVersion hasPrefix:trimmedVersion]) {
                mcMatch = YES;
                break;
            }
        }
        
        // If MC version matches and no loader is specified, or if loaders not available, use this version
        if (mcMatch && (normalizedLoader.length == 0 || !loaderArray || i >= loaderArray.count)) {
            return i;
        }
        
        // If MC version matches, check loader compatibility
        if (mcMatch && normalizedLoader.length > 0 && i < loaderArray.count) {
            id loaderItem = loaderArray[i];
            NSArray *loaders = [loaderItem isKindOfClass:[NSArray class]] ? loaderItem : (loaderItem ? @[loaderItem] : @[]);
            
            for (id loaderObj in loaders) {
                NSString *loaderStr = [loaderObj isKindOfClass:[NSString class]] ? loaderObj : [loaderObj description];
                NSString *trimmedLoader = [[loaderStr stringByTrimmingCharactersInSet:[NSCharacterSet whitespaceAndNewlineCharacterSet]] lowercaseString];
                
                if ([trimmedLoader isEqualToString:normalizedLoader]) {
                    return i;
                }
            }
        }
    }
    
    // If no exact match found, return the first version as fallback
    return 0;
}

#pragma mark - Utilities



- (void)prepareForDownload {
    // Create a fake progress which is used to update completedUnitCount properly
    // (completedUnitCount does not update unless subprogress completes)
    self.textProgress = [NSProgress new];
    self.textProgress.kind = NSProgressKindFile;
    self.textProgress.fileOperationKind = NSProgressFileOperationKindDownloading;
    self.textProgress.totalUnitCount = -1;

    self.progress = [NSProgress new];
    // Push 1 byte so it won't accidentally finish after downloading assets index
    self.progress.totalUnitCount = 1;
    [self.fileList removeAllObjects];
    [self.progressList removeAllObjects];
    
    self.currentStage = @"Preparing download";
}

- (void)finishDownloadWithErrorString:(NSString *)error {
    self.currentStage = @"Error";
    [self.progress cancel];
    [self.manager invalidateSessionCancelingTasks:YES resetSession:YES];
    showDialog(localize(@"Error", nil), error);
    self.handleError();
}


- (void)finishDownloadWithError:(NSError *)error file:(NSString *)file {
    self.currentStage = @"Error";
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

@end

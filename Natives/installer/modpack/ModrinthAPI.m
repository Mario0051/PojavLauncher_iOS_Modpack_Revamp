#import "ModrinthAPI.h"
#import "MinecraftResourceDownloadTask.h"
#import "PLProfiles.h"
#import "utils.h"
#import "UnzipKit.h"
#import "ModpackUtils.h"

@implementation ModrinthAPI

- (instancetype)init {
    self = [super initWithURL:@"https://api.modrinth.com/v2"];
    return self;
}

- (NSMutableArray *)searchModWithFilters:(NSDictionary<NSString *, id> *)searchFilters
                       previousPageResult:(NSMutableArray *)modrinthSearchResult {
    // Create facets array once
    NSString *projectType = [searchFilters[@"isModpack"] boolValue] ? @"modpack" : @"mod";
    NSString *mcVer = searchFilters[@"mcVersion"];
    NSMutableArray *outerFacets = [NSMutableArray array];
    [outerFacets addObject:@[[NSString stringWithFormat:@"project_type:%@", projectType]]];
    if (mcVer && mcVer.length > 0) {
        [outerFacets addObject:@[[NSString stringWithFormat:@"versions:%@", mcVer]]];
    }
    
    // Serialize facets to JSON once with better error handling
    NSError *jsonError = nil;
    NSData *jsonData = [NSJSONSerialization dataWithJSONObject:outerFacets options:0 error:&jsonError];
    NSString *facetsParam = @"[]";
    if (jsonData && !jsonError) {
        facetsParam = [[NSString alloc] initWithData:jsonData encoding:NSUTF8StringEncoding];
    } else {
        NSLog(@"ModrinthAPI.searchModWithFilters: JSON error: %@", jsonError.localizedDescription);
    }
    
    // Build query parameters with defaults for nil values
    int limit = 20;
    NSString *rawName = (searchFilters[@"name"] != nil ? searchFilters[@"name"] : @"");
    NSString *nameQuery = [rawName stringByReplacingOccurrencesOfString:@" " withString:@"+"];
    NSDictionary *params = @{
        @"limit": @(limit),
        @"index": @"relevance",
        @"facets": facetsParam,
        @"offset": @(modrinthSearchResult.count),
        @"query": nameQuery
    };
    
    // Make API request
    NSDictionary *response = [self getEndpoint:@"search" params:params];
    if (!response) {
        NSLog(@"[ModrinthAPI] searchModWithFilters: No response returned");
        return nil;
    }
    
    // Process results more efficiently
    NSMutableArray *result = modrinthSearchResult ?: [NSMutableArray new];
    for (NSDictionary *hit in response[@"hits"]) {
        BOOL isModpack = [hit[@"project_type"] isEqualToString:@"modpack"];
        [result addObject:[@{
            @"apiSource": @(1),
            @"isModpack": @(isModpack),
            @"id": hit[@"project_id"],
            @"title": hit[@"title"] ?: @"",
            @"description": hit[@"description"] ?: @"",
            @"imageUrl": hit[@"icon_url"] ?: @""
        } mutableCopy]];
    }
    
    // Update pagination state with proper type conversion
    self.reachedLastPage = result.count >= [response[@"total_hits"] unsignedLongValue];
    return result;
}

- (void)loadDetailsOfMod:(NSMutableDictionary *)item {
    [self loadDetailsOfMod:item completion:^(NSError *error) {}];
}

- (void)loadDetailsOfModSync:(NSMutableDictionary *)item {
    NSArray *response = [self getEndpoint:[NSString stringWithFormat:@"project/%@/version", item[@"id"]] params:@{}];
    if (!response) {
        NSLog(@"loadDetailsOfModSync: No response for mod id %@", item[@"id"]);
        return;
    }
    
    // Pre-allocate arrays with estimated capacity
    NSUInteger estimatedCount = response.count;
    NSMutableArray *versionNames = [NSMutableArray arrayWithCapacity:estimatedCount];
    NSMutableArray *gameVersionsArray = [NSMutableArray arrayWithCapacity:estimatedCount];
    NSMutableArray *versionUrls = [NSMutableArray arrayWithCapacity:estimatedCount];
    NSMutableArray *versionSizes = [NSMutableArray arrayWithCapacity:estimatedCount];
    NSMutableArray *versionHashes = [NSMutableArray arrayWithCapacity:estimatedCount];
    NSMutableArray *versionLoaders = [NSMutableArray arrayWithCapacity:estimatedCount];
    
    for (NSDictionary *versionDict in response) {
        // Use nil coalescing to simplify null checks
        NSString *versionDisplay = versionDict[@"version_number"] ?: versionDict[@"name"] ?: @"";
        NSArray *supportedGameVersions = versionDict[@"game_versions"] ?: @[];
        NSDictionary *file = [versionDict[@"files"] firstObject];
        if (!file) {
            NSLog(@"loadDetailsOfModSync: Missing file info for version %@", versionDict);
            continue;
        }
        
        // Extract all needed values at once
        NSString *url = file[@"url"] ?: @"";
        NSNumber *size = file[@"size"] ?: @0;
        NSDictionary *hashes = file[@"hashes"];
        NSString *sha1 = hashes[@"sha1"] ?: @"";
        NSArray *loaders = versionDict[@"loaders"] ?: @[];
        
        // Add all values to arrays
        [versionNames addObject:versionDisplay];
        [gameVersionsArray addObject:supportedGameVersions];
        [versionUrls addObject:url];
        [versionSizes addObject:size];
        [versionHashes addObject:sha1];
        [versionLoaders addObject:loaders];
    }
    
    // Assign arrays to the item dictionary once at the end
    item[@"versionNames"] = versionNames;
    item[@"gameVersions"] = gameVersionsArray;
    item[@"versionUrls"] = versionUrls;
    item[@"versionSizes"] = versionSizes;
    item[@"versionHashes"] = versionHashes;
    item[@"versionLoaders"] = versionLoaders;
    item[@"versionDetailsLoaded"] = @(YES);
}

- (void)loadDetailsOfMod:(NSMutableDictionary *)item completion:(void (^)(NSError *error))completion {
    NSString *endpoint = [NSString stringWithFormat:@"project/%@/version", item[@"id"]];
    [self getEndpoint:endpoint params:@{} completion:^(id response, NSError *error) {
        if (!response) {
            NSLog(@"loadDetailsOfMod: No response for mod id %@, error: %@", item[@"id"], error);
            if (completion) completion(error);
            return;
        }
        if (![response isKindOfClass:[NSArray class]]) {
            NSLog(@"loadDetailsOfMod: Unexpected response type: %@", [response class]);
            if (completion) completion([NSError errorWithDomain:@"ModrinthAPIErrorDomain" code:0 userInfo:@{NSLocalizedDescriptionKey:@"Unexpected response format"}]);
            return;
        }
        NSMutableArray *versionNames = [NSMutableArray new];
        NSMutableArray *gameVersionsArray = [NSMutableArray new];
        NSMutableArray *versionUrls = [NSMutableArray new];
        NSMutableArray *versionSizes = [NSMutableArray new];
        NSMutableArray *versionHashes = [NSMutableArray new];
        NSMutableArray *versionLoaders = [NSMutableArray new];
        
        for (NSDictionary *versionDict in response) {
            NSString *versionDisplay = versionDict[@"version_number"] ?: versionDict[@"name"] ?: @"";
            NSArray *supportedGameVersions = versionDict[@"game_versions"] ?: @[];
            NSDictionary *file = [versionDict[@"files"] firstObject];
            if (!file) {
                NSLog(@"loadDetailsOfMod: Missing file info for version %@", versionDict);
                continue;
            }
            NSString *url = file[@"url"] ?: @"";
            NSNumber *size = file[@"size"] ?: @0;
            NSDictionary *hashes = file[@"hashes"];
            NSString *sha1 = hashes[@"sha1"] ?: @"";
            NSArray *loaders = versionDict[@"loaders"] ?: @[];
            
            [versionNames addObject:versionDisplay];
            [gameVersionsArray addObject:supportedGameVersions];
            [versionUrls addObject:url];
            [versionSizes addObject:size];
            [versionHashes addObject:sha1];
            [versionLoaders addObject:loaders];
        }
        
        item[@"versionNames"] = versionNames;
        item[@"gameVersions"] = gameVersionsArray;
        item[@"versionUrls"] = versionUrls;
        item[@"versionSizes"] = versionSizes;
        item[@"versionHashes"] = versionHashes;
        item[@"versionLoaders"] = versionLoaders;
        item[@"versionDetailsLoaded"] = @(YES);
        NSLog(@"loadDetailsOfMod: Loaded %lu versions for mod %@", (unsigned long)versionNames.count, item[@"id"]);
        if (completion) completion(nil);
    }];
}

- (void)installModFromDetail:(NSDictionary *)modDetail atIndex:(NSUInteger)selectedVersion {
    NSDictionary *userInfo = @{@"detail": modDetail, @"index": @(selectedVersion)};
    [[NSNotificationCenter defaultCenter] postNotificationName:@"InstallMod" object:self userInfo:userInfo];
}

- (void)downloader:(MinecraftResourceDownloadTask *)downloader submitDownloadTasksFromPackage:(NSString *)packagePath toPath:(NSString *)destPath {
    NSLog(@"[ModrinthAPI] Beginning modpack extraction from %@ to %@", packagePath, destPath);
    
    // Create the destination directory if it doesn't exist
    NSError *dirError = nil;
    [[NSFileManager defaultManager] createDirectoryAtPath:destPath 
                              withIntermediateDirectories:YES 
                                               attributes:nil 
                                                    error:&dirError];
    if (dirError) {
        NSLog(@"[ModrinthAPI] Failed to create destination directory: %@", dirError);
        [downloader finishDownloadWithErrorString:[NSString stringWithFormat:@"Failed to create destination directory: %@", dirError.localizedDescription]];
        return;
    }
    
    // Open the archive
    NSError *archiveError = nil;
    UZKArchive *archive = [[UZKArchive alloc] initWithPath:packagePath error:&archiveError];
    if (archiveError) {
        NSLog(@"[ModrinthAPI] Failed to open modpack archive: %@", archiveError);
        [downloader finishDownloadWithErrorString:[NSString stringWithFormat:@"Failed to open modpack archive: %@", archiveError.localizedDescription]];
        return;
    }
    
    // Extract the manifest - try modrinth.index.json first (newer format)
    NSError *manifestError = nil;
    NSString *manifestPath = [destPath stringByAppendingPathComponent:@"modrinth.index.json"];
    NSData *manifestData = [archive extractDataFromFile:@"modrinth.index.json" error:&manifestError];
    
    // If no modrinth.index.json, try manifest.json (older format)
    if (!manifestData) {
        manifestError = nil;
        manifestData = [archive extractDataFromFile:@"manifest.json" error:&manifestError];
        if (manifestData) {
            manifestPath = [destPath stringByAppendingPathComponent:@"manifest.json"];
        }
    }
    
    if (!manifestData) {
        NSLog(@"[ModrinthAPI] Failed to extract any manifest file: %@", manifestError);
        [downloader finishDownloadWithErrorString:@"Failed to extract manifest from modpack. This might not be a valid modpack."];
        return;
    }
    
    // Save manifest data
    if (manifestData) {
        NSError *writeError = nil;
        [manifestData writeToFile:manifestPath options:NSDataWritingAtomic error:&writeError];
        if (writeError) {
            NSLog(@"[ModrinthAPI] Warning: couldn't write manifest file: %@", writeError);
        }
    }
    
    // Extract overrides
    NSError *extractError = nil;
    [ModpackUtils archive:archive extractDirectory:@"overrides" toPath:destPath error:&extractError];
    if (extractError) {
        NSLog(@"[ModrinthAPI] Warning: error extracting overrides: %@", extractError);
        // Don't fail, as some modpacks might not have overrides
    }
    
    // Try extract client-overrides if they exist
    NSError *clientOverridesError = nil;
    [ModpackUtils archive:archive extractDirectory:@"client-overrides" toPath:destPath error:&clientOverridesError];
    if (clientOverridesError) {
        NSLog(@"[ModrinthAPI] Note: No client-overrides found or error: %@", clientOverridesError);
        // This is optional, don't fail
    }
    
    // Parse the manifest
    NSError *jsonError = nil;
    NSDictionary *manifest = [NSJSONSerialization JSONObjectWithData:manifestData options:0 error:&jsonError];
    if (jsonError) {
        NSLog(@"[ModrinthAPI] Failed to parse manifest JSON: %@", jsonError);
        [downloader finishDownloadWithErrorString:[NSString stringWithFormat:@"Failed to parse manifest: %@", jsonError.localizedDescription]];
        return;
    }
    
    // Extract key information from manifest
    NSString *profileName = manifest[@"name"] ?: @"Unknown Modpack";
    
    // Create mods directory within the destination path
    NSString *modsDir = [destPath stringByAppendingPathComponent:@"mods"];
    NSError *modsDirError = nil;
    [[NSFileManager defaultManager] createDirectoryAtPath:modsDir
                              withIntermediateDirectories:YES
                                               attributes:nil
                                                    error:&modsDirError];
    if (modsDirError) {
        NSLog(@"[ModrinthAPI] Warning: Failed to create mods directory: %@", modsDirError);
    }
    
    // Download and set up mods from the manifest
    NSArray *files = manifest[@"files"];
    
    if (!files || ![files isKindOfClass:[NSArray class]] || files.count == 0) {
        NSLog(@"[ModrinthAPI] Warning: No files found in manifest");
        // Create a profile even if no files are found
        [self processManifestForProfile:manifest destPath:destPath];
        dispatch_async(dispatch_get_main_queue(), ^{
            downloader.progress.completedUnitCount = downloader.progress.totalUnitCount;
            downloader.textProgress.completedUnitCount = downloader.textProgress.totalUnitCount;
        });
        return;
    }
    
    // Set up profile based on manifest before downloading mods
    [self processManifestForProfile:manifest destPath:destPath];
    
    // Process mod downloads
    dispatch_group_t group = dispatch_group_create();
    
    for (NSDictionary *file in files) {
        NSArray *downloads = file[@"downloads"];
        if (!downloads || ![downloads isKindOfClass:[NSArray class]] || downloads.count == 0) {
            NSLog(@"[ModrinthAPI] Warning: No download URLs for file %@", file[@"filename"]);
            continue;
        }
        
        NSString *downloadUrl = downloads[0];
        if (!downloadUrl || ![downloadUrl isKindOfClass:[NSString class]]) {
            NSLog(@"[ModrinthAPI] Warning: Invalid download URL for file");
            continue;
        }
        
        // Determine the correct path for this file
        NSString *filePath;
        NSString *path = file[@"path"];
        
        if (path && [path length] > 0) {
            // Use the specified path relative to the destination directory
            filePath = [destPath stringByAppendingPathComponent:path];
        } else {
            // Default to mods folder with filename
            NSString *fileName = file[@"filename"];
            if (!fileName || [fileName length] == 0) {
                // Extract filename from URL if not provided
                NSURL *url = [NSURL URLWithString:downloadUrl];
                fileName = url.lastPathComponent ?: @"unknown.jar";
            }
            filePath = [modsDir stringByAppendingPathComponent:fileName];
        }
        
        // Ensure the directory exists
        NSString *fileDirectory = [filePath stringByDeletingLastPathComponent];
        NSError *dirCreateError = nil;
        [[NSFileManager defaultManager] createDirectoryAtPath:fileDirectory
                                  withIntermediateDirectories:YES
                                                   attributes:nil
                                                        error:&dirCreateError];
        if (dirCreateError) {
            NSLog(@"[ModrinthAPI] Warning: Failed to create directory for file %@: %@", filePath, dirCreateError);
            continue;
        }
        
        // Get file size if available
        NSNumber *size = file[@"fileSize"];
        NSUInteger fileSize = size ? [size unsignedIntegerValue] : 1;
        
        // Get hash if available
        NSString *sha1 = nil;
        NSDictionary *hashes = file[@"hashes"];
        if (hashes) {
            sha1 = hashes[@"sha1"];
        }
        
        NSLog(@"[ModrinthAPI] Downloading mod to: %@", filePath);
        
        // Queue download
        dispatch_group_enter(group);
        NSURLSessionDownloadTask *task = [downloader createDownloadTask:downloadUrl 
                                                                   size:fileSize 
                                                                    sha:sha1 
                                                                altName:file[@"filename"] 
                                                                 toPath:filePath 
                                                                success:^{
                                                                    NSLog(@"[ModrinthAPI] Successfully downloaded file to: %@", filePath);
                                                                    dispatch_group_leave(group);
                                                                }];
        if (task) {
            dispatch_async(dispatch_get_main_queue(), ^{
                [task resume];
            });
        } else {
            NSLog(@"[ModrinthAPI] Warning: Failed to create download task for %@", filePath);
            dispatch_group_leave(group);
        }
    }
    
    // Wait for all downloads to complete
    dispatch_group_notify(group, dispatch_get_global_queue(DISPATCH_QUEUE_PRIORITY_DEFAULT, 0), ^{
        // Cleanup the zip file
        NSError *removeError = nil;
        [[NSFileManager defaultManager] removeItemAtPath:packagePath error:&removeError];
        if (removeError) {
            NSLog(@"[ModrinthAPI] Warning: Failed to remove package file: %@", removeError);
        }
        
        NSLog(@"[ModrinthAPI] Modpack extraction and download setup complete");
        
        // Signal completion
        dispatch_async(dispatch_get_main_queue(), ^{
            downloader.progress.completedUnitCount = downloader.progress.totalUnitCount;
            downloader.textProgress.completedUnitCount = downloader.textProgress.totalUnitCount;
        });
    });
}

// Helper method to process manifest and set up profile
- (void)processManifestForProfile:(NSDictionary *)manifest destPath:(NSString *)destPath {
    NSString *profileName = manifest[@"name"] ?: @"Unknown Modpack";
    NSString *gameVersion = manifest[@"dependencies"][@"minecraft"] ?: @"";
    NSString *modLoader = @"";
    NSString *modLoaderVersion = @"";
    
    // Try to determine mod loader from dependencies
    if (manifest[@"dependencies"][@"fabric-loader"]) {
        modLoader = @"fabric";
        modLoaderVersion = manifest[@"dependencies"][@"fabric-loader"];
    } else if (manifest[@"dependencies"][@"forge"]) {
        modLoader = @"forge";
        modLoaderVersion = manifest[@"dependencies"][@"forge"];
    } else if (manifest[@"dependencies"][@"quilt-loader"]) {
        modLoader = @"quilt";
        modLoaderVersion = manifest[@"dependencies"][@"quilt-loader"];
    } else if (manifest[@"dependencies"][@"neoforge"]) {
        modLoader = @"neoforge";
        modLoaderVersion = manifest[@"dependencies"][@"neoforge"];
    }
    
    // Create a version string based on available information
    NSString *versionId;
    if ([modLoader length] > 0 && [modLoaderVersion length] > 0) {
        if ([modLoader isEqualToString:@"fabric"] || [modLoader isEqualToString:@"quilt"]) {
            versionId = [NSString stringWithFormat:@"%@-%@-%@-%@", modLoader, @"loader", modLoaderVersion, gameVersion];
        } else {
            versionId = [NSString stringWithFormat:@"%@-%@-%@", gameVersion, modLoader, modLoaderVersion];
        }
    } else {
        versionId = gameVersion;
    }
    
    // Create a safe profile name
    NSString *safeProfileName = [profileName stringByReplacingOccurrencesOfString:@"/" withString:@"_"];
    safeProfileName = [safeProfileName stringByReplacingOccurrencesOfString:@"\\" withString:@"_"];
    safeProfileName = [safeProfileName stringByReplacingOccurrencesOfString:@":" withString:@"_"];
    safeProfileName = [safeProfileName stringByTrimmingCharactersInSet:[NSCharacterSet whitespaceAndNewlineCharacterSet]];
    
    if (safeProfileName.length == 0) {
        safeProfileName = @"UnknownModpack";
    }
    
    // The key fix: Use the actual destination path for the game directory
    // Instead of creating a new relative path, use the actual extracted path
    NSString *gameDir = destPath;
    
    // Create profile info
    NSMutableDictionary *profileInfo = [@{
        @"gameDir": gameDir,
        @"name": profileName,
        @"lastVersionId": versionId.length > 0 ? versionId : @"latest-release",
        @"icon": manifest[@"icon"] ?: @""
    } mutableCopy];
    
    // Ensure the profile directory exists and create essential subdirectories
    NSError *dirError = nil;
    [[NSFileManager defaultManager] createDirectoryAtPath:gameDir 
                              withIntermediateDirectories:YES 
                                               attributes:nil 
                                                    error:&dirError];
    
    if (!dirError) {
        // Create essential subdirectories
        NSArray *essentialDirs = @[@"mods", @"resourcepacks", @"shaderpacks", @"saves", @"config"];
        for (NSString *dir in essentialDirs) {
            NSString *dirPath = [gameDir stringByAppendingPathComponent:dir];
            [[NSFileManager defaultManager] createDirectoryAtPath:dirPath 
                                      withIntermediateDirectories:YES 
                                                       attributes:nil 
                                                            error:nil];
        }
    }
    
    // Save profile
    dispatch_async(dispatch_get_main_queue(), ^{
        PLProfiles.current.profiles[profileName] = profileInfo;
        PLProfiles.current.selectedProfileName = profileName;
        [PLProfiles.current save];
        
        NSLog(@"[ModrinthAPI] Profile created with name: %@, gameDir: %@, versionId: %@", 
              profileName, gameDir, versionId);
    });
}

@end

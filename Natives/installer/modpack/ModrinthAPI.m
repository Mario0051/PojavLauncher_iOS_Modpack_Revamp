#import "MinecraftResourceDownloadTask.h"
#import "ModrinthAPI.h"
#import "PLProfiles.h"

@implementation ModrinthAPI

- (instancetype)init {
    return [super initWithURL:@"https://api.modrinth.com/v2"];
}

- (NSMutableArray *)searchModWithFilters:(NSDictionary<NSString *, NSString *> *)searchFilters previousPageResult:(NSMutableArray *)modrinthSearchResult {
    int limit = 50;

    NSMutableString *facetString = [NSMutableString new];
    [facetString appendString:@"["];
    [facetString appendFormat:@"[\"project_type:%@\"]", searchFilters[@"isModpack"].boolValue ? @"modpack" : @"mod"];
    if (searchFilters[@"mcVersion"].length > 0) {
        [facetString appendFormat:@",[\"versions:%@\"]", searchFilters[@"mcVersion"]];
    }
    [facetString appendString:@"]"];

    NSDictionary *params = @{
        @"facets": facetString,
        @"query": [searchFilters[@"name"] stringByReplacingOccurrencesOfString:@" " withString:@"+"],
        @"limit": @(limit),
        @"index": @"relevance",
        @"offset": @(modrinthSearchResult.count)
    };
    NSDictionary *response = [self getEndpoint:@"search" params:params];
    if (!response) {
        return nil;
    }

    NSMutableArray *result = modrinthSearchResult ?: [NSMutableArray new];
    for (NSDictionary *hit in response[@"hits"]) {
        BOOL isModpack = [hit[@"project_type"] isEqualToString:@"modpack"];
        [result addObject:@{
            @"apiSource": @(1), // Constant MODRINTH
            @"isModpack": @(isModpack),
            @"id": hit[@"project_id"],
            @"title": hit[@"title"],
            @"description": hit[@"description"],
            @"imageUrl": hit[@"icon_url"]
        }.mutableCopy];
    }
    self.reachedLastPage = result.count >= [response[@"total_hits"] unsignedLongValue];
    return result;
}

- (void)loadDetailsOfMod:(NSMutableDictionary *)item {
    NSArray *response = [self getEndpoint:[NSString stringWithFormat:@"project/%@/version", item[@"id"]] params:nil];
    if (!response) {
        return;
    }
    NSArray<NSString *> *names = [response valueForKey:@"name"];
    NSMutableArray<NSString *> *mcNames = [NSMutableArray new];
    NSMutableArray<NSString *> *urls = [NSMutableArray new];
    NSMutableArray<NSString *> *hashes = [NSMutableArray new];
    NSMutableArray<NSString *> *sizes = [NSMutableArray new];
    [response enumerateObjectsUsingBlock:
  ^(NSDictionary *version, NSUInteger i, BOOL *stop) {
        NSDictionary *file = [version[@"files"] firstObject];
        mcNames[i] = [version[@"game_versions"] firstObject];
        sizes[i] = file[@"size"];
        urls[i] = file[@"url"];
        NSDictionary *hashesMap = file[@"hashes"];
        hashes[i] = hashesMap[@"sha1"] ?: [NSNull null];
    }];
    item[@"versionNames"] = names;
    item[@"mcVersionNames"] = mcNames;
    item[@"versionSizes"] = sizes;
    item[@"versionUrls"] = urls;
    item[@"versionHashes"] = hashes;
    item[@"versionDetailsLoaded"] = @(YES);
}

- (void)downloader:(MinecraftResourceDownloadTask *)downloader submitDownloadTasksFromPackage:(NSString *)packagePath toPath:(NSString *)destPath {
    NSError *error;
    UZKArchive *archive = [[UZKArchive alloc] initWithPath:packagePath error:&error];
    if (error) {
        [downloader finishDownloadWithErrorString:[NSString stringWithFormat:@"Failed to open modpack package: %@", error.localizedDescription]];
        return;
    }

    NSData *indexData = [archive extractDataFromFile:@"modrinth.index.json" error:&error];
    if (!indexData) {
        // Try mrpack format (newer Modrinth format)
        indexData = [archive extractDataFromFile:@"modrinth.index.json" error:&error];
        if (!indexData) {
            indexData = [archive extractDataFromFile:@"index.json" error:&error];
        }
    }
    
    if (!indexData) {
        [downloader finishDownloadWithErrorString:@"Failed to find index.json in modpack"];
        return;
    }
    
    NSDictionary* indexDict = [NSJSONSerialization JSONObjectWithData:indexData options:kNilOptions error:&error];
    if (error) {
        [downloader finishDownloadWithErrorString:[NSString stringWithFormat:@"Failed to parse modpack index: %@", error.localizedDescription]];
        return;
    }

    // Get files and create a more unique display name for each file
    NSArray *files = indexDict[@"files"];
    if (!files || ![files isKindOfClass:[NSArray class]] || files.count == 0) {
        [downloader finishDownloadWithErrorString:@"No mod files found in modpack index"];
        return;
    }
    
    downloader.progress.totalUnitCount = [files count];
    
    // Track pending downloads to ensure we complete properly
    __block NSInteger pendingDownloads = files.count;
    
    for (NSDictionary *indexFile in files) {
        if (![indexFile isKindOfClass:[NSDictionary class]]) {
            NSLog(@"[ModrinthAPI] Skipping invalid file entry");
            pendingDownloads--;
            downloader.progress.completedUnitCount++;
            continue;
        }
        
        NSArray *downloadURLs = indexFile[@"downloads"];
        if (!downloadURLs || ![downloadURLs isKindOfClass:[NSArray class]] || downloadURLs.count == 0) {
            NSLog(@"[ModrinthAPI] File has no download URLs: %@", indexFile[@"path"]);
            pendingDownloads--;
            downloader.progress.completedUnitCount++;
            continue;
        }
        
        NSString *url = [downloadURLs firstObject];
        NSString *sha = indexFile[@"hashes"][@"sha1"];
        NSString *path = [destPath stringByAppendingPathComponent:indexFile[@"path"]];
        NSUInteger size = [indexFile[@"fileSize"] unsignedLongLongValue];
        
        // Create a display name that includes more path information
        NSString *displayName = indexFile[@"path"];
        
        // Create success callback that decrements pending downloads and checks for completion
        void(^fileSuccess)(void) = ^{
            pendingDownloads--;
            
            // If all downloads are complete, proceed to extraction
            if (pendingDownloads == 0) {
                [self extractAndFinalizeModpack:downloader archive:archive indexDict:indexDict destPath:destPath packagePath:packagePath];
            }
        };
        
        NSURLSessionDownloadTask *task = [downloader createDownloadTask:url size:size sha:sha altName:displayName toPath:path success:fileSuccess];
        if (task) {
            // Add to file list with the unique display name
            [downloader.fileList addObject:displayName];
            [task resume];
        } else if (!downloader.progress.cancelled) {
            pendingDownloads--;
            downloader.progress.completedUnitCount++;
            
            // If all downloads are complete, proceed to extraction
            if (pendingDownloads == 0) {
                [self extractAndFinalizeModpack:downloader archive:archive indexDict:indexDict destPath:destPath packagePath:packagePath];
            }
        } else {
            return; // cancelled
        }
    }
    
    // If there were no downloads to process, proceed directly to extraction
    if (pendingDownloads == 0) {
        [self extractAndFinalizeModpack:downloader archive:archive indexDict:indexDict destPath:destPath packagePath:packagePath];
    }
}

- (void)extractAndFinalizeModpack:(MinecraftResourceDownloadTask *)downloader 
                          archive:(UZKArchive *)archive
                        indexDict:(NSDictionary *)indexDict
                         destPath:(NSString *)destPath
                      packagePath:(NSString *)packagePath {
    NSError *error;
    
    // Extract overrides directory (still perform the extraction, just don't show it in the UI)
    [ModpackUtils archive:archive extractDirectory:@"overrides" toPath:destPath error:&error];
    if (error) {
        NSLog(@"[ModrinthAPI] Failed to extract overrides: %@", error.localizedDescription);
        // Continue anyway, as overrides might not exist
    }
    
    // Extract client-overrides directory
    [ModpackUtils archive:archive extractDirectory:@"client-overrides" toPath:destPath error:&error];
    if (error) {
        NSLog(@"[ModrinthAPI] Failed to extract client-overrides: %@", error.localizedDescription);
        // Continue anyway, as client-overrides might not exist
    }
    
    // Delete package cache
    [NSFileManager.defaultManager removeItemAtPath:packagePath error:nil];

    // Download dependency client json (if available)
    NSDictionary<NSString *, NSString *> *depInfo = [ModpackUtils infoForDependencies:indexDict[@"dependencies"]];
    
    if (depInfo[@"json"]) {
        NSString *jsonPath = [NSString stringWithFormat:@"%1$s/versions/%2$@/%2$@.json", getenv("POJAV_GAME_DIR"), depInfo[@"id"]];
        
        // Create directories for JSON
        [[NSFileManager defaultManager] createDirectoryAtPath:[jsonPath stringByDeletingLastPathComponent] 
                                withIntermediateDirectories:YES 
                                                 attributes:nil 
                                                      error:nil];
        
        // Create a success callback that will run after JSON download completes
        void(^jsonSuccess)(void) = ^{
            // Only create profile and mark as complete after JSON download
            [self finalizeModpackInstallation:downloader indexDict:indexDict depInfo:depInfo destPath:destPath];
        };
        
        // Use the version with success callback to wait for completion
        NSURLSessionDownloadTask *task = [downloader createDownloadTask:depInfo[@"json"] size:0 sha:nil altName:nil toPath:jsonPath success:jsonSuccess];
        if (task) {
            [task resume];
        } else {
            // If task couldn't be created but file exists, still finalize
            [self finalizeModpackInstallation:downloader indexDict:indexDict depInfo:depInfo destPath:destPath];
        }
    } else {
        // No JSON to download, so we can finalize immediately
        [self finalizeModpackInstallation:downloader indexDict:indexDict depInfo:depInfo destPath:destPath];
    }
}

- (void)finalizeModpackInstallation:(MinecraftResourceDownloadTask *)downloader 
                          indexDict:(NSDictionary *)indexDict
                            depInfo:(NSDictionary *)depInfo
                           destPath:(NSString *)destPath {
    // Create a mutable dictionary for the new profile
    NSString *profileName = indexDict[@"name"];
    if (!profileName || [profileName length] == 0) {
        profileName = [destPath lastPathComponent];
    }
    
    NSMutableDictionary *newProfile = [@{
        @"gameDir": [NSString stringWithFormat:@"./custom_gamedir/%@", destPath.lastPathComponent],
        @"name": profileName,
        @"lastVersionId": depInfo[@"id"] ?: @"latest-release"
    } mutableCopy];
    
    // Safely handle the icon data
    NSString *tmpIconPath = [NSTemporaryDirectory() stringByAppendingPathComponent:@"icon.png"];
    NSData *iconData = [NSData dataWithContentsOfFile:tmpIconPath];
    if (iconData && iconData.length > 0) {
        // Only add icon if valid data exists
        newProfile[@"icon"] = [NSString stringWithFormat:@"data:image/png;base64,%@",
                              [iconData base64EncodedStringWithOptions:0]];
    }
    
    // Add the profile to the profiles list
    PLProfiles.current.profiles[profileName] = newProfile;
    
    // Set this as the selected profile
    PLProfiles.current.selectedProfileName = profileName;
    
    // Save the profile changes to disk
    [PLProfiles.current save];
    
    // Ensure metadata reflects completion and marks this as a modpack install
    if (!downloader.metadata) {
        downloader.metadata = [NSMutableDictionary dictionary];
    }
    downloader.metadata[@"isModpackInstall"] = @YES;
    downloader.metadata[@"allTasksComplete"] = @YES;
    
    // Ensure progress is marked as complete
    downloader.progress.completedUnitCount = downloader.progress.totalUnitCount;
    
    // Log completion
    NSLog(@"[ModrinthAPI] Modpack installation complete: %@", profileName);
}

@end

#import "ModrinthAPI.h"
#import "MinecraftResourceDownloadTask.h"
#import "PLProfiles.h"

@implementation ModrinthAPI

- (instancetype)init {
    self = [super initWithURL:@"https://api.modrinth.com/v2"];
    return self;
}

- (NSMutableArray *)searchModWithFilters:(NSDictionary<NSString *, id> *)searchFilters
                       previousPageResult:(NSMutableArray *)modrinthSearchResult {
    NSString *projectType = [searchFilters[@"isModpack"] boolValue] ? @"modpack" : @"mod";
    NSString *mcVer = searchFilters[@"mcVersion"];
    NSMutableArray *outerFacets = [NSMutableArray array];
    [outerFacets addObject:@[[NSString stringWithFormat:@"project_type:%@", projectType]]];
    if (mcVer && mcVer.length > 0) {
        [outerFacets addObject:@[[NSString stringWithFormat:@"versions:%@", mcVer]]];
    }
    
    NSError *jsonError = nil;
    NSData *jsonData = [NSJSONSerialization dataWithJSONObject:outerFacets options:0 error:&jsonError];
    NSString *facetsParam = @"[]";
    if (jsonData && !jsonError) {
        facetsParam = [[NSString alloc] initWithData:jsonData encoding:NSUTF8StringEncoding];
    } else {
        NSLog(@"ModrinthAPI.searchModWithFilters: JSON error: %@", jsonError.localizedDescription);
    }
    
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
    
    NSDictionary *response = [self getEndpoint:@"search" params:params];
    if (!response) {
        NSLog(@"[ModrinthAPI] searchModWithFilters: No response returned");
        return nil;
    }
    
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
            NSLog(@"loadDetailsOfModSync: Missing file info for version %@", versionDict);
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
    NSError *extractError = nil;
    UZKArchive *archive = [[UZKArchive alloc] initWithPath:packagePath error:&extractError];
    if (extractError) {
        NSLog(@"[ModrinthAPI] Error opening package: %@", extractError);
        dispatch_async(dispatch_get_main_queue(), ^{
            [downloader finishDownloadWithErrorString:[NSString stringWithFormat:@"Failed to open modpack: %@", extractError.localizedDescription]];
        });
        return;
    }
    
    // Extract the modpack
    NSError *error = nil;
    BOOL extractionSuccess = YES;
    
    [archive performOnFilesInArchive:^(UZKFileInfo *fileInfo, BOOL *stop) {
        NSString *destItemPath = [destPath stringByAppendingPathComponent:fileInfo.filename];
        if (fileInfo.isDirectory) {
            NSError *dirError = nil;
            BOOL created = [[NSFileManager defaultManager] createDirectoryAtPath:destItemPath 
                                                     withIntermediateDirectories:YES 
                                                                      attributes:nil 
                                                                           error:&dirError];
            if (!created || dirError) {
                NSLog(@"[ModrinthAPI] Extraction error for directory %@: %@", destItemPath, dirError);
                *stop = YES;
                extractionSuccess = NO;
            }
        } else {
            NSError *fileError = nil;
            NSData *data = [archive extractData:fileInfo error:&fileError];
            if (!data || fileError) {
                NSLog(@"[ModrinthAPI] Extraction error for file %@: %@", fileInfo.filename, fileError);
                *stop = YES;
                extractionSuccess = NO;
            } else {
                BOOL written = [data writeToFile:destItemPath options:NSDataWritingAtomic error:&fileError];
                if (!written || fileError) {
                    NSLog(@"[ModrinthAPI] Write error for file %@: %@", destItemPath, fileError);
                    *stop = YES;
                    extractionSuccess = NO;
                }
            }
        }
    } error:&error];
    
    if (!extractionSuccess || error) {
        dispatch_async(dispatch_get_main_queue(), ^{
            [downloader finishDownloadWithErrorString:[NSString stringWithFormat:@"Extraction failed: %@", error.localizedDescription]];
        });
        return;
    }
    
    // Look for the modpack metadata (modrinth.index.json)
    NSString *modpackMetadataPath = [destPath stringByAppendingPathComponent:@"modrinth.index.json"];
    NSData *metadataData = [NSData dataWithContentsOfFile:modpackMetadataPath];
    if (!metadataData) {
        dispatch_async(dispatch_get_main_queue(), ^{
            [downloader finishDownloadWithErrorString:@"Missing modpack metadata (modrinth.index.json)"];
        });
        return;
    }
    
    NSError *jsonError = nil;
    NSDictionary *metadata = [NSJSONSerialization JSONObjectWithData:metadataData options:0 error:&jsonError];
    if (jsonError) {
        dispatch_async(dispatch_get_main_queue(), ^{
            [downloader finishDownloadWithErrorString:[NSString stringWithFormat:@"Failed to parse modpack metadata: %@", jsonError.localizedDescription]];
        });
        return;
    }
    
    // Process the modpack
    NSString *profileName = metadata[@"name"] ?: destPath.lastPathComponent;
    NSString *gameDir = [ModpackUtils getUniqueProfileDirectory:profileName];
    
    [ModpackUtils createProfileDirectory:gameDir];
    
    // Extract Minecraft version and mod loader version from the metadata
    NSString *minecraftVersion = metadata[@"dependencies"][@"minecraft"];
    NSString *modLoader = @"";
    NSString *modLoaderVersion = @"";
    if (metadata[@"dependencies"][@"fabric-loader"]) {
        modLoader = @"fabric";
        modLoaderVersion = metadata[@"dependencies"][@"fabric-loader"];
    } else if (metadata[@"dependencies"][@"forge"]) {
        modLoader = @"forge";
        modLoaderVersion = metadata[@"dependencies"][@"forge"];
    } else if (metadata[@"dependencies"][@"quilt-loader"]) {
        modLoader = @"quilt";
        modLoaderVersion = metadata[@"dependencies"][@"quilt-loader"];
    }
    
    NSString *finalVersionString = @"";
    if ([modLoader isEqualToString:@"fabric"]) {
        finalVersionString = [NSString stringWithFormat:@"fabric-loader-%@-%@", modLoaderVersion, minecraftVersion];
    } else if ([modLoader isEqualToString:@"forge"]) {
        finalVersionString = [NSString stringWithFormat:@"%@-forge-%@", minecraftVersion, modLoaderVersion];
    } else if ([modLoader isEqualToString:@"quilt"]) {
        finalVersionString = [NSString stringWithFormat:@"quilt-loader-%@-%@", modLoaderVersion, minecraftVersion];
    } else {
        finalVersionString = minecraftVersion;
    }
    
    // Create the profile
    NSDictionary *profileInfo = @{
        @"gameDir": gameDir,
        @"name": profileName,
        @"lastVersionId": finalVersionString,
        @"icon": @""
    };
    
    dispatch_async(dispatch_get_main_queue(), ^{
        NSLog(@"[ModrinthAPI] Setting profile: %@", profileName);
        PLProfiles.current.profiles[profileName] = [profileInfo mutableCopy];
        PLProfiles.current.selectedProfileName = profileName;
        [PLProfiles.current save];
        
        // Installation succeeded
        [downloader.progress setCompletedUnitCount:downloader.progress.totalUnitCount];
    });
}

@end

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
    NSDictionary* indexDict = [NSJSONSerialization JSONObjectWithData:indexData options:kNilOptions error:&error];
    if (error) {
        [downloader finishDownloadWithErrorString:[NSString stringWithFormat:@"Failed to parse modrinth.index.json: %@", error.localizedDescription]];
        return;
    }

    // Set phase description for downloading modpack files
    downloader.currentPhase = DownloadPhaseModpackExtraction;
    
    // Get files and create a more unique display name for each file
    NSArray *files = indexDict[@"files"];
    downloader.currentPhaseItemsTotal = [files count];
    downloader.currentPhaseItemsCompleted = 0;
    [downloader updatePhaseDescription];
    
    // Add a uniqueness counter to make sure all display names are distinct
    NSMutableDictionary *fileNameCounts = [NSMutableDictionary dictionary];
    
    downloader.progress.totalUnitCount = [files count];
    for (NSDictionary *indexFile in files) {
        NSString *url = [indexFile[@"downloads"] firstObject];
        NSString *sha = indexFile[@"hashes"][@"sha1"];
        NSString *path = [destPath stringByAppendingPathComponent:indexFile[@"path"]];
        NSUInteger size = [indexFile[@"fileSize"] unsignedLongLongValue];
        
        // Create a display name that includes more path information
        // This makes it more likely that each file will have a unique entry
        NSString *displayName = indexFile[@"path"];
        
        // Keep track of how many times this filename appears and add a counter if needed
        NSString *baseName = [displayName lastPathComponent];
        NSNumber *count = fileNameCounts[baseName];
        int occurrences = count ? [count intValue] + 1 : 1;
        fileNameCounts[baseName] = @(occurrences);
        
        // If this filename has been seen before, make it unique by including part of the path
        if (occurrences > 1 && [displayName pathComponents].count > 1) {
            NSArray *components = [displayName pathComponents];
            NSString *parentDir = components[components.count - 2];
            displayName = [NSString stringWithFormat:@"%@/%@", parentDir, baseName];
        }
        
        // Create a wrapped success callback to track completion and update phase description
        void(^fileSuccess)(void) = ^{
            downloader.currentPhaseItemsCompleted++;
            [downloader updatePhaseDescription];
        };
        
        NSURLSessionDownloadTask *task = [downloader createDownloadTask:url size:size sha:sha altName:displayName toPath:path success:fileSuccess];
        if (task) {
            // Add to file list with the unique display name
            [downloader.fileList addObject:displayName];
            [task resume];
        } else if (!downloader.progress.cancelled) {
            downloader.progress.completedUnitCount++;
            downloader.currentPhaseItemsCompleted++;
            [downloader updatePhaseDescription];
        } else {
            return; // cancelled
        }
    }

    // Transition to setup phase for extraction
    downloader.currentPhase = DownloadPhaseModpackSetup;
    downloader.currentPhaseItemsTotal = 2; // Two extraction operations
    downloader.currentPhaseItemsCompleted = 0;
    [downloader updatePhaseDescription];
    
    // Add a specific identifier for the extraction process
    [downloader.fileList addObject:@"Extracting overrides..."];
    NSProgress *extractionProgress = [NSProgress progressWithTotalUnitCount:100];
    [downloader.progressList addObject:extractionProgress];
    
    // Extract overrides directory
    [ModpackUtils archive:archive extractDirectory:@"overrides" toPath:destPath error:&error];
    if (error) {
        [downloader finishDownloadWithErrorString:[NSString stringWithFormat:@"Failed to extract overrides from modpack package: %@", error.localizedDescription]];
        return;
    }
    
    // Update extraction progress
    extractionProgress.completedUnitCount = 50;
    downloader.currentPhaseItemsCompleted++;
    [downloader updatePhaseDescription];

    // Add another specific identifier for client extractions
    [downloader.fileList addObject:@"Extracting client files..."];
    NSProgress *clientExtractionProgress = [NSProgress progressWithTotalUnitCount:100];
    [downloader.progressList addObject:clientExtractionProgress];
    
    // Extract client-overrides directory
    [ModpackUtils archive:archive extractDirectory:@"client-overrides" toPath:destPath error:&error];
    if (error) {
        [downloader finishDownloadWithErrorString:[NSString stringWithFormat:@"Failed to extract client-overrides from modpack package: %@", error.localizedDescription]];
        return;
    }

    // Mark extraction as complete
    clientExtractionProgress.completedUnitCount = 100;
    extractionProgress.completedUnitCount = 100;
    
    // Mark setup phase as complete
    downloader.currentPhaseItemsCompleted++;
    [downloader updatePhaseDescription];
    
    // Delete package cache
    [NSFileManager.defaultManager removeItemAtPath:packagePath error:nil];

    // Download dependency client json (if available)
    NSDictionary<NSString *, NSString *> *depInfo = [ModpackUtils infoForDependencies:indexDict[@"dependencies"]];
    if (depInfo[@"json"]) {
        NSString *jsonPath = [NSString stringWithFormat:@"%1$s/versions/%2$@/%2$@.json", getenv("POJAV_GAME_DIR"), depInfo[@"id"]];
        
        // Add a specific identifier for the json download
        [downloader.fileList addObject:@"Setting up mod loader..."];
        NSProgress *jsonProgress = [NSProgress progressWithTotalUnitCount:100];
        [downloader.progressList addObject:jsonProgress];
        
        NSURLSessionDownloadTask *task = [downloader createDownloadTask:depInfo[@"json"] size:0 sha:nil altName:nil toPath:jsonPath];
        [task resume];
        
        // Mark the json download as complete
        jsonProgress.completedUnitCount = 100;
    }
    // TODO: automation for Forge

    // Create profile
    NSString *tmpIconPath = [NSTemporaryDirectory() stringByAppendingPathComponent:@"icon.png"];
    PLProfiles.current.profiles[indexDict[@"name"]] = @{
        @"gameDir": [NSString stringWithFormat:@"./custom_gamedir/%@", destPath.lastPathComponent],
        @"name": indexDict[@"name"],
        @"lastVersionId": depInfo[@"id"],
        @"icon": [NSString stringWithFormat:@"data:image/png;base64,%@",
            [[NSData dataWithContentsOfFile:tmpIconPath]
            base64EncodedStringWithOptions:0]]
    }.mutableCopy;
    PLProfiles.current.selectedProfileName = indexDict[@"name"];
    
    // Mark installation as complete
    downloader.currentPhase = DownloadPhaseComplete;
    [downloader updatePhaseDescription];
    
    // Add a completion marker
    [downloader.fileList addObject:@"Complete"];
    NSProgress *completeProgress = [NSProgress progressWithTotalUnitCount:1];
    completeProgress.completedUnitCount = 1;
    [downloader.progressList addObject:completeProgress];
    
    // Mark all tasks as complete in metadata
    if (!downloader.metadata) {
        downloader.metadata = [NSMutableDictionary dictionary];
    }
    downloader.metadata[@"allTasksComplete"] = @YES;
}

@end

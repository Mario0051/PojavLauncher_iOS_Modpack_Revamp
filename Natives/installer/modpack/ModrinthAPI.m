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

@end

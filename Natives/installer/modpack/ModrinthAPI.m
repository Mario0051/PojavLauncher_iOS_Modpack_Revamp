#import "ModrinthAPI.h"
#import "MinecraftResourceDownloadTask.h"
#import "PLProfiles.h"

@implementation ModrinthAPI

- (instancetype)init {
    return [super initWithURL:@"https://api.modrinth.com/v2"];
}

- (NSMutableArray *)searchModWithFilters:(NSDictionary<NSString *, id> *)searchFilters
                       previousPageResult:(NSMutableArray *)modrinthSearchResult {
    NSString *projectType = [searchFilters[@"isModpack"] boolValue] ? @"modpack" : @"mod";
    NSString *mcVer = searchFilters[@"mcVersion"];
    NSMutableArray *outerFacets = [NSMutableArray array];
    
    // Build facets array
    [outerFacets addObject:@[[NSString stringWithFormat:@"project_type:%@", projectType]]];
    if (mcVer && mcVer.length > 0) {
        [outerFacets addObject:@[[NSString stringWithFormat:@"versions:%@", mcVer]]];
    }
    
    // Convert facets to JSON string
    NSString *facetsParam = @"[]";
    NSError *jsonError = nil;
    NSData *jsonData = [NSJSONSerialization dataWithJSONObject:outerFacets options:0 error:&jsonError];
    if (jsonData && !jsonError) {
        facetsParam = [[NSString alloc] initWithData:jsonData encoding:NSUTF8StringEncoding];
    } else {
        NSLog(@"ModrinthAPI.searchModWithFilters: JSON error: %@", jsonError.localizedDescription);
        self.lastError = jsonError;
    }
    
    // Set up search parameters
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
    
    // Make the request
    NSDictionary *response = [self getEndpoint:@"search" params:params];
    if (!response) {
        NSLog(@"[ModrinthAPI] searchModWithFilters: No response returned");
        return nil;
    }
    
    // Process results
    NSMutableArray *result = modrinthSearchResult ?: [NSMutableArray new];
    NSArray *hits = response[@"hits"];
    if ([hits isKindOfClass:[NSArray class]]) {
        for (NSDictionary *hit in hits) {
            if (![hit isKindOfClass:[NSDictionary class]]) {
                continue;
            }
            
            NSString *projectType = hit[@"project_type"];
            BOOL isModpack = [projectType isKindOfClass:[NSString class]] && [projectType isEqualToString:@"modpack"];
            
            NSMutableDictionary *entry = [@{
                @"apiSource": @(1),
                @"isModpack": @(isModpack),
                @"id": hit[@"project_id"] ?: @"",
                @"title": hit[@"title"] ?: @"",
                @"description": hit[@"description"] ?: @"",
                @"imageUrl": hit[@"icon_url"] ?: @""
            } mutableCopy];
            
            [result addObject:entry];
        }
    }
    
    // Check if we've reached the last page
    NSNumber *totalHits = response[@"total_hits"];
    if ([totalHits isKindOfClass:[NSNumber class]]) {
        self.reachedLastPage = result.count >= [totalHits unsignedLongValue];
    } else {
        self.reachedLastPage = YES;
    }
    
    return result;
}

- (void)loadDetailsOfMod:(NSMutableDictionary *)item {
    [self loadDetailsOfMod:item completion:^(NSError *error) {}];
}

- (void)loadDetailsOfModSync:(NSMutableDictionary *)item {
    if (!item || ![item isKindOfClass:[NSMutableDictionary class]]) {
        NSLog(@"loadDetailsOfModSync: Invalid item");
        return;
    }
    
    NSString *modId = item[@"id"];
    if (!modId || ![modId isKindOfClass:[NSString class]] || modId.length == 0) {
        NSLog(@"loadDetailsOfModSync: Missing mod ID");
        return;
    }
    
    NSArray *response = [self getEndpoint:[NSString stringWithFormat:@"project/%@/version", modId] params:@{}];
    if (!response) {
        NSLog(@"loadDetailsOfModSync: No response for mod id %@", modId);
        return;
    }
    
    if (![response isKindOfClass:[NSArray class]]) {
        NSLog(@"loadDetailsOfModSync: Unexpected response type: %@", [response class]);
        return;
    }
    
    NSMutableArray *versionNames = [NSMutableArray new];
    NSMutableArray *gameVersionsArray = [NSMutableArray new];
    NSMutableArray *versionUrls = [NSMutableArray new];
    NSMutableArray *versionSizes = [NSMutableArray new];
    NSMutableArray *versionHashes = [NSMutableArray new];
    NSMutableArray *versionLoaders = [NSMutableArray new];
    
    for (NSDictionary *versionDict in response) {
        if (![versionDict isKindOfClass:[NSDictionary class]]) {
            continue;
        }
        
        // Extract version display name
        NSString *versionDisplay = versionDict[@"version_number"] ?: versionDict[@"name"] ?: @"";
        
        // Extract game versions
        NSArray *supportedGameVersions = versionDict[@"game_versions"];
        if (![supportedGameVersions isKindOfClass:[NSArray class]]) {
            supportedGameVersions = @[];
        }
        
        // Extract file info
        NSArray *files = versionDict[@"files"];
        if (![files isKindOfClass:[NSArray class]] || files.count == 0) {
            NSLog(@"loadDetailsOfModSync: Missing file info for version %@", versionDict);
            continue;
        }
        
        NSDictionary *file = files[0];
        if (![file isKindOfClass:[NSDictionary class]]) {
            continue;
        }
        
        NSString *url = file[@"url"] ?: @"";
        NSNumber *size = file[@"size"];
        if (![size isKindOfClass:[NSNumber class]]) {
            size = @0;
        }
        
        // Extract hashes
        NSDictionary *hashes = file[@"hashes"];
        NSString *sha1 = @"";
        if ([hashes isKindOfClass:[NSDictionary class]]) {
            sha1 = hashes[@"sha1"] ?: @"";
        }
        
        // Extract loaders
        NSArray *loaders = versionDict[@"loaders"];
        if (![loaders isKindOfClass:[NSArray class]]) {
            loaders = @[];
        }
        
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
    if (!item || ![item isKindOfClass:[NSMutableDictionary class]]) {
        NSError *error = [NSError errorWithDomain:@"ModrinthAPIErrorDomain" 
                                             code:101 
                                         userInfo:@{NSLocalizedDescriptionKey: @"Invalid item"}];
        if (completion) {
            completion(error);
        }
        return;
    }
    
    NSString *modId = item[@"id"];
    if (!modId || ![modId isKindOfClass:[NSString class]] || modId.length == 0) {
        NSError *error = [NSError errorWithDomain:@"ModrinthAPIErrorDomain" 
                                             code:102 
                                         userInfo:@{NSLocalizedDescriptionKey: @"Missing mod ID"}];
        if (completion) {
            completion(error);
        }
        return;
    }
    
    NSString *endpoint = [NSString stringWithFormat:@"project/%@/version", modId];
    __weak typeof(self) weakSelf = self;
    
    [self getEndpoint:endpoint params:@{} completion:^(id response, NSError *error) {
        if (!response) {
            NSLog(@"loadDetailsOfMod: No response for mod id %@, error: %@", modId, error);
            if (completion) {
                completion(error);
            }
            return;
        }
        
        if (![response isKindOfClass:[NSArray class]]) {
            NSLog(@"loadDetailsOfMod: Unexpected response type: %@", [response class]);
            NSError *formatError = [NSError errorWithDomain:@"ModrinthAPIErrorDomain" 
                                                       code:103 
                                                   userInfo:@{NSLocalizedDescriptionKey:@"Unexpected response format"}];
            if (completion) {
                completion(formatError);
            }
            return;
        }
        
        NSMutableArray *versionNames = [NSMutableArray new];
        NSMutableArray *gameVersionsArray = [NSMutableArray new];
        NSMutableArray *versionUrls = [NSMutableArray new];
        NSMutableArray *versionSizes = [NSMutableArray new];
        NSMutableArray *versionHashes = [NSMutableArray new];
        NSMutableArray *versionLoaders = [NSMutableArray new];
        
        NSArray *versionsArray = (NSArray *)response;
        for (NSDictionary *versionDict in versionsArray) {
            if (![versionDict isKindOfClass:[NSDictionary class]]) {
                continue;
            }
            
            // Extract version display name
            NSString *versionDisplay = versionDict[@"version_number"] ?: versionDict[@"name"] ?: @"";
            
            // Extract game versions
            NSArray *supportedGameVersions = versionDict[@"game_versions"];
            if (![supportedGameVersions isKindOfClass:[NSArray class]]) {
                supportedGameVersions = @[];
            }
            
            // Extract file info
            NSArray *files = versionDict[@"files"];
            if (![files isKindOfClass:[NSArray class]] || files.count == 0) {
                NSLog(@"loadDetailsOfMod: Missing file info for version %@", versionDict);
                continue;
            }
            
            NSDictionary *file = files[0];
            if (![file isKindOfClass:[NSDictionary class]]) {
                continue;
            }
            
            NSString *url = file[@"url"] ?: @"";
            NSNumber *size = file[@"size"];
            if (![size isKindOfClass:[NSNumber class]]) {
                size = @0;
            }
            
            // Extract hashes
            NSDictionary *hashes = file[@"hashes"];
            NSString *sha1 = @"";
            if ([hashes isKindOfClass:[NSDictionary class]]) {
                sha1 = hashes[@"sha1"] ?: @"";
            }
            
            // Extract loaders
            NSArray *loaders = versionDict[@"loaders"];
            if (![loaders isKindOfClass:[NSArray class]]) {
                loaders = @[];
            }
            
            [versionNames addObject:versionDisplay];
            [gameVersionsArray addObject:supportedGameVersions];
            [versionUrls addObject:url];
            [versionSizes addObject:size];
            [versionHashes addObject:sha1];
            [versionLoaders addObject:loaders];
        }
        
        dispatch_async(dispatch_get_main_queue(), ^{
            item[@"versionNames"] = versionNames;
            item[@"gameVersions"] = gameVersionsArray;
            item[@"versionUrls"] = versionUrls;
            item[@"versionSizes"] = versionSizes;
            item[@"versionHashes"] = versionHashes;
            item[@"versionLoaders"] = versionLoaders;
            item[@"versionDetailsLoaded"] = @(YES);
            
            NSLog(@"loadDetailsOfMod: Loaded %lu versions for mod %@", (unsigned long)versionNames.count, modId);
            
            if (completion) {
                completion(nil);
            }
        });
    }];
}

- (void)installModFromDetail:(NSDictionary *)modDetail atIndex:(NSUInteger)selectedVersion {
    if (!modDetail) {
        NSLog(@"[ModrinthAPI] Cannot install mod: nil modDetail");
        return;
    }
    
    NSDictionary *userInfo = @{
        @"detail": modDetail,
        @"index": @(selectedVersion)
    };
    
    dispatch_async(dispatch_get_main_queue(), ^{
        [[NSNotificationCenter defaultCenter] postNotificationName:@"InstallMod" 
                                                            object:self 
                                                          userInfo:userInfo];
    });
}

@end

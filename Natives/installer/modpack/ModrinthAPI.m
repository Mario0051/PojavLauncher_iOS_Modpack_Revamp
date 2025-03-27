#import "AFNetworking.h"
#import "installer/FabricUtils.h"
#import "JavaGUIViewController.h"
#import "LauncherNavigationController.h"
#import "MinecraftResourceDownloadTask.h"
#import "ModrinthAPI.h"
#import "ModpackUtils.h"
#import "PLProfiles.h"
#import "UIKit+hook.h"
#import "utils.h"
#import "LauncherPreferences.h"

// External functions from utils.h
extern void showDialog(NSString *title, NSString *message);

// Maximum concurrent downloads for modpack files
#define MAX_CONCURRENT_DOWNLOADS 6

@interface ModrinthAPI ()
@property (nonatomic, assign) NSInteger pendingModpackDownloads;
@property (nonatomic, strong) NSLock *downloadCountLock;
@property (nonatomic, strong) dispatch_queue_t fileProcessingQueue;
@end

@implementation ModrinthAPI

// Helper function to convert WebP URLs to supported formats
- (NSString *)convertWebPUrl:(NSString *)imageUrl {
    if (!imageUrl || imageUrl.length == 0) {
        return imageUrl;
    }
    
    // Handle WebP format by requesting PNG instead
    if ([imageUrl.lowercaseString hasSuffix:@".webp"]) {
        // Try one of several approaches:
        
        // 1. For Modrinth CDN: Add format=png parameter
        if ([imageUrl containsString:@"cdn.modrinth.com"]) {
            // Check if URL already has parameters
            if ([imageUrl containsString:@"?"]) {
                return [imageUrl stringByAppendingString:@"&format=png"];
            } else {
                return [imageUrl stringByAppendingString:@"?format=png"];
            }
        }
        
        // 2. For other services: Try changing extension
        return [imageUrl stringByReplacingOccurrencesOfString:@".webp" 
                                                   withString:@".png" 
                                                      options:NSCaseInsensitiveSearch 
                                                        range:NSMakeRange(0, imageUrl.length)];
    }
    
    return imageUrl;
}

- (instancetype)init {
    self = [super init];
    if (self) {
        // Create URL session configuration with appropriate settings
        NSURLSessionConfiguration *configuration = [NSURLSessionConfiguration defaultSessionConfiguration];
        
        // Set reasonable timeouts
        configuration.timeoutIntervalForRequest = 30.0;
        configuration.timeoutIntervalForResource = 60.0;
        
        // Use a descriptive user agent
        configuration.HTTPAdditionalHeaders = @{
            @"User-Agent": @"PojavLauncher-iOS",
            @"Accept": @"application/json"
        };
        
        // Initialize URL session with configuration
        self.session = [NSURLSession sessionWithConfiguration:configuration];
        
        // Initialize other properties
        self.reachedLastPage = NO;
    }
    return self;
}

- (NSMutableArray *)searchModWithFilters:(NSDictionary *)filters previousPageResult:(NSMutableArray *)previousPageResult {
    // Safety check for filters
    if (!filters) {
        filters = @{};
    }
    
    // Get pagination info
    NSInteger offset = [previousPageResult count];
    
    // Create URL with basic endpoint - default project type is "mod"
    NSString *urlStr = @"https://api.modrinth.com/v2/search";
    NSURL *url = [NSURL URLWithString:urlStr];
    
    // Prepare parameters dictionary with nil safety
    NSMutableDictionary *parameters = [NSMutableDictionary dictionary];
    
    // Include the standard facets for modpacks
    if ([filters[@"isModpack"] boolValue]) {
        parameters[@"facets"] = @"[[\"project_type:modpack\"]]";
    }
    
    // Set limit for results per page
    parameters[@"limit"] = @"50";
    
    // Only include offset if we have previous results
    if (offset > 0) {
        parameters[@"offset"] = [NSString stringWithFormat:@"%ld", (long)offset];
    }
    
    // Apply sort method if provided
    NSString *sortMethod = filters[@"sortMethod"];
    if (sortMethod && sortMethod.length > 0) {
        parameters[@"index"] = sortMethod;
    } else {
        parameters[@"index"] = @"relevance";
    }
    
    // Apply search term if provided - ensure it's not nil
    NSString *searchTerm = filters[@"name"];
    if (searchTerm && searchTerm.length > 0) {
        parameters[@"query"] = searchTerm;
    }
    
    // Log the parameters for debugging
    NSLog(@"[ModrinthAPI] Searching with params: %@", parameters);
    
    // Create request
    NSError *error;
    NSURLRequest *request = [[AFJSONRequestSerializer serializer] requestWithMethod:@"GET" URLString:urlStr parameters:parameters error:&error];
    
    if (error) {
        NSLog(@"[ModrinthAPI] Error creating request: %@", error);
        self.lastError = error;
        return previousPageResult ?: [NSMutableArray array];
    }
    
    // Perform synchronous request
    dispatch_semaphore_t semaphore = dispatch_semaphore_create(0);
    __block id responseObject = nil;
    __block NSError *requestError = nil;
    
    [self.sessionManager dataTaskWithRequest:request uploadProgress:nil downloadProgress:nil completionHandler:^(NSURLResponse *response, id responseData, NSError *dataError) {
        responseObject = responseData;
        requestError = dataError;
        dispatch_semaphore_signal(semaphore);
    }] resume];
    
    dispatch_semaphore_wait(semaphore, dispatch_time(DISPATCH_TIME_NOW, 30 * NSEC_PER_SEC));
    
    // Handle request errors
    if (requestError) {
        NSLog(@"[ModrinthAPI] Network error: %@", requestError);
        self.lastError = requestError;
        return previousPageResult ?: [NSMutableArray array];
    }
    
    // Parse response
    NSDictionary *jsonResponse = responseObject;
    NSArray *hits = jsonResponse[@"hits"];
    
    // If no results, return empty array
    if (!hits || ![hits isKindOfClass:[NSArray class]]) {
        NSLog(@"[ModrinthAPI] No hits in response or invalid format");
        return previousPageResult ?: [NSMutableArray array];
    }
    
    // Update pagination state
    NSNumber *totalHits = jsonResponse[@"total_hits"];
    NSInteger totalResults = [totalHits integerValue];
    self.reachedLastPage = (offset + hits.count >= totalResults);
    
    NSLog(@"[ModrinthAPI] Got %lu search results", (unsigned long)hits.count);
    NSLog(@"[ModrinthAPI] Pagination: %ld/%ld (reached last page: %@)", 
          (long)(offset + hits.count), 
          (long)totalResults, 
          self.reachedLastPage ? @"YES" : @"NO");
    
    // Create result array
    NSMutableArray *modpacks = previousPageResult ?: [NSMutableArray array];
    
    // Process each result
    for (NSDictionary *modData in hits) {
        // Skip invalid data
        if (![modData isKindOfClass:[NSDictionary class]]) {
            continue;
        }
        
        // Create safe copy of data
        NSMutableDictionary *modpack = [NSMutableDictionary dictionary];
        
        // Copy standard fields with nil checks
        if (modData[@"title"]) modpack[@"title"] = modData[@"title"];
        if (modData[@"slug"]) modpack[@"slug"] = modData[@"slug"];
        if (modData[@"description"]) modpack[@"description"] = modData[@"description"];
        if (modData[@"project_id"]) modpack[@"id"] = modData[@"project_id"];
        if (modData[@"categories"]) modpack[@"categories"] = modData[@"categories"];
        if (modData[@"downloads"]) modpack[@"downloads"] = modData[@"downloads"];
        
        // Handle icon URL
        NSString *iconUrl = modData[@"icon_url"];
        if (iconUrl && iconUrl.length > 0) {
            modpack[@"imageUrl"] = iconUrl;
            NSLog(@"[ModrinthAPI] Project %@ has icon URL: %@", modpack[@"id"], iconUrl);
        }
        
        // Add to result array
        [modpacks addObject:modpack];
    }
    
    return modpacks;
}

- (void)loadDetailsOfMod:(NSMutableDictionary *)item {
    // Check for nil or invalid item
    if (!item || ![item isKindOfClass:[NSMutableDictionary class]]) {
        NSLog(@"[ModrinthAPI] Warning: item is nil or not a mutable dictionary");
        return;
    }
    
    // Check for project ID
    NSString *projectId = item[@"id"];
    if (!projectId || ![projectId isKindOfClass:[NSString class]] || projectId.length == 0) {
        NSLog(@"[ModrinthAPI] Warning: item has no valid ID");
        return;
    }
    
    // Create headers with proper User-Agent
    NSDictionary *headers = @{@"User-Agent": self.userAgent};
    
    // First, load full project details to get complete category info and other metadata
    NSString *projectEndpoint = [NSString stringWithFormat:@"project/%@", projectId];
    NSDictionary *projectDetails = [self getEndpoint:projectEndpoint params:nil headers:headers];
    
    // Extract additional metadata if available
    if (projectDetails) {
        // Check for updated icon URL and update if available
        if (projectDetails[@"icon_url"] && [projectDetails[@"icon_url"] isKindOfClass:[NSString class]]) {
            NSString *newIconUrl = projectDetails[@"icon_url"];
            newIconUrl = [newIconUrl stringByReplacingOccurrencesOfString:@"\\/" withString:@"/"];
            
            // Convert WebP URLs
            newIconUrl = [self convertWebPUrl:newIconUrl];
            
            // Only update if we have a valid URL
            if (newIconUrl.length > 0) {
                item[@"imageUrl"] = newIconUrl;
                NSLog(@"[ModrinthAPI] Updated icon URL for project %@: %@", projectId, newIconUrl);
            }
        }
        
        // Get complete categories list
        if (projectDetails[@"categories"] && [projectDetails[@"categories"] isKindOfClass:[NSArray class]]) {
            item[@"categories"] = projectDetails[@"categories"];
        }
        
        // Get additional tags if available
        if (projectDetails[@"additional_categories"] && [projectDetails[@"additional_categories"] isKindOfClass:[NSArray class]]) {
            NSMutableArray *allCategories = [NSMutableArray arrayWithArray:item[@"categories"] ?: @[]];
            [allCategories addObjectsFromArray:projectDetails[@"additional_categories"]];
            item[@"categories"] = allCategories;
        }
        
        // Get client/server side info
        if (projectDetails[@"client_side"]) {
            item[@"client_side"] = projectDetails[@"client_side"];
        }
        if (projectDetails[@"server_side"]) {
            item[@"server_side"] = projectDetails[@"server_side"];
        }
        
        // Get license info
        if (projectDetails[@"license"]) {
            item[@"license"] = projectDetails[@"license"];
        }
    }
    
    // Now load version data
    NSString *endpoint = [NSString stringWithFormat:@"project/%@/version", projectId];
    NSArray *response = [self getEndpoint:endpoint params:nil headers:headers];
    
    // Check response validity
    if (!response || ![response isKindOfClass:[NSArray class]] || response.count == 0) {
        NSLog(@"[ModrinthAPI] Warning: no version data for project ID %@", projectId);
        return;
    }
    
    // Extract version data
    NSMutableArray<NSString *> *names = [NSMutableArray new];
    NSMutableArray<NSString *> *mcNames = [NSMutableArray new];
    NSMutableArray<NSString *> *urls = [NSMutableArray new];
    NSMutableArray<NSString *> *hashes = [NSMutableArray new];
    NSMutableArray<NSNumber *> *sizes = [NSMutableArray new];
    
    // Initialize arrays to avoid index out of bounds
    for (NSUInteger i = 0; i < response.count; i++) {
        [names addObject:@"Unknown Version"];
        [mcNames addObject:@"Unknown"];
        [urls addObject:@""];
        [hashes addObject:@""];
        [sizes addObject:@(0)];
    }
    
    // Safely process each version
    [response enumerateObjectsUsingBlock:^(NSDictionary *version, NSUInteger i, BOOL *stop) {
        if (![version isKindOfClass:[NSDictionary class]]) {
            return;
        }
        
        // Get version name
        if (version[@"name"] && [version[@"name"] isKindOfClass:[NSString class]]) {
            names[i] = version[@"name"];
        }
        
        // Get Minecraft version
        if (version[@"game_versions"] && [version[@"game_versions"] isKindOfClass:[NSArray class]] && 
            [version[@"game_versions"] count] > 0 && 
            [version[@"game_versions"][0] isKindOfClass:[NSString class]]) {
            mcNames[i] = version[@"game_versions"][0];
        }
        
        // Get file information - prefer primary file if available
        if (version[@"files"] && [version[@"files"] isKindOfClass:[NSArray class]] && 
            [version[@"files"] count] > 0) {
            
            // Find the primary file first if possible
            NSDictionary *primaryFile = nil;
            for (NSDictionary *file in version[@"files"]) {
                if ([file isKindOfClass:[NSDictionary class]] && 
                    [file[@"primary"] boolValue]) {
                    primaryFile = file;
                    break;
                }
            }
            
            // If no primary file, use the first file
            NSDictionary *file = primaryFile ?: version[@"files"][0];
            
            if ([file isKindOfClass:[NSDictionary class]]) {
                // Get file size
                if (file[@"size"] && [file[@"size"] isKindOfClass:[NSNumber class]]) {
                    sizes[i] = file[@"size"];
                }
                
                // Get download URL
                if (file[@"url"] && [file[@"url"] isKindOfClass:[NSString class]]) {
                    NSString *fileUrl = [file[@"url"] stringByReplacingOccurrencesOfString:@"\\/" withString:@"/"];
                    urls[i] = fileUrl;
                }
                
                // Get hash
                if (file[@"hashes"] && [file[@"hashes"] isKindOfClass:[NSDictionary class]] && 
                    file[@"hashes"][@"sha1"] && [file[@"hashes"][@"sha1"] isKindOfClass:[NSString class]]) {
                    hashes[i] = file[@"hashes"][@"sha1"];
                }
            }
        }
    }];
    
    // Update the item with version information
    item[@"versionNames"] = names;
    item[@"mcVersionNames"] = mcNames;
    item[@"versionSizes"] = sizes;
    item[@"versionUrls"] = urls;
    item[@"versionHashes"] = hashes;
    item[@"versionDetailsLoaded"] = @(YES);
}

- (id)getEndpoint:(NSString *)endpoint params:(NSDictionary *)params headers:(NSDictionary *)headers {
    // Create a cancel semaphore to handle timeouts
    dispatch_semaphore_t cancelSemaphore = dispatch_semaphore_create(0);
    
    // Initialize data holder
    __block NSData *responseData = nil;
    __block NSError *responseError = nil;
    
    // Create URL with parameters
    NSMutableString *urlString = [NSMutableString stringWithString:endpoint];
    
    // Add query parameters if provided
    if (params && params.count > 0) {
        [urlString appendString:@"?"];
        NSMutableArray *queryParams = [NSMutableArray array];
        
        for (NSString *key in params) {
            NSString *value = [params[key] description];
            NSString *escapedValue = [value stringByAddingPercentEncodingWithAllowedCharacters:[NSCharacterSet URLQueryAllowedCharacterSet]];
            [queryParams addObject:[NSString stringWithFormat:@"%@=%@", key, escapedValue]];
        }
        
        [urlString appendString:[queryParams componentsJoinedByString:@"&"]];
    }
    
    // Create URL request
    NSURL *url = [NSURL URLWithString:urlString];
    NSMutableURLRequest *request = [NSMutableURLRequest requestWithURL:url];
    
    // Set HTTP method
    [request setHTTPMethod:@"GET"];
    
    // Set headers
    if (headers) {
        for (NSString *key in headers) {
            [request setValue:headers[key] forHTTPHeaderField:key];
        }
    }
    
    // Add default User-Agent if not provided
    if (![request valueForHTTPHeaderField:@"User-Agent"]) {
        [request setValue:@"PojavLauncher iOS" forHTTPHeaderField:@"User-Agent"];
    }
    
    // Set reasonable timeout
    [request setTimeoutInterval:20.0];
    
    // Create URLSession task
    NSURLSessionTask *task = [self.session dataTaskWithRequest:request completionHandler:^(NSData *data, NSURLResponse *response, NSError *error) {
        if (error) {
            responseError = error;
        } else if (data) {
            responseData = data;
        }
        
        // Signal completion
        dispatch_semaphore_signal(cancelSemaphore);
    }];
    
    // Start the task
    [task resume];
    
    // Use the semaphore for the current thread only (this is already running in a background thread)
    // Set a timeout to prevent hanging indefinitely
    long result = dispatch_semaphore_wait(cancelSemaphore, dispatch_time(DISPATCH_TIME_NOW, 20 * NSEC_PER_SEC));
    
    // Handle timeout
    if (result != 0) {
        [task cancel];
        self.lastError = [NSError errorWithDomain:@"ModrinthAPI" 
                                             code:NSURLErrorTimedOut 
                                         userInfo:@{NSLocalizedDescriptionKey: @"Request timed out"}];
        return nil;
    }
    
    // Handle error
    if (responseError) {
        self.lastError = responseError;
        return nil;
    }
    
    // If no data was received
    if (!responseData) {
        return nil;
    }
    
    // Try to parse the response as JSON
    NSError *jsonError = nil;
    id jsonObject = [NSJSONSerialization JSONObjectWithData:responseData options:0 error:&jsonError];
    
    if (jsonError) {
        // If JSON parsing fails, return the raw data
        self.lastError = jsonError;
        return responseData;
    }
    
    // Return the parsed JSON object
    return jsonObject;
}

// Compatibility method for old code - forwards to method with headers
- (id)getEndpoint:(NSString *)endpoint params:(NSDictionary *)params {
    return [self getEndpoint:endpoint params:params headers:@{@"User-Agent": self.userAgent}];
}

- (void)downloader:(MinecraftResourceDownloadTask *)downloader submitDownloadTasksFromPackage:(NSString *)packagePath toPath:(NSString *)destPath {
    NSError *error;
    UZKArchive *archive = [[UZKArchive alloc] initWithPath:packagePath error:&error];
    if (error) {
        [downloader finishDownloadWithErrorString:[NSString stringWithFormat:@"Failed to open modpack package: %@", error.localizedDescription]];
        return;
    }

    NSLog(@"[ModrinthAPI] Opening modpack archive: %@", packagePath);
    NSLog(@"[ModrinthAPI] Destination path: %@", destPath);

    // Make sure the destination directory exists
    [[NSFileManager defaultManager] createDirectoryAtPath:destPath 
                             withIntermediateDirectories:YES 
                                              attributes:nil 
                                                   error:&error];
    if (error) {
        [downloader finishDownloadWithErrorString:[NSString stringWithFormat:@"Failed to create destination directory: %@", error.localizedDescription]];
        return;
    }

    // Reset progress for the new phase - initialize with a value that will be replaced
    downloader.progress.totalUnitCount = 1;
    downloader.progress.completedUnitCount = 0;
    if (downloader.textProgress) {
        downloader.textProgress.totalUnitCount = 1;
        downloader.textProgress.completedUnitCount = 0;
    }

    // Add a status entry to the file list
    [downloader.fileList addObject:@"Reading modpack index..."];
    NSProgress *indexProgress = [NSProgress progressWithTotalUnitCount:1];
    [downloader.progressList addObject:indexProgress];

    // Try to extract the index file - first try the newer format, then fall back to the older one
    NSData *indexData = [archive extractDataFromFile:@"index.json" error:nil];
    
    // If the newer format doesn't exist, try the older format
    if (!indexData) {
        indexData = [archive extractDataFromFile:@"modrinth.index.json" error:&error];
    }
    
    if (!indexData) {
        [downloader finishDownloadWithErrorString:@"Failed to find index.json or modrinth.index.json in modpack"];
        return;
    }
    
    // Update progress for index reading
    indexProgress.completedUnitCount = 1;
    
    NSDictionary* indexDict = [NSJSONSerialization JSONObjectWithData:indexData options:kNilOptions error:&error];
    if (error) {
        [downloader finishDownloadWithErrorString:[NSString stringWithFormat:@"Failed to parse modpack index: %@", error.localizedDescription]];
        return;
    }

    NSLog(@"[ModrinthAPI] Modpack index parsed successfully");

    // Store the destination path in metadata for later use
    if (!downloader.metadata) {
        downloader.metadata = [NSMutableDictionary dictionary];
    }
    downloader.metadata[@"destPath"] = destPath;

    // Get files and create a more unique display name for each file
    NSArray *files = indexDict[@"files"];
    if (!files || ![files isKindOfClass:[NSArray class]] || files.count == 0) {
        [downloader finishDownloadWithErrorString:@"No mod files found in modpack index"];
        return;
    }
    
    // Set up tracking for retries
    downloader.metadata[@"retryMap"] = [NSMutableDictionary dictionary];
    
    // Store the modpack dependencies for later use in Forge/NeoForge installation
    downloader.metadata[@"modpackDependencies"] = indexDict[@"dependencies"];
    
    // Calculate total size for better progress tracking
    unsigned long long totalSize = 0;
    for (NSDictionary *indexFile in files) {
        if ([indexFile isKindOfClass:[NSDictionary class]]) {
            if (indexFile[@"fileSize"] && [indexFile[@"fileSize"] isKindOfClass:[NSNumber class]]) {
                totalSize += [indexFile[@"fileSize"] unsignedLongLongValue];
            }
        }
    }
    
    // Reset the progress tracking with actual file count and size
    downloader.progress.totalUnitCount = totalSize > 0 ? totalSize : files.count;
    downloader.progress.completedUnitCount = 0;
    
    if (downloader.textProgress) {
        downloader.textProgress.totalUnitCount = downloader.progress.totalUnitCount;
        downloader.textProgress.completedUnitCount = 0;
    }
    
    // Initialize the pending downloads counter
    [self.downloadCountLock lock];
    self.pendingModpackDownloads = files.count;
    [self.downloadCountLock unlock];
    
    NSLog(@"[ModrinthAPI] Starting download of %ld mod files", (long)files.count);
    
    // Add overall status to file list
    [downloader.fileList addObject:[NSString stringWithFormat:@"Downloading %ld files...", (long)files.count]];
    NSProgress *overallProgress = [NSProgress progressWithTotalUnitCount:files.count];
    overallProgress.completedUnitCount = 0;
    [downloader.progressList addObject:overallProgress];
    
    // Create a dispatch group for tracking completion
    dispatch_group_t downloadGroup = dispatch_group_create();
    
    // Process files in batches to avoid overwhelming the system
    NSInteger totalFiles = files.count;
    NSInteger batchSize = 20; // Process 20 files at a time for better organization
    
    for (NSInteger batchStart = 0; batchStart < totalFiles; batchStart += batchSize) {
        NSInteger batchEnd = MIN(batchStart + batchSize, totalFiles);
        NSRange batchRange = NSMakeRange(batchStart, batchEnd - batchStart);
        NSArray *batchFiles = [files subarrayWithRange:batchRange];
        
        // Process this batch of files
        for (NSDictionary *indexFile in batchFiles) {
            if (![indexFile isKindOfClass:[NSDictionary class]]) {
                NSLog(@"[ModrinthAPI] Skipping invalid file entry");
                
                [self.downloadCountLock lock];
                self.pendingModpackDownloads--;
                [self.downloadCountLock unlock];
                
                overallProgress.completedUnitCount++;
                continue;
            }
            
            NSArray *downloadURLs = indexFile[@"downloads"];
            if (!downloadURLs || ![downloadURLs isKindOfClass:[NSArray class]] || downloadURLs.count == 0) {
                NSLog(@"[ModrinthAPI] File has no download URLs: %@", indexFile[@"path"]);
                
                [self.downloadCountLock lock];
                self.pendingModpackDownloads--;
                [self.downloadCountLock unlock];
                
                overallProgress.completedUnitCount++;
                continue;
            }
            
            NSString *url = [downloadURLs firstObject];
            NSString *sha = indexFile[@"hashes"][@"sha1"];
            
            // Ensure the path is correctly constructed relative to the destPath
            NSString *relativePath = indexFile[@"path"];
            
            // Make sure relativePath doesn't start with a slash to avoid path issues
            if ([relativePath hasPrefix:@"/"]) {
                relativePath = [relativePath substringFromIndex:1];
            }
            
            NSString *path = [destPath stringByAppendingPathComponent:relativePath];
            
            NSUInteger size = [indexFile[@"fileSize"] unsignedLongLongValue];
            
            // Create directory structure if needed
            NSString *dirPath = [path stringByDeletingLastPathComponent];
            [[NSFileManager defaultManager] createDirectoryAtPath:dirPath 
                                     withIntermediateDirectories:YES 
                                                      attributes:nil 
                                                           error:nil];
            
            // Create a display name that includes more path information
            NSString *displayName = [NSString stringWithFormat:@"Downloading %@", relativePath];
            NSLog(@"[ModrinthAPI] Preparing to download: %@ to %@", displayName, path);
            
            // Create unique ID for tracking retries
            NSString *downloadID = [NSString stringWithFormat:@"%@_%@", path.lastPathComponent, sha ?: @"nohash"];
            
            // Enter the download group for this file
            dispatch_group_enter(downloadGroup);
            
            // Create success callback that decrements pending downloads
            void(^fileSuccess)(void) = ^{
                [self.downloadCountLock lock];
                self.pendingModpackDownloads--;
                NSInteger remaining = self.pendingModpackDownloads;
                [self.downloadCountLock unlock];
                
                NSLog(@"[ModrinthAPI] Download completed: %@, %ld remaining", relativePath, (long)remaining);
                
                // Update the overall progress
                overallProgress.completedUnitCount++;
                
                // Leave the download group for this file
                dispatch_group_leave(downloadGroup);
            };
            
            // Create failure callback that will retry the download once
            void(^fileFailure)(NSError *error) = ^(NSError *error) {
                // Check if this file has already been retried
                NSMutableDictionary *retryMap = downloader.metadata[@"retryMap"];
                NSNumber *retryCount = retryMap[downloadID];
                
                if (!retryCount || retryCount.intValue < 1) {
                    // Log retry attempt
                    NSLog(@"[ModrinthAPI] Retrying download for %@ after failure: %@", relativePath, error.localizedDescription);
                    
                    // Mark this file as retried
                    retryMap[downloadID] = @(retryCount ? retryCount.intValue + 1 : 1);
                    
                    // Create a new download task with the same parameters
                    NSURLSessionDownloadTask *retryTask = [downloader createDownloadTask:url 
                                                                               size:size 
                                                                                sha:sha 
                                                                            altName:[NSString stringWithFormat:@"%@ (retry)", displayName]
                                                                             toPath:path 
                                                                            success:fileSuccess
                                                                            failure:^(NSError *retryError) {
                        // If retry also fails, decrement pending count
                        NSLog(@"[ModrinthAPI] Retry failed for %@: %@", relativePath, retryError.localizedDescription);
                        
                        [self.downloadCountLock lock];
                        self.pendingModpackDownloads--;
                        [self.downloadCountLock unlock];
                        
                        // Update the overall progress
                        overallProgress.completedUnitCount++;
                        
                        // Leave the download group for this file
                        dispatch_group_leave(downloadGroup);
                    }];
                    
                    // Task is automatically queued by createDownloadTask
                } else {
                    // Already retried, decrement pending count
                    [self.downloadCountLock lock];
                    self.pendingModpackDownloads--;
                    [self.downloadCountLock unlock];
                    
                    overallProgress.completedUnitCount++;
                    
                    // Leave the download group for this file
                    dispatch_group_leave(downloadGroup);
                }
            };
            
            NSURLSessionDownloadTask *task = [downloader createDownloadTask:url 
                                                                   size:size 
                                                                    sha:sha 
                                                                altName:displayName 
                                                                 toPath:path 
                                                                success:fileSuccess
                                                                failure:fileFailure];
            
            if (!task && downloader.progress.cancelled) {
                // If download was cancelled, leave the group now
                dispatch_group_leave(downloadGroup);
                return; // Exit the loop
            } else if (!task) {
                // If task creation failed but download wasn't cancelled, still leave the group
                [self.downloadCountLock lock];
                self.pendingModpackDownloads--;
                [self.downloadCountLock unlock];
                
                overallProgress.completedUnitCount++;
                dispatch_group_leave(downloadGroup);
            }
            // NOTE: Tasks are now automatically queued and will be processed by the download queue
        }
    }
    
    // Wait for all downloads to complete with timeout
    dispatch_time_t timeout = dispatch_time(DISPATCH_TIME_NOW, (int64_t)(600 * NSEC_PER_SEC)); // 10 minute timeout
    
    dispatch_async(dispatch_get_global_queue(DISPATCH_QUEUE_PRIORITY_DEFAULT, 0), ^{
        // Wait for all tasks to complete or timeout
        long result = dispatch_group_wait(downloadGroup, timeout);
        
        if (result != 0) {
            // Timeout - some downloads didn't complete in time
            NSLog(@"[ModrinthAPI] Warning: Some downloads timed out, but continuing with extraction");
        }
        
        // Proceed with extraction even if some downloads failed
        if (!downloader.progress.cancelled) {
            [self extractAndFinalizeModpack:downloader archive:archive indexDict:indexDict destPath:destPath packagePath:packagePath];
        }
    });
}

- (void)extractAndFinalizeModpack:(MinecraftResourceDownloadTask *)downloader 
                          archive:(UZKArchive *)archive
                        indexDict:(NSDictionary *)indexDict
                         destPath:(NSString *)destPath
                      packagePath:(NSString *)packagePath {
    NSError *error;
    
    // Add extraction filename to track progress
    [downloader.fileList addObject:@"Extracting modpack..."];
    NSProgress *extractionProgress = [NSProgress progressWithTotalUnitCount:100];
    extractionProgress.completedUnitCount = 0;
    [downloader.progressList addObject:extractionProgress];
    [downloader.progress addChild:extractionProgress withPendingUnitCount:100];
    
    NSLog(@"[ModrinthAPI] Beginning extraction of modpack to %@", destPath);
    
    // Extract overrides directory - this is the main content directory
    extractionProgress.completedUnitCount = 10; // 10% for starting extraction
    [self extractDirectoryFromArchive:archive directory:@"overrides" toPath:destPath progress:extractionProgress];
    extractionProgress.completedUnitCount = 50; // 50% after overrides
    
    // Extract client-overrides directory if it exists (new in Modrinth format)
    [self extractDirectoryFromArchive:archive directory:@"client-overrides" toPath:destPath progress:extractionProgress];
    extractionProgress.completedUnitCount = 75; // 75% after client-overrides
    
    // Extract server-overrides directory if it exists (for completeness, though not used on client)
    [self extractDirectoryFromArchive:archive directory:@"server-overrides" toPath:destPath progress:nil];
    
    // Delete package cache
    [NSFileManager.defaultManager removeItemAtPath:packagePath error:nil];

    // Update extraction progress
    extractionProgress.completedUnitCount = 90; // 90% after cleanup

    // Download dependency client json (if available)
    NSDictionary<NSString *, NSString *> *depInfo = [ModpackUtils infoForDependencies:indexDict[@"dependencies"]];
    
    if (depInfo[@"json"]) {
        // Add JSON download to file list
        [downloader.fileList addObject:@"Downloading dependency JSON..."];
        NSProgress *jsonProgress = [NSProgress progressWithTotalUnitCount:100];
        jsonProgress.completedUnitCount = 0;
        [downloader.progressList addObject:jsonProgress];
        [downloader.progress addChild:jsonProgress withPendingUnitCount:50]; // Add to overall progress
        
        NSString *jsonPath = [NSString stringWithFormat:@"%1$s/versions/%2$@/%2$@.json", getenv("POJAV_GAME_DIR"), depInfo[@"id"]];
        
        // Create directories for JSON
        [[NSFileManager defaultManager] createDirectoryAtPath:[jsonPath stringByDeletingLastPathComponent] 
                                withIntermediateDirectories:YES 
                                                 attributes:nil 
                                                      error:nil];
        
        // Create a success callback that will run after JSON download completes
        void(^jsonSuccess)(void) = ^{
            // Mark JSON download as complete
            jsonProgress.completedUnitCount = 100;
            
            // Mark extraction as complete
            extractionProgress.completedUnitCount = 100;
            
            // Only create profile and mark as complete after JSON download
            [self finalizeModpackInstallation:downloader indexDict:indexDict depInfo:depInfo destPath:destPath];
        };
        
        // Use the version with success callback to wait for completion
        NSURLSessionDownloadTask *task = [downloader createDownloadTask:depInfo[@"json"] 
                                                                   size:0 
                                                                    sha:nil 
                                                                altName:@"Downloading dependency JSON..."
                                                                 toPath:jsonPath 
                                                                success:jsonSuccess
                                                                failure:^(NSError *jsonError) {
            NSLog(@"[ModrinthAPI] Failed to download JSON: %@", jsonError.localizedDescription);
            
            // Still mark JSON download as complete
            jsonProgress.completedUnitCount = 100;
            
            // Still mark extraction as complete
            extractionProgress.completedUnitCount = 100;
            
            // Still finalize the installation
            [self finalizeModpackInstallation:downloader indexDict:indexDict depInfo:depInfo destPath:destPath];
        }];
        
        // Task is automatically queued by createDownloadTask
    } else {
        // No JSON to download, so we can finalize immediately
        extractionProgress.completedUnitCount = 100;
        [self finalizeModpackInstallation:downloader indexDict:indexDict depInfo:depInfo destPath:destPath];
    }
}

- (void)extractDirectoryFromArchive:(UZKArchive *)archive directory:(NSString *)directoryName toPath:(NSString *)destPath progress:(NSProgress *)progress {
    // Only attempt extraction if the directory name is valid
    if (!directoryName || directoryName.length == 0) {
        NSLog(@"[ModrinthAPI] Invalid directory name for extraction");
        return;
    }
    
    NSError *error;
    NSLog(@"[ModrinthAPI] Extracting %@ directory to %@", directoryName, destPath);
    
    // Make sure we have a trailing slash for proper directory path comparison
    NSString *dirWithSlash = [directoryName hasSuffix:@"/"] ? directoryName : [directoryName stringByAppendingString:@"/"];
    
    // First check if the directory exists in the archive
    __block BOOL directoryExists = NO;
    [archive performOnFilesInArchive:^(UZKFileInfo *fileInfo, BOOL *stop) {
        if ([fileInfo.filename hasPrefix:dirWithSlash] || 
            [fileInfo.filename isEqualToString:directoryName] ||
            [fileInfo.filename hasPrefix:directoryName]) {
            directoryExists = YES;
            *stop = YES;
        }
    } error:&error];
    
    if (!directoryExists) {
        NSLog(@"[ModrinthAPI] Directory %@ not found in the archive, skipping", directoryName);
        return;
    }
    
    [ModpackUtils archive:archive extractDirectory:directoryName toPath:destPath error:&error];
    
    if (error) {
        NSLog(@"[ModrinthAPI] Error extracting %@ directory: %@", directoryName, error.localizedDescription);
    } else {
        NSLog(@"[ModrinthAPI] Successfully extracted %@ directory to %@", directoryName, destPath);
        
        // Update progress if provided
        if (progress) {
            progress.completedUnitCount = MIN(progress.completedUnitCount + 5, progress.totalUnitCount);
        }
    }
}

- (void)finalizeModpackInstallation:(MinecraftResourceDownloadTask *)downloader 
                          indexDict:(NSDictionary *)indexDict
                            depInfo:(NSDictionary *)depInfo
                           destPath:(NSString *)destPath {
    // Add setup progress to file list
    [downloader.fileList addObject:@"Setting up modpack profile..."];
    NSProgress *setupProgress = [NSProgress progressWithTotalUnitCount:100];
    setupProgress.completedUnitCount = 0;
    [downloader.progressList addObject:setupProgress];
    [downloader.progress addChild:setupProgress withPendingUnitCount:50]; // Add to overall progress
    
    // Update setup progress
    setupProgress.completedUnitCount = 25; // 25% started setup
    
    // Get the profile name from indexDict, or use the directory name if not available
    NSString *profileName = indexDict[@"name"];
    if (!profileName || [profileName length] == 0) {
        profileName = [destPath lastPathComponent];
    }
    
    // Calculate the relative gameDir from the absolute destPath
    NSString *gameDir;
    NSString *instancesPath = [NSString stringWithFormat:@"%s/instances/%@", 
                              getenv("POJAV_HOME"), 
                              getPrefObject(@"general.game_directory")];
    
    // Check if destPath is within the instances directory structure
    if ([destPath hasPrefix:instancesPath]) {
        // Calculate the relative path by removing the instances path prefix
        NSUInteger prefixLength = instancesPath.length;
        if (prefixLength < destPath.length) {
            // Extract relative path
            gameDir = [destPath substringFromIndex:prefixLength];
            
            // Remove leading slash if present
            if ([gameDir hasPrefix:@"/"]) {
                gameDir = [gameDir substringFromIndex:1];
            }
        } else {
            // Fallback: If the path calculation fails, use a default profile-based path
            gameDir = [PLProfiles uniqueGameDirForProfileName:profileName];
            NSLog(@"[ModrinthAPI] Warning: destPath equals or is shorter than instancesPath. Using default profile path: %@", gameDir);
        }
    } else {
        // If destPath is outside instances directory, use a standardized path
        gameDir = [PLProfiles uniqueGameDirForProfileName:profileName];
        NSLog(@"[ModrinthAPI] Warning: destPath is not within instances directory. Using default profile path: %@", gameDir);
    }
    
    // Update setup progress
    setupProgress.completedUnitCount = 50; // 50% determined paths
    
    NSLog(@"[ModrinthAPI] Creating profile: %@ with gameDir: %@", profileName, gameDir);
    
    // Create the profile with the properly aligned gameDir
    NSMutableDictionary *newProfile = [@{
        @"gameDir": gameDir,
        @"name": profileName,
        @"lastVersionId": depInfo[@"id"] ?: @"latest-release"
    } mutableCopy];
    
    // Update setup progress
    setupProgress.completedUnitCount = 75; // 75% profile created
    
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
    
    // Update setup progress
    setupProgress.completedUnitCount = 100; // 100% profile saved
    
    // Ensure metadata reflects completion and marks this as a modpack install
    if (!downloader.metadata) {
        downloader.metadata = [NSMutableDictionary dictionary];
    }
    downloader.metadata[@"isModpackInstall"] = @YES;
    downloader.metadata[@"allTasksComplete"] = @YES;
    downloader.metadata[@"profileName"] = profileName;
    
    // Ensure progress is marked as complete
    downloader.progress.completedUnitCount = downloader.progress.totalUnitCount;
    
    // Add completion marker
    [downloader.fileList addObject:@"Complete"];
    NSProgress *completeProgress = [NSProgress progressWithTotalUnitCount:1];
    completeProgress.completedUnitCount = 1;
    [downloader.progressList addObject:completeProgress];
    
    // Log completion
    NSLog(@"[ModrinthAPI] Modpack installation complete: %@", profileName);
    
    // Check for Forge immediately
    [self checkAndInstallForge:downloader 
             withDependencies:indexDict[@"dependencies"] 
                  profileName:profileName];
}

- (void)checkAndInstallForge:(MinecraftResourceDownloadTask *)downloader 
            withDependencies:(NSDictionary *)dependencies 
                 profileName:(NSString *)profileName {
    // Check if the modpack requires Forge/NeoForge
    NSString *forgeVersion = dependencies[@"forge"];
    NSString *neoForgeVersion = dependencies[@"neoforge"];
    NSString *minecraftVersion = dependencies[@"minecraft"];
    
    if (!forgeVersion && !neoForgeVersion) {
        // No Forge dependency, nothing to install
        return;
    }

    NSString *vendor = forgeVersion ? @"Forge" : @"NeoForge";
    NSString *version = forgeVersion ?: neoForgeVersion;
    NSString *fullVersion;
    
    // Format the version based on the vendor
    if ([vendor isEqualToString:@"Forge"]) {
        fullVersion = [NSString stringWithFormat:@"%@-%@", minecraftVersion, version];
    } else {
        // NeoForge uses a different format
        fullVersion = version;
    }
    
    // Check if this Forge version is already installed
    NSString *versionPath = [NSString stringWithFormat:@"%s/versions/%@", getenv("POJAV_GAME_DIR"), fullVersion];
    if ([NSFileManager.defaultManager fileExistsAtPath:versionPath]) {
        NSLog(@"[ModrinthAPI] %@ version %@ is already installed", vendor, fullVersion);
        return;
    }
    
    // Need to present this on the main thread after the download is complete
    dispatch_async(dispatch_get_main_queue(), ^{
        // Show alert to user
        UIAlertController *alert = [UIAlertController 
            alertControllerWithTitle:[NSString stringWithFormat:@"%@ Installation Required", vendor]
            message:[NSString stringWithFormat:@"This modpack requires %@ %@, which is not yet installed. Would you like to install it now?", vendor, fullVersion]
            preferredStyle:UIAlertControllerStyleAlert];
            
        [alert addAction:[UIAlertAction 
            actionWithTitle:@"Yes" 
            style:UIAlertActionStyleDefault 
            handler:^(UIAlertAction * _Nonnull action) {
                // Get the correct endpoint info based on vendor type
                NSDictionary *endpoints;
                
                if ([vendor isEqualToString:@"Forge"]) {
                    endpoints = @{
                        @"installer": @"https://maven.minecraftforge.net/net/minecraftforge/forge/%1$@/forge-%1$@-installer.jar",
                        @"metadata": @"https://maven.minecraftforge.net/net/minecraftforge/forge/maven-metadata.xml"
                    };
                } else { // NeoForge
                    endpoints = @{
                        @"installer": @"https://maven.neoforged.net/releases/net/neoforged/neoforge/%1$@/neoforge-%1$@-installer.jar",
                        @"metadata": @"https://maven.neoforged.net/releases/net/neoforged/neoforge/maven-metadata.xml"
                    };
                }
                
                // Download the installer
                NSString *installerUrl = [NSString stringWithFormat:endpoints[@"installer"], fullVersion];
                NSString *outPath = [NSTemporaryDirectory() stringByAppendingPathComponent:@"forge-installer.jar"];
                NSLog(@"[ModrinthAPI] Downloading %@ installer from: %@", vendor, installerUrl);
                
                // Create download manager
                NSURLSessionConfiguration *configuration = [NSURLSessionConfiguration defaultSessionConfiguration];
                AFURLSessionManager *manager = [[AFURLSessionManager alloc] initWithSessionConfiguration:configuration];
                
                // Setup UI for download
                UIViewController *currentVC = nil;
                UISplitViewController *splitVC = nil;
                
                // Find the root view controller - proper way to get the current UI
                NSArray<UIWindow *> *windows = nil;
                if (@available(iOS 13.0, *)) {
                    UIWindowScene *windowScene = nil;
                    for (UIScene *scene in UIApplication.sharedApplication.connectedScenes) {
                        if ([scene isKindOfClass:[UIWindowScene class]] && 
                            ((UIWindowScene *)scene).activationState == UISceneActivationStateForegroundActive) {
                            windowScene = (UIWindowScene *)scene;
                            break;
                        }
                    }
                    windows = windowScene.windows;
                } else {
                    windows = UIApplication.sharedApplication.windows;
                }
                
                UIWindow *mainWindow = nil;
                for (UIWindow *window in windows) {
                    if (window.isKeyWindow) {
                        mainWindow = window;
                        break;
                    }
                }
                
                if (mainWindow) {
                    currentVC = mainWindow.rootViewController;
                    if ([currentVC isKindOfClass:[UISplitViewController class]]) {
                        splitVC = (UISplitViewController *)currentVC;
                    }
                }
                
                // Get the navigation controller for progress updates
                LauncherNavigationController *navVC = nil;
                if (splitVC && splitVC.viewControllers.count > 1) {
                    navVC = (LauncherNavigationController *)splitVC.viewControllers[1];
                    [navVC setInteractionEnabled:NO forDownloading:YES];
                    navVC.progressText.text = [NSString stringWithFormat:@"Downloading %@ installer...", vendor];
                    navVC.progressViewMain.hidden = NO;
                }
                
                // Create download request with proper User-Agent header
                NSMutableURLRequest *request = [NSMutableURLRequest requestWithURL:[NSURL URLWithString:installerUrl]];
                [request setValue:self.userAgent forHTTPHeaderField:@"User-Agent"];
                
                NSURLSessionDownloadTask *downloadTask = [manager downloadTaskWithRequest:request progress:^(NSProgress * _Nonnull progress) {
                    dispatch_async(dispatch_get_main_queue(), ^{
                        if (navVC) {
                            navVC.progressViewMain.progress = progress.fractionCompleted;
                        }
                    });
                } destination:^NSURL *(NSURL *targetPath, NSURLResponse *response) {
                    [NSFileManager.defaultManager removeItemAtPath:outPath error:nil];
                    return [NSURL fileURLWithPath:outPath];
                } completionHandler:^(NSURLResponse *response, NSURL *filePath, NSError *error) {
                    dispatch_async(dispatch_get_main_queue(), ^{
                        if (error) {
                            if (navVC) {
                                [navVC setInteractionEnabled:YES forDownloading:NO];
                            }
                            showDialog(@"Error", [NSString stringWithFormat:@"Failed to download %@ installer: %@", vendor, error.localizedDescription]);
                            return;
                        }
                        
                        // Reset UI 
                        if (navVC) {
                            [navVC setInteractionEnabled:YES forDownloading:NO];
                            navVC.progressViewMain.hidden = YES;
                            navVC.progressText.text = nil;
                            
                            // CRITICAL CHANGE: Don't show another alert before launching
                            // Remove the showDialog and delay that was causing problems
                            NSLog(@"[ModrinthAPI] %@ installer download complete, launching...", vendor);
                            
                            // Launch the installer directly
                            [navVC enterModInstallerWithPath:outPath hitEnterAfterWindowShown:YES];
                        } else {
                            // Fallback if we couldn't get the navigation controller
                            showDialog(@"Error", @"Could not locate navigation controller for installer launch");
                        }
                    });
                }];
                
                [downloadTask resume];
            }]];
            
        [alert addAction:[UIAlertAction 
            actionWithTitle:@"No" 
            style:UIAlertActionStyleCancel 
            handler:nil]];
        
        // Present the alert on the main thread using the appropriate view controller
        UIViewController *currentVC = nil;
        
        // Find the root view controller - proper way to get the current UI
        NSArray<UIWindow *> *windows = nil;
        if (@available(iOS 13.0, *)) {
            UIWindowScene *windowScene = nil;
            for (UIScene *scene in UIApplication.sharedApplication.connectedScenes) {
                if ([scene isKindOfClass:[UIWindowScene class]] && 
                    ((UIWindowScene *)scene).activationState == UISceneActivationStateForegroundActive) {
                    windowScene = (UIWindowScene *)scene;
                    break;
                }
            }
            windows = windowScene.windows;
        } else {
            windows = UIApplication.sharedApplication.windows;
        }
        
        UIWindow *mainWindow = nil;
        for (UIWindow *window in windows) {
            if (window.isKeyWindow) {
                mainWindow = window;
                break;
            }
        }
        
        if (mainWindow) {
            currentVC = mainWindow.rootViewController;
            // Find the topmost presented view controller
            while (currentVC.presentedViewController) {
                currentVC = currentVC.presentedViewController;
            }
            [currentVC presentViewController:alert animated:YES completion:nil];
        }
    });
}

- (void)installModpackFromDetail:(NSDictionary *)modDetail atIndex:(NSUInteger)selectedVersion {
    // Pass details to LauncherNavigationController
    NSDictionary* userInfo = @{
        @"detail": modDetail,
        @"index": @(selectedVersion)
    };
    [NSNotificationCenter.defaultCenter 
        postNotificationName:@"InstallModpack" 
        object:self userInfo:userInfo];
}

@end

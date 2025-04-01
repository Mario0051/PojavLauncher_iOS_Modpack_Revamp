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
        
        // Initialize user agent with a default value to avoid nil crashes
        self.userAgent = @"PojavLauncher-iOS";
        
        // Use a descriptive user agent
        configuration.HTTPAdditionalHeaders = @{
            @"User-Agent": self.userAgent,
            @"Accept": @"application/json"
        };
        
        // Initialize URL session with configuration
        self.session = [NSURLSession sessionWithConfiguration:configuration];
        
        // Initialize other properties
        self.reachedLastPage = NO;
        
        // Initialize download tracking objects
        self.downloadCountLock = [[NSLock alloc] init];
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
    
    // Create URL with basic endpoint
    NSString *urlStr = @"https://api.modrinth.com/v2/search";
    
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
    
    // Create session and manager for the request
    NSURLSessionConfiguration *configuration = [NSURLSessionConfiguration defaultSessionConfiguration];
    AFURLSessionManager *manager = [[AFURLSessionManager alloc] initWithSessionConfiguration:configuration];
    
    // Create request serializer
    AFJSONRequestSerializer *requestSerializer = [AFJSONRequestSerializer serializer];
    
    // Create the request with parameters
    NSError *serializationError;
    NSMutableURLRequest *request = [requestSerializer requestWithMethod:@"GET" 
                                                             URLString:urlStr 
                                                            parameters:parameters 
                                                                 error:&serializationError];
    
    if (serializationError) {
        NSLog(@"[ModrinthAPI] Error creating request: %@", serializationError);
        self.lastError = serializationError;
        return previousPageResult ?: [NSMutableArray array];
    }
    
    // Perform synchronous request
    dispatch_semaphore_t semaphore = dispatch_semaphore_create(0);
    __block id responseObject = nil;
    __block NSError *requestError = nil;
    
    NSURLSessionDataTask *dataTask = [manager dataTaskWithRequest:request uploadProgress:nil downloadProgress:nil completionHandler:^(NSURLResponse *response, id responseData, NSError *dataError) {
        responseObject = responseData;
        requestError = dataError;
        dispatch_semaphore_signal(semaphore);
    }];
    
    [dataTask resume];
    
    dispatch_semaphore_wait(semaphore, dispatch_time(DISPATCH_TIME_NOW, 30 * NSEC_PER_SEC));
    
    // Handle request errors
    if (requestError) {
        NSLog(@"[ModrinthAPI] Network error: %@", requestError);
        self.lastError = requestError;
        return previousPageResult ?: [NSMutableArray array];
    }
    
    // Parse response
    NSDictionary *jsonResponse = responseObject;
    
    // Safety check for JSON response
    if (!jsonResponse || ![jsonResponse isKindOfClass:[NSDictionary class]]) {
        NSLog(@"[ModrinthAPI] Invalid JSON response");
        return previousPageResult ?: [NSMutableArray array];
    }
    
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
    
    // Create headers with proper User-Agent - with nil check
    NSDictionary *headers;
    if (self.userAgent) {
        headers = @{@"User-Agent": self.userAgent};
    } else {
        // Fallback to default user agent if property is nil
        headers = @{@"User-Agent": @"PojavLauncher-iOS"};
    }
    
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
        
        // Get complete categories list - safely with nil checks
        if (projectDetails[@"categories"] && [projectDetails[@"categories"] isKindOfClass:[NSArray class]]) {
            item[@"categories"] = projectDetails[@"categories"];
        }
        
        // Get additional tags if available - safely with nil checks
        if (projectDetails[@"additional_categories"] && [projectDetails[@"additional_categories"] isKindOfClass:[NSArray class]]) {
            // Create a mutable array to hold combined categories
            NSMutableArray *allCategories = [NSMutableArray array];
            
            // Add existing categories if they exist (with type check)
            if (item[@"categories"] && [item[@"categories"] isKindOfClass:[NSArray class]]) {
                [allCategories addObjectsFromArray:item[@"categories"]];
            }
            
            // Add additional categories
            [allCategories addObjectsFromArray:projectDetails[@"additional_categories"]];
            
            // Update item with combined categories
            if (allCategories.count > 0) {
                item[@"categories"] = allCategories;
            }
        }
        
        // Get client/server side info - with nil checks
        if (projectDetails[@"client_side"] && [projectDetails[@"client_side"] isKindOfClass:[NSString class]]) {
            item[@"client_side"] = projectDetails[@"client_side"];
        }
        
        if (projectDetails[@"server_side"] && [projectDetails[@"server_side"] isKindOfClass:[NSString class]]) {
            item[@"server_side"] = projectDetails[@"server_side"];
        }
        
        // Get license info - with nil check
        if (projectDetails[@"license"] && [projectDetails[@"license"] isKindOfClass:[NSDictionary class]]) {
            item[@"license"] = projectDetails[@"license"];
        } else if (projectDetails[@"license"] && [projectDetails[@"license"] isKindOfClass:[NSString class]]) {
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
            [version[@"game_versions"] count] > 0) {
            // Make sure we have a string at index 0
            id firstVersion = version[@"game_versions"][0];
            if ([firstVersion isKindOfClass:[NSString class]]) {
                mcNames[i] = firstVersion;
            }
        }
        
        // Get file information - prefer primary file if available
        if (version[@"files"] && [version[@"files"] isKindOfClass:[NSArray class]] && 
            [version[@"files"] count] > 0) {
            
            // Find the primary file first if possible
            NSDictionary *primaryFile = nil;
            for (id fileObj in version[@"files"]) {
                if ([fileObj isKindOfClass:[NSDictionary class]]) {
                    NSDictionary *file = (NSDictionary *)fileObj;
                    if (file[@"primary"] && [file[@"primary"] boolValue]) {
                        primaryFile = file;
                        break;
                    }
                }
            }
            
            // If no primary file, use the first file (with type checking)
            id firstFileObj = version[@"files"][0];
            NSDictionary *file = nil;
            
            if (primaryFile) {
                file = primaryFile;
            } else if ([firstFileObj isKindOfClass:[NSDictionary class]]) {
                file = (NSDictionary *)firstFileObj;
            }
            
            if (file) {
                // Get file size (with type checking)
                if (file[@"size"] && [file[@"size"] isKindOfClass:[NSNumber class]]) {
                    sizes[i] = file[@"size"];
                }
                
                // Get download URL (with type checking)
                if (file[@"url"] && [file[@"url"] isKindOfClass:[NSString class]]) {
                    NSString *fileUrl = [file[@"url"] stringByReplacingOccurrencesOfString:@"\\/" withString:@"/"];
                    urls[i] = fileUrl;
                }
                
                // Get hash (with nested type checking)
                if (file[@"hashes"] && [file[@"hashes"] isKindOfClass:[NSDictionary class]]) {
                    id sha1Hash = file[@"hashes"][@"sha1"];
                    if (sha1Hash && [sha1Hash isKindOfClass:[NSString class]]) {
                        hashes[i] = sha1Hash;
                    }
                }
            }
        }
    }];
    
    // Update the item with version information - all arrays should have valid values now
    if (names.count > 0) item[@"versionNames"] = names;
    if (mcNames.count > 0) item[@"mcVersionNames"] = mcNames;
    if (sizes.count > 0) item[@"versionSizes"] = sizes;
    if (urls.count > 0) item[@"versionUrls"] = urls;
    if (hashes.count > 0) item[@"versionHashes"] = hashes;
    
    // Set loaded flag only after successfully processing
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
    
    // Add API base URL if not already included
    if (![urlString hasPrefix:@"http"]) {
        // Default to Modrinth API base URL
        [urlString insertString:@"https://api.modrinth.com/v2/" atIndex:0];
    }
    
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
    
    // Set headers with nil safety
    if (headers) {
        for (NSString *key in headers) {
            if (headers[key]) { // Ensure we're not adding nil values
                [request setValue:headers[key] forHTTPHeaderField:key];
            }
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
    NSDictionary *headers = @{@"User-Agent": self.userAgent ?: @"PojavLauncher-iOS"};
    return [self getEndpoint:endpoint params:params headers:headers];
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
    
    // Now we can directly mark the download phase as complete using the public method
    [downloader markDownloadPhaseComplete:YES];
    
    // Log completion
    NSLog(@"[ModrinthAPI] Modpack installation complete: %@", profileName);
    
    // Check for Forge immediately
    [self checkAndInstallForge:downloader 
             withDependencies:indexDict[@"dependencies"] 
                  profileName:profileName];
    
    // Post notification that modpack installation is complete
    // CRITICAL CHANGE: Moved after checkAndInstallForge call
    dispatch_async(dispatch_get_main_queue(), ^{
        NSDictionary *userInfo = @{
            @"profileName": profileName,
            @"gameDir": gameDir
        };
        
        [[NSNotificationCenter defaultCenter] postNotificationName:@"ModpackInstallationComplete" 
                                                            object:self 
                                                          userInfo:userInfo];
    });
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
    
    // Now we can directly mark the download phase as complete using the public method
    [downloader markDownloadPhaseComplete:YES];
    
    // Log completion
    NSLog(@"[ModrinthAPI] Modpack installation complete: %@", profileName);
    
    // Check for Forge immediately
    [self checkAndInstallForge:downloader 
             withDependencies:indexDict[@"dependencies"] 
                  profileName:profileName];
    
    // Post notification that modpack installation is complete
    // CRITICAL CHANGE: Moved after checkAndInstallForge call
    dispatch_async(dispatch_get_main_queue(), ^{
        NSDictionary *userInfo = @{
            @"profileName": profileName,
            @"gameDir": gameDir
        };
        
        [[NSNotificationCenter defaultCenter] postNotificationName:@"ModpackInstallationComplete" 
                                                            object:self 
                                                          userInfo:userInfo];
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

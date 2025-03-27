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
    // Check if the URL is nil or empty
    if (!imageUrl || imageUrl.length == 0) {
        return imageUrl;
    }

    // Handle WebP format by requesting PNG instead
    if ([imageUrl.lowercaseString hasSuffix:@".webp"]) {
        // 1. For Modrinth CDN: Add format=png parameter if not already present
        if ([imageUrl containsString:@"cdn.modrinth.com"]) {
            NSURLComponents *components = [NSURLComponents componentsWithString:imageUrl];
            NSMutableArray *queryItems = [components.queryItems mutableCopy] ?: [NSMutableArray array];

            // Check if format parameter already exists
            BOOL formatExists = NO;
            for (NSURLQueryItem *item in queryItems) {
                if ([item.name isEqualToString:@"format"]) {
                    formatExists = YES;
                    break;
                }
            }

            // Add format=png if it doesn't exist
            if (!formatExists) {
                [queryItems addObject:[NSURLQueryItem queryItemWithName:@"format" value:@"png"]];
                components.queryItems = queryItems;
                return components.URL.absoluteString;
            } else {
                // If format parameter exists, return original URL
                return imageUrl;
            }
        }

        // 2. For other services: Try changing extension
        return [imageUrl stringByReplacingOccurrencesOfString:@".webp"
                                                   withString:@".png"
                                                      options:NSCaseInsensitiveSearch
                                                        range:NSMakeRange(0, imageUrl.length)];
    }

    // If not WebP, return the original URL
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
        self.userAgent = @"PojavLauncher-iOS"; // Ensure user agent is set
        self.downloadCountLock = [[NSLock alloc] init];
        self.fileProcessingQueue = dispatch_queue_create("net.kdt.pojavlauncher.modrinth.filequeue", DISPATCH_QUEUE_SERIAL);
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
        parameters[@"index"] = @"relevance"; // Default sort
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
    AFHTTPRequestSerializer *requestSerializer = [AFHTTPRequestSerializer serializer];

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

    // Set User-Agent header
    [request setValue:self.userAgent forHTTPHeaderField:@"User-Agent"];

    // Perform synchronous request using a semaphore
    dispatch_semaphore_t semaphore = dispatch_semaphore_create(0);
    __block id responseObject = nil;
    __block NSError *requestError = nil;

    NSURLSessionDataTask *dataTask = [manager dataTaskWithRequest:request uploadProgress:nil downloadProgress:nil completionHandler:^(NSURLResponse *response, id responseData, NSError *dataError) {
        responseObject = responseData;
        requestError = dataError;
        dispatch_semaphore_signal(semaphore);
    }];

    [dataTask resume];

    // Wait for the request to complete, with a timeout
    dispatch_time_t timeout = dispatch_time(DISPATCH_TIME_NOW, 30 * NSEC_PER_SEC);
    if (dispatch_semaphore_wait(semaphore, timeout) != 0) {
        [dataTask cancel];
        NSLog(@"[ModrinthAPI] Network request timed out.");
        self.lastError = [NSError errorWithDomain:NSURLErrorDomain code:NSURLErrorTimedOut userInfo:@{NSLocalizedDescriptionKey: @"Search request timed out"}];
        return previousPageResult ?: [NSMutableArray array];
    }

    // Handle request errors
    if (requestError) {
        NSLog(@"[ModrinthAPI] Network error: %@", requestError);
        self.lastError = requestError;
        return previousPageResult ?: [NSMutableArray array];
    }

    // Parse response - ensure it's NSData before parsing
    if (![responseObject isKindOfClass:[NSData class]]) {
        NSLog(@"[ModrinthAPI] Unexpected response type: %@", [responseObject class]);
        self.lastError = [NSError errorWithDomain:@"ModrinthAPIError" code:101 userInfo:@{NSLocalizedDescriptionKey: @"Unexpected response format"}];
        return previousPageResult ?: [NSMutableArray array];
    }
    
    NSError *jsonError = nil;
    NSDictionary *jsonResponse = [NSJSONSerialization JSONObjectWithData:responseObject options:0 error:&jsonError];
    
    if (jsonError) {
        NSLog(@"[ModrinthAPI] JSON parsing error: %@", jsonError);
        self.lastError = jsonError;
        return previousPageResult ?: [NSMutableArray array];
    }


    // Safety check for JSON response
    if (!jsonResponse || ![jsonResponse isKindOfClass:[NSDictionary class]]) {
        NSLog(@"[ModrinthAPI] Invalid JSON response structure");
        self.lastError = [NSError errorWithDomain:@"ModrinthAPIError" code:102 userInfo:@{NSLocalizedDescriptionKey: @"Invalid JSON response structure"}];
        return previousPageResult ?: [NSMutableArray array];
    }

    NSArray *hits = jsonResponse[@"hits"];

    // If no results or invalid format, return
    if (!hits || ![hits isKindOfClass:[NSArray class]]) {
        NSLog(@"[ModrinthAPI] No hits in response or invalid format");
        // If offset is 0 and no hits, assume reached end
        if (offset == 0) {
            self.reachedLastPage = YES;
        }
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

        // Copy standard fields with nil checks and type validation
        id title = modData[@"title"];
        if (title && [title isKindOfClass:[NSString class]]) modpack[@"title"] = title;

        id slug = modData[@"slug"];
        if (slug && [slug isKindOfClass:[NSString class]]) modpack[@"slug"] = slug;
        
        id description = modData[@"description"];
        if (description && [description isKindOfClass:[NSString class]]) modpack[@"description"] = description;

        id projectId = modData[@"project_id"];
        if (projectId && [projectId isKindOfClass:[NSString class]]) modpack[@"id"] = projectId;

        id categories = modData[@"categories"];
        if (categories && [categories isKindOfClass:[NSArray class]]) modpack[@"categories"] = categories;

        id downloads = modData[@"downloads"];
        if (downloads && [downloads isKindOfClass:[NSNumber class]]) modpack[@"downloads"] = downloads;

        // Handle icon URL
        id iconUrl = modData[@"icon_url"];
        if (iconUrl && [iconUrl isKindOfClass:[NSString class]] && ((NSString *)iconUrl).length > 0) {
            // Convert WebP URL if necessary
            NSString *convertedUrl = [self convertWebPUrl:(NSString *)iconUrl];
            modpack[@"imageUrl"] = convertedUrl;
            NSLog(@"[ModrinthAPI] Project %@ has icon URL: %@", modpack[@"id"], convertedUrl);
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
        item[@"versionDetailsLoaded"] = @(NO); // Mark as failed
        return;
    }

    // Check for project ID
    NSString *projectId = item[@"id"];
    if (!projectId || ![projectId isKindOfClass:[NSString class]] || projectId.length == 0) {
        NSLog(@"[ModrinthAPI] Warning: item has no valid ID");
        item[@"versionDetailsLoaded"] = @(NO); // Mark as failed
        return;
    }

    // Create headers with proper User-Agent
    NSDictionary *headers = @{@"User-Agent": self.userAgent};

    // First, load full project details to get complete category info and other metadata
    NSString *projectEndpoint = [NSString stringWithFormat:@"project/%@", projectId];
    NSDictionary *projectDetails = [self getEndpoint:projectEndpoint params:nil headers:headers];

    // Extract additional metadata if available
    if (projectDetails && [projectDetails isKindOfClass:[NSDictionary class]]) {
        // Check for updated icon URL and update if available
        id iconUrlObj = projectDetails[@"icon_url"];
        if (iconUrlObj && ![iconUrlObj isKindOfClass:[NSNull class]] && [iconUrlObj isKindOfClass:[NSString class]]) {
            NSString *newIconUrl = (NSString *)iconUrlObj;
            newIconUrl = [newIconUrl stringByReplacingOccurrencesOfString:@"\\/" withString:@"/"];

            // Convert WebP URLs
            newIconUrl = [self convertWebPUrl:newIconUrl];

            // Only update if we have a valid, non-empty URL
            if (newIconUrl.length > 0) {
                item[@"imageUrl"] = newIconUrl; // Safe: newIconUrl is non-nil string
                NSLog(@"[ModrinthAPI] Updated icon URL for project %@: %@", projectId, newIconUrl);
            }
        }

        // Get complete categories list
        id categoriesObj = projectDetails[@"categories"];
        if (categoriesObj && ![categoriesObj isKindOfClass:[NSNull class]] && [categoriesObj isKindOfClass:[NSArray class]]) {
            item[@"categories"] = categoriesObj; // Safe: categoriesObj is non-nil NSArray
        } else {
            // Ensure categories key exists even if empty
            if (!item[@"categories"]) {
                 item[@"categories"] = @[];
            }
        }

        // Get additional tags if available
        id additionalCategoriesObj = projectDetails[@"additional_categories"];
        if (additionalCategoriesObj && ![additionalCategoriesObj isKindOfClass:[NSNull class]] && [additionalCategoriesObj isKindOfClass:[NSArray class]]) {
            NSMutableArray *allCategories = [NSMutableArray arrayWithArray:item[@"categories"] ?: @[]];
            [allCategories addObjectsFromArray:(NSArray *)additionalCategoriesObj];
            // Remove duplicates while preserving order
            NSOrderedSet *orderedSet = [NSOrderedSet orderedSetWithArray:allCategories];
            item[@"categories"] = [orderedSet array]; // Safe: allCategories is non-nil NSMutableArray
        }

        // Get client/server side info
        id clientSideObj = projectDetails[@"client_side"];
        if (clientSideObj && ![clientSideObj isKindOfClass:[NSNull class]]) {
            item[@"client_side"] = clientSideObj; // Safe: clientSideObj is not nil/NSNull
        }
        id serverSideObj = projectDetails[@"server_side"];
        if (serverSideObj && ![serverSideObj isKindOfClass:[NSNull class]]) {
            item[@"server_side"] = serverSideObj; // Safe: serverSideObj is not nil/NSNull
        }

        // Get license info
        id licenseObj = projectDetails[@"license"];
        if (licenseObj && ![licenseObj isKindOfClass:[NSNull class]]) {
            item[@"license"] = licenseObj; // Safe: licenseObj is not nil/NSNull
        }
    } else if (projectDetails == nil && self.lastError) {
        // If fetching project details failed, log the error and mark as failed
        NSLog(@"[ModrinthAPI] Failed to load project details for %@: %@", projectId, self.lastError.localizedDescription);
        item[@"versionDetailsLoaded"] = @(NO);
        return; // Stop further processing if project details failed
    } else {
        NSLog(@"[ModrinthAPI] Warning: projectDetails response was nil or not a dictionary for project ID %@", projectId);
        // Continue to try loading versions, but categories might be incomplete.
    }

    // Now load version data
    NSString *endpoint = [NSString stringWithFormat:@"project/%@/version", projectId];
    NSArray *response = [self getEndpoint:endpoint params:nil headers:headers];

    // Check response validity
    if (!response || ![response isKindOfClass:[NSArray class]]) {
        NSLog(@"[ModrinthAPI] Warning: no version data or invalid format for project ID %@. Error: %@", projectId, self.lastError ? self.lastError.localizedDescription : @"Unknown error");
        item[@"versionDetailsLoaded"] = @(NO); // Mark as failed if versions couldn't be loaded
        return;
    }
    
    if (response.count == 0) {
        NSLog(@"[ModrinthAPI] Warning: project ID %@ has 0 versions available.", projectId);
        // Still mark as loaded, but arrays will be empty
        item[@"versionNames"] = @[];
        item[@"mcVersionNames"] = @[];
        item[@"versionSizes"] = @[];
        item[@"versionUrls"] = @[];
        item[@"versionHashes"] = @[];
        item[@"versionDetailsLoaded"] = @(YES);
        return;
    }

    // Extract version data
    NSMutableArray<NSString *> *names = [NSMutableArray arrayWithCapacity:response.count];
    NSMutableArray<NSString *> *mcNames = [NSMutableArray arrayWithCapacity:response.count];
    NSMutableArray<NSString *> *urls = [NSMutableArray arrayWithCapacity:response.count];
    NSMutableArray<NSString *> *hashes = [NSMutableArray arrayWithCapacity:response.count];
    NSMutableArray<NSNumber *> *sizes = [NSMutableArray arrayWithCapacity:response.count];

    // Safely process each version
    for (id versionObj in response) {
        if (![versionObj isKindOfClass:[NSDictionary class]]) {
            // Skip invalid entries, but add placeholders to keep arrays aligned
            [names addObject:@"Invalid Version Data"];
            [mcNames addObject:@"Unknown"];
            [urls addObject:@""];
            [hashes addObject:@""];
            [sizes addObject:@(0)];
            continue;
        }
        NSDictionary *version = (NSDictionary *)versionObj;

        // Get version name
        NSString *versionName = @"Unknown Version";
        id nameObj = version[@"name"];
        if (nameObj && [nameObj isKindOfClass:[NSString class]]) {
            versionName = (NSString *)nameObj;
        }
        [names addObject:versionName];

        // Get Minecraft version (take the first one)
        NSString *mcVersion = @"Unknown";
        id gameVersionsObj = version[@"game_versions"];
        if (gameVersionsObj && [gameVersionsObj isKindOfClass:[NSArray class]]) {
            NSArray *gameVersions = (NSArray *)gameVersionsObj;
            if (gameVersions.count > 0 && [gameVersions[0] isKindOfClass:[NSString class]]) {
                mcVersion = gameVersions[0];
            }
        }
        [mcNames addObject:mcVersion];

        // Get file information - prefer primary file if available
        NSString *fileUrl = @"";
        NSString *fileHash = @"";
        NSNumber *fileSize = @(0);
        id filesObj = version[@"files"];
        if (filesObj && [filesObj isKindOfClass:[NSArray class]]) {
            NSArray *files = (NSArray *)filesObj;
            NSDictionary *primaryFile = nil;
            for (id fileObj in files) {
                if ([fileObj isKindOfClass:[NSDictionary class]]) {
                    NSDictionary *file = (NSDictionary *)fileObj;
                    id primaryFlag = file[@"primary"];
                    if (primaryFlag && [primaryFlag isKindOfClass:[NSNumber class]] && [primaryFlag boolValue]) {
                        primaryFile = file;
                        break;
                    }
                }
            }
            
            // If no primary file, use the first valid file
            NSDictionary *fileToUse = primaryFile;
            if (!fileToUse && files.count > 0) {
                 for (id fileObj in files) {
                     if ([fileObj isKindOfClass:[NSDictionary class]]) {
                         fileToUse = (NSDictionary*)fileObj;
                         break;
                     }
                 }
            }

            if (fileToUse) {
                // Get file size
                id sizeObj = fileToUse[@"size"];
                if (sizeObj && [sizeObj isKindOfClass:[NSNumber class]]) {
                    fileSize = (NSNumber *)sizeObj;
                }

                // Get download URL
                id urlObj = fileToUse[@"url"];
                if (urlObj && [urlObj isKindOfClass:[NSString class]]) {
                    fileUrl = [(NSString *)urlObj stringByReplacingOccurrencesOfString:@"\\/" withString:@"/"];
                }

                // Get hash (SHA1)
                id hashesObj = fileToUse[@"hashes"];
                if (hashesObj && [hashesObj isKindOfClass:[NSDictionary class]]) {
                    id sha1Obj = ((NSDictionary *)hashesObj)[@"sha1"];
                    if (sha1Obj && [sha1Obj isKindOfClass:[NSString class]]) {
                        fileHash = (NSString *)sha1Obj;
                    }
                }
            }
        }
        [urls addObject:fileUrl];
        [hashes addObject:fileHash];
        [sizes addObject:fileSize];
    }

    // Update the item with version information
    item[@"versionNames"] = names; // Safe: names is non-nil
    item[@"mcVersionNames"] = mcNames; // Safe: mcNames is non-nil
    item[@"versionSizes"] = sizes; // Safe: sizes is non-nil
    item[@"versionUrls"] = urls; // Safe: urls is non-nil
    item[@"versionHashes"] = hashes; // Safe: hashes is non-nil
    item[@"versionDetailsLoaded"] = @(YES); // Mark as successfully loaded
}

- (id)getEndpoint:(NSString *)endpoint params:(NSDictionary *)params headers:(NSDictionary *)headers {
    // Create a cancel semaphore to handle timeouts
    dispatch_semaphore_t cancelSemaphore = dispatch_semaphore_create(0);

    // Initialize data holder
    __block NSData *responseData = nil;
    __block NSError *responseError = nil;
    __block NSURLResponse *urlResponse = nil;

    // Create base URL
    NSURLComponents *components = [NSURLComponents componentsWithString:@"https://api.modrinth.com/v2/"];
    components.path = [components.path stringByAppendingPathComponent:endpoint];

    // Add query parameters if provided
    if (params && params.count > 0) {
        NSMutableArray *queryItems = [NSMutableArray array];
        for (NSString *key in params) {
            NSString *value = [params[key] description]; // Ensure value is a string
            [queryItems addObject:[NSURLQueryItem queryItemWithName:key value:value]];
        }
        components.queryItems = queryItems;
    }

    // Create URL request
    NSURL *url = components.URL;
    if (!url) {
        NSLog(@"[ModrinthAPI] Failed to create URL for endpoint: %@", endpoint);
        self.lastError = [NSError errorWithDomain:@"ModrinthAPIError" code:100 userInfo:@{NSLocalizedDescriptionKey: @"Invalid URL"}];
        return nil;
    }
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
        [request setValue:self.userAgent forHTTPHeaderField:@"User-Agent"];
    }

    // Set reasonable timeout
    [request setTimeoutInterval:30.0];

    // Create URLSession task
    NSURLSessionDataTask *task = [self.session dataTaskWithRequest:request completionHandler:^(NSData *data, NSURLResponse *response, NSError *error) {
        responseError = error;
        responseData = data;
        urlResponse = response; // Store the response
        // Signal completion
        dispatch_semaphore_signal(cancelSemaphore);
    }];

    // Start the task
    [task resume];

    // Wait for completion using the semaphore with a timeout
    long result = dispatch_semaphore_wait(cancelSemaphore, dispatch_time(DISPATCH_TIME_NOW, 30 * NSEC_PER_SEC));

    // Handle timeout
    if (result != 0) {
        [task cancel]; // Cancel the task if it timed out
        self.lastError = [NSError errorWithDomain:NSURLErrorDomain
                                             code:NSURLErrorTimedOut
                                         userInfo:@{NSLocalizedDescriptionKey: @"Request timed out"}];
        NSLog(@"[ModrinthAPI] Request timed out for endpoint: %@", endpoint);
        return nil;
    }

    // Handle network error
    if (responseError) {
        self.lastError = responseError;
        NSLog(@"[ModrinthAPI] Network error for endpoint %@: %@", endpoint, responseError.localizedDescription);
        return nil;
    }
    
    // Check HTTP status code
    if ([urlResponse isKindOfClass:[NSHTTPURLResponse class]]) {
        NSInteger statusCode = ((NSHTTPURLResponse *)urlResponse).statusCode;
        if (statusCode < 200 || statusCode >= 300) {
            NSString *errorDesc = [NSString stringWithFormat:@"HTTP Error %ld for endpoint %@", (long)statusCode, endpoint];
            if (responseData) {
                NSString *responseString = [[NSString alloc] initWithData:responseData encoding:NSUTF8StringEncoding];
                if (responseString) {
                     errorDesc = [errorDesc stringByAppendingFormat:@": %@", responseString];
                }
            }
            self.lastError = [NSError errorWithDomain:@"ModrinthAPIHTTPError" code:statusCode userInfo:@{NSLocalizedDescriptionKey: errorDesc}];
            NSLog(@"[ModrinthAPI] %@", errorDesc);
            return nil; // Return nil on HTTP error
        }
    }

    // If no data was received
    if (!responseData) {
        NSLog(@"[ModrinthAPI] No data received for endpoint: %@", endpoint);
        self.lastError = [NSError errorWithDomain:@"ModrinthAPIError" code:103 userInfo:@{NSLocalizedDescriptionKey: @"No data received"}];
        return nil;
    }

    // Try to parse the response as JSON
    NSError *jsonError = nil;
    id jsonObject = [NSJSONSerialization JSONObjectWithData:responseData options:kNilOptions error:&jsonError];

    if (jsonError) {
        // If JSON parsing fails, return nil and store the error
        self.lastError = jsonError;
        NSLog(@"[ModrinthAPI] JSON Parsing Error for endpoint %@: %@", endpoint, jsonError.localizedDescription);
        // Optionally log the raw response string for debugging
        // NSString *responseStr = [[NSString alloc] initWithData:responseData encoding:NSUTF8StringEncoding];
        // NSLog(@"[ModrinthAPI] Raw response: %@", responseStr);
        return nil; // Return nil if JSON parsing fails
    }

    // Return the parsed JSON object
    self.lastError = nil; // Clear last error on success
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

    // Reset progress for the new phase
    downloader.progress.totalUnitCount = 1; // Placeholder, will be updated
    downloader.progress.completedUnitCount = 0;
    if (downloader.textProgress) {
        downloader.textProgress.totalUnitCount = 1; // Placeholder
        downloader.textProgress.completedUnitCount = 0;
    }

    // Add a status entry for reading the index
    [downloader.fileList addObject:@"Reading modpack index..."];
    NSProgress *indexProgress = [NSProgress progressWithTotalUnitCount:1];
    [downloader.progressList addObject:indexProgress];
    // Do not add index progress to overall progress yet

    // Try to extract the index file - first try the newer format, then fall back to the older one
    NSData *indexData = [archive extractDataFromFile:@"modrinth.index.json" error:nil]; // Correct order: modrinth first
    if (!indexData) {
        indexData = [archive extractDataFromFile:@"index.json" error:&error]; // Fallback to generic index
    }

    if (!indexData || error) {
        NSString *errorMessage = error ? error.localizedDescription : @"index file not found";
        [downloader finishDownloadWithErrorString:[NSString stringWithFormat:@"Failed to read modpack index: %@", errorMessage]];
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
    if (!files || ![files isKindOfClass:[NSArray class]]) {
        [downloader finishDownloadWithErrorString:@"Modpack index 'files' array is missing or invalid"];
        return;
    }
    
    if (files.count == 0) {
        // No files to download, proceed directly to extraction
        NSLog(@"[ModrinthAPI] No mod files found in index, proceeding to extraction.");
        [self extractAndFinalizeModpack:downloader archive:archive indexDict:indexDict destPath:destPath packagePath:packagePath];
        return;
    }

    // Set up tracking for retries
    downloader.metadata[@"retryMap"] = [NSMutableDictionary dictionary];

    // Store the modpack dependencies for later use in Forge/NeoForge installation
    if (indexDict[@"dependencies"] && [indexDict[@"dependencies"] isKindOfClass:[NSDictionary class]]) {
         downloader.metadata[@"modpackDependencies"] = indexDict[@"dependencies"];
    } else {
         downloader.metadata[@"modpackDependencies"] = @{}; // Ensure it exists
    }


    // Calculate total size for better progress tracking
    unsigned long long totalSize = 0;
    NSUInteger validFileCount = 0;
    for (id fileEntry in files) {
        if ([fileEntry isKindOfClass:[NSDictionary class]]) {
            NSDictionary *indexFile = (NSDictionary *)fileEntry;
            id fileSize = indexFile[@"fileSize"];
            if (fileSize && [fileSize isKindOfClass:[NSNumber class]]) {
                totalSize += [fileSize unsignedLongLongValue];
                validFileCount++;
            }
        }
    }

    // Reset the progress tracking with actual file count and size
    // Use total size if available, otherwise fall back to file count
    BOOL useSizeForProgress = totalSize > 0;
    downloader.progress.totalUnitCount = useSizeForProgress ? totalSize : validFileCount;
    downloader.progress.completedUnitCount = 0;

    if (downloader.textProgress) {
        downloader.textProgress.totalUnitCount = validFileCount; // Text progress tracks file count
        downloader.textProgress.completedUnitCount = 0;
    }

    // Initialize the pending downloads counter
    [self.downloadCountLock lock];
    self.pendingModpackDownloads = validFileCount;
    [self.downloadCountLock unlock];

    NSLog(@"[ModrinthAPI] Starting download of %lu mod files (Total size: %llu bytes)", (unsigned long)validFileCount, totalSize);

    // Add overall status to file list
    [downloader.fileList addObject:[NSString stringWithFormat:@"Downloading %lu files...", (unsigned long)validFileCount]];
    NSProgress *overallProgress = [NSProgress progressWithTotalUnitCount:validFileCount];
    overallProgress.completedUnitCount = 0;
    [downloader.progressList addObject:overallProgress];
    // Add overall download progress as a child of the main progress
    [downloader.progress addChild:overallProgress withPendingUnitCount:useSizeForProgress ? totalSize : validFileCount];


    // Create a dispatch group for tracking completion
    dispatch_group_t downloadGroup = dispatch_group_create();

    // Process files using the downloader's queue
    for (id fileEntry in files) {
        // Check for cancellation before processing each file
        if (downloader.progress.cancelled) {
             NSLog(@"[ModrinthAPI] Download cancelled during file processing setup.");
             break;
        }
        
        if (![fileEntry isKindOfClass:[NSDictionary class]]) {
            NSLog(@"[ModrinthAPI] Skipping invalid file entry in index");
            continue; // Skip invalid entries
        }
        NSDictionary *indexFile = (NSDictionary *)fileEntry;

        NSArray *downloadURLs = indexFile[@"downloads"];
        if (!downloadURLs || ![downloadURLs isKindOfClass:[NSArray class]] || downloadURLs.count == 0) {
            NSLog(@"[ModrinthAPI] File has no download URLs: %@", indexFile[@"path"]);
            // Decrement pending count for skipped file
            [self.downloadCountLock lock];
            self.pendingModpackDownloads--;
            [self.downloadCountLock unlock];
            overallProgress.completedUnitCount++;
            if (downloader.textProgress) downloader.textProgress.completedUnitCount++;
            continue;
        }

        NSString *url = [downloadURLs firstObject];
        NSString *sha = nil;
        id hashesObj = indexFile[@"hashes"];
        if (hashesObj && [hashesObj isKindOfClass:[NSDictionary class]]) {
            id shaObj = ((NSDictionary *)hashesObj)[@"sha1"];
             if (shaObj && [shaObj isKindOfClass:[NSString class]]) {
                 sha = (NSString *)shaObj;
             }
        }


        // Ensure the path is correctly constructed relative to the destPath
        NSString *relativePath = indexFile[@"path"];
        if (!relativePath || ![relativePath isKindOfClass:[NSString class]]) {
             NSLog(@"[ModrinthAPI] File entry missing or invalid path");
             [self.downloadCountLock lock];
             self.pendingModpackDownloads--;
             [self.downloadCountLock unlock];
             overallProgress.completedUnitCount++;
             if (downloader.textProgress) downloader.textProgress.completedUnitCount++;
             continue;
        }


        // Make sure relativePath doesn't start with a slash to avoid path issues
        if ([relativePath hasPrefix:@"/"]) {
            relativePath = [relativePath substringFromIndex:1];
        }

        NSString *path = [destPath stringByAppendingPathComponent:relativePath];

        NSUInteger size = 0;
        id sizeObj = indexFile[@"fileSize"];
        if (sizeObj && [sizeObj isKindOfClass:[NSNumber class]]) {
            size = [sizeObj unsignedLongValue];
        }


        // Create directory structure if needed (run this on the file processing queue)
        dispatch_sync(self.fileProcessingQueue, ^{
            NSString *dirPath = [path stringByDeletingLastPathComponent];
            NSError *dirError;
            [[NSFileManager defaultManager] createDirectoryAtPath:dirPath
                                     withIntermediateDirectories:YES
                                                      attributes:nil
                                                           error:&dirError];
             if (dirError) {
                 NSLog(@"[ModrinthAPI] Warning: Failed to create directory %@: %@", dirPath, dirError.localizedDescription);
             }
        });


        // Create a display name that includes more path information
        NSString *displayName = relativePath; // Use relative path as display name
        NSLog(@"[ModrinthAPI] Preparing to download: %@ to %@", displayName, path);

        // Create unique ID for tracking retries
        NSString *downloadID = [NSString stringWithFormat:@"%@_%@", relativePath, sha ?: @"nohash"];

        // Enter the download group for this file
        dispatch_group_enter(downloadGroup);

        // Create success callback that decrements pending downloads
        void(^fileSuccess)(void) = ^{
            [self.downloadCountLock lock];
            self.pendingModpackDownloads--;
            NSInteger remaining = self.pendingModpackDownloads;
            [self.downloadCountLock unlock];

            NSLog(@"[ModrinthAPI] Download completed: %@, %ld remaining", relativePath, (long)remaining);

            // Update the overall progress (file count based)
            overallProgress.completedUnitCount++;
             if (downloader.textProgress) downloader.textProgress.completedUnitCount++;

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

                // Re-enter the group for the retry attempt, then create the task
                dispatch_group_enter(downloadGroup); // Enter again for retry
                
                // Use a copy of success/failure blocks for the retry
                void(^retrySuccess)(void) = ^{
                    [self.downloadCountLock lock];
                    self.pendingModpackDownloads--;
                    NSInteger remaining = self.pendingModpackDownloads;
                    [self.downloadCountLock unlock];
                    NSLog(@"[ModrinthAPI] Retry successful: %@, %ld remaining", relativePath, (long)remaining);
                    overallProgress.completedUnitCount++;
                    if (downloader.textProgress) downloader.textProgress.completedUnitCount++;
                    dispatch_group_leave(downloadGroup); // Leave for successful retry
                };
                
                void(^retryFailure)(NSError *retryError) = ^(NSError *retryError) {
                    NSLog(@"[ModrinthAPI] Retry failed for %@: %@", relativePath, retryError.localizedDescription);
                    // Decrement pending count after final failure
                    [self.downloadCountLock lock];
                    self.pendingModpackDownloads--;
                    [self.downloadCountLock unlock];
                    overallProgress.completedUnitCount++; // Mark as completed (failed)
                    if (downloader.textProgress) downloader.textProgress.completedUnitCount++;
                    dispatch_group_leave(downloadGroup); // Leave for failed retry
                };

                // Create the retry download task
                [downloader createDownloadTask:url
                                            size:size
                                             sha:sha
                                         altName:[NSString stringWithFormat:@"%@ (retry)", displayName]
                                          toPath:path
                                         success:retrySuccess
                                         failure:retryFailure];

                 // Leave the group for the *original* failed attempt
                 dispatch_group_leave(downloadGroup);

            } else {
                // Already retried, decrement pending count and leave group
                NSLog(@"[ModrinthAPI] Download failed after retry for %@: %@", relativePath, error.localizedDescription);
                [self.downloadCountLock lock];
                self.pendingModpackDownloads--;
                [self.downloadCountLock unlock];
                overallProgress.completedUnitCount++; // Mark as completed (failed)
                if (downloader.textProgress) downloader.textProgress.completedUnitCount++;
                dispatch_group_leave(downloadGroup);
            }
        };
        
        // Add the download task using the downloader's mechanism
        [downloader createDownloadTask:url
                                    size:size
                                     sha:sha
                                 altName:displayName
                                  toPath:path
                                 success:fileSuccess
                                 failure:fileFailure];

        // Check for immediate cancellation after adding task
        if (downloader.progress.cancelled) {
             NSLog(@"[ModrinthAPI] Download cancelled after adding task for %@", displayName);
             // If cancelled, manually leave the group as the callbacks might not fire
             dispatch_group_leave(downloadGroup);
             break; // Exit the loop
        }
    }

    // Check for cancellation one last time before waiting
    if (downloader.progress.cancelled) {
        NSLog(@"[ModrinthAPI] Download cancelled before waiting for group completion.");
        // Need to ensure group balance if we broke the loop early
        // Since we might have left the loop early, ensure the group count is 0
        [self.downloadCountLock lock];
        NSInteger pending = self.pendingModpackDownloads;
        while (pending > 0) {
             dispatch_group_leave(downloadGroup);
             pending--;
        }
        self.pendingModpackDownloads = 0;
        [self.downloadCountLock unlock];
        // Don't proceed to extraction
        return;
    }

    // Wait for all downloads to complete or timeout in a background thread
    // to avoid blocking the main thread
    dispatch_async(dispatch_get_global_queue(DISPATCH_QUEUE_PRIORITY_DEFAULT, 0), ^{
        // Set a reasonable timeout (e.g., 15 minutes)
        dispatch_time_t timeout = dispatch_time(DISPATCH_TIME_NOW, (int64_t)(900 * NSEC_PER_SEC));

        NSLog(@"[ModrinthAPI] Waiting for %ld downloads to complete...", (long)validFileCount);
        long result = dispatch_group_wait(downloadGroup, timeout);

        if (result != 0) {
            // Timeout occurred
            NSLog(@"[ModrinthAPI] Warning: Download group wait timed out. Some downloads may not have completed.");
            // Cancel remaining tasks in the downloader
            [downloader cancelAllTasks];
        } else {
             NSLog(@"[ModrinthAPI] All downloads completed or failed.");
        }
        
        // Proceed with extraction regardless of timeout/failures, unless cancelled
        if (!downloader.progress.cancelled) {
            dispatch_async(self.fileProcessingQueue, ^{ // Run extraction on the file processing queue
                 [self extractAndFinalizeModpack:downloader archive:archive indexDict:indexDict destPath:destPath packagePath:packagePath];
            });
        } else {
             NSLog(@"[ModrinthAPI] Download was cancelled, skipping extraction.");
             // Clean up the temporary package file
             [[NSFileManager defaultManager] removeItemAtPath:packagePath error:nil];
        }
    });
}


- (void)extractAndFinalizeModpack:(MinecraftResourceDownloadTask *)downloader
                          archive:(UZKArchive *)archive
                        indexDict:(NSDictionary *)indexDict
                         destPath:(NSString *)destPath
                      packagePath:(NSString *)packagePath {
    // Ensure this runs on the dedicated file processing queue
    dispatch_assert_queue(self.fileProcessingQueue);

    // Add extraction filename to track progress
    dispatch_async(dispatch_get_main_queue(), ^{
        [downloader.fileList addObject:@"Extracting modpack files..."];
        NSProgress *extractionProgress = [NSProgress progressWithTotalUnitCount:100];
        extractionProgress.completedUnitCount = 0;
        [downloader.progressList addObject:extractionProgress];
        // Add extraction progress as a child
        [downloader.progress addChild:extractionProgress withPendingUnitCount:100]; // Adjust weight as needed
        downloader.metadata[@"extractionProgress"] = extractionProgress; // Store for updates
    });

    NSLog(@"[ModrinthAPI] Beginning extraction of modpack contents to %@", destPath);

    // Extract overrides directory - this is the main content directory
    [self updateExtractionProgress:downloader percentage:10];
    [self extractDirectoryFromArchive:archive directory:@"overrides" toPath:destPath progress:downloader.metadata[@"extractionProgress"]];
    [self updateExtractionProgress:downloader percentage:50];

    // Extract client-overrides directory if it exists (newer Modrinth format)
    [self extractDirectoryFromArchive:archive directory:@"client-overrides" toPath:destPath progress:downloader.metadata[@"extractionProgress"]];
    [self updateExtractionProgress:downloader percentage:75];

    // Extract server-overrides directory if it exists (for completeness, though not used by client)
    // No progress update needed here as it's less critical for the client
    [self extractDirectoryFromArchive:archive directory:@"server-overrides" toPath:destPath progress:nil];

    // Clean up the downloaded package file
    NSError *removeError;
    [NSFileManager.defaultManager removeItemAtPath:packagePath error:&removeError];
    if (removeError) {
        NSLog(@"[ModrinthAPI] Warning: Failed to remove package cache %@: %@", packagePath, removeError.localizedDescription);
    }

    // Update extraction progress
    [self updateExtractionProgress:downloader percentage:90];

    // Get dependency info safely
    NSDictionary *dependencies = downloader.metadata[@"modpackDependencies"];
    if (!dependencies || ![dependencies isKindOfClass:[NSDictionary class]]) {
        dependencies = @{}; // Ensure it's a dictionary
    }
    NSDictionary<NSString *, NSString *> *depInfo = [ModpackUtils infoForDependencies:dependencies];


    // Check if a dependency JSON needs to be downloaded
    NSString *jsonUrl = depInfo[@"json"];
    if (jsonUrl && jsonUrl.length > 0) {
        // Add JSON download status
        dispatch_async(dispatch_get_main_queue(), ^{
            [downloader.fileList addObject:@"Downloading dependency info..."];
            NSProgress *jsonProgress = [NSProgress progressWithTotalUnitCount:100];
            [downloader.progressList addObject:jsonProgress];
            [downloader.progress addChild:jsonProgress withPendingUnitCount:50]; // Weight for JSON download
             downloader.metadata[@"jsonProgress"] = jsonProgress; // Store for updates
        });

        NSString *versionId = depInfo[@"id"];
        NSString *jsonPath = [NSString stringWithFormat:@"%@/versions/%@/%@.json", getenv("POJAV_GAME_DIR"), versionId, versionId];

        // Create directories for JSON path
        NSString *jsonDir = [jsonPath stringByDeletingLastPathComponent];
        NSError *jsonDirError;
        [[NSFileManager defaultManager] createDirectoryAtPath:jsonDir
                                 withIntermediateDirectories:YES
                                                  attributes:nil
                                                       error:&jsonDirError];
        if (jsonDirError) {
             NSLog(@"[ModrinthAPI] Warning: Failed to create directory for JSON %@: %@", jsonDir, jsonDirError.localizedDescription);
        }


        // Create success callback for JSON download
        void(^jsonSuccess)(void) = ^{
            dispatch_async(dispatch_get_main_queue(), ^{
                 NSProgress *jsonProgress = downloader.metadata[@"jsonProgress"];
                 if (jsonProgress) jsonProgress.completedUnitCount = 100;
                 [self updateExtractionProgress:downloader percentage:100]; // Mark extraction complete
            });
            // Finalize installation after JSON download
            [self finalizeModpackInstallation:downloader indexDict:indexDict depInfo:depInfo destPath:destPath];
        };

        // Create failure callback for JSON download
        void(^jsonFailure)(NSError *jsonError) = ^(NSError *jsonError) {
            NSLog(@"[ModrinthAPI] Failed to download dependency JSON: %@", jsonError.localizedDescription);
            dispatch_async(dispatch_get_main_queue(), ^{
                 NSProgress *jsonProgress = downloader.metadata[@"jsonProgress"];
                 if (jsonProgress) jsonProgress.completedUnitCount = 100; // Mark as complete (failed)
                 [self updateExtractionProgress:downloader percentage:100]; // Mark extraction complete
            });
            // Still finalize installation even if JSON fails
            [self finalizeModpackInstallation:downloader indexDict:indexDict depInfo:depInfo destPath:destPath];
        };

        // Create and queue the JSON download task
         [downloader createDownloadTask:jsonUrl
                                    size:0 // Size unknown
                                     sha:nil // No hash check for JSON usually
                                 altName:@"Dependency Info"
                                  toPath:jsonPath
                                 success:jsonSuccess
                                 failure:jsonFailure];
    } else {
        // No JSON to download, finalize immediately
        [self updateExtractionProgress:downloader percentage:100];
        [self finalizeModpackInstallation:downloader indexDict:indexDict depInfo:depInfo destPath:destPath];
    }
}

// Helper to update extraction progress on the main thread
- (void)updateExtractionProgress:(MinecraftResourceDownloadTask *)downloader percentage:(NSInteger)percentage {
    dispatch_async(dispatch_get_main_queue(), ^{
        NSProgress *extractionProgress = downloader.metadata[@"extractionProgress"];
        if (extractionProgress) {
            extractionProgress.completedUnitCount = MIN(percentage, extractionProgress.totalUnitCount);
        }
    });
}

- (void)extractDirectoryFromArchive:(UZKArchive *)archive directory:(NSString *)directoryName toPath:(NSString *)destPath progress:(NSProgress *)progress {
    // Ensure this runs on the dedicated file processing queue
    dispatch_assert_queue(self.fileProcessingQueue);

    if (!directoryName || directoryName.length == 0) {
        NSLog(@"[ModrinthAPI] Invalid directory name for extraction: %@", directoryName);
        return;
    }

    NSError *error;
    NSLog(@"[ModrinthAPI] Attempting to extract directory '%@' from archive to '%@'", directoryName, destPath);

    // Use ModpackUtils helper for extraction
    [ModpackUtils archive:archive extractDirectory:directoryName toPath:destPath error:&error];

    if (error) {
        // Log error but continue, as the directory might just not exist
        NSLog(@"[ModrinthAPI] Info: Could not extract directory '%@': %@", directoryName, error.localizedDescription);
    } else {
        NSLog(@"[ModrinthAPI] Successfully extracted directory '%@' (or it was empty/didn't exist)", directoryName);
        // Optionally update progress if provided and successful
        if (progress) {
            dispatch_async(dispatch_get_main_queue(), ^{
                // Increment progress slightly upon successful extraction of a section
                progress.completedUnitCount = MIN(progress.completedUnitCount + 5, progress.totalUnitCount);
            });
        }
    }
}

- (void)finalizeModpackInstallation:(MinecraftResourceDownloadTask *)downloader
                          indexDict:(NSDictionary *)indexDict
                            depInfo:(NSDictionary *)depInfo
                           destPath:(NSString *)destPath {
    // Ensure this runs on the dedicated file processing queue
    dispatch_assert_queue(self.fileProcessingQueue);

    // Add setup status on main thread
    dispatch_async(dispatch_get_main_queue(), ^{
        [downloader.fileList addObject:@"Setting up profile..."];
        NSProgress *setupProgress = [NSProgress progressWithTotalUnitCount:100];
        [downloader.progressList addObject:setupProgress];
        [downloader.progress addChild:setupProgress withPendingUnitCount:50]; // Weight for setup
        downloader.metadata[@"setupProgress"] = setupProgress; // Store for updates
    });

    [self updateSetupProgress:downloader percentage:25];

    // Get the profile name from indexDict, or use the directory name if not available
    NSString *profileName = indexDict[@"name"];
    if (!profileName || ![profileName isKindOfClass:[NSString class]] || [profileName length] == 0) {
        profileName = [destPath lastPathComponent]; // Fallback to directory name
    }
    // Sanitize profile name if needed (though PLProfiles might handle this)
    profileName = [profileName stringByReplacingOccurrencesOfString:@"/" withString:@"-"];

    // Calculate the relative gameDir based on the standard instances structure
    NSString *gameDir = [PLProfiles uniqueGameDirForProfileName:profileName];

    [self updateSetupProgress:downloader percentage:50];

    NSLog(@"[ModrinthAPI] Creating profile: '%@' with gameDir: '%@'", profileName, gameDir);

    // Create the profile dictionary
    NSMutableDictionary *newProfile = [@{
        @"gameDir": gameDir,
        @"name": profileName,
        @"lastVersionId": depInfo[@"id"] ?: @"latest-release" // Use dependency ID or fallback
    } mutableCopy];

    [self updateSetupProgress:downloader percentage:75];

    // Safely handle the icon data from temporary path
    NSString *tmpIconPath = [NSTemporaryDirectory() stringByAppendingPathComponent:@"icon.png"];
    NSData *iconData = [NSData dataWithContentsOfFile:tmpIconPath];
    if (iconData && iconData.length > 0) {
        NSString *base64Icon = [NSString stringWithFormat:@"data:image/png;base64,%@",
                                [iconData base64EncodedStringWithOptions:0]];
        newProfile[@"icon"] = base64Icon;
    }
    // Clean up temporary icon file
    [[NSFileManager defaultManager] removeItemAtPath:tmpIconPath error:nil];


    // Add the profile and save using PLProfiles (ensures thread safety within PLProfiles)
    [PLProfiles.current addOrUpdateProfile:newProfile withName:profileName];
    PLProfiles.current.selectedProfileName = profileName;
    [PLProfiles.current save];


    [self updateSetupProgress:downloader percentage:100];

    // Ensure metadata reflects completion and marks this as a modpack install
    dispatch_async(dispatch_get_main_queue(), ^{
        if (!downloader.metadata) {
            downloader.metadata = [NSMutableDictionary dictionary];
        }
        downloader.metadata[@"isModpackInstall"] = @YES;
        downloader.metadata[@"allTasksComplete"] = @YES;
        downloader.metadata[@"profileName"] = profileName;

        // Ensure overall progress is marked as complete
        downloader.progress.completedUnitCount = downloader.progress.totalUnitCount;
        if (downloader.textProgress) {
            downloader.textProgress.completedUnitCount = downloader.textProgress.totalUnitCount;
        }

        // Add completion marker
        [downloader.fileList addObject:@"Installation Complete"];
        NSProgress *completeProgress = [NSProgress progressWithTotalUnitCount:1];
        completeProgress.completedUnitCount = 1;
        [downloader.progressList addObject:completeProgress];
        
        // Notify completion
        [downloader completeDownload];

        NSLog(@"[ModrinthAPI] Modpack installation complete for profile: %@", profileName);

        // Check for Forge/NeoForge after completion notification
        [self checkAndInstallForge:downloader
                 withDependencies:indexDict[@"dependencies"] // Pass original dependencies
                      profileName:profileName];
    });
}

// Helper to update setup progress on the main thread
- (void)updateSetupProgress:(MinecraftResourceDownloadTask *)downloader percentage:(NSInteger)percentage {
    dispatch_async(dispatch_get_main_queue(), ^{
        NSProgress *setupProgress = downloader.metadata[@"setupProgress"];
        if (setupProgress) {
            setupProgress.completedUnitCount = MIN(percentage, setupProgress.totalUnitCount);
        }
    });
}


- (void)checkAndInstallForge:(MinecraftResourceDownloadTask *)downloader
            withDependencies:(NSDictionary *)dependencies
                 profileName:(NSString *)profileName {
    // This method should run on the main thread as it interacts with UI

    // Ensure dependencies is a dictionary
     if (!dependencies || ![dependencies isKindOfClass:[NSDictionary class]]) {
         dependencies = @{};
     }

    // Check if the modpack requires Forge or NeoForge
    NSString *forgeVersion = dependencies[@"forge"];
    NSString *neoForgeVersion = dependencies[@"neoforge"];
    NSString *minecraftVersion = dependencies[@"minecraft"];

    // Validate versions
    if ((!forgeVersion || ![forgeVersion isKindOfClass:[NSString class]]) &&
        (!neoForgeVersion || ![neoForgeVersion isKindOfClass:[NSString class]])) {
        NSLog(@"[ModrinthAPI] No valid Forge or NeoForge dependency found.");
        return; // No Forge dependency
    }
    if (!minecraftVersion || ![minecraftVersion isKindOfClass:[NSString class]]) {
         NSLog(@"[ModrinthAPI] Minecraft version dependency missing or invalid.");
         // Cannot proceed without Minecraft version
         showDialog(@"Installation Incomplete", @"Modpack dependency information is missing the Minecraft version. Forge/NeoForge cannot be installed automatically.");
         return;
    }


    NSString *vendor = forgeVersion ? @"Forge" : @"NeoForge";
    NSString *version = forgeVersion ?: neoForgeVersion;
    NSString *fullVersion;

    // Construct the full version ID used in the versions directory
    if ([vendor isEqualToString:@"Forge"]) {
        // Forge format: MCVersion-ForgeVersion (e.g., 1.19.2-43.2.0)
        fullVersion = [NSString stringWithFormat:@"%@-%@", minecraftVersion, version];
    } else {
        // NeoForge format: NeoForgeVersion (e.g., 20.4.88-beta) - It already includes MC version implicitly
        // Or sometimes just the version number if it's for a specific MC version context.
        // Let's assume the provided version string is the target identifier.
        // NeoForge might also use MCVersion-NeoForgeVersion like Forge. Check format.
        // Example: 1.20.1-47.1.3 -> Forge style
        // Example: 20.4.198-beta -> NeoForge specific style
        // Let's try to detect: If version contains '-', assume Forge style.
         if ([version containsString:@"-"]) {
             // Check if it already starts with MC version
             if (![version hasPrefix:minecraftVersion]) {
                 fullVersion = [NSString stringWithFormat:@"%@-%@", minecraftVersion, version];
             } else {
                 fullVersion = version; // Assume format like 1.20.1-47.1.3 is correct
             }
         } else {
            // Assume it's just the NeoForge version part, prepend MC version
             fullVersion = [NSString stringWithFormat:@"%@-%@", minecraftVersion, version];
         }
         // NeoForge specific format might just be the version itself in some contexts?
         // Let's stick to MCVersion-LoaderVersion for consistency unless proven otherwise.
         // Correction: Official NeoForge versions in launcher are often just the NeoForge version string itself.
         // Example: 47.1.82 (for 1.20.1). The JSON name might be different.
         // Let's use the version string directly provided by Modrinth for NeoForge check.
         // Update: Check the path structure. Forge/NeoForge usually install under their full name.
         // We'll use the `fullVersion` derived above for path checking.
    }


    // Check if this specific loader version is already installed
    NSString *versionPath = [NSString stringWithFormat:@"%@/versions/%@", getenv("POJAV_GAME_DIR"), fullVersion];
    if ([NSFileManager.defaultManager fileExistsAtPath:versionPath]) {
        NSLog(@"[ModrinthAPI] %@ version %@ seems to be already installed at %@", vendor, fullVersion, versionPath);
        return;
    } else {
         NSLog(@"[ModrinthAPI] %@ version %@ not found at %@. Prompting for installation.", vendor, fullVersion, versionPath);
    }


    // Show alert to user (must be on main thread)
    UIAlertController *alert = [UIAlertController
        alertControllerWithTitle:[NSString stringWithFormat:@"%@ Installation Required", vendor]
        message:[NSString stringWithFormat:@"This modpack requires %@ %@ for Minecraft %@, which is not yet installed. Would you like to install it now?", vendor, version, minecraftVersion]
        preferredStyle:UIAlertControllerStyleAlert];

    [alert addAction:[UIAlertAction
        actionWithTitle:@"Yes"
        style:UIAlertActionStyleDefault
        handler:^(UIAlertAction * _Nonnull action) {
            // Get the correct endpoint info based on vendor type
            NSDictionary *endpoints;
            NSString *installerFileNameFormat; // Format for the expected installer JAR name

            if ([vendor isEqualToString:@"Forge"]) {
                endpoints = @{
                    @"installer": @"https://maven.minecraftforge.net/net/minecraftforge/forge/%1$@/forge-%1$@-installer.jar",
                    @"metadata": @"https://maven.minecraftforge.net/net/minecraftforge/forge/maven-metadata.xml"
                };
                installerFileNameFormat = @"forge-%@-installer.jar"; // %1$@ will be fullVersion
            } else { // NeoForge
                endpoints = @{
                    // NeoForge installer URL might need adjustment based on version format
                    @"installer": @"https://maven.neoforged.net/releases/net/neoforged/neoforge/%1$@/neoforge-%1$@-installer.jar",
                    @"metadata": @"https://maven.neoforged.net/releases/net/neoforged/neoforge/maven-metadata.xml"
                };
                 installerFileNameFormat = @"neoforge-%@-installer.jar"; // %1$@ will be fullVersion
            }

            // Construct the installer URL using the full version ID
            NSString *installerUrl = [NSString stringWithFormat:endpoints[@"installer"], fullVersion];
            NSString *expectedInstallerJarName = [NSString stringWithFormat:installerFileNameFormat, fullVersion];
            NSString *outPath = [NSTemporaryDirectory() stringByAppendingPathComponent:expectedInstallerJarName];

            NSLog(@"[ModrinthAPI] Downloading %@ installer from: %@", vendor, installerUrl);
            NSLog(@"[ModrinthAPI] Saving installer to: %@", outPath);

            // Create download manager
            NSURLSessionConfiguration *configuration = [NSURLSessionConfiguration defaultSessionConfiguration];
            AFURLSessionManager *manager = [[AFURLSessionManager alloc] initWithSessionConfiguration:configuration];

            // Setup UI for download - Find the active navigation controller
            LauncherNavigationController *navVC = nil;
            UIViewController *rootVC = nil;
            // Get the key window scene
            UIWindowScene *windowScene = nil;
            for (UIScene *scene in UIApplication.sharedApplication.connectedScenes) {
                if (scene.activationState == UISceneActivationStateForegroundActive && [scene isKindOfClass:[UIWindowScene class]]) {
                    windowScene = (UIWindowScene *)scene;
                    break;
                }
            }
            // Get the key window from the scene
            UIWindow *keyWindow = nil;
            for (UIWindow *window in windowScene.windows) {
                if (window.isKeyWindow) {
                    keyWindow = window;
                    break;
                }
            }
            rootVC = keyWindow.rootViewController;

            // Traverse to find the LauncherNavigationController
            if ([rootVC isKindOfClass:[UISplitViewController class]]) {
                 UISplitViewController *splitVC = (UISplitViewController *)rootVC;
                 if (splitVC.viewControllers.count > 1 && [splitVC.viewControllers[1] isKindOfClass:[LauncherNavigationController class]]) {
                      navVC = (LauncherNavigationController *)splitVC.viewControllers[1];
                 }
            } else if ([rootVC isKindOfClass:[LauncherNavigationController class]]) {
                 navVC = (LauncherNavigationController *)rootVC;
            }


            if (navVC) {
                [navVC setInteractionEnabled:NO forDownloading:YES];
                navVC.progressText.text = [NSString stringWithFormat:@"Downloading %@ installer...", vendor];
                navVC.progressViewMain.hidden = NO;
                navVC.progressViewMain.progress = 0.0f; // Reset progress
            } else {
                 NSLog(@"[ModrinthAPI] Warning: Could not find LauncherNavigationController to display progress.");
            }


            // Create download request with User-Agent
            NSMutableURLRequest *request = [NSMutableURLRequest requestWithURL:[NSURL URLWithString:installerUrl]];
            [request setValue:self.userAgent forHTTPHeaderField:@"User-Agent"];

            NSURLSessionDownloadTask *downloadTask = [manager downloadTaskWithRequest:request progress:^(NSProgress * _Nonnull downloadProgress) {
                dispatch_async(dispatch_get_main_queue(), ^{
                    if (navVC) {
                        navVC.progressViewMain.progress = downloadProgress.fractionCompleted;
                    }
                });
            } destination:^NSURL *(NSURL *targetPath, NSURLResponse *response) {
                // Remove existing file if present before moving
                [[NSFileManager defaultManager] removeItemAtPath:outPath error:nil];
                return [NSURL fileURLWithPath:outPath];
            } completionHandler:^(NSURLResponse *response, NSURL *filePath, NSError *error) {
                dispatch_async(dispatch_get_main_queue(), ^{
                    // Restore UI interaction regardless of outcome
                    if (navVC) {
                        [navVC setInteractionEnabled:YES forDownloading:NO];
                        navVC.progressViewMain.hidden = YES;
                        navVC.progressText.text = nil;
                    }

                    if (error) {
                        NSLog(@"[ModrinthAPI] Error downloading %@ installer: %@", vendor, error.localizedDescription);
                        showDialog(@"Download Failed", [NSString stringWithFormat:@"Failed to download the %@ installer: %@", vendor, error.localizedDescription]);
                        return;
                    }

                    if (!filePath || ![[NSFileManager defaultManager] fileExistsAtPath:filePath.path]) {
                         NSLog(@"[ModrinthAPI] %@ installer file not found after download at %@", vendor, filePath.path);
                         showDialog(@"Download Failed", [NSString stringWithFormat:@"The %@ installer file seems to be missing after download.", vendor]);
                         return;
                    }


                    NSLog(@"[ModrinthAPI] %@ installer downloaded successfully to %@", vendor, filePath.path);

                    // Launch the installer using the appropriate method in LauncherNavigationController
                    if (navVC) {
                         // Use the correct path from the completion handler's `filePath`
                         [navVC enterModInstallerWithPath:filePath.path hitEnterAfterWindowShown:YES];
                    } else {
                         NSLog(@"[ModrinthAPI] Error: Could not locate navigation controller to launch installer.");
                         showDialog(@"Error", @"Could not launch the installer automatically. Please find it in the temporary directory and run it manually if possible.");
                    }
                });
            }];

            [downloadTask resume];
        }]];

    [alert addAction:[UIAlertAction
        actionWithTitle:@"No"
        style:UIAlertActionStyleCancel
        handler:nil]];

    // Find the topmost view controller to present the alert
    UIViewController *presentingVC = keyWindow.rootViewController;
    while (presentingVC.presentedViewController) {
        presentingVC = presentingVC.presentedViewController;
    }
    [presentingVC presentViewController:alert animated:YES completion:nil];
}


- (void)installModpackFromDetail:(NSDictionary *)modDetail atIndex:(NSUInteger)selectedVersion {
    // Ensure this runs on the main thread as it posts a notification
    // that likely triggers UI updates.
    dispatch_async(dispatch_get_main_queue(), ^{
        // Pass details to LauncherNavigationController via notification
        NSDictionary* userInfo = @{
            @"detail": modDetail ?: @{}, // Ensure dictionary is not nil
            @"index": @(selectedVersion)
        };
        [[NSNotificationCenter defaultCenter]
            postNotificationName:@"InstallModpack"
            object:self userInfo:userInfo];
         NSLog(@"[ModrinthAPI] Posted InstallModpack notification for version index %lu", (unsigned long)selectedVersion);
    });
}

@end

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
extern NSString* getPrefObject(NSString* key);

// Maximum concurrent downloads for modpack files
#define MAX_CONCURRENT_DOWNLOADS 6

@interface ModrinthAPI ()
// Private properties for download management
@property (nonatomic, assign) NSInteger pendingModpackDownloads;
@property (nonatomic, strong) NSLock *downloadCountLock;
@property (nonatomic, strong) dispatch_queue_t fileProcessingQueue; // Serial queue for file I/O
@end

@implementation ModrinthAPI

// Helper function to convert WebP URLs to supported formats (like PNG)
- (NSString *)convertWebPUrl:(NSString *)imageUrl {
    // Return original URL if it's nil, empty, or not a WebP
    if (!imageUrl || imageUrl.length == 0 || ![imageUrl.lowercaseString hasSuffix:@".webp"]) {
        return imageUrl;
    }

    // Handle Modrinth CDN URLs by appending format=png
    if ([imageUrl containsString:@"cdn.modrinth.com"]) {
        // Use NSURLComponents for robust parameter addition
        NSURLComponents *components = [NSURLComponents componentsWithString:imageUrl];
        NSMutableArray *queryItems = [components.queryItems mutableCopy] ?: [NSMutableArray array];

        // Check if 'format' parameter already exists
        BOOL formatExists = NO;
        for (NSURLQueryItem *item in queryItems) {
            if ([item.name isEqualToString:@"format"]) {
                formatExists = YES;
                break;
            }
        }

        // Add 'format=png' if it doesn't exist
        if (!formatExists) {
            [queryItems addObject:[NSURLQueryItem queryItemWithName:@"format" value:@"png"]];
            components.queryItems = queryItems;
            return components.URL.absoluteString ?: imageUrl; // Return original if URL creation fails
        }
    } else {
        // For other URLs, try replacing the extension
        return [imageUrl stringByReplacingOccurrencesOfString:@".webp"
                                                   withString:@".png"
                                                      options:NSCaseInsensitiveSearch | NSBackwardsSearch // More precise replacement
                                                        range:NSMakeRange(0, imageUrl.length)];
    }

    // Return the original URL if no conversion was applied
    return imageUrl;
}

- (instancetype)init {
    self = [super init];
    if (self) {
        // Create URL session configuration with appropriate settings
        NSURLSessionConfiguration *configuration = [NSURLSessionConfiguration defaultSessionConfiguration];

        // Set reasonable timeouts
        configuration.timeoutIntervalForRequest = 30.0; // Timeout for establishing connection
        configuration.timeoutIntervalForResource = 60.0; // Timeout for the entire resource download

        // **FIX:** Initialize userAgent property to prevent nil value.
        // Use a descriptive user agent string.
        self.userAgent = @"PojavLauncher-iOS/1.0 (github.com/PojavLauncherTeam/PojavLauncher_iOS)";
        configuration.HTTPAdditionalHeaders = @{
            @"User-Agent": self.userAgent, // Use the initialized property
            @"Accept": @"application/json" // Standard Accept header for APIs
        };

        // Initialize the URL session with the configuration
        self.session = [NSURLSession sessionWithConfiguration:configuration];

        // Initialize properties for pagination and error tracking
        self.reachedLastPage = NO;
        self.lastError = nil; // Initialize lastError to nil

        // Initialize properties for download management
        self.downloadCountLock = [[NSLock alloc] init]; // Lock for thread-safe access to download counter
        self.pendingModpackDownloads = 0; // Counter for active downloads
        // Create a serial queue for file system operations (extraction, directory creation) to prevent race conditions
        self.fileProcessingQueue = dispatch_queue_create("com.pojavlauncher.modrinthFileProcessing", DISPATCH_QUEUE_SERIAL);
    }
    return self;
}

// Search for mods/modpacks on Modrinth with filters and pagination support
- (NSMutableArray *)searchModWithFilters:(NSDictionary *)filters previousPageResult:(NSMutableArray *)previousPageResult {
    // Ensure filters dictionary is not nil
    if (!filters) {
        filters = @{}; // Use an empty dictionary if filters are nil
    }

    // Determine the offset for pagination based on previous results
    NSInteger offset = previousPageResult ? [previousPageResult count] : 0;

    // Base URL for Modrinth search API
    NSString *urlStr = @"https://api.modrinth.com/v2/search";

    // Prepare parameters dictionary, ensuring values are valid
    NSMutableDictionary *parameters = [NSMutableDictionary dictionary];

    // Add standard facet for modpacks if requested
    if ([filters[@"isModpack"] boolValue]) {
        parameters[@"facets"] = @"[[\"project_type:modpack\"]]"; // Modrinth API format for facets
    }

    // Set limit for results per page (Modrinth default/max is often higher, but 50 is reasonable)
    parameters[@"limit"] = @"50";

    // Add offset parameter only if we are loading subsequent pages
    if (offset > 0) {
        parameters[@"offset"] = [NSString stringWithFormat:@"%ld", (long)offset];
    }

    // Apply sort method, defaulting to 'relevance'
    NSString *sortMethod = filters[@"sortMethod"];
    if (sortMethod && [sortMethod isKindOfClass:[NSString class]] && sortMethod.length > 0) {
        parameters[@"index"] = sortMethod;
    } else {
        parameters[@"index"] = @"relevance"; // Default sort order
    }

    // Apply search term (query) if provided
    NSString *searchTerm = filters[@"name"];
    if (searchTerm && [searchTerm isKindOfClass:[NSString class]] && searchTerm.length > 0) {
        parameters[@"query"] = searchTerm;
    }

    // Log the parameters being used for debugging
    NSLog(@"[ModrinthAPI] Searching with params: %@", parameters);

    // Use AFNetworking for the request (consider replacing synchronous wait with async handling)
    NSURLSessionConfiguration *configuration = [NSURLSessionConfiguration defaultSessionConfiguration];
    AFURLSessionManager *manager = [[AFURLSessionManager alloc] initWithSessionConfiguration:configuration];
    // Use JSON request serializer
    AFJSONRequestSerializer *requestSerializer = [AFJSONRequestSerializer serializer];

    // Create the URL request
    NSError *serializationError;
    NSMutableURLRequest *request = [requestSerializer requestWithMethod:@"GET"
                                                             URLString:urlStr
                                                            parameters:parameters // AFNetworking handles parameter encoding
                                                                 error:&serializationError];

    if (serializationError) {
        NSLog(@"[ModrinthAPI] Error creating request serialization: %@", serializationError);
        self.lastError = serializationError;
        return previousPageResult ?: [NSMutableArray array]; // Return previous results or empty array
    }

    // Ensure User-Agent is set (should be handled by session config, but double-check)
    if (![request valueForHTTPHeaderField:@"User-Agent"] && self.userAgent) {
        [request setValue:self.userAgent forHTTPHeaderField:@"User-Agent"];
    } else if (![request valueForHTTPHeaderField:@"User-Agent"]) {
        [request setValue:@"PojavLauncher-iOS" forHTTPHeaderField:@"User-Agent"]; // Fallback if somehow nil
    }

    // **Synchronous Request using Semaphore:**
    // This blocks the calling thread. Consider refactoring to use completion handlers
    // if this method is called from the main thread or performance is critical.
    dispatch_semaphore_t semaphore = dispatch_semaphore_create(0);
    __block id responseObject = nil;
    __block NSError *requestError = nil;
    __block NSURLResponse *urlResponse = nil; // To check status code

    NSURLSessionDataTask *dataTask = [manager dataTaskWithRequest:request uploadProgress:nil downloadProgress:nil completionHandler:^(NSURLResponse *response, id responseData, NSError *dataError) {
        responseObject = responseData;
        requestError = dataError;
        urlResponse = response;
        dispatch_semaphore_signal(semaphore); // Signal completion
    }];

    [dataTask resume]; // Start the task

    // Wait for the semaphore with a timeout (e.g., 30 seconds)
    long timeoutResult = dispatch_semaphore_wait(semaphore, dispatch_time(DISPATCH_TIME_NOW, 30 * NSEC_PER_SEC));

    // Handle timeout
    if (timeoutResult != 0) {
        [dataTask cancel]; // Cancel the task if it timed out
        NSLog(@"[ModrinthAPI] Network request timed out for search.");
        self.lastError = [NSError errorWithDomain:NSURLErrorDomain code:NSURLErrorTimedOut userInfo:@{NSLocalizedDescriptionKey: @"Search request timed out"}];
        return previousPageResult ?: [NSMutableArray array];
    }

    // Handle fundamental network errors
    if (requestError) {
        NSLog(@"[ModrinthAPI] Network error during search: %@", requestError);
        self.lastError = requestError;
        return previousPageResult ?: [NSMutableArray array];
    }

    // Check HTTP Status Code
    NSInteger statusCode = 0;
    if ([urlResponse isKindOfClass:[NSHTTPURLResponse class]]) {
        statusCode = [(NSHTTPURLResponse *)urlResponse statusCode];
        if (statusCode < 200 || statusCode >= 300) {
            NSString *errorBody = [[NSString alloc] initWithData:(NSData *)responseObject encoding:NSUTF8StringEncoding] ?: @"";
             NSLog(@"[ModrinthAPI] HTTP error %ld during search: %@", (long)statusCode, errorBody);
             self.lastError = [NSError errorWithDomain:@"ModrinthAPIHTTPError" code:statusCode userInfo:@{NSLocalizedDescriptionKey:[NSString stringWithFormat:@"Search failed with HTTP status %ld", (long)statusCode], @"ResponseBody": errorBody}];
             return previousPageResult ?: [NSMutableArray array];
        }
    }


    // Parse the JSON response
    NSDictionary *jsonResponse = responseObject;
    if (!jsonResponse || ![jsonResponse isKindOfClass:[NSDictionary class]]) {
        NSLog(@"[ModrinthAPI] Invalid or non-dictionary JSON response received for search.");
        self.lastError = [NSError errorWithDomain:@"ModrinthAPI" code:1 userInfo:@{NSLocalizedDescriptionKey: @"Invalid JSON response format for search"}];
        return previousPageResult ?: [NSMutableArray array];
    }

    // Extract hits (search results)
    NSArray *hits = jsonResponse[@"hits"];
    if (!hits || ![hits isKindOfClass:[NSArray class]]) {
        NSLog(@"[ModrinthAPI] 'hits' array missing or invalid in search response.");
        // Treat as no results found, don't set error necessarily
        self.reachedLastPage = YES; // Assume end of results if 'hits' is missing/invalid
        return previousPageResult ?: [NSMutableArray array];
    }

    // Update pagination state based on total hits
    NSNumber *totalHitsNum = jsonResponse[@"total_hits"];
    NSInteger totalResults = totalHitsNum ? [totalHitsNum integerValue] : 0;
    self.reachedLastPage = (offset + hits.count >= totalResults);

    NSLog(@"[ModrinthAPI] Got %lu search results.", (unsigned long)hits.count);
    NSLog(@"[ModrinthAPI] Pagination: %ld/%ld (reached last page: %@)",
          (long)(offset + hits.count),
          (long)totalResults,
          self.reachedLastPage ? @"YES" : @"NO");

    // Initialize or use the previous result array
    NSMutableArray *modpacks = previousPageResult ?: [NSMutableArray array];
    NSMutableSet *currentIds = [NSMutableSet set]; // To avoid adding duplicates if previousPageResult exists
    if (previousPageResult) {
        for (NSDictionary* mod in previousPageResult) {
            if (mod[@"id"]) [currentIds addObject:mod[@"id"]];
        }
    }


    // Process each hit and add to the results array
    for (NSDictionary *modData in hits) {
        if (![modData isKindOfClass:[NSDictionary class]]) {
            NSLog(@"[ModrinthAPI] Warning: Skipping invalid item in 'hits' array.");
            continue;
        }

        // Extract data safely, checking types and presence
        NSMutableDictionary *modpack = [NSMutableDictionary dictionary];
        NSString *projectId = nil;
        if (modData[@"project_id"] && [modData[@"project_id"] isKindOfClass:[NSString class]]) {
             projectId = modData[@"project_id"];
             // Avoid adding duplicates if paginating
             if ([currentIds containsObject:projectId]) {
                 continue;
             }
             modpack[@"id"] = projectId;
        } else {
             NSLog(@"[ModrinthAPI] Warning: Skipping search result with missing or invalid 'project_id'.");
             continue; // Skip if no valid ID
        }


        if (modData[@"title"] && [modData[@"title"] isKindOfClass:[NSString class]]) modpack[@"title"] = modData[@"title"];
        if (modData[@"slug"] && [modData[@"slug"] isKindOfClass:[NSString class]]) modpack[@"slug"] = modData[@"slug"];
        if (modData[@"description"] && [modData[@"description"] isKindOfClass:[NSString class]]) modpack[@"description"] = modData[@"description"];
        if (modData[@"categories"] && [modData[@"categories"] isKindOfClass:[NSArray class]]) modpack[@"categories"] = modData[@"categories"];
        if (modData[@"downloads"] && [modData[@"downloads"] isKindOfClass:[NSNumber class]]) modpack[@"downloads"] = modData[@"downloads"];

        // Handle and convert icon URL immediately
        NSString *iconUrl = modData[@"icon_url"];
        if (iconUrl && [iconUrl isKindOfClass:[NSString class]] && iconUrl.length > 0) {
            modpack[@"imageUrl"] = [self convertWebPUrl:iconUrl]; // Convert WebP
            NSLog(@"[ModrinthAPI] Project %@ has icon URL: %@", modpack[@"id"], modpack[@"imageUrl"]);
        }

        // Add the processed modpack to the results
        [modpacks addObject:modpack];
         [currentIds addObject:projectId]; // Track added ID
    }

    // Clear lastError on success
    self.lastError = nil;
    return modpacks;
}

// Load detailed information for a specific mod/modpack item
- (void)loadDetailsOfMod:(NSMutableDictionary *)item {
    // Validate the input item
    if (!item || ![item isKindOfClass:[NSMutableDictionary class]]) {
        NSLog(@"[ModrinthAPI] Error: item provided to loadDetailsOfMod is nil or not a mutable dictionary.");
        return;
    }

    // Get the project ID, ensuring it's a valid string
    NSString *projectId = item[@"id"];
    if (!projectId || ![projectId isKindOfClass:[NSString class]] || projectId.length == 0) {
        NSLog(@"[ModrinthAPI] Error: item provided to loadDetailsOfMod has no valid 'id'.");
        // Mark as loaded to prevent retry loops, but indicate failure?
        item[@"versionDetailsLoaded"] = @(YES);
        item[@"loadError"] = @"Missing Project ID";
        return;
    }

    // Prepare headers using the initialized userAgent
    NSDictionary *headers = @{@"User-Agent": self.userAgent};

    // --- 1. Load Full Project Details ---
    NSString *projectEndpoint = [NSString stringWithFormat:@"https://api.modrinth.com/v2/project/%@", projectId];
    NSLog(@"[ModrinthAPI] Fetching project details for %@ from %@", projectId, projectEndpoint);
    NSDictionary *projectDetails = [self getEndpoint:projectEndpoint params:nil headers:headers];

    // Process project details if successfully fetched and is a dictionary
    if (projectDetails && [projectDetails isKindOfClass:[NSDictionary class]]) {
        // Update Icon URL if available and different
        NSString *newIconUrl = projectDetails[@"icon_url"];
        if (newIconUrl && [newIconUrl isKindOfClass:[NSString class]] && newIconUrl.length > 0) {
            NSString *convertedIconUrl = [self convertWebPUrl:newIconUrl];
            // Only update if the URL actually changed (or wasn't present before)
            if (![item[@"imageUrl"] isEqualToString:convertedIconUrl]) {
                 item[@"imageUrl"] = convertedIconUrl;
                 NSLog(@"[ModrinthAPI] Updated icon URL for project %@ to: %@", projectId, convertedIconUrl);
            }
        }

        // Consolidate categories and additional categories, avoiding duplicates
        NSMutableSet *allCategoriesSet = [NSMutableSet set];
        // Add existing categories first if they exist and are valid
        if (item[@"categories"] && [item[@"categories"] isKindOfClass:[NSArray class]]) {
            for (id cat in item[@"categories"]) {
                if ([cat isKindOfClass:[NSString class]]) {
                    [allCategoriesSet addObject:cat];
                }
            }
        }
        // Add categories from project details
        if (projectDetails[@"categories"] && [projectDetails[@"categories"] isKindOfClass:[NSArray class]]) {
            for (id cat in projectDetails[@"categories"]) {
                if ([cat isKindOfClass:[NSString class]]) {
                    [allCategoriesSet addObject:cat];
                }
            }
        }
        // Add additional categories from project details
        if (projectDetails[@"additional_categories"] && [projectDetails[@"additional_categories"] isKindOfClass:[NSArray class]]) {
             for (id cat in projectDetails[@"additional_categories"]) {
                if ([cat isKindOfClass:[NSString class]]) {
                    [allCategoriesSet addObject:cat];
                }
            }
        }
        // Update the item's categories if the set is not empty
         if (allCategoriesSet.count > 0) {
             // Convert set to sorted array for consistent order? Optional.
             item[@"categories"] = [[allCategoriesSet allObjects] sortedArrayUsingSelector:@selector(localizedCaseInsensitiveCompare:)];
         }


        // Get client/server side requirement (convert string to boolean if possible)
        // Modrinth uses strings like "required", "optional", "unsupported"
        if (projectDetails[@"client_side"] && [projectDetails[@"client_side"] isKindOfClass:[NSString class]]) {
            item[@"client_side"] = projectDetails[@"client_side"]; // Keep the string for more info
        }
        if (projectDetails[@"server_side"] && [projectDetails[@"server_side"] isKindOfClass:[NSString class]]) {
            item[@"server_side"] = projectDetails[@"server_side"]; // Keep the string
        }

        // Get license information (can be dictionary or string)
        id licenseInfo = projectDetails[@"license"];
        if (licenseInfo && ([licenseInfo isKindOfClass:[NSDictionary class]] || [licenseInfo isKindOfClass:[NSString class]])) {
            item[@"license"] = licenseInfo;
        }
    } else if (projectDetails) {
        // Log if the response was not a dictionary as expected
        NSLog(@"[ModrinthAPI] Warning: Project details received for %@ were not in the expected dictionary format.", projectId);
    } else {
        // Log if the request failed (self.lastError should be set by getEndpoint)
        NSLog(@"[ModrinthAPI] Warning: Failed to fetch project details for %@. Error: %@", projectId, self.lastError.localizedDescription ?: @"Unknown error");
        // Do not return yet, proceed to try fetching versions
    }

    // --- 2. Load Version Data ---
    NSString *versionsEndpoint = [NSString stringWithFormat:@"https://api.modrinth.com/v2/project/%@/version", projectId];
     NSLog(@"[ModrinthAPI] Fetching versions for %@ from %@", projectId, versionsEndpoint);
    // Optionally add parameters for filtering versions (e.g., loaders, game_versions) if needed
    // Example: NSDictionary *versionParams = @{@"loaders": @"[\"fabric\"]", @"game_versions": @"[\"1.19.2\"]"};
    NSArray *versionsResponse = [self getEndpoint:versionsEndpoint params:nil headers:headers];

    // Initialize arrays for version data, even if loading fails
    NSMutableArray<NSString *> *names = [NSMutableArray new];
    NSMutableArray<NSString *> *mcNames = [NSMutableArray new];
    NSMutableArray<NSString *> *urls = [NSMutableArray new];
    NSMutableArray<NSString *> *hashes = [NSMutableArray new];
    NSMutableArray<NSNumber *> *sizes = [NSMutableArray new];

    // Check if version response is valid
    if (!versionsResponse || ![versionsResponse isKindOfClass:[NSArray class]]) {
        NSLog(@"[ModrinthAPI] Warning: No version data or invalid format received for project ID %@. Error: %@", projectId, self.lastError.localizedDescription ?: @"Unknown error");
        // Mark details as loaded even on failure to prevent retries
        item[@"versionDetailsLoaded"] = @(YES);
        item[@"loadError"] = @"Failed to load versions"; // Add specific error info
        // Assign empty arrays
        item[@"versionNames"] = names;
        item[@"mcVersionNames"] = mcNames;
        item[@"versionSizes"] = sizes;
        item[@"versionUrls"] = urls;
        item[@"versionHashes"] = hashes;
        return; // Stop processing if versions couldn't be loaded
    }

    // Process each version in the response array
    for (id versionObj in versionsResponse) {
        if (![versionObj isKindOfClass:[NSDictionary class]]) {
            NSLog(@"[ModrinthAPI] Warning: Skipping invalid version object in response for %@", projectId);
            continue;
        }
        NSDictionary *version = (NSDictionary *)versionObj;

        // Get version name (required)
        NSString *versionName = @"Unknown Version";
        if (version[@"name"] && [version[@"name"] isKindOfClass:[NSString class]]) {
            versionName = version[@"name"];
        }
        [names addObject:versionName];

        // Get compatible Minecraft versions (use the first one listed as primary)
        NSString *mcVersion = @"Unknown";
        if (version[@"game_versions"] && [version[@"game_versions"] isKindOfClass:[NSArray class]]) {
            NSArray *gameVersions = version[@"game_versions"];
            // Find the first valid string version
            for (id gv in gameVersions) {
                if ([gv isKindOfClass:[NSString class]] && ((NSString *)gv).length > 0) {
                     mcVersion = (NSString *)gv;
                     break;
                }
            }
        }
        [mcNames addObject:mcVersion];

        // Find the primary file associated with this version
        NSString *fileUrl = @"";
        NSString *fileHash = @""; // Primarily SHA1
        NSNumber *fileSize = @(0);

        if (version[@"files"] && [version[@"files"] isKindOfClass:[NSArray class]]) {
            NSArray *files = version[@"files"];
            NSDictionary *primaryFile = nil;

            // Iterate to find the file marked as primary
            for (id fileObj in files) {
                if ([fileObj isKindOfClass:[NSDictionary class]]) {
                    NSDictionary *file = (NSDictionary *)fileObj;
                    // Check for boolean primary flag
                    if (file[@"primary"] && [file[@"primary"] isKindOfClass:[NSNumber class]] && [file[@"primary"] boolValue]) {
                        primaryFile = file;
                        break;
                    }
                }
            }

            // If no primary file found, use the first valid file in the array
            if (!primaryFile) {
                 for (id fileObj in files) {
                      if ([fileObj isKindOfClass:[NSDictionary class]]) {
                           primaryFile = (NSDictionary *)fileObj; // Use the first valid one
                           break;
                      }
                 }
            }


            // Extract details from the selected file (primary or first)
            if (primaryFile) {
                // Get file size
                if (primaryFile[@"size"] && [primaryFile[@"size"] isKindOfClass:[NSNumber class]]) {
                    fileSize = primaryFile[@"size"];
                }

                // Get download URL
                if (primaryFile[@"url"] && [primaryFile[@"url"] isKindOfClass:[NSString class]]) {
                    fileUrl = primaryFile[@"url"]; // URLs should be absolute and valid
                }

                // Get hash (prefer SHA1)
                if (primaryFile[@"hashes"] && [primaryFile[@"hashes"] isKindOfClass:[NSDictionary class]]) {
                    NSDictionary *hashesDict = primaryFile[@"hashes"];
                    if (hashesDict[@"sha1"] && [hashesDict[@"sha1"] isKindOfClass:[NSString class]]) {
                        fileHash = hashesDict[@"sha1"];
                    } else if (hashesDict[@"sha512"] && [hashesDict[@"sha512"] isKindOfClass:[NSString class]]) {
                         // Log if SHA1 is missing, maybe store SHA512 if needed elsewhere
                         NSLog(@"[ModrinthAPI] Note: SHA1 hash missing for file in version %@ of project %@. SHA512 available.", versionName, projectId);
                    }
                }
            } else {
                NSLog(@"[ModrinthAPI] Warning: No valid files found for version %@ of project %@", versionName, projectId);
            }
        } else {
            NSLog(@"[ModrinthAPI] Warning: 'files' array missing or invalid for version %@ of project %@", versionName, projectId);
        }

        // Add extracted file details to the arrays
        [urls addObject:fileUrl];
        [hashes addObject:fileHash];
        [sizes addObject:fileSize];
    }

    // Update the original item dictionary with the loaded version data
    item[@"versionNames"] = names;
    item[@"mcVersionNames"] = mcNames;
    item[@"versionSizes"] = sizes;
    item[@"versionUrls"] = urls;
    item[@"versionHashes"] = hashes;
    item[@"versionDetailsLoaded"] = @(YES); // Mark details as successfully loaded
    item[@"loadError"] = [NSNull null]; // Clear any previous load error
    
    NSLog(@"[ModrinthAPI] Successfully loaded %lu versions for project %@", (unsigned long)names.count, projectId);
}


// Generic method to perform a GET request to a Modrinth API endpoint
- (id)getEndpoint:(NSString *)endpoint params:(NSDictionary *)params headers:(NSDictionary *)headers {
    // Semaphore for synchronous waiting (consider async alternatives)
    dispatch_semaphore_t completionSemaphore = dispatch_semaphore_create(0);

    // Variables to store response data and error
    __block NSData *responseData = nil;
    __block NSError *responseError = nil;
    __block NSURLResponse *urlResponse = nil;

    // Ensure the endpoint is a full URL, prefixing with base API URL if needed
    NSString *urlString = endpoint;
    if (![urlString hasPrefix:@"http"]) {
        urlString = [NSString stringWithFormat:@"https://api.modrinth.com/v2/%@", endpoint];
    }

    // Use NSURLComponents for safe URL and parameter construction
    NSURLComponents *urlComponents = [NSURLComponents componentsWithString:urlString];
    if (!urlComponents) {
         NSLog(@"[ModrinthAPI] Error: Could not create URL components from string: %@", urlString);
         self.lastError = [NSError errorWithDomain:@"ModrinthAPI" code:NSURLErrorBadURL userInfo:@{NSLocalizedDescriptionKey: @"Invalid URL structure"}];
         return nil;
    }


    // Add query parameters if provided
    if (params && params.count > 0) {
        NSMutableArray<NSURLQueryItem *> *queryItems = [urlComponents.queryItems mutableCopy] ?: [NSMutableArray array];
        for (NSString *key in params) {
            NSString *value = [params[key] description]; // Ensure value is string
            // Modrinth facets need specific encoding (brackets), avoid double encoding them.
             if ([key isEqualToString:@"facets"] || [key isEqualToString:@"loaders"] || [key isEqualToString:@"game_versions"]) {
                  [queryItems addObject:[NSURLQueryItem queryItemWithName:key value:value]]; // Pass raw value
             } else {
                  // Standard encoding for other parameters
                 [queryItems addObject:[NSURLQueryItem queryItemWithName:key value:value]];
             }
        }
        urlComponents.queryItems = queryItems;
    }

    // Create the final URL
    NSURL *url = urlComponents.URL;
    if (!url) {
        NSLog(@"[ModrinthAPI] Error: Could not create final URL from components for endpoint: %@", endpoint);
        self.lastError = [NSError errorWithDomain:@"ModrinthAPI" code:NSURLErrorBadURL userInfo:@{NSLocalizedDescriptionKey: @"Failed to construct final URL"}];
        return nil;
    }

    // Create the URL request
    NSMutableURLRequest *request = [NSMutableURLRequest requestWithURL:url];
    [request setHTTPMethod:@"GET"];
    [request setTimeoutInterval:20.0]; // Set request timeout

    // Apply headers, ensuring User-Agent is present
    if (headers) {
        for (NSString *key in headers) {
             if ([headers[key] isKindOfClass:[NSString class]]) { // Ensure header value is string
                 [request setValue:headers[key] forHTTPHeaderField:key];
             }
        }
    }
    // Ensure User-Agent is set using the instance property
    if (![request valueForHTTPHeaderField:@"User-Agent"]) {
        [request setValue:self.userAgent forHTTPHeaderField:@"User-Agent"];
    }

    // Create and start the data task
    NSURLSessionDataTask *task = [self.session dataTaskWithRequest:request completionHandler:^(NSData *data, NSURLResponse *response, NSError *error) {
        responseData = data;
        responseError = error;
        urlResponse = response;
        dispatch_semaphore_signal(completionSemaphore); // Signal completion
    }];
    [task resume];

    // Wait for completion or timeout
    long result = dispatch_semaphore_wait(completionSemaphore, dispatch_time(DISPATCH_TIME_NOW, 20 * NSEC_PER_SEC)); // Use same timeout as request

    // Handle timeout
    if (result != 0) {
        [task cancel]; // Cancel the ongoing task
        NSLog(@"[ModrinthAPI] Request timed out for URL: %@", url.absoluteString);
        self.lastError = [NSError errorWithDomain:NSURLErrorDomain
                                             code:NSURLErrorTimedOut
                                         userInfo:@{NSLocalizedDescriptionKey: @"Request timed out", @"URL": url.absoluteString}];
        return nil;
    }

    // Handle fundamental network errors
    if (responseError) {
        NSLog(@"[ModrinthAPI] Network error for URL %@: %@", url.absoluteString, responseError.localizedDescription);
        self.lastError = responseError;
        return nil;
    }

    // Check HTTP status code for errors
    NSInteger statusCode = 0;
    if ([urlResponse isKindOfClass:[NSHTTPURLResponse class]]) {
        statusCode = [(NSHTTPURLResponse *)urlResponse statusCode];
        if (statusCode < 200 || statusCode >= 300) {
            NSString *errorBody = [[NSString alloc] initWithData:responseData encoding:NSUTF8StringEncoding] ?: @"(No response body)";
            NSLog(@"[ModrinthAPI] HTTP error %ld for URL %@: %@", (long)statusCode, url.absoluteString, errorBody);
            self.lastError = [NSError errorWithDomain:@"ModrinthAPIHTTPError"
                                                 code:statusCode
                                             userInfo:@{NSLocalizedDescriptionKey: [NSString stringWithFormat:@"API request failed with HTTP status %ld", (long)statusCode], @"URL": url.absoluteString, @"ResponseBody": errorBody}];
            return nil; // Return nil on HTTP errors
        }
    }

    // Check if data was actually received
    if (!responseData || responseData.length == 0) {
        NSLog(@"[ModrinthAPI] Warning: No data received for successful request to URL: %@", url.absoluteString);
        // Treat as success but with no data, or set a specific error? Let's return nil.
        self.lastError = [NSError errorWithDomain:@"ModrinthAPI" code:2 userInfo:@{NSLocalizedDescriptionKey: @"No data received despite success status", @"URL": url.absoluteString}];
        return nil;
    }

    // Attempt to parse the response data as JSON
    NSError *jsonError = nil;
    // Use NSJSONReadingAllowFragments for flexibility, though Modrinth should return valid JSON objects/arrays
    id jsonObject = [NSJSONSerialization JSONObjectWithData:responseData options:NSJSONReadingAllowFragments error:&jsonError];

    if (jsonError) {
        // Log detailed error if JSON parsing fails
        NSString *responseDataString = [[NSString alloc] initWithData:responseData encoding:NSUTF8StringEncoding] ?: @"(Invalid encoding)";
        NSLog(@"[ModrinthAPI] JSON parsing error for URL %@: %@\nResponse Data: %@", url.absoluteString, jsonError.localizedDescription, responseDataString);
        self.lastError = jsonError;
        return nil; // Return nil on JSON parsing failure
    }

    // If everything succeeded, clear lastError and return the JSON object
    self.lastError = nil;
    return jsonObject;
}

// Compatibility method for older code that doesn't pass headers explicitly
- (id)getEndpoint:(NSString *)endpoint params:(NSDictionary *)params {
    // Forward the call to the main method, providing the standard User-Agent header
    return [self getEndpoint:endpoint params:params headers:@{@"User-Agent": self.userAgent}];
}

// Method to initiate the download process for a modpack package (.mrpack file)
- (void)downloader:(MinecraftResourceDownloadTask *)downloader submitDownloadTasksFromPackage:(NSString *)packagePath toPath:(NSString *)destPath {
    NSError *error;

    // --- 1. Open the Modpack Archive ---
    UZKArchive *archive = [[UZKArchive alloc] initWithPath:packagePath error:&error];
    if (error || !archive) {
        NSString *errorMessage = @"Failed to open modpack archive";
         if (error) errorMessage = [errorMessage stringByAppendingFormat:@": %@", error.localizedDescription];
        [downloader finishDownloadWithErrorString:errorMessage];
        return;
    }
    NSLog(@"[ModrinthAPI] Opened modpack archive: %@", packagePath);
    NSLog(@"[ModrinthAPI] Target destination path: %@", destPath);

    // --- 2. Ensure Destination Directory Exists ---
    // Use the file processing queue for directory creation
    dispatch_async(self.fileProcessingQueue, ^{
         NSError *dirError;
         [[NSFileManager defaultManager] createDirectoryAtPath:destPath
                                  withIntermediateDirectories:YES
                                                   attributes:nil
                                                        error:&dirError];
         if (dirError) {
             // Handle error on main thread for UI update
             dispatch_async(dispatch_get_main_queue(), ^{
                 [downloader finishDownloadWithErrorString:[NSString stringWithFormat:@"Failed to create destination directory %@: %@", destPath, dirError.localizedDescription]];
             });
             return; // Stop processing on this queue
         }

         // --- 3. Read Modpack Index File ---
         // Update UI status on main thread
         dispatch_async(dispatch_get_main_queue(), ^{
             [downloader.fileList addObject:@"Reading modpack index..."];
             NSProgress *indexProgress = [NSProgress progressWithTotalUnitCount:1];
             [downloader.progressList addObject:indexProgress];
             // Reset overall progress temporarily
             downloader.progress.totalUnitCount = 1;
             downloader.progress.completedUnitCount = 0;
         });


        // Try extracting index.json (newer?) then modrinth.index.json (older)
        NSData *indexData = [archive extractDataFromFile:@"index.json" error:nil];
        if (!indexData) {
            indexData = [archive extractDataFromFile:@"modrinth.index.json" error:&error];
        }

        if (!indexData) {
            NSString *errorMessage = @"Failed to find index.json or modrinth.index.json in modpack";
            if (error) errorMessage = [errorMessage stringByAppendingFormat:@". Error: %@", error.localizedDescription];
            dispatch_async(dispatch_get_main_queue(), ^{
                 [downloader finishDownloadWithErrorString:errorMessage];
            });
            return; // Stop processing
        }

        // Parse the index JSON data
        NSDictionary* indexDict = [NSJSONSerialization JSONObjectWithData:indexData options:kNilOptions error:&error];
        if (error || !indexDict || ![indexDict isKindOfClass:[NSDictionary class]]) {
            NSString *errorMessage = @"Failed to parse modpack index JSON";
            if (error) errorMessage = [errorMessage stringByAppendingFormat:@": %@", error.localizedDescription];
            dispatch_async(dispatch_get_main_queue(), ^{
                 [downloader finishDownloadWithErrorString:errorMessage];
            });
            return; // Stop processing
        }

        // --- 4. Prepare for File Downloads ---
         NSString *modpackName = indexDict[@"name"] ?: @"(Unnamed Modpack)";
         NSLog(@"[ModrinthAPI] Modpack index for '%@' parsed successfully.", modpackName);

        // Store necessary info in downloader metadata
         dispatch_async(dispatch_get_main_queue(), ^{
             if (!downloader.metadata) downloader.metadata = [NSMutableDictionary dictionary];
             downloader.metadata[@"destPath"] = destPath;
             downloader.metadata[@"retryMap"] = [NSMutableDictionary dictionary]; // For tracking retries
             // Store dependencies if they exist and are valid
             if (indexDict[@"dependencies"] && [indexDict[@"dependencies"] isKindOfClass:[NSDictionary class]]) {
                 downloader.metadata[@"modpackDependencies"] = indexDict[@"dependencies"];
             } else {
                 NSLog(@"[ModrinthAPI] Warning: 'dependencies' missing or invalid in index for '%@'.", modpackName);
                 downloader.metadata[@"modpackDependencies"] = @{}; // Ensure key exists
             }
             // Update index reading progress
             NSProgress *indexProgress = downloader.progressList.firstObject; // Assuming it's the first one
             if (indexProgress.totalUnitCount == 1) indexProgress.completedUnitCount = 1;
         });


        // Get the list of files to download
        NSArray *files = indexDict[@"files"];
        if (!files || ![files isKindOfClass:[NSArray class]] || files.count == 0) {
            NSLog(@"[ModrinthAPI] No files listed in modpack index for '%@'. Proceeding to extraction.", modpackName);
            // No files to download, go directly to extraction phase
            [self extractAndFinalizeModpack:downloader archive:archive indexDict:indexDict destPath:destPath packagePath:packagePath];
            return; // Stop download preparation
        }

        // --- 5. Initiate Downloads ---
        // Calculate total download size for progress reporting
        unsigned long long totalSize = 0;
        for (id fileObj in files) {
            if ([fileObj isKindOfClass:[NSDictionary class]]) {
                NSDictionary *indexFile = (NSDictionary *)fileObj;
                if (indexFile[@"fileSize"] && [indexFile[@"fileSize"] isKindOfClass:[NSNumber class]]) {
                    totalSize += [indexFile[@"fileSize"] unsignedLongLongValue];
                }
            }
        }

        // Update overall progress on the main thread
         dispatch_async(dispatch_get_main_queue(), ^{
             // Use total size if available and > 0, otherwise use file count
             downloader.progress.totalUnitCount = (totalSize > 0) ? totalSize : files.count;
             downloader.progress.completedUnitCount = 0;
             if (downloader.textProgress) {
                 downloader.textProgress.totalUnitCount = downloader.progress.totalUnitCount;
                 downloader.textProgress.completedUnitCount = 0;
             }
             // Add overall download status message
             NSString *overallStatus = [NSString stringWithFormat:@"Downloading %ld files...", (long)files.count];
             [downloader.fileList addObject:overallStatus];
             // Add progress object to track file count completion
             NSProgress *overallFileCountProgress = [NSProgress progressWithTotalUnitCount:files.count];
             [downloader.progressList addObject:overallFileCountProgress];
         });


        // Reset and set the pending download count
        [self.downloadCountLock lock];
        self.pendingModpackDownloads = files.count;
        [self.downloadCountLock unlock];
        NSLog(@"[ModrinthAPI] Starting download of %ld mod files for '%@'", (long)files.count, modpackName);

        // Use a dispatch group to wait for all downloads
        dispatch_group_t downloadGroup = dispatch_group_create();

        // Iterate through files and create download tasks
        for (id indexFileObj in files) {
            // Check for cancellation before processing each file
             if (downloader.progress.cancelled) {
                 NSLog(@"[ModrinthAPI] Download cancelled before processing all files.");
                 break; // Exit the loop
             }

            if (![indexFileObj isKindOfClass:[NSDictionary class]]) {
                NSLog(@"[ModrinthAPI] Skipping invalid file entry in index.");
                 [self.downloadCountLock lock];
                 self.pendingModpackDownloads--;
                 [self.downloadCountLock unlock];
                  dispatch_async(dispatch_get_main_queue(), ^{
                       NSProgress* overallFileCountProgress = downloader.progressList.lastObject; // Assume last is file count
                       if (overallFileCountProgress.totalUnitCount == files.count) overallFileCountProgress.completedUnitCount++;
                  });
                continue;
            }
            NSDictionary *indexFile = (NSDictionary *)indexFileObj;

            // Validate download URLs
            NSArray *downloadURLs = indexFile[@"downloads"];
            NSString *urlString = nil;
             if (downloadURLs && [downloadURLs isKindOfClass:[NSArray class]] && downloadURLs.count > 0) {
                  if ([downloadURLs.firstObject isKindOfClass:[NSString class]]) {
                       urlString = downloadURLs.firstObject;
                  }
             }
            if (!urlString || urlString.length == 0) {
                NSLog(@"[ModrinthAPI] File '%@' has no valid download URLs.", indexFile[@"path"] ?: @"(No Path)");
                 [self.downloadCountLock lock];
                 self.pendingModpackDownloads--;
                 [self.downloadCountLock unlock];
                  dispatch_async(dispatch_get_main_queue(), ^{
                      NSProgress* overallFileCountProgress = downloader.progressList.lastObject;
                      if (overallFileCountProgress.totalUnitCount == files.count) overallFileCountProgress.completedUnitCount++;
                  });
                continue;
            }
             NSURL *url = [NSURL URLWithString:urlString];
             if (!url) {
                  NSLog(@"[ModrinthAPI] Could not create URL from string '%@' for file '%@'", urlString, indexFile[@"path"] ?: @"(No Path)");
                  [self.downloadCountLock lock];
                  self.pendingModpackDownloads--;
                  [self.downloadCountLock unlock];
                  dispatch_async(dispatch_get_main_queue(), ^{
                      NSProgress* overallFileCountProgress = downloader.progressList.lastObject;
                      if (overallFileCountProgress.totalUnitCount == files.count) overallFileCountProgress.completedUnitCount++;
                  });
                  continue;
             }


            // Get hash (SHA1 preferred)
            NSString *sha = nil;
            if (indexFile[@"hashes"] && [indexFile[@"hashes"] isKindOfClass:[NSDictionary class]]) {
                NSDictionary *hashesDict = indexFile[@"hashes"];
                if (hashesDict[@"sha1"] && [hashesDict[@"sha1"] isKindOfClass:[NSString class]]) {
                    sha = hashesDict[@"sha1"];
                }
            }

            // Construct destination path safely
            NSString *relativePath = indexFile[@"path"];
            if (![relativePath isKindOfClass:[NSString class]] || relativePath.length == 0) {
                NSLog(@"[ModrinthAPI] File entry has invalid or missing 'path'.");
                 [self.downloadCountLock lock];
                 self.pendingModpackDownloads--;
                 [self.downloadCountLock unlock];
                  dispatch_async(dispatch_get_main_queue(), ^{
                      NSProgress* overallFileCountProgress = downloader.progressList.lastObject;
                      if (overallFileCountProgress.totalUnitCount == files.count) overallFileCountProgress.completedUnitCount++;
                  });
                continue;
            }
            // Basic path sanitization to prevent escaping destPath
            relativePath = [relativePath stringByReplacingOccurrencesOfString:@".." withString:@""];
            if ([relativePath hasPrefix:@"/"]) relativePath = [relativePath substringFromIndex:1];
            NSString *path = [destPath stringByAppendingPathComponent:relativePath];

            // Get file size
            NSUInteger size = 0;
            if (indexFile[@"fileSize"] && [indexFile[@"fileSize"] isKindOfClass:[NSNumber class]]) {
                size = [indexFile[@"fileSize"] unsignedIntegerValue];
            }

            // Create directory structure on the file processing queue
            dispatch_async(self.fileProcessingQueue, ^{
                 NSString *dirPath = [path stringByDeletingLastPathComponent];
                 NSError *dirError;
                 [[NSFileManager defaultManager] createDirectoryAtPath:dirPath
                                          withIntermediateDirectories:YES
                                                           attributes:nil
                                                                error:&dirError];
                 if (dirError) NSLog(@"[ModrinthAPI] Error creating directory %@: %@", dirPath, dirError.localizedDescription);
            });

            // Define display name and download ID
            NSString *displayName = [NSString stringWithFormat:@"Downloading %@", relativePath];
            NSString *downloadID = [NSString stringWithFormat:@"%@_%@", relativePath, sha ?: @"nohash"];
             NSLog(@"[ModrinthAPI] Preparing download: %@ to %@", displayName, path);

            // Enter the dispatch group for this file's download task
            dispatch_group_enter(downloadGroup);

            // --- Define Success and Failure Blocks ---
            void(^__block fileSuccess)(void) = nil; // Need __block for recursive use in retry
            void(^__block fileFailure)(NSError *) = nil;

            fileSuccess = ^{
                [self.downloadCountLock lock];
                self.pendingModpackDownloads--;
                NSInteger remaining = self.pendingModpackDownloads;
                [self.downloadCountLock unlock];
                NSLog(@"[ModrinthAPI] OK: %@ (%ld left)", relativePath, (long)remaining);

                // Update overall file count progress on main thread
                dispatch_async(dispatch_get_main_queue(), ^{
                    NSProgress* overallFileCountProgress = downloader.progressList.lastObject;
                    if (overallFileCountProgress.totalUnitCount == files.count) overallFileCountProgress.completedUnitCount++;
                });
                dispatch_group_leave(downloadGroup); // Leave group on success
            };

            fileFailure = ^(NSError *failureError){
                 NSMutableDictionary *retryMap = downloader.metadata[@"retryMap"];
                 int retryCount = [retryMap[downloadID] intValue]; // Defaults to 0 if nil

                 if (retryCount < 1 && !downloader.progress.cancelled) { // Allow 1 retry
                     NSLog(@"[ModrinthAPI] Retrying download for %@ after error: %@", relativePath, failureError.localizedDescription);
                     retryMap[downloadID] = @(retryCount + 1);

                     // Create and queue the retry task
                      NSURLSessionDownloadTask *retryTask = [downloader createDownloadTask:url.absoluteString
                                                                                   size:size sha:sha altName:[displayName stringByAppendingString:@" (Retry)"]
                                                                                 toPath:path success:fileSuccess failure:fileFailure]; // Recursive call to failure block

                     if (!retryTask && !downloader.progress.cancelled) {
                         // If retry task creation fails immediately
                          NSLog(@"[ModrinthAPI] Failed to create retry task for %@", relativePath);
                          [self.downloadCountLock lock]; self.pendingModpackDownloads--; [self.downloadCountLock unlock];
                           dispatch_async(dispatch_get_main_queue(), ^{
                               NSProgress* overallFileCountProgress = downloader.progressList.lastObject;
                               if (overallFileCountProgress.totalUnitCount == files.count) overallFileCountProgress.completedUnitCount++;
                           });
                           dispatch_group_leave(downloadGroup);
                     }
                 } else {
                     // Max retries reached or cancelled
                      if (!downloader.progress.cancelled) {
                           NSLog(@"[ModrinthAPI] FAIL: %@ (Error: %@)", relativePath, failureError.localizedDescription);
                      } else {
                           NSLog(@"[ModrinthAPI] CANCELLED: %@", relativePath);
                      }
                      [self.downloadCountLock lock]; self.pendingModpackDownloads--; [self.downloadCountLock unlock];
                       dispatch_async(dispatch_get_main_queue(), ^{
                           NSProgress* overallFileCountProgress = downloader.progressList.lastObject;
                           if (overallFileCountProgress.totalUnitCount == files.count) overallFileCountProgress.completedUnitCount++;
                       });
                       dispatch_group_leave(downloadGroup); // Leave group on final failure or cancellation
                 }
            };


            // Create the initial download task
             NSURLSessionDownloadTask *task = [downloader createDownloadTask:url.absoluteString
                                                                       size:size sha:sha altName:displayName
                                                                     toPath:path success:fileSuccess failure:fileFailure];

            // Handle immediate task creation failure or cancellation
            if (!task) {
                if (downloader.progress.cancelled) {
                     NSLog(@"[ModrinthAPI] Download cancelled during task creation for: %@", relativePath);
                } else {
                     NSLog(@"[ModrinthAPI] Failed to create initial download task for: %@", relativePath);
                }
                dispatch_group_leave(downloadGroup); // Leave group if task creation failed

                 // Decrement pending count if not cancelled (failure case)
                 if (!downloader.progress.cancelled) {
                      [self.downloadCountLock lock]; self.pendingModpackDownloads--; [self.downloadCountLock unlock];
                      dispatch_async(dispatch_get_main_queue(), ^{
                          NSProgress* overallFileCountProgress = downloader.progressList.lastObject;
                          if (overallFileCountProgress.totalUnitCount == files.count) overallFileCountProgress.completedUnitCount++;
                      });
                 }
                 if (downloader.progress.cancelled) {
                      break; // Exit loop if cancelled
                 }
            }
        } // End of file iteration loop


        // --- 6. Wait for Downloads and Finalize ---
        // If cancelled during loop, don't wait
         if (downloader.progress.cancelled) {
              NSLog(@"[ModrinthAPI] Download process cancelled, skipping wait and finalization.");
              // Clean up group? May not be necessary.
              return; // Stop processing
         }

         NSLog(@"[ModrinthAPI] All download tasks queued. Waiting for completion...");
         // Wait for all tasks in the group to complete (success or failure) with timeout
         dispatch_time_t timeout = dispatch_time(DISPATCH_TIME_NOW, (int64_t)(600 * NSEC_PER_SEC)); // 10 minute timeout
         long waitResult = dispatch_group_wait(downloadGroup, timeout);

         // Check for cancellation again after waiting
          if (downloader.progress.cancelled) {
               NSLog(@"[ModrinthAPI] Download process cancelled after waiting for tasks.");
               return; // Stop processing
          }


         if (waitResult != 0) {
             NSLog(@"[ModrinthAPI] Warning: Download group timed out after 10 minutes. Some files might be missing.");
             // Potentially update UI to indicate timeout or partial success
         } else {
             NSLog(@"[ModrinthAPI] All download tasks finished (completed or failed).");
         }

         // Proceed to extraction and finalization regardless of individual file failures, unless cancelled.
         NSLog(@"[ModrinthAPI] Proceeding to extraction and finalization...");
         [self extractAndFinalizeModpack:downloader archive:archive indexDict:indexDict destPath:destPath packagePath:packagePath];

    }); // End of initial file processing queue dispatch
}


// Method to extract overrides and finalize the modpack installation
- (void)extractAndFinalizeModpack:(MinecraftResourceDownloadTask *)downloader
                          archive:(UZKArchive *)archive
                        indexDict:(NSDictionary *)indexDict
                         destPath:(NSString *)destPath
                      packagePath:(NSString *)packagePath {
    // Update UI status on main thread
    dispatch_async(dispatch_get_main_queue(), ^{
        [downloader.fileList addObject:@"Extracting modpack overrides..."];
        NSProgress *extractionProgress = [NSProgress progressWithTotalUnitCount:100];
        [downloader.progressList addObject:extractionProgress];
        // Update overall progress minimally for extraction phase
        // downloader.progress.completedUnitCount += 1; // Or adjust totalUnitCount earlier
    });

    NSLog(@"[ModrinthAPI] Starting extraction phase for modpack: %@", indexDict[@"name"] ?: @"(Unnamed)");

    // Perform extraction on the file processing queue
    dispatch_async(self.fileProcessingQueue, ^{
        NSProgress *extractionProgress = nil; // Find progress object later if needed on main thread

        // --- 1. Extract Overrides ---
        NSLog(@"[ModrinthAPI] Extracting 'overrides' directory...");
        [self extractDirectoryFromArchive:archive directory:@"overrides" toPath:destPath progress:nil]; // Progress handled granularly if needed
        dispatch_async(dispatch_get_main_queue(), ^{ // Update progress on main thread
            NSProgress* ep = downloader.progressList.lastObject;
             if (ep.totalUnitCount == 100) ep.completedUnitCount = 50;
        });

        // --- 2. Extract Client Overrides ---
        NSLog(@"[ModrinthAPI] Extracting 'client-overrides' directory...");
        [self extractDirectoryFromArchive:archive directory:@"client-overrides" toPath:destPath progress:nil];
        dispatch_async(dispatch_get_main_queue(), ^{
            NSProgress* ep = downloader.progressList.lastObject;
             if (ep.totalUnitCount == 100) ep.completedUnitCount = 75;
        });

        // --- 3. Extract Server Overrides (Optional, for completeness) ---
        // NSLog(@"[ModrinthAPI] Extracting 'server-overrides' directory (if present)...");
        // [self extractDirectoryFromArchive:archive directory:@"server-overrides" toPath:destPath progress:nil];
        // No progress update for server overrides

        // --- 4. Delete Modpack Archive ---
        NSError *removeError;
        [[NSFileManager defaultManager] removeItemAtPath:packagePath error:&removeError];
        if (removeError) {
            NSLog(@"[ModrinthAPI] Warning: Failed to delete modpack archive %@: %@", packagePath, removeError.localizedDescription);
        } else {
            NSLog(@"[ModrinthAPI] Deleted modpack archive: %@", packagePath);
        }
        dispatch_async(dispatch_get_main_queue(), ^{
            NSProgress* ep = downloader.progressList.lastObject;
             if (ep.totalUnitCount == 100) ep.completedUnitCount = 90;
        });

        // --- 5. Handle Dependencies (Download Loader JSON if needed) ---
        NSDictionary *dependencies = downloader.metadata[@"modpackDependencies"]; // Retrieved earlier
        if (!dependencies || ![dependencies isKindOfClass:[NSDictionary class]]) {
            NSLog(@"[ModrinthAPI] No valid dependencies found, finalizing without loader JSON download.");
            dispatch_async(dispatch_get_main_queue(), ^{
                 NSProgress* ep = downloader.progressList.lastObject;
                 if (ep.totalUnitCount == 100) ep.completedUnitCount = 100;
                 [self finalizeModpackInstallation:downloader indexDict:indexDict depInfo:@{} destPath:destPath];
            });
            return; // Exit queue block
        }

        NSDictionary<NSString *, NSString *> *depInfo = [ModpackUtils infoForDependencies:dependencies];
        NSString *depJsonUrl = depInfo[@"json"];
        NSString *depVersionId = depInfo[@"id"];

        if (depJsonUrl && [depJsonUrl isKindOfClass:[NSString class]] && depVersionId && [depVersionId isKindOfClass:[NSString class]]) {
            // Update UI status on main thread
            dispatch_async(dispatch_get_main_queue(), ^{
                 [downloader.fileList addObject:@"Downloading loader JSON..."];
                 NSProgress *jsonProgress = [NSProgress progressWithTotalUnitCount:100];
                 [downloader.progressList addObject:jsonProgress];
            });

             // Construct path safely
             NSString *gameDir = [NSString stringWithUTF8String:getenv("POJAV_GAME_DIR") ?: ""];
             if (gameDir.length == 0) {
                  NSLog(@"[ModrinthAPI] Error: POJAV_GAME_DIR not set. Cannot download loader JSON.");
                  dispatch_async(dispatch_get_main_queue(), ^{
                       [downloader finishDownloadWithErrorString:@"Internal Error: Game directory not found."];
                  });
                  return; // Exit queue block
             }
             NSString *jsonPath = [NSString stringWithFormat:@"%@/versions/%@/%@.json", gameDir, depVersionId, depVersionId];
             NSString *jsonDir = [jsonPath stringByDeletingLastPathComponent];

             // Create directory on file queue
             NSError *jsonDirError;
             [[NSFileManager defaultManager] createDirectoryAtPath:jsonDir withIntermediateDirectories:YES attributes:nil error:&jsonDirError];
             if (jsonDirError) NSLog(@"[ModrinthAPI] Error creating directory for loader JSON %@: %@", jsonDir, jsonDirError.localizedDescription);


             // Define completion blocks for JSON download
             void(^jsonSuccess)(void) = ^{
                  NSLog(@"[ModrinthAPI] Loader JSON downloaded successfully.");
                  dispatch_async(dispatch_get_main_queue(), ^{
                      NSProgress* jp = downloader.progressList.lastObject; if(jp.totalUnitCount == 100) jp.completedUnitCount = 100;
                      NSProgress* ep = downloader.progressList[downloader.progressList.count - 2]; if(ep.totalUnitCount == 100) ep.completedUnitCount = 100;
                      [self finalizeModpackInstallation:downloader indexDict:indexDict depInfo:depInfo destPath:destPath];
                  });
             };
             void(^jsonFailure)(NSError *) = ^(NSError *jsonError){
                  NSLog(@"[ModrinthAPI] Failed to download loader JSON %@: %@", depJsonUrl, jsonError.localizedDescription);
                  // Proceed with finalization even if JSON download fails, profile will use default/fallback version ID
                  dispatch_async(dispatch_get_main_queue(), ^{
                      NSProgress* jp = downloader.progressList.lastObject; if(jp.totalUnitCount == 100) jp.completedUnitCount = 100;
                      NSProgress* ep = downloader.progressList[downloader.progressList.count - 2]; if(ep.totalUnitCount == 100) ep.completedUnitCount = 100;
                      // Maybe add warning to downloader status?
                      [self finalizeModpackInstallation:downloader indexDict:indexDict depInfo:depInfo destPath:destPath]; // Pass original depInfo
                  });
             };

             // Create and start download task for JSON
              NSURLSessionDownloadTask *task = [downloader createDownloadTask:depJsonUrl size:0 sha:nil
                                                                      altName:@"Downloading loader JSON..." toPath:jsonPath
                                                                      success:jsonSuccess failure:jsonFailure];
             if (!task && !downloader.progress.cancelled) {
                 NSLog(@"[ModrinthAPI] Failed to create download task for loader JSON.");
                 jsonFailure([NSError errorWithDomain:@"ModrinthAPI" code:3 userInfo:@{NSLocalizedDescriptionKey: @"Failed to create loader JSON download task"}]);
             }

        } else {
            // No valid dependency JSON URL found
            NSLog(@"[ModrinthAPI] No loader JSON specified in dependencies, finalizing installation.");
            dispatch_async(dispatch_get_main_queue(), ^{
                 NSProgress* ep = downloader.progressList.lastObject; // Extraction progress
                 if (ep.totalUnitCount == 100) ep.completedUnitCount = 100;
                 [self finalizeModpackInstallation:downloader indexDict:indexDict depInfo:depInfo ?: @{} destPath:destPath]; // Use depInfo or empty dict
            });
        }
    }); // End of file processing queue dispatch
}


// Helper method to extract a specific directory from the archive
- (void)extractDirectoryFromArchive:(UZKArchive *)archive directory:(NSString *)directoryName toPath:(NSString *)destPath progress:(NSProgress *)progress {
    // Validate inputs
    if (!archive || !directoryName || directoryName.length == 0 || !destPath) {
        NSLog(@"[ModrinthAPI] Invalid arguments for extractDirectoryFromArchive.");
        return;
    }

    NSError *error = nil;
    // Use the utility function, assuming it handles directory traversal and file writing safely
     NSLog(@"[ModrinthAPI] Extracting directory '%@' from archive to '%@'", directoryName, destPath);
    BOOL success = [ModpackUtils archive:archive extractDirectory:directoryName toPath:destPath error:&error];

    if (!success) {
         // Log the error, ModpackUtils should provide details if possible
         NSLog(@"[ModrinthAPI] Failed to extract directory '%@': %@", directoryName, error ? error.localizedDescription : @"Unknown error from ModpackUtils");
         // Decide if this failure is critical. For overrides, it might be.
         // Optionally update progress to indicate failure for this step?
    } else {
         NSLog(@"[ModrinthAPI] Successfully extracted directory '%@'.", directoryName);
         // Optionally update progress on the main thread if provided
         if (progress) {
             dispatch_async(dispatch_get_main_queue(), ^{
                 // Increment progress, ensuring it doesn't exceed total
                 // Adjust increment based on expected work for this directory
                 progress.completedUnitCount = MIN(progress.completedUnitCount + 20, progress.totalUnitCount);
             });
         }
    }
}

// Method to create the profile, save it, and trigger Forge/NeoForge check
- (void)finalizeModpackInstallation:(MinecraftResourceDownloadTask *)downloader
                          indexDict:(NSDictionary *)indexDict
                            depInfo:(NSDictionary *)depInfo
                           destPath:(NSString *)destPath {
    // Ensure this crucial step runs on the main thread for profile saving and UI updates
    dispatch_async(dispatch_get_main_queue(), ^{
        // --- 1. Update UI Status ---
        [downloader.fileList addObject:@"Creating modpack profile..."];
        NSProgress *setupProgress = [NSProgress progressWithTotalUnitCount:100];
        [downloader.progressList addObject:setupProgress];
        setupProgress.completedUnitCount = 10; // Start setup progress

        // --- 2. Determine Profile Name ---
        NSString *profileName = indexDict[@"name"];
        if (!profileName || ![profileName isKindOfClass:[NSString class]] || profileName.length == 0) {
            profileName = [destPath lastPathComponent]; // Use directory name as fallback
            NSLog(@"[ModrinthAPI] Using directory name as profile name: %@", profileName);
        }
        // Consider sanitizing profileName if it might contain invalid characters for filenames/profiles

        // --- 3. Determine Relative gameDir ---
        NSString *gameDir = nil;
        NSString *pojHome = [NSString stringWithUTF8String:getenv("POJAV_HOME") ?: ""];
        NSString *gameDirPref = getPrefObject(@"general.game_directory") ?: @"default"; // Use 'default' or handle nil pref
         NSString *instancesBasePath = [pojHome stringByAppendingPathComponent:@"instances"];
         NSString *expectedPrefix = [instancesBasePath stringByAppendingPathComponent:gameDirPref];

         // Check if destPath is within the standard instances structure relative to the game_directory preference
         if ([destPath hasPrefix:expectedPrefix] && destPath.length > expectedPrefix.length) {
             // Calculate relative path from the *preference* subdirectory
             gameDir = [destPath substringFromIndex:expectedPrefix.length];
             if ([gameDir hasPrefix:@"/"]) gameDir = [gameDir substringFromIndex:1]; // Remove leading slash
             NSLog(@"[ModrinthAPI] Calculated relative gameDir based on preference '%@': %@", gameDirPref, gameDir);
         } else {
             // Fallback: If destPath is outside the standard structure, create a unique directory name within the preference folder
             NSLog(@"[ModrinthAPI] Warning: destPath '%@' not within expected structure '%@'. Using unique name.", destPath, expectedPrefix);
             // We need a way to create the unique name relative to gameDirPref
             // Example: gameDir = [NSString stringWithFormat:@"%@/%@", gameDirPref, [PLProfiles uniqueGameDirForProfileName:profileName]]; // Needs adjustment
             // For now, let's assume PLProfiles creates it relative to instances/
              gameDir = [PLProfiles uniqueGameDirForProfileName:profileName]; // This likely puts it in instances/uniqueName
              // If it should be instances/gameDirPref/uniqueName, adjust PLProfiles or logic here.
              NSLog(@"[ModrinthAPI] Using unique profile gameDir (relative to instances): %@", gameDir);
         }
        setupProgress.completedUnitCount = 50;

        // --- 4. Get Loader Version ID ---
        NSString *loaderVersionId = depInfo[@"id"];
        if (!loaderVersionId || ![loaderVersionId isKindOfClass:[NSString class]] || loaderVersionId.length == 0) {
            NSLog(@"[ModrinthAPI] Warning: Loader version ID missing from depInfo. Using 'latest-release'.");
            loaderVersionId = @"latest-release"; // Default fallback
        }

        // --- 5. Create Profile Dictionary ---
        NSLog(@"[ModrinthAPI] Creating profile '%@' with gameDir '%@' and version '%@'", profileName, gameDir, loaderVersionId);
        NSMutableDictionary *newProfile = [@{
            @"name": profileName,
            @"gameDir": gameDir, // Relative path determined above
            @"lastVersionId": loaderVersionId,
            // Add any other necessary default profile keys/values here
            @"created": [NSDate date], // Track creation date
            @"type": @"custom" // Mark as custom profile
        } mutableCopy];
        setupProgress.completedUnitCount = 75;

        // --- 6. Add Profile Icon ---
        NSString *tmpIconPath = [NSTemporaryDirectory() stringByAppendingPathComponent:@"icon.png"];
        NSData *iconData = [NSData dataWithContentsOfFile:tmpIconPath];
        if (iconData && iconData.length > 0) {
            NSString *base64Icon = [iconData base64EncodedStringWithOptions:0];
            if (base64Icon) {
                newProfile[@"icon"] = [NSString stringWithFormat:@"data:image/png;base64,%@", base64Icon];
            } else {
                NSLog(@"[ModrinthAPI] Warning: Failed to base64 encode profile icon data.");
            }
            // Clean up temporary icon file
            [[NSFileManager defaultManager] removeItemAtPath:tmpIconPath error:nil];
        }

        // --- 7. Save Profile ---
        // Ensure PLProfiles exists and profiles dictionary is initialized
        if (!PLProfiles.current.profiles) {
            PLProfiles.current.profiles = [NSMutableDictionary dictionary];
        }
        PLProfiles.current.profiles[profileName] = newProfile; // Add or replace profile
        PLProfiles.current.selectedProfileName = profileName; // Select the new profile

        if (![PLProfiles.current save]) {
            NSLog(@"[ModrinthAPI] CRITICAL ERROR: Failed to save profiles after adding modpack '%@'!", profileName);
            showDialog(@"Save Error", @"Failed to save the new modpack profile. Please check storage space or restart the app.");
            // Potentially revert profile changes in memory?
            // [PLProfiles.current.profiles removeObjectForKey:profileName];
            // Consider how to handle this failure robustly.
        } else {
             NSLog(@"[ModrinthAPI] Profile '%@' saved successfully.", profileName);
        }
        setupProgress.completedUnitCount = 100;

        // --- 8. Update Downloader Status ---
        if (!downloader.metadata) downloader.metadata = [NSMutableDictionary dictionary];
        downloader.metadata[@"isModpackInstall"] = @YES;
        downloader.metadata[@"allTasksComplete"] = @YES;
        downloader.metadata[@"profileName"] = profileName;

        // Mark overall progress complete
        downloader.progress.completedUnitCount = downloader.progress.totalUnitCount;
        if (downloader.textProgress) downloader.textProgress.completedUnitCount = downloader.textProgress.totalUnitCount;

        // Add "Complete" status message
        [downloader.fileList addObject:@"Complete"];
        NSProgress *completeProgress = [NSProgress progressWithTotalUnitCount:1];
        completeProgress.completedUnitCount = 1;
        [downloader.progressList addObject:completeProgress];

        // --- 9. Signal Download Completion ---
         NSLog(@"[ModrinthAPI] Modpack installation process finished for '%@'.", profileName);
         // This should notify the UI that the entire process (including setup) is done
         [downloader finishDownloadWithSuccess];

        // --- 10. Check for Forge/NeoForge ---
         NSDictionary *dependencies = indexDict[@"dependencies"];
         if (dependencies && [dependencies isKindOfClass:[NSDictionary class]]) {
              [self checkAndInstallForge:downloader withDependencies:dependencies profileName:profileName];
         } else {
              NSLog(@"[ModrinthAPI] No dependencies found in index, skipping Forge/NeoForge check.");
         }
    }); // End main thread dispatch
}


// Method to check if Forge/NeoForge is needed and prompt for installation
- (void)checkAndInstallForge:(MinecraftResourceDownloadTask *)downloader
            withDependencies:(NSDictionary *)dependencies
                 profileName:(NSString *)profileName {
    // This method involves UI interaction (UIAlertController), so it MUST run on the main thread.
    // It's called from finalizeModpackInstallation which already dispatches to main thread.

    // Validate dependencies
    if (!dependencies || ![dependencies isKindOfClass:[NSDictionary class]]) {
        NSLog(@"[ModrinthAPI] Invalid dependencies provided for Forge check.");
        return;
    }

    // Extract required loader versions
    NSString *forgeVersion = dependencies[@"forge"];
    NSString *neoForgeVersion = dependencies[@"neoforge"];
    NSString *minecraftVersion = dependencies[@"minecraft"];

    // Ensure they are strings
    if (forgeVersion && ![forgeVersion isKindOfClass:[NSString class]]) forgeVersion = nil;
    if (neoForgeVersion && ![neoForgeVersion isKindOfClass:[NSString class]]) neoForgeVersion = nil;
    if (!minecraftVersion || ![minecraftVersion isKindOfClass:[NSString class]]) {
        NSLog(@"[ModrinthAPI] Cannot check for Forge/NeoForge: Minecraft version missing or invalid in dependencies.");
        return; // Cannot proceed without MC version
    }

    // Determine which loader is needed (if any)
    NSString *vendor = nil;
    NSString *loaderVersion = nil;
    if (forgeVersion) {
        vendor = @"Forge";
        loaderVersion = forgeVersion;
    } else if (neoForgeVersion) {
        vendor = @"NeoForge";
        loaderVersion = neoForgeVersion;
    } else {
        NSLog(@"[ModrinthAPI] No Forge or NeoForge dependency specified for profile '%@'.", profileName);
        return; // Neither loader is required
    }

    // Construct the expected full version ID (e.g., 1.19.2-forge-43.2.0 or 1.20.1-neoforge-47.1.80)
    // Note: Convention might vary, especially for NeoForge. Adjust as needed.
    NSString *fullVersionId = [NSString stringWithFormat:@"%@-%@-%@", minecraftVersion, [vendor lowercaseString], loaderVersion];
     // Or maybe just: [NSString stringWithFormat:@"%@-%@", minecraftVersion, loaderVersion] for Forge?
     // Or maybe NeoForge uses its own scheme? Let's assume MC-Vendor-Loader format for now.
     // Example NeoForge version from Modrinth might be "47.1.80", need to combine with MC version.
     // Let's refine based on actual installed version names:
     if ([vendor isEqualToString:@"Forge"]) {
         fullVersionId = [NSString stringWithFormat:@"%@-%@", minecraftVersion, loaderVersion]; // Standard Forge naming
     } else { // NeoForge - Naming can be complex (e.g., just version, or mc-version)
         // Let's try the common pattern seen in launchers:
         fullVersionId = [NSString stringWithFormat:@"%@-%@", minecraftVersion, loaderVersion]; // Assuming NeoForge also follows this
         // If this fails, might need lookup logic based on metadata.
     }


    // Check if this version directory already exists
    NSString *gameDir = [NSString stringWithUTF8String:getenv("POJAV_GAME_DIR") ?: ""];
    if (gameDir.length == 0) {
        NSLog(@"[ModrinthAPI] Error: POJAV_GAME_DIR not set. Cannot check for existing loader installation.");
        return;
    }
    NSString *versionPath = [NSString stringWithFormat:@"%@/versions/%@", gameDir, fullVersionId];
    BOOL isDir = NO;
    if ([[NSFileManager defaultManager] fileExistsAtPath:versionPath isDirectory:&isDir] && isDir) {
        NSLog(@"[ModrinthAPI] Required loader '%@' seems to be already installed at: %@", fullVersionId, versionPath);
        // Ensure the profile uses this version ID
         PLProfiles *profiles = PLProfiles.current;
         NSMutableDictionary *profile = profiles.profiles[profileName];
         if (profile && ![profile[@"lastVersionId"] isEqualToString:fullVersionId]) {
              NSLog(@"[ModrinthAPI] Updating profile '%@' lastVersionId to '%@'.", profileName, fullVersionId);
              profile[@"lastVersionId"] = fullVersionId;
              [profiles save];
         }
        return; // Already installed
    }

    // --- Loader Not Found - Prompt User ---
    NSString *alertTitle = [NSString stringWithFormat:@"%@ Installation Required", vendor];
    NSString *alertMessage = [NSString stringWithFormat:@"This modpack needs %@ %@ for Minecraft %@. It's not installed.\n\nInstall it now?", vendor, loaderVersion, minecraftVersion];

    UIAlertController *alert = [UIAlertController alertControllerWithTitle:alertTitle message:alertMessage preferredStyle:UIAlertControllerStyleAlert];

    // --- "Yes" Action ---
    [alert addAction:[UIAlertAction actionWithTitle:@"Install Now" style:UIAlertActionStyleDefault handler:^(UIAlertAction * _Nonnull action) {
        // Determine Maven URL and filename format
        NSString *mavenUrlFormat;
        NSString *installerFilenameFormat;

        if ([vendor isEqualToString:@"Forge"]) {
            // Forge: net/minecraftforge/forge/{mcVersion}-{forgeVersion}/forge-{mcVersion}-{forgeVersion}-installer.jar
            mavenUrlFormat = @"https://maven.minecraftforge.net/net/minecraftforge/forge/%1$@-%2$@/forge-%1$@-%2$@-installer.jar";
             installerFilenameFormat = @"forge-%1$@-%2$@-installer.jar";
        } else { // NeoForge
            // NeoForge: releases/net/neoforged/neoforge/{loaderVersion}/neoforge-{loaderVersion}-installer.jar (newer?)
            // Or: releases/net/neoforged/neoforge/{mcVersion}-{loaderVersion}/neoforge-{mcVersion}-{loaderVersion}-installer.jar (older?)
            // Let's try the MC-Version format first as it's more explicit
             mavenUrlFormat = @"https://maven.neoforged.net/releases/net/neoforged/neoforge/%1$@-%2$@/neoforge-%1$@-%2$@-installer.jar";
             installerFilenameFormat = @"neoforge-%1$@-%2$@-installer.jar";
             // Need a fallback if this 404s, maybe try just {loaderVersion}?
        }

        NSString *installerUrlString = [NSString stringWithFormat:mavenUrlFormat, minecraftVersion, loaderVersion];
        NSString *installerFilename = [NSString stringWithFormat:installerFilenameFormat, minecraftVersion, loaderVersion];
        NSString *outPath = [NSTemporaryDirectory() stringByAppendingPathComponent:installerFilename];

        NSLog(@"[ModrinthAPI] Attempting to download %@ installer from: %@", vendor, installerUrlString);

        // Find the LauncherNavigationController for UI updates
         LauncherNavigationController *navVC = findLauncherNavigationController();
         if (!navVC) {
              NSLog(@"[ModrinthAPI] Error: Could not find LauncherNavigationController to manage installer download UI.");
              showDialog(@"UI Error", @"Cannot start installer download: Main navigation interface not found.");
              return;
         }

        // Setup UI: Disable interaction, show progress
         [navVC setInteractionEnabled:NO forDownloading:YES];
         navVC.progressText.text = [NSString stringWithFormat:@"Downloading %@...", vendor];
         navVC.progressViewMain.hidden = NO;
         navVC.progressViewMain.progress = 0.0f;

        // Create download request
        NSURL *installerUrl = [NSURL URLWithString:installerUrlString];
         if (!installerUrl) {
              NSLog(@"[ModrinthAPI] Error: Invalid installer URL: %@", installerUrlString);
              showDialog(@"Download Error", @"Could not create a valid URL for the installer.");
              [navVC setInteractionEnabled:YES forDownloading:NO]; // Reset UI
              navVC.progressViewMain.hidden = YES; navVC.progressText.text = nil;
              return;
         }
         NSMutableURLRequest *request = [NSMutableURLRequest requestWithURL:installerUrl];
        [request setValue:self.userAgent forHTTPHeaderField:@"User-Agent"];

        // Create download manager and task
        AFURLSessionManager *manager = [[AFURLSessionManager alloc] initWithSessionConfiguration:[NSURLSessionConfiguration defaultSessionConfiguration]];
        NSURLSessionDownloadTask *downloadTask = [manager downloadTaskWithRequest:request progress:^(NSProgress * _Nonnull downloadProgress) {
            dispatch_async(dispatch_get_main_queue(), ^{ // Update UI on main thread
                navVC.progressViewMain.progress = downloadProgress.fractionCompleted;
            });
        } destination:^NSURL *(NSURL *targetPath, NSURLResponse *response) {
            [[NSFileManager defaultManager] removeItemAtPath:outPath error:nil]; // Remove existing file
            return [NSURL fileURLWithPath:outPath];
        } completionHandler:^(NSURLResponse *response, NSURL *filePath, NSError *error) {
            dispatch_async(dispatch_get_main_queue(), ^{ // Handle completion on main thread
                // Reset UI state
                 [navVC setInteractionEnabled:YES forDownloading:NO];
                 navVC.progressViewMain.hidden = YES;
                 navVC.progressText.text = nil;

                 NSInteger statusCode = 0;
                 if ([response isKindOfClass:[NSHTTPURLResponse class]]) statusCode = ((NSHTTPURLResponse*)response).statusCode;

                 if (error || statusCode >= 400 || !filePath || ![[NSFileManager defaultManager] fileExistsAtPath:filePath.path]) {
                     NSString *errorMessage = error.localizedDescription ?: @"Unknown download error";
                      if (statusCode == 404) {
                           errorMessage = [NSString stringWithFormat:@"Installer not found (404). The required version (%@ %@) might not exist for MC %@.", vendor, loaderVersion, minecraftVersion];
                           NSLog(@"[ModrinthAPI] Installer download failed: 404 Not Found for URL %@", installerUrlString);
                      } else if (statusCode >= 400) {
                           errorMessage = [NSString stringWithFormat:@"Download failed with HTTP status %ld.", (long)statusCode];
                           NSLog(@"[ModrinthAPI] Installer download failed: HTTP %ld for URL %@", (long)statusCode, installerUrlString);
                      } else if (error) {
                           NSLog(@"[ModrinthAPI] Installer download failed: %@", error);
                      } else {
                           errorMessage = @"Installer file missing after download.";
                           NSLog(@"[ModrinthAPI] Installer download finished but file is missing at: %@", filePath.path);
                      }
                      showDialog(@"Download Failed", errorMessage);
                     return;
                 }

                 NSLog(@"[ModrinthAPI] %@ installer downloaded successfully to: %@", vendor, filePath.path);
                 NSLog(@"[ModrinthAPI] Launching installer GUI...");

                 // Launch the Java installer GUI
                 // Pass YES to automatically attempt 'Enter' for client install
                 [navVC enterModInstallerWithPath:filePath.path hitEnterAfterWindowShown:YES];

                 // Update profile's lastVersionId AFTER installer finishes successfully?
                 // The installer creates the version folder, so we can update the profile now
                 // assuming the user completes the installation.
                  PLProfiles *profiles = PLProfiles.current;
                  NSMutableDictionary *profile = profiles.profiles[profileName];
                  if (profile && ![profile[@"lastVersionId"] isEqualToString:fullVersionId]) {
                       NSLog(@"[ModrinthAPI] Setting profile '%@' lastVersionId to '%@' post-installer-launch.", profileName, fullVersionId);
                       profile[@"lastVersionId"] = fullVersionId;
                       [profiles save];
                  }
            }); // End completion handler main thread dispatch
        }];
        [downloadTask resume]; // Start the download
    }]];

    // --- "No" Action ---
    [alert addAction:[UIAlertAction actionWithTitle:@"Later" style:UIAlertActionStyleCancel handler:^(UIAlertAction * _Nonnull action) {
        NSLog(@"[ModrinthAPI] User deferred %@ installation.", vendor);
        showDialog(@"Installation Deferred", [NSString stringWithFormat:@"The modpack may not work correctly without %@. You can install it manually later.", vendor]);
    }]];

    // --- Present Alert ---
    UIViewController *presentingVC = findTopViewController(); // Helper to find the topmost VC
    if (presentingVC) {
        [presentingVC presentViewController:alert animated:YES completion:nil];
    } else {
        NSLog(@"[ModrinthAPI] Error: Could not find a view controller to present the loader installation alert.");
        // Fallback: show a basic dialog?
        showDialog(alertTitle, alertMessage); // Less ideal, but informs the user
    }
}


// Method to trigger the modpack installation flow via NotificationCenter
- (void)installModpackFromDetail:(NSDictionary *)modDetail atIndex:(NSUInteger)selectedVersion {
    // Validate input
    if (!modDetail || ![modDetail isKindOfClass:[NSDictionary class]]) {
        NSLog(@"[ModrinthAPI] Error: Invalid modDetail dictionary provided to installModpackFromDetail.");
        // Show error to user? Depends on context how this is called.
        showDialog(@"Installation Error", @"Cannot start installation: Invalid modpack details.");
        return;
    }
    // Optional: Validate selectedVersion index against arrays in modDetail if they exist at this point
     NSArray* versionUrls = modDetail[@"versionUrls"];
     if (versionUrls && [versionUrls isKindOfClass:[NSArray class]] && selectedVersion >= versionUrls.count) {
          NSLog(@"[ModrinthAPI] Error: selectedVersion index %lu out of bounds for %lu versions.", (unsigned long)selectedVersion, (unsigned long)versionUrls.count);
          showDialog(@"Installation Error", @"Cannot start installation: Invalid version selected.");
          return;
     }


    NSLog(@"[ModrinthAPI] Posting notification to install modpack '%@', version index %lu", modDetail[@"title"] ?: @"(No Title)", (unsigned long)selectedVersion);

    // Prepare user info dictionary
    NSDictionary* userInfo = @{
        @"detail": modDetail,           // Pass the full modpack detail dictionary
        @"index": @(selectedVersion)    // Pass the index of the selected version
    };

    // Post the notification on the main thread as it will likely trigger UI updates
    dispatch_async(dispatch_get_main_queue(), ^{
        [[NSNotificationCenter defaultCenter]
            postNotificationName:@"InstallModpack" // Notification name listened to by LauncherNavigationController
            object:self                            // Sender is this ModrinthAPI instance
            userInfo:userInfo];                     // Data payload
    });
}

// Helper function to find LauncherNavigationController (assumes standard UI structure)
LauncherNavigationController* findLauncherNavigationController() {
     UIWindow *keyWindow = nil;
     if (@available(iOS 13.0, *)) {
         // Find active scene's key window
         for (UIScene *scene in UIApplication.sharedApplication.connectedScenes) {
             if (scene.activationState == UISceneActivationStateForegroundActive && [scene isKindOfClass:[UIWindowScene class]]) {
                  // Find the key window within the scene
                  for (UIWindow *window in ((UIWindowScene *)scene).windows) {
                       if (window.isKeyWindow) {
                            keyWindow = window;
                            break;
                       }
                  }
                  if (keyWindow) break;
             }
         }
         // Fallback if key window not found in scene
         if (!keyWindow) keyWindow = UIApplication.sharedApplication.windows.firstObject;

     } else {
         keyWindow = UIApplication.sharedApplication.keyWindow;
     }

     UIViewController *rootVC = keyWindow.rootViewController;
     if ([rootVC isKindOfClass:[UISplitViewController class]]) {
         UISplitViewController *splitVC = (UISplitViewController *)rootVC;
         // Look in detail controller first (common case)
         if (splitVC.viewControllers.count > 1 && [splitVC.viewControllers[1] isKindOfClass:[UINavigationController class]]) {
              UINavigationController* nav = (UINavigationController*)splitVC.viewControllers[1];
              if ([nav.viewControllers.firstObject isKindOfClass:[LauncherNavigationController class]]) {
                   return (LauncherNavigationController*)nav.viewControllers.firstObject;
              }
              // Check if the nav controller itself is the LauncherNavigationController
              if ([nav isKindOfClass:[LauncherNavigationController class]]) {
                   return (LauncherNavigationController*)nav;
              }

         }
          // Look in primary controller if not found in detail
         if (splitVC.viewControllers.count > 0 && [splitVC.viewControllers[0] isKindOfClass:[UINavigationController class]]) {
              UINavigationController* nav = (UINavigationController*)splitVC.viewControllers[0];
               if ([nav.viewControllers.firstObject isKindOfClass:[LauncherNavigationController class]]) {
                   return (LauncherNavigationController*)nav.viewControllers.firstObject;
               }
              if ([nav isKindOfClass:[LauncherNavigationController class]]) {
                   return (LauncherNavigationController*)nav;
              }
         }
     } else if ([rootVC isKindOfClass:[LauncherNavigationController class]]) {
         return (LauncherNavigationController *)rootVC;
     } else if ([rootVC isKindOfClass:[UINavigationController class]]) {
         // Check if the root navigation controller contains it
          UINavigationController* nav = (UINavigationController*)rootVC;
           if ([nav.viewControllers.firstObject isKindOfClass:[LauncherNavigationController class]]) {
                return (LauncherNavigationController*)nav.viewControllers.firstObject;
           }
     }
     NSLog(@"[ModrinthAPI Helper] Warning: LauncherNavigationController not found in expected UI hierarchy.");
     return nil; // Not found
}

// Helper function to find the topmost view controller for presenting alerts/modals
UIViewController* findTopViewController() {
    UIWindow *keyWindow = nil;
    if (@available(iOS 13.0, *)) {
        for (UIScene *scene in UIApplication.sharedApplication.connectedScenes) {
            if (scene.activationState == UISceneActivationStateForegroundActive && [scene isKindOfClass:[UIWindowScene class]]) {
                for (UIWindow *window in ((UIWindowScene *)scene).windows) {
                    if (window.isKeyWindow) {
                        keyWindow = window;
                        break;
                    }
                }
                if(keyWindow) break;
            }
        }
         if (!keyWindow) keyWindow = UIApplication.sharedApplication.windows.firstObject;
    } else {
        keyWindow = UIApplication.sharedApplication.keyWindow;
    }

    UIViewController *topController = keyWindow.rootViewController;
    while (topController.presentedViewController) {
        topController = topController.presentedViewController;
    }
    return topController;
}


@end

#import <UIKit/UIKit.h>

@class ModpackAPI;

typedef NS_ENUM(NSInteger, DownloadSource) {
    DownloadSourceMinecraft,
    DownloadSourceCurseForge,
    DownloadSourceModrinth
};

@interface MinecraftResourceDownloadTask : NSObject

@property NSProgress *progress, *textProgress;
@property NSMutableArray *fileList, *progressList;
@property NSMutableDictionary* metadata;
@property(nonatomic, copy) void(^handleError)(void);

/**
 * Prepares the task for downloading by initializing progress tracking
 */
- (void)prepareForDownload;

/**
 * Creates a new download task for a remote resource
 * @param url The URL to download from
 * @param size The expected size of the file
 * @param sha The SHA hash for verification
 * @param altName An alternate name to display
 * @param path The destination path
 * @return The created download task
 */
- (NSURLSessionDownloadTask *)createDownloadTask:(NSString *)url 
                                            size:(NSUInteger)size 
                                             sha:(NSString *)sha 
                                         altName:(NSString *)altName 
                                          toPath:(NSString *)path;

/**
 * Creates a new download task with completion callback
 * @param url The URL to download from
 * @param size The expected size of the file
 * @param sha The SHA hash for verification
 * @param altName An alternate name to display
 * @param path The destination path
 * @param success The callback to execute when download completes successfully
 * @return The created download task
 */
- (NSURLSessionDownloadTask *)createDownloadTask:(NSString *)url 
                                            size:(NSUInteger)size 
                                             sha:(NSString *)sha 
                                         altName:(NSString *)altName 
                                          toPath:(NSString *)path 
                                         success:(void (^)())success;

/**
 * Formats a display name for a file with source information
 * @param fileName The original file name
 * @param source The download source
 * @return A formatted display name
 */
- (NSString *)formatDisplayNameForFile:(NSString *)fileName fromSource:(DownloadSource)source;

/**
 * Finishes the download process with an error message
 * @param error The error message to display
 */
- (void)finishDownloadWithErrorString:(NSString *)error;

/**
 * Downloads a Minecraft version
 * @param version The version to download
 */
- (void)downloadVersion:(NSDictionary *)version;

/**
 * Downloads a modpack using the specified API
 * @param api The ModpackAPI instance
 * @param modDetail The modpack details
 * @param selectedVersion The index of the selected version
 */
- (void)downloadModpackFromAPI:(ModpackAPI *)api 
                        detail:(NSDictionary *)modDetail 
                       atIndex:(NSUInteger)selectedVersion;

/**
 * Retrieves metadata for a specific download task
 * @param task The download task to retrieve metadata for
 * @return A dictionary containing task metadata
 */
- (NSDictionary *)getDownloadTaskInfo:(NSURLSessionDownloadTask *)task;

/**
 * Retrieves metadata for all downloaded files
 * @return An array of dictionaries containing download task metadata
 */
- (NSArray<NSDictionary *> *)getAllDownloadedFiles;

/**
 * Logs the current download source
 * @param source The download source to log
 */
- (void)logDownloadSource:(DownloadSource)source;

/**
 * Checks the SHA of a downloaded file
 * @param sha The expected SHA hash
 * @param path The path to the file
 * @param altName An alternate name for logging
 * @return YES if the file passes SHA verification, NO otherwise
 */
- (BOOL)checkSHA:(NSString *)sha forFile:(NSString *)path altName:(NSString *)altName;

/**
 * Marks the download task as fully completed
 * This is important for modpack installations to ensure proper completion
 */
- (void)markAsCompleted;

/**
 * Cancels all active download tasks
 */
- (void)cancelAllTasks;

@end

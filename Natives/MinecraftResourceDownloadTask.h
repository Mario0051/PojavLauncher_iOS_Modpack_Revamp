#import <UIKit/UIKit.h>

@class ModpackAPI;

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
- (NSURLSessionDownloadTask *)createDownloadTask:(NSString *)url size:(NSUInteger)size sha:(NSString *)sha altName:(NSString *)altName toPath:(NSString *)path;

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
- (NSURLSessionDownloadTask *)createDownloadTask:(NSString *)url size:(NSUInteger)size sha:(NSString *)sha altName:(NSString *)altName toPath:(NSString *)path success:(void (^)(void))success;

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
- (void)downloadModpackFromAPI:(ModpackAPI *)api detail:(NSDictionary *)modDetail atIndex:(NSUInteger)selectedVersion;

@end

#import <UIKit/UIKit.h>

@class ModpackAPI;
@class AFURLSessionManager;

@interface MinecraftResourceDownloadTask : NSObject
@property NSProgress *progress, *textProgress;
@property NSMutableArray *fileList, *progressList;
@property NSMutableDictionary* metadata;
@property(nonatomic, copy) void(^handleError)(void);
@property(nonatomic, readonly) AFURLSessionManager* manager;
@property(nonatomic, assign) NSInteger successfulDownloads;
@property(nonatomic, assign) NSInteger totalDownloads;
@property(nonatomic, assign) BOOL verboseLogging;
@property(nonatomic, strong) NSMutableArray *pendingVerificationList;
@property(nonatomic, assign) BOOL deferSHAVerification;
@property(nonatomic, assign) BOOL hasProcessedAssets;
@property (nonatomic, readonly) BOOL isDownloadPhaseComplete; // Ensure this property is declared

/**
 * Creates a download task with optional callbacks for success and failure handling.
 *
 * @param url The URL to download from
 * @param size The expected size of the file (used for progress tracking)
 * @param sha The SHA1 checksum for validation, or nil to skip validation
 * @param altName An alternative name for display purposes, or nil to use the filename
 * @param path The local path to save the file to
 * @param success Optional callback to execute upon successful download
 * @param failure Optional callback to execute if the download fails
 * @return The created download task, or nil if the file already exists and passes validation
 */
- (NSURLSessionDownloadTask *)createDownloadTask:(NSString *)url
                                           size:(NSUInteger)size
                                            sha:(NSString *)sha
                                        altName:(NSString *)altName
                                         toPath:(NSString *)path
                                        success:(void (^)(void))success
                                        failure:(void (^)(NSError *error))failure;

/**
 * @deprecated Use createDownloadTask:size:sha:altName:toPath:success:failure: instead
 */
- (NSURLSessionDownloadTask *)createDownloadTask:(NSString *)url
                                           size:(NSUInteger)size
                                            sha:(NSString *)sha
                                        altName:(NSString *)altName
                                         toPath:(NSString *)path
                                        success:(void (^)(void))success DEPRECATED_MSG_ATTRIBUTE("Use createDownloadTask:size:sha:altName:toPath:success:failure: instead");

/**
 * @deprecated Use createDownloadTask:size:sha:altName:toPath:success:failure: instead
 */
- (NSURLSessionDownloadTask *)createDownloadTask:(NSString *)url
                                           size:(NSUInteger)size
                                            sha:(NSString *)sha
                                        altName:(NSString *)altName
                                         toPath:(NSString *)path DEPRECATED_MSG_ATTRIBUTE("Use createDownloadTask:size:sha:altName:toPath:success:failure: instead");

// Helper methods for progress tracking
// - (void)addDownloadTaskToProgress:(NSURLSessionDownloadTask *)task size:(NSUInteger)size; // REMOVED
- (void)prepareForDownload;

// Error handling methods
- (void)finishDownloadWithErrorString:(NSString *)error;
- (void)finishDownloadWithError:(NSError *)error file:(NSString *)file;

// File validation methods
- (BOOL)checkSHA:(NSString *)sha forFile:(NSString *)path altName:(NSString *)altName;
- (BOOL)checkSHA:(NSString *)sha forFile:(NSString *)path altName:(NSString *)altName logSuccess:(BOOL)logSuccess;
- (BOOL)checkSHAIgnorePref:(NSString *)sha forFile:(NSString *)path altName:(NSString *)altName logSuccess:(BOOL)logSuccess;
- (BOOL)checkAccessWithDialog:(BOOL)show;

// Methods for deferred SHA verification
- (void)addFileToVerificationList:(NSString *)path sha:(NSString *)sha altName:(NSString *)altName url:(NSString *)url size:(NSUInteger)size;
- (BOOL)verifyPendingFiles;
- (void)redownloadFileWithPath:(NSString *)path sha:(NSString *)sha altName:(NSString *)altName url:(NSString *)url size:(NSUInteger)size;

// Helper method to check completion status
// - (void)checkCompletionStatus; // Keep for internal logic if needed, but rely on group/flag externally // No longer needed externally

// Main download methods
- (void)downloadVersion:(NSDictionary *)version;
- (void)downloadVersionMetadata:(NSDictionary *)version success:(void (^)(void))success;
- (void)downloadAssetMetadataWithSuccess:(void (^)(void))success;
- (NSArray *)downloadClientLibraries:(NSDictionary *)versionMetadata;
- (NSArray *)downloadClientAssets:(NSDictionary *)assetIndexObj;
- (void)downloadClientJar:(NSDictionary *)versionMetadata;
- (void)downloadModpackFromAPI:(ModpackAPI *)api detail:(NSDictionary *)modDetail atIndex:(NSUInteger)selectedVersion;

@end

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

// Basic download task method without success callback
- (NSURLSessionDownloadTask *)createDownloadTask:(NSString *)url 
                                           size:(NSUInteger)size 
                                            sha:(NSString *)sha 
                                        altName:(NSString *)altName 
                                         toPath:(NSString *)path;

// Extended download task method with success callback
- (NSURLSessionDownloadTask *)createDownloadTask:(NSString *)url 
                                           size:(NSUInteger)size 
                                            sha:(NSString *)sha 
                                        altName:(NSString *)altName 
                                         toPath:(NSString *)path 
                                        success:(void (^)(void))success;

// Extended download task method with success and failure callbacks for retry support
- (NSURLSessionDownloadTask *)createDownloadTask:(NSString *)url 
                                           size:(NSUInteger)size 
                                            sha:(NSString *)sha 
                                        altName:(NSString *)altName 
                                         toPath:(NSString *)path 
                                        success:(void (^)(void))success
                                        failure:(void (^)(NSError *error))failure;

// Helper methods for progress tracking
- (void)addDownloadTaskToProgress:(NSURLSessionDownloadTask *)task size:(NSUInteger)size;
- (void)prepareForDownload;

// Error handling methods
- (void)finishDownloadWithErrorString:(NSString *)error;
- (void)finishDownloadWithError:(NSError *)error file:(NSString *)file;

// File validation methods
- (BOOL)checkSHA:(NSString *)sha forFile:(NSString *)path altName:(NSString *)altName;
- (BOOL)checkSHA:(NSString *)sha forFile:(NSString *)path altName:(NSString *)altName logSuccess:(BOOL)logSuccess;
- (BOOL)checkSHAIgnorePref:(NSString *)sha forFile:(NSString *)path altName:(NSString *)altName logSuccess:(BOOL)logSuccess;
- (BOOL)checkAccessWithDialog:(BOOL)show;

// New methods for deferred SHA verification
- (void)addFileToVerificationList:(NSString *)path sha:(NSString *)sha altName:(NSString *)altName;
- (BOOL)verifyPendingFiles;
- (void)redownloadFileWithPath:(NSString *)path sha:(NSString *)sha altName:(NSString *)altName url:(NSString *)url size:(NSUInteger)size;

// Main download methods
- (void)downloadVersion:(NSDictionary *)version;
- (void)downloadVersionMetadata:(NSDictionary *)version success:(void (^)(void))success;
- (void)downloadAssetMetadataWithSuccess:(void (^)(void))success;
- (NSArray *)downloadClientLibraries;
- (NSArray *)downloadClientAssets;
- (void)downloadModpackFromAPI:(ModpackAPI *)api detail:(NSDictionary *)modDetail atIndex:(NSUInteger)selectedVersion;

@end

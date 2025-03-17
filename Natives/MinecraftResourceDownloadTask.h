#import <UIKit/UIKit.h>

@class ModpackAPI;

@interface MinecraftResourceDownloadTask : NSObject
@property NSProgress *progress, *textProgress;
@property NSMutableArray *fileList, *progressList;
@property NSMutableDictionary* metadata;
@property(nonatomic, copy) void(^handleError)(void);
@property(nonatomic, readonly) AFURLSessionManager* manager;

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

- (void)addDownloadTaskToProgress:(NSURLSessionDownloadTask *)task size:(NSUInteger)size;
- (void)finishDownloadWithErrorString:(NSString *)error;

- (void)downloadVersion:(NSDictionary *)version;
- (void)downloadModpackFromAPI:(ModpackAPI *)api detail:(NSDictionary *)modDetail atIndex:(NSUInteger)selectedVersion;

@end

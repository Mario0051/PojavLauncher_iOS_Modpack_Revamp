#import <UIKit/UIKit.h>

@class ModpackAPI;

@interface MinecraftResourceDownloadTask : NSObject
@property NSProgress *progress, *textProgress;
@property NSMutableArray *fileList, *progressList;
@property NSMutableDictionary* metadata;
@property(nonatomic, copy) void(^handleError)(void);
@property(nonatomic, copy) NSString *currentStage;

// Dependencies handling
@property(nonatomic, strong) NSMutableArray *dependencyQueue;
@property(nonatomic, assign) BOOL processingDependencies;
@property(nonatomic, strong) NSMutableSet *processedDependencyIds;

- (NSURLSessionDownloadTask *)createDownloadTask:(NSString *)url size:(NSUInteger)size sha:(NSString *)sha altName:(NSString *)altName toPath:(NSString *)path;
- (NSURLSessionDownloadTask *)createDownloadTask:(NSString *)url size:(NSUInteger)size sha:(NSString *)sha altName:(NSString *)altName toPath:(NSString *)path success:(void (^)(void))success;
- (void)finishDownloadWithErrorString:(NSString *)error;

- (void)downloadVersion:(NSDictionary *)version;
- (void)downloadModpackFromAPI:(ModpackAPI *)api detail:(NSDictionary *)modDetail atIndex:(NSUInteger)selectedVersion;
- (void)downloadModFromDetail:(NSDictionary *)modDetail atIndex:(NSUInteger)selectedVersion;
- (void)processNextDependency:(NSString *)modsDir;
- (NSInteger)findCompatibleVersionIndex:(NSArray *)gameVersions loaderArray:(NSArray *)loaderArray selectedMCVersion:(NSString *)mcVersion selectedLoader:(NSString *)loader;

@end

#import <Foundation/Foundation.h>
#import "ModpackUtils.h"
#import "UnzipKit.h"
#import "NetworkService.h"

@class MinecraftResourceDownloadTask;
NS_ASSUME_NONNULL_BEGIN

typedef NS_ENUM(NSInteger, ModpackAPIErrorCode) {
    ModpackAPIErrorCodeNetwork = 1000,
    ModpackAPIErrorCodeParsing = 1001,
    ModpackAPIErrorCodeResourceNotFound = 1002,
    ModpackAPIErrorCodeExtraction = 1003,
    ModpackAPIErrorCodeInvalidManifest = 1004,
    ModpackAPIErrorCodeFileOperation = 1005,
    ModpackAPIErrorCodeAuthentication = 1006
};

@interface ModpackAPI : NSObject

// Common properties
@property(nonatomic, strong) NSString *baseURL;
@property(nonatomic, strong, nullable) NSError *lastError;
@property(nonatomic, assign) BOOL reachedLastPage;
@property(nonatomic, strong, readonly) NetworkService *networkService;

// Initialization
- (instancetype)initWithURL:(NSString *)url NS_DESIGNATED_INITIALIZER;

// Common methods for all API implementations
- (nullable NSMutableArray *)searchModWithFilters:(NSDictionary *)filters previousPageResult:(nullable NSMutableArray *)prevResult;
- (void)loadDetailsOfMod:(NSMutableDictionary *)item completion:(void (^)(NSError * _Nullable error))completion;
- (void)installModpackFromDetail:(NSDictionary *)modDetail atIndex:(NSUInteger)selectedVersion;
- (void)downloader:(MinecraftResourceDownloadTask *)downloader submitDownloadTasksFromPackage:(NSString *)packagePath toPath:(NSString *)destPath;

// Utility methods that can be used by subclasses
- (nullable id)getEndpoint:(NSString *)endpoint params:(nullable NSDictionary *)params;
- (void)getEndpoint:(NSString *)endpoint params:(nullable NSDictionary *)params completion:(void (^)(id _Nullable result, NSError * _Nullable error))completion;
- (NSError *)errorWithCode:(ModpackAPIErrorCode)code message:(NSString *)message underlyingError:(nullable NSError *)underlyingError;
- (NSString *)cacheKeyForEndpoint:(NSString *)endpoint params:(nullable NSDictionary *)params;
- (void)extractArchive:(UZKArchive *)archive directory:(NSString *)dir toPath:(NSString *)path progress:(void (^)(double progress))progressCallback error:(NSError **)error;

// Template methods that subclasses should implement
- (NSDictionary *)processManifest:(NSDictionary *)manifest error:(NSError **)error;
- (NSString *)getManifestFilename;
- (NSArray *)getFilesFromManifest:(NSDictionary *)manifest;

// Unavailable initializers
- (instancetype)init NS_UNAVAILABLE;
+ (instancetype)new NS_UNAVAILABLE;

@end

NS_ASSUME_NONNULL_END

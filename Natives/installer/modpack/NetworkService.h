#import <Foundation/Foundation.h>

NS_ASSUME_NONNULL_BEGIN

typedef void(^NetworkCompletionHandler)(id _Nullable responseObject, NSError * _Nullable error);

@interface NetworkService : NSObject

+ (instancetype)sharedInstance;

- (NSURLSessionDataTask *)GET:(NSString *)url 
                    parameters:(nullable NSDictionary *)parameters 
                       headers:(nullable NSDictionary *)headers
                     cacheName:(nullable NSString *)cacheName
                    completion:(NetworkCompletionHandler)completion;

- (NSURLSessionDownloadTask *)download:(NSString *)url 
                             toPath:(NSString *)path
                           progress:(nullable void (^)(NSProgress *progress))progressHandler
                         completion:(nullable void (^)(NSURL *location, NSError *_Nullable error))completion;

- (id)cachedResponseForKey:(NSString *)key;
- (void)cacheResponse:(id)response forKey:(NSString *)key;
- (void)clearCache;

@end

NS_ASSUME_NONNULL_END

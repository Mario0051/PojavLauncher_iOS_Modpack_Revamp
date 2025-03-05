#import <Foundation/Foundation.h>

NS_ASSUME_NONNULL_BEGIN

/**
 * Utility class for Fabric/Quilt mod loader installation
 */
@interface FabricUtils : NSObject

/**
 * Returns endpoints configuration for Fabric and Quilt services
 * @return Dictionary with endpoint configurations
 */
+ (NSDictionary *)endpoints;

@end

NS_ASSUME_NONNULL_END

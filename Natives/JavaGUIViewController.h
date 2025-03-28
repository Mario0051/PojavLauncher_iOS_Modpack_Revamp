#import <UIKit/UIKit.h>

@interface SurfaceView : UIView
- (void)displayLayer;
@end

@interface JavaGUIViewController : UIViewController
@property(nonatomic) NSString* filepath;
@property(nonatomic, readwrite) int requiredJavaVersion;

- (void)setHitEnterAfterWindowShown:(BOOL)hitEnter;

// Method to get Java version from JSON
- (int)getJavaVersionFromJSON;

// Method to get Java version from JAR
- (int)getJavaVersionFromJar;
@end

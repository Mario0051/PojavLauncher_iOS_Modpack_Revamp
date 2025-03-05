#import <UIKit/UIKit.h>

typedef NS_ENUM(NSInteger, InstanceType) {
    InstanceTypeVanilla = 0,
    InstanceTypeFabric,
    InstanceTypeForge,
    InstanceTypeQuilt,
    InstanceTypeNeoForge
};

@interface LauncherViewController : UIViewController

@property (weak, nonatomic) IBOutlet UISegmentedControl *instanceSelector;
@property (weak, nonatomic) IBOutlet UIButton *launchButton;
@property (weak, nonatomic) IBOutlet UIButton *installButton;

// Saves the selected Minecraft version for the current instance (writes config_ver.txt)
- (void)saveSelectedVersion:(NSString *)version;

// IBAction to launch the game with the selected instance
- (IBAction)launchGame:(id)sender;

// IBAction to install the mod loader for the selected instance (Fabric/Forge/Quilt/NeoForge)
- (IBAction)installModLoader:(id)sender;

@end

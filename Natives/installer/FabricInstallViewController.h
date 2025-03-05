#import <UIKit/UIKit.h>
#import "PLPrefTableViewController.h"

@interface FabricInstallViewController : PLPrefTableViewController

/**
 * Initializes and configures the view controller for Fabric/Quilt installation
 */
- (void)viewDidLoad;

/**
 * Closes the installation view
 */
- (void)actionClose;

/**
 * Performs the Fabric/Quilt installation
 */
- (void)actionDone:(UIBarButtonItem *)sender;

@end

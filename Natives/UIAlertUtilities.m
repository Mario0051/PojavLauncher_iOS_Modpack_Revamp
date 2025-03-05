#import "UIAlertUtilities.h"

@implementation UIAlertUtilities

+ (void)presentAlertWithTitle:(NSString *)title message:(NSString *)message viewController:(nullable UIViewController *)viewController {
    [self presentAlertWithTitle:title message:message actionTitle:NSLocalizedString(@"OK", @"") handler:nil viewController:viewController];
}

+ (void)presentAlertWithTitle:(NSString *)title message:(NSString *)message actionTitle:(NSString *)actionTitle handler:(void (^)(UIAlertAction *action))handler viewController:(nullable UIViewController *)viewController {
    
    UIAlertController *alertController = [UIAlertController alertControllerWithTitle:title
                                                                             message:message
                                                                      preferredStyle:UIAlertControllerStyleAlert];
    
    UIAlertAction *okAction = [UIAlertAction actionWithTitle:actionTitle
                                                       style:UIAlertActionStyleDefault
                                                     handler:handler];
    [alertController addAction:okAction];
    
    // Determine which view controller to present from
    UIViewController *presentingViewController = viewController;
    if (!presentingViewController) {
        presentingViewController = [self topmostViewController];
    }
    
    // Check if the view controller is already presenting something
    if (presentingViewController.presentedViewController) {
        // Dismiss what's currently presented first
        [presentingViewController dismissViewControllerAnimated:NO completion:^{
            [presentingViewController presentViewController:alertController animated:YES completion:nil];
        }];
    } else {
        [presentingViewController presentViewController:alertController animated:YES completion:nil];
    }
}

+ (UIViewController *)topmostViewController {
    UIWindow *keyWindow = nil;
    
    // Get the key window for iOS 13+ or older versions
    if (@available(iOS 13.0, *)) {
        NSArray<UIScene *> *scenes = [[UIApplication sharedApplication].connectedScenes allObjects];
        for (UIScene *scene in scenes) {
            if ([scene isKindOfClass:[UIWindowScene class]]) {
                UIWindowScene *windowScene = (UIWindowScene *)scene;
                for (UIWindow *window in windowScene.windows) {
                    if (window.isKeyWindow) {
                        keyWindow = window;
                        break;
                    }
                }
                if (keyWindow) {
                    break;
                }
            }
        }
        
        // Fallback if no key window was found
        if (!keyWindow && scenes.count > 0 && [scenes[0] isKindOfClass:[UIWindowScene class]]) {
            UIWindowScene *windowScene = (UIWindowScene *)scenes[0];
            if (windowScene.windows.count > 0) {
                keyWindow = windowScene.windows[0];
            }
        }
    } else {
        // Pre-iOS 13
        keyWindow = [UIApplication sharedApplication].keyWindow;
    }
    
    // Fallback if still no key window
    if (!keyWindow) {
        keyWindow = [UIApplication sharedApplication].windows.firstObject;
    }
    
    // Get the root view controller
    UIViewController *rootViewController = keyWindow.rootViewController;
    if (!rootViewController) {
        return [[UIViewController alloc] init]; // Fallback
    }
    
    // Navigate through the presented view controllers
    UIViewController *currentController = rootViewController;
    while (currentController.presentedViewController) {
        currentController = currentController.presentedViewController;
    }
    
    // For tab controllers, get the selected view controller
    if ([currentController isKindOfClass:[UITabBarController class]]) {
        UITabBarController *tabController = (UITabBarController *)currentController;
        if (tabController.selectedViewController) {
            currentController = tabController.selectedViewController;
        }
    }
    
    // For navigation controllers, get the visible view controller
    if ([currentController isKindOfClass:[UINavigationController class]]) {
        UINavigationController *navController = (UINavigationController *)currentController;
        if (navController.visibleViewController) {
            currentController = navController.visibleViewController;
        }
    }
    
    return currentController;
}

@end

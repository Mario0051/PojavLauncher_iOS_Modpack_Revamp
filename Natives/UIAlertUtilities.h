#import <UIKit/UIKit.h>

NS_ASSUME_NONNULL_BEGIN

/**
 * Utilities for presenting alerts in a way that's compatible with all iOS versions
 */
@interface UIAlertUtilities : NSObject

/**
 * Presents an alert dialog with the given title and message
 * @param title The alert title
 * @param message The alert message
 * @param viewController Optional view controller to present from (if nil, will present from key window)
 */
+ (void)presentAlertWithTitle:(NSString *)title 
                      message:(NSString *)message 
              viewController:(nullable UIViewController *)viewController;

/**
 * Presents an alert dialog with the given title, message, and action
 * @param title The alert title
 * @param message The alert message
 * @param actionTitle The title for the action button
 * @param handler The handler to call when the action is selected
 * @param viewController Optional view controller to present from (if nil, will present from key window)
 */
+ (void)presentAlertWithTitle:(NSString *)title 
                      message:(NSString *)message 
                  actionTitle:(NSString *)actionTitle 
                      handler:(void (^)(UIAlertAction *action))handler 
              viewController:(nullable UIViewController *)viewController;

/**
 * Returns the topmost presented view controller
 * @return The topmost view controller
 */
+ (UIViewController *)topmostViewController;

@end

NS_ASSUME_NONNULL_END

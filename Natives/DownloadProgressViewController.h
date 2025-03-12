#import <UIKit/UIKit.h>
#import "MinecraftResourceDownloadTask.h"

@interface DownloadProgressViewController : UITableViewController
@property MinecraftResourceDownloadTask* task;

- (instancetype)initWithTask:(MinecraftResourceDownloadTask *)task;

/**
 * Closes the view controller. If a download is in progress,
 * shows a confirmation dialog before dismissing.
 */
- (void)actionClose;

/**
 * Removes all progress observers to prevent memory leaks
 */
- (void)removeAllProgressObservers;

/**
 * Removes a specific progress observer
 * @param progress The progress object to stop observing
 */
- (void)removeProgressObserver:(NSProgress *)progress;

/**
 * Refreshes the UI with current progress information
 */
- (void)refreshProgressUI;

@end

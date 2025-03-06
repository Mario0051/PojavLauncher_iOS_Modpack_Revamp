#import "LauncherMenuViewController.h"
#import "LauncherNavigationController.h"
#import "LauncherPreferences.h"
#import "LauncherPrefGameDirViewController.h"
#import "LauncherPrefManageJREViewController.h"
#import "LauncherProfileEditorViewController.h"
#import "LauncherProfilesViewController.h"
//#import "NSFileManager+NRFileManager.h"
#import "PLProfiles.h"
#import "UIKit+AFNetworking.h"
#import "UIKit+hook.h"
#import "installer/FabricInstallViewController.h"
#import "installer/ForgeInstallViewController.h"
#import "installer/ModpackInstallViewController.h"
#import "installer/ModMenuViewController.h"
#import "ios_uikit_bridge.h"
#import "utils.h"

typedef NS_ENUM(NSUInteger, LauncherProfilesTableSection) {
    kInstances,
    kProfiles
};

@interface LauncherProfilesViewController ()

@property(nonatomic) UIBarButtonItem *createButtonItem;

@end

@implementation LauncherProfilesViewController

- (id)init {
    self = [super init];
    self.title = localize(@"Profiles", nil);
    return self;
}

- (NSString *)imageName {
    return @"MenuProfiles";
}

- (void)viewDidLoad
{
    [super viewDidLoad];
    
    // Build create menu with a new "Mods" option.
    UIMenu *createMenu = [UIMenu menuWithTitle:localize(@"profile.title.create", nil)
                                        image:nil
                                   identifier:nil
                                      options:UIMenuOptionsDisplayInline
                                     children:@[
        [UIAction actionWithTitle:@"Vanilla" image:nil identifier:@"vanilla" handler:^(UIAction *action) {
            [self actionEditProfile:@{@"name": @"", @"lastVersionId": @"latest-release"}];
        }],
        [UIAction actionWithTitle:@"Fabric/Quilt" image:nil identifier:@"fabric_or_quilt" handler:^(UIAction *action) {
            [self actionCreateFabricProfile];
        }],
        [UIAction actionWithTitle:@"Forge" image:nil identifier:@"forge" handler:^(UIAction *action) {
            [self actionCreateForgeProfile];
        }],
        [UIAction actionWithTitle:@"Modpack" image:nil identifier:@"modpack" handler:^(UIAction *action) {
            [self actionCreateModpackProfile];
        }],
        [UIAction actionWithTitle:@"Mods" image:nil identifier:@"mods" handler:^(UIAction *action) {
            [self actionOpenMods];
        }]
    ]];
    
    self.createButtonItem = [[UIBarButtonItem alloc] initWithBarButtonSystemItem:UIBarButtonSystemItemAdd menu:createMenu];
    
    self.tableView = [[UITableView alloc] initWithFrame:CGRectZero style:UITableViewStyleInsetGrouped];
    self.tableView.keyboardDismissMode = UIScrollViewKeyboardDismissModeInteractive;
}

- (void)viewWillAppear:(BOOL)animated {
    [super viewWillAppear:animated];
    
    // Place navigation buttons.
    self.navigationItem.rightBarButtonItems = @[[sidebarViewController drawAccountButton], self.createButtonItem];
    
    // Update profiles.
    [PLProfiles updateCurrent];
    [self.tableView reloadData];
    [self.navigationController performSelector:@selector(reloadProfileList)];
}

- (void)actionTogglePrefIsolation:(UISwitch *)sender {
    if (!sender.isOn) {
        setPrefBool(@"internal.isolated", NO);
    }
    toggleIsolatedPref(sender.isOn);
}

- (void)actionCreateFabricProfile {
    FabricInstallViewController *vc = [FabricInstallViewController new];
    [self presentNavigatedViewController:vc];
}

- (void)actionCreateForgeProfile {
    ForgeInstallViewController *vc = [ForgeInstallViewController new];
    [self presentNavigatedViewController:vc];
}

- (void)actionCreateModpackProfile {
    ModpackInstallViewController *vc = [ModpackInstallViewController new];
    [self presentNavigatedViewController:vc];
}

- (void)actionOpenMods {
    ModMenuViewController *modMenuVC = [[ModMenuViewController alloc] init];
    modMenuVC.title = @"Mods";
    [self presentNavigatedViewController:modMenuVC];
}

- (void)actionEditProfile:(NSDictionary *)profile {
    LauncherProfileEditorViewController *vc = [LauncherProfileEditorViewController new];
    vc.profile = profile.mutableCopy;
    [self presentNavigatedViewController:vc];
}

- (void)presentNavigatedViewController:(UIViewController *)vc {
    UINavigationController *nav = [[UINavigationController alloc] initWithRootViewController:vc];
    [self presentViewController:nav animated:YES completion:nil];
}

#pragma mark Table view

- (NSInteger)numberOfSectionsInTableView:(UITableView *)tableView {
    return 2;
}

- (NSString *)tableView:(UITableView *)tableView titleForHeaderInSection:(NSInteger)section {
    switch (section) {
        case 0: return localize(@"profile.section.instance", nil);
        case 1: return localize(@"profile.section.profiles", nil);
    }
    return nil;
}

- (NSInteger)tableView:(UITableView *)tableView numberOfRowsInSection:(NSInteger)section {
    switch (section) {
        case 0: return 2;
        case 1: return [PLProfiles.current.profiles count];
    }
    return 0;
}

- (void)setupInstanceCell:(UITableViewCell *) cell atRow:(NSInteger)row {
    cell.userInteractionEnabled = !getenv("DEMO_LOCK");
    if (row == 0) {
        cell.imageView.image = [UIImage systemImageNamed:@"folder"];
        cell.textLabel.text = localize(@"preference.title.game_directory", nil);
        cell.detailTextLabel.text = getenv("DEMO_LOCK") ? @".demo" : getPrefObject(@"general.game_directory");
    } else {
        NSString *imageName;
        if (@available(iOS 15.0, *)) {
            imageName = @"folder.badge.gearshape";
        } else {
            imageName = @"folder.badge.gear";
        }
        cell.imageView.image = [UIImage systemImageNamed:imageName];
        cell.textLabel.text = localize(@"profile.title.separate_preference", nil);
        cell.detailTextLabel.text = localize(@"profile.detail.separate_preference", nil);
        UISwitch *view = [UISwitch new];
        [view setOn:getPrefBool(@"internal.isolated") animated:NO];
        [view addTarget:self action:@selector(actionTogglePrefIsolation:) forControlEvents:UIControlEventValueChanged];
        cell.accessoryView = view;
    }
}

- (void)setupProfileCell:(UITableViewCell *) cell atRow:(NSInteger)row {
    NSMutableDictionary *profile = PLProfiles.current.profiles.allValues[row];
    
    cell.textLabel.text = profile[@"name"];
    cell.detailTextLabel.text = profile[@"lastVersionId"];
    cell.imageView.layer.magnificationFilter = kCAFilterNearest;
    
    // Use cached image loading
    UIImage *fallbackImage = [UIImage imageNamed:@"DefaultProfile"];
    
    // Properly size the fallback image
    UIGraphicsBeginImageContextWithOptions(CGSizeMake(40, 40), NO, 0.0);
    [fallbackImage drawInRect:CGRectMake(0, 0, 40, 40)];
    UIImage *resizedPlaceholder = UIGraphicsGetImageFromCurrentImageContext();
    UIGraphicsEndImageContext();
    
    if ([profile[@"icon"] hasPrefix:@"data:image/"]) {
        // Try to decode the base64 image
        NSString *base64String = [profile[@"icon"] componentsSeparatedByString:@","].lastObject;
        if (base64String) {
            NSData *imageData = [[NSData alloc] initWithBase64EncodedString:base64String options:0];
            if (imageData) {
                UIImage *iconImage = [UIImage imageWithData:imageData];
                if (iconImage) {
                    // Resize the icon image
                    UIGraphicsBeginImageContextWithOptions(CGSizeMake(40, 40), NO, 0.0);
                    [iconImage drawInRect:CGRectMake(0, 0, 40, 40)];
                    UIImage *resizedIcon = UIGraphicsGetImageFromCurrentImageContext();
                    UIGraphicsEndImageContext();
                    
                    cell.imageView.image = resizedIcon;
                    return;
                }
            }
        }
    }
    
    // If URL-based icon or base64 failed, use the URL loading with caching
    if ([profile[@"icon"] hasPrefix:@"http"]) {
        NSURL *iconURL = [NSURL URLWithString:profile[@"icon"]];
        if (iconURL) {
            __weak typeof(cell) weakCell = cell;
            [cell.imageView setImageWithURLRequest:[NSURLRequest requestWithURL:iconURL]
                                 placeholderImage:resizedPlaceholder
                                          success:^(NSURLRequest *request, NSHTTPURLResponse *response, UIImage *image) {
                // Resize the downloaded image properly
                UIGraphicsBeginImageContextWithOptions(CGSizeMake(40, 40), NO, 0.0);
                [image drawInRect:CGRectMake(0, 0, 40, 40)];
                UIImage *resizedImage = UIGraphicsGetImageFromCurrentImageContext();
                UIGraphicsEndImageContext();
                
                weakCell.imageView.image = resizedImage;
                weakCell.imageView.contentMode = UIViewContentModeScaleAspectFit;
                [weakCell setNeedsLayout];
            } failure:^(NSURLRequest *request, NSHTTPURLResponse *response, NSError *error) {
                weakCell.imageView.image = resizedPlaceholder;
                [weakCell setNeedsLayout];
            }];
            return;
        }
    }
    
    // Fallback to placeholder image
    cell.imageView.image = resizedPlaceholder;
    cell.imageView.contentMode = UIViewContentModeScaleAspectFit;
}

- (UITableViewCell *)tableView:(nonnull UITableView *)tableView cellForRowAtIndexPath:(NSIndexPath *)indexPath
{
    NSString *cellID = indexPath.section == kInstances ? @"InstanceCell" : @"ProfileCell";
    UITableViewCell *cell = [tableView dequeueReusableCellWithIdentifier:cellID];
    if (cell == nil) {
        cell = [[UITableViewCell alloc] initWithStyle:UITableViewCellStyleSubtitle reuseIdentifier:cellID];
        cell.accessoryType = UITableViewCellAccessoryDisclosureIndicator;
        cell.detailTextLabel.numberOfLines = 0;
        cell.detailTextLabel.lineBreakMode = NSLineBreakByWordWrapping;
        if (indexPath.section == kProfiles) {
            cell.imageView.frame = CGRectMake(0, 0, 40, 40);
            cell.imageView.isSizeFixed = YES;
        }
    } else {
        cell.imageView.image = nil;
        cell.userInteractionEnabled = YES;
        cell.accessoryView = nil;
    }
    
    if (indexPath.section == kInstances) {
        [self setupInstanceCell:cell atRow:indexPath.row];
    } else {
        [self setupProfileCell:cell atRow:indexPath.row];
    }
    
    cell.textLabel.enabled = cell.detailTextLabel.enabled = cell.userInteractionEnabled;
    return cell;
}

- (void)tableView:(UITableView *)tableView didSelectRowAtIndexPath:(NSIndexPath *)indexPath {
    [tableView deselectRowAtIndexPath:indexPath animated:NO];
    
    if (indexPath.section == kInstances) {
        if (indexPath.row == 0) {
            [self.navigationController pushViewController:[LauncherPrefGameDirViewController new] animated:YES];
        }
        return;
    }
    
    [self actionEditProfile:PLProfiles.current.profiles.allValues[indexPath.row]];
}

#pragma mark Context Menu configuration

- (void)tableView:(UITableView *)tableView commitEditingStyle:(UITableViewCellEditingStyle)editingStyle forRowAtIndexPath:(NSIndexPath *)indexPath
{
    if (editingStyle != UITableViewCellEditingStyleDelete) return;
    
    UITableViewCell *cell = [self.tableView cellForRowAtIndexPath:indexPath];
    NSString *title = localize(@"preference.title.confirm", nil);
    NSString *message = [NSString stringWithFormat:localize(@"preference.title.confirm.delete_runtime", nil), cell.textLabel.text];
    UIAlertController *confirmAlert = [UIAlertController alertControllerWithTitle:title message:message preferredStyle:UIAlertControllerStyleActionSheet];
    confirmAlert.popoverPresentationController.sourceView = cell;
    confirmAlert.popoverPresentationController.sourceRect = cell.bounds;
    UIAlertAction *ok = [UIAlertAction actionWithTitle:localize(@"OK", nil) style:UIAlertActionStyleDestructive handler:^(UIAlertAction * _Nonnull action) {
        [PLProfiles.current.profiles removeObjectForKey:cell.textLabel.text];
        if ([PLProfiles.current.selectedProfileName isEqualToString:cell.textLabel.text]) {
            PLProfiles.current.selectedProfileName = PLProfiles.current.profiles.allKeys[0];
            [self.navigationController performSelector:@selector(reloadProfileList)];
        } else {
            [PLProfiles.current save];
        }
        [tableView deleteRowsAtIndexPaths:@[indexPath] withRowAnimation:UITableViewRowAnimationAutomatic];
    }];
    UIAlertAction *cancel = [UIAlertAction actionWithTitle:localize(@"Cancel", nil) style:UIAlertActionStyleCancel handler:nil];
    [confirmAlert addAction:cancel];
    [confirmAlert addAction:ok];
    [self presentViewController:confirmAlert animated:YES completion:nil];
}

- (UITableViewCellEditingStyle)tableView:(UITableView *)tableView editingStyleForRowAtIndexPath:(NSIndexPath *)indexPath
{
    if (indexPath.section == kInstances || PLProfiles.current.profiles.count == 1) {
        return UITableViewCellEditingStyleNone;
    }
    return UITableViewCellEditingStyleDelete;
}

@end

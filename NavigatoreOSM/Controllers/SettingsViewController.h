#import <UIKit/UIKit.h>
#import <MapKit/MapKit.h>

@class SettingsViewController;
@class OSMTileOverlay;

@protocol SettingsViewControllerDelegate <NSObject>
@optional
- (void)settingsViewControllerDidUpdateSettings:(SettingsViewController *)controller;
@end

@interface SettingsViewController : UITableViewController

@property (nonatomic, weak) id<SettingsViewControllerDelegate> delegate;
@property (nonatomic, weak) OSMTileOverlay *tileOverlay;
@property (nonatomic, assign) MKCoordinateRegion currentMapRegion;

@end

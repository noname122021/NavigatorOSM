#import <UIKit/UIKit.h>
#import <CoreLocation/CoreLocation.h>
#import <MapKit/MapKit.h>

@protocol SearchViewControllerDelegate <NSObject>
- (void)searchViewControllerDidSelectLocation:(CLLocationCoordinate2D)coordinate title:(NSString *)title;
@optional
- (void)searchViewControllerDidRequestShowAllPOIs:(NSArray *)annotations categoryName:(NSString *)categoryName;
@end

@interface SearchViewController : UIViewController

@property (nonatomic, weak) id<SearchViewControllerDelegate> delegate;
@property (nonatomic, assign) CLLocationCoordinate2D userLocation;

+ (void)saveRecentDestinationWithTitle:(NSString *)title coordinate:(CLLocationCoordinate2D)coordinate;
+ (NSArray *)recentDestinations;
+ (void)clearRecentDestinations;

@end

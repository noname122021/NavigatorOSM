//
//  TrafficTileOverlay.h
//  NavigatorOSM
//

#import <MapKit/MapKit.h>
#import "OSMTileOverlay.h"

@interface TrafficTileOverlay : NSObject <MKOverlay>

@property (nonatomic, copy) NSString *apiKey;
@property (nonatomic, assign) BOOL isEnabled;
@property (nonatomic, readonly) CLLocationCoordinate2D coordinate;
@property (nonatomic, readonly) MKMapRect boundingMapRect;

+ (instancetype)sharedOverlay;
- (void)updateApiKey:(NSString *)apiKey;
- (BOOL)hasValidApiKey;
- (NSData *)cachedTileDataForX:(NSInteger)x y:(NSInteger)y z:(NSInteger)z;
- (void)loadTileAtPath:(MKTileOverlayPath)path result:(void (^)(NSData *tileData, NSError *error))result;

@end

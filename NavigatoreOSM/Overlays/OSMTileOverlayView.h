//
//  OSMTileOverlayView.h
//  NavigatorOSM
//

#import <MapKit/MapKit.h>
#import "OSMTileOverlay.h"
#import "TrafficTileOverlay.h"

@interface OSMTileOverlayView : MKOverlayView

@property (nonatomic, strong, readonly) OSMTileOverlay *tileOverlay;

- (instancetype)initWithTileOverlay:(OSMTileOverlay *)overlay;

@end

@interface TrafficTileOverlayView : MKOverlayView

@property (nonatomic, strong, readonly) TrafficTileOverlay *trafficOverlay;

- (instancetype)initWithTrafficOverlay:(TrafficTileOverlay *)overlay;

@end

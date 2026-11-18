//
//  OSMTileOverlayView.m
//  NavigatorOSM
//

#import "OSMTileOverlayView.h"

@interface OSMTileOverlayView ()
@property (nonatomic, strong, readwrite) OSMTileOverlay *tileOverlay;
@end

@implementation OSMTileOverlayView

- (instancetype)initWithTileOverlay:(OSMTileOverlay *)overlay {
    self = [super initWithOverlay:overlay];
    if (self) {
        _tileOverlay = overlay;
    }
    return self;
}

- (BOOL)canDrawMapRect:(MKMapRect)mapRect zoomScale:(MKZoomScale)zoomScale {
    return YES;
}

- (void)drawMapRect:(MKMapRect)mapRect zoomScale:(MKZoomScale)zoomScale inContext:(CGContextRef)context {
    if (!self.tileOverlay) return;

    NSInteger zoom = (NSInteger)round(log2(zoomScale)) + 20;
    if (zoom < 1) zoom = 1;
    if (zoom > 19) zoom = 19;

    NSInteger maxTiles = 1 << zoom;
    double tileSize = 268435456.0 / (double)maxTiles;

    NSInteger minX = (NSInteger)floor(MKMapRectGetMinX(mapRect) / tileSize);
    NSInteger maxX = (NSInteger)floor((MKMapRectGetMaxX(mapRect) - 1.0) / tileSize);
    NSInteger minY = (NSInteger)floor(MKMapRectGetMinY(mapRect) / tileSize);
    NSInteger maxY = (NSInteger)floor((MKMapRectGetMaxY(mapRect) - 1.0) / tileSize);

    if (minX < 0) minX = 0;
    if (maxX >= maxTiles) maxX = maxTiles - 1;
    if (minY < 0) minY = 0;
    if (maxY >= maxTiles) maxY = maxTiles - 1;

    for (NSInteger x = minX; x <= maxX; x++) {
        for (NSInteger y = minY; y <= maxY; y++) {
            MKMapRect tileMapRect = MKMapRectMake(x * tileSize, y * tileSize, tileSize, tileSize);
            CGRect rect = [self rectForMapRect:tileMapRect];

            UIImage *img = [self.tileOverlay cachedTileImageForX:x y:y z:zoom];
            if (img) {
                UIGraphicsPushContext(context);
                [img drawInRect:rect];
                UIGraphicsPopContext();
            } else {
                MKTileOverlayPath path;
                path.x = x;
                path.y = y;
                path.z = zoom;
                path.contentScaleFactor = 1.0;

                __weak OSMTileOverlayView *weakSelf = self;
                [self.tileOverlay loadTileAtPath:path result:^(NSData *tileData, NSError *error) {
                    if (tileData && !error) {
                        dispatch_async(dispatch_get_main_queue(), ^{
                            [weakSelf setNeedsDisplayInMapRect:tileMapRect];
                        });
                    }
                }];
            }
        }
    }
}

@end

@interface TrafficTileOverlayView ()
@property (nonatomic, strong, readwrite) TrafficTileOverlay *trafficOverlay;
@end

@implementation TrafficTileOverlayView

- (instancetype)initWithTrafficOverlay:(TrafficTileOverlay *)overlay {
    self = [super initWithOverlay:overlay];
    if (self) {
        _trafficOverlay = overlay;
    }
    return self;
}

- (BOOL)canDrawMapRect:(MKMapRect)mapRect zoomScale:(MKZoomScale)zoomScale {
    return (self.trafficOverlay && self.trafficOverlay.isEnabled && [self.trafficOverlay hasValidApiKey]);
}

- (void)drawMapRect:(MKMapRect)mapRect zoomScale:(MKZoomScale)zoomScale inContext:(CGContextRef)context {
    if (!self.trafficOverlay || !self.trafficOverlay.isEnabled || ![self.trafficOverlay hasValidApiKey]) return;

    NSInteger zoom = (NSInteger)round(log2(zoomScale)) + 20;
    if (zoom < 6) return;
    if (zoom > 18) zoom = 18;

    NSInteger maxTiles = 1 << zoom;
    double tileSize = 268435456.0 / (double)maxTiles;

    NSInteger minX = (NSInteger)floor(MKMapRectGetMinX(mapRect) / tileSize);
    NSInteger maxX = (NSInteger)floor((MKMapRectGetMaxX(mapRect) - 1.0) / tileSize);
    NSInteger minY = (NSInteger)floor(MKMapRectGetMinY(mapRect) / tileSize);
    NSInteger maxY = (NSInteger)floor((MKMapRectGetMaxY(mapRect) - 1.0) / tileSize);

    if (minX < 0) minX = 0;
    if (maxX >= maxTiles) maxX = maxTiles - 1;
    if (minY < 0) minY = 0;
    if (maxY >= maxTiles) maxY = maxTiles - 1;

    for (NSInteger x = minX; x <= maxX; x++) {
        for (NSInteger y = minY; y <= maxY; y++) {
            MKMapRect tileMapRect = MKMapRectMake(x * tileSize, y * tileSize, tileSize, tileSize);
            CGRect rect = [self rectForMapRect:tileMapRect];

            NSData *cached = [self.trafficOverlay cachedTileDataForX:x y:y z:zoom];
            if (cached) {
                UIImage *img = [UIImage imageWithData:cached];
                if (img) {
                    UIGraphicsPushContext(context);
                    [img drawInRect:rect blendMode:kCGBlendModeNormal alpha:0.85];
                    UIGraphicsPopContext();
                }
            } else {
                MKTileOverlayPath path;
                path.x = x;
                path.y = y;
                path.z = zoom;
                path.contentScaleFactor = 1.0;

                __weak TrafficTileOverlayView *weakSelf = self;
                [self.trafficOverlay loadTileAtPath:path result:^(NSData *tileData, NSError *error) {
                    if (tileData && !error) {
                        dispatch_async(dispatch_get_main_queue(), ^{
                            [weakSelf setNeedsDisplayInMapRect:tileMapRect];
                        });
                    }
                }];
            }
        }
    }
}

@end

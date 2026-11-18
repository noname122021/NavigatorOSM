//
//  OSMTileOverlay.h
//  NavigatorOSM
//

#import <MapKit/MapKit.h>
#import "../Services/RoutingService.h"

#ifndef MKTileOverlayPath_DEFINED
#define MKTileOverlayPath_DEFINED
typedef struct {
    NSInteger x;
    NSInteger y;
    NSInteger z;
    CGFloat contentScaleFactor;
} MKTileOverlayPath;
#endif

@interface OSMTileOverlay : NSObject <MKOverlay>

@property (nonatomic, readonly) CLLocationCoordinate2D coordinate;
@property (nonatomic, readonly) MKMapRect boundingMapRect;
@property (nonatomic, readonly) BOOL hasOfflineMaps;
@property (nonatomic, readonly) NSUInteger offlineTileCount;

@property (nonatomic, readonly) BOOL isDownloadCancelled;

/// Cache e Prefetching Predittivo
- (void)clearMemoryCache;
- (void)clearDiskCache;
- (NSUInteger)diskCacheSizeBytes;
- (void)reloadOfflineDatabases;
- (void)cancelDownloadVisibleRegion;
- (void)downloadVisibleRegion:(MKCoordinateRegion)region
                     minZoom:(NSInteger)minZ
                     maxZoom:(NSInteger)maxZ
                    progress:(void (^)(NSUInteger completed, NSUInteger total, double mbDownloaded))progressBlock
                  completion:(void (^)(NSUInteger downloaded, double totalMB, BOOL cancelled))completionBlock;
- (NSData *)cachedTileDataForX:(NSInteger)x y:(NSInteger)y z:(NSInteger)z;
- (UIImage *)cachedTileImageForX:(NSInteger)x y:(NSInteger)y z:(NSInteger)z;
- (void)loadTileAtPath:(MKTileOverlayPath)path result:(void (^)(NSData *tileData, NSError *error))result;
- (void)prefetchTilesAlongRoute:(RouteInfo *)route currentDistance:(double)currentDistance lookaheadMeters:(double)lookahead;
- (void)prefetchTilesAheadOfCoordinate:(CLLocationCoordinate2D)coord heading:(double)heading speed:(double)speed;

@end

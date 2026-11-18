#import "OSMTileOverlay.h"
#import <UIKit/UIKit.h>
#import <sqlite3.h>

#pragma mark - MBTiles Offline Database Handler

@interface MBTilesDB : NSObject
@property (nonatomic, copy) NSString *path;
@property (nonatomic, assign) sqlite3 *db;
@property (nonatomic, assign) sqlite3_stmt *stmt;
- (instancetype)initWithPath:(NSString *)path;
- (NSData *)tileDataForX:(NSInteger)x y:(NSInteger)y z:(NSInteger)z;
- (NSUInteger)tileCount;
- (void)close;
@end

@implementation MBTilesDB

- (instancetype)initWithPath:(NSString *)path {
    self = [super init];
    if (self) {
        _path = [path copy];
        if (sqlite3_open_v2([_path UTF8String], &_db, SQLITE_OPEN_READONLY, NULL) == SQLITE_OK) {
            // Standard MBTiles tiles table query
            const char *sql = "SELECT tile_data FROM tiles WHERE zoom_level = ? AND tile_column = ? AND tile_row = ? LIMIT 1;";
            sqlite3_prepare_v2(_db, sql, -1, &_stmt, NULL);
        } else {
            if (_db) {
                sqlite3_close(_db);
                _db = NULL;
            }
            return nil;
        }
    }
    return self;
}

- (NSData *)tileDataForX:(NSInteger)x y:(NSInteger)y z:(NSInteger)z {
    if (!_db || !_stmt) return nil;

    @synchronized (self) {
        // MBTiles standard uses TMS tile_row: y_tms = (1 << z) - 1 - y
        NSInteger tmsY = (1 << z) - 1 - y;

        sqlite3_reset(_stmt);
        sqlite3_bind_int(_stmt, 1, (int)z);
        sqlite3_bind_int(_stmt, 2, (int)x);
        sqlite3_bind_int(_stmt, 3, (int)tmsY);

        if (sqlite3_step(_stmt) == SQLITE_ROW) {
            const void *bytes = sqlite3_column_blob(_stmt, 0);
            int len = sqlite3_column_bytes(_stmt, 0);
            if (bytes && len > 0) {
                return [NSData dataWithBytes:bytes length:len];
            }
        }
    }
    return nil;
}

- (NSUInteger)tileCount {
    if (!_db) return 0;
    NSUInteger count = 0;
    @synchronized (self) {
        sqlite3_stmt *countStmt = NULL;
        if (sqlite3_prepare_v2(_db, "SELECT count(*) FROM tiles;", -1, &countStmt, NULL) == SQLITE_OK) {
            if (sqlite3_step(countStmt) == SQLITE_ROW) {
                count = (NSUInteger)sqlite3_column_int(countStmt, 0);
            }
            sqlite3_finalize(countStmt);
        }
    }
    return count;
}

- (void)close {
    @synchronized (self) {
        if (_stmt) {
            sqlite3_finalize(_stmt);
            _stmt = NULL;
        }
        if (_db) {
            sqlite3_close(_db);
            _db = NULL;
        }
    }
}

- (void)dealloc {
    [self close];
}

@end

#pragma mark - OSMTileOverlay Implementation

@interface OSMTileOverlay ()
@property (nonatomic, strong) NSURLSession *session;
@property (nonatomic, copy) NSString *cacheDirectory;
@property (nonatomic, strong) NSMutableArray *offlineDatabases;
@property (nonatomic, strong) NSCache *memoryCache;
@property (nonatomic, strong) NSCache *imageMemoryCache;
@property (nonatomic, strong) NSOperationQueue *prefetchQueue;
@property (nonatomic, strong) NSMutableSet *prefetchInProgressKeys;
@property (nonatomic, strong) NSDate *lastAheadPrefetchDate;
@property (nonatomic, assign, readwrite) BOOL isDownloadCancelled;
@property (nonatomic, strong) NSOperationQueue *activeDownloadQueue;
@end

@implementation OSMTileOverlay

static inline MKTileOverlayPath TilePathForCoordinate(CLLocationCoordinate2D coord, NSUInteger zoom) {
    MKTileOverlayPath p;
    p.z = zoom;
    p.contentScaleFactor = 1.0;
    int n = 1 << zoom;
    int x = (int)floor((coord.longitude + 180.0) / 360.0 * (double)n);
    double latRad = coord.latitude * M_PI / 180.0;
    int y = (int)floor((1.0 - asinh(tan(latRad)) / M_PI) / 2.0 * (double)n);
    p.x = MAX(0, MIN(n - 1, x));
    p.y = MAX(0, MIN(n - 1, y));
    return p;
}

- (CLLocationCoordinate2D)coordinate {
    return CLLocationCoordinate2DMake(0, 0);
}

- (MKMapRect)boundingMapRect {
    return MKMapRectWorld;
}

- (instancetype)init {
    self = [super init];
    if (self) {
        // HTTP Session per tile OSM standard con round-robin CDN
        NSURLSessionConfiguration *config = [NSURLSessionConfiguration defaultSessionConfiguration];
        config.HTTPAdditionalHeaders = @{
            @"User-Agent": @"NavigatoreOSM/1.3.17 (iPad; iOS 6.1.2; TileEngine)"
        };
        config.timeoutIntervalForRequest = 8.0;
        config.HTTPMaximumConnectionsPerHost = 6;
        _session = [NSURLSession sessionWithConfiguration:config];

        // Cache RAM: 350 tile (~8.5 MB RAM)
        _memoryCache = [[NSCache alloc] init];
        _memoryCache.countLimit = 350;

        _imageMemoryCache = [[NSCache alloc] init];
        _imageMemoryCache.countLimit = 250;

        _prefetchQueue = [[NSOperationQueue alloc] init];
        _prefetchQueue.maxConcurrentOperationCount = 3;
        _prefetchInProgressKeys = [NSMutableSet set];

        _offlineDatabases = [NSMutableArray array];

        // Cartella cache locale su disco
        NSString *baseCache = [NSSearchPathForDirectoriesInDomains(NSCachesDirectory, NSUserDomainMask, YES) firstObject];
        _cacheDirectory = [baseCache stringByAppendingPathComponent:@"OSMTiles"];
        [[NSFileManager defaultManager] createDirectoryAtPath:_cacheDirectory withIntermediateDirectories:YES attributes:nil error:nil];

        // Carica database offline MBTiles
        [self reloadOfflineDatabases];

        [[NSNotificationCenter defaultCenter] addObserver:self
                                                 selector:@selector(clearMemoryCache)
                                                     name:UIApplicationDidReceiveMemoryWarningNotification
                                                   object:nil];
    }
    return self;
}

- (void)dealloc {
    [[NSNotificationCenter defaultCenter] removeObserver:self];
    [_session invalidateAndCancel];
    for (MBTilesDB *db in _offlineDatabases) {
        [db close];
    }
}

- (void)reloadOfflineDatabases {
    for (MBTilesDB *db in self.offlineDatabases) {
        [db close];
    }
    [self.offlineDatabases removeAllObjects];

    NSString *docs = [NSSearchPathForDirectoriesInDomains(NSDocumentDirectory, NSUserDomainMask, YES) firstObject];
    NSString *appMaps = [docs stringByAppendingPathComponent:@"Maps"];
    [[NSFileManager defaultManager] createDirectoryAtPath:appMaps withIntermediateDirectories:YES attributes:nil error:nil];

    NSArray *dirs = @[
        appMaps,
        docs,
        @"/var/mobile/Documents/Maps",
        @"/var/mobile/Media/Maps"
    ];

    NSFileManager *fm = [NSFileManager defaultManager];
    NSMutableSet *scannedPaths = [NSMutableSet set];

    for (NSString *dir in dirs) {
        BOOL isDir = NO;
        if ([fm fileExistsAtPath:dir isDirectory:&isDir] && isDir) {
            NSArray *files = [fm contentsOfDirectoryAtPath:dir error:nil];
            for (NSString *file in files) {
                if ([[[file pathExtension] lowercaseString] isEqualToString:@"mbtiles"]) {
                    NSString *fullPath = [dir stringByAppendingPathComponent:file];
                    if (![scannedPaths containsObject:fullPath]) {
                        [scannedPaths addObject:fullPath];
                        MBTilesDB *db = [[MBTilesDB alloc] initWithPath:fullPath];
                        if (db) {
                            [self.offlineDatabases addObject:db];
                            NSLog(@"[OSMTileOverlay] Caricata mappa offline MBTiles: %@", file);
                        }
                    }
                }
            }
        }
    }
}

- (BOOL)hasOfflineMaps {
    return self.offlineDatabases.count > 0;
}

- (NSUInteger)offlineTileCount {
    NSUInteger total = 0;
    for (MBTilesDB *db in self.offlineDatabases) {
        total += [db tileCount];
    }
    return total;
}

- (NSURL *)URLForTilePath:(MKTileOverlayPath)path {
    // Round-robin {a,b,c}.tile.openstreetmap.org
    static const char cdnSubdomains[] = "abc";
    char sub = cdnSubdomains[(labs((long)path.x) + labs((long)path.y)) % 3];
    NSString *urlStr = [NSString stringWithFormat:@"https://%c.tile.openstreetmap.org/%ld/%ld/%ld.png",
                        sub, (long)path.z, (long)path.x, (long)path.y];
    return [NSURL URLWithString:urlStr];
}

- (NSString *)tileFilePathForPath:(MKTileOverlayPath)path {
    return [self.cacheDirectory stringByAppendingFormat:@"/standard/%ld/%ld/%ld.png",
            (long)path.z, (long)path.x, (long)path.y];
}

- (NSString *)cacheKeyForPath:(MKTileOverlayPath)path {
    return [NSString stringWithFormat:@"%ld_%ld_%ld", (long)path.z, (long)path.x, (long)path.y];
}

- (void)clearMemoryCache {
    [self.memoryCache removeAllObjects];
    [self.imageMemoryCache removeAllObjects];
}

- (NSUInteger)diskCacheSizeBytes {
    NSUInteger totalSize = 0;
    NSFileManager *fm = [NSFileManager defaultManager];
    NSDirectoryEnumerator *enumerator = [fm enumeratorAtPath:self.cacheDirectory];
    NSString *file;
    while ((file = [enumerator nextObject])) {
        NSDictionary *attrs = [enumerator fileAttributes];
        totalSize += [attrs fileSize];
    }
    return totalSize;
}

- (void)clearDiskCache {
    [self.memoryCache removeAllObjects];
    [self.imageMemoryCache removeAllObjects];
    NSFileManager *fm = [NSFileManager defaultManager];
    [fm removeItemAtPath:self.cacheDirectory error:nil];
    [fm createDirectoryAtPath:self.cacheDirectory withIntermediateDirectories:YES attributes:nil error:nil];
}

static inline NSInteger TileXFromLon(double lon, NSInteger zoom) {
    int n = 1 << zoom;
    int x = (int)floor((lon + 180.0) / 360.0 * (double)n);
    return MAX(0, MIN(n - 1, x));
}

static inline NSInteger TileYFromLat(double lat, NSInteger zoom) {
    int n = 1 << zoom;
    double latRad = lat * M_PI / 180.0;
    int y = (int)floor((1.0 - asinh(tan(latRad)) / M_PI) / 2.0 * (double)n);
    return MAX(0, MIN(n - 1, y));
}

- (void)cancelDownloadVisibleRegion {
    self.isDownloadCancelled = YES;
    if (self.activeDownloadQueue) {
        [self.activeDownloadQueue cancelAllOperations];
        self.activeDownloadQueue = nil;
    }
}

- (void)downloadVisibleRegion:(MKCoordinateRegion)region
                     minZoom:(NSInteger)minZ
                     maxZoom:(NSInteger)maxZ
                    progress:(void (^)(NSUInteger completed, NSUInteger total, double mbDownloaded))progressBlock
                  completion:(void (^)(NSUInteger downloaded, double totalMB, BOOL cancelled))completionBlock {

    self.isDownloadCancelled = NO;

    double minLat = region.center.latitude - region.span.latitudeDelta / 2.0;
    double maxLat = region.center.latitude + region.span.latitudeDelta / 2.0;
    double minLon = region.center.longitude - region.span.longitudeDelta / 2.0;
    double maxLon = region.center.longitude + region.span.longitudeDelta / 2.0;

    NSMutableArray *missingPaths = [NSMutableArray array];
    NSFileManager *fm = [NSFileManager defaultManager];

    for (NSInteger z = minZ; z <= maxZ; z++) {
        NSInteger startX = TileXFromLon(minLon, z);
        NSInteger endX = TileXFromLon(maxLon, z);
        NSInteger startY = TileYFromLat(maxLat, z); // lat più alta ha indice Y più piccolo in OSM
        NSInteger endY = TileYFromLat(minLat, z);

        if (startX > endX) { NSInteger t = startX; startX = endX; endX = t; }
        if (startY > endY) { NSInteger t = startY; startY = endY; endY = t; }

        for (NSInteger x = startX; x <= endX; x++) {
            for (NSInteger y = startY; y <= endY; y++) {
                MKTileOverlayPath p;
                p.x = x; p.y = y; p.z = z; p.contentScaleFactor = 1.0;
                NSString *path = [self tileFilePathForPath:p];
                if (![fm fileExistsAtPath:path]) {
                    [missingPaths addObject:[NSValue value:&p withObjCType:@encode(MKTileOverlayPath)]];
                }
            }
        }
    }

    NSUInteger total = missingPaths.count;
    if (total == 0) {
        if (completionBlock) completionBlock(0, 0.0, NO);
        return;
    }

    __block NSUInteger completed = 0;
    __block NSUInteger downloadedCount = 0;
    __block unsigned long long totalBytes = 0;
    __weak OSMTileOverlay *weakSelf = self;

    NSOperationQueue *dlQueue = [[NSOperationQueue alloc] init];
    dlQueue.maxConcurrentOperationCount = 4;
    self.activeDownloadQueue = dlQueue;

    for (NSValue *val in missingPaths) {
        MKTileOverlayPath p;
        [val getValue:&p];

        [dlQueue addOperationWithBlock:^{
            if (!weakSelf || weakSelf.isDownloadCancelled) return;

            NSURL *url = [weakSelf URLForTilePath:p];
            NSString *filePath = [weakSelf tileFilePathForPath:p];
            NSData *data = [NSData dataWithContentsOfURL:url];
            if (weakSelf.isDownloadCancelled) return;

            if (data && data.length > 100) {
                NSString *folder = [filePath stringByDeletingLastPathComponent];
                [[NSFileManager defaultManager] createDirectoryAtPath:folder withIntermediateDirectories:YES attributes:nil error:nil];
                [data writeToFile:filePath atomically:YES];
                @synchronized (weakSelf) {
                    downloadedCount++;
                    totalBytes += data.length;
                }
            }

            @synchronized (weakSelf) {
                completed++;
            }
            if (progressBlock && !weakSelf.isDownloadCancelled) {
                double mb = (double)totalBytes / (1024.0 * 1024.0);
                dispatch_async(dispatch_get_main_queue(), ^{
                    if (!weakSelf.isDownloadCancelled) {
                        progressBlock(completed, total, mb);
                    }
                });
            }
        }];
    }

    dispatch_async(dispatch_get_global_queue(DISPATCH_QUEUE_PRIORITY_DEFAULT, 0), ^{
        [dlQueue waitUntilAllOperationsAreFinished];
        dispatch_async(dispatch_get_main_queue(), ^{
            BOOL wasCancelled = weakSelf ? weakSelf.isDownloadCancelled : YES;
            double finalMB = (double)totalBytes / (1024.0 * 1024.0);
            if (completionBlock) completionBlock(downloadedCount, finalMB, wasCancelled);
        });
    });
}

- (NSData *)cachedTileDataForX:(NSInteger)x y:(NSInteger)y z:(NSInteger)z {
    MKTileOverlayPath p;
    p.x = x;
    p.y = y;
    p.z = z;
    p.contentScaleFactor = 1.0;
    NSString *cacheKey = [self cacheKeyForPath:p];
    NSData *memData = [self.memoryCache objectForKey:cacheKey];
    if (memData && memData.length > 0) return memData;

    // Controllo database offline MBTiles
    if (self.offlineDatabases.count > 0) {
        for (MBTilesDB *db in self.offlineDatabases) {
            NSData *offlineData = [db tileDataForX:x y:y z:z];
            if (offlineData && offlineData.length > 0) {
                [self.memoryCache setObject:offlineData forKey:cacheKey];
                return offlineData;
            }
        }
    }

    NSString *filePath = [self tileFilePathForPath:p];
    if ([[NSFileManager defaultManager] fileExistsAtPath:filePath]) {
        NSData *diskData = [NSData dataWithContentsOfFile:filePath];
        if (diskData && diskData.length > 0) {
            [self.memoryCache setObject:diskData forKey:cacheKey];
            return diskData;
        }
    }
    return nil;
}

- (UIImage *)cachedTileImageForX:(NSInteger)x y:(NSInteger)y z:(NSInteger)z {
    MKTileOverlayPath p;
    p.x = x;
    p.y = y;
    p.z = z;
    p.contentScaleFactor = 1.0;
    NSString *cacheKey = [self cacheKeyForPath:p];
    UIImage *cachedImg = [self.imageMemoryCache objectForKey:cacheKey];
    if (cachedImg) return cachedImg;

    NSData *data = [self cachedTileDataForX:x y:y z:z];
    if (data && data.length > 0) {
        UIImage *img = [UIImage imageWithData:data];
        if (img) {
            [self.imageMemoryCache setObject:img forKey:cacheKey];
            return img;
        }
    }
    return nil;
}

- (void)loadTileAtPath:(MKTileOverlayPath)path result:(void (^)(NSData *tileData, NSError *error))result {
    if (!result) return;

    NSString *cacheKey = [self cacheKeyForPath:path];

    // 1. Cache RAM: istantanea (< 0.1 ms)
    NSData *memData = [self.memoryCache objectForKey:cacheKey];
    if (memData && memData.length > 0) {
        result(memData, nil);
        return;
    }

    // 2. Offline MBTiles SQLite: zero rete, ultra-veloce (< 0.5 ms)
    if (self.offlineDatabases.count > 0) {
        for (MBTilesDB *db in self.offlineDatabases) {
            NSData *offlineData = [db tileDataForX:path.x y:path.y z:path.z];
            if (offlineData && offlineData.length > 0) {
                [self.memoryCache setObject:offlineData forKey:cacheKey];
                UIImage *img = [UIImage imageWithData:offlineData];
                if (img) {
                    [self.imageMemoryCache setObject:img forKey:cacheKey];
                }
                result(offlineData, nil);
                return;
            }
        }
    }

    // 3. Cache su disco locale
    NSString *filePath = [self tileFilePathForPath:path];
    if ([[NSFileManager defaultManager] fileExistsAtPath:filePath]) {
        NSData *diskData = [NSData dataWithContentsOfFile:filePath];
        if (diskData && diskData.length > 0) {
            [self.memoryCache setObject:diskData forKey:cacheKey];
            result(diskData, nil);
            return;
        }
    }

    // 4. Download da server OSM
    NSURL *tileURL = [self URLForTilePath:path];
    if (!tileURL) {
        result(nil, [NSError errorWithDomain:@"OSMTileOverlayError" code:-1 userInfo:nil]);
        return;
    }

    __weak OSMTileOverlay *weakSelf = self;
    NSURLSessionDataTask *task = [self.session dataTaskWithURL:tileURL completionHandler:^(NSData *data, NSURLResponse *response, NSError *error) {
        if (data && !error && data.length > 100) {
            [weakSelf.memoryCache setObject:data forKey:cacheKey];
            UIImage *img = [UIImage imageWithData:data];
            if (img) {
                [weakSelf.imageMemoryCache setObject:img forKey:cacheKey];
            }

            dispatch_async(dispatch_get_global_queue(DISPATCH_QUEUE_PRIORITY_LOW, 0), ^{
                NSString *folder = [filePath stringByDeletingLastPathComponent];
                [[NSFileManager defaultManager] createDirectoryAtPath:folder withIntermediateDirectories:YES attributes:nil error:nil];
                [data writeToFile:filePath atomically:YES];
            });

            result(data, nil);
        } else {
            result(nil, error);
        }
    }];
    [task resume];
}

#pragma mark - Prefetching Predittivo

- (void)prefetchTilePath:(MKTileOverlayPath)path {
    NSString *cacheKey = [self cacheKeyForPath:path];
    if ([self.memoryCache objectForKey:cacheKey]) return;

    if (self.offlineDatabases.count > 0) {
        for (MBTilesDB *db in self.offlineDatabases) {
            NSData *offlineData = [db tileDataForX:path.x y:path.y z:path.z];
            if (offlineData && offlineData.length > 0) {
                [self.memoryCache setObject:offlineData forKey:cacheKey];
                return;
            }
        }
    }

    NSString *filePath = [self tileFilePathForPath:path];
    if ([[NSFileManager defaultManager] fileExistsAtPath:filePath]) return;

    @synchronized (self.prefetchInProgressKeys) {
        if ([self.prefetchInProgressKeys containsObject:cacheKey]) return;
        [self.prefetchInProgressKeys addObject:cacheKey];
    }

    NSURL *tileURL = [self URLForTilePath:path];
    if (!tileURL) {
        @synchronized (self.prefetchInProgressKeys) {
            [self.prefetchInProgressKeys removeObject:cacheKey];
        }
        return;
    }

    __weak OSMTileOverlay *weakSelf = self;
    __block NSBlockOperation *op = [NSBlockOperation blockOperationWithBlock:^{
        if (op.isCancelled) {
            @synchronized (weakSelf.prefetchInProgressKeys) {
                [weakSelf.prefetchInProgressKeys removeObject:cacheKey];
            }
            return;
        }

        NSURLRequest *req = [NSURLRequest requestWithURL:tileURL cachePolicy:NSURLRequestReturnCacheDataElseLoad timeoutInterval:8.0];
        NSURLSessionDataTask *task = [weakSelf.session dataTaskWithRequest:req completionHandler:^(NSData *data, NSURLResponse *response, NSError *error) {
            if (data && !error && data.length > 100) {
                [weakSelf.memoryCache setObject:data forKey:cacheKey];
                NSString *folder = [filePath stringByDeletingLastPathComponent];
                [[NSFileManager defaultManager] createDirectoryAtPath:folder withIntermediateDirectories:YES attributes:nil error:nil];
                [data writeToFile:filePath atomically:YES];
            }
            @synchronized (weakSelf.prefetchInProgressKeys) {
                [weakSelf.prefetchInProgressKeys removeObject:cacheKey];
            }
        }];
        [task resume];
    }];

    [self.prefetchQueue addOperation:op];
}

- (void)prefetchTilesAlongRoute:(RouteInfo *)route currentDistance:(double)currentDistance lookaheadMeters:(double)lookahead {
    if (!route || !route.polyline || route.polyline.pointCount < 2) return;

    NSUInteger totalPoints = route.polyline.pointCount;
    MKMapPoint *points = route.polyline.points;
    if (!points || totalPoints < 2) return;

    double startDist = MAX(0.0, currentDistance);
    double endDist = MIN(route.totalDistance, startDist + lookahead);
    if (endDist <= startDist) return;

    [self.prefetchQueue cancelAllOperations];

    double sampleStepMeters = 130.0;
    double currentAccumulatedDist = 0.0;
    double nextTargetDist = startDist;

    NSMutableSet *queuedKeys = [NSMutableSet set];

    for (NSUInteger i = 0; i < totalPoints - 1 && nextTargetDist <= endDist; i++) {
        MKMapPoint p1 = points[i];
        MKMapPoint p2 = points[i + 1];
        CLLocationDistance segLen = MKMetersBetweenMapPoints(p1, p2);
        if (segLen <= 0.001) continue;

        double segStartDist = currentAccumulatedDist;
        double segEndDist = currentAccumulatedDist + segLen;

        while (nextTargetDist >= segStartDist && nextTargetDist <= segEndDist && nextTargetDist <= endDist) {
            double ratio = (nextTargetDist - segStartDist) / segLen;
            MKMapPoint sampledPoint = MKMapPointMake(p1.x + (p2.x - p1.x) * ratio,
                                                     p1.y + (p2.y - p1.y) * ratio);
            CLLocationCoordinate2D coord = MKCoordinateForMapPoint(sampledPoint);

            double distFromCar = nextTargetDist - startDist;

            // 1. Nei prossimi 1.800 metri: Zoom 17
            if (distFromCar <= 1800.0) {
                MKTileOverlayPath p17 = TilePathForCoordinate(coord, 17);
                NSString *k17 = [self cacheKeyForPath:p17];
                if (![queuedKeys containsObject:k17]) {
                    [queuedKeys addObject:k17];
                    [self prefetchTilePath:p17];
                }
            }

            // 2. Nei prossimi 3.000 metri: Zoom 16
            if (distFromCar <= 3000.0) {
                MKTileOverlayPath p16 = TilePathForCoordinate(coord, 16);
                NSString *k16 = [self cacheKeyForPath:p16];
                if (![queuedKeys containsObject:k16]) {
                    [queuedKeys addObject:k16];
                    [self prefetchTilePath:p16];
                }
            }

            // 3. Fino alla fine del lookahead: Zoom 15
            MKTileOverlayPath p15 = TilePathForCoordinate(coord, 15);
            NSString *k15 = [self cacheKeyForPath:p15];
            if (![queuedKeys containsObject:k15]) {
                [queuedKeys addObject:k15];
                [self prefetchTilePath:p15];
            }

            nextTargetDist += sampleStepMeters;
        }

        currentAccumulatedDist = segEndDist;
    }
}

- (void)prefetchTilesAheadOfCoordinate:(CLLocationCoordinate2D)coord heading:(double)heading speed:(double)speed {
    if (speed < 3.5) return;

    NSDate *now = [NSDate date];
    if (self.lastAheadPrefetchDate && [now timeIntervalSinceDate:self.lastAheadPrefetchDate] < 4.0) {
        return;
    }
    self.lastAheadPrefetchDate = now;

    double rEarth = 6371000.0;
    double lat1 = coord.latitude * M_PI / 180.0;
    double lon1 = coord.longitude * M_PI / 180.0;
    double brng = heading * M_PI / 180.0;

    double distances[] = { 160.0, 380.0, 700.0, 1100.0 };
    NSUInteger numDists = sizeof(distances) / sizeof(distances[0]);

    NSMutableSet *queuedKeys = [NSMutableSet set];

    for (NSUInteger i = 0; i < numDists; i++) {
        double d = distances[i];
        double lat2 = asin(sin(lat1) * cos(d / rEarth) + cos(lat1) * sin(d / rEarth) * cos(brng));
        double lon2 = lon1 + atan2(sin(brng) * sin(d / rEarth) * cos(lat1), cos(d / rEarth) - sin(lat1) * sin(lat2));

        CLLocationCoordinate2D forwardCoord = CLLocationCoordinate2DMake(lat2 * 180.0 / M_PI, lon2 * 180.0 / M_PI);

        if (d <= 400.0) {
            MKTileOverlayPath centerPath = TilePathForCoordinate(forwardCoord, 17);
            for (NSInteger dx = -1; dx <= 1; dx++) {
                for (NSInteger dy = -1; dy <= 1; dy++) {
                    MKTileOverlayPath p = centerPath;
                    NSInteger nx = (NSInteger)p.x + dx;
                    NSInteger ny = (NSInteger)p.y + dy;
                    int maxN = 1 << 17;
                    if (nx >= 0 && nx < maxN && ny >= 0 && ny < maxN) {
                        p.x = (NSUInteger)nx;
                        p.y = (NSUInteger)ny;
                        NSString *k = [self cacheKeyForPath:p];
                        if (![queuedKeys containsObject:k]) {
                            [queuedKeys addObject:k];
                            [self prefetchTilePath:p];
                        }
                    }
                }
            }
        }

        MKTileOverlayPath p16 = TilePathForCoordinate(forwardCoord, 16);
        NSString *k16 = [self cacheKeyForPath:p16];
        if (![queuedKeys containsObject:k16]) {
            [queuedKeys addObject:k16];
            [self prefetchTilePath:p16];
        }

        if (d >= 700.0) {
            MKTileOverlayPath p15 = TilePathForCoordinate(forwardCoord, 15);
            NSString *k15 = [self cacheKeyForPath:p15];
            if (![queuedKeys containsObject:k15]) {
                [queuedKeys addObject:k15];
                [self prefetchTilePath:p15];
            }
        }
    }
}

@end

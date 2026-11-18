//
//  TrafficTileOverlay.m
//  NavigatorOSM
//

#import "TrafficTileOverlay.h"

@interface TrafficTileOverlay ()
@property (nonatomic, strong) NSURLSession *session;
@property (nonatomic, copy) NSString *cacheDirectory;
@end

@implementation TrafficTileOverlay

+ (instancetype)sharedOverlay {
    static TrafficTileOverlay *instance = nil;
    static dispatch_once_t onceToken;
    dispatch_once(&onceToken, ^{
        instance = [[TrafficTileOverlay alloc] init];
    });
    return instance;
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
        NSString *savedKey = [[NSUserDefaults standardUserDefaults] stringForKey:@"TrafficApiKey"];
        if (!savedKey || savedKey.length == 0) {
            savedKey = @"";
        }

        BOOL enabled = NO;
        if (savedKey.length >= 6 && [[NSUserDefaults standardUserDefaults] objectForKey:@"TrafficEnabled"]) {
            enabled = [[NSUserDefaults standardUserDefaults] boolForKey:@"TrafficEnabled"];
        }

        _apiKey = [savedKey copy];
        _isEnabled = enabled;

        NSURLSessionConfiguration *config = [NSURLSessionConfiguration defaultSessionConfiguration];
        config.timeoutIntervalForRequest = 6.0;
        config.HTTPAdditionalHeaders = @{
            @"User-Agent": @"NavigatoreOSM/1.3.7 (iPad Mini 1; iOS 9.3.5; TrafficClient)"
        };
        _session = [NSURLSession sessionWithConfiguration:config];

        NSString *baseCache = [NSSearchPathForDirectoriesInDomains(NSCachesDirectory, NSUserDomainMask, YES) firstObject];
        _cacheDirectory = [baseCache stringByAppendingPathComponent:@"TrafficTiles"];
        [[NSFileManager defaultManager] createDirectoryAtPath:_cacheDirectory withIntermediateDirectories:YES attributes:nil error:nil];
    }
    return self;
}

- (void)setIsEnabled:(BOOL)isEnabled {
    _isEnabled = isEnabled;
    [[NSUserDefaults standardUserDefaults] setBool:isEnabled forKey:@"TrafficEnabled"];
    [[NSUserDefaults standardUserDefaults] synchronize];
}

- (BOOL)hasValidApiKey {
    return (self.apiKey && self.apiKey.length >= 6);
}

- (void)updateApiKey:(NSString *)apiKey {
    _apiKey = [apiKey copy];
    [[NSUserDefaults standardUserDefaults] setObject:apiKey forKey:@"TrafficApiKey"];
    [[NSUserDefaults standardUserDefaults] synchronize];
}

- (NSURL *)URLForTilePath:(MKTileOverlayPath)path {
    if (!self.apiKey || self.apiKey.length == 0) return nil;
    NSString *urlStr = [NSString stringWithFormat:@"https://api.tomtom.com/traffic/map/4/tile/flow/relative0/%ld/%ld/%ld.png?key=%@",
                        (long)path.z, (long)path.x, (long)path.y, self.apiKey];
    return [NSURL URLWithString:urlStr];
}

- (NSData *)cachedTileDataForX:(NSInteger)x y:(NSInteger)y z:(NSInteger)z {
    if (!self.isEnabled || ![self hasValidApiKey]) return nil;
    NSString *filePath = [self.cacheDirectory stringByAppendingFormat:@"/%ld/%ld/%ld.png", (long)z, (long)x, (long)y];
    NSDictionary *attrs = [[NSFileManager defaultManager] attributesOfItemAtPath:filePath error:nil];
    if (attrs) {
        NSDate *modDate = attrs[NSFileModificationDate];
        if (modDate && [[NSDate date] timeIntervalSinceDate:modDate] < 180.0) { // 3 min
            NSData *cached = [NSData dataWithContentsOfFile:filePath];
            if (cached && cached.length > 0) return cached;
        }
    }
    return nil;
}

- (void)loadTileAtPath:(MKTileOverlayPath)path result:(void (^)(NSData *tileData, NSError *error))result {
    if (!self.isEnabled || self.apiKey.length == 0) {
        if (result) result(nil, nil);
        return;
    }

    NSString *filePath = [self.cacheDirectory stringByAppendingFormat:@"/%ld/%ld/%ld.png",
                          (long)path.z, (long)path.x, (long)path.y];

    NSDictionary *attrs = [[NSFileManager defaultManager] attributesOfItemAtPath:filePath error:nil];
    if (attrs) {
        NSDate *modDate = attrs[NSFileModificationDate];
        if (modDate && [[NSDate date] timeIntervalSinceDate:modDate] < 180.0) {
            NSData *cached = [NSData dataWithContentsOfFile:filePath];
            if (cached && cached.length > 0) {
                if (result) result(cached, nil);
                return;
            }
        }
    }

    NSURL *tileURL = [self URLForTilePath:path];
    if (!tileURL) {
        if (result) result(nil, nil);
        return;
    }

    NSURLSessionDataTask *task = [self.session dataTaskWithURL:tileURL completionHandler:^(NSData *data, NSURLResponse *response, NSError *error) {
        if (data && !error && [response isKindOfClass:[NSHTTPURLResponse class]]) {
            NSHTTPURLResponse *httpResp = (NSHTTPURLResponse *)response;
            if (httpResp.statusCode == 200) {
                NSString *folder = [filePath stringByDeletingLastPathComponent];
                [[NSFileManager defaultManager] createDirectoryAtPath:folder withIntermediateDirectories:YES attributes:nil error:nil];
                [data writeToFile:filePath atomically:YES];
                if (result) result(data, nil);
                return;
            }
        }
        if (result) result(nil, nil);
    }];
    [task resume];
}

@end

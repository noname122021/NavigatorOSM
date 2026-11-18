#import "QuickPOIShelfView.h"
#import "../Services/LocalizationManager.h"
#import "../Services/FuelPriceService.h"
#import <objc/runtime.h>

@interface QuickPOIShelfView ()
@property (nonatomic, strong) NSURLSession *session;
@property (nonatomic, strong) UIActivityIndicatorView *spinner;
@property (nonatomic, strong) NSMutableArray *categoryButtons;
@end

static NSArray *POICategoriesDefinition(void) {
    return @[
        @{@"icon": @"⛽", @"key": @"FUEL",        @"def": @"Заправка",    @"query": @"fuel",                 @"type": @"amenity"},
        @{@"icon": @"🍕", @"key": @"RESTAURANTS", @"def": @"Еда",         @"query": @"restaurant,fast_food", @"type": @"amenity"},
        @{@"icon": @"🅿️", @"key": @"PARKING",     @"def": @"Парковки",    @"query": @"parking,parking_space,parking_entrance", @"type": @"amenity"},
        @{@"icon": @"☕", @"key": @"CAFE",        @"def": @"Кафе",        @"query": @"cafe,bar",             @"type": @"amenity"},
        @{@"icon": @"💊", @"key": @"PHARMACY",    @"def": @"Аптеки",      @"query": @"pharmacy",             @"type": @"amenity"}
    ];
}

@implementation QuickPOIShelfView

- (void)dealloc {
    [[NSNotificationCenter defaultCenter] removeObserver:self];
}

- (instancetype)initWithFrame:(CGRect)frame {
    self = [super initWithFrame:frame];
    if (self) {
        self.backgroundColor = [UIColor colorWithWhite:0.12 alpha:0.95];
        self.layer.cornerRadius = 16.0;
        self.layer.borderColor = [[UIColor colorWithWhite:0.3 alpha:0.7] CGColor];
        self.layer.borderWidth = 1.0;
        self.layer.shadowColor = [[UIColor blackColor] CGColor];
        self.layer.shadowPath = [UIBezierPath bezierPathWithRoundedRect:self.bounds cornerRadius:16.0].CGPath;
        self.layer.shadowOpacity = 0.3;
        self.layer.shadowRadius = 4.0;
        self.layer.shadowOffset = CGSizeMake(0, 2);

        _categoryButtons = [NSMutableArray array];

        NSURLSessionConfiguration *config = [NSURLSessionConfiguration defaultSessionConfiguration];
        config.timeoutIntervalForRequest = 10.0;
        config.HTTPAdditionalHeaders = @{
            @"User-Agent": @"NavigatoreOSM/1.3 (iPad Mini 1; iOS 9.3.5)"
        };
        _session = [NSURLSession sessionWithConfiguration:config];

        [self setupButtons];

        _spinner = [[UIActivityIndicatorView alloc] initWithActivityIndicatorStyle:UIActivityIndicatorViewStyleWhite];
        _spinner.center = CGPointMake(frame.size.width / 2.0, frame.size.height / 2.0);
        _spinner.hidesWhenStopped = YES;
        [self addSubview:_spinner];

        [[NSNotificationCenter defaultCenter] addObserver:self
                                                 selector:@selector(updateLocalizedTitles)
                                                     name:kAppLanguagePreferenceChangedNotification
                                                   object:nil];
        [[NSNotificationCenter defaultCenter] addObserver:self
                                                 selector:@selector(updateLocalizedTitles)
                                                     name:kFuelPricesUpdatedNotification
                                                   object:nil];
    }
    return self;
}

- (void)setupButtons {
    NSArray *items = POICategoriesDefinition();
    [self.categoryButtons removeAllObjects];

    CGFloat totalW = self.bounds.size.width - 50;
    CGFloat btnW = totalW / (CGFloat)items.count;
    CGFloat btnH = self.bounds.size.height - 16;

    for (NSUInteger i = 0; i < items.count; i++) {
        NSDictionary *dict = items[i];
        UIButton *btn = [UIButton buttonWithType:UIButtonTypeCustom];
        btn.frame = CGRectMake(8 + i * btnW, 8, btnW - 4, btnH);
        btn.backgroundColor = [UIColor colorWithWhite:0.22 alpha:0.85];
        btn.layer.cornerRadius = 10.0;
        btn.layer.borderColor = [[UIColor colorWithWhite:0.4 alpha:0.4] CGColor];
        btn.layer.borderWidth = 1.0;

        NSString *title = NLString(dict[@"key"], dict[@"def"]);
        NSString *text = [NSString stringWithFormat:@"%@ %@", dict[@"icon"], title];
        [btn setTitle:text forState:UIControlStateNormal];
        btn.titleLabel.font = [UIFont boldSystemFontOfSize:11.0];
        [btn setTitleColor:[UIColor whiteColor] forState:UIControlStateNormal];
        btn.titleLabel.adjustsFontSizeToFitWidth = YES;
        btn.titleLabel.minimumScaleFactor = 0.7;

        objc_setAssociatedObject(btn, "poi_query", dict[@"query"], OBJC_ASSOCIATION_COPY_NONATOMIC);
        objc_setAssociatedObject(btn, "poi_type", dict[@"type"], OBJC_ASSOCIATION_COPY_NONATOMIC);
        objc_setAssociatedObject(btn, "poi_key", dict[@"key"], OBJC_ASSOCIATION_COPY_NONATOMIC);
        objc_setAssociatedObject(btn, "poi_def", dict[@"def"], OBJC_ASSOCIATION_COPY_NONATOMIC);
        objc_setAssociatedObject(btn, "poi_name", title, OBJC_ASSOCIATION_COPY_NONATOMIC);

        [btn addTarget:self action:@selector(handlePOITapped:) forControlEvents:UIControlEventTouchUpInside];
        [self addSubview:btn];
        [self.categoryButtons addObject:btn];
    }

    // Bottone chiudi a destra
    UIButton *closeBtn = [UIButton buttonWithType:UIButtonTypeCustom];
    closeBtn.frame = CGRectMake(self.bounds.size.width - 42, 8, 34, btnH);
    closeBtn.backgroundColor = [UIColor colorWithWhite:0.25 alpha:0.9];
    closeBtn.layer.cornerRadius = 10.0;
    [closeBtn setTitle:@"✕" forState:UIControlStateNormal];
    [closeBtn setTitleColor:[UIColor whiteColor] forState:UIControlStateNormal];
    closeBtn.titleLabel.font = [UIFont boldSystemFontOfSize:15.0];
    [closeBtn addTarget:self action:@selector(handleClose) forControlEvents:UIControlEventTouchUpInside];
    [self addSubview:closeBtn];
}

- (void)updateLocalizedTitles {
    NSArray *items = POICategoriesDefinition();
    for (NSUInteger i = 0; i < self.categoryButtons.count && i < items.count; i++) {
        UIButton *btn = self.categoryButtons[i];
        NSDictionary *dict = items[i];
        NSString *title = NLString(dict[@"key"], dict[@"def"]);
        NSString *text = [NSString stringWithFormat:@"%@ %@", dict[@"icon"], title];
        [btn setTitle:text forState:UIControlStateNormal];
        objc_setAssociatedObject(btn, "poi_name", title, OBJC_ASSOCIATION_COPY_NONATOMIC);
    }
}

- (void)handleClose {
    if ([self.delegate respondsToSelector:@selector(quickPOIShelfViewDidRequestClose:)]) {
        [self.delegate quickPOIShelfViewDidRequestClose:self];
    }
}

- (void)handlePOITapped:(UIButton *)sender {
    NSString *query = objc_getAssociatedObject(sender, "poi_query");
    NSString *key = objc_getAssociatedObject(sender, "poi_key");
    NSString *def = objc_getAssociatedObject(sender, "poi_def");
    NSString *name = (key && def) ? NLString(key, def) : (objc_getAssociatedObject(sender, "poi_name") ?: @"POI");

    if ([self.delegate respondsToSelector:@selector(quickPOIShelfView:didRequestSearchCategory:categoryName:)]) {
        [self.delegate quickPOIShelfView:self didRequestSearchCategory:query categoryName:name];
    }
}

- (void)searchCategory:(NSString *)query fromCoordinate:(CLLocationCoordinate2D)coord categoryName:(NSString *)categoryName {
    MKCoordinateRegion region = MKCoordinateRegionMakeWithDistance(coord, 1600.0, 1600.0);
    [self searchCategory:query inRegion:region categoryName:categoryName];
}

- (void)searchCategory:(NSString *)query inRegion:(MKCoordinateRegion)region categoryName:(NSString *)categoryName {
    [self.spinner startAnimating];
    [self executeNominatimSearch:query inRegion:region categoryName:categoryName];
}

- (void)executeNominatimSearch:(NSString *)query inRegion:(MKCoordinateRegion)region categoryName:(NSString *)categoryName {
    NSArray *subQueries = [query componentsSeparatedByString:@","];
    dispatch_group_t group = dispatch_group_create();
    NSMutableArray *rawItems = [NSMutableArray array];

    CLLocationCoordinate2D center = region.center;
    if (!CLLocationCoordinate2DIsValid(center) || (fabs(center.latitude) < 0.01 && fabs(center.longitude) < 0.01)) {
        [self.spinner stopAnimating];
        return;
    }

    double latRad = center.latitude * M_PI / 180.0;
    double metersPerDegLat = 111320.0;
    double metersPerDegLon = 111320.0 * cos(latRad);
    if (metersPerDegLon < 1.0) metersPerDegLon = 1.0;

    // Viewport exact half spans in degrees (matches screen frame precisely in landscape & portrait)
    double halfLat = region.span.latitudeDelta / 2.0;
    double halfLon = region.span.longitudeDelta / 2.0;

    // Sanity checks: keep at least ~100m to avoid zero-size box, and at most ~15km for Nominatim stability
    double minDegLat = 100.0 / metersPerDegLat;
    double minDegLon = 100.0 / metersPerDegLon;
    halfLat = MAX(halfLat, minDegLat);
    halfLon = MAX(halfLon, minDegLon);

    double maxDegLat = 15000.0 / metersPerDegLat;
    double maxDegLon = 15000.0 / metersPerDegLon;
    halfLat = MIN(halfLat, maxDegLat);
    halfLon = MIN(halfLon, maxDegLon);

    double minLon = center.longitude - halfLon;
    double maxLon = center.longitude + halfLon;
    double minLat = center.latitude - halfLat;
    double maxLat = center.latitude + halfLat;

    NSString *lang = [[LocalizationManager sharedManager] currentLanguage];
    NSString *acceptLang = @"en";
    if ([lang isEqualToString:@"ru"]) acceptLang = @"ru,uk;q=0.9,en;q=0.5";
    else if ([lang isEqualToString:@"uk"]) acceptLang = @"uk,ru;q=0.9,en;q=0.5";
    else if ([lang isEqualToString:@"it"]) acceptLang = @"it,en;q=0.8";

    NSString *encodedLang = [acceptLang stringByAddingPercentEncodingWithAllowedCharacters:[NSCharacterSet URLQueryAllowedCharacterSet]];

    for (NSString *subQ in subQueries) {
        NSString *trimmedQ = [subQ stringByTrimmingCharactersInSet:[NSCharacterSet whitespaceCharacterSet]];
        if (trimmedQ.length == 0) continue;

        NSString *urlString = [NSString stringWithFormat:
                               @"https://nominatim.openstreetmap.org/search?format=json&amenity=%@&viewbox=%.5f,%.5f,%.5f,%.5f&bounded=1&limit=50&addressdetails=1&accept-language=%@",
                               trimmedQ, minLon, maxLat, maxLon, minLat, encodedLang];

        NSMutableURLRequest *req = [NSMutableURLRequest requestWithURL:[NSURL URLWithString:urlString]];
        req.timeoutInterval = 8.0;
        [req setValue:@"NavigatoreOSM-iOS6" forHTTPHeaderField:@"User-Agent"];
        [req setValue:acceptLang forHTTPHeaderField:@"Accept-Language"];

        dispatch_group_enter(group);
        NSURLSessionDataTask *task = [self.session dataTaskWithRequest:req completionHandler:^(NSData *data, NSURLResponse *response, NSError *error) {
            if (!error && data) {
                NSArray *items = [NSJSONSerialization JSONObjectWithData:data options:0 error:nil];
                if ([items isKindOfClass:[NSArray class]]) {
                    @synchronized (rawItems) {
                        [rawItems addObjectsFromArray:items];
                    }
                }
            }
            dispatch_group_leave(group);
        }];
        [task resume];
    }

    __weak QuickPOIShelfView *weakSelf = self;
    dispatch_group_notify(group, dispatch_get_global_queue(DISPATCH_QUEUE_PRIORITY_DEFAULT, 0), ^{
        dispatch_async(dispatch_get_main_queue(), ^{
            [weakSelf.spinner stopAnimating];
        });

        NSMutableArray *annotations = [NSMutableArray array];
        NSMutableSet *seenCoords = [NSMutableSet set];

        for (NSDictionary *d in rawItems) {
            double lat = [d[@"lat"] doubleValue];
            double lon = [d[@"lon"] doubleValue];

            // Deduplicate items very close to each other (~1.1m)
            NSString *coordKey = [NSString stringWithFormat:@"%.5f,%.5f", lat, lon];
            if ([seenCoords containsObject:coordKey]) continue;
            [seenCoords addObject:coordKey];

            NSDictionary *addr = [d[@"address"] isKindOfClass:[NSDictionary class]] ? d[@"address"] : nil;
            NSString *road = addr[@"road"] ?: addr[@"pedestrian"] ?: addr[@"footway"] ?: addr[@"street"] ?: addr[@"residential"];
            NSString *house = addr[@"house_number"];
            NSString *suburb = addr[@"suburb"] ?: addr[@"neighbourhood"] ?: addr[@"quarter"] ?: addr[@"city_district"];

            // Format complete street and building address (e.g. "вул. Богатирська, 1А")
            NSString *fullAddress = @"";
            if (road.length > 0 && house.length > 0) {
                fullAddress = [NSString stringWithFormat:@"%@, %@", road, house];
            } else if (road.length > 0) {
                fullAddress = road;
            } else if (suburb.length > 0) {
                fullAddress = suburb;
            }

            // POI Name: use official name or brand; never pure house number as title
            NSString *rawName = d[@"name"];
            if (!rawName || rawName.length == 0) {
                rawName = addr[@"amenity"] ?: addr[@"brand"] ?: addr[@"operator"] ?: addr[@"shop"];
            }
            NSString *disp = d[@"display_name"] ?: categoryName;
            NSArray *parts = [disp componentsSeparatedByString:@", "];
            NSString *title = (rawName.length > 0) ? rawName : nil;

            if (!title) {
                if ([query containsString:@"fuel"]) {
                    title = [NSString stringWithFormat:@"⛽ %@", categoryName];
                } else if ([query containsString:@"parking"]) {
                    title = [NSString stringWithFormat:@"🅿️ %@", categoryName];
                } else if ([query containsString:@"pharmacy"]) {
                    title = [NSString stringWithFormat:@"💊 %@", categoryName];
                } else if ([query containsString:@"restaurant"] || [query containsString:@"fast_food"]) {
                    title = (parts.count > 0 && ![parts[0] isEqualToString:road]) ? parts[0] : [NSString stringWithFormat:@"🍕 %@", categoryName];
                } else if ([query containsString:@"cafe"]) {
                    title = (parts.count > 0 && ![parts[0] isEqualToString:road]) ? parts[0] : [NSString stringWithFormat:@"☕ %@", categoryName];
                } else {
                    title = (parts.count > 0) ? parts[0] : categoryName;
                }
            } else {
                if ([query containsString:@"fuel"] && ![title hasPrefix:@"⛽"]) {
                    title = [NSString stringWithFormat:@"⛽ %@", title];
                }
            }

            // If title is just a house number or digits (e.g. "2" or "25" or "1A"), replace with category
            BOOL isNum = NO;
            if (house && [title isEqualToString:house]) {
                isNum = YES;
            } else if (title.length <= 4 && title.length > 0 && [[NSCharacterSet decimalDigitCharacterSet] characterIsMember:[title characterAtIndex:0]]) {
                isNum = YES;
            }

            if (isNum) {
                title = categoryName;
                if (fullAddress.length == 0 && parts.count > 1) {
                    fullAddress = [NSString stringWithFormat:@"%@, %@", parts[1], parts[0]];
                }
            }

            if (fullAddress.length == 0) {
                if (parts.count > 2) {
                    fullAddress = [NSString stringWithFormat:@"%@, %@", parts[1], parts[2]];
                } else if (parts.count > 1) {
                    fullAddress = parts[1];
                }
            }

            MKPointAnnotation *ann = [[MKPointAnnotation alloc] init];
            ann.coordinate = CLLocationCoordinate2DMake(lat, lon);
            ann.title = title;
            ann.subtitle = fullAddress;
            [annotations addObject:ann];
        }

        // Distance sorting: nearest to search viewport center first!
        CLLocation *centerLoc = [[CLLocation alloc] initWithLatitude:center.latitude longitude:center.longitude];
        [annotations sortUsingComparator:^NSComparisonResult(MKPointAnnotation *a1, MKPointAnnotation *a2) {
            CLLocation *loc1 = [[CLLocation alloc] initWithLatitude:a1.coordinate.latitude longitude:a1.coordinate.longitude];
            CLLocation *loc2 = [[CLLocation alloc] initWithLatitude:a2.coordinate.latitude longitude:a2.coordinate.longitude];
            CLLocationDistance d1 = [centerLoc distanceFromLocation:loc1];
            CLLocationDistance d2 = [centerLoc distanceFromLocation:loc2];
            return [@(d1) compare:@(d2)];
        }];

        if (annotations.count > 0) {
            dispatch_async(dispatch_get_global_queue(DISPATCH_QUEUE_PRIORITY_LOW, 0), ^{
                NSString *docs = [NSSearchPathForDirectoriesInDomains(NSDocumentDirectory, NSUserDomainMask, YES) firstObject];
                NSString *poiPath = [docs stringByAppendingPathComponent:@"offline_pois.plist"];
                NSMutableArray *stored = [NSMutableArray arrayWithContentsOfFile:poiPath] ?: [NSMutableArray array];
                NSMutableSet *existing = [NSMutableSet set];
                for (NSDictionary *d in stored) {
                    if (d[@"lat"] && d[@"lon"]) [existing addObject:[NSString stringWithFormat:@"%.4f,%.4f", [d[@"lat"] doubleValue], [d[@"lon"] doubleValue]]];
                }
                for (MKPointAnnotation *ann in annotations) {
                    NSString *key = [NSString stringWithFormat:@"%.4f,%.4f", ann.coordinate.latitude, ann.coordinate.longitude];
                    if (![existing containsObject:key]) {
                        [existing addObject:key];
                        [stored addObject:@{
                            @"title": ann.title ?: @"",
                            @"subtitle": ann.subtitle ?: @"",
                            @"lat": @(ann.coordinate.latitude),
                            @"lon": @(ann.coordinate.longitude)
                        }];
                    }
                }
                if (stored.count > 500) {
                    [stored removeObjectsInRange:NSMakeRange(0, stored.count - 500)];
                }
                [stored writeToFile:poiPath atomically:YES];
            });
        }

        dispatch_async(dispatch_get_main_queue(), ^{
            if ([weakSelf.delegate respondsToSelector:@selector(quickPOIShelfView:didFindPOIs:categoryName:)]) {
                [weakSelf.delegate quickPOIShelfView:weakSelf didFindPOIs:annotations categoryName:categoryName];
            }
        });
    });
}

@end

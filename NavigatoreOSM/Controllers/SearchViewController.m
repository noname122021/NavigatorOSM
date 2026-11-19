#import "SearchViewController.h"
#import "../Services/LocalizationManager.h"

@interface SearchItem : NSObject
@property (nonatomic, copy) NSString *title;
@property (nonatomic, copy) NSString *subtitle;
@property (nonatomic, copy) NSString *displayName;
@property (nonatomic, assign) CLLocationCoordinate2D coordinate;
@property (nonatomic, assign) CLLocationDistance distance;
@property (nonatomic, assign) BOOL isRecent;
@property (nonatomic, assign) BOOL isExactHouseNumber;
@end

@implementation SearchItem
@end

static NSString *const kRecentDestinationsKey = @"NavigatoreOSM_RecentDestinations";

@interface SearchViewController () <UISearchBarDelegate, UITableViewDataSource, UITableViewDelegate>
@property (nonatomic, strong) UISearchBar *searchBar;
@property (nonatomic, strong) UITableView *tableView;
@property (nonatomic, strong) NSMutableArray *results;
@property (nonatomic, strong) NSURLSession *session;
@property (nonatomic, strong) NSURLSessionDataTask *currentSearchTask;
@property (nonatomic, strong) UIActivityIndicatorView *spinner;
@property (nonatomic, strong) UILabel *statusLabel;
@property (nonatomic, assign) BOOL showMapAllButton;
@property (nonatomic, assign) BOOL showingRecents;
@end

@implementation SearchViewController

+ (NSArray *)recentDestinations {
    NSArray *recents = [[NSUserDefaults standardUserDefaults] arrayForKey:kRecentDestinationsKey];
    return recents ?: @[];
}

+ (void)saveRecentDestinationWithTitle:(NSString *)title coordinate:(CLLocationCoordinate2D)coordinate {
    if (!title || title.length == 0 || !CLLocationCoordinate2DIsValid(coordinate)) return;

    NSMutableArray *recents = [[self recentDestinations] mutableCopy];

    // Rimuovi duplicati vicini (< 250m) o con lo stesso titolo
    NSMutableArray *toRemove = [NSMutableArray array];
    for (NSDictionary *dict in recents) {
        double lat = [dict[@"lat"] doubleValue];
        double lon = [dict[@"lon"] doubleValue];
        NSString *existingTitle = dict[@"title"] ?: @"";
        if ([existingTitle isEqualToString:title] ||
            (fabs(lat - coordinate.latitude) < 0.0025 && fabs(lon - coordinate.longitude) < 0.0025)) {
            [toRemove addObject:dict];
        }
    }
    [recents removeObjectsInArray:toRemove];

    NSDictionary *newEntry = @{
        @"title": title,
        @"lat": @(coordinate.latitude),
        @"lon": @(coordinate.longitude),
        @"timestamp": @([[NSDate date] timeIntervalSince1970])
    };
    [recents insertObject:newEntry atIndex:0];

    // Mantieni al massimo 15 destinazioni recenti
    while (recents.count > 15) {
        [recents removeLastObject];
    }

    [[NSUserDefaults standardUserDefaults] setObject:recents forKey:kRecentDestinationsKey];
    [[NSUserDefaults standardUserDefaults] synchronize];
}

+ (void)clearRecentDestinations {
    [[NSUserDefaults standardUserDefaults] removeObjectForKey:kRecentDestinationsKey];
    [[NSUserDefaults standardUserDefaults] synchronize];
}

- (void)viewDidLoad {
    [super viewDidLoad];
    self.title = NLString(@"SEARCH_TITLE", @"Поиск места");
    self.view.backgroundColor = [UIColor colorWithWhite:0.12 alpha:1.0];

    self.results = [NSMutableArray array];
    self.showMapAllButton = NO;
    self.showingRecents = NO;

    NSURLSessionConfiguration *config = [NSURLSessionConfiguration defaultSessionConfiguration];
    config.timeoutIntervalForRequest = 8.0;
    config.HTTPAdditionalHeaders = @{
        @"User-Agent": @"NavigatoreOSM/1.3.17.1 (iPad; iOS 6.1; SearchEngine)"
    };
    self.session = [NSURLSession sessionWithConfiguration:config];

    // Barra superiore alta 64pt
    UIView *topBar = [[UIView alloc] initWithFrame:CGRectMake(0, 0, self.view.bounds.size.width, 64)];
    topBar.autoresizingMask = UIViewAutoresizingFlexibleWidth;
    topBar.backgroundColor = [UIColor colorWithWhite:0.16 alpha:1.0];
    topBar.userInteractionEnabled = YES;
    [self.view addSubview:topBar];

    // Pulsante Chiudi ad alto contrasto
    UIButton *closeBtn = [UIButton buttonWithType:UIButtonTypeCustom];
    closeBtn.frame = CGRectMake(topBar.bounds.size.width - 96, 12, 86, 40);
    closeBtn.autoresizingMask = UIViewAutoresizingFlexibleLeftMargin;
    closeBtn.backgroundColor = [UIColor colorWithRed:0.85 green:0.25 blue:0.25 alpha:0.9];
    closeBtn.layer.cornerRadius = 10.0;
    closeBtn.layer.masksToBounds = YES;
    [closeBtn setTitle:NLString(@"CLOSE", @"✕ Закрыть") forState:UIControlStateNormal];
    [closeBtn setTitleColor:[UIColor whiteColor] forState:UIControlStateNormal];
    closeBtn.titleLabel.font = [UIFont boldSystemFontOfSize:15.0];
    [closeBtn addTarget:self action:@selector(handleClose) forControlEvents:UIControlEventTouchUpInside];
    [topBar addSubview:closeBtn];

    CGFloat searchWidth = topBar.bounds.size.width - 116;

    // Search Bar
    self.searchBar = [[UISearchBar alloc] initWithFrame:CGRectMake(10, 10, searchWidth, 44)];
    self.searchBar.autoresizingMask = UIViewAutoresizingFlexibleWidth;
    self.searchBar.delegate = self;
    self.searchBar.placeholder = NLString(@"SEARCH_INPUT_PLACEHOLDER", @"Улица, дом, город или место...");
    self.searchBar.barStyle = UIBarStyleBlack;
    self.searchBar.tintColor = [UIColor colorWithWhite:0.16 alpha:1.0];
    [topBar addSubview:self.searchBar];

    // Gesture swipe verso il basso per chiudere
    UISwipeGestureRecognizer *swipeDown = [[UISwipeGestureRecognizer alloc] initWithTarget:self action:@selector(handleClose)];
    swipeDown.direction = UISwipeGestureRecognizerDirectionDown;
    [topBar addGestureRecognizer:swipeDown];

    // TableView
    self.tableView = [[UITableView alloc] initWithFrame:CGRectMake(0, 64, self.view.bounds.size.width, self.view.bounds.size.height - 64) style:UITableViewStylePlain];
    self.tableView.autoresizingMask = UIViewAutoresizingFlexibleWidth | UIViewAutoresizingFlexibleHeight;
    self.tableView.backgroundColor = [UIColor colorWithWhite:0.12 alpha:1.0];
    self.tableView.separatorColor = [UIColor colorWithWhite:0.25 alpha:1.0];
    self.tableView.dataSource = self;
    self.tableView.delegate = self;
    [self.view addSubview:self.tableView];

    // Spinner
    self.spinner = [[UIActivityIndicatorView alloc] initWithActivityIndicatorStyle:UIActivityIndicatorViewStyleWhiteLarge];
    self.spinner.center = CGPointMake(self.view.bounds.size.width / 2.0, 140);
    self.spinner.autoresizingMask = UIViewAutoresizingFlexibleLeftMargin | UIViewAutoresizingFlexibleRightMargin;
    self.spinner.hidesWhenStopped = YES;
    [self.view addSubview:self.spinner];

    // Status label (per feedback vocale "Sto ascoltando...")
    self.statusLabel = [[UILabel alloc] initWithFrame:CGRectMake(12, 68, self.view.bounds.size.width - 24, 38)];
    self.statusLabel.autoresizingMask = UIViewAutoresizingFlexibleWidth;
    self.statusLabel.backgroundColor = [UIColor colorWithRed:0.08 green:0.22 blue:0.38 alpha:0.95];
    self.statusLabel.layer.cornerRadius = 8.0;
    self.statusLabel.layer.masksToBounds = YES;
    self.statusLabel.textColor = [UIColor colorWithRed:0.4 green:0.85 blue:1.0 alpha:1.0];
    self.statusLabel.font = [UIFont boldSystemFontOfSize:15.0];
    self.statusLabel.textAlignment = NSTextAlignmentCenter;
    self.statusLabel.hidden = YES;
    [self.view addSubview:self.statusLabel];

    [self styleSearchField];
    [self loadRecentItems];
    [self.searchBar becomeFirstResponder];
}

- (void)loadRecentItems {
    [self.spinner stopAnimating];
    self.statusLabel.hidden = YES;
    [self.results removeAllObjects];
    self.showMapAllButton = NO;

    BOOL hasLoc = CLLocationCoordinate2DIsValid(self.userLocation) && self.userLocation.latitude != 0;
    CLLocation *uLoc = hasLoc ? [[CLLocation alloc] initWithLatitude:self.userLocation.latitude longitude:self.userLocation.longitude] : nil;

    NSArray *recents = [SearchViewController recentDestinations];
    for (NSDictionary *dict in recents) {
        SearchItem *item = [[SearchItem alloc] init];
        NSString *rawTitle = dict[@"title"] ?: NLString(@"SELECTED_DESTINATION", @"Точка назначения");
        NSArray *parts = [rawTitle componentsSeparatedByString:@", "];
        item.title = (parts.count > 0) ? parts[0] : rawTitle;
        item.subtitle = (parts.count > 1) ? [[parts subarrayWithRange:NSMakeRange(1, parts.count - 1)] componentsJoinedByString:@", "] : NLString(@"RECENT_DEST_SUB", @"Недавний адрес");
        item.displayName = rawTitle;
        item.coordinate = CLLocationCoordinate2DMake([dict[@"lat"] doubleValue], [dict[@"lon"] doubleValue]);
        item.isRecent = YES;
        if (uLoc) {
            CLLocation *iLoc = [[CLLocation alloc] initWithLatitude:item.coordinate.latitude longitude:item.coordinate.longitude];
            item.distance = [uLoc distanceFromLocation:iLoc];
        } else {
            item.distance = -1;
        }
        [self.results addObject:item];
    }
    self.showingRecents = (self.results.count > 0);
    [self.tableView reloadData];
}

- (void)viewDidLayoutSubviews {
    [super viewDidLayoutSubviews];
    [self styleSearchField];
}

- (void)styleSearchField {
    [self recursivelyStyleTextFieldInView:self.searchBar];
}

- (void)recursivelyStyleTextFieldInView:(UIView *)view {
    if ([view isKindOfClass:[UITextField class]]) {
        UITextField *tf = (UITextField *)view;
        tf.textColor = [UIColor blackColor];
        tf.keyboardAppearance = UIKeyboardAppearanceDefault;
        tf.font = [UIFont systemFontOfSize:16.0];
        @try {
            [tf setValue:[UIColor colorWithWhite:0.45 alpha:1.0] forKeyPath:@"_placeholderLabel.textColor"];
        } @catch (NSException *e) {}
        return;
    }
    for (UIView *sub in view.subviews) {
        [self recursivelyStyleTextFieldInView:sub];
    }
}

- (void)dismissKeyboard {
    [self.searchBar resignFirstResponder];
    [self.view endEditing:YES];
}

- (void)handleClose {
    [self.searchBar resignFirstResponder];
    [self dismissViewControllerAnimated:YES completion:nil];
}

#pragma mark - UISearchBarDelegate

- (void)searchBarTextDidBeginEditing:(UISearchBar *)searchBar {
    [self styleSearchField];
}

- (void)searchBar:(UISearchBar *)searchBar textDidChange:(NSString *)searchText {
    [NSObject cancelPreviousPerformRequestsWithTarget:self selector:@selector(triggerDebouncedSearch) object:nil];
    if (searchText.length == 0) {
        [self loadRecentItems];
    } else if (searchText.length >= 3) {
        // Ricerca as-you-type debounced a 450ms
        [self performSelector:@selector(triggerDebouncedSearch) withObject:nil afterDelay:0.45];
    }
}

- (void)triggerDebouncedSearch {
    NSString *query = self.searchBar.text;
    if (query.length >= 3) {
        [self performSearch:query];
    }
}

- (void)searchBarSearchButtonClicked:(UISearchBar *)searchBar {
    [searchBar resignFirstResponder];
    [NSObject cancelPreviousPerformRequestsWithTarget:self selector:@selector(triggerDebouncedSearch) object:nil];
    NSString *query = searchBar.text;
    if (query.length == 0) {
        [self loadRecentItems];
        return;
    }
    [self performSearch:query];
}

#pragma mark - Geocoding & Ricerca Indirizzi con Numeri Civici

// Estrae l'eventuale numero civico inserito dall'utente nella query (es. "Via Roma 10" -> "10")
- (NSString *)extractHouseNumberFromQuery:(NSString *)query {
    if (!query || query.length == 0) return nil;
    NSRegularExpression *regex = [NSRegularExpression regularExpressionWithPattern:@"\\b(\\d+[a-zA-Z]?)\\b" options:0 error:nil];
    NSTextCheckingResult *match = [regex firstMatchInString:query options:0 range:NSMakeRange(0, query.length)];
    if (match && match.range.location != NSNotFound) {
        return [query substringWithRange:match.range];
    }
    return nil;
}

- (void)performSearch:(NSString *)query {
    [self.currentSearchTask cancel];
    [self.spinner startAnimating];
    self.statusLabel.hidden = YES;
    [self.results removeAllObjects];
    self.showMapAllButton = NO;
    self.showingRecents = NO;
    [self.tableView reloadData];

    NSString *cleanLower = [[query stringByTrimmingCharactersInSet:[NSCharacterSet whitespaceCharacterSet]] lowercaseString];

    // Se l'utente cerca categorie generiche, cerca direttamente per tag OSM Nominatim (bounded nel raggio locale)
    NSString *categoryAmenity = nil;
    if ([cleanLower isEqualToString:@"заправка"] || [cleanLower isEqualToString:@"заправки"] || [cleanLower isEqualToString:@"азс"] ||
        [cleanLower isEqualToString:@"gas station"] || [cleanLower isEqualToString:@"fuel"] || [cleanLower isEqualToString:@"petrol station"]) {
        categoryAmenity = @"fuel";
    } else if ([cleanLower isEqualToString:@"еда"] || [cleanLower isEqualToString:@"ресторан"] || [cleanLower isEqualToString:@"рестораны"] ||
               [cleanLower isEqualToString:@"restaurant"] || [cleanLower isEqualToString:@"food"]) {
        categoryAmenity = @"restaurant";
    } else if ([cleanLower isEqualToString:@"кафе"] || [cleanLower isEqualToString:@"бар"] ||
               [cleanLower isEqualToString:@"cafe"] || [cleanLower isEqualToString:@"bar"]) {
        categoryAmenity = @"cafe";
    } else if ([cleanLower isEqualToString:@"аптека"] || [cleanLower isEqualToString:@"аптеки"] ||
               [cleanLower isEqualToString:@"pharmacy"]) {
        categoryAmenity = @"pharmacy";
    } else if ([cleanLower isEqualToString:@"парковка"] || [cleanLower isEqualToString:@"парковки"] ||
               [cleanLower isEqualToString:@"parking"]) {
        categoryAmenity = @"parking";
    }

    if (categoryAmenity) {
        [self performCategorySearch:categoryAmenity originalQuery:query];
        return;
    }

    NSString *effectiveQuery = query;
    BOOL hasProximity = CLLocationCoordinate2DIsValid(self.userLocation) && self.userLocation.latitude != 0;

    NSString *requestedHouseNumber = [[self extractHouseNumberFromQuery:effectiveQuery] copy];
    NSString *encodedQuery = [effectiveQuery stringByAddingPercentEncodingWithAllowedCharacters:[NSCharacterSet URLQueryAllowedCharacterSet]];
    NSString *lang = [[LocalizationManager sharedManager] currentLanguage];
    // Photon supports only 'default, de, en, fr'. If unsupported (ru, uk, it), omit to get native local OSM names.
    NSString *langParam = ([lang isEqualToString:@"de"] || [lang isEqualToString:@"en"] || [lang isEqualToString:@"fr"]) ? [NSString stringWithFormat:@"&lang=%@", lang] : @"";

    // STEP 1: Query primaria su Komoot Photon API (ottimizzata per OSM con civici e lat/lon bias)
    NSString *photonUrlStr;
    if (hasProximity) {
        photonUrlStr = [NSString stringWithFormat:@"https://photon.komoot.io/api/?q=%@&lat=%.4f&lon=%.4f&limit=15%@",
                        encodedQuery, self.userLocation.latitude, self.userLocation.longitude, langParam];
    } else {
        photonUrlStr = [NSString stringWithFormat:@"https://photon.komoot.io/api/?q=%@&limit=15%@", encodedQuery, langParam];
    }

    NSURL *photonURL = [NSURL URLWithString:photonUrlStr];
    __weak SearchViewController *weakSelf = self;

    self.currentSearchTask = [self.session dataTaskWithURL:photonURL completionHandler:^(NSData *data, NSURLResponse *response, NSError *error) {
        if (!error && data && data.length > 0) {
            NSArray *photonResults = [weakSelf parsePhotonResults:data requestedHouseNumber:requestedHouseNumber query:query];
            if (photonResults.count > 0) {
                dispatch_async(dispatch_get_main_queue(), ^{
                    [weakSelf.spinner stopAnimating];
                    weakSelf.results = [photonResults mutableCopy];
                    weakSelf.showMapAllButton = (photonResults.count >= 2);
                    [weakSelf.tableView reloadData];
                });
                return;
            }
        }

        // STEP 2: Fallback automatico su Nominatim OSM
        NSLog(@"[SearchViewController] Photon ha restituito 0 risultati o errore, fallback su Nominatim...");
        [weakSelf performNominatimFallbackSearch:query requestedHouseNumber:requestedHouseNumber];
    }];
    [self.currentSearchTask resume];
}

- (NSArray *)parsePhotonResults:(NSData *)data requestedHouseNumber:(NSString *)reqHN query:(NSString *)originalQuery {
    id json = [NSJSONSerialization JSONObjectWithData:data options:0 error:nil];
    if (![json isKindOfClass:[NSDictionary class]]) return @[];

    NSArray *features = json[@"features"];
    if (![features isKindOfClass:[NSArray class]] || features.count == 0) return @[];

    BOOL hasLoc = CLLocationCoordinate2DIsValid(self.userLocation) && self.userLocation.latitude != 0;
    CLLocation *uLoc = hasLoc ? [[CLLocation alloc] initWithLatitude:self.userLocation.latitude longitude:self.userLocation.longitude] : nil;

    NSMutableArray *items = [NSMutableArray array];
    for (NSDictionary *feat in features) {
        NSDictionary *props = feat[@"properties"];
        NSDictionary *geom = feat[@"geometry"];
        NSArray *coords = geom[@"coordinates"];
        if (!props || !coords || coords.count < 2) continue;

        double lon = [coords[0] doubleValue];
        double lat = [coords[1] doubleValue];

        NSString *street = props[@"street"];
        NSString *housenumber = props[@"housenumber"];
        NSString *name = props[@"name"];
        NSString *city = props[@"city"] ?: props[@"town"] ?: props[@"village"] ?: props[@"municipality"] ?: props[@"county"] ?: @"";
        NSString *state = props[@"state"] ?: @"";

        SearchItem *item = [[SearchItem alloc] init];
        item.coordinate = CLLocationCoordinate2DMake(lat, lon);
        if (uLoc) {
            CLLocation *iLoc = [[CLLocation alloc] initWithLatitude:lat longitude:lon];
            item.distance = [uLoc distanceFromLocation:iLoc];
        } else {
            item.distance = -1;
        }

        // Formattazione titolo e sottotitolo strutturati
        if (housenumber.length > 0 && street.length > 0) {
            item.isExactHouseNumber = YES;
            if (name.length > 0 && ![name isEqualToString:street]) {
                item.title = name;
                item.subtitle = [NSString stringWithFormat:@"%@ %@, %@", street, housenumber, city];
            } else {
                item.title = [NSString stringWithFormat:@"%@ %@", street, housenumber];
                item.subtitle = state.length > 0 ? [NSString stringWithFormat:@"%@ (%@)", city, state] : city;
            }
            item.displayName = [NSString stringWithFormat:@"%@ %@, %@", street, housenumber, city];
        } else if (street.length > 0) {
            if (reqHN.length > 0) {
                // L'utente aveva chiesto un civico ma OSM non lo ha censito: preservalo nel titolo!
                item.title = [NSString stringWithFormat:@"%@ %@", street, reqHN];
                item.subtitle = [NSString stringWithFormat:@"%@ %@", city, NLString(@"APPROX_HOUSE_NUMBER", @"• Примерный номер дома")];
                item.displayName = [NSString stringWithFormat:@"%@ %@, %@", street, reqHN, city];
                item.isExactHouseNumber = NO;
            } else {
                item.title = street;
                item.subtitle = state.length > 0 ? [NSString stringWithFormat:@"%@ (%@)", city, state] : city;
                item.displayName = city.length > 0 ? [NSString stringWithFormat:@"%@, %@", street, city] : street;
            }
        } else if (name.length > 0) {
            item.title = name;
            item.subtitle = state.length > 0 ? [NSString stringWithFormat:@"%@ (%@)", city, state] : city;
            item.displayName = city.length > 0 ? [NSString stringWithFormat:@"%@, %@", name, city] : name;
        } else {
            item.title = originalQuery;
            item.subtitle = city;
            item.displayName = originalQuery;
        }

        [items addObject:item];
    }

    if (hasLoc) {
        [items sortUsingComparator:^NSComparisonResult(SearchItem *a, SearchItem *b) {
            if (a.distance < b.distance) return NSOrderedAscending;
            if (a.distance > b.distance) return NSOrderedDescending;
            return NSOrderedSame;
        }];
    }

    return items;
}

- (void)performNominatimFallbackSearch:(NSString *)query requestedHouseNumber:(NSString *)reqHN {
    // Normalizzazione query per Nominatim: se contiene civico e non ha virgola, inserisci la virgola prima del numero
    NSString *normalizedQuery = query;
    if (reqHN.length > 0 && ![query containsString:@","]) {
        NSRange numRange = [query rangeOfString:reqHN];
        if (numRange.location != NSNotFound && numRange.location > 0) {
            NSString *prefix = [[query substringToIndex:numRange.location] stringByTrimmingCharactersInSet:[NSCharacterSet whitespaceCharacterSet]];
            NSString *suffix = [query substringFromIndex:numRange.location];
            normalizedQuery = [NSString stringWithFormat:@"%@, %@", prefix, suffix];
        }
    }

    NSString *encoded = [normalizedQuery stringByAddingPercentEncodingWithAllowedCharacters:[NSCharacterSet URLQueryAllowedCharacterSet]];
    NSString *urlString;
    NSString *lang = [[LocalizationManager sharedManager] currentLanguage];
    NSString *acceptLang = @"en";
    if ([lang isEqualToString:@"ru"]) acceptLang = @"ru,uk;q=0.9,en;q=0.5";
    else if ([lang isEqualToString:@"uk"]) acceptLang = @"uk,ru;q=0.9,en;q=0.5";
    else if ([lang isEqualToString:@"it"]) acceptLang = @"it,en;q=0.8";

    NSString *encodedLang = [acceptLang stringByAddingPercentEncodingWithAllowedCharacters:[NSCharacterSet URLQueryAllowedCharacterSet]];

    BOOL hasLocation = CLLocationCoordinate2DIsValid(self.userLocation) && self.userLocation.latitude != 0;
    if (hasLocation) {
        double delta = 0.50; // ~55 km radius around user
        urlString = [NSString stringWithFormat:
            @"https://nominatim.openstreetmap.org/search?format=json&q=%@&viewbox=%.4f,%.4f,%.4f,%.4f&bounded=0&limit=25&addressdetails=1&accept-language=%@",
            encoded,
            self.userLocation.longitude - delta, self.userLocation.latitude + delta,
            self.userLocation.longitude + delta, self.userLocation.latitude - delta,
            encodedLang];
    } else {
        urlString = [NSString stringWithFormat:@"https://nominatim.openstreetmap.org/search?format=json&q=%@&limit=25&addressdetails=1&accept-language=%@", encoded, encodedLang];
    }

    NSMutableURLRequest *req = [NSMutableURLRequest requestWithURL:[NSURL URLWithString:urlString]];
    req.timeoutInterval = 8.0;
    [req setValue:@"NavigatoreOSM-iOS6" forHTTPHeaderField:@"User-Agent"];
    [req setValue:acceptLang forHTTPHeaderField:@"Accept-Language"];

    __weak SearchViewController *weakSelf = self;
    self.currentSearchTask = [self.session dataTaskWithRequest:req completionHandler:^(NSData *data, NSURLResponse *response, NSError *error) {
        dispatch_async(dispatch_get_main_queue(), ^{
            [weakSelf.spinner stopAnimating];
        });

        if (error || !data) {
            [weakSelf showOfflineResultsForQuery:query];
            return;
        }

        NSArray *parsed = [weakSelf parseNominatimResults:data requestedHouseNumber:reqHN query:query];
        dispatch_async(dispatch_get_main_queue(), ^{
            if (parsed.count > 0) {
                weakSelf.results = [parsed mutableCopy];
                weakSelf.showMapAllButton = (parsed.count >= 2);
                [weakSelf.tableView reloadData];
            } else {
                [weakSelf showOfflineResultsForQuery:query];
            }
        });
    }];
    [self.currentSearchTask resume];
}

- (void)performCategorySearch:(NSString *)amenity originalQuery:(NSString *)query {
    BOOL hasLocation = CLLocationCoordinate2DIsValid(self.userLocation) && self.userLocation.latitude != 0;
    if (!hasLocation) {
        [self performNominatimFallbackSearch:query requestedHouseNumber:nil];
        return;
    }

    NSString *lang = [[LocalizationManager sharedManager] currentLanguage];
    NSString *acceptLang = @"en";
    if ([lang isEqualToString:@"ru"]) acceptLang = @"ru,uk;q=0.9,en;q=0.5";
    else if ([lang isEqualToString:@"uk"]) acceptLang = @"uk,ru;q=0.9,en;q=0.5";
    else if ([lang isEqualToString:@"it"]) acceptLang = @"it,en;q=0.8";

    NSString *encodedLang = [acceptLang stringByAddingPercentEncodingWithAllowedCharacters:[NSCharacterSet URLQueryAllowedCharacterSet]];
    double delta = 0.12; // ~13 km
    NSString *urlString = [NSString stringWithFormat:
        @"https://nominatim.openstreetmap.org/search?format=json&amenity=%@&viewbox=%.4f,%.4f,%.4f,%.4f&bounded=1&limit=25&addressdetails=1&accept-language=%@",
        amenity,
        self.userLocation.longitude - delta, self.userLocation.latitude + delta,
        self.userLocation.longitude + delta, self.userLocation.latitude - delta,
        encodedLang];

    NSMutableURLRequest *req = [NSMutableURLRequest requestWithURL:[NSURL URLWithString:urlString]];
    req.timeoutInterval = 8.0;
    [req setValue:@"NavigatoreOSM-iOS6" forHTTPHeaderField:@"User-Agent"];
    [req setValue:acceptLang forHTTPHeaderField:@"Accept-Language"];

    __weak SearchViewController *weakSelf = self;
    self.currentSearchTask = [self.session dataTaskWithRequest:req completionHandler:^(NSData *data, NSURLResponse *response, NSError *error) {
        dispatch_async(dispatch_get_main_queue(), ^{
            [weakSelf.spinner stopAnimating];
        });

        if (error || !data) {
            [weakSelf showOfflineResultsForQuery:query];
            return;
        }

        NSArray *parsed = [weakSelf parseNominatimResults:data requestedHouseNumber:nil query:query];
        dispatch_async(dispatch_get_main_queue(), ^{
            if (parsed.count > 0) {
                weakSelf.results = [parsed mutableCopy];
                weakSelf.showMapAllButton = (parsed.count >= 2);
                [weakSelf.tableView reloadData];
            } else {
                [weakSelf showOfflineResultsForQuery:query];
            }
        });
    }];
    [self.currentSearchTask resume];
}

- (NSArray *)parseNominatimResults:(NSData *)data requestedHouseNumber:(NSString *)reqHN query:(NSString *)originalQuery {
    NSArray *items = [NSJSONSerialization JSONObjectWithData:data options:0 error:nil];
    if (![items isKindOfClass:[NSArray class]] || items.count == 0) return @[];

    BOOL hasLoc = CLLocationCoordinate2DIsValid(self.userLocation) && self.userLocation.latitude != 0;
    CLLocation *uLoc = hasLoc ? [[CLLocation alloc] initWithLatitude:self.userLocation.latitude longitude:self.userLocation.longitude] : nil;

    NSMutableArray *newResults = [NSMutableArray array];
    for (NSDictionary *dict in items) {
        double lat = [dict[@"lat"] doubleValue];
        double lon = [dict[@"lon"] doubleValue];
        NSDictionary *addr = dict[@"address"];
        NSString *dispName = dict[@"display_name"] ?: @"";

        NSString *road = addr[@"road"] ?: addr[@"pedestrian"] ?: addr[@"footway"];
        NSString *houseNum = addr[@"house_number"];
        NSString *city = addr[@"city"] ?: addr[@"town"] ?: addr[@"village"] ?: addr[@"municipality"] ?: addr[@"county"] ?: @"";
        NSString *state = addr[@"state"] ?: @"";
        NSString *name = dict[@"name"] ?: @"";

        SearchItem *item = [[SearchItem alloc] init];
        item.coordinate = CLLocationCoordinate2DMake(lat, lon);
        if (uLoc) {
            CLLocation *iLoc = [[CLLocation alloc] initWithLatitude:lat longitude:lon];
            item.distance = [uLoc distanceFromLocation:iLoc];
        } else {
            item.distance = -1;
        }

        if (houseNum.length > 0 && road.length > 0) {
            item.isExactHouseNumber = YES;
            if (name.length > 0 && ![name isEqualToString:road]) {
                item.title = name;
                item.subtitle = [NSString stringWithFormat:@"%@ %@, %@", road, houseNum, city];
            } else {
                item.title = [NSString stringWithFormat:@"%@ %@", road, houseNum];
                item.subtitle = state.length > 0 ? [NSString stringWithFormat:@"%@ (%@)", city, state] : city;
            }
            item.displayName = [NSString stringWithFormat:@"%@ %@, %@", road, houseNum, city];
        } else if (road.length > 0) {
            if (reqHN.length > 0) {
                item.title = [NSString stringWithFormat:@"%@ %@", road, reqHN];
                item.subtitle = [NSString stringWithFormat:@"%@ %@", city, NLString(@"APPROX_HOUSE_NUMBER", @"• Примерный номер дома")];
                item.displayName = [NSString stringWithFormat:@"%@ %@, %@", road, reqHN, city];
                item.isExactHouseNumber = NO;
            } else {
                item.title = name.length > 0 ? name : road;
                item.subtitle = state.length > 0 ? [NSString stringWithFormat:@"%@ (%@)", city, state] : city;
                item.displayName = city.length > 0 ? [NSString stringWithFormat:@"%@, %@", road, city] : road;
            }
        } else {
            NSArray *parts = [dispName componentsSeparatedByString:@", "];
            item.title = name.length > 0 ? name : ((parts.count > 0) ? parts[0] : dispName);
            item.subtitle = (parts.count > 1) ? parts[1] : @"";
            item.displayName = dispName;
        }

        [newResults addObject:item];
    }

    if (hasLoc) {
        [newResults sortUsingComparator:^NSComparisonResult(SearchItem *a, SearchItem *b) {
            if (a.distance < b.distance) return NSOrderedAscending;
            if (a.distance > b.distance) return NSOrderedDescending;
            return NSOrderedSame;
        }];
    }
    return newResults;
}

- (void)showOfflineResultsForQuery:(NSString *)query {
    NSArray *offlineResults = [self offlineMatchesForQuery:query];
    dispatch_async(dispatch_get_main_queue(), ^{
        [self.spinner stopAnimating];
        if (offlineResults.count > 0) {
            self.results = [offlineResults mutableCopy];
            self.showMapAllButton = (offlineResults.count >= 2);
            self.statusLabel.hidden = YES;
            [self.tableView reloadData];
        } else {
            self.statusLabel.text = NLString(@"OFFLINE_SEARCH_NO_RESULTS", @"Нет сети и совпадений в оффлайн-кэше.");
            self.statusLabel.hidden = NO;
            [self.tableView reloadData];
        }
    });
}

- (NSArray *)offlineMatchesForQuery:(NSString *)query {
    NSMutableArray *matches = [NSMutableArray array];
    NSString *cleanQ = [query lowercaseString];

    // 1. Поиск по недавним сохраненным местам
    NSArray *recents = [SearchViewController recentDestinations];
    for (NSDictionary *dict in recents) {
        NSString *title = dict[@"title"] ?: @"";
        if ([[title lowercaseString] containsString:cleanQ]) {
            SearchItem *item = [[SearchItem alloc] init];
            item.title = title;
            item.subtitle = NLString(@"RECENT_OFFLINE_BADGE", @"🕒 Недавнее (из кэша)");
            item.displayName = title;
            item.coordinate = CLLocationCoordinate2DMake([dict[@"lat"] doubleValue], [dict[@"lon"] doubleValue]);
            item.isRecent = YES;
            [matches addObject:item];
        }
    }

    // 2. Поиск по сохраненным оффлайн-точкам (offline_pois.plist)
    NSString *docs = [NSSearchPathForDirectoriesInDomains(NSDocumentDirectory, NSUserDomainMask, YES) firstObject];
    NSString *poiPath = [docs stringByAppendingPathComponent:@"offline_pois.plist"];
    NSArray *offlinePOIs = [NSArray arrayWithContentsOfFile:poiPath];
    for (NSDictionary *dict in offlinePOIs) {
        NSString *title = dict[@"title"] ?: @"";
        NSString *subtitle = dict[@"subtitle"] ?: @"";
        if ([[title lowercaseString] containsString:cleanQ] || [[subtitle lowercaseString] containsString:cleanQ]) {
            SearchItem *item = [[SearchItem alloc] init];
            item.title = title;
            item.subtitle = subtitle.length > 0 ? [NSString stringWithFormat:@"💾 %@", subtitle] : @"💾 Оффлайн";
            item.displayName = title;
            item.coordinate = CLLocationCoordinate2DMake([dict[@"lat"] doubleValue], [dict[@"lon"] doubleValue]);
            [matches addObject:item];
        }
    }

    return matches;
}

#pragma mark - Show All POIs On Map

- (void)showAllResultsOnMap {
    if (self.results.count == 0) return;

    NSMutableArray *annotations = [NSMutableArray array];
    for (SearchItem *item in self.results) {
        MKPointAnnotation *ann = [[MKPointAnnotation alloc] init];
        ann.coordinate = item.coordinate;
        ann.title = item.title;
        ann.subtitle = item.subtitle;
        [annotations addObject:ann];
    }

    NSString *category = self.searchBar.text ?: NLString(@"SEARCH_RESULTS", @"Результаты поиска");

    [self dismissViewControllerAnimated:YES completion:^{
        if ([self.delegate respondsToSelector:@selector(searchViewControllerDidRequestShowAllPOIs:categoryName:)]) {
            [self.delegate searchViewControllerDidRequestShowAllPOIs:annotations categoryName:category];
        }
    }];
}

#pragma mark - UITableViewDataSource & Delegate

- (NSInteger)tableView:(UITableView *)tableView numberOfRowsInSection:(NSInteger)section {
    if (self.showingRecents) {
        return self.results.count + 1; // +1 per pulsante "Cancella cronologia"
    }
    NSInteger extra = self.showMapAllButton ? 1 : 0;
    return self.results.count + extra;
}

- (NSString *)tableView:(UITableView *)tableView titleForHeaderInSection:(NSInteger)section {
    if (self.showingRecents) {
        return NLString(@"RECENT_DESTINATIONS", @"🕒 НЕДАВНИЕ МЕСТА");
    } else if (self.results.count > 0) {
        return [NSString stringWithFormat:NLString(@"SEARCH_RESULTS_FOR", @"РЕЗУЛЬТАТЫ ПО \"%@\""), self.searchBar.text ?: @""];
    }
    return nil;
}

- (UITableViewCell *)tableView:(UITableView *)tableView cellForRowAtIndexPath:(NSIndexPath *)indexPath {
    // Ultima riga dei recenti: pulsante "Cancella cronologia"
    if (self.showingRecents && indexPath.row == self.results.count) {
        UITableViewCell *clearCell = [tableView dequeueReusableCellWithIdentifier:@"ClearRecentsCell"];
        if (!clearCell) {
            clearCell = [[UITableViewCell alloc] initWithStyle:UITableViewCellStyleDefault reuseIdentifier:@"ClearRecentsCell"];
            clearCell.backgroundColor = [UIColor colorWithWhite:0.15 alpha:1.0];
            clearCell.textLabel.textColor = [UIColor colorWithRed:0.95 green:0.4 blue:0.4 alpha:1.0];
            clearCell.textLabel.font = [UIFont systemFontOfSize:14.0];
            clearCell.textLabel.textAlignment = NSTextAlignmentCenter;
        }
        clearCell.textLabel.text = NLString(@"CLEAR_HISTORY", @"✕ Очистить историю");
        return clearCell;
    }

    // Prima riga: pulsante "Mostra tutti sulla mappa"
    if (self.showMapAllButton && indexPath.row == 0 && !self.showingRecents) {
        UITableViewCell *mapCell = [tableView dequeueReusableCellWithIdentifier:@"MapAllCell"];
        if (!mapCell) {
            mapCell = [[UITableViewCell alloc] initWithStyle:UITableViewCellStyleDefault reuseIdentifier:@"MapAllCell"];
            mapCell.backgroundColor = [UIColor colorWithRed:0.1 green:0.3 blue:0.55 alpha:1.0];
            mapCell.textLabel.textColor = [UIColor whiteColor];
            mapCell.textLabel.font = [UIFont boldSystemFontOfSize:15.0];
            mapCell.textLabel.textAlignment = NSTextAlignmentCenter;
        }
        mapCell.textLabel.text = [NSString stringWithFormat:NLString(@"SHOW_ALL_MAP", @"📍 Показать все %lu на карте"), (unsigned long)self.results.count];
        return mapCell;
    }

    static NSString *cellId = @"SearchCell";
    UITableViewCell *cell = [tableView dequeueReusableCellWithIdentifier:cellId];
    if (!cell) {
        cell = [[UITableViewCell alloc] initWithStyle:UITableViewCellStyleSubtitle reuseIdentifier:cellId];
        cell.backgroundColor = [UIColor colorWithWhite:0.18 alpha:1.0];
        cell.textLabel.backgroundColor = [UIColor clearColor];
        cell.textLabel.textColor = [UIColor whiteColor];
        cell.textLabel.font = [UIFont boldSystemFontOfSize:15.0];
        cell.detailTextLabel.backgroundColor = [UIColor clearColor];
        cell.detailTextLabel.textColor = [UIColor colorWithWhite:0.75 alpha:1.0];
        cell.detailTextLabel.font = [UIFont systemFontOfSize:13.0];
    }

    NSInteger resultIndex = (self.showMapAllButton && !self.showingRecents) ? (indexPath.row - 1) : indexPath.row;
    SearchItem *item = self.results[resultIndex];

    if (self.showingRecents) {
        cell.textLabel.text = [NSString stringWithFormat:@"🕒 %@", item.title];
    } else {
        cell.textLabel.text = item.title;
    }

    if (item.distance >= 0) {
        NSString *distStr = NLFormatDistance(item.distance);
        if (item.subtitle.length > 0) {
            cell.detailTextLabel.text = [NSString stringWithFormat:@"%@ • %@", distStr, item.subtitle];
        } else {
            cell.detailTextLabel.text = distStr;
        }
    } else {
        cell.detailTextLabel.text = item.subtitle;
    }

    return cell;
}

- (void)scrollViewWillBeginDragging:(UIScrollView *)scrollView {
    [self.searchBar resignFirstResponder];
}

- (void)tableView:(UITableView *)tableView didSelectRowAtIndexPath:(NSIndexPath *)indexPath {
    [tableView deselectRowAtIndexPath:indexPath animated:YES];

    if (self.showingRecents && indexPath.row == self.results.count) {
        [SearchViewController clearRecentDestinations];
        [self loadRecentItems];
        return;
    }

    if (self.showMapAllButton && indexPath.row == 0 && !self.showingRecents) {
        [self showAllResultsOnMap];
        return;
    }

    NSInteger resultIndex = (self.showMapAllButton && !self.showingRecents) ? (indexPath.row - 1) : indexPath.row;
    if (resultIndex < 0 || resultIndex >= (NSInteger)self.results.count) {
        return;
    }
    SearchItem *selected = self.results[resultIndex];
    if (!selected) return;

    CLLocationCoordinate2D selectedCoord = selected.coordinate;
    NSString *selectedTitle = [selected.displayName copy] ?: [selected.title copy];

    [SearchViewController saveRecentDestinationWithTitle:selectedTitle coordinate:selectedCoord];

    [self.searchBar resignFirstResponder];

    id<SearchViewControllerDelegate> delegate = self.delegate;
    if ([delegate respondsToSelector:@selector(searchViewControllerDidSelectLocation:title:)]) {
        [delegate searchViewControllerDidSelectLocation:selectedCoord title:selectedTitle];
    }
    [self dismissViewControllerAnimated:YES completion:nil];
}

@end

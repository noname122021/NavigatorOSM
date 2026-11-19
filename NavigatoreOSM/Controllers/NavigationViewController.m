#import "NavigationViewController.h"
#import "SearchViewController.h"
#import "SettingsViewController.h"
#import "RouteSummaryViewController.h"
#import "../Overlays/OSMTileOverlay.h"
#import "../Overlays/OSMTileOverlayView.h"
#import "../Overlays/TrafficTileOverlay.h"
#import "../Services/RoutingService.h"
#import "../Services/VoiceGuidanceService.h"
#import "../Services/NetworkGPSReceiver.h"
#import "../Views/SpeedometerView.h"
#import "../Views/ManeuverHUDView.h"
#import "../Views/ModernTripBarView.h"
#import "../Views/RouteSelectorView.h"
#import "../Views/QuickPOIShelfView.h"
#import "../Views/POIResultsCardView.h"
#import "../Services/LocalizationManager.h"
#import "../Services/FuelPriceService.h"
#import "../Services/RouteTrackingEngine.h"
#import "../Views/VehicleAnnotationView.h"
#import "../Services/SpeedCameraService.h"
#import "../Views/SpeedCameraAnnotationView.h"
#import "../Views/FuelStationAnnotationView.h"
#import <AudioToolbox/AudioToolbox.h>

@interface NavigationViewController () <SearchViewControllerDelegate, NetworkGPSReceiverDelegate, RouteSelectorViewDelegate, QuickPOIShelfViewDelegate, SettingsViewControllerDelegate, POIResultsCardViewDelegate, RouteSummaryViewControllerDelegate, RouteTrackingEngineDelegate, UIGestureRecognizerDelegate>

@property (nonatomic, strong) OSMTileOverlay *osmOverlay;
@property (nonatomic, strong) TrafficTileOverlay *trafficOverlay;
@property (nonatomic, strong) CLLocationManager *locationManager;
@property (nonatomic, strong) CLLocation *currentLocation;
@property (nonatomic, assign) CLLocationDirection currentHeading;

// Motore di Tracciamento & Dead Reckoning
@property (nonatomic, strong) RouteTrackingEngine *trackingEngine;
@property (nonatomic, strong) VehicleAnnotation *vehicleAnnotation;
@property (nonatomic, strong) CADisplayLink *displayLink;
@property (nonatomic, assign) CFTimeInterval lastFrameTime;
@property (nonatomic, assign) BOOL isTrackingVehicle;
@property (nonatomic, assign) BOOL hasPerformedInitialZoom;
@property (nonatomic, assign) BOOL isCruisingWithVehiclePuck;

// UI HUD Moderna Waze / Google Maps
@property (nonatomic, strong) ManeuverHUDView *maneuverHUD;
@property (nonatomic, strong) ModernTripBarView *tripBar;
@property (nonatomic, strong) SpeedometerView *speedometer;
@property (nonatomic, strong) RouteSelectorView *routeSelector;
@property (nonatomic, strong) QuickPOIShelfView *poiShelf;
@property (nonatomic, strong) POIResultsCardView *poiResultsCard;

// Allerta Autovelox in avvicinamento
@property (nonatomic, strong) UIView *cameraAlertBanner;
@property (nonatomic, strong) UILabel *cameraAlertLabel;
@property (nonatomic, assign) long long lastAlertedCameraId;
@property (nonatomic, strong) NSDate *lastCameraAlertDate;
@property (nonatomic, strong) NSMutableArray *cameraAnnotations;
@property (nonatomic, assign) NSTimeInterval lastCameraCheckTime;
@property (nonatomic, assign) BOOL hasFetchedInitialCameras;

// Toast HUD per feedback immediato
@property (nonatomic, strong) UILabel *toastLabel;

// Ricalcolo Intelligente & Deviazione Volontaria
@property (nonatomic, strong) UIButton *detourRecalculateButton;
@property (nonatomic, strong) NSDate *lastRerouteDate;
@property (nonatomic, strong) NSDate *lastRerouteSpokenDate;
@property (nonatomic, assign) NSUInteger consecutiveRerouteAttempts;

// Distributori Carburante su Mappa
@property (nonatomic, strong) NSMutableArray *fuelAnnotations;
@property (nonatomic, assign) BOOL hasFetchedInitialFuelStations;
@property (nonatomic, assign) NSTimeInterval lastTilePrefetchTime;
@property (nonatomic, strong) UIButton *fuelToggleButton;
@property (nonatomic, assign) BOOL isFuelVisibleDuringNavigation;

// Controlli Flottanti (FAB)
@property (nonatomic, strong) UIButton *topSearchPill;
@property (nonatomic, strong) UIButton *recenterButton;
@property (nonatomic, strong) UIButton *trafficButton;
@property (nonatomic, strong) UIButton *settingsButton;
@property (nonatomic, strong) UILabel *gpsSourceLabel;

// Navigazione
@property (nonatomic, strong) NSArray *availableRoutes;
@property (nonatomic, strong) RouteInfo *currentRoute;
@property (nonatomic, assign) NSUInteger currentStepIndex;
@property (nonatomic, assign) BOOL isNavigating;
@property (nonatomic, assign) NSInteger offRouteConsecutiveCount;
@property (nonatomic, strong) NSMutableArray *poiAnnotations;
@property (nonatomic, strong) MKPointAnnotation *destinationPin;
@property (nonatomic, assign) NSUInteger currentRouteRequestId;

@end

@implementation NavigationViewController

- (void)viewDidLoad {
    [super viewDidLoad];
    self.view.backgroundColor = [UIColor blackColor];

    // 1. Evita assolutamente lo spegnimento dello schermo durante la guida!
    [UIApplication sharedApplication].idleTimerDisabled = YES;

    // 2. Mappa Nativa con MapKit (a schermo intero)
    self.mapView = [[MKMapView alloc] initWithFrame:self.view.bounds];
    self.mapView.autoresizingMask = UIViewAutoresizingFlexibleWidth | UIViewAutoresizingFlexibleHeight;
    self.mapView.delegate = self;
    self.mapView.showsUserLocation = YES;

    // Long-press per impostare rapidamente una destinazione toccando la mappa
    UILongPressGestureRecognizer *longPress = [[UILongPressGestureRecognizer alloc] initWithTarget:self action:@selector(handleMapLongPress:)];
    longPress.minimumPressDuration = 0.6;
    [self.mapView addGestureRecognizer:longPress];

    [self.view addSubview:self.mapView];

    // 3. Sovrapponi layer mappa OSM Standard / Offline MBTiles
    self.mapView.mapType = MKMapTypeStandard;
    self.osmOverlay = [[OSMTileOverlay alloc] init];
    [self.mapView insertOverlay:self.osmOverlay atIndex:0];

    // 4. Layer Traffico in tempo reale
    self.trafficOverlay = [TrafficTileOverlay sharedOverlay];
    if (self.trafficOverlay.isEnabled) {
        [self.mapView addOverlay:self.trafficOverlay];
    }

    // 4b. Inizializza Motore di Tracciamento & Annotazione Veicolo (Dead Reckoning a 30 FPS)
    self.trackingEngine = [[RouteTrackingEngine alloc] init];
    self.trackingEngine.delegate = self;
    self.vehicleAnnotation = [[VehicleAnnotation alloc] init];
    self.isTrackingVehicle = YES;
    self.hasPerformedInitialZoom = NO;
    self.isCruisingWithVehiclePuck = NO;

    // 5. Configura GPS Nativo (Apple CoreLocation)
    self.locationManager = [[CLLocationManager alloc] init];
    self.locationManager.delegate = self;
    self.locationManager.desiredAccuracy = kCLLocationAccuracyBestForNavigation;
    self.locationManager.activityType = CLActivityTypeAutomotiveNavigation;
    self.locationManager.distanceFilter = 1.0;
    self.locationManager.headingFilter = 2.0;

    if ([self.locationManager respondsToSelector:@selector(requestWhenInUseAuthorization)]) {
        [self.locationManager performSelector:@selector(requestWhenInUseAuthorization)];
    }
    [self.locationManager startUpdatingLocation];
    [self.locationManager startUpdatingHeading];

    // 6. Ricevitore GPS di rete (UDP o TCP) per tethering da Android con impostazioni persistenti
    [NetworkGPSReceiver sharedReceiver].delegate = self;
    [[NetworkGPSReceiver sharedReceiver] startWithSavedSettings];

    UIPanGestureRecognizer *mapPan = [[UIPanGestureRecognizer alloc] initWithTarget:self action:@selector(handleMapPan:)];
    mapPan.delegate = self;
    [self.mapView addGestureRecognizer:mapPan];

    UIPinchGestureRecognizer *mapPinch = [[UIPinchGestureRecognizer alloc] initWithTarget:self action:@selector(handleMapPinch:)];
    mapPinch.delegate = self;
    [self.mapView addGestureRecognizer:mapPinch];

    self.poiAnnotations = [NSMutableArray array];

    // 7. Costruisci l'interfaccia grafica moderna in stile Google Maps / Waze
    [self setupModernUI];

    [[NSNotificationCenter defaultCenter] addObserver:self
                                             selector:@selector(handleLanguageChanged:)
                                                 name:kAppLanguagePreferenceChangedNotification
                                               object:nil];
    [[NSNotificationCenter defaultCenter] addObserver:self
                                             selector:@selector(handleAppDidEnterBackground)
                                                 name:UIApplicationDidEnterBackgroundNotification
                                               object:nil];
    [[NSNotificationCenter defaultCenter] addObserver:self
                                             selector:@selector(handleAppWillEnterForeground)
                                                 name:UIApplicationWillEnterForegroundNotification
                                               object:nil];

    // Map ready
}

- (void)handleAppDidEnterBackground {
    self.displayLink.paused = YES;
}

- (void)handleAppWillEnterForeground {
    self.lastFrameTime = CACurrentMediaTime();
    self.displayLink.paused = NO;
}

- (void)viewWillAppear:(BOOL)animated {
    [super viewWillAppear:animated];
    [UIApplication sharedApplication].idleTimerDisabled = YES;
    if (self.isNavigating && self.currentRoute) {
        [self updateCameraAnnotationsOnMap];
    }
}

#pragma mark - Setup UI Moderna (Google Maps / Waze)

- (void)setupModernUI {
    CGFloat w = self.view.bounds.size.width;
    CGFloat h = self.view.bounds.size.height;

    __weak NavigationViewController *weakSelf = self;

    // 1. Barra di Ricerca a Pillola Flottante Superiore (Stile Google Maps)
    CGFloat pillW = MIN(380, w - 48);
    self.topSearchPill = [UIButton buttonWithType:UIButtonTypeCustom];
    self.topSearchPill.frame = CGRectMake(24, 20, pillW, 48);
    self.topSearchPill.backgroundColor = [UIColor colorWithWhite:0.12 alpha:0.95];
    self.topSearchPill.layer.cornerRadius = 24.0;
    self.topSearchPill.layer.borderColor = [[UIColor colorWithWhite:0.35 alpha:0.7] CGColor];
    self.topSearchPill.layer.borderWidth = 1.0;
    self.topSearchPill.layer.shadowColor = [[UIColor blackColor] CGColor];
    self.topSearchPill.layer.shadowPath = [UIBezierPath bezierPathWithRoundedRect:self.topSearchPill.bounds cornerRadius:24.0].CGPath;
    self.topSearchPill.layer.shadowOpacity = 0.30;
    self.topSearchPill.layer.shadowRadius = 4.0;
    self.topSearchPill.layer.shadowOffset = CGSizeMake(0, 2);
    [self.topSearchPill setTitle:NLString(@"SEARCH_PLACEHOLDER", @"  🔍 Поиск места или адреса...") forState:UIControlStateNormal];
    [self.topSearchPill setTitleColor:[UIColor colorWithWhite:0.9 alpha:1.0] forState:UIControlStateNormal];
    self.topSearchPill.titleLabel.font = [UIFont systemFontOfSize:15.0];
    self.topSearchPill.contentHorizontalAlignment = UIControlContentHorizontalAlignmentLeft;
    self.topSearchPill.contentEdgeInsets = UIEdgeInsetsMake(0, 16, 0, 16);
    [self.topSearchPill addTarget:self action:@selector(openSearch) forControlEvents:UIControlEventTouchUpInside];
    [self.view addSubview:self.topSearchPill];

    // 2. Barra POI Rapida a Pillole (Benzina, Ristoranti, Parcheggi, Bar, Farmacie)
    self.poiShelf = [[QuickPOIShelfView alloc] initWithFrame:CGRectMake(24, 76, MIN(420, w - 48), 46)];
    self.poiShelf.delegate = self;
    [self.view addSubview:self.poiShelf];

    // 3. Scheda Manovre Smeraldo Stile Waze (Nascosta prima di avviare la navigazione)
    self.maneuverHUD = [[ManeuverHUDView alloc] initWithFrame:CGRectMake(24, 20, 380, 108)];
    self.maneuverHUD.autoresizingMask = UIViewAutoresizingFlexibleRightMargin | UIViewAutoresizingFlexibleBottomMargin;
    self.maneuverHUD.onTapBlock = ^{
        [weakSelf showRouteSummary];
    };
    self.maneuverHUD.hidden = YES;
    [self.view addSubview:self.maneuverHUD];

    // 3b. Pulsante Flottante Toggle Distributori in Alto a Destra (visibile solo durante la rotta)
    // NB: la bussola nativa di MapKit occupa l'angolo in alto a destra (circa 40pt).
    // Riserviamo quello spazio spostando il pulsante ⛽ a sinistra della bussola, così da
    // mantenere entrambi visibili e correttamente spaziati anche in orientamento 3D/ruotato.
    CGFloat fuelBtnSize = 48.0;
    CGFloat compassReservedWidth = 56.0;
    CGFloat fuelBtnX = w - fuelBtnSize - 16.0 - compassReservedWidth;
    if (fuelBtnX < 24.0) {
        fuelBtnX = 24.0;
    }
    self.fuelToggleButton = [self createCircularButtonWithTitle:@"⛽" frame:CGRectMake(fuelBtnX, 20, fuelBtnSize, fuelBtnSize)];
    self.fuelToggleButton.autoresizingMask = UIViewAutoresizingFlexibleLeftMargin | UIViewAutoresizingFlexibleBottomMargin;
    [self.fuelToggleButton addTarget:self action:@selector(toggleFuelStationsOnMap) forControlEvents:UIControlEventTouchUpInside];
    self.fuelToggleButton.hidden = YES;
    self.fuelToggleButton.alpha = 0.0;
    [self.view addSubview:self.fuelToggleButton];

    // 4. Barra di Viaggio Inferiore Stile Google Maps (ETA grande, minuti, km, tasto stop)
    self.tripBar = [[ModernTripBarView alloc] initWithFrame:CGRectMake(24, h - 86, MIN(440, w - 48), 68)];
    self.tripBar.autoresizingMask = UIViewAutoresizingFlexibleRightMargin | UIViewAutoresizingFlexibleTopMargin;
    self.tripBar.onExitBlock = ^{
        [weakSelf cancelCurrentRoute];
    };
    self.tripBar.hidden = YES;
    [self.view addSubview:self.tripBar];

    // 5. Tachimetro Circolare Stile Waze in basso a sinistra
    self.speedometer = [[SpeedometerView alloc] initWithFrame:CGRectMake(24, h - 195, 96, 96)];
    self.speedometer.autoresizingMask = UIViewAutoresizingFlexibleRightMargin | UIViewAutoresizingFlexibleTopMargin;
    [self.view addSubview:self.speedometer];

    // 6. Pillola di stato GPS (visibile solo durante la ricerca del segnale o perdita fix)
    self.gpsSourceLabel = [[UILabel alloc] initWithFrame:CGRectMake((w - 240) / 2.0, 70, 240, 26)];
    self.gpsSourceLabel.autoresizingMask = UIViewAutoresizingFlexibleLeftMargin | UIViewAutoresizingFlexibleRightMargin | UIViewAutoresizingFlexibleBottomMargin;
    self.gpsSourceLabel.backgroundColor = [UIColor colorWithWhite:0.1 alpha:0.85];
    self.gpsSourceLabel.textColor = [UIColor whiteColor];
    self.gpsSourceLabel.textAlignment = NSTextAlignmentCenter;
    self.gpsSourceLabel.font = [UIFont boldSystemFontOfSize:12.0];
    self.gpsSourceLabel.layer.cornerRadius = 13.0;
    self.gpsSourceLabel.layer.masksToBounds = YES;
    self.gpsSourceLabel.text = NLString(@"GPS_SEARCHING", @"📡 Поиск сигнала GPS...");
    self.gpsSourceLabel.hidden = NO;
    [self.view addSubview:self.gpsSourceLabel];

    // 7. TOOLBAR VERTICALE COLLAPSIBLE a destra
    [self setupVerticalToolbar];

    // 8. Selettore Itinerari Multipli in basso (con opzioni al volo No Pedaggio/No Autostrade e costi)
    self.routeSelector = [[RouteSelectorView alloc] initWithFrame:CGRectMake(20, h - 245, w - 40, 230)];
    self.routeSelector.autoresizingMask = UIViewAutoresizingFlexibleWidth | UIViewAutoresizingFlexibleTopMargin;
    self.routeSelector.delegate = self;
    self.routeSelector.hidden = YES;
    [self.view addSubview:self.routeSelector];

    // 9. Scheda Risultati POI
    self.poiResultsCard = [[POIResultsCardView alloc] initWithFrame:CGRectMake(20, h - 170, w - 40, 155)];
    self.poiResultsCard.autoresizingMask = UIViewAutoresizingFlexibleWidth | UIViewAutoresizingFlexibleTopMargin;
    self.poiResultsCard.delegate = self;
    [self.view addSubview:self.poiResultsCard];

    self.cameraAnnotations = [NSMutableArray array];
    self.fuelAnnotations = [NSMutableArray array];

    // Pulsante Flottante Deviazione Volontaria / Ricalcolo Discreto
    self.detourRecalculateButton = [UIButton buttonWithType:UIButtonTypeCustom];
    self.detourRecalculateButton.frame = CGRectMake((w - 240) / 2.0, 134, 240, 40);
    self.detourRecalculateButton.autoresizingMask = UIViewAutoresizingFlexibleLeftMargin | UIViewAutoresizingFlexibleRightMargin | UIViewAutoresizingFlexibleBottomMargin;
    self.detourRecalculateButton.backgroundColor = [UIColor colorWithRed:0.95 green:0.45 blue:0.10 alpha:0.95];
    self.detourRecalculateButton.layer.cornerRadius = 20.0;
    self.detourRecalculateButton.layer.borderColor = [[UIColor whiteColor] CGColor];
    self.detourRecalculateButton.layer.borderWidth = 1.5;
    [self.detourRecalculateButton setTitle:NLString(@"DETOUR_REROUTE", @"⚠️ Fuori rotta • 🔄 Ricalcola") forState:UIControlStateNormal];
    [self.detourRecalculateButton setTitleColor:[UIColor whiteColor] forState:UIControlStateNormal];
    self.detourRecalculateButton.titleLabel.font = [UIFont boldSystemFontOfSize:13.5];
    [self.detourRecalculateButton addTarget:self action:@selector(handleDetourRecalculateTapped) forControlEvents:UIControlEventTouchUpInside];
    self.detourRecalculateButton.hidden = YES;
    [self.view addSubview:self.detourRecalculateButton];

    // Toast HUD compatto per feedback al tocco
    self.toastLabel = [[UILabel alloc] initWithFrame:CGRectMake((w - 280) / 2.0, 80, 280, 36)];
    self.toastLabel.autoresizingMask = UIViewAutoresizingFlexibleLeftMargin | UIViewAutoresizingFlexibleRightMargin;
    self.toastLabel.backgroundColor = [UIColor colorWithWhite:0.1 alpha:0.92];
    self.toastLabel.textColor = [UIColor whiteColor];
    self.toastLabel.textAlignment = NSTextAlignmentCenter;
    self.toastLabel.font = [UIFont boldSystemFontOfSize:14.0];
    self.toastLabel.layer.cornerRadius = 18.0;
    self.toastLabel.layer.masksToBounds = YES;
    self.toastLabel.layer.borderColor = [[UIColor colorWithWhite:0.3 alpha:0.8] CGColor];
    self.toastLabel.layer.borderWidth = 1.0;
    self.toastLabel.alpha = 0.0;
    self.toastLabel.hidden = YES;
    [self.view addSubview:self.toastLabel];

    [[NSNotificationCenter defaultCenter] addObserver:self
                                             selector:@selector(updateFuelAnnotationsOnMap)
                                                 name:kFuelPricesUpdatedNotification
                                               object:nil];


    // 10. Banner Allerta Autovelox in Avvicinamento
    CGFloat bannerW = MIN(380, w - 48);
    self.cameraAlertBanner = [[UIView alloc] initWithFrame:CGRectMake(24, 134, bannerW, 38)];
    self.cameraAlertBanner.autoresizingMask = UIViewAutoresizingFlexibleRightMargin | UIViewAutoresizingFlexibleBottomMargin;
    self.cameraAlertBanner.backgroundColor = [UIColor colorWithRed:0.90 green:0.20 blue:0.15 alpha:0.95];
    self.cameraAlertBanner.layer.cornerRadius = 10.0;
    self.cameraAlertBanner.layer.borderColor = [[UIColor whiteColor] CGColor];
    self.cameraAlertBanner.layer.borderWidth = 1.5;
    self.cameraAlertBanner.layer.shadowColor = [[UIColor blackColor] CGColor];
    self.cameraAlertBanner.layer.shadowOpacity = 0.5;
    self.cameraAlertBanner.layer.shadowRadius = 4.0;
    self.cameraAlertBanner.layer.shadowOffset = CGSizeMake(0, 2);
    self.cameraAlertBanner.hidden = YES;

    self.cameraAlertLabel = [[UILabel alloc] initWithFrame:self.cameraAlertBanner.bounds];
    self.cameraAlertLabel.backgroundColor = [UIColor clearColor];
    self.cameraAlertLabel.font = [UIFont boldSystemFontOfSize:12.5];
    self.cameraAlertLabel.textColor = [UIColor whiteColor];
    self.cameraAlertLabel.textAlignment = NSTextAlignmentCenter;
    self.cameraAlertLabel.adjustsFontSizeToFitWidth = YES;
    self.cameraAlertLabel.minimumScaleFactor = 0.7;
    [self.cameraAlertBanner addSubview:self.cameraAlertLabel];
    [self.view addSubview:self.cameraAlertBanner];
}

- (void)handleLanguageChanged:(NSNotification *)note {
    [self.topSearchPill setTitle:NLString(@"SEARCH_PLACEHOLDER", @"  🔍 Поиск места или адреса...") forState:UIControlStateNormal];
    if (self.currentLocation == nil) {
        self.gpsSourceLabel.text = NLString(@"GPS_SEARCHING", @"📡 Поиск сигнала GPS...");
        self.gpsSourceLabel.hidden = NO;
        self.gpsSourceLabel.alpha = 1.0;
    }
    [self.poiShelf updateLocalizedTitles];
    [self.maneuverHUD reset];
}

- (void)viewDidLayoutSubviews {
    [super viewDidLayoutSubviews];
}

- (void)hideMapKitAttributionInView:(UIView *)view {
    for (UIView *sub in view.subviews) {
        NSString *className = NSStringFromClass([sub class]);
        if ([className containsString:@"Attribution"] || [className containsString:@"Legal"]) {
            sub.hidden = YES;
            sub.alpha = 0.0;
        }
        [self hideMapKitAttributionInView:sub];
    }
}

#pragma mark - Toolbar Verticale Collapsible (◀ / ▶)

- (void)setupVerticalToolbar {
    CGFloat w = self.view.bounds.size.width;
    CGFloat btnSize = 50.0;
    CGFloat rightMargin = 14.0;
    CGFloat btnX = w - btnSize - rightMargin;
    CGFloat spacing = 58.0;

    // Il pulsante più in basso è 🎯 (sempre visibile)
    CGFloat baseY = self.view.bounds.size.height - 68;

    self.recenterButton = [self createCircularButtonWithTitle:@"🎯" frame:CGRectMake(btnX, baseY, btnSize, btnSize)];
    [self.recenterButton addTarget:self action:@selector(recenterMap) forControlEvents:UIControlEventTouchUpInside];
    [self.view addSubview:self.recenterButton];

    // Pulsante Impostazioni ⚙️ diretto (sempre visibile sopra 🎯)
    self.settingsButton = [self createCircularButtonWithTitle:@"⚙️" frame:CGRectMake(btnX, baseY - spacing, btnSize, btnSize)];
    [self.settingsButton addTarget:self action:@selector(openSettings) forControlEvents:UIControlEventTouchUpInside];
    [self.view addSubview:self.settingsButton];
}

- (UIButton *)createCircularButtonWithTitle:(NSString *)title frame:(CGRect)frame {
    UIButton *btn = [UIButton buttonWithType:UIButtonTypeCustom];
    btn.frame = frame;
    btn.autoresizingMask = UIViewAutoresizingFlexibleLeftMargin | UIViewAutoresizingFlexibleTopMargin;
    btn.backgroundColor = [UIColor colorWithWhite:0.96 alpha:0.96];
    btn.layer.cornerRadius = frame.size.width / 2.0;
    btn.layer.borderColor = [[UIColor colorWithWhite:0.75 alpha:0.90] CGColor];
    btn.layer.borderWidth = 1.0;
    btn.layer.shadowColor = [[UIColor blackColor] CGColor];
    btn.layer.shadowPath = [UIBezierPath bezierPathWithOvalInRect:CGRectMake(0, 0, frame.size.width, frame.size.height)].CGPath;
    btn.layer.shadowOpacity = 0.20;
    btn.layer.shadowRadius = 2.5;
    btn.layer.shadowOffset = CGSizeMake(0, 1.5);
    [btn setTitle:title forState:UIControlStateNormal];
    [btn setTitleColor:[UIColor colorWithWhite:0.15 alpha:1.0] forState:UIControlStateNormal];
    btn.titleLabel.font = [UIFont systemFontOfSize:22.0];
    return btn;
}

- (void)startDisplayLink {
    if (self.displayLink) return;
    self.displayLink = [CADisplayLink displayLinkWithTarget:self selector:@selector(handleDisplayLink:)];
    self.displayLink.frameInterval = 2; // 30 FPS: perfetto per A5 (silky smooth e leggero su CPU)
    [self.displayLink addToRunLoop:[NSRunLoop mainRunLoop] forMode:NSRunLoopCommonModes];
    self.lastFrameTime = CACurrentMediaTime();
}

- (void)stopDisplayLink {
    if (self.displayLink) {
        [self.displayLink invalidate];
        self.displayLink = nil;
    }
}

- (BOOL)gestureRecognizer:(UIGestureRecognizer *)gestureRecognizer shouldRecognizeSimultaneouslyWithGestureRecognizer:(UIGestureRecognizer *)otherGestureRecognizer {
    return YES;
}

- (void)handleMapPan:(UIPanGestureRecognizer *)pan {
    if (pan.state == UIGestureRecognizerStateBegan) {
        self.isTrackingVehicle = NO;
        self.recenterButton.hidden = NO;
    }
}

- (void)handleMapPinch:(UIPinchGestureRecognizer *)pinch {
    if (pinch.state == UIGestureRecognizerStateBegan) {
        self.isTrackingVehicle = NO;
        self.recenterButton.hidden = NO;
    }
}

- (void)applyCameraPerspectiveAnimated:(BOOL)animated {
    CLLocationCoordinate2D center;

    if (self.isNavigating && self.trackingEngine.hasActiveRoute && CLLocationCoordinate2DIsValid(self.trackingEngine.currentCoordinate) && self.trackingEngine.currentCoordinate.latitude != 0) {
        center = self.trackingEngine.currentCoordinate;
    } else if (self.currentLocation && CLLocationCoordinate2DIsValid(self.currentLocation.coordinate) && self.currentLocation.coordinate.latitude != 0) {
        center = self.currentLocation.coordinate;
    } else if (self.mapView.userLocation.location && CLLocationCoordinate2DIsValid(self.mapView.userLocation.location.coordinate) && self.mapView.userLocation.location.coordinate.latitude != 0) {
        center = self.mapView.userLocation.location.coordinate;
    } else if (self.currentRoute.steps.count > 0) {
        ManeuverStep *firstStep = (ManeuverStep *)self.currentRoute.steps[0];
        if (CLLocationCoordinate2DIsValid(firstStep.coordinate)) {
            center = firstStep.coordinate;
        } else {
            center = self.mapView.centerCoordinate;
        }
    } else {
        center = self.mapView.centerCoordinate;
    }

    if (CLLocationCoordinate2DIsValid(center) && center.latitude != 0) {
        double dist = self.isNavigating ? 400.0 : 500.0;
        MKCoordinateRegion reg = MKCoordinateRegionMakeWithDistance(center, dist, dist);
        [self.mapView setRegion:reg animated:animated];
    }
}

- (void)recenterMap {
    self.isTrackingVehicle = YES;
    self.recenterButton.hidden = YES;
    [self applyCameraPerspectiveAnimated:NO];
}

#pragma mark - Azioni Flottanti

- (void)openSearch {
    SearchViewController *searchVC = [[SearchViewController alloc] init];
    searchVC.delegate = self;
    searchVC.modalPresentationStyle = UIModalPresentationFormSheet;
    // Passa la posizione corrente per ricerche geolocalizzate con prossimità
    if (self.currentLocation && CLLocationCoordinate2DIsValid(self.currentLocation.coordinate) && self.currentLocation.coordinate.latitude != 0) {
        searchVC.userLocation = self.currentLocation.coordinate;
    } else if (self.mapView.userLocation.location && CLLocationCoordinate2DIsValid(self.mapView.userLocation.location.coordinate) && self.mapView.userLocation.location.coordinate.latitude != 0) {
        searchVC.userLocation = self.mapView.userLocation.location.coordinate;
    } else if (CLLocationCoordinate2DIsValid(self.mapView.centerCoordinate) && self.mapView.centerCoordinate.latitude != 0) {
        searchVC.userLocation = self.mapView.centerCoordinate;
    }
    [self presentViewController:searchVC animated:YES completion:nil];
}

- (void)openSettings {
    SettingsViewController *settingsVC = [[SettingsViewController alloc] init];
    settingsVC.delegate = self;
    settingsVC.tileOverlay = self.osmOverlay;
    settingsVC.currentMapRegion = self.mapView.region;
    // Wrapper UINavigationController per barra nativa con pulsante Chiudi di sistema
    UINavigationController *nav = [[UINavigationController alloc] initWithRootViewController:settingsVC];
    nav.navigationBar.barStyle = UIBarStyleBlack;
    nav.navigationBar.translucent = NO;
    nav.navigationBar.tintColor = [UIColor colorWithWhite:0.16 alpha:1.0];
    nav.navigationBar.titleTextAttributes = @{NSForegroundColorAttributeName: [UIColor whiteColor]};
    nav.modalPresentationStyle = UIModalPresentationFormSheet;
    [self presentViewController:nav animated:YES completion:nil];
}

- (void)toggleTraffic {
    self.trafficOverlay.isEnabled = !self.trafficOverlay.isEnabled;
    if (self.trafficOverlay.isEnabled) {
        if (![self.mapView.overlays containsObject:self.trafficOverlay]) {
            [self.mapView addOverlay:self.trafficOverlay];
        }
        [self.trafficButton setTitle:@"🚦" forState:UIControlStateNormal];
        [[VoiceGuidanceService sharedService] speak:NLString(@"TRAFFIC_ON", @"Traffico attivato.")];

        if (![self.trafficOverlay hasValidApiKey]) {
            UIAlertController *alert = [UIAlertController alertControllerWithTitle:NLString(@"TRAFFIC_KEY_TITLE", @"Traffico in Tempo Reale")
                                                                           message:NLString(@"TRAFFIC_KEY_MSG", @"Il livello del traffico è attivo ma richiede una chiave API TomTom per visualizzare il flusso in tempo reale.\n\nPuoi registrarti gratuitamente su developer.tomtom.com (2500 richieste/giorno) e inserirla nelle Impostazioni.")
                                                                    preferredStyle:UIAlertControllerStyleAlert];
            [alert addAction:[UIAlertAction actionWithTitle:NLString(@"SETTINGS_TITLE", @"⚙️ Impostazioni") style:UIAlertActionStyleDefault handler:^(UIAlertAction *action) {
                [self openSettings];
            }]];
            [alert addAction:[UIAlertAction actionWithTitle:@"OK" style:UIAlertActionStyleCancel handler:nil]];
            [self presentViewController:alert animated:YES completion:nil];
        }
    } else {
        [self.mapView removeOverlay:self.trafficOverlay];
        [self.trafficButton setTitle:@"⚪" forState:UIControlStateNormal];
        [[VoiceGuidanceService sharedService] speak:NLString(@"TRAFFIC_OFF", @"Traffico disattivato.")];
    }
}


- (void)handleDetourRecalculateTapped {
    self.consecutiveRerouteAttempts = 0;
    self.detourRecalculateButton.hidden = YES;
    [self showToastHUD:NLString(@"RECALCULATING_DETOUR", @"🔄 Ricalcolo percorso...")];
    [self triggerAutoReroute];
}

- (void)showToastHUD:(NSString *)message {
    if (!self.toastLabel) return;
    self.toastLabel.text = message;
    self.toastLabel.hidden = NO;
    [self.view bringSubviewToFront:self.toastLabel];
    [UIView animateWithDuration:0.2 animations:^{
        self.toastLabel.alpha = 1.0;
    } completion:^(BOOL finished) {
        dispatch_after(dispatch_time(DISPATCH_TIME_NOW, (int64_t)(1.6 * NSEC_PER_SEC)), dispatch_get_main_queue(), ^{
            [UIView animateWithDuration:0.3 animations:^{
                self.toastLabel.alpha = 0.0;
            } completion:^(BOOL fin) {
                self.toastLabel.hidden = YES;
            }];
        });
    }];
}

- (void)showWelcomeSplashScreen {
    // 1. Chime di benvenuto delicato (System Sound 1104 - Tink)
    AudioServicesPlaySystemSound(1104);

    // 2. Elegante Splash View centrale flottante
    CGFloat w = self.view.bounds.size.width;
    CGFloat h = self.view.bounds.size.height;
    CGFloat splashW = MIN(320.0, w - 48.0);
    CGFloat splashH = 124.0;

    UIView *splashView = [[UIView alloc] initWithFrame:CGRectMake((w - splashW) / 2.0, (h - splashH) / 2.0 - 24.0, splashW, splashH)];
    splashView.autoresizingMask = UIViewAutoresizingFlexibleLeftMargin | UIViewAutoresizingFlexibleRightMargin | UIViewAutoresizingFlexibleTopMargin | UIViewAutoresizingFlexibleBottomMargin;
    splashView.backgroundColor = [UIColor colorWithWhite:0.10 alpha:0.92];
    splashView.layer.cornerRadius = 20.0;
    splashView.layer.borderColor = [[UIColor colorWithRed:0.25 green:0.65 blue:1.0 alpha:0.8] CGColor];
    splashView.layer.borderWidth = 1.5;
    splashView.layer.shadowColor = [[UIColor blackColor] CGColor];
    splashView.layer.shadowOpacity = 0.6;
    splashView.layer.shadowRadius = 12.0;
    splashView.layer.shadowOffset = CGSizeMake(0, 4);
    splashView.alpha = 0.0;
    splashView.transform = CGAffineTransformMakeScale(0.92, 0.92);

    UILabel *iconLabel = [[UILabel alloc] initWithFrame:CGRectMake(0, 14, splashW, 30)];
    iconLabel.backgroundColor = [UIColor clearColor];
    iconLabel.text = @"📍";
    iconLabel.font = [UIFont systemFontOfSize:26.0];
    iconLabel.textAlignment = NSTextAlignmentCenter;
    [splashView addSubview:iconLabel];

    UILabel *titleLabel = [[UILabel alloc] initWithFrame:CGRectMake(16, 48, splashW - 32, 24)];
    titleLabel.backgroundColor = [UIColor clearColor];
    titleLabel.text = @"NavigatorOSM";
    titleLabel.textColor = [UIColor whiteColor];
    titleLabel.font = [UIFont boldSystemFontOfSize:19.0];
    titleLabel.textAlignment = NSTextAlignmentCenter;
    [splashView addSubview:titleLabel];

    UILabel *subtitleLabel = [[UILabel alloc] initWithFrame:CGRectMake(16, 74, splashW - 32, 36)];
    subtitleLabel.backgroundColor = [UIColor clearColor];
    subtitleLabel.text = NLString(@"WELCOME_SPLASH", @"Pronto per la navigazione");
    subtitleLabel.textColor = [UIColor colorWithRed:0.35 green:0.80 blue:1.0 alpha:1.0];
    subtitleLabel.font = [UIFont systemFontOfSize:13.0];
    subtitleLabel.textAlignment = NSTextAlignmentCenter;
    subtitleLabel.numberOfLines = 2;
    [splashView addSubview:subtitleLabel];

    [self.view addSubview:splashView];

    // Animazione di apparizione morbida (fade-in + pop)
    [UIView animateWithDuration:0.3 delay:0.1 options:UIViewAnimationOptionCurveEaseOut animations:^{
        splashView.alpha = 1.0;
        splashView.transform = CGAffineTransformIdentity;
    } completion:^(BOOL finished) {
        // Dissolvenza automatica dopo 1.3 secondi
        [UIView animateWithDuration:0.4 delay:1.3 options:UIViewAnimationOptionCurveEaseIn animations:^{
            splashView.alpha = 0.0;
            splashView.transform = CGAffineTransformMakeScale(1.04, 1.04);
        } completion:^(BOOL fin) {
            [splashView removeFromSuperview];
        }];
    }];
}

- (void)cancelCurrentRoute {
    self.currentRouteRequestId++;
    self.isNavigating = NO;
    self.routeSelector.hidden = YES;
    self.tripBar.hidden = YES;
    self.maneuverHUD.hidden = YES;
    self.cameraAlertBanner.hidden = YES;
    self.detourRecalculateButton.hidden = YES;
    self.consecutiveRerouteAttempts = 0;
    self.lastRerouteDate = nil;
    self.lastAlertedCameraId = 0;
    self.lastCameraAlertDate = nil;
    [self.speedometer setDynamicSpeedLimit:0];

    // Ripristina barra di ricerca e POI in alto
    self.topSearchPill.hidden = NO;
    self.poiShelf.hidden = NO;

    // Rimuovi TUTTE le polylines dalla mappa per garantire una pulizia perfetta
    for (id<MKOverlay> overlay in [self.mapView.overlays copy]) {
        if ([overlay isKindOfClass:[MKPolyline class]]) {
            [self.mapView removeOverlay:overlay];
        }
    }

    // Rimuovi pin destinazione e annotazioni temporanee
    if (self.destinationPin) {
        [self.mapView removeAnnotation:self.destinationPin];
        self.destinationPin = nil;
    }
    if (self.poiAnnotations.count > 0) {
        [self.mapView removeAnnotations:self.poiAnnotations];
        [self.poiAnnotations removeAllObjects];
    }

    // Nascondi pulsante carburante e resetta stato toggle
    self.fuelToggleButton.hidden = YES;
    self.fuelToggleButton.alpha = 0.0;
    self.isFuelVisibleDuringNavigation = NO;

    // Rimuovi distributori e autovelox dalla mappa per garantire la massima pulizia e reattività
    if (self.fuelAnnotations.count > 0) {
        [self.mapView removeAnnotations:self.fuelAnnotations];
        [self.fuelAnnotations removeAllObjects];
    }
    if (self.cameraAnnotations.count > 0) {
        [self.mapView removeAnnotations:self.cameraAnnotations];
        [self.cameraAnnotations removeAllObjects];
    }

    self.isNavigating = NO;
    [self stopDisplayLink];
    self.isCruisingWithVehiclePuck = NO;
    self.mapView.showsUserLocation = YES;

    self.availableRoutes = nil;
    self.currentRoute = nil;
    self.currentStepIndex = 0;
    self.offRouteConsecutiveCount = 0;
    [self.trackingEngine clearActiveRoute];

    [self.maneuverHUD reset];
    [[VoiceGuidanceService sharedService] resetManeuverTracking];

    [self applyCameraPerspectiveAnimated:YES];
}

- (void)repeatCurrentInstruction {
    if (self.currentRoute && self.currentStepIndex < self.currentRoute.steps.count) {
        ManeuverStep *step = self.currentRoute.steps[self.currentStepIndex];
        double dist = (self.trackingEngine && self.isNavigating) ? self.trackingEngine.remainingDistanceToStep : step.distance;
        [[VoiceGuidanceService sharedService] repeatCurrentManeuverModifier:step.modifier
                                                                       type:step.type
                                                                   distance:dist];
    }
}

#pragma mark - Search & Route Calculation (Itinerari Multipli)

- (void)handleMapLongPress:(UILongPressGestureRecognizer *)gesture {
    if (gesture.state != UIGestureRecognizerStateBegan) return;

    if (self.poiResultsCard) {
        [self.poiResultsCard dismiss];
    }

    CGPoint point = [gesture locationInView:self.mapView];
    CLLocationCoordinate2D coord = [self.mapView convertPoint:point toCoordinateFromView:self.mapView];

    // Rimuovi eventuali pin temporanei precedenti
    [self.mapView removeAnnotations:self.poiAnnotations];
    [self.poiAnnotations removeAllObjects];

    MKPointAnnotation *pin = [[MKPointAnnotation alloc] init];
    pin.coordinate = coord;
    pin.title = NLString(@"SELECTED_DESTINATION", @"Выбранная точка");
    [self.poiAnnotations addObject:pin];
    [self.mapView addAnnotation:pin];

    [self searchViewControllerDidSelectLocation:coord title:NLString(@"POINT_ON_MAP", @"Точка на карте")];
}

- (void)searchViewControllerDidSelectLocation:(CLLocationCoordinate2D)coordinate title:(NSString *)title {
    if (self.poiResultsCard) {
        [self.poiResultsCard dismiss];
    }
    NSUInteger thisRequestId = ++self.currentRouteRequestId;
    [SearchViewController saveRecentDestinationWithTitle:title coordinate:coordinate];

    CLLocationCoordinate2D startCoord;
    if (self.currentLocation && CLLocationCoordinate2DIsValid(self.currentLocation.coordinate) && self.currentLocation.coordinate.latitude != 0) {
        startCoord = self.currentLocation.coordinate;
    } else if (self.mapView.userLocation.location && CLLocationCoordinate2DIsValid(self.mapView.userLocation.location.coordinate) && self.mapView.userLocation.location.coordinate.latitude != 0) {
        startCoord = self.mapView.userLocation.location.coordinate;
    } else if (CLLocationCoordinate2DIsValid(self.mapView.centerCoordinate) && self.mapView.centerCoordinate.latitude != 0) {
        startCoord = self.mapView.centerCoordinate;
    } else {
        startCoord = CLLocationCoordinate2DMake(45.4642, 9.1900); // Default Milano
    }

    [self.topSearchPill setTitle:NLString(@"SEARCH_PLACEHOLDER", @"  🔍 Поиск места или адреса...") forState:UIControlStateNormal];
    [[VoiceGuidanceService sharedService] speak:NLString(@"SEARCHING_ROUTES", @"Ricerca itinerari alternativi...")];

    // Imposta pin di destinazione e centra mappa subito
    if (self.destinationPin) {
        [self.mapView removeAnnotation:self.destinationPin];
    }
    self.destinationPin = [[MKPointAnnotation alloc] init];
    self.destinationPin.coordinate = coordinate;
    self.destinationPin.title = title ?: NLString(@"SELECTED_DESTINATION", @"Точка назначения");
    [self.mapView addAnnotation:self.destinationPin];

    if (CLLocationCoordinate2DIsValid(coordinate)) {
        MKCoordinateRegion reg = MKCoordinateRegionMakeWithDistance(coordinate, 1200, 1200);
        [self.mapView setRegion:reg animated:YES];
    }

    __weak NavigationViewController *weakSelf = self;
    BOOL avoidTolls = self.routeSelector ? self.routeSelector.avoidTolls : NO;
    BOOL avoidHighways = self.routeSelector ? self.routeSelector.avoidHighways : NO;
    [[RoutingService sharedService] calculateRoutesFrom:startCoord
                                                     to:coordinate
                                       destinationTitle:title
                                             avoidTolls:avoidTolls
                                          avoidHighways:avoidHighways
                                         corridorOffset:0.22
                                             completion:^(NSArray *routes, NSError *error) {
        if (!weakSelf || weakSelf.currentRouteRequestId != thisRequestId) {
            NSLog(@"[NavigationViewController] Itinerario scartato: richiesta annullata o superata.");
            return;
        }

        [weakSelf.topSearchPill setTitle:NLString(@"SEARCH_PLACEHOLDER", @"  🔍 Поиск места или адреса...") forState:UIControlStateNormal];

        if (error || routes.count == 0) {
            if (CLLocationCoordinate2DIsValid(coordinate)) {
                MKCoordinateRegion reg = MKCoordinateRegionMakeWithDistance(coordinate, 1200, 1200);
                [weakSelf.mapView setRegion:reg animated:YES];
            }
            NSString *errPrompt = (error.code == -2)
                ? NLString(@"NO_ROUTE_FOUND", @"Nessun percorso stradale trovato per questa destinazione.")
                : NLString(@"CALC_ERROR", @"Errore nel calcolo del percorso.");
            [[VoiceGuidanceService sharedService] speak:errPrompt];
            return;
        }

        // Pulisci overlay precedenti
        for (id<MKOverlay> overlay in [weakSelf.mapView.overlays copy]) {
            if ([overlay isKindOfClass:[MKPolyline class]]) {
                [weakSelf.mapView removeOverlay:overlay];
            }
        }

        weakSelf.availableRoutes = routes;
        weakSelf.currentRoute = routes[0];
        weakSelf.currentStepIndex = 0;

        for (RouteInfo *r in routes) {
            if (r.polyline) {
                [weakSelf.mapView addOverlay:r.polyline];
            }
        }

        RouteInfo *r0 = routes[0];
        if (r0.polyline && r0.polyline.pointCount >= 2) {
            MKMapRect mapRect = r0.polyline.boundingMapRect;
            if (!MKMapRectIsNull(mapRect) && !MKMapRectIsEmpty(mapRect)) {
                double minMeters = 800.0;
                double mapPointsPerMeter = MKMapPointsPerMeterAtLatitude(weakSelf.mapView.centerCoordinate.latitude);
                double minSize = mapPointsPerMeter * minMeters;
                if (mapRect.size.width < minSize) {
                    double diff = (minSize - mapRect.size.width) / 2.0;
                    mapRect.origin.x -= diff;
                    mapRect.size.width = minSize;
                }
                if (mapRect.size.height < minSize) {
                    double diff = (minSize - mapRect.size.height) / 2.0;
                    mapRect.origin.y -= diff;
                    mapRect.size.height = minSize;
                }
                [weakSelf.mapView setVisibleMapRect:mapRect
                                        edgePadding:UIEdgeInsetsMake(120, 60, 220, 60)
                                           animated:YES];
            }
        } else if (CLLocationCoordinate2DIsValid(coordinate)) {
            MKCoordinateRegion reg = MKCoordinateRegionMakeWithDistance(coordinate, 1200, 1200);
            [weakSelf.mapView setRegion:reg animated:YES];
        }

        // Mostra il selettore itinerari
        [weakSelf.poiResultsCard dismiss];
        [weakSelf.poiResultsCard dismiss];
        if (weakSelf.poiAnnotations.count > 0) {
            [weakSelf.mapView removeAnnotations:weakSelf.poiAnnotations];
            [weakSelf.poiAnnotations removeAllObjects];
        }
        if (weakSelf.fuelAnnotations.count > 0) {
            [weakSelf.mapView removeAnnotations:weakSelf.fuelAnnotations];
            [weakSelf.fuelAnnotations removeAllObjects];
        }
        weakSelf.topSearchPill.hidden = YES;
        weakSelf.poiShelf.hidden = YES;
        [weakSelf.routeSelector setRoutes:routes];
        weakSelf.routeSelector.hidden = NO;

        // Nascondi barre superiori per non ingombrare
        weakSelf.topSearchPill.hidden = YES;
        weakSelf.poiShelf.hidden = YES;

        NSString *fmt = NLString(@"FOUND_ROUTES_VOICE", @"Trovati %lu itinerari. Tocca quello desiderato per iniziare.");
        NSString *msg = [NSString stringWithFormat:fmt, (unsigned long)routes.count];
        [[VoiceGuidanceService sharedService] speak:msg];
    }];
}

- (void)showAnnotationsCompat:(NSArray *)annotations animated:(BOOL)animated {
    if (annotations.count == 0) return;
    MKMapRect zoomRect = MKMapRectNull;
    for (id<MKAnnotation> annotation in annotations) {
        if (!CLLocationCoordinate2DIsValid(annotation.coordinate)) continue;
        MKMapPoint point = MKMapPointForCoordinate(annotation.coordinate);
        MKMapRect pointRect = MKMapRectMake(point.x, point.y, 0.1, 0.1);
        zoomRect = MKMapRectUnion(zoomRect, pointRect);
    }

    // Includi sempre la posizione dell'utente (se valida) per inquadrare sia partenza che arrivo
    CLLocation *uLoc = self.currentLocation ?: self.mapView.userLocation.location;
    if (uLoc && CLLocationCoordinate2DIsValid(uLoc.coordinate) && fabs(uLoc.coordinate.latitude) > 0.1) {
        MKMapPoint userPt = MKMapPointForCoordinate(uLoc.coordinate);
        zoomRect = MKMapRectUnion(zoomRect, MKMapRectMake(userPt.x, userPt.y, 0.1, 0.1));
    }

    // Assicura una dimensione minima del rettangolo (almeno ~800m) per evitare zoom eccessivo con 1 solo POI
    double minMeters = 800.0;
    double mapPointsPerMeter = MKMapPointsPerMeterAtLatitude(self.mapView.centerCoordinate.latitude);
    double minSize = mapPointsPerMeter * minMeters;
    if (zoomRect.size.width < minSize) {
        double diff = (minSize - zoomRect.size.width) / 2.0;
        zoomRect.origin.x -= diff;
        zoomRect.size.width = minSize;
    }
    if (zoomRect.size.height < minSize) {
        double diff = (minSize - zoomRect.size.height) / 2.0;
        zoomRect.origin.y -= diff;
        zoomRect.size.height = minSize;
    }

    // Edge padding generoso: 90pt sopra (per la barra di ricerca), 190pt sotto (per la scheda POI)
    [self.mapView setVisibleMapRect:zoomRect edgePadding:UIEdgeInsetsMake(90, 60, 190, 60) animated:animated];
}

#pragma mark - SearchViewControllerDelegate (Show All POIs on Map)

- (void)searchViewControllerDidRequestShowAllPOIs:(NSArray *)annotations categoryName:(NSString *)categoryName {
    // Rimuovi pin precedenti
    [self.mapView removeAnnotations:self.poiAnnotations];
    [self.poiAnnotations removeAllObjects];

    // Aggiungi tutti i pin
    [self.poiAnnotations addObjectsFromArray:annotations];
    [self.mapView addAnnotations:annotations];

    // Zoom automatico per inquadrare tutti i POI
    if (annotations.count > 0) {
        [self showAnnotationsCompat:annotations animated:YES];
    }

    // Mostra la scheda risultati POI
    [self.poiResultsCard showWithAnnotations:annotations
                                categoryName:categoryName
                             currentLocation:self.currentLocation];
}

#pragma mark - RouteSelectorViewDelegate

- (void)routeSelectorView:(RouteSelectorView *)view didSelectRouteIndex:(NSUInteger)index {
    if (index >= self.availableRoutes.count) return;

    self.currentRoute = self.availableRoutes[index];
    self.currentStepIndex = 0;

    for (RouteInfo *r in self.availableRoutes) {
        if (r.polyline) {
            [self.mapView removeOverlay:r.polyline];
            [self.mapView addOverlay:r.polyline];
        }
    }
}

- (void)routeSelectorView:(RouteSelectorView *)view didConfirmStartRoute:(RouteInfo *)selectedRoute {
    self.currentRoute = selectedRoute;
    self.isNavigating = YES;
    self.routeSelector.hidden = YES;
    self.offRouteConsecutiveCount = 0;

    // Rimuovi tutti i pin temporanei POI di ricerca e distributori dalla mappa
    if (self.poiAnnotations.count > 0) {
        [self.mapView removeAnnotations:self.poiAnnotations];
        [self.poiAnnotations removeAllObjects];
    }
    if (self.fuelAnnotations.count > 0) {
        [self.mapView removeAnnotations:self.fuelAnnotations];
        [self.fuelAnnotations removeAllObjects];
    }
    self.isFuelVisibleDuringNavigation = NO;

    for (RouteInfo *r in self.availableRoutes) {
        if (r != selectedRoute && r.polyline) {
            [self.mapView removeOverlay:r.polyline];
        }
    }
    if (selectedRoute.polyline) {
        [self.mapView removeOverlay:selectedRoute.polyline];
        [self.mapView addOverlay:selectedRoute.polyline];
    }

    // Mostra HUD di guida in stile Waze e Google Maps
    self.maneuverHUD.hidden = NO;
    self.tripBar.hidden = NO;

    if (self.currentRoute.steps.count > 0) {
        ManeuverStep *step1 = self.currentRoute.steps[0];
        ManeuverStep *step2 = (self.currentRoute.steps.count > 1) ? self.currentRoute.steps[1] : nil;
        [self.maneuverHUD updateWithManeuver:step1 distanceToStep:step1.distance nextStep:step2];
    }
    [self.tripBar updateRemainingDistance:self.currentRoute.totalDistance
                                 duration:self.currentRoute.totalDuration
                            trafficStatus:self.currentRoute.trafficDescription];

    [self.trackingEngine setActiveRoute:selectedRoute initialLocation:self.currentLocation];
    self.isCruisingWithVehiclePuck = NO;

    [[VoiceGuidanceService sharedService] playPromptNamed:@"depart"];
    self.mapView.showsUserLocation = YES;

    [self refreshSpeedCamerasForRoute:selectedRoute];
    self.isFuelVisibleDuringNavigation = NO; // Spento di default: attivabile al volo con il toggle ⛽
    [self updateFuelToggleButtonAppearance];
    self.fuelToggleButton.hidden = NO;
    [UIView animateWithDuration:0.25 animations:^{
        self.fuelToggleButton.alpha = 1.0;
    }];
    [self.osmOverlay prefetchTilesAlongRoute:selectedRoute currentDistance:0 lookaheadMeters:4000.0];
    self.isTrackingVehicle = YES;

    [self applyCameraPerspectiveAnimated:NO];
    [self startDisplayLink];

    NSString *format = NLString(@"START_DRIVING_TO", @"Inizia a guidare verso %@.");
    NSString *prompt = [NSString stringWithFormat:format, self.currentRoute.destinationTitle];
    [[VoiceGuidanceService sharedService] speak:prompt];
}

- (void)routeSelectorViewDidCancel:(RouteSelectorView *)view {
    [self cancelCurrentRoute];
}

- (void)routeSelectorViewDidRequestRecalculate:(RouteSelectorView *)view {
    [self recalculateAlternativeRoutes];
}

- (void)routeSelectorView:(RouteSelectorView *)view didToggleAvoidTolls:(BOOL)avoidTolls avoidHighways:(BOOL)avoidHighways {
    [self recalculateRoutesWithAvoidTolls:avoidTolls avoidHighways:avoidHighways corridorOffset:0.22];
}

#pragma mark - Route Summary & Alternative Routes

- (void)showRouteSummary {
    if (!self.currentRoute) {
        [self repeatCurrentInstruction];
        return;
    }

    RouteSummaryViewController *summaryVC = [[RouteSummaryViewController alloc] init];
    summaryVC.route = self.currentRoute;
    summaryVC.currentStepIndex = self.currentStepIndex;
    summaryVC.delegate = self;
    [self presentViewController:summaryVC animated:YES completion:nil];
}

#pragma mark - RouteSummaryViewControllerDelegate

- (void)routeSummaryViewControllerDidRequestRecalculate:(RouteSummaryViewController *)controller {
    [controller dismissViewControllerAnimated:YES completion:^{
        [self recalculateAlternativeRoutes];
    }];
}

- (void)routeSummaryViewControllerDidRequestRepeatVoice:(RouteSummaryViewController *)controller {
    [self repeatCurrentInstruction];
}

- (void)routeSummaryViewController:(RouteSummaryViewController *)controller didSelectStepIndex:(NSUInteger)stepIndex {
    // Non muovere la mappa sotto il controller modale a schermo intero
}

- (void)recalculateAlternativeRoutes {
    static int sCorridorCycle = 0;
    sCorridorCycle++;
    double offsets[] = { 0.35, -0.30, 0.22, 0.45 };
    double currentOffset = offsets[sCorridorCycle % 4];

    BOOL avoidTolls = self.routeSelector ? self.routeSelector.avoidTolls : NO;
    BOOL avoidHighways = self.routeSelector ? self.routeSelector.avoidHighways : NO;

    [self recalculateRoutesWithAvoidTolls:avoidTolls avoidHighways:avoidHighways corridorOffset:currentOffset];
}

- (void)recalculateRoutesWithAvoidTolls:(BOOL)avoidTolls
                          avoidHighways:(BOOL)avoidHighways
                         corridorOffset:(double)currentOffset {
    CLLocationCoordinate2D startCoord;
    if (self.currentLocation && CLLocationCoordinate2DIsValid(self.currentLocation.coordinate) && self.currentLocation.coordinate.latitude != 0) {
        startCoord = self.currentLocation.coordinate;
    } else if (self.mapView.userLocation.location && CLLocationCoordinate2DIsValid(self.mapView.userLocation.location.coordinate) && self.mapView.userLocation.location.coordinate.latitude != 0) {
        startCoord = self.mapView.userLocation.location.coordinate;
    } else {
        startCoord = self.mapView.centerCoordinate;
    }

    CLLocationCoordinate2D destCoord = kCLLocationCoordinate2DInvalid;
    NSString *destTitle = nil;
    if (self.currentRoute) {
        destCoord = self.currentRoute.destinationCoordinate;
        destTitle = self.currentRoute.destinationTitle;
    } else if (self.destinationPin) {
        destCoord = self.destinationPin.coordinate;
        destTitle = self.destinationPin.title;
    }

    if (!CLLocationCoordinate2DIsValid(destCoord) || destCoord.latitude == 0) {
        return;
    }

    // Se eravamo in navigazione attiva, azzeriamo HUD e mostriamo il selettore
    self.isNavigating = NO;
    self.isCruisingWithVehiclePuck = NO;
    self.mapView.showsUserLocation = YES;
    [self stopDisplayLink];
    self.maneuverHUD.hidden = YES;
    self.tripBar.hidden = YES;

    NSString *msg = NLString(@"SEARCHING_ROUTES", @"Ricerca itinerari alternativi...");
    if (avoidTolls && avoidHighways) {
        msg = NLString(@"SEARCHING_NO_TOLLS_NO_HWY", @"Ricerca itinerari senza pedaggi e senza autostrade...");
    } else if (avoidTolls) {
        msg = NLString(@"SEARCHING_NO_TOLLS", @"Ricerca itinerari senza pedaggio...");
    } else if (avoidHighways) {
        msg = NLString(@"SEARCHING_NO_HWY", @"Ricerca itinerari senza autostrade...");
    }
    [[VoiceGuidanceService sharedService] speak:msg];

    self.currentRouteRequestId++;
    NSUInteger thisRequestId = self.currentRouteRequestId;

    __weak NavigationViewController *weakSelf = self;
    [[RoutingService sharedService] calculateRoutesFrom:startCoord
                                                     to:destCoord
                                       destinationTitle:destTitle
                                             avoidTolls:avoidTolls
                                          avoidHighways:avoidHighways
                                         corridorOffset:currentOffset
                                             completion:^(NSArray *routes, NSError *error) {
        if (!weakSelf || weakSelf.currentRouteRequestId != thisRequestId) return;

        if (error || routes.count == 0) {
            NSString *errPrompt = (error.code == -2)
                ? NLString(@"NO_ROUTE_FOUND", @"Nessun percorso stradale trovato per questa destinazione.")
                : NLString(@"CALC_ERROR", @"Errore nel calcolo del percorso.");
            [[VoiceGuidanceService sharedService] speak:errPrompt];
            return;
        }

        // Pulisci overlay precedenti
        for (id<MKOverlay> overlay in [weakSelf.mapView.overlays copy]) {
            if ([overlay isKindOfClass:[MKPolyline class]]) {
                [weakSelf.mapView removeOverlay:overlay];
            }
        }

        weakSelf.availableRoutes = routes;
        weakSelf.currentRoute = routes[0];
        weakSelf.currentStepIndex = 0;

        for (RouteInfo *r in routes) {
            if (r.polyline) {
                [weakSelf.mapView addOverlay:r.polyline];
            }
        }

        RouteInfo *r0 = routes[0];
        if (r0.polyline && r0.polyline.pointCount >= 2) {
            MKMapRect mapRect = r0.polyline.boundingMapRect;
            if (!MKMapRectIsNull(mapRect) && !MKMapRectIsEmpty(mapRect)) {
                double minMeters = 800.0;
                double mapPointsPerMeter = MKMapPointsPerMeterAtLatitude(weakSelf.mapView.centerCoordinate.latitude);
                double minSize = mapPointsPerMeter * minMeters;
                if (mapRect.size.width < minSize) {
                    double diff = (minSize - mapRect.size.width) / 2.0;
                    mapRect.origin.x -= diff;
                    mapRect.size.width = minSize;
                }
                if (mapRect.size.height < minSize) {
                    double diff = (minSize - mapRect.size.height) / 2.0;
                    mapRect.origin.y -= diff;
                    mapRect.size.height = minSize;
                }
                [weakSelf.mapView setVisibleMapRect:mapRect
                                        edgePadding:UIEdgeInsetsMake(120, 60, 240, 60)
                                           animated:YES];
            }
        }

        [weakSelf.poiResultsCard dismiss];
        if (weakSelf.poiAnnotations.count > 0) {
            [weakSelf.mapView removeAnnotations:weakSelf.poiAnnotations];
            [weakSelf.poiAnnotations removeAllObjects];
        }
        if (weakSelf.fuelAnnotations.count > 0) {
            [weakSelf.mapView removeAnnotations:weakSelf.fuelAnnotations];
            [weakSelf.fuelAnnotations removeAllObjects];
        }
        weakSelf.topSearchPill.hidden = YES;
        weakSelf.poiShelf.hidden = YES;
        [weakSelf.routeSelector setRoutes:routes];
        weakSelf.routeSelector.hidden = NO;
        [weakSelf.osmOverlay prefetchTilesAlongRoute:routes[0] currentDistance:0 lookaheadMeters:4000.0];

        NSString *foundVoiceFmt = NLString(@"FOUND_ROUTES_VOICE", @"Trovati %lu itinerari. Tocca quello desiderato per iniziare.");
        NSString *voiceMsg = [NSString stringWithFormat:foundVoiceFmt, (unsigned long)routes.count];
        [[VoiceGuidanceService sharedService] speak:voiceMsg];
    }];
}

#pragma mark - QuickPOIShelfViewDelegate

- (void)quickPOIShelfView:(QuickPOIShelfView *)shelf didRequestSearchCategory:(NSString *)query categoryName:(NSString *)categoryName {
    MKCoordinateRegion currentRegion = self.mapView.region;
    [shelf searchCategory:query inRegion:currentRegion categoryName:categoryName];
}

- (void)quickPOIShelfView:(QuickPOIShelfView *)shelf didFindPOIs:(NSArray *)annotations categoryName:(NSString *)category {
    self.routeSelector.hidden = YES;
    if (self.poiAnnotations.count > 0) {
        [self.mapView removeAnnotations:self.poiAnnotations];
        [self.poiAnnotations removeAllObjects];
    }
    if (self.fuelAnnotations.count > 0) {
        [self.mapView removeAnnotations:self.fuelAnnotations];
        [self.fuelAnnotations removeAllObjects];
    }

    [self.poiAnnotations addObjectsFromArray:annotations];
    [self.mapView addAnnotations:annotations];

    CLLocation *userLoc = self.currentLocation ?: self.mapView.userLocation.location;
    CLLocation *refLoc = nil;
    if (userLoc && CLLocationCoordinate2DIsValid(userLoc.coordinate) && fabs(userLoc.coordinate.latitude) > 0.1) {
        refLoc = userLoc;
    } else if (CLLocationCoordinate2DIsValid(self.mapView.centerCoordinate)) {
        refLoc = [[CLLocation alloc] initWithLatitude:self.mapView.centerCoordinate.latitude
                                            longitude:self.mapView.centerCoordinate.longitude];
    }

    // Mostra la scheda risultati POI con distanze e tasto Naviga
    [self.poiResultsCard showWithAnnotations:annotations
                                categoryName:category
                             currentLocation:refLoc];

    NSString *fmt = NLString(@"POI_FOUND_VOICE", @"Trovati %lu %@ nelle vicinanze.");
    NSString *msg = [NSString stringWithFormat:fmt, (unsigned long)annotations.count, category];
    [[VoiceGuidanceService sharedService] speak:msg];
}

- (void)quickPOIShelfViewDidRequestClose:(QuickPOIShelfView *)shelf {
    // Opzionale
}

#pragma mark - POIResultsCardViewDelegate

- (void)poiResultsCardView:(POIResultsCardView *)card didSelectNavigateToPOI:(MKPointAnnotation *)annotation {
    // Avvia il calcolo del percorso verso il POI selezionato
    [self searchViewControllerDidSelectLocation:annotation.coordinate title:annotation.title];
}

#pragma mark - MKMapViewDelegate (Annotation Views)

- (MKAnnotationView *)mapView:(MKMapView *)mapView viewForAnnotation:(id<MKAnnotation>)annotation {
    if ([annotation isKindOfClass:[MKUserLocation class]]) {
        return nil;
    }

    if ([annotation isKindOfClass:[VehicleAnnotation class]]) {
        static NSString *vehId = @"VehicleAnnotationView";
        VehicleAnnotationView *vehView = (VehicleAnnotationView *)[mapView dequeueReusableAnnotationViewWithIdentifier:vehId];
        if (!vehView) {
            vehView = [[VehicleAnnotationView alloc] initWithAnnotation:annotation reuseIdentifier:vehId];
        } else {
            vehView.annotation = annotation;
        }
        [vehView updateHeading:self.vehicleAnnotation.heading cameraHeading:0.0];
        return vehView;
    }

    if ([annotation isKindOfClass:[SpeedCameraAnnotation class]]) {
        static NSString *camId = @"SpeedCameraAnnotationView";
        SpeedCameraAnnotationView *camView = (SpeedCameraAnnotationView *)[mapView dequeueReusableAnnotationViewWithIdentifier:camId];
        if (!camView) {
            camView = [[SpeedCameraAnnotationView alloc] initWithAnnotation:annotation reuseIdentifier:camId];
        } else {
            camView.annotation = annotation;
        }
        [camView updateWithCamera:((SpeedCameraAnnotation *)annotation).camera];
        return camView;
    }

    if ([annotation isKindOfClass:[FuelStationAnnotation class]]) {
        static NSString *fuelId = @"FuelStationAnnotationView";
        FuelStationAnnotationView *fuelView = (FuelStationAnnotationView *)[mapView dequeueReusableAnnotationViewWithIdentifier:fuelId];
        if (!fuelView) {
            fuelView = [[FuelStationAnnotationView alloc] initWithAnnotation:annotation reuseIdentifier:fuelId];
        } else {
            fuelView.annotation = annotation;
        }
        FuelStationAnnotation *fAnn = (FuelStationAnnotation *)annotation;
        [fuelView updateWithStation:fAnn.station fuelType:fAnn.fuelType];
        return fuelView;
    }

    static NSString *poiId = @"POIAnnotation";
    MKPinAnnotationView *pin = (MKPinAnnotationView *)[mapView dequeueReusableAnnotationViewWithIdentifier:poiId];
    if (!pin) {
        pin = [[MKPinAnnotationView alloc] initWithAnnotation:annotation reuseIdentifier:poiId];
        pin.canShowCallout = YES;
        pin.animatesDrop = YES;

        UIButton *rightBtn = [UIButton buttonWithType:UIButtonTypeDetailDisclosure];
        pin.rightCalloutAccessoryView = rightBtn;
    } else {
        pin.annotation = annotation;
    }

    // Colore pin in base al tipo (verde per POI, rosso per destinazione)
    if ([pin respondsToSelector:@selector(setPinTintColor:)]) {
        [pin performSelector:@selector(setPinTintColor:) withObject:[UIColor colorWithRed:0.15 green:0.65 blue:0.35 alpha:1.0]];
    } else {
        pin.pinColor = MKPinAnnotationColorGreen;
    }

    return pin;
}

- (void)mapView:(MKMapView *)mapView annotationView:(MKAnnotationView *)view calloutAccessoryControlTapped:(UIControl *)control {
    id<MKAnnotation> ann = view.annotation;
    if (ann) {
        [self searchViewControllerDidSelectLocation:ann.coordinate title:ann.title];
    }
}

#pragma mark - Gestione Posizione & Ricalcolo Fuori Rotta

- (void)locationManager:(CLLocationManager *)manager didChangeAuthorizationStatus:(CLAuthorizationStatus)status {
    if (status == kCLAuthorizationStatusAuthorized || (int)status == 3 || (int)status == 4) {
        [manager startUpdatingLocation];
        [manager startUpdatingHeading];
    }
}

- (void)locationManager:(CLLocationManager *)manager didUpdateLocations:(NSArray *)locations {
    CLLocation *loc = [locations lastObject];
    if (!loc) return;

    // Se il ricevitore di rete Android è attivo e sta ricevendo fix recenti (< 5.0 secondi),
    // ignoriamo completamente CoreLocation per evitare che la triangolazione Wi-Fi / celle (200-500m)
    // generi salti spuri, il cerchio di approssimazione gigante o continui falsi ricalcoli!
    NetworkGPSReceiver *netGPS = [NetworkGPSReceiver sharedReceiver];
    if (netGPS.isRunning && netGPS.lastPacketTimestamp && [[NSDate date] timeIntervalSinceDate:netGPS.lastPacketTimestamp] < 5.0) {
        return;
    }

    // Se l'accuratezza di CoreLocation è peggiore del limite, scartiamo il fix.
    // Se non abbiamo ancora nessuna posizione (primo fix) accettiamo fino a 250m (Wi-Fi), altrimenti max 100m.
    CLLocationAccuracy maxAcc = (self.currentLocation == nil) ? 250.0 : 100.0;
    if (loc.horizontalAccuracy > maxAcc) {
        return;
    }

    [self processLocationUpdate:loc heading:self.currentHeading];
}

- (void)locationManager:(CLLocationManager *)manager didUpdateHeading:(CLHeading *)newHeading {
    self.currentHeading = newHeading.trueHeading > 0 ? newHeading.trueHeading : newHeading.magneticHeading;
}

- (void)locationManager:(CLLocationManager *)manager didFailWithError:(NSError *)error {
    self.gpsSourceLabel.text = NLString(@"GPS_LOST", @"⚠️ Сигнал GPS потерян");
    self.gpsSourceLabel.backgroundColor = [UIColor colorWithRed:0.85 green:0.22 blue:0.22 alpha:0.9];
    self.gpsSourceLabel.hidden = NO;
    self.gpsSourceLabel.alpha = 1.0;
}

- (void)networkGPSDidUpdateLocation:(CLLocation *)location heading:(CLLocationDirection)heading {
    NetworkGPSReceiver *netGPS = [NetworkGPSReceiver sharedReceiver];
    NSString *source = [NSString stringWithFormat:@"📡 Android (%@)",
                        netGPS.lastStreamType ?: @"NET"];
    self.gpsSourceLabel.text = source;
    if (heading >= 0) {
        self.currentHeading = heading;
    }
    [self processLocationUpdate:location heading:heading];
}

- (void)processLocationUpdate:(CLLocation *)location heading:(CLLocationDirection)heading {
    if (self.isTrackingVehicle && self.currentLocation && [location distanceFromLocation:self.currentLocation] > 50000.0) {
        MKCoordinateRegion reg = MKCoordinateRegionMakeWithDistance(location.coordinate, 1000, 1000);
        [self.mapView setRegion:reg animated:YES];
    }
    self.currentLocation = location;
    if (heading >= 0) {
        self.currentHeading = heading;
    }

    // Dissolvi la pillola di ricerca GPS una volta acquisito il segnale
    if (self.gpsSourceLabel && !self.gpsSourceLabel.hidden && self.gpsSourceLabel.alpha > 0.05) {
        [UIView animateWithDuration:0.6 delay:1.0 options:UIViewAnimationOptionCurveEaseOut animations:^{
            self.gpsSourceLabel.alpha = 0.0;
        } completion:^(BOOL finished) {
            if (finished) self.gpsSourceLabel.hidden = YES;
        }];
    }

    // 1. Animazione dolce in apertura verso la posizione del dispositivo (eseguita UNA SOLA VOLTA)
    if (!self.hasPerformedInitialZoom && CLLocationCoordinate2DIsValid(location.coordinate) && location.coordinate.latitude != 0) {
        self.hasPerformedInitialZoom = YES;
        MKCoordinateRegion reg = MKCoordinateRegionMakeWithDistance(location.coordinate, 1000, 1000);
        [self.mapView setRegion:reg animated:YES];
    }

    if (!self.hasFetchedInitialCameras && CLLocationCoordinate2DIsValid(location.coordinate) && fabs(location.coordinate.latitude) > 0.1) {
        self.hasFetchedInitialCameras = YES;
    }

    if (!self.hasFetchedInitialFuelStations && CLLocationCoordinate2DIsValid(location.coordinate) && fabs(location.coordinate.latitude) > 0.1) {
        self.hasFetchedInitialFuelStations = YES;
    }

    // Prefetching predittivo dei tasselli mappa (in navigazione lungo la rotta o a prua del veicolo)
    NSTimeInterval nowPrefetch = CACurrentMediaTime();
    if (nowPrefetch - self.lastTilePrefetchTime > 4.0) {
        self.lastTilePrefetchTime = nowPrefetch;
        if (self.isNavigating && self.currentRoute) {
            [self.osmOverlay prefetchTilesAlongRoute:self.currentRoute
                                     currentDistance:self.trackingEngine.currentRouteDistance
                                     lookaheadMeters:3500.0];
        } else if (location.speed > 3.5) { // Movimento > ~13 km/h in guida libera
            [self.osmOverlay prefetchTilesAheadOfCoordinate:location.coordinate
                                                    heading:self.currentHeading
                                                      speed:location.speed];
        }
    }

    if (self.isNavigating && self.trackingEngine.hasActiveRoute) {
        // Invia il fix GPS al motore di tracciamento mezzeria:
        // Verifica la tolleranza (range ragionevole) e riconcilia il progresso longitudinale
        // senza spostare l'auto lateralmente per inseguire un GPS impreciso!
        [self.trackingEngine processGPSLocation:location heading:heading];
    } else {
        // Guida libera: mantieni sempre visibile il puck del veicolo sulle mappe OSM raster
        if (self.vehicleAnnotation) {
            if (![self.mapView.annotations containsObject:self.vehicleAnnotation]) {
                [self.mapView addAnnotation:self.vehicleAnnotation];
            }
            CLLocationDirection puckHeading = (heading >= 0) ? heading : (self.vehicleAnnotation.heading >= 0 ? self.vehicleAnnotation.heading : 0.0);
            [self.vehicleAnnotation updateCoordinate:location.coordinate heading:puckHeading];
            VehicleAnnotationView *vehView = (VehicleAnnotationView *)[self.mapView viewForAnnotation:self.vehicleAnnotation];
            if (vehView) {
                [vehView updateHeading:puckHeading cameraHeading:0.0];
            }
        }

        [self.speedometer updateSpeed:location.speed];

        BOOL isRouteSelectorActive = (self.routeSelector && !self.routeSelector.hidden);
        if (self.isTrackingVehicle && self.hasPerformedInitialZoom && location.speed >= 1.2 && !isRouteSelectorActive) {
            [self.mapView setCenterCoordinate:location.coordinate animated:NO];
        }
    }
}

#pragma mark - Display Link Loop (Avanzamento a 30 FPS con Gradiente di Velocità)

- (void)handleDisplayLink:(CADisplayLink *)link {
    CFTimeInterval now = CACurrentMediaTime();
    CFTimeInterval dt = now - self.lastFrameTime;
    self.lastFrameTime = now;
    if (dt <= 0.001 || dt > 0.25) {
        dt = 0.033;
    }

    if (self.isNavigating && self.trackingEngine.hasActiveRoute) {
        // 1. Avanza lungo la polyline interpolando la velocità del GPS come gradiente
        [self.trackingEngine updateTickWithDeltaTime:dt];

        double speed = self.trackingEngine.smoothedSpeed;

        if (![self.mapView.annotations containsObject:self.vehicleAnnotation]) {
            [self.mapView addAnnotation:self.vehicleAnnotation];
        }
        self.isCruisingWithVehiclePuck = YES;

        // 3. Aggiorna tachimetro in modo fluido
        [self.speedometer updateSpeed:speed];

        // 4. Se in crociera con puck attivo, aggiorna posizione, rotazione e insegui con telecamera 3D
        if (self.isCruisingWithVehiclePuck) {
            CLLocationCoordinate2D vehicleCoord = self.trackingEngine.currentCoordinate;
            CLLocationDirection vehicleHeading = self.trackingEngine.currentHeading;

            [self.vehicleAnnotation updateCoordinate:vehicleCoord heading:vehicleHeading];
            VehicleAnnotationView *vehView = (VehicleAnnotationView *)[self.mapView viewForAnnotation:self.vehicleAnnotation];
            if (vehView) {
                [vehView updateHeading:vehicleHeading cameraHeading:0.0];
            }

            if (self.isTrackingVehicle) {
                // In iOS 6 2D navigation: center the map on the vehicle
                [self.mapView setCenterCoordinate:vehicleCoord animated:NO];
            }
        }

        // 5. Aggiorna countdown e HUD
        [self updateHUDFromTrackingEngine];
    }

    // Controllo allerta autovelox a cadenza regolare (~2 volte al secondo)
    if (now - self.lastCameraCheckTime > 0.5) {
        self.lastCameraCheckTime = now;
        [self checkSpeedCameraAlerts];
    }
}

- (void)updateHUDFromTrackingEngine {
    if (!self.isNavigating || !self.currentRoute) return;

    // Aggiornamento limite di velocità dinamico per la strada su cui si sta attualmente transitando
    NSUInteger roadIdx = self.trackingEngine.currentRoadStepIndex;
    if (roadIdx < self.currentRoute.steps.count) {
        ManeuverStep *currentRoadStep = self.currentRoute.steps[roadIdx];
        int dynamicLimit = currentRoadStep.speedLimit;
        if (dynamicLimit <= 0) {
            dynamicLimit = [RoutingService deduceSpeedLimitForStep:currentRoadStep];
        }

        // Se è presente un autovelox in avvicinamento entro 500m con limite certificato, ha la precedenza
        CLLocationDistance camDist = 0;
        CLLocationDirection heading = (self.vehicleAnnotation.heading >= 0) ? self.vehicleAnnotation.heading : self.currentHeading;
        SpeedCamera *cam = [[SpeedCameraService sharedService] checkApproachingCameraFromLocation:self.currentLocation
                                                                                            heading:heading
                                                                                        outDistance:&camDist];
        if (cam && cam.speedLimit > 0 && camDist < 500.0) {
            dynamicLimit = cam.speedLimit;
        }

        [self.speedometer setDynamicSpeedLimit:dynamicLimit];
    }

    // Aggiornamento della prossima manovra nell'HUD
    NSUInteger stepIdx = self.trackingEngine.currentStepIndex;
    if (stepIdx < self.currentRoute.steps.count) {
        ManeuverStep *targetStep = self.currentRoute.steps[stepIdx];
        CLLocationDistance distToStep = self.trackingEngine.remainingDistanceToStep;
        ManeuverStep *nextStep = (stepIdx + 1 < self.currentRoute.steps.count) ? self.currentRoute.steps[stepIdx + 1] : nil;

        [self.maneuverHUD updateWithManeuver:targetStep distanceToStep:distToStep nextStep:nextStep];

        CLLocationDistance remainingDist = self.trackingEngine.remainingDistanceToDestination;
        NSTimeInterval remainingDuration = self.trackingEngine.remainingDuration;
        [self.tripBar updateRemainingDistance:remainingDist duration:remainingDuration trafficStatus:self.currentRoute.trafficDescription];

        // Istruzioni vocali discrete con checkpoint
        [[VoiceGuidanceService sharedService] speakManeuverModifier:targetStep.modifier
                                                               type:targetStep.type
                                                   distanceInMeters:distToStep
                                                          stepIndex:stepIdx
                                                fallbackInstruction:targetStep.instruction];
    }
}

#pragma mark - Gestione e Allerte Autovelox

- (void)checkSpeedCameraAlerts {
    if (!self.currentLocation) return;

    BOOL alertsEnabled = YES;
    if ([[NSUserDefaults standardUserDefaults] objectForKey:@"SpeedCameraAlertsEnabled"]) {
        alertsEnabled = [[NSUserDefaults standardUserDefaults] boolForKey:@"SpeedCameraAlertsEnabled"];
    }
    if (!alertsEnabled) {
        if (!self.cameraAlertBanner.hidden) {
            self.cameraAlertBanner.hidden = YES;
        }
        return;
    }

    CLLocationDistance distToCam = 0;
    CLLocationDirection heading = (self.vehicleAnnotation.heading >= 0) ? self.vehicleAnnotation.heading : self.currentHeading;
    SpeedCamera *approaching = [[SpeedCameraService sharedService] checkApproachingCameraFromLocation:self.currentLocation
                                                                                               heading:heading
                                                                                           outDistance:&distToCam];

    if (approaching) {
        if (approaching.speedLimit > 0 && distToCam < 500.0) {
            [self.speedometer setDynamicSpeedLimit:approaching.speedLimit];
        }

        NSString *limitText = (approaching.speedLimit > 0) ? [NSString stringWithFormat:@" • Limite %d km/h", approaching.speedLimit] : @"";
        self.cameraAlertLabel.text = [NSString stringWithFormat:@"📸 %@ a %.0fm%@", [approaching typeDescription], distToCam, limitText];

        if (self.cameraAlertBanner.hidden) {
            self.cameraAlertBanner.alpha = 0.0;
            self.cameraAlertBanner.hidden = NO;
            [UIView animateWithDuration:0.25 animations:^{
                self.cameraAlertBanner.alpha = 1.0;
            }];
        }

        // Notifica vocale con cooldown di 45 secondi
        BOOL canVoiceAlert = (approaching.osmId != self.lastAlertedCameraId) ||
                             (!self.lastCameraAlertDate || [[NSDate date] timeIntervalSinceDate:self.lastCameraAlertDate] > 45.0);

        if (canVoiceAlert && distToCam < 600.0) {
            self.lastAlertedCameraId = approaching.osmId;
            self.lastCameraAlertDate = [NSDate date];

            int roundedDist = (int)(round(distToCam / 50.0) * 50.0);
            if (roundedDist < 50) roundedDist = 50;

            NSString *voiceText;
            if (approaching.speedLimit > 0) {
                voiceText = [NSString stringWithFormat:NLString(@"SPEED_CAMERA_AT_M_LIMIT", @"Attenzione, controllo della velocità a %d metri. Limite %d chilometri orari."),
                             roundedDist, approaching.speedLimit];
            } else {
                voiceText = [NSString stringWithFormat:NLString(@"SPEED_CAMERA_AT_M", @"Attenzione, postazione di controllo velocità a %d metri."),
                             roundedDist];
            }
            if (![[VoiceGuidanceService sharedService] playPromptNamed:@"speedcam"]) {
                [[VoiceGuidanceService sharedService] speakAlert:voiceText];
            }
        }
    } else {
        if (!self.cameraAlertBanner.hidden) {
            [UIView animateWithDuration:0.25 animations:^{
                self.cameraAlertBanner.alpha = 0.0;
            } completion:^(BOOL finished) {
                self.cameraAlertBanner.hidden = YES;
            }];
        }
    }
}

- (void)refreshSpeedCamerasAroundCoordinate:(CLLocationCoordinate2D)coord {
    if (!self.isNavigating) return;
    if (!CLLocationCoordinate2DIsValid(coord) || (fabs(coord.latitude) < 0.1 && fabs(coord.longitude) < 0.1)) return;
    __weak NavigationViewController *weakSelf = self;
    [[SpeedCameraService sharedService] fetchCamerasAroundCoordinate:coord radiusMeters:15000 completion:^(NSArray *cameras, NSError *error) {
        dispatch_async(dispatch_get_main_queue(), ^{
            [weakSelf updateCameraAnnotationsOnMap];
        });
    }];
}

- (void)refreshSpeedCamerasForRoute:(RouteInfo *)route {
    if (!self.isNavigating || !route) return;
    __weak NavigationViewController *weakSelf = self;
    [[SpeedCameraService sharedService] fetchCamerasAlongRoute:route completion:^(NSArray *cameras, NSError *error) {
        dispatch_async(dispatch_get_main_queue(), ^{
            [weakSelf updateCameraAnnotationsOnMap];
        });
    }];
}

- (void)updateCameraAnnotationsOnMap {
    if (!self.cameraAnnotations) {
        self.cameraAnnotations = [NSMutableArray array];
    }
    if (self.cameraAnnotations.count > 0) {
        [self.mapView removeAnnotations:self.cameraAnnotations];
        [self.cameraAnnotations removeAllObjects];
    }

    // Mostra gli autovelox su mappa SOLO se stiamo navigando attivamente!
    if (!self.isNavigating || !self.currentRoute) {
        return;
    }

    NSArray *anns = [[SpeedCameraService sharedService] annotationsForCachedCameras];
    if (anns.count > 0) {
        [self.cameraAnnotations addObjectsFromArray:anns];
        [self.mapView addAnnotations:anns];
    }
}

#pragma mark - Gestione Distributori Carburante (Toggle al Volo ⛽)

- (BOOL)shouldShowFuelStationsOnMap {
    if (self.isNavigating) {
        return self.isFuelVisibleDuringNavigation;
    }
    return NO;
}

- (void)toggleFuelStationsOnMap {
    self.isFuelVisibleDuringNavigation = !self.isFuelVisibleDuringNavigation;
    [self updateFuelToggleButtonAppearance];

    if (self.isFuelVisibleDuringNavigation) {
        CLLocationCoordinate2D center = self.mapView.centerCoordinate;
        if (self.isTrackingVehicle && self.currentLocation && CLLocationCoordinate2DIsValid(self.currentLocation.coordinate) && fabs(self.currentLocation.coordinate.latitude) > 0.1) {
            center = self.currentLocation.coordinate;
        }
        [self refreshFuelStationsAroundCoordinate:center];
        [[VoiceGuidanceService sharedService] speakAlert:NLString(@"FUEL_SHOWN_VOICE", @"Distributori attivati sulla mappa.")];
    } else {
        [self updateFuelAnnotationsOnMap];
        [[VoiceGuidanceService sharedService] speakAlert:NLString(@"FUEL_HIDDEN_VOICE", @"Distributori nascosti.")];
    }
}

- (void)updateFuelToggleButtonAppearance {
    if (self.isFuelVisibleDuringNavigation) {
        self.fuelToggleButton.layer.borderColor = [[UIColor colorWithRed:0.18 green:0.80 blue:0.44 alpha:1.0] CGColor]; // Verde attivo
        self.fuelToggleButton.layer.borderWidth = 2.4;
        self.fuelToggleButton.backgroundColor = [UIColor colorWithRed:0.08 green:0.25 blue:0.14 alpha:0.95];
    } else {
        self.fuelToggleButton.layer.borderColor = [[UIColor colorWithWhite:0.35 alpha:0.75] CGColor];
        self.fuelToggleButton.layer.borderWidth = 1.0;
        self.fuelToggleButton.backgroundColor = [UIColor colorWithWhite:0.12 alpha:0.92];
    }
}

- (void)refreshFuelStationsAroundCoordinate:(CLLocationCoordinate2D)coord {
    if (![self shouldShowFuelStationsOnMap]) return;
    if (!CLLocationCoordinate2DIsValid(coord) || (fabs(coord.latitude) < 0.1 && fabs(coord.longitude) < 0.1)) return;
    __weak NavigationViewController *weakSelf = self;
    [[FuelPriceService sharedService] fetchStationsAroundCoordinate:coord radiusKm:15 completion:^(NSArray *stations, NSError *error) {
        dispatch_async(dispatch_get_main_queue(), ^{
            [weakSelf updateFuelAnnotationsOnMap];
        });
    }];
}

- (void)refreshFuelStationsForRoute:(RouteInfo *)route {
    if (![self shouldShowFuelStationsOnMap]) return;
    if (!route) return;
    __weak NavigationViewController *weakSelf = self;
    [[FuelPriceService sharedService] fetchStationsAlongRoute:route completion:^(NSArray *stations, NSError *error) {
        dispatch_async(dispatch_get_main_queue(), ^{
            [weakSelf updateFuelAnnotationsOnMap];
        });
    }];
}

- (void)updateFuelAnnotationsOnMap {
    if (![NSThread isMainThread]) {
        dispatch_async(dispatch_get_main_queue(), ^{
            [self updateFuelAnnotationsOnMap];
        });
        return;
    }

    if (!self.mapView) return;

    if (!self.fuelAnnotations) {
        self.fuelAnnotations = [NSMutableArray array];
    }
    if (self.fuelAnnotations.count > 0) {
        [self.mapView removeAnnotations:self.fuelAnnotations];
        [self.fuelAnnotations removeAllObjects];
    }

    if (![self shouldShowFuelStationsOnMap]) {
        return;
    }

    NSArray *anns = [[FuelPriceService sharedService] annotationsForCachedStations];
    if (anns.count > 0) {
        [self.fuelAnnotations addObjectsFromArray:anns];
        [self.mapView addAnnotations:anns];
    }
}

#pragma mark - RouteTrackingEngineDelegate

- (void)routeTrackingEngine:(RouteTrackingEngine *)engine
        didAdvanceToStepIndex:(NSUInteger)stepIndex
      remainingDistanceToStep:(CLLocationDistance)distToStep {
    if (self.detourRecalculateButton && !self.detourRecalculateButton.hidden) {
        self.detourRecalculateButton.hidden = YES;
        self.consecutiveRerouteAttempts = 0;
    }
    if (self.currentRoute && stepIndex < self.currentRoute.steps.count) {
        ManeuverStep *step = self.currentRoute.steps[stepIndex];
        ManeuverStep *nextStep = (stepIndex + 1 < self.currentRoute.steps.count) ? self.currentRoute.steps[stepIndex + 1] : nil;
        [self.maneuverHUD updateWithManeuver:step distanceToStep:distToStep nextStep:nextStep];
    }
}

- (void)routeTrackingEngineDidArriveAtDestination:(RouteTrackingEngine *)engine {
    [[VoiceGuidanceService sharedService] speakAlert:NLString(@"ARRIVED", @"Sei arrivato a destinazione.")];
    [self cancelCurrentRoute];
}

- (void)routeTrackingEngineDidDetectOffRoute:(RouteTrackingEngine *)engine atLocation:(CLLocation *)location {
    self.isCruisingWithVehiclePuck = NO;
    self.mapView.showsUserLocation = YES;

    self.consecutiveRerouteAttempts++;
    if (self.consecutiveRerouteAttempts <= 2) {
        // Primi tentativi: ricalcolo automatico discreto
        [self triggerAutoReroute];
    } else {
        // Deviazione volontaria del guidatore (es. scelta di un'altra strada o sosta)
        // Evitiamo il ciclo continuo di ricalcolo e audio assillante
        if (self.detourRecalculateButton) {
            self.detourRecalculateButton.hidden = NO;
            [self.view bringSubviewToFront:self.detourRecalculateButton];
        }
    }
}

- (void)triggerAutoReroute {
    if (!self.isNavigating || !self.currentRoute) return;

    NSDate *now = [NSDate date];
    if (self.lastRerouteDate && [now timeIntervalSinceDate:self.lastRerouteDate] < 12.0) {
        // Debounce ricalcolo per evitare spam di richieste di rete ravvicinate
        return;
    }
    self.lastRerouteDate = now;

    NSUInteger thisRequestId = ++self.currentRouteRequestId;

    // Notifica vocale discreta con throttle minimo di 35 secondi
    if (!self.lastRerouteSpokenDate || [now timeIntervalSinceDate:self.lastRerouteSpokenDate] > 35.0) {
        self.lastRerouteSpokenDate = now;
        if (![[VoiceGuidanceService sharedService] playPromptNamed:@"recalculate"]) {
            [[VoiceGuidanceService sharedService] speakAlert:NLString(@"RECALCULATING", @"Ricalcolo del percorso in corso...")];
        }
    }

    CLLocationCoordinate2D start;
    if (self.currentLocation && CLLocationCoordinate2DIsValid(self.currentLocation.coordinate) && self.currentLocation.coordinate.latitude != 0) {
        start = self.currentLocation.coordinate;
    } else if (self.mapView.userLocation.location && CLLocationCoordinate2DIsValid(self.mapView.userLocation.location.coordinate) && self.mapView.userLocation.location.coordinate.latitude != 0) {
        start = self.mapView.userLocation.location.coordinate;
    } else {
        start = self.mapView.centerCoordinate;
    }
    CLLocationCoordinate2D dest = self.currentRoute.destinationCoordinate;
    NSString *title = self.currentRoute.destinationTitle;

    __weak NavigationViewController *weakSelf = self;
    BOOL avoidTolls = self.routeSelector ? self.routeSelector.avoidTolls : NO;
    BOOL avoidHighways = self.routeSelector ? self.routeSelector.avoidHighways : NO;
    [[RoutingService sharedService] calculateRoutesFrom:start
                                                     to:dest
                                       destinationTitle:title
                                             avoidTolls:avoidTolls
                                          avoidHighways:avoidHighways
                                         corridorOffset:0.22
                                             completion:^(NSArray *routes, NSError *error) {
        if (!weakSelf || weakSelf.currentRouteRequestId != thisRequestId || !weakSelf.isNavigating) {
            NSLog(@"[NavigationViewController] Ricalcolo percorso scartato: richiesta annullata o obsoleta.");
            return;
        }
        if (error || routes.count == 0) return;
        RouteInfo *newRoute = routes[0];

        // Rimuovi polylines precedenti
        for (id<MKOverlay> overlay in [weakSelf.mapView.overlays copy]) {
            if ([overlay isKindOfClass:[MKPolyline class]]) {
                [weakSelf.mapView removeOverlay:overlay];
            }
        }

        weakSelf.currentRoute = newRoute;
        weakSelf.currentStepIndex = 0;
        weakSelf.consecutiveRerouteAttempts = 0;
        weakSelf.detourRecalculateButton.hidden = YES;
        [weakSelf.trackingEngine setActiveRoute:newRoute initialLocation:weakSelf.currentLocation];
        [weakSelf.mapView addOverlay:newRoute.polyline];

        if (newRoute.steps.count > 0) {
            ManeuverStep *step1 = newRoute.steps[0];
            ManeuverStep *step2 = (newRoute.steps.count > 1) ? newRoute.steps[1] : nil;
            [weakSelf.maneuverHUD updateWithManeuver:step1 distanceToStep:step1.distance nextStep:step2];
        }
        [weakSelf.tripBar updateRemainingDistance:newRoute.totalDistance duration:newRoute.totalDuration trafficStatus:newRoute.trafficDescription];

        // Rinfresca velox, distributori e prefetch per il nuovo itinerario ricalcolato
        [weakSelf refreshSpeedCamerasForRoute:newRoute];
        [weakSelf refreshFuelStationsForRoute:newRoute];
        [weakSelf.osmOverlay prefetchTilesAlongRoute:newRoute currentDistance:0 lookaheadMeters:4000.0];

        [[VoiceGuidanceService sharedService] resetManeuverTracking];
        [[VoiceGuidanceService sharedService] speakAlert:NLString(@"NEW_ROUTE_READY", @"Nuovo percorso pronto. Continua a guidare.")];
    }];
}

#pragma mark - SettingsViewControllerDelegate

- (void)settingsViewControllerDidUpdateSettings:(SettingsViewController *)controller {
    [self.osmOverlay reloadOfflineDatabases];
}

#pragma mark - MKMapViewDelegate

- (MKOverlayView *)mapView:(MKMapView *)mapView viewForOverlay:(id<MKOverlay>)overlay {
    if ([overlay isKindOfClass:[OSMTileOverlay class]]) {
        return [[OSMTileOverlayView alloc] initWithTileOverlay:(OSMTileOverlay *)overlay];
    }

    if ([overlay isKindOfClass:[TrafficTileOverlay class]]) {
        return [[TrafficTileOverlayView alloc] initWithTrafficOverlay:(TrafficTileOverlay *)overlay];
    }

    if ([overlay isKindOfClass:[MKPolyline class]]) {
        MKPolylineView *view = [[MKPolylineView alloc] initWithPolyline:(MKPolyline *)overlay];
        view.lineCap = kCGLineCapRound;
        view.lineJoin = kCGLineJoinRound;

        if (self.currentRoute && overlay == self.currentRoute.polyline) {
            // Percorso attivo in blu elettrico brillante (#007AFF) ad alto contrasto
            view.strokeColor = [UIColor colorWithRed:0.0 green:0.48 blue:1.0 alpha:0.95];
            view.lineWidth = 8.5;
        } else {
            // Alternative in grigio/azzurro (#6C7A89) ben distinguibile
            view.strokeColor = [UIColor colorWithRed:0.45 green:0.52 blue:0.62 alpha:0.80];
            view.lineWidth = 6.0;
        }
        return view;
    }
    return nil;
}

@end

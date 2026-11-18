#import "RouteSummaryViewController.h"
#import "../Services/LocalizationManager.h"
#import "../Services/VoiceGuidanceService.h"
#import "../Services/FuelPriceService.h"

static NSString *ArrowSymbolForStep(ManeuverStep *step) {
    if (!step) return @"↑";
    NSString *type = step.type ?: @"";
    NSString *modifier = step.modifier ?: @"";

    if ([type isEqualToString:@"arrive"]) return @"🏁";
    if ([type isEqualToString:@"roundabout"]) return @"🔄";
    if ([modifier isEqualToString:@"left"]) return @"↰";
    if ([modifier isEqualToString:@"right"]) return @"↱";
    if ([modifier isEqualToString:@"sharp left"]) return @"↲";
    if ([modifier isEqualToString:@"sharp right"]) return @"↳";
    if ([modifier isEqualToString:@"slight left"]) return @"↖";
    if ([modifier isEqualToString:@"slight right"]) return @"↗";
    if ([modifier isEqualToString:@"uturn"]) return @"↺";
    return @"↑";
}

@interface RouteSummaryViewController () <UITableViewDataSource, UITableViewDelegate>

@property (nonatomic, strong) UIView *headerView;
@property (nonatomic, strong) UILabel *titleLabel;
@property (nonatomic, strong) UILabel *destinationLabel;
@property (nonatomic, strong) UIButton *topCloseButton;
@property (nonatomic, strong) UIView *headerSeparator;

@property (nonatomic, strong) UIView *metricsView;
@property (nonatomic, strong) UILabel *timeLabel;
@property (nonatomic, strong) UILabel *distanceLabel;
@property (nonatomic, strong) UILabel *trafficLabel;
@property (nonatomic, strong) UILabel *costLabel;
@property (nonatomic, strong) UILabel *stepsCountLabel;
@property (nonatomic, strong) UIView *metricsSeparator;

@property (nonatomic, strong) UITableView *tableView;

@property (nonatomic, strong) UIView *bottomBar;
@property (nonatomic, strong) UIButton *recalculateButton;
@property (nonatomic, strong) UIButton *repeatVoiceButton;
@property (nonatomic, strong) UIButton *closeButton;
@property (nonatomic, strong) UIView *bottomSeparator;

@end

@implementation RouteSummaryViewController

- (void)dealloc {
    [[NSNotificationCenter defaultCenter] removeObserver:self];
}

- (instancetype)init {
    self = [super init];
    if (self) {
        self.contentSizeForViewInPopover = CGSizeMake(540, 620);
        self.modalPresentationStyle = UIModalPresentationFormSheet;
    }
    return self;
}

- (void)viewDidLoad {
    [super viewDidLoad];
    self.view.backgroundColor = [UIColor colorWithWhite:0.10 alpha:1.0];

    [self setupHeader];
    [self setupMetrics];
    [self setupBottomBar];
    [self setupTableView];

    [[NSNotificationCenter defaultCenter] addObserver:self
                                             selector:@selector(handleLanguageChanged)
                                                 name:kAppLanguagePreferenceChangedNotification
                                               object:nil];

    [self scrollToCurrentStep];
}

- (void)viewDidLayoutSubviews {
    [super viewDidLayoutSubviews];

    CGFloat w = self.view.bounds.size.width;
    CGFloat h = self.view.bounds.size.height;
    if (w <= 0 || h <= 0) return;

    // 1. Header
    CGFloat headerH = 64.0;
    _headerView.frame = CGRectMake(0, 0, w, headerH);
    _titleLabel.frame = CGRectMake(20, 10, w - 75, 24);
    _destinationLabel.frame = CGRectMake(20, 36, w - 75, 20);
    _topCloseButton.frame = CGRectMake(w - 50, 12, 40, 40);
    _headerSeparator.frame = CGRectMake(0, headerH - 1, w, 1);

    // 2. Metrics (78px per ospitare comodamente durata, distanza, traffico, costi carburante/pedaggio e passaggi)
    CGFloat metricsH = 78.0;
    _metricsView.frame = CGRectMake(0, headerH, w, metricsH);
    CGFloat colW = floor((w - 32.0) / 3.0);
    _timeLabel.frame = CGRectMake(16, 8, colW, 22);
    _distanceLabel.frame = CGRectMake(16 + colW, 8, colW, 22);
    _trafficLabel.frame = CGRectMake(16 + colW * 2, 8, w - 16 - (16 + colW * 2), 22);
    _costLabel.frame = CGRectMake(16, 32, w - 32, 20);
    _stepsCountLabel.frame = CGRectMake(16, 54, w - 32, 18);
    _metricsSeparator.frame = CGRectMake(0, metricsH - 1, w, 1);

    // 3. Bottom Action Bar (altezza 70px)
    CGFloat bottomH = 70.0;
    _bottomBar.frame = CGRectMake(0, h - bottomH, w, bottomH);
    _bottomSeparator.frame = CGRectMake(0, 0, w, 1);

    // Layout esplicito dei 3 pulsanti proporzionato alla larghezza REALE della view (risolve sovrapposizioni Issue #4)
    CGFloat btnH = 46.0;
    CGFloat spacing = 8.0;
    CGFloat usableW = w - 32.0 - (spacing * 2.0);
    CGFloat recalcW = round(usableW * 0.46);
    CGFloat voiceW = round(usableW * 0.30);
    CGFloat closeW = usableW - recalcW - voiceW;

    _recalculateButton.frame = CGRectMake(16, 12, recalcW, btnH);
    _repeatVoiceButton.frame = CGRectMake(16 + recalcW + spacing, 12, voiceW, btnH);
    _closeButton.frame = CGRectMake(16 + recalcW + spacing + voiceW + spacing, 12, closeW, btnH);

    // 4. Table View (riempie tutto lo spazio tra metrics e bottom bar)
    CGFloat tableY = headerH + metricsH;
    _tableView.frame = CGRectMake(0, tableY, w, h - tableY - bottomH);
}

- (void)setupHeader {
    _headerView = [[UIView alloc] initWithFrame:CGRectZero];
    _headerView.backgroundColor = [UIColor colorWithWhite:0.14 alpha:1.0];
    [self.view addSubview:_headerView];

    _titleLabel = [[UILabel alloc] initWithFrame:CGRectZero];
    _titleLabel.backgroundColor = [UIColor clearColor];
    _titleLabel.font = [UIFont boldSystemFontOfSize:18.0];
    _titleLabel.textColor = [UIColor whiteColor];
    _titleLabel.text = NLString(@"ROUTE_SUMMARY", @"📋 Riepilogo Itinerario");
    [_headerView addSubview:_titleLabel];

    _destinationLabel = [[UILabel alloc] initWithFrame:CGRectZero];
    _destinationLabel.backgroundColor = [UIColor clearColor];
    _destinationLabel.font = [UIFont systemFontOfSize:13.0];
    _destinationLabel.textColor = [UIColor colorWithWhite:0.75 alpha:1.0];
    _destinationLabel.text = self.route.destinationTitle ?: NLString(@"SELECTED_DESTINATION", @"Точка назначения");
    [_headerView addSubview:_destinationLabel];

    _topCloseButton = [UIButton buttonWithType:UIButtonTypeCustom];
    [_topCloseButton setTitle:@"✕" forState:UIControlStateNormal];
    [_topCloseButton setTitleColor:[UIColor whiteColor] forState:UIControlStateNormal];
    _topCloseButton.titleLabel.font = [UIFont boldSystemFontOfSize:20.0];
    [_topCloseButton addTarget:self action:@selector(handleClose) forControlEvents:UIControlEventTouchUpInside];
    [_headerView addSubview:_topCloseButton];

    _headerSeparator = [[UIView alloc] initWithFrame:CGRectZero];
    _headerSeparator.backgroundColor = [UIColor colorWithWhite:0.25 alpha:1.0];
    [_headerView addSubview:_headerSeparator];
}

- (void)setupMetrics {
    _metricsView = [[UIView alloc] initWithFrame:CGRectZero];
    _metricsView.backgroundColor = [UIColor colorWithWhite:0.16 alpha:1.0];
    [self.view addSubview:_metricsView];

    NSString *timeStr = NLFormatDuration(self.route.totalDuration);
    NSString *distStr = NLFormatDistance(self.route.totalDistance);

    _timeLabel = [[UILabel alloc] initWithFrame:CGRectZero];
    _timeLabel.backgroundColor = [UIColor clearColor];
    _timeLabel.font = [UIFont boldSystemFontOfSize:17.0];
    _timeLabel.textColor = [UIColor colorWithRed:0.2 green:0.8 blue:0.4 alpha:1.0];
    _timeLabel.text = timeStr;
    _timeLabel.adjustsFontSizeToFitWidth = YES;
    _timeLabel.minimumScaleFactor = 0.75;
    [_metricsView addSubview:_timeLabel];

    _distanceLabel = [[UILabel alloc] initWithFrame:CGRectZero];
    _distanceLabel.backgroundColor = [UIColor clearColor];
    _distanceLabel.font = [UIFont boldSystemFontOfSize:17.0];
    _distanceLabel.textColor = [UIColor colorWithRed:0.3 green:0.75 blue:1.0 alpha:1.0];
    _distanceLabel.text = distStr;
    _distanceLabel.adjustsFontSizeToFitWidth = YES;
    _distanceLabel.minimumScaleFactor = 0.75;
    [_metricsView addSubview:_distanceLabel];

    _trafficLabel = [[UILabel alloc] initWithFrame:CGRectZero];
    _trafficLabel.backgroundColor = [UIColor clearColor];
    _trafficLabel.font = [UIFont boldSystemFontOfSize:13.0];
    _trafficLabel.textColor = [UIColor colorWithWhite:0.92 alpha:1.0];
    NSString *tDesc = self.route.trafficDescription ?: NLString(@"TRAFFIC_SMOOTH", @"✅ Свободно");
    _trafficLabel.text = tDesc;
    _trafficLabel.adjustsFontSizeToFitWidth = YES;
    _trafficLabel.minimumScaleFactor = 0.70;
    [_metricsView addSubview:_trafficLabel];

    // Calcolo consumo carburante stimato (litri e costo)
    FuelPriceService *fuel = [FuelPriceService sharedService];
    FuelType fType = fuel.selectedFuelType;
    double distKm = self.route.totalDistance / 1000.0;
    double consRate = [fuel effectiveConsumptionForFuelType:fType];
    double estUnits = distKm * (consRate / 100.0);
    NSString *unitStr = [fuel unitForFuelType:fType] ?: @"L";
    NSString *cur = fuel.currencySymbol ?: @"€";

    if (self.route.totalTripCost <= 0.01) {
        [self.route updateTripCosts];
    }

    _costLabel = [[UILabel alloc] initWithFrame:CGRectZero];
    _costLabel.backgroundColor = [UIColor clearColor];
    _costLabel.font = [UIFont systemFontOfSize:12.5];
    _costLabel.textColor = [UIColor colorWithRed:1.0 green:0.82 blue:0.3 alpha:1.0];
    if ([cur isEqualToString:@"-"] || [cur isEqualToString:@" "]) {
        _costLabel.text = [NSString stringWithFormat:@"⛽ ~%.1f %@", estUnits, unitStr];
    } else {
        _costLabel.text = [NSString stringWithFormat:@"⛽ ~%.1f %@ • ~%.2f %@", estUnits, unitStr, self.route.fuelCost, cur];
    }
    _costLabel.adjustsFontSizeToFitWidth = YES;
    _costLabel.minimumScaleFactor = 0.75;
    [_metricsView addSubview:_costLabel];

    _stepsCountLabel = [[UILabel alloc] initWithFrame:CGRectZero];
    _stepsCountLabel.backgroundColor = [UIColor clearColor];
    _stepsCountLabel.font = [UIFont systemFontOfSize:12.0];
    _stepsCountLabel.textColor = [UIColor colorWithWhite:0.65 alpha:1.0];
    _stepsCountLabel.text = [NSString stringWithFormat:@"%lu %@ • %@",
                             (unsigned long)self.route.steps.count,
                             NLString(@"STEPS", @"Маневров"),
                             self.route.badgeTitle ?: @""];
    _stepsCountLabel.adjustsFontSizeToFitWidth = YES;
    _stepsCountLabel.minimumScaleFactor = 0.8;
    [_metricsView addSubview:_stepsCountLabel];

    _metricsSeparator = [[UIView alloc] initWithFrame:CGRectZero];
    _metricsSeparator.backgroundColor = [UIColor colorWithWhite:0.25 alpha:1.0];
    [_metricsView addSubview:_metricsSeparator];
}

- (void)setupBottomBar {
    _bottomBar = [[UIView alloc] initWithFrame:CGRectZero];
    _bottomBar.backgroundColor = [UIColor colorWithWhite:0.14 alpha:1.0];
    [self.view addSubview:_bottomBar];

    _bottomSeparator = [[UIView alloc] initWithFrame:CGRectZero];
    _bottomSeparator.backgroundColor = [UIColor colorWithWhite:0.25 alpha:1.0];
    [_bottomBar addSubview:_bottomSeparator];

    _recalculateButton = [UIButton buttonWithType:UIButtonTypeCustom];
    _recalculateButton.backgroundColor = [UIColor colorWithRed:0.0 green:0.48 blue:0.95 alpha:1.0];
    _recalculateButton.layer.cornerRadius = 10.0;
    [_recalculateButton setTitle:NLString(@"FIND_MORE_ROUTES", @"🔄 Другие варианты") forState:UIControlStateNormal];
    [_recalculateButton setTitleColor:[UIColor whiteColor] forState:UIControlStateNormal];
    _recalculateButton.titleLabel.font = [UIFont boldSystemFontOfSize:13.5];
    _recalculateButton.titleLabel.adjustsFontSizeToFitWidth = YES;
    _recalculateButton.titleLabel.minimumScaleFactor = 0.65;
    [_recalculateButton addTarget:self action:@selector(handleRecalculate) forControlEvents:UIControlEventTouchUpInside];
    [_bottomBar addSubview:_recalculateButton];

    _repeatVoiceButton = [UIButton buttonWithType:UIButtonTypeCustom];
    _repeatVoiceButton.backgroundColor = [UIColor colorWithWhite:0.25 alpha:1.0];
    _repeatVoiceButton.layer.cornerRadius = 10.0;
    [_repeatVoiceButton setTitle:NLString(@"REPEAT_VOICE", @"🔊 Повторить") forState:UIControlStateNormal];
    [_repeatVoiceButton setTitleColor:[UIColor whiteColor] forState:UIControlStateNormal];
    _repeatVoiceButton.titleLabel.font = [UIFont boldSystemFontOfSize:13.0];
    _repeatVoiceButton.titleLabel.adjustsFontSizeToFitWidth = YES;
    _repeatVoiceButton.titleLabel.minimumScaleFactor = 0.7;
    [_repeatVoiceButton addTarget:self action:@selector(handleRepeatVoice) forControlEvents:UIControlEventTouchUpInside];
    [_bottomBar addSubview:_repeatVoiceButton];

    _closeButton = [UIButton buttonWithType:UIButtonTypeCustom];
    _closeButton.backgroundColor = [UIColor colorWithWhite:0.20 alpha:1.0];
    _closeButton.layer.cornerRadius = 10.0;
    [_closeButton setTitle:NLString(@"CLOSE", @"✕ Закрыть") forState:UIControlStateNormal];
    [_closeButton setTitleColor:[UIColor whiteColor] forState:UIControlStateNormal];
    _closeButton.titleLabel.font = [UIFont systemFontOfSize:13.0];
    _closeButton.titleLabel.adjustsFontSizeToFitWidth = YES;
    _closeButton.titleLabel.minimumScaleFactor = 0.7;
    [_closeButton addTarget:self action:@selector(handleClose) forControlEvents:UIControlEventTouchUpInside];
    [_bottomBar addSubview:_closeButton];
}

- (void)setupTableView {
    _tableView = [[UITableView alloc] initWithFrame:CGRectZero style:UITableViewStylePlain];
    _tableView.backgroundColor = [UIColor colorWithWhite:0.11 alpha:1.0];
    _tableView.separatorColor = [UIColor colorWithWhite:0.22 alpha:1.0];
    _tableView.dataSource = self;
    _tableView.delegate = self;
    _tableView.rowHeight = 62.0;
    [self.view addSubview:_tableView];
}

- (void)scrollToCurrentStep {
    if (self.currentStepIndex < self.route.steps.count) {
        NSIndexPath *ip = [NSIndexPath indexPathForRow:self.currentStepIndex inSection:0];
        [_tableView scrollToRowAtIndexPath:ip atScrollPosition:UITableViewScrollPositionMiddle animated:NO];
    }
}

- (void)handleLanguageChanged {
    _titleLabel.text = NLString(@"ROUTE_SUMMARY", @"📋 Маршрут");
    [_recalculateButton setTitle:NLString(@"FIND_MORE_ROUTES", @"🔄 Другие варианты") forState:UIControlStateNormal];
    [_repeatVoiceButton setTitle:NLString(@"REPEAT_VOICE", @"🔊 Повторить") forState:UIControlStateNormal];
    [_closeButton setTitle:NLString(@"CLOSE", @"✕ Закрыть") forState:UIControlStateNormal];

    if (self.route.totalTripCost <= 0.01) {
        [self.route updateTripCosts];
    }
    NSString *cur = [FuelPriceService sharedService].currencySymbol ?: @"€";
    BOOL hasCur = ![cur isEqualToString:@"—"];
    if (self.route.tollCost > 0.05) {
        NSString *curSuffix = hasCur ? [NSString stringWithFormat:@" %@", cur] : @"";
        _costLabel.text = [NSString stringWithFormat:@"⛽ %.2f%@ • 🚗 %.2f%@ • %@ %.2f%@",
                           self.route.fuelCost, curSuffix, self.route.tollCost, curSuffix, NLString(@"TOTAL_LABEL", @"Всего"), self.route.totalTripCost, curSuffix];
    } else {
        _costLabel.text = hasCur ? [NSString stringWithFormat:@"⛽ %.2f %@", self.route.fuelCost, cur] : [NSString stringWithFormat:@"⛽ %.2f", self.route.fuelCost];
    }
    _stepsCountLabel.text = [NSString stringWithFormat:@"%lu %@ • %@",
                             (unsigned long)self.route.steps.count,
                             NLString(@"STEPS", @"Маневров"),
                             self.route.badgeTitle ?: @""];
    [_tableView reloadData];
}

#pragma mark - Actions

- (void)handleRecalculate {
    if ([self.delegate respondsToSelector:@selector(routeSummaryViewControllerDidRequestRecalculate:)]) {
        [self.delegate routeSummaryViewControllerDidRequestRecalculate:self];
    } else {
        [self dismissViewControllerAnimated:YES completion:nil];
    }
}

- (void)handleRepeatVoice {
    if ([self.delegate respondsToSelector:@selector(routeSummaryViewControllerDidRequestRepeatVoice:)]) {
        [self.delegate routeSummaryViewControllerDidRequestRepeatVoice:self];
    } else if (self.currentStepIndex < self.route.steps.count) {
        ManeuverStep *step = self.route.steps[self.currentStepIndex];
        [[VoiceGuidanceService sharedService] repeatCurrentManeuverModifier:step.modifier
                                                                       type:step.type
                                                                   distance:step.distance];
    }
}

- (void)handleClose {
    if ([self.delegate respondsToSelector:@selector(routeSummaryViewControllerDidClose:)]) {
        [self.delegate routeSummaryViewControllerDidClose:self];
    }
    [self dismissViewControllerAnimated:YES completion:nil];
}

#pragma mark - UITableViewDataSource

- (NSInteger)tableView:(UITableView *)tableView numberOfRowsInSection:(NSInteger)section {
    return self.route.steps.count;
}

- (UITableViewCell *)tableView:(UITableView *)tableView cellForRowAtIndexPath:(NSIndexPath *)indexPath {
    static NSString *CellId = @"RouteStepCell";
    UITableViewCell *cell = [tableView dequeueReusableCellWithIdentifier:CellId];
    if (!cell) {
        cell = [[UITableViewCell alloc] initWithStyle:UITableViewCellStyleSubtitle reuseIdentifier:CellId];
        cell.backgroundColor = [UIColor colorWithWhite:0.12 alpha:1.0];
        cell.textLabel.backgroundColor = [UIColor clearColor];
        cell.textLabel.textColor = [UIColor whiteColor];
        cell.textLabel.font = [UIFont boldSystemFontOfSize:14.0];
        cell.detailTextLabel.backgroundColor = [UIColor clearColor];
        cell.detailTextLabel.textColor = [UIColor colorWithRed:0.25 green:0.75 blue:1.0 alpha:1.0];
        cell.detailTextLabel.font = [UIFont boldSystemFontOfSize:12.0];
    }

    if (indexPath.row >= self.route.steps.count) return cell;

    ManeuverStep *step = self.route.steps[indexPath.row];
    NSString *symbol = ArrowSymbolForStep(step);

    NSString *street = (step.streetName.length > 0) ? step.streetName : step.instruction;
    cell.textLabel.text = [NSString stringWithFormat:@"%ld. %@  %@", (long)(indexPath.row + 1), symbol, street ?: @""];

    NSString *distStr = NLFormatDistance(step.distance);

    BOOL isCurrent = (indexPath.row == self.currentStepIndex);
    if (isCurrent) {
        cell.backgroundColor = [UIColor colorWithRed:0.0 green:0.35 blue:0.22 alpha:0.85]; // Emerald highlight
        cell.detailTextLabel.text = [NSString stringWithFormat:@"▶ %@ • %@", distStr, step.instruction ?: @""];
        cell.detailTextLabel.textColor = [UIColor colorWithRed:0.4 green:1.0 blue:0.6 alpha:1.0];
    } else {
        cell.backgroundColor = [UIColor colorWithWhite:0.12 alpha:1.0];
        cell.detailTextLabel.text = [NSString stringWithFormat:@"%@ • %@", distStr, step.instruction ?: @""];
        cell.detailTextLabel.textColor = [UIColor colorWithWhite:0.65 alpha:1.0];
    }

    return cell;
}

#pragma mark - UITableViewDelegate

- (void)tableView:(UITableView *)tableView didSelectRowAtIndexPath:(NSIndexPath *)indexPath {
    [tableView deselectRowAtIndexPath:indexPath animated:YES];
    if (indexPath.row < self.route.steps.count) {
        ManeuverStep *step = self.route.steps[indexPath.row];
        [[VoiceGuidanceService sharedService] repeatCurrentManeuverModifier:step.modifier
                                                                       type:step.type
                                                                   distance:step.distance];
        if ([self.delegate respondsToSelector:@selector(routeSummaryViewController:didSelectStepIndex:)]) {
            [self.delegate routeSummaryViewController:self didSelectStepIndex:indexPath.row];
        }
    }
}

@end

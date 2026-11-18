#import "SettingsViewController.h"
#import "Services/NetworkGPSReceiver.h"
#import "Services/VoiceGuidanceService.h"
#import "Services/LocalizationManager.h"
#import "Services/FuelPriceService.h"
#import "Services/TollGuruService.h"
#import "Overlays/TrafficTileOverlay.h"
#import "Overlays/OSMTileOverlay.h"
#import "Services/SpeedCameraService.h"

@interface SettingsViewController () <UITextFieldDelegate>

@property (nonatomic, strong) NSTimer *refreshTimer;
@property (nonatomic, strong) UISegmentedControl *languageSegment;
@property (nonatomic, strong) UISegmentedControl *fuelTypeSegment;
@property (nonatomic, strong) UISegmentedControl *currencySegment;
@property (nonatomic, strong) UITextField *consumptionTextField;
@property (nonatomic, strong) UITextField *priceTextField;
@property (nonatomic, strong) UITextField *portTextField;
@property (nonatomic, strong) UITextField *ipTextField;
@property (nonatomic, strong) UISwitch *voiceSwitch;
@property (nonatomic, strong) UISegmentedControl *voiceModeSegment;
@property (nonatomic, strong) UISwitch *networkGPSSwitch;
@property (nonatomic, strong) UISwitch *showFuelStationsSwitch;

// Traffico & Autovelox
@property (nonatomic, strong) UISwitch *trafficSwitch;
@property (nonatomic, strong) UITextField *trafficApiKeyTextField;
@property (nonatomic, strong) UISwitch *speedCameraAlertSwitch;

// Riferimenti diretti ai label diagnostici (aggiornati senza reloadSections!)
@property (nonatomic, weak) UILabel *diagStatusLabel;
@property (nonatomic, weak) UILabel *diagLocationLabel;
@property (nonatomic, assign) double cachedDiskCacheMB;

@end

@implementation SettingsViewController

- (instancetype)init {
    self = [super initWithStyle:UITableViewStyleGrouped];
    return self;
}

- (void)viewDidLoad {
    [super viewDidLoad];

    [self updateNavigationTitles];

    // Stile scuro per la tabella
    self.tableView.backgroundColor = [UIColor colorWithWhite:0.12 alpha:1.0];
    self.tableView.separatorColor = [UIColor colorWithWhite:0.22 alpha:1.0];

    // Chiudi tastiera al tocco
    UITapGestureRecognizer *tap = [[UITapGestureRecognizer alloc] initWithTarget:self action:@selector(dismissKeyboard)];
    tap.cancelsTouchesInView = NO;
    [self.tableView addGestureRecognizer:tap];

    [self updateDiskCacheSizeInBackground];
}

- (void)updateDiskCacheSizeInBackground {
    if (!self.tileOverlay) return;
    __weak typeof(self) weakSelf = self;
    dispatch_async(dispatch_get_global_queue(DISPATCH_QUEUE_PRIORITY_LOW, 0), ^{
        double mb = ((double)[weakSelf.tileOverlay diskCacheSizeBytes] / (1024.0 * 1024.0));
        dispatch_async(dispatch_get_main_queue(), ^{
            weakSelf.cachedDiskCacheMB = mb;
            [weakSelf.tableView reloadRowsAtIndexPaths:@[[NSIndexPath indexPathForRow:1 inSection:7]] withRowAnimation:UITableViewRowAnimationNone];
        });
    });
}

- (void)updateNavigationTitles {
    self.navigationItem.title = NLString(@"SETTINGS_TITLE", @"⚙️ Impostazioni");
    self.navigationItem.rightBarButtonItem = [[UIBarButtonItem alloc]
        initWithTitle:NLString(@"CLOSE", @"✕ Chiudi")
                style:UIBarButtonItemStyleDone
               target:self
               action:@selector(handleClose)];
    self.navigationItem.rightBarButtonItem.tintColor = [UIColor colorWithRed:0.2 green:0.6 blue:1.0 alpha:1.0];
}

- (void)viewWillAppear:(BOOL)animated {
    [super viewWillAppear:animated];
    // Timer per aggiornare SOLO i label diagnostici via assegnazione diretta
    // MAI chiamare reloadSections qui — causa il freeze su iOS 9!
    self.refreshTimer = [NSTimer scheduledTimerWithTimeInterval:1.5
                                                        target:self
                                                      selector:@selector(refreshDiagnosticLabels)
                                                      userInfo:nil
                                                       repeats:YES];
}

- (void)viewWillDisappear:(BOOL)animated {
    [super viewWillDisappear:animated];
    [self.refreshTimer invalidate];
    self.refreshTimer = nil;
}

#pragma mark - Aggiornamento Diagnostica (SENZA reloadSections!)

- (void)refreshDiagnosticLabels {
    // Aggiornamento diretto dei label — NESSUN reload della tabella!
    NetworkGPSReceiver *gps = [NetworkGPSReceiver sharedReceiver];

    if (self.diagStatusLabel) {
        NSString *ipLocal = [gps localIPAddress];
        NSString *status;
        if (gps.isRunning) {
            status = gps.isDualMode ? NLString(@"CONNECTED_DUAL", @"Duale UDP+TCP") : (gps.isTCPClientMode ? NLString(@"CONNECTED_TCP", @"Connesso TCP") : NLString(@"LISTENING_UDP", @"In ascolto UDP"));
        } else {
            status = NLString(@"STOPPED", @"Fermo");
        }
        self.diagStatusLabel.text = [NSString stringWithFormat:@"IP iPad: %@ • %@ • Pkt: %lu", ipLocal, status, (unsigned long)gps.packetsReceivedCount];
        self.diagStatusLabel.textColor = gps.packetsReceivedCount > 0
            ? [UIColor colorWithRed:0.3 green:0.85 blue:0.4 alpha:1.0]
            : [UIColor colorWithRed:1.0 green:0.7 blue:0.2 alpha:1.0];
    }

    if (self.diagLocationLabel) {
        if (gps.lastLocation) {
            self.diagLocationLabel.text = [NSString stringWithFormat:@"%.4f, %.4f (±%.0fm)",
                gps.lastLocation.coordinate.latitude,
                gps.lastLocation.coordinate.longitude,
                gps.lastLocation.horizontalAccuracy];
            self.diagLocationLabel.textColor = [UIColor colorWithRed:0.3 green:0.85 blue:0.4 alpha:1.0];
        } else {
            self.diagLocationLabel.text = NLString(@"NO_PACKETS", @"Nessun pacchetto ricevuto");
            self.diagLocationLabel.textColor = [UIColor colorWithWhite:0.6 alpha:1.0];
        }
    }
}

- (void)dismissKeyboard {
    [self.view endEditing:YES];
}

- (void)handleClose {
    [self.view endEditing:YES];

    NetworkGPSReceiver *gps = [NetworkGPSReceiver sharedReceiver];

    NSInteger port = [self.portTextField.text integerValue];
    if (port > 0) {
        gps.port = port;
    }

    NSString *ip = [self.ipTextField.text stringByTrimmingCharactersInSet:[NSCharacterSet whitespaceAndNewlineCharacterSet]];
    if (ip.length > 0) {
        gps.tcpHost = ip;
    }

    gps.isDualMode = YES;

    if (self.networkGPSSwitch) {
        gps.isEnabled = self.networkGPSSwitch.isOn;
    }
    if (self.voiceSwitch) {
        [VoiceGuidanceService sharedService].isMuted = !self.voiceSwitch.isOn;
    }
    if (self.voiceModeSegment) {
        [VoiceGuidanceService sharedService].voiceMode = (VoiceGuidanceMode)self.voiceModeSegment.selectedSegmentIndex;
    }

    // Salvataggio impostazioni carburante e consumi
    if (self.fuelTypeSegment) {
        [FuelPriceService sharedService].selectedFuelType = (FuelType)self.fuelTypeSegment.selectedSegmentIndex;
    }
    if (self.consumptionTextField) {
        NSString *txt = [self.consumptionTextField.text stringByReplacingOccurrencesOfString:@"," withString:@"."];
        double val = [txt doubleValue];
        [[FuelPriceService sharedService] setCustomConsumption:val forFuelType:[FuelPriceService sharedService].selectedFuelType];
    }
    if (self.priceTextField) {
        NSString *txt = [self.priceTextField.text stringByReplacingOccurrencesOfString:@"," withString:@"."];
        double val = [txt doubleValue];
        [[FuelPriceService sharedService] setCustomPrice:val forFuelType:[FuelPriceService sharedService].selectedFuelType];
    }
    if (self.showFuelStationsSwitch) {
        [[NSUserDefaults standardUserDefaults] setBool:self.showFuelStationsSwitch.isOn forKey:@"ShowFuelStationsOnMap"];
        [[NSNotificationCenter defaultCenter] postNotificationName:kFuelPricesUpdatedNotification object:nil];
    }

    if (self.trafficSwitch) {
        [TrafficTileOverlay sharedOverlay].isEnabled = self.trafficSwitch.isOn;
    }
    if (self.trafficApiKeyTextField) {
        [[TrafficTileOverlay sharedOverlay] updateApiKey:self.trafficApiKeyTextField.text];
    }
    if (self.speedCameraAlertSwitch) {
        [[NSUserDefaults standardUserDefaults] setBool:self.speedCameraAlertSwitch.isOn forKey:@"SpeedCameraAlertsEnabled"];
    }

    [gps saveSettings];
    [gps startWithSavedSettings];
    [[NSUserDefaults standardUserDefaults] synchronize];

    if ([self.delegate respondsToSelector:@selector(settingsViewControllerDidUpdateSettings:)]) {
        [self.delegate settingsViewControllerDidUpdateSettings:self];
    }
    [self dismissViewControllerAnimated:YES completion:nil];
}

- (void)textFieldDidEndEditing:(UITextField *)textField {
    FuelPriceService *fuel = [FuelPriceService sharedService];
    FuelType type = fuel.selectedFuelType;
    if (textField == self.consumptionTextField) {
        NSString *t = [textField.text stringByReplacingOccurrencesOfString:@"," withString:@"."];
        double val = [t doubleValue];
        [fuel setCustomConsumption:val forFuelType:type];
    } else if (textField == self.priceTextField) {
        NSString *t = [textField.text stringByReplacingOccurrencesOfString:@"," withString:@"."];
        double val = [t doubleValue];
        [fuel setCustomPrice:val forFuelType:type];
    } else if (textField == self.trafficApiKeyTextField) {
        [[TrafficTileOverlay sharedOverlay] updateApiKey:textField.text];
    }
}

- (void)applyFuelTypeChange:(UISegmentedControl *)sender {
    [self.view endEditing:YES];
    FuelType newType = (FuelType)sender.selectedSegmentIndex;
    [FuelPriceService sharedService].selectedFuelType = newType;
    if (self.consumptionTextField) {
        double c = [[FuelPriceService sharedService] effectiveConsumptionForFuelType:newType];
        self.consumptionTextField.text = [NSString stringWithFormat:@"%.1f", c];
    }
    if (self.priceTextField) {
        double p = [[FuelPriceService sharedService] effectivePriceForFuelType:newType];
        self.priceTextField.text = [NSString stringWithFormat:@"%.3f", p];
    }
    [[NSNotificationCenter defaultCenter] postNotificationName:kFuelPricesUpdatedNotification object:nil];
    [self.tableView reloadData];
}

- (void)applyVoiceModeChange:(UISegmentedControl *)sender {
    [VoiceGuidanceService sharedService].voiceMode = (VoiceGuidanceMode)sender.selectedSegmentIndex;
}

- (void)applyCurrencyChange:(UISegmentedControl *)sender {
    [self.view endEditing:YES];
    NSArray *curs = [[FuelPriceService sharedService] availableCurrencies];
    if (sender.selectedSegmentIndex < curs.count) {
        [FuelPriceService sharedService].currencySymbol = curs[sender.selectedSegmentIndex];
    }
    [self.tableView reloadData];
}

- (void)applyLanguageChange:(UISegmentedControl *)sender {
    NSString *pref = @"auto";
    if (sender.selectedSegmentIndex == 1) {
        pref = @"en";
    } else if (sender.selectedSegmentIndex == 2) {
        pref = @"it";
    } else if (sender.selectedSegmentIndex == 3) {
        pref = @"ru";
    } else if (sender.selectedSegmentIndex == 4) {
        pref = @"uk";
    }

    [[LocalizationManager sharedManager] setSelectedLanguagePreference:pref];
    self.voiceModeSegment = nil;
    self.voiceSwitch = nil;
    self.fuelTypeSegment = nil;
    self.languageSegment = nil;
    [self updateNavigationTitles];
    [self.tableView reloadData];
}

- (void)handleNetworkGPSSwitchChanged:(UISwitch *)sender {
    [NetworkGPSReceiver sharedReceiver].isEnabled = sender.isOn;
}

- (void)handleVoiceSwitchChanged:(UISwitch *)sender {
    [VoiceGuidanceService sharedService].isMuted = !sender.isOn;
}

- (void)copyCydiaRepoURL:(NSString *)urlString {
    [UIPasteboard generalPasteboard].string = urlString;
    NSString *msg = [NSString stringWithFormat:@"%@\n\n%@",
                     urlString,
                     NLString(@"COPIED_CYDIA_MSG", @"Repository URL copied to clipboard. Open Cydia > Sources > Edit > Add.")];
    UIAlertController *alert = [UIAlertController alertControllerWithTitle:NLString(@"COPIED_TITLE", @"Copied!")
                                                                   message:msg
                                                            preferredStyle:UIAlertControllerStyleAlert];
    [alert addAction:[UIAlertAction actionWithTitle:@"OK" style:UIAlertActionStyleDefault handler:nil]];
    [self presentViewController:alert animated:YES completion:nil];
}

#pragma mark - UITableViewDataSource

- (NSInteger)numberOfSectionsInTableView:(UITableView *)tableView {
    return 9; // 0: Versione, 1: Lingua, 2: Carburante, 3: GPS, 4: Traffico & Velox, 5: Cydia, 6: Voce, 7: Offline Maps, 8: Chiudi
}

- (NSInteger)tableView:(UITableView *)tableView numberOfRowsInSection:(NSInteger)section {
    switch (section) {
        case 0: return 3; // Versione App, Data Build, Architettura
        case 1: return 1; // Lingua Interfaccia
        case 2: return 5; // Carburante: Tipo, Valuta, Consumo, Prezzo, Mostra Distributori
        case 3: return 5; // Ricevitore GPS di Rete (Abilita, Porta, IP Server, Diagnostica, Ultima Posizione)
        case 4: return 3; // Traffico & Autovelox: Attiva Traffico, Chiave TomTom, Avvisi Velox
        case 5: return 3; // Cydia: Original (iOS 9+), iOS 6 Revival, Instructions
        case 6: return 2; // Voce: Attiva Voce, Modalità
        case 7: return 2; // Offline Maps: Download area, Clear cache
        case 8: return 1; // Pulsante Salva ed Esci
        default: return 0;
    }
}

- (NSString *)tableView:(UITableView *)tableView titleForHeaderInSection:(NSInteger)section {
    switch (section) {
        case 0: return NLString(@"SEC_VERSION", @"ℹ️ SOFTWARE & SYSTEM VERSION");
        case 1: return NLString(@"SEC_LANGUAGE", @"🌐 APPLICATION LANGUAGE");
        case 2: return NLString(@"SEC_FUEL", @"⛽ FUEL & TRIP COSTS");
        case 3: return NLString(@"SEC_GPS", @"📡 NETWORK GPS (FROM ANDROID)");
        case 4: return NLString(@"SEC_TRAFFIC_VELOX", @"LIVE TRAFFIC & 📷 SPEED CAMERAS");
        case 5: return NLString(@"SEC_CYDIA", @"📲 CYDIA OTA UPDATES");
        case 6: return NLString(@"SEC_VOICE", @"🔊 VOICE GUIDANCE");
        case 7: return NLString(@"SEC_OFFLINE_MAPS", @"💾 OFFLINE MAPS & STORAGE");
        case 8: return nil;
        default: return @"";
    }
}

- (NSString *)tableView:(UITableView *)tableView titleForFooterInSection:(NSInteger)section {
    if (section == 4) {
        // Footer note explaining TomTom API key requirement
        return NLString(@"TRAFFIC_FOOTER", @"Traffic layer requires a free TomTom API key (developer.tomtom.com). Without a key, traffic is not displayed.");
    }
    return nil;
}

- (UITableViewCell *)tableView:(UITableView *)tableView cellForRowAtIndexPath:(NSIndexPath *)indexPath {
    NSString *cellId = [NSString stringWithFormat:@"Cell_%ld_%ld", (long)indexPath.section, (long)indexPath.row];
    UITableViewCell *cell = [tableView dequeueReusableCellWithIdentifier:cellId];
    if (!cell) {
        cell = [[UITableViewCell alloc] initWithStyle:UITableViewCellStyleValue1 reuseIdentifier:cellId];
        cell.backgroundColor = [UIColor colorWithWhite:0.18 alpha:1.0];
        cell.textLabel.backgroundColor = [UIColor clearColor];
        cell.textLabel.textColor = [UIColor whiteColor];
        cell.textLabel.font = [UIFont systemFontOfSize:15.0];
        cell.detailTextLabel.backgroundColor = [UIColor clearColor];
        cell.detailTextLabel.textColor = [UIColor colorWithWhite:0.75 alpha:1.0];
        cell.detailTextLabel.font = [UIFont systemFontOfSize:14.0];
        cell.selectionStyle = UITableViewCellSelectionStyleNone;
    }

    NetworkGPSReceiver *gps = [NetworkGPSReceiver sharedReceiver];

    // SEZIONE 0: Versione Software
    if (indexPath.section == 0) {
        NSDictionary *info = [[NSBundle mainBundle] infoDictionary];
        NSString *versionStr = info[@"CFBundleShortVersionString"] ?: @"1.3.17.1";
        NSString *buildStr = info[@"CFBundleVersion"] ?: @"1.3.17.1";

        if (indexPath.row == 0) {
            cell.textLabel.text = NLString(@"APP_VERSION", @"Versione Applicazione");
            cell.detailTextLabel.text = [NSString stringWithFormat:@"v%@ (Build %@)", versionStr, buildStr];
            cell.detailTextLabel.textColor = [UIColor colorWithRed:0.2 green:0.7 blue:1.0 alpha:1.0];
        } else if (indexPath.row == 1) {
            cell.textLabel.text = NLString(@"BUILD_DATE", @"Data di Compilazione");
            cell.detailTextLabel.text = [NSString stringWithFormat:@"%s %s", __DATE__, __TIME__];
        } else if (indexPath.row == 2) {
            cell.textLabel.text = NLString(@"PLATFORM", @"Platform");
            UIDevice *dev = [UIDevice currentDevice];
            cell.detailTextLabel.text = [NSString stringWithFormat:@"armv7 • %@ • iOS %@", dev.model, dev.systemVersion];
        }
    }
    // SEZIONE 1: Lingua Interfaccia
    else if (indexPath.section == 1) {
        cell.textLabel.text = nil;
        if (!self.languageSegment) {
            self.languageSegment = [[UISegmentedControl alloc] initWithItems:@[
                NLString(@"LANG_AUTO", @"Auto"),
                @"EN",
                @"IT",
                @"RU",
                @"UK"
            ]];
            for (int i = 0; i < 5; i++) {
                [self.languageSegment setWidth:58.0 forSegmentAtIndex:i];
            }
            NSString *pref = [[LocalizationManager sharedManager] selectedLanguagePreference];
            if ([pref isEqualToString:@"en"]) {
                self.languageSegment.selectedSegmentIndex = 1;
            } else if ([pref isEqualToString:@"it"]) {
                self.languageSegment.selectedSegmentIndex = 2;
            } else if ([pref isEqualToString:@"ru"]) {
                self.languageSegment.selectedSegmentIndex = 3;
            } else if ([pref isEqualToString:@"uk"]) {
                self.languageSegment.selectedSegmentIndex = 4;
            } else {
                self.languageSegment.selectedSegmentIndex = 0;
            }
            [self.languageSegment addTarget:self action:@selector(applyLanguageChange:) forControlEvents:UIControlEventValueChanged];
            self.languageSegment.tintColor = [UIColor colorWithRed:0.2 green:0.6 blue:1.0 alpha:1.0];
        }
        cell.accessoryView = self.languageSegment;
    }
    // SEZIONE 2: Carburante & Costi di Viaggio
    else if (indexPath.section == 2) {
        FuelPriceService *fuel = [FuelPriceService sharedService];
        FuelType curType = fuel.selectedFuelType;

        if (indexPath.row == 0) {
            cell.textLabel.text = nil;
            if (!self.fuelTypeSegment) {
                self.fuelTypeSegment = [[UISegmentedControl alloc] initWithItems:@[
                    NLString(@"FUEL_PETROL_SHORT", @"⛽ 95"),
                    NLString(@"FUEL_DIESEL_SHORT", @"⛽ Diesel"),
                    @"GPL",
                    @"⚡ EV",
                    @"CNG"
                ]];
                for (int i = 0; i < 5; i++) {
                    [self.fuelTypeSegment setWidth:58.0 forSegmentAtIndex:i];
                }
                [self.fuelTypeSegment addTarget:self action:@selector(applyFuelTypeChange:) forControlEvents:UIControlEventValueChanged];
                self.fuelTypeSegment.tintColor = [UIColor colorWithRed:0.2 green:0.6 blue:1.0 alpha:1.0];
            }
            self.fuelTypeSegment.selectedSegmentIndex = curType;
            cell.accessoryView = self.fuelTypeSegment;
        } else if (indexPath.row == 1) {
            cell.textLabel.text = NLString(@"CURRENCY_LABEL", @"Currency");
            if (!self.currencySegment) {
                NSArray *curs = [fuel availableCurrencies];
                self.currencySegment = [[UISegmentedControl alloc] initWithItems:curs];
                for (NSUInteger i = 0; i < curs.count; i++) {
                    [self.currencySegment setWidth:58.0 forSegmentAtIndex:i];
                }
                [self.currencySegment addTarget:self action:@selector(applyCurrencyChange:) forControlEvents:UIControlEventValueChanged];
                self.currencySegment.tintColor = [UIColor colorWithRed:0.2 green:0.6 blue:1.0 alpha:1.0];
            }
            NSArray *curs = [fuel availableCurrencies];
            NSUInteger curIdx = [curs indexOfObject:fuel.currencySymbol];
            self.currencySegment.selectedSegmentIndex = (curIdx != NSNotFound) ? curIdx : 0;
            cell.accessoryView = self.currencySegment;
        } else if (indexPath.row == 2) {
            NSString *unit = [fuel consumptionUnitForFuelType:curType];
            cell.textLabel.text = [NSString stringWithFormat:@"%@ (%@)", NLString(@"FUEL_CONSUMPTION", @"Consumo Medio"), unit];
            if (!self.consumptionTextField) {
                self.consumptionTextField = [[UITextField alloc] initWithFrame:CGRectMake(0, 0, 95, 32)];
                self.consumptionTextField.textColor = [UIColor whiteColor];
                self.consumptionTextField.backgroundColor = [UIColor colorWithWhite:0.25 alpha:1.0];
                self.consumptionTextField.keyboardType = UIKeyboardTypeDecimalPad;
                self.consumptionTextField.textAlignment = NSTextAlignmentCenter;
                self.consumptionTextField.layer.cornerRadius = 6.0;
                self.consumptionTextField.delegate = self;
            }
            double val = [fuel effectiveConsumptionForFuelType:curType];
            self.consumptionTextField.text = [NSString stringWithFormat:@"%.1f", val];
            cell.accessoryView = self.consumptionTextField;
        } else if (indexPath.row == 3) {
            NSString *cur = fuel.currencySymbol ?: @"€";
            NSString *unit = [NSString stringWithFormat:@"%@/%@", cur, [fuel unitForFuelType:curType]];
            cell.textLabel.text = [NSString stringWithFormat:@"%@ (%@)", NLString(@"FUEL_PRICE", @"Prezzo Carburante"), unit];
            if (!self.priceTextField) {
                self.priceTextField = [[UITextField alloc] initWithFrame:CGRectMake(0, 0, 95, 32)];
                self.priceTextField.textColor = [UIColor whiteColor];
                self.priceTextField.backgroundColor = [UIColor colorWithWhite:0.25 alpha:1.0];
                self.priceTextField.keyboardType = UIKeyboardTypeDecimalPad;
                self.priceTextField.textAlignment = NSTextAlignmentCenter;
                self.priceTextField.layer.cornerRadius = 6.0;
                self.priceTextField.delegate = self;
            }
            double p = [fuel effectivePriceForFuelType:curType];
            self.priceTextField.text = [NSString stringWithFormat:@"%.3f", p];
            cell.accessoryView = self.priceTextField;
        } else if (indexPath.row == 4) {
            cell.textLabel.text = NLString(@"SHOW_FUEL_ON_MAP", @"Mostra Distributori su Mappa");
            if (!self.showFuelStationsSwitch) {
                self.showFuelStationsSwitch = [[UISwitch alloc] init];
                BOOL isShown = YES;
                if ([[NSUserDefaults standardUserDefaults] objectForKey:@"ShowFuelStationsOnMap"]) {
                    isShown = [[NSUserDefaults standardUserDefaults] boolForKey:@"ShowFuelStationsOnMap"];
                }
                self.showFuelStationsSwitch.on = isShown;
                self.showFuelStationsSwitch.onTintColor = [UIColor colorWithRed:0.15 green:0.75 blue:0.35 alpha:1.0];
            }
            cell.accessoryView = self.showFuelStationsSwitch;
        }
    }
    // SEZIONE 3: GPS Rete (Ricezione simultanea duale UDP Broadcast + TCP Client)
    else if (indexPath.section == 3) {
        if (indexPath.row == 0) {
            cell.textLabel.text = NLString(@"NETWORK_GPS_SWITCH", @"Network GPS (Android)");
            if (!self.networkGPSSwitch) {
                self.networkGPSSwitch = [[UISwitch alloc] init];
                self.networkGPSSwitch.on = [NetworkGPSReceiver sharedReceiver].isEnabled;
                self.networkGPSSwitch.onTintColor = [UIColor colorWithRed:0.15 green:0.75 blue:0.35 alpha:1.0];
                [self.networkGPSSwitch addTarget:self action:@selector(handleNetworkGPSSwitchChanged:) forControlEvents:UIControlEventValueChanged];
            }
            cell.accessoryView = self.networkGPSSwitch;
        } else if (indexPath.row == 1) {
            cell.textLabel.text = NLString(@"PORT", @"Porta Ricezione (Default 8888)");
            if (!self.portTextField) {
                self.portTextField = [[UITextField alloc] initWithFrame:CGRectMake(0, 0, 90, 32)];
                self.portTextField.text = [NSString stringWithFormat:@"%ld", (long)gps.port];
                self.portTextField.textColor = [UIColor whiteColor];
                self.portTextField.backgroundColor = [UIColor colorWithWhite:0.25 alpha:1.0];
                self.portTextField.keyboardType = UIKeyboardTypeNumberPad;
                self.portTextField.textAlignment = NSTextAlignmentCenter;
                self.portTextField.layer.cornerRadius = 6.0;
            }
            cell.accessoryView = self.portTextField;
        } else if (indexPath.row == 2) {
            cell.textLabel.text = NLString(@"SERVER_IP", @"IP Server Android (Hotspot / TCP)");
            if (!self.ipTextField) {
                self.ipTextField = [[UITextField alloc] initWithFrame:CGRectMake(0, 0, 130, 32)];
                NSString *gw = [NetworkGPSReceiver defaultGatewayIP];
                self.ipTextField.text = (gps.tcpHost.length > 0) ? gps.tcpHost : (gw ?: @"192.168.43.1");
                self.ipTextField.placeholder = gw ?: @"192.168.43.1";
                self.ipTextField.textColor = [UIColor whiteColor];
                self.ipTextField.backgroundColor = [UIColor colorWithWhite:0.25 alpha:1.0];
                self.ipTextField.textAlignment = NSTextAlignmentCenter;
                self.ipTextField.layer.cornerRadius = 6.0;
            }
            cell.accessoryView = self.ipTextField;
        } else if (indexPath.row == 3) {
            // Box Diagnostica Live
            cell.textLabel.text = NLString(@"DIAGNOSTICS", @"Diagnostica Ricezione");
            NSString *ipLocal = [gps localIPAddress];
            NSString *status;
            if (gps.isRunning) {
                status = gps.isDualMode ? NLString(@"CONNECTED_DUAL", @"Duale UDP+TCP") : (gps.isTCPClientMode ? NLString(@"CONNECTED_TCP", @"Connesso TCP") : NLString(@"LISTENING_UDP", @"In ascolto UDP"));
            } else {
                status = NLString(@"STOPPED", @"Fermo");
            }
            NSString *diag = [NSString stringWithFormat:@"IP iPad: %@ • %@ • Pkt: %lu", ipLocal, status, (unsigned long)gps.packetsReceivedCount];
            cell.detailTextLabel.text = diag;
            cell.detailTextLabel.textColor = gps.packetsReceivedCount > 0
                ? [UIColor colorWithRed:0.3 green:0.85 blue:0.4 alpha:1.0]
                : [UIColor colorWithRed:1.0 green:0.7 blue:0.2 alpha:1.0];
            self.diagStatusLabel = cell.detailTextLabel;
        } else if (indexPath.row == 4) {
            cell.textLabel.text = NLString(@"LAST_LOCATION", @"Ultima Posizione Ricevuta");
            if (gps.lastLocation) {
                cell.detailTextLabel.text = [NSString stringWithFormat:@"%.4f, %.4f (±%.0fm)",
                                             gps.lastLocation.coordinate.latitude,
                                             gps.lastLocation.coordinate.longitude,
                                             gps.lastLocation.horizontalAccuracy];
                cell.detailTextLabel.textColor = [UIColor colorWithRed:0.3 green:0.85 blue:0.4 alpha:1.0];
            } else {
                cell.detailTextLabel.text = NLString(@"NO_PACKETS", @"Nessun pacchetto ricevuto");
                cell.detailTextLabel.textColor = [UIColor colorWithWhite:0.6 alpha:1.0];
            }
            self.diagLocationLabel = cell.detailTextLabel;
        }
    }
    // SEZIONE 4: Traffico Live & Autovelox
    else if (indexPath.section == 4) {
        if (indexPath.row == 0) {
            cell.textLabel.text = NLString(@"TRAFFIC_ENABLED", @"Traffico in Tempo Reale");
            if (!self.trafficSwitch) {
                self.trafficSwitch = [[UISwitch alloc] init];
                self.trafficSwitch.on = [TrafficTileOverlay sharedOverlay].isEnabled;
                self.trafficSwitch.onTintColor = [UIColor colorWithRed:0.15 green:0.75 blue:0.35 alpha:1.0];
                [self.trafficSwitch addTarget:self action:@selector(handleTrafficSwitchChanged:) forControlEvents:UIControlEventValueChanged];
            }
            cell.accessoryView = self.trafficSwitch;
        } else if (indexPath.row == 1) {
            cell.textLabel.text = NLString(@"TOMTOM_KEY", @"Chiave API TomTom");
            if (!self.trafficApiKeyTextField) {
                self.trafficApiKeyTextField = [[UITextField alloc] initWithFrame:CGRectMake(0, 0, 150, 32)];
                self.trafficApiKeyTextField.textColor = [UIColor whiteColor];
                self.trafficApiKeyTextField.backgroundColor = [UIColor colorWithWhite:0.25 alpha:1.0];
                self.trafficApiKeyTextField.textAlignment = NSTextAlignmentCenter;
                self.trafficApiKeyTextField.layer.cornerRadius = 6.0;
                self.trafficApiKeyTextField.placeholder = NLString(@"ENTER_API_KEY", @"TomTom API Key");
                self.trafficApiKeyTextField.autocorrectionType = UITextAutocorrectionTypeNo;
                self.trafficApiKeyTextField.autocapitalizationType = UITextAutocapitalizationTypeNone;
                self.trafficApiKeyTextField.delegate = self;
            }
            self.trafficApiKeyTextField.text = [TrafficTileOverlay sharedOverlay].apiKey;
            cell.accessoryView = self.trafficApiKeyTextField;
        } else if (indexPath.row == 2) {
            cell.textLabel.text = NLString(@"SPEED_CAMERA_ALERTS", @"Avvisi Visivi & Vocali Autovelox");
            if (!self.speedCameraAlertSwitch) {
                self.speedCameraAlertSwitch = [[UISwitch alloc] init];
                BOOL isEnabled = YES;
                if ([[NSUserDefaults standardUserDefaults] objectForKey:@"SpeedCameraAlertsEnabled"]) {
                    isEnabled = [[NSUserDefaults standardUserDefaults] boolForKey:@"SpeedCameraAlertsEnabled"];
                }
                self.speedCameraAlertSwitch.on = isEnabled;
                self.speedCameraAlertSwitch.onTintColor = [UIColor colorWithRed:0.15 green:0.75 blue:0.35 alpha:1.0];
            }
            cell.accessoryView = self.speedCameraAlertSwitch;
        }
    }
    // SEZIONE 5: Cydia Repo OTA
    else if (indexPath.section == 5) {
        if (indexPath.row == 0) {
            cell.textLabel.text = NLString(@"CYDIA_SOURCE_ORIGINAL", @"Original (iOS 9+, Nicola)");
            cell.detailTextLabel.text = @"https://vibe-maribit.github.io/NavigatorOSM/";
            cell.detailTextLabel.textColor = [UIColor colorWithRed:0.3 green:0.7 blue:1.0 alpha:1.0];
            cell.selectionStyle = UITableViewCellSelectionStyleGray;
            cell.accessoryType = UITableViewCellAccessoryDisclosureIndicator;
        } else if (indexPath.row == 1) {
            cell.textLabel.text = NLString(@"CYDIA_SOURCE_IOS6", @"iOS 6 Revival Repo");
            cell.detailTextLabel.text = @"https://noname122021.github.io/cydia-repo/";
            cell.detailTextLabel.textColor = [UIColor colorWithRed:0.3 green:0.7 blue:1.0 alpha:1.0];
            cell.selectionStyle = UITableViewCellSelectionStyleGray;
            cell.accessoryType = UITableViewCellAccessoryDisclosureIndicator;
        } else {
            cell.textLabel.text = NLString(@"OTA_INSTRUCTIONS", @"OTA Instructions:");
            cell.detailTextLabel.text = NLString(@"OTA_STEPS", @"Open Cydia > Sources > Edit > Add");
            cell.detailTextLabel.textColor = [UIColor colorWithWhite:0.7 alpha:1.0];
            cell.selectionStyle = UITableViewCellSelectionStyleNone;
            cell.accessoryType = UITableViewCellAccessoryNone;
        }
    }
    // SEZIONE 6: Guida Vocale
    else if (indexPath.section == 6) {
        if (indexPath.row == 0) {
            cell.textLabel.text = NLString(@"VOICE_SWITCH", @"Enable Voice Guidance");
            if (!self.voiceSwitch) {
                self.voiceSwitch = [[UISwitch alloc] init];
                self.voiceSwitch.on = ![VoiceGuidanceService sharedService].isMuted;
                self.voiceSwitch.onTintColor = [UIColor colorWithRed:0.15 green:0.75 blue:0.35 alpha:1.0];
                [self.voiceSwitch addTarget:self action:@selector(handleVoiceSwitchChanged:) forControlEvents:UIControlEventValueChanged];
            }
            cell.accessoryView = self.voiceSwitch;
        } else if (indexPath.row == 1) {
            cell.textLabel.text = nil;
            if (!self.voiceModeSegment) {
                self.voiceModeSegment = [[UISegmentedControl alloc] initWithItems:@[
                    NLString(@"VOICE_ALL", @"🔊 All"),
                    NLString(@"VOICE_ALERTS", @"⚠️ Alerts")
                ]];
                for (int i = 0; i < 2; i++) {
                    [self.voiceModeSegment setWidth:140.0 forSegmentAtIndex:i];
                }
                NSInteger m = [VoiceGuidanceService sharedService].voiceMode;
                self.voiceModeSegment.selectedSegmentIndex = (m >= 1) ? 1 : 0;
                self.voiceModeSegment.tintColor = [UIColor colorWithRed:0.2 green:0.6 blue:1.0 alpha:1.0];
                [self.voiceModeSegment addTarget:self action:@selector(applyVoiceModeChange:) forControlEvents:UIControlEventValueChanged];
            }
            cell.accessoryView = self.voiceModeSegment;
        }
    }
    // SEZIONE 7: Mappe Offline e Cache
    else if (indexPath.section == 7) {
        cell.selectionStyle = UITableViewCellSelectionStyleGray;
        if (indexPath.row == 0) {
            cell.textLabel.text = NLString(@"OFFLINE_DL_AREA", @"📥 Download Visible Area");
            cell.detailTextLabel.text = NLString(@"OFFLINE_DL_HINT", @"Zoom 13–16");
        } else if (indexPath.row == 1) {
            cell.textLabel.text = NLString(@"OFFLINE_CLEAR_CACHE", @"Clear Map Cache");
            double mb = self.cachedDiskCacheMB;
            cell.detailTextLabel.text = [NSString stringWithFormat:@"%.1f MB", mb];
        }
    }
    // SEZIONE 8: Pulsante Salva ed Esci (footer)
    else if (indexPath.section == 8) {
        cell.textLabel.text = NLString(@"SAVE_EXIT", @"💾 Salva ed Esci");
        cell.textLabel.textColor = [UIColor colorWithRed:0.2 green:0.7 blue:1.0 alpha:1.0];
        cell.textLabel.font = [UIFont boldSystemFontOfSize:17.0];
        cell.textLabel.textAlignment = NSTextAlignmentCenter;
        cell.backgroundColor = [UIColor colorWithWhite:0.15 alpha:1.0];
        cell.selectionStyle = UITableViewCellSelectionStyleGray;
    }

    return cell;
}

- (void)tableView:(UITableView *)tableView didSelectRowAtIndexPath:(NSIndexPath *)indexPath {
    [tableView deselectRowAtIndexPath:indexPath animated:YES];
    if (indexPath.section == 2 && indexPath.row == 5) {
        if ([TollGuruService sharedService].isQuotaExceeded) {
            UIAlertController *resetAlert = [UIAlertController alertControllerWithTitle:NLString(@"TOLLGURU_RESET_TITLE", @"Quota TollGuru")
                                                                                message:NLString(@"TOLLGURU_RESET_MSG", @"La quota giornaliera (~15 calcoli) è risultata esaurita oggi. Vuoi azzerare il blocco per ritentare?")
                                                                         preferredStyle:UIAlertControllerStyleAlert];
            [resetAlert addAction:[UIAlertAction actionWithTitle:NLString(@"RESET", @"Azzera Blocco") style:UIAlertActionStyleDefault handler:^(UIAlertAction *action) {
                [[TollGuruService sharedService] resetQuotaStatus];
                [self.tableView reloadData];
            }]];
            [resetAlert addAction:[UIAlertAction actionWithTitle:NLString(@"CANCEL", @"Annulla") style:UIAlertActionStyleCancel handler:nil]];
            [self presentViewController:resetAlert animated:YES completion:nil];
        }
    }
    if (indexPath.section == 5) {
        if (indexPath.row == 0) {
            [self copyCydiaRepoURL:@"https://vibe-maribit.github.io/NavigatorOSM/"];
        } else if (indexPath.row == 1) {
            [self copyCydiaRepoURL:@"https://noname122021.github.io/cydia-repo/"];
        }
    }
    if (indexPath.section == 7 && indexPath.row == 0) {
        [self handleDownloadArea];
    }
    if (indexPath.section == 7 && indexPath.row == 1) {
        [self handleClearCache];
    }
    if (indexPath.section == 8 && indexPath.row == 0) {
        [self handleClose];
    }
}

- (void)handleDownloadArea {
    if (!self.tileOverlay) return;

    UIAlertController *alert = [UIAlertController alertControllerWithTitle:NLString(@"OFFLINE_DL_TITLE", @"Download Offline Map")
                                                                   message:NLString(@"OFFLINE_DL_MSG", @"Downloading map tiles to cache...")
                                                            preferredStyle:UIAlertControllerStyleAlert];
    alert.showsProgressBar = YES;

    __weak SettingsViewController *weakSelf = self;
    [alert addAction:[UIAlertAction actionWithTitle:NLString(@"STOP", @"Stop") style:UIAlertActionStyleCancel handler:^(UIAlertAction *action) {
        [weakSelf.tileOverlay cancelDownloadVisibleRegion];
    }]];
    [self presentViewController:alert animated:YES completion:nil];

    [self.tileOverlay downloadVisibleRegion:self.currentMapRegion minZoom:13 maxZoom:16 progress:^(NSUInteger completed, NSUInteger total, double mb) {
        if (!weakSelf || weakSelf.tileOverlay.isDownloadCancelled) return;
        float pct = (total > 0) ? ((float)completed / (float)total) : 0.0f;
        [alert setProgress:pct];

        alert.message = [NSString stringWithFormat:@"%@: %lu / %lu (%.1f MB)",
                         NLString(@"DOWNLOADING", @"Downloading"),
                         (unsigned long)completed, (unsigned long)total, mb];
    } completion:^(NSUInteger downloaded, double totalMB, BOOL cancelled) {
        if (cancelled) return;
        [alert dismissViewControllerAnimated:YES completion:^{
            NSString *msg = [NSString stringWithFormat:@"%@: %lu %@ (%.1f MB).",
                             NLString(@"OFFLINE_DL_DONE", @"Done! Saved"),
                             (unsigned long)downloaded,
                             NLString(@"TILES", @"tiles"),
                             totalMB];
            UIAlertController *doneAlert = [UIAlertController alertControllerWithTitle:NLString(@"SUCCESS", @"Success")
                                                                               message:msg
                                                                        preferredStyle:UIAlertControllerStyleAlert];
            [doneAlert addAction:[UIAlertAction actionWithTitle:@"OK" style:UIAlertActionStyleDefault handler:nil]];
            [weakSelf presentViewController:doneAlert animated:YES completion:nil];
            [weakSelf updateDiskCacheSizeInBackground];
        }];
    }];
}

- (void)handleClearCache {
    UIAlertController *confirm = [UIAlertController alertControllerWithTitle:NLString(@"CONFIRM_CLEAR_TITLE", @"Clear Cache?")
                                                                     message:NLString(@"CONFIRM_CLEAR_MSG", @"All downloaded map tiles will be deleted from device memory.")
                                                              preferredStyle:UIAlertControllerStyleAlert];
    __weak SettingsViewController *weakSelf = self;
    [confirm addAction:[UIAlertAction actionWithTitle:NLString(@"DELETE", @"Delete") style:UIAlertActionStyleDestructive handler:^(UIAlertAction *action) {
        [weakSelf.tileOverlay clearDiskCache];
        [weakSelf updateDiskCacheSizeInBackground];
    }]];
    [confirm addAction:[UIAlertAction actionWithTitle:NLString(@"CANCEL", @"Cancel") style:UIAlertActionStyleCancel handler:nil]];
    [self presentViewController:confirm animated:YES completion:nil];
}

- (void)handleTrafficSwitchChanged:(UISwitch *)sender {
    if (sender.isOn) {
        NSString *key = self.trafficApiKeyTextField.text ?: [TrafficTileOverlay sharedOverlay].apiKey;
        if (key.length < 6) {
            sender.on = NO;
            // Alert user that TomTom API key is required to show traffic flow
            UIAlertController *alert = [UIAlertController alertControllerWithTitle:NLString(@"TRAFFIC_KEY_TITLE", @"TomTom Key Required")
                                                                           message:NLString(@"TRAFFIC_KEY_MSG", @"To display live traffic flow, enter a free TomTom API key in the field below (obtainable at developer.tomtom.com).")
                                                                    preferredStyle:UIAlertControllerStyleAlert];
            [alert addAction:[UIAlertAction actionWithTitle:@"OK" style:UIAlertActionStyleDefault handler:nil]];
            [self presentViewController:alert animated:YES completion:nil];
        }
    }
}

@end

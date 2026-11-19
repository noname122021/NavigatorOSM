#import "RoutingService.h"
#import "LocalizationManager.h"
#import "FuelPriceService.h"
#import "TollGuruService.h"

@implementation ManeuverStep
@end

@implementation RouteInfo

- (void)updateTripCosts {
    FuelPriceService *fuel = [FuelPriceService sharedService];
    self.fuelCost = [fuel fuelCostForDistance:self.totalDistance];
    if (!self.isTollCostExact) {
        self.tollCost = [fuel estimatedTollCostForDistance:self.totalDistance hasTolls:self.hasToll];
    }
    self.totalTripCost = self.fuelCost + self.tollCost;
}

- (NSString *)formattedCostSummary {
    return [[FuelPriceService sharedService] formattedCostSummaryForFuelCost:self.fuelCost tollCost:self.tollCost];
}

@end


@interface RoutingService ()
@property (nonatomic, strong) NSURLSession *session;
@end

@implementation RoutingService

+ (instancetype)sharedService {
    static RoutingService *instance = nil;
    static dispatch_once_t onceToken;
    dispatch_once(&onceToken, ^{
        instance = [[RoutingService alloc] init];
    });
    return instance;
}

- (instancetype)init {
    self = [super init];
    if (self) {
        NSURLSessionConfiguration *config = [NSURLSessionConfiguration defaultSessionConfiguration];
        config.timeoutIntervalForRequest = 15.0;
        config.HTTPAdditionalHeaders = @{
            @"User-Agent": @"NavigatoreOSM/1.0 (iPad Mini 1; iOS 9.3.5)"
        };
        _session = [NSURLSession sessionWithConfiguration:config];
    }
    return self;
}

static int DeduceSpeedLimitForStep(NSString *ref, NSString *streetName, CLLocationDistance distance, NSTimeInterval duration) {
    NSString *combined = [NSString stringWithFormat:@"%@ %@", ref ?: @"", streetName ?: @""];
    NSString *upper = [combined uppercaseString];

    // 1. Autostrade (A1, A4, A14, AUTOSTRADA, AUTOSTRADALE, DIR) -> 130 km/h
    if ([upper containsString:@"AUTOSTRADA"] || [upper containsString:@"AUTOSTRADALE"]) return 130;
    NSRegularExpression *motorwayRegex = [NSRegularExpression regularExpressionWithPattern:@"\\bA[0-9]{1,3}\\b" options:0 error:nil];
    if ([motorwayRegex numberOfMatchesInString:upper options:0 range:NSMakeRange(0, upper.length)] > 0) {
        return 130;
    }

    // 2. Raccordi Autostradali, Tangenziali, Superstrade -> 110 km/h
    if ([upper containsString:@"TANGENZIALE"] || [upper containsString:@"SUPERSTRADA"] || [upper containsString:@"RACCORDO"]) {
        return 110;
    }
    NSRegularExpression *raRegex = [NSRegularExpression regularExpressionWithPattern:@"\\bRA[0-9]{1,2}\\b" options:0 error:nil];
    if ([raRegex numberOfMatchesInString:upper options:0 range:NSMakeRange(0, upper.length)] > 0) {
        return 110;
    }

    // 3. Strade Statali, Regionali, Provinciali -> 90 km/h
    NSRegularExpression *extraurbanRegex = [NSRegularExpression regularExpressionWithPattern:@"\\b(SS|SR|SP|NSA)\\s*[0-9]+" options:0 error:nil];
    if ([extraurbanRegex numberOfMatchesInString:upper options:0 range:NSMakeRange(0, upper.length)] > 0) {
        return 90;
    }
    if ([upper containsString:@"STATALE"] || [upper containsString:@"PROVINCIALE"] || [upper containsString:@"REGIONALE"] ||
        [upper containsString:@"EXTRAURBANA"]) {
        return 90;
    }

    // 4. Se il tratto è sufficientemente lungo (> 350m), usiamo la velocità teorica stimata
    // (evitando che le penalità di svolta/semafori su tratti brevi falsino il limite)
    if (duration > 2.0 && distance > 350.0) {
        double modeledSpeedKmh = (distance / duration) * 3.6;
        if (modeledSpeedKmh >= 95.0) {
            return 130;
        } else if (modeledSpeedKmh >= 75.0) {
            return 110;
        } else if (modeledSpeedKmh >= 55.0) {
            return 90;
        } else if (modeledSpeedKmh >= 40.0) {
            return 70;
        }
    }

    // Default per viabilità ordinaria/urbana
    return 50;
}

static NSString *FormatManeuverLocalized(NSString *type, NSString *modifier, NSString *name) {
    NSString *lang = [[LocalizationManager sharedManager] currentLanguage];
    NSString *base = @"";
    NSString *ontoFormat = @"%@ onto %@";

    if ([lang isEqualToString:@"ru"]) {
        ontoFormat = @"%@ на %@";
        if ([type isEqualToString:@"depart"]) {
            base = @"Направляйтесь";
        } else if ([type isEqualToString:@"arrive"]) {
            return @"Вы прибыли в пункт назначения";
        } else if ([type isEqualToString:@"turn"]) {
            if ([modifier isEqualToString:@"left"]) base = @"Поверните налево";
            else if ([modifier isEqualToString:@"right"]) base = @"Поверните направо";
            else if ([modifier isEqualToString:@"sharp left"]) base = @"Крутой поворот налево";
            else if ([modifier isEqualToString:@"sharp right"]) base = @"Крутой поворот направо";
            else if ([modifier isEqualToString:@"slight left"]) base = @"Держитесь левее";
            else if ([modifier isEqualToString:@"slight right"]) base = @"Держитесь правее";
            else if ([modifier isEqualToString:@"uturn"]) return @"Развернитесь";
            else base = @"Поверните";
        } else if ([type isEqualToString:@"roundabout"]) {
            base = @"На круговом движении съезд";
        } else if ([type isEqualToString:@"fork"]) {
            if ([modifier isEqualToString:@"left"]) return @"На развилке держитесь левее";
            else return @"На развилке держитесь правее";
        } else if ([type isEqualToString:@"on ramp"] || [type isEqualToString:@"off ramp"]) {
            base = @"Съезжайте на развязку";
        } else {
            base = @"Продолжайте движение";
        }
    } else if ([lang isEqualToString:@"uk"]) {
        ontoFormat = @"%@ на %@";
        if ([type isEqualToString:@"depart"]) {
            base = @"Рухайтесь";
        } else if ([type isEqualToString:@"arrive"]) {
            return @"Ви прибули в пункт призначення";
        } else if ([type isEqualToString:@"turn"]) {
            if ([modifier isEqualToString:@"left"]) base = @"Поверніть ліворуч";
            else if ([modifier isEqualToString:@"right"]) base = @"Поверніть праворуч";
            else if ([modifier isEqualToString:@"sharp left"]) base = @"Різкий поворот ліворуч";
            else if ([modifier isEqualToString:@"sharp right"]) base = @"Різкий поворот праворуч";
            else if ([modifier isEqualToString:@"slight left"]) base = @"Тримайтесь лівіше";
            else if ([modifier isEqualToString:@"slight right"]) base = @"Тримайтесь правіше";
            else if ([modifier isEqualToString:@"uturn"]) return @"Розверніться";
            else base = @"Поверніть";
        } else if ([type isEqualToString:@"roundabout"]) {
            base = @"На кільці з'їзд";
        } else if ([type isEqualToString:@"fork"]) {
            if ([modifier isEqualToString:@"left"]) return @"На розгалуженні тримайтесь лівіше";
            else return @"На розгалуженні тримайтесь правіше";
        } else if ([type isEqualToString:@"on ramp"] || [type isEqualToString:@"off ramp"]) {
            base = @"З'їжджайте на розв'язку";
        } else {
            base = @"Продовжуйте рух";
        }
    } else if ([lang isEqualToString:@"it"]) {
        ontoFormat = @"%@ su %@";
        if ([type isEqualToString:@"depart"]) {
            base = @"Parti verso";
        } else if ([type isEqualToString:@"arrive"]) {
            return @"Destinazione raggiunta";
        } else if ([type isEqualToString:@"turn"]) {
            if ([modifier isEqualToString:@"left"]) base = @"Gira a sinistra";
            else if ([modifier isEqualToString:@"right"]) base = @"Gira a destra";
            else if ([modifier isEqualToString:@"sharp left"]) base = @"Svolta stretta a sinistra";
            else if ([modifier isEqualToString:@"sharp right"]) base = @"Svolta stretta a destra";
            else if ([modifier isEqualToString:@"slight left"]) base = @"Tieni la sinistra";
            else if ([modifier isEqualToString:@"slight right"]) base = @"Tieni la destra";
            else if ([modifier isEqualToString:@"uturn"]) return @"Fai inversione a U";
            else base = @"Svolta";
        } else if ([type isEqualToString:@"roundabout"]) {
            base = @"Alla rotonda prendi l'uscita";
        } else if ([type isEqualToString:@"fork"]) {
            if ([modifier isEqualToString:@"left"]) return @"Al bivio tieni la sinistra";
            else return @"Al bivio tieni la destra";
        } else if ([type isEqualToString:@"on ramp"] || [type isEqualToString:@"off ramp"]) {
            base = @"Prendi l'uscita";
        } else {
            base = @"Continua";
        }
    } else {
        ontoFormat = @"%@ onto %@";
        if ([type isEqualToString:@"depart"]) {
            base = @"Head towards";
        } else if ([type isEqualToString:@"arrive"]) {
            return @"Destination reached";
        } else if ([type isEqualToString:@"turn"]) {
            if ([modifier isEqualToString:@"left"]) base = @"Turn left";
            else if ([modifier isEqualToString:@"right"]) base = @"Turn right";
            else if ([modifier isEqualToString:@"sharp left"]) base = @"Sharp left";
            else if ([modifier isEqualToString:@"sharp right"]) base = @"Sharp right";
            else if ([modifier isEqualToString:@"slight left"]) base = @"Keep left";
            else if ([modifier isEqualToString:@"slight right"]) base = @"Keep right";
            else if ([modifier isEqualToString:@"uturn"]) return @"Make a U-turn";
            else base = @"Turn";
        } else if ([type isEqualToString:@"roundabout"]) {
            base = @"At the roundabout take the exit";
        } else if ([type isEqualToString:@"fork"]) {
            if ([modifier isEqualToString:@"left"]) return @"Keep left at the fork";
            else return @"Keep right at the fork";
        } else if ([type isEqualToString:@"on ramp"] || [type isEqualToString:@"off ramp"]) {
            base = @"Take the exit";
        } else {
            base = @"Continue";
        }
    }

    if (name && name.length > 0) {
        return [NSString stringWithFormat:ontoFormat, base, name];
    }
    return base;
}

static NSString *EvaluateTrafficDescription(NSDictionary *leg) {
    NSString *smooth = NLString(@"TRAFFIC_SMOOTH", @"✅ Smooth Flow");
    NSString *slow = NLString(@"TRAFFIC_SLOW", @"⚠️ Slowdowns");
    NSString *heavy = NLString(@"TRAFFIC_HEAVY", @"⛔ Heavy Traffic");

    NSDictionary *annotation = leg[@"annotation"];
    if (!annotation) return smooth;

    NSArray *speeds = annotation[@"speed"];
    if (![speeds isKindOfClass:[NSArray class]] || speeds.count == 0) {
        return smooth;
    }

    NSUInteger slowCount = 0;
    NSUInteger total = speeds.count;
    for (NSNumber *spd in speeds) {
        double val = [spd doubleValue];
        // Sotto i 15 km/h (circa 4.2 m/s) è considerato traffico lento/coda
        if (val < 4.2) {
            slowCount++;
        }
    }

    double slowRatio = (double)slowCount / (double)total;
    if (slowRatio > 0.30) {
        return heavy;
    } else if (slowRatio > 0.12) {
        return slow;
    } else {
        return smooth;
    }
}

- (NSArray *)parseRoutesData:(NSData *)data
                               destination:(CLLocationCoordinate2D)destination
                                     title:(NSString *)title
                                     error:(NSError **)outError {
    NSError *jsonError = nil;
    NSDictionary *json = [NSJSONSerialization JSONObjectWithData:data options:0 error:&jsonError];
    if (jsonError) {
        if (outError) *outError = jsonError;
        return nil;
    }

    NSString *code = json[@"code"];
    if (![code isEqualToString:@"Ok"]) {
        NSString *desc = [NSString stringWithFormat:@"OSRM code: %@", code ?: @"Sconosciuto"];
        if (outError) *outError = [NSError errorWithDomain:@"RoutingService" code:-2 userInfo:@{NSLocalizedDescriptionKey: desc}];
        return nil;
    }

    NSArray *rawRoutes = json[@"routes"];
    if (rawRoutes.count == 0) {
        if (outError) *outError = [NSError errorWithDomain:@"RoutingService" code:-3 userInfo:@{NSLocalizedDescriptionKey: @"Nessun percorso disponibile"}];
        return nil;
    }

    NSMutableArray *results = [NSMutableArray array];

    for (NSUInteger rIdx = 0; rIdx < rawRoutes.count; rIdx++) {
        NSDictionary *rDict = rawRoutes[rIdx];
        CLLocationDistance totalDistance = [rDict[@"distance"] doubleValue];
        NSTimeInterval totalDuration = [rDict[@"duration"] doubleValue];

        // Filtro Deduplicazione: evita di mostrare due itinerari identici
        BOOL isDuplicate = NO;
        for (RouteInfo *existing in results) {
            if (fabs(existing.totalDistance - totalDistance) < 60.0 &&
                fabs(existing.totalDuration - totalDuration) < 25.0) {
                isDuplicate = YES;
                break;
            }
        }
        if (isDuplicate) {
            NSLog(@"[RoutingService] Scartato itinerario duplicato (distanza: %.0fm, tempo: %.0fs)", totalDistance, totalDuration);
            continue;
        }

        // 1. Geometria GeoJSON [lon, lat]
        NSDictionary *geometry = rDict[@"geometry"];
        NSArray *coordinates = geometry[@"coordinates"];
        NSUInteger count = coordinates.count;
        if (count == 0) continue;

        CLLocationCoordinate2D *coords = malloc(sizeof(CLLocationCoordinate2D) * count);
        for (NSUInteger i = 0; i < count; i++) {
            NSArray *pt = coordinates[i];
            coords[i] = CLLocationCoordinate2DMake([pt[1] doubleValue], [pt[0] doubleValue]);
        }

        MKPolyline *polyline = [MKPolyline polylineWithCoordinates:coords count:count];
        free(coords);

        // 2. Passaggi di manovra e calcolo strade principali
        NSMutableArray *steps = [NSMutableArray array];
        NSMutableDictionary *roadDistances = [NSMutableDictionary dictionary];
        NSString *trafficStatus = NLString(@"TRAFFIC_SMOOTH", @"✅ Smooth Flow");

        NSArray *legs = rDict[@"legs"];
        if (legs.count > 0) {
            NSDictionary *firstLeg = legs[0];
            trafficStatus = EvaluateTrafficDescription(firstLeg);

            NSArray *rawSteps = firstLeg[@"steps"];
            for (NSDictionary *raw in rawSteps) {
                ManeuverStep *step = [[ManeuverStep alloc] init];
                step.distance = [raw[@"distance"] doubleValue];
                step.duration = [raw[@"duration"] doubleValue];
                step.streetName = raw[@"name"] ?: @"";
                step.ref = raw[@"ref"] ?: @"";
                if (step.streetName.length == 0 && step.ref.length > 0) {
                    step.streetName = step.ref;
                }
                step.speedLimit = DeduceSpeedLimitForStep(step.ref, step.streetName, step.distance, step.duration);

                if (step.streetName.length > 2) {
                    double currentDist = [roadDistances[step.streetName] doubleValue];
                    roadDistances[step.streetName] = @(currentDist + step.distance);
                }

                NSDictionary *maneuver = raw[@"maneuver"];
                step.type = maneuver[@"type"] ?: @"";
                step.modifier = maneuver[@"modifier"] ?: @"";
                NSArray *loc = maneuver[@"location"];
                if (loc.count >= 2) {
                    step.coordinate = CLLocationCoordinate2DMake([loc[1] doubleValue], [loc[0] doubleValue]);
                }
                step.instruction = FormatManeuverLocalized(step.type, step.modifier, step.streetName);
                [steps addObject:step];
            }
        }

        // Trova le 2 strade con percorrenza maggiore per il riassunto reale
        NSArray *sortedRoads = [roadDistances keysSortedByValueUsingComparator:^NSComparisonResult(NSNumber *obj1, NSNumber *obj2) {
            return [obj2 compare:obj1];
        }];

        NSString *summaryStr = nil;
        if (sortedRoads.count >= 2) {
            summaryStr = [NSString stringWithFormat:@"%@ / %@", sortedRoads[0], sortedRoads[1]];
        } else if (sortedRoads.count == 1) {
            summaryStr = sortedRoads[0];
        } else {
            summaryStr = (results.count == 0) ? NLString(@"BADGE_OPTIMAL", @"Оптимальный") : [NSString stringWithFormat:@"%@ %lu", NLString(@"BADGE_ALTERNATIVE", @"Альтернатива"), (unsigned long)results.count];
        }

        RouteInfo *info = [[RouteInfo alloc] init];
        info.polyline = polyline;
        info.steps = steps;
        info.totalDistance = totalDistance;
        info.totalDuration = totalDuration;
        info.destinationCoordinate = destination;
        info.destinationTitle = title ?: @"Destinazione";
        info.routeSummary = summaryStr;
        info.trafficDescription = trafficStatus;
        info.routeIndex = results.count;
        info.isPrimary = (results.count == 0);

        BOOL hasHwy = NO;
        BOOL hasToll = NO;
        for (ManeuverStep *st in steps) {
            NSString *lower = [[NSString stringWithFormat:@"%@ %@", st.ref ?: @"", st.streetName ?: @""] lowercaseString];
            if ([lower containsString:@"autostrada"] || [lower containsString:@"tangenziale"] ||
                [lower containsString:@"pedaggio"] || [lower containsString:@"toll"] ||
                [lower containsString:@"a1"] || [lower containsString:@"a4"] || [lower containsString:@"a8"] ||
                [lower containsString:@"a7"] || [lower containsString:@"a9"] || [lower containsString:@"a14"] ||
                [lower containsString:@"a22"] || [lower containsString:@"a35"] || st.speedLimit == 130) {
                hasHwy = YES;
                hasToll = YES;
            }
        }
        info.hasHighway = hasHwy;
        info.hasToll = hasToll;
        [info updateTripCosts];

        [results addObject:info];
    }

    [self reindexAndClassifyRoutes:results];
    return results;
}

- (void)appendUniqueRoute:(RouteInfo *)newRoute toRoutes:(NSMutableArray *)routes {
    if (!newRoute || !newRoute.polyline) return;
    if (routes.count == 0) {
        [routes addObject:newRoute];
        return;
    }
    RouteInfo *primary = routes[0];
    // Scarta se deviazione eccessiva (> 1.7x tempo del percorso primario)
    if (newRoute.totalDuration > primary.totalDuration * 1.75) {
        return;
    }
    for (RouteInfo *existing in routes) {
        if (fabs(existing.totalDistance - newRoute.totalDistance) < 250.0 &&
            fabs(existing.totalDuration - newRoute.totalDuration) < 120.0) {
            return; // Duplicato
        }
    }
    [routes addObject:newRoute];
}

- (void)reindexAndClassifyRoutes:(NSMutableArray *)results
                      avoidTolls:(BOOL)avoidTolls
                   avoidHighways:(BOOL)avoidHighways {
    if (results.count == 0) return;

    // Ordina per rispetto delle preferenze utente, poi per durata crescente
    [results sortUsingComparator:^NSComparisonResult(RouteInfo *r1, RouteInfo *r2) {
        if (avoidTolls) {
            if (!r1.hasToll && r2.hasToll) return NSOrderedAscending;
            if (r1.hasToll && !r2.hasToll) return NSOrderedDescending;
        }
        if (avoidHighways) {
            if (!r1.hasHighway && r2.hasHighway) return NSOrderedAscending;
            if (r1.hasHighway && !r2.hasHighway) return NSOrderedDescending;
        }
        if (r1.totalDuration < r2.totalDuration) return NSOrderedAscending;
        if (r1.totalDuration > r2.totalDuration) return NSOrderedDescending;
        return NSOrderedSame;
    }];

    NSTimeInterval minDuration = DBL_MAX;
    CLLocationDistance minDistance = DBL_MAX;
    for (RouteInfo *r in results) {
        if (r.totalDuration < minDuration) minDuration = r.totalDuration;
        if (r.totalDistance < minDistance) minDistance = r.totalDistance;
    }

    RouteInfo *primary = results[0];
    for (NSUInteger i = 0; i < results.count; i++) {
        RouteInfo *r = results[i];
        r.routeIndex = i;
        r.isPrimary = (i == 0);

        // Assegna badge strategico
        if (avoidTolls && !r.hasToll) {
            r.badgeTitle = NLString(@"BADGE_NO_TOLLS", @"🌿 No Pedaggio");
        } else if (avoidHighways && !r.hasHighway) {
            r.badgeTitle = NLString(@"BADGE_NO_HIGHWAYS", @"🍃 No Autostrada");
        } else if (fabs(r.totalDuration - minDuration) < 15.0 && fabs(r.totalDistance - minDistance) < 100.0) {
            r.badgeTitle = NLString(@"BADGE_OPTIMAL", @"⭐ Ottimale");
        } else if (fabs(r.totalDuration - minDuration) < 15.0) {
            r.badgeTitle = NLString(@"BADGE_FASTEST", @"🚀 Più Veloce");
        } else if (fabs(r.totalDistance - minDistance) < 100.0) {
            r.badgeTitle = NLString(@"BADGE_SHORTEST", @"🍃 Più Breve");
        } else {
            r.badgeTitle = (i == 1) ? NLString(@"BADGE_ALTERNATIVE", @"⚖️ Alternativa") : NLString(@"BADGE_SCENIC", @"🍃 Panoramica");
        }

        // Assegna delta
        if (i == 0) {
            r.deltaDescription = NLString(@"RECOMMENDED", @"Consigliato");
        } else {
            int deltaMins = (int)round((r.totalDuration - primary.totalDuration) / 60.0);
            double deltaKm = (r.totalDistance - primary.totalDistance) / 1000.0;

            NSString *sameTimeStr = NLString(@"SAME_TIME", @"То же время");
            NSString *sameDistStr = NLString(@"SAME_DISTANCE", @"Та же дист.");

            NSString *timeDelta = (deltaMins == 0) ? sameTimeStr : (deltaMins > 0 ? [NSString stringWithFormat:@"+%d min", deltaMins] : [NSString stringWithFormat:@"%d min", deltaMins]);
            NSString *distDelta = (fabs(deltaKm) < 0.1) ? sameDistStr : (deltaKm > 0 ? [NSString stringWithFormat:@"+%.1f km", deltaKm] : [NSString stringWithFormat:@"%.1f km", deltaKm]);

            r.deltaDescription = [NSString stringWithFormat:@"%@ • %@", timeDelta, distDelta];
        }
    }
}

- (void)reindexAndClassifyRoutes:(NSMutableArray *)results {
    [self reindexAndClassifyRoutes:results avoidTolls:NO avoidHighways:NO];
}

- (void)enrichWithAlternativeCorridors:(NSMutableArray *)routes
                                 start:(CLLocationCoordinate2D)start
                           destination:(CLLocationCoordinate2D)destination
                                 title:(NSString *)title
                           offsetRatio:(double)offsetRatio
                            completion:(void (^)(NSArray *finalRoutes))done {
    // Non inventiamo waypoint perpendicolari arbitrari in mezzo ai campi/boschi
    // che costringevano il motore a deviazioni illogiche.
    // Usiamo unicamente le alternative reali fornite dal grafo stradale OSRM/Valhalla.
    [self reindexAndClassifyRoutes:routes];
    if (done) done(routes);
}

static NSArray *DecodePolyline6(NSString *encoded) {
    if (!encoded || encoded.length == 0) return @[];
    NSMutableArray *coordsArray = [NSMutableArray array];
    const char *bytes = [encoded UTF8String];
    NSUInteger len = strlen(bytes);
    NSUInteger idx = 0;
    int lat = 0;
    int lng = 0;
    double precision = 1e6;

    while (idx < len) {
        int result = 0;
        int shift = 0;
        while (idx < len) {
            int b = bytes[idx++] - 63;
            result |= (b & 0x1f) << shift;
            shift += 5;
            if (b < 0x20) break;
        }
        int dlat = ((result & 1) ? ~(result >> 1) : (result >> 1));
        lat += dlat;

        result = 0;
        shift = 0;
        while (idx < len) {
            int b = bytes[idx++] - 63;
            result |= (b & 0x1f) << shift;
            shift += 5;
            if (b < 0x20) break;
        }
        int dlng = ((result & 1) ? ~(result >> 1) : (result >> 1));
        lng += dlng;

        CLLocationCoordinate2D coord = CLLocationCoordinate2DMake((double)lat / precision, (double)lng / precision);
        [coordsArray addObject:[NSValue valueWithBytes:&coord objCType:@encode(CLLocationCoordinate2D)]];
    }
    return coordsArray;
}

static MKPolyline *PolylineFromCoords(NSArray *coordsArray) {
    NSUInteger count = coordsArray.count;
    if (count == 0) return nil;
    CLLocationCoordinate2D *coords = malloc(sizeof(CLLocationCoordinate2D) * count);
    for (NSUInteger i = 0; i < count; i++) {
        [coordsArray[i] getValue:&coords[i]];
    }
    MKPolyline *polyline = [MKPolyline polylineWithCoordinates:coords count:count];
    free(coords);
    return polyline;
}

- (RouteInfo *)routeFromValhallaTrip:(NSDictionary *)trip
                          destination:(CLLocationCoordinate2D)destination
                                title:(NSString *)title {
    if (![trip isKindOfClass:[NSDictionary class]]) return nil;

    NSDictionary *summary = trip[@"summary"];
    NSArray *legs = trip[@"legs"];
    if (![legs isKindOfClass:[NSArray class]] || legs.count == 0) return nil;

    NSDictionary *leg = legs[0];
    NSString *shape = leg[@"shape"];
    NSArray *decodedCoords = DecodePolyline6(shape);
    if (decodedCoords.count == 0) return nil;

    MKPolyline *polyline = PolylineFromCoords(decodedCoords);

    double lengthKm = [summary[@"length"] doubleValue];
    double totalDistance = lengthKm * 1000.0;
    double totalDuration = [summary[@"time"] doubleValue];
    BOOL hasToll = [summary[@"has_toll"] boolValue];
    BOOL hasHighway = [summary[@"has_highway"] boolValue];

    NSMutableArray *steps = [NSMutableArray array];
    NSMutableDictionary *roadDistances = [NSMutableDictionary dictionary];

    NSArray *rawManeuvers = leg[@"maneuvers"];
    for (NSDictionary *m in rawManeuvers) {
        ManeuverStep *step = [[ManeuverStep alloc] init];
        step.distance = [m[@"length"] doubleValue] * 1000.0;
        step.duration = [m[@"time"] doubleValue];
        step.instruction = m[@"instruction"] ?: @"";

        NSArray *names = m[@"street_names"];
        if ([names isKindOfClass:[NSArray class]] && names.count > 0) {
            step.streetName = names[0];
        } else {
            step.streetName = @"";
        }
        step.ref = @"";
        step.speedLimit = DeduceSpeedLimitForStep(step.ref, step.streetName, step.distance, step.duration);

        if (step.streetName.length > 2) {
            double cur = [roadDistances[step.streetName] doubleValue];
            roadDistances[step.streetName] = @(cur + step.distance);
        }

        NSInteger shapeIdx = [m[@"begin_shape_index"] integerValue];
        if (shapeIdx >= 0 && shapeIdx < (NSInteger)decodedCoords.count) {
            CLLocationCoordinate2D c;
            [decodedCoords[shapeIdx] getValue:&c];
            step.coordinate = c;
        }

        NSInteger mType = [m[@"type"] integerValue];
        if (mType == 4 || mType == 5 || mType == 6) {
            step.type = @"arrive";
        } else if (mType == 1 || mType == 2 || mType == 3) {
            step.type = @"depart";
        } else if (mType == 26 || mType == 27) {
            step.type = @"roundabout";
        } else if (mType == 14 || mType == 15 || mType == 16) {
            step.type = @"turn";
            step.modifier = @"left";
        } else if (mType == 9 || mType == 10 || mType == 11) {
            step.type = @"turn";
            step.modifier = @"right";
        } else if (mType == 12 || mType == 13) {
            step.type = @"turn";
            step.modifier = @"uturn";
        } else {
            step.type = @"continue";
        }

        [steps addObject:step];
    }

    NSArray *sortedRoads = [roadDistances keysSortedByValueUsingComparator:^NSComparisonResult(NSNumber *o1, NSNumber *o2) {
        return [o2 compare:o1];
    }];

    NSString *summaryStr = nil;
    if (sortedRoads.count >= 2) {
        summaryStr = [NSString stringWithFormat:@"%@ / %@", sortedRoads[0], sortedRoads[1]];
    } else if (sortedRoads.count == 1) {
        summaryStr = sortedRoads[0];
    } else {
        summaryStr = hasToll ? NLString(@"HIGHWAY_ROUTE", @"Автомагистраль") : NLString(@"BADGE_OPTIMAL", @"Оптимальный");
    }

    RouteInfo *info = [[RouteInfo alloc] init];
    info.polyline = polyline;
    info.steps = steps;
    info.totalDistance = totalDistance;
    info.totalDuration = totalDuration;
    info.destinationCoordinate = destination;
    info.destinationTitle = title ?: NLString(@"SELECTED_DESTINATION", @"Точка назначения");
    info.routeSummary = summaryStr;
    info.trafficDescription = NLString(@"TRAFFIC_SMOOTH", @"✅ Smooth Flow");
    info.hasToll = hasToll;
    info.hasHighway = hasHighway;
    [info updateTripCosts];

    return info;
}

- (NSArray *)parseValhallaResponseData:(NSData *)data
                                        destination:(CLLocationCoordinate2D)destination
                                              title:(NSString *)title
                                         avoidTolls:(BOOL)avoidTolls
                                      avoidHighways:(BOOL)avoidHighways
                                              error:(NSError **)outError {
    NSError *jsonError = nil;
    NSDictionary *json = [NSJSONSerialization JSONObjectWithData:data options:0 error:&jsonError];
    if (jsonError || ![json isKindOfClass:[NSDictionary class]]) {
        if (outError) *outError = jsonError ?: [NSError errorWithDomain:@"RoutingService" code:-2 userInfo:@{NSLocalizedDescriptionKey: @"Risposta Valhalla non valida"}];
        return nil;
    }

    NSMutableArray *results = [NSMutableArray array];

    NSDictionary *primaryTrip = json[@"trip"];
    RouteInfo *r0 = [self routeFromValhallaTrip:primaryTrip destination:destination title:title];
    if (r0) {
        [results addObject:r0];
    }

    NSArray *alts = json[@"alternates"];
    if ([alts isKindOfClass:[NSArray class]]) {
        for (NSDictionary *alt in alts) {
            NSDictionary *altTrip = alt[@"trip"];
            RouteInfo *rAlt = [self routeFromValhallaTrip:altTrip destination:destination title:title];
            if (rAlt) {
                [self appendUniqueRoute:rAlt toRoutes:results];
            }
        }
    }

    if (results.count == 0) {
        if (outError) *outError = [NSError errorWithDomain:@"RoutingService" code:-2 userInfo:@{NSLocalizedDescriptionKey: @"Nessun percorso restituito da Valhalla"}];
        return nil;
    }

    [self reindexAndClassifyRoutes:results avoidTolls:avoidTolls avoidHighways:avoidHighways];
    return results;
}

- (void)calculateRoutesFrom:(CLLocationCoordinate2D)start
                         to:(CLLocationCoordinate2D)destination
           destinationTitle:(NSString *)title
                 avoidTolls:(BOOL)avoidTolls
              avoidHighways:(BOOL)avoidHighways
             corridorOffset:(double)offsetRatio
                 completion:(RoutesCompletionBlock)completion {

    NSLog(@"[RoutingService] Calcolo itinerario da (%.4f, %.4f) a (%.4f, %.4f) [Pedaggi: %@, Autostrade: %@]",
          start.latitude, start.longitude, destination.latitude, destination.longitude,
          avoidTolls ? @"NO" : @"SI", avoidHighways ? @"NO" : @"SI");

    __weak RoutingService *weakSelf = self;

    // Se l'utente ha richiesto esplicitamente di evitare pedaggi o autostrade, usiamo il motore avanzato Valhalla
    if (avoidTolls || avoidHighways) {
        NSURL *url = [NSURL URLWithString:@"https://valhalla1.openstreetmap.de/route"];
        NSMutableURLRequest *req = [NSMutableURLRequest requestWithURL:url];
        req.HTTPMethod = @"POST";
        [req setValue:@"application/json" forHTTPHeaderField:@"Content-Type"];

        NSDictionary *body = @{
            @"locations": @[
                @{ @"lat": @(start.latitude), @"lon": @(start.longitude) },
                @{ @"lat": @(destination.latitude), @"lon": @(destination.longitude) }
            ],
            @"costing": @"auto",
            @"costing_options": @{
                @"auto": @{
                    @"use_highways": avoidHighways ? @(0.0) : @(1.0),
                    @"use_tolls": avoidTolls ? @(0.0) : @(1.0),
                    @"toll_booth_penalty": avoidTolls ? @(2000.0) : @(0.0)
                }
            },
            @"alternates": @(3),
            @"directions_options": @{
                @"units": @"kilometers",
                @"language": [[LocalizationManager sharedManager] speechVoiceLanguage] ?: @"en-US"
            }
        };

        NSError *encErr = nil;
        req.HTTPBody = [NSJSONSerialization dataWithJSONObject:body options:0 error:&encErr];

        NSURLSessionDataTask *vTask = [self.session dataTaskWithRequest:req completionHandler:^(NSData *data, NSURLResponse *resp, NSError *err) {
            if (!err && data) {
                NSError *parseErr = nil;
                NSArray *valhallaRoutes = [weakSelf parseValhallaResponseData:data destination:destination title:title avoidTolls:avoidTolls avoidHighways:avoidHighways error:&parseErr];
                if (valhallaRoutes.count > 0) {
                    NSLog(@"[RoutingService] Valhalla ha calcolato %lu itinerari con successo", (unsigned long)valhallaRoutes.count);
                    [weakSelf cacheRoutesForOffline:valhallaRoutes start:start destination:destination title:title];
                    [[TollGuruService sharedService] requestTollForRoutes:valhallaRoutes from:start to:destination];
                    dispatch_async(dispatch_get_main_queue(), ^{
                        if (completion) completion(valhallaRoutes, nil);
                    });
                    return;
                }
                NSLog(@"[RoutingService] Valhalla parse fallito: %@, tento fallback OSRM", parseErr);
            } else {
                NSLog(@"[RoutingService] Valhalla network err: %@, tento fallback OSRM", err);
            }

            // Fallback su OSRM standard in caso di errore Valhalla
            [weakSelf calculateRoutesFrom:start to:destination destinationTitle:title corridorOffset:offsetRatio completion:completion];
        }];
        [vTask resume];
        return;
    }

    // Modalità standard: OSRM primario con corridoi alternativi
    [self calculateRoutesFrom:start to:destination destinationTitle:title corridorOffset:offsetRatio completion:completion];
}

- (void)calculateRoutesFrom:(CLLocationCoordinate2D)start
                         to:(CLLocationCoordinate2D)destination
            destinationTitle:(NSString *)title
                  completion:(RoutesCompletionBlock)completion {
    [self calculateRoutesFrom:start to:destination destinationTitle:title avoidTolls:NO avoidHighways:NO corridorOffset:0.22 completion:completion];
}

- (void)calculateRoutesFrom:(CLLocationCoordinate2D)start
                         to:(CLLocationCoordinate2D)destination
            destinationTitle:(NSString *)title
             corridorOffset:(double)offsetRatio
                  completion:(RoutesCompletionBlock)completion {

    NSString *coordsParam = [NSString stringWithFormat:@"%.6f,%.6f;%.6f,%.6f",
                             start.longitude, start.latitude,
                             destination.longitude, destination.latitude];

    NSString *primaryUrlStr = [NSString stringWithFormat:
                              @"http://router.project-osrm.org/route/v1/driving/%@?overview=full&geometries=geojson&steps=true&alternatives=3&annotations=true",
                              coordsParam];

    NSString *fallbackUrlStr = [NSString stringWithFormat:
                               @"http://routing.openstreetmap.de/routed-car/route/v1/driving/%@?overview=full&geometries=geojson&steps=true&alternatives=3&annotations=true",
                               coordsParam];

    NSLog(@"[RoutingService] Richiesta itinerari OSRM da (%.4f, %.4f) a (%.4f, %.4f) con offset %.2f",
          start.latitude, start.longitude, destination.latitude, destination.longitude, offsetRatio);

    __weak RoutingService *weakSelf = self;
    NSURL *primaryUrl = [NSURL URLWithString:primaryUrlStr];
    NSURLSessionDataTask *task1 = [self.session dataTaskWithURL:primaryUrl completionHandler:^(NSData *data, NSURLResponse *response, NSError *error) {
        if (!error && data) {
            NSError *parseErr = nil;
            NSArray *parsed = [weakSelf parseRoutesData:data destination:destination title:title error:&parseErr];
            if (parsed.count > 0) {
                NSMutableArray *routesMut = [parsed mutableCopy];
                [weakSelf enrichWithAlternativeCorridors:routesMut start:start destination:destination title:title offsetRatio:offsetRatio completion:^(NSArray *finalRoutes) {
                    NSLog(@"[RoutingService] Itinerari finali OSRM calcolati: %lu percorsi", (unsigned long)finalRoutes.count);
                    [weakSelf cacheRoutesForOffline:finalRoutes start:start destination:destination title:title];
                    [[TollGuruService sharedService] requestTollForRoutes:finalRoutes from:start to:destination];
                    dispatch_async(dispatch_get_main_queue(), ^{
                        if (completion) completion(finalRoutes, nil);
                    });
                }];
                return;
            }
            NSLog(@"[RoutingService] Server primario OSRM ha restituito errore di parsing: %@", parseErr);
        } else {
            NSLog(@"[RoutingService] Errore server primario OSRM: %@, tento server secondario...", error.localizedDescription);
        }

        // Tentativo su server secondario (OSM DE router)
        NSURL *fallbackUrl = [NSURL URLWithString:fallbackUrlStr];
        NSURLSessionDataTask *task2 = [weakSelf.session dataTaskWithURL:fallbackUrl completionHandler:^(NSData *data2, NSURLResponse *resp2, NSError *err2) {
            if (!err2 && data2) {
                NSError *parseErr2 = nil;
                NSArray *parsed2 = [weakSelf parseRoutesData:data2 destination:destination title:title error:&parseErr2];
                if (parsed2.count > 0) {
                    NSMutableArray *routesMut2 = [parsed2 mutableCopy];
                    [weakSelf enrichWithAlternativeCorridors:routesMut2 start:start destination:destination title:title offsetRatio:offsetRatio completion:^(NSArray *finalRoutes2) {
                        NSLog(@"[RoutingService] Itinerari finali secondario: %lu percorsi", (unsigned long)finalRoutes2.count);
                        [weakSelf cacheRoutesForOffline:finalRoutes2 start:start destination:destination title:title];
                        [[TollGuruService sharedService] requestTollForRoutes:finalRoutes2 from:start to:destination];
                        dispatch_async(dispatch_get_main_queue(), ^{
                            if (completion) completion(finalRoutes2, nil);
                        });
                    }];
                    return;
                }
                NSLog(@"[RoutingService] Server secondario errore parsing: %@", parseErr2);
            } else {
                NSLog(@"[RoutingService] Errore anche su server secondario: %@", err2.localizedDescription);
            }

            // Fallback Offline: 1. Кэшированные маршруты
            NSArray *offlineRoutes = [weakSelf cachedOfflineRoutesFrom:start to:destination title:title];
            if (offlineRoutes.count > 0) {
                NSLog(@"[RoutingService] Сеть недоступна, возвращен кэшированный оффлайн-маршрут");
                dispatch_async(dispatch_get_main_queue(), ^{
                    if (completion) completion(offlineRoutes, nil);
                });
                return;
            }

            // Fallback Offline: 2. Прямой оффлайн-маршрут
            RouteInfo *direct = [weakSelf offlineDirectRouteFrom:start to:destination title:title];
            if (direct) {
                NSLog(@"[RoutingService] Сеть недоступна, построен прямой оффлайн-маршрут");
                dispatch_async(dispatch_get_main_queue(), ^{
                    if (completion) completion(@[direct], nil);
                });
                return;
            }

            dispatch_async(dispatch_get_main_queue(), ^{
                if (completion) {
                    completion(nil, err2 ?: error ?: [NSError errorWithDomain:@"RoutingService" code:-2 userInfo:@{NSLocalizedDescriptionKey: @"Nessun itinerario trovato"}]);
                }
            });
        }];
        [task2 resume];
    }];
    [task1 resume];
}

- (void)calculateRouteFrom:(CLLocationCoordinate2D)start
                        to:(CLLocationCoordinate2D)destination
               destinationTitle:(NSString *)title
                completion:(RouteCompletionBlock)completion {
    [self calculateRoutesFrom:start to:destination destinationTitle:title completion:^(NSArray *routes, NSError *error) {
        if (error || routes.count == 0) {
            if (completion) completion(nil, error);
        } else {
            if (completion) completion(routes[0], nil);
        }
    }];
}

#pragma mark - Offline Routing Engine & Route Caching

static NSString * const kOfflineRoutesPath = @"/var/mobile/Documents/offline_routes.plist";

- (void)cacheRoutesForOffline:(NSArray *)routes
                        start:(CLLocationCoordinate2D)start
                  destination:(CLLocationCoordinate2D)dest
                        title:(NSString *)title {
    if (routes.count == 0) return;

    dispatch_async(dispatch_get_global_queue(DISPATCH_QUEUE_PRIORITY_LOW, 0), ^{
        NSMutableArray *existing = [NSMutableArray arrayWithContentsOfFile:kOfflineRoutesPath];
        if (!existing) existing = [NSMutableArray array];

        for (RouteInfo *r in routes) {
            if (!r.polyline || r.polyline.pointCount == 0) continue;

            NSUInteger count = r.polyline.pointCount;
            CLLocationCoordinate2D *coords = malloc(sizeof(CLLocationCoordinate2D) * count);
            [r.polyline getCoordinates:coords range:NSMakeRange(0, count)];

            NSMutableArray *coordList = [NSMutableArray arrayWithCapacity:count];
            for (NSUInteger i = 0; i < count; i++) {
                [coordList addObject:@[@(coords[i].latitude), @(coords[i].longitude)]];
            }
            free(coords);

            NSMutableArray *stepList = [NSMutableArray arrayWithCapacity:r.steps.count];
            for (ManeuverStep *step in r.steps) {
                [stepList addObject:@{
                    @"instruction": step.instruction ?: @"",
                    @"streetName": step.streetName ?: @"",
                    @"ref": step.ref ?: @"",
                    @"speedLimit": @(step.speedLimit),
                    @"type": step.type ?: @"",
                    @"modifier": step.modifier ?: @"",
                    @"distance": @(step.distance),
                    @"duration": @(step.duration),
                    @"lat": @(step.coordinate.latitude),
                    @"lon": @(step.coordinate.longitude)
                }];
            }

            NSDictionary *dict = @{
                @"destLat": @(dest.latitude),
                @"destLon": @(dest.longitude),
                @"startLat": @(start.latitude),
                @"startLon": @(start.longitude),
                @"title": title ?: (r.destinationTitle ?: @""),
                @"summary": r.routeSummary ?: @"",
                @"distance": @(r.totalDistance),
                @"duration": @(r.totalDuration),
                @"coords": coordList,
                @"steps": stepList,
                @"timestamp": @([[NSDate date] timeIntervalSince1970])
            };

            for (NSInteger i = (NSInteger)existing.count - 1; i >= 0; i--) {
                NSDictionary *item = existing[i];
                double dLat = [item[@"destLat"] doubleValue] - dest.latitude;
                double dLon = [item[@"destLon"] doubleValue] - dest.longitude;
                if (fabs(dLat) < 0.001 && fabs(dLon) < 0.001) {
                    [existing removeObjectAtIndex:i];
                }
            }

            [existing insertObject:dict atIndex:0];
        }

        while (existing.count > 50) {
            [existing removeLastObject];
        }

        [existing writeToFile:kOfflineRoutesPath atomically:YES];
        NSLog(@"[RoutingService] Salvati %lu itinerari in кэш оффлайн-маршрутов (%@)", (unsigned long)routes.count, kOfflineRoutesPath);
    });
}

- (NSArray *)cachedOfflineRoutesFrom:(CLLocationCoordinate2D)start
                                  to:(CLLocationCoordinate2D)destination
                               title:(NSString *)title {
    if (![[NSFileManager defaultManager] fileExistsAtPath:kOfflineRoutesPath]) return nil;
    NSArray *list = [NSArray arrayWithContentsOfFile:kOfflineRoutesPath];
    if (![list isKindOfClass:[NSArray class]] || list.count == 0) return nil;

    for (NSDictionary *dict in list) {
        if (![dict isKindOfClass:[NSDictionary class]]) continue;
        double dLat = [dict[@"destLat"] doubleValue];
        double dLon = [dict[@"destLon"] doubleValue];
        if (dLat == 0.0 && dLon == 0.0) continue;

        CLLocation *dLoc = [[CLLocation alloc] initWithLatitude:dLat longitude:dLon];
        CLLocation *targetLoc = [[CLLocation alloc] initWithLatitude:destination.latitude longitude:destination.longitude];
        CLLocationDistance dist = [dLoc distanceFromLocation:targetLoc];

        if (dist <= 500.0) {
            NSArray *coordList = dict[@"coords"];
            if (![coordList isKindOfClass:[NSArray class]] || coordList.count < 2) continue;

            NSUInteger count = coordList.count;
            CLLocationCoordinate2D *coords = malloc(sizeof(CLLocationCoordinate2D) * count);
            if (!coords) continue;

            NSUInteger validCount = 0;
            for (NSUInteger i = 0; i < count; i++) {
                id pt = coordList[i];
                double lat = 0.0, lon = 0.0;
                if ([pt isKindOfClass:[NSArray class]] && [(NSArray *)pt count] >= 2) {
                    lat = [pt[0] doubleValue];
                    lon = [pt[1] doubleValue];
                } else if ([pt isKindOfClass:[NSDictionary class]]) {
                    lat = [pt[@"lat"] doubleValue];
                    lon = [pt[@"lon"] doubleValue];
                }
                if (lat != 0.0 || lon != 0.0) {
                    coords[validCount++] = CLLocationCoordinate2DMake(lat, lon);
                }
            }

            if (validCount < 2) {
                free(coords);
                continue;
            }

            MKPolyline *polyline = [MKPolyline polylineWithCoordinates:coords count:validCount];
            free(coords);

            NSMutableArray *steps = [NSMutableArray array];
            NSArray *rawSteps = dict[@"steps"];
            if ([rawSteps isKindOfClass:[NSArray class]]) {
                for (NSDictionary *sDict in rawSteps) {
                    if (![sDict isKindOfClass:[NSDictionary class]]) continue;
                    ManeuverStep *step = [[ManeuverStep alloc] init];
                    step.instruction = sDict[@"instruction"];
                    step.streetName = sDict[@"streetName"];
                    step.ref = sDict[@"ref"];
                    step.speedLimit = [sDict[@"speedLimit"] intValue];
                    step.type = sDict[@"type"];
                    step.modifier = sDict[@"modifier"];
                    step.distance = [sDict[@"distance"] doubleValue];
                    step.duration = [sDict[@"duration"] doubleValue];
                    step.coordinate = CLLocationCoordinate2DMake([sDict[@"lat"] doubleValue], [sDict[@"lon"] doubleValue]);
                    [steps addObject:step];
                }
            }

            RouteInfo *info = [[RouteInfo alloc] init];
            info.polyline = polyline;
            info.steps = steps;
            info.totalDistance = [dict[@"distance"] doubleValue];
            info.totalDuration = [dict[@"duration"] doubleValue];
            info.destinationCoordinate = destination;
            info.destinationTitle = title ?: dict[@"title"];
            info.routeSummary = dict[@"summary"];
            info.badgeTitle = NLString(@"OFFLINE_CACHED_BADGE", @"💾 Оффлайн (кэш)");
            info.trafficDescription = NLString(@"OFFLINE_NO_TRAFFIC", @"💾 Оффлайн режим");
            info.isPrimary = YES;
            [info updateTripCosts];

            NSLog(@"[RoutingService] Trovato percorso offline in cache per '%@' (distanza: %.0fm)", info.destinationTitle, info.totalDistance);
            return @[info];
        }
    }
    return nil;
}

- (RouteInfo *)offlineDirectRouteFrom:(CLLocationCoordinate2D)start
                                   to:(CLLocationCoordinate2D)destination
                                title:(NSString *)title {
    if (!CLLocationCoordinate2DIsValid(start) || !CLLocationCoordinate2DIsValid(destination)) {
        return nil;
    }
    CLLocation *startLoc = [[CLLocation alloc] initWithLatitude:start.latitude longitude:start.longitude];
    CLLocation *destLoc = [[CLLocation alloc] initWithLatitude:destination.latitude longitude:destination.longitude];
    CLLocationDistance directDist = [startLoc distanceFromLocation:destLoc];
    if (directDist < 5.0) {
        directDist = 50.0;
    }

    CLLocationDistance roadDist = directDist * 1.25;
    NSTimeInterval duration = roadDist / 9.7; // ~35 km/h

    CLLocationCoordinate2D midCoord = CLLocationCoordinate2DMake((start.latitude + destination.latitude) / 2.0,
                                                                 (start.longitude + destination.longitude) / 2.0);
    CLLocationCoordinate2D coords[3];
    coords[0] = start;
    coords[1] = midCoord;
    coords[2] = destination;

    MKPolyline *polyline = [MKPolyline polylineWithCoordinates:coords count:3];

    ManeuverStep *step1 = [[ManeuverStep alloc] init];
    step1.type = @"depart";
    step1.modifier = @"straight";
    step1.instruction = NLString(@"OFFLINE_DEPART", @"Направляйтесь к пункту назначения");
    step1.streetName = NLString(@"OFFLINE_ROUTE", @"Маршрут");
    step1.distance = roadDist * 0.5;
    step1.duration = duration * 0.5;
    step1.coordinate = start;
    step1.speedLimit = 50;

    ManeuverStep *step2 = [[ManeuverStep alloc] init];
    step2.type = @"continue";
    step2.modifier = @"straight";
    step2.instruction = [NSString stringWithFormat:NLString(@"OFFLINE_CONTINUE_TO", @"Продолжайте движение к %@"), title ?: @"цели"];
    step2.streetName = title ?: NLString(@"DESTINATION", @"Пункт назначения");
    step2.distance = roadDist * 0.5;
    step2.duration = duration * 0.5;
    step2.coordinate = midCoord;
    step2.speedLimit = 50;

    ManeuverStep *step3 = [[ManeuverStep alloc] init];
    step3.type = @"arrive";
    step3.modifier = @"straight";
    step3.instruction = NLString(@"ARRIVED_AT_DESTINATION", @"Вы прибыли в пункт назначения");
    step3.streetName = title ?: @"";
    step3.distance = 0;
    step3.duration = 0;
    step3.coordinate = destination;
    step3.speedLimit = 50;

    RouteInfo *info = [[RouteInfo alloc] init];
    info.polyline = polyline;
    info.steps = @[step1, step2, step3];
    info.totalDistance = roadDist;
    info.totalDuration = duration;
    info.destinationCoordinate = destination;
    info.destinationTitle = title ?: NLString(@"DESTINATION", @"Пункт назначения");
    info.routeSummary = [NSString stringWithFormat:NLString(@"OFFLINE_DIRECT_SUMMARY", @"Прямой оффлайн-маршрут (%.1f км)"), roadDist / 1000.0];
    info.badgeTitle = NLString(@"OFFLINE_DIRECT_BADGE", @"💾 Оффлайн");
    info.trafficDescription = NLString(@"OFFLINE_NO_TRAFFIC", @"💾 Оффлайн режим");
    info.isPrimary = YES;
    [info updateTripCosts];

    return info;
}

+ (int)deduceSpeedLimitForStep:(ManeuverStep *)step {
    if (!step) return 50;
    if (step.speedLimit > 0) return step.speedLimit;
    return DeduceSpeedLimitForStep(step.ref, step.streetName, step.distance, step.duration);
}

@end

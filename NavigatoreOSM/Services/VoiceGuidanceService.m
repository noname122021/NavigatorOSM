#import "VoiceGuidanceService.h"
#import "LocalizationManager.h"

NSString *const kVoiceGuidanceModeChangedNotification = @"VoiceGuidanceModeChangedNotification";
NSString *const kPrefVoiceGuidanceMode = @"VoiceGuidanceMode";

@interface VoiceGuidanceService () <AVAudioPlayerDelegate>
@property (nonatomic, strong) AVAudioPlayer *audioPlayer;
@property (nonatomic, copy) NSString *lastSpokenPhrase;
@property (nonatomic, strong) NSDate *lastSpokenTime;

// Checkpoint per la manovra attualmente tracciata
@property (nonatomic, assign) NSUInteger trackedStepIndex;
@property (nonatomic, assign) BOOL didSpeak1000m;
@property (nonatomic, assign) BOOL didSpeak500m;
@property (nonatomic, assign) BOOL didSpeak200m;
@property (nonatomic, assign) BOOL didSpeakNow;
@end

@implementation VoiceGuidanceService

+ (instancetype)sharedService {
    static VoiceGuidanceService *instance = nil;
    static dispatch_once_t onceToken;
    dispatch_once(&onceToken, ^{
        instance = [[VoiceGuidanceService alloc] init];
    });
    return instance;
}

- (instancetype)init {
    self = [super init];
    if (self) {
        _trackedStepIndex = NSNotFound;
        
        // Setup audio session for clear navigation voice output
        [[AVAudioSession sharedInstance] setCategory:AVAudioSessionCategoryPlayback error:nil];
        [[AVAudioSession sharedInstance] setActive:YES error:nil];
    }
    return self;
}

- (VoiceGuidanceMode)voiceMode {
    if (![[NSUserDefaults standardUserDefaults] objectForKey:kPrefVoiceGuidanceMode]) {
        return VoiceGuidanceModeAll;
    }
    return (VoiceGuidanceMode)[[NSUserDefaults standardUserDefaults] integerForKey:kPrefVoiceGuidanceMode];
}

- (void)setVoiceMode:(VoiceGuidanceMode)mode {
    [[NSUserDefaults standardUserDefaults] setInteger:mode forKey:kPrefVoiceGuidanceMode];
    [[NSUserDefaults standardUserDefaults] synchronize];
    if (mode == VoiceGuidanceModeMuted) {
        [self stopSpeaking];
    }
    [[NSNotificationCenter defaultCenter] postNotificationName:kVoiceGuidanceModeChangedNotification object:self];
}

- (BOOL)isMuted {
    return (self.voiceMode == VoiceGuidanceModeMuted);
}

- (void)setIsMuted:(BOOL)isMuted {
    self.voiceMode = isMuted ? VoiceGuidanceModeMuted : VoiceGuidanceModeAll;
}

- (void)cycleVoiceMode {
    VoiceGuidanceMode nextMode;
    switch (self.voiceMode) {
        case VoiceGuidanceModeAll:
            nextMode = VoiceGuidanceModeAlertsOnly;
            break;
        case VoiceGuidanceModeAlertsOnly:
            nextMode = VoiceGuidanceModeMuted;
            break;
        case VoiceGuidanceModeMuted:
        default:
            nextMode = VoiceGuidanceModeAll;
            break;
    }
    self.voiceMode = nextMode;
}

- (NSString *)currentModeTitle {
    switch (self.voiceMode) {
        case VoiceGuidanceModeAll:
            return NLString(@"VOICE_ALL", @"🔊 Все");
        case VoiceGuidanceModeAlertsOnly:
            return NLString(@"VOICE_ALERTS", @"⚠️ Опасности");
        case VoiceGuidanceModeMuted:
            return NLString(@"VOICE_MUTED", @"🔇 Выкл");
    }
}

- (NSString *)currentModeIcon {
    switch (self.voiceMode) {
        case VoiceGuidanceModeAll:
            return @"🔊";
        case VoiceGuidanceModeAlertsOnly:
            return @"⚠️";
        case VoiceGuidanceModeMuted:
            return @"🔇";
    }
}

- (void)stopSpeaking {
    if (self.audioPlayer && self.audioPlayer.isPlaying) {
        [self.audioPlayer stop];
        self.audioPlayer = nil;
    }
}

- (void)resetManeuverTracking {
    self.trackedStepIndex = NSNotFound;
    self.didSpeak1000m = NO;
    self.didSpeak500m = NO;
    self.didSpeak200m = NO;
    self.didSpeakNow = NO;
    [self stopSpeaking];
}

- (BOOL)isSpeakingOrPlaying {
    return (self.audioPlayer && self.audioPlayer.isPlaying);
}

- (BOOL)playPromptNamed:(NSString *)name {
    if (self.isMuted || !name || name.length == 0) return NO;

    NSString *lang = [[LocalizationManager sharedManager] currentLanguage] ?: @"en";
    NSString *subPath = [NSString stringWithFormat:@"Audio/%@", lang];
    NSString *filePath = [[NSBundle mainBundle] pathForResource:name ofType:@"caf" inDirectory:subPath];
    if (!filePath) {
        // Fallback to English pre-rendered audio
        filePath = [[NSBundle mainBundle] pathForResource:name ofType:@"caf" inDirectory:@"Audio/en"];
    }
    if (!filePath) {
        return NO;
    }

    [self stopSpeaking];

    NSError *error = nil;
    self.audioPlayer = [[AVAudioPlayer alloc] initWithContentsOfURL:[NSURL fileURLWithPath:filePath] error:&error];
    self.audioPlayer.delegate = self;
    if (error || !self.audioPlayer) {
        NSLog(@"[VoiceGuidanceService] Audio player error: %@", error.localizedDescription);
        return NO;
    }
    [self.audioPlayer prepareToPlay];
    [self.audioPlayer play];
    self.lastSpokenTime = [NSDate date];
    self.lastSpokenPhrase = name;
    return YES;
}

- (void)speakAlert:(NSString *)text {
    if (self.voiceMode == VoiceGuidanceModeMuted || !text || text.length == 0) return;
    [self speak:text];
}

- (void)speak:(NSString *)text {
    if (self.isMuted || !text || text.length == 0) return;

    // Direct prompt name check
    if ([self playPromptNamed:text]) return;

    // Map common localized sentences / keywords to high-quality bundled CAF files
    NSString *lower = [text lowercaseString];
    if ([lower containsString:@"ricalcol"] || [lower containsString:@"перерасчет"] || [lower containsString:@"пересчет"] || [lower containsString:@"перерахун"] || [lower containsString:@"recalculat"]) {
        [self playPromptNamed:@"recalculate"];
    } else if ([lower containsString:@"arrivat"] || [lower containsString:@"прибыл"] || [lower containsString:@"прибув"] || [lower containsString:@"arrived"]) {
        [self playPromptNamed:@"arrive"];
    } else if ([lower containsString:@"partenz"] || [lower containsString:@"начните"] || [lower containsString:@"почніть"] || [lower containsString:@"depart"] || [lower containsString:@"guidare"]) {
        [self playPromptNamed:@"depart"];
    } else if ([lower containsString:@"autovelox"] || [lower containsString:@"камер"] || [lower containsString:@"speed camera"]) {
        [self playPromptNamed:@"speedcam"];
    } else if ([lower containsString:@"velocit"] || [lower containsString:@"скорост"] || [lower containsString:@"швидкост"] || [lower containsString:@"speed limit"]) {
        [self playPromptNamed:@"speedlimit"];
    }
}

static NSString *ManeuverActionKey(NSString *modifier, NSString *type) {
    if ([type isEqualToString:@"arrive"]) return @"arrive";
    if ([type isEqualToString:@"roundabout"] || [type isEqualToString:@"rotary"]) return @"roundabout";
    if ([modifier isEqualToString:@"left"]) return @"turn_left";
    if ([modifier isEqualToString:@"right"]) return @"turn_right";
    if ([modifier isEqualToString:@"sharp left"]) return @"sharp_left";
    if ([modifier isEqualToString:@"sharp right"]) return @"sharp_right";
    if ([modifier isEqualToString:@"slight left"]) return @"slight_left";
    if ([modifier isEqualToString:@"slight right"]) return @"slight_right";
    if ([modifier isEqualToString:@"uturn"]) return @"uturn";
    return @"straight";
}

- (void)repeatCurrentManeuverModifier:(NSString *)modifier
                                 type:(NSString *)type
                             distance:(double)distance {
    if (self.isMuted) return;

    NSString *manKey = ManeuverActionKey(modifier, type);
    if ([manKey isEqualToString:@"arrive"]) {
        [self playPromptNamed:@"arrive"];
        return;
    }

    NSString *prompt = nil;
    if (distance > 700.0) {
        prompt = [NSString stringWithFormat:@"1000m_%@", manKey];
    } else if (distance > 300.0) {
        prompt = [NSString stringWithFormat:@"500m_%@", manKey];
    } else if (distance > 60.0) {
        prompt = [NSString stringWithFormat:@"200m_%@", manKey];
    } else {
        prompt = [NSString stringWithFormat:@"now_%@", manKey];
    }

    if (![self playPromptNamed:prompt]) {
        [self playPromptNamed:[NSString stringWithFormat:@"now_%@", manKey]];
    }
}

- (void)speakManeuverModifier:(NSString *)modifier
                         type:(NSString *)type
             distanceInMeters:(double)distance
                    stepIndex:(NSUInteger)stepIndex
          fallbackInstruction:(NSString *)instruction {
    if (self.voiceMode != VoiceGuidanceModeAll) return;

    if (self.trackedStepIndex != stepIndex) {
        self.trackedStepIndex = stepIndex;
        self.didSpeak1000m = NO;
        self.didSpeak500m = NO;
        self.didSpeak200m = NO;
        self.didSpeakNow = NO;
    }

    NSString *manKey = ManeuverActionKey(modifier, type);
    if ([manKey isEqualToString:@"arrive"]) {
        if (distance <= 60 && !self.didSpeakNow) {
            self.didSpeakNow = YES;
            [self playPromptNamed:@"arrive"];
        }
        return;
    }

    NSString *prompt = nil;
    if (distance > 750 && distance <= 1200) {
        if (!self.didSpeak1000m) {
            self.didSpeak1000m = YES;
            prompt = [NSString stringWithFormat:@"1000m_%@", manKey];
        }
    } else if (distance > 350 && distance <= 600) {
        if (!self.didSpeak500m) {
            self.didSpeak500m = YES;
            prompt = [NSString stringWithFormat:@"500m_%@", manKey];
        }
    } else if (distance > 100 && distance <= 250) {
        if (!self.didSpeak200m) {
            self.didSpeak200m = YES;
            prompt = [NSString stringWithFormat:@"200m_%@", manKey];
        }
    } else if (distance <= 45 && distance > 10) {
        if (!self.didSpeakNow) {
            self.didSpeakNow = YES;
            prompt = [NSString stringWithFormat:@"now_%@", manKey];
        }
    }

    if (prompt) {
        [self playPromptNamed:prompt];
    }
}

- (void)speakManeuver:(NSString *)instruction distanceInMeters:(double)distance stepIndex:(NSUInteger)stepIndex {
    [self speakManeuverModifier:nil type:nil distanceInMeters:distance stepIndex:stepIndex fallbackInstruction:instruction];
}

- (void)speakManeuver:(NSString *)instruction distanceInMeters:(double)distance {
    [self speakManeuver:instruction distanceInMeters:distance stepIndex:0];
}

#pragma mark - AVAudioPlayerDelegate

- (void)audioPlayerDidFinishPlaying:(AVAudioPlayer *)player successfully:(BOOL)flag {
    if (self.audioPlayer == player) {
        self.audioPlayer = nil;
    }
}

@end

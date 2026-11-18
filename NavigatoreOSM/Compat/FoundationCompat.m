//
//  FoundationCompat.m
//  iOS 6 Compatibility helpers for Foundation and UIKit
//

#import "FoundationCompat.h"
#import <objc/runtime.h>

@implementation NSString (iOS6Compat)

- (BOOL)containsString:(NSString *)str {
    if (!str || str.length == 0) return NO;
    return [self rangeOfString:str].location != NSNotFound;
}

- (NSString *)stringByAddingPercentEncodingWithAllowedCharacters:(id)ignored {
    CFStringRef escaped = CFURLCreateStringByAddingPercentEscapes(
        kCFAllocatorDefault,
        (__bridge CFStringRef)self,
        NULL,
        CFSTR("!*'();:@&=+$,/?%#[]"),
        kCFStringEncodingUTF8
    );
    return (__bridge_transfer NSString *)escaped;
}

@end

@implementation NSArray (iOS6Compat)

- (id)firstObject {
    return (self.count > 0) ? self[0] : nil;
}

@end

@implementation NSCharacterSet (iOS6Compat)

+ (id)URLQueryAllowedCharacterSet {
    return nil;
}

@end

@implementation NSCalendar (iOS6Compat)

- (BOOL)isDateInToday:(NSDate *)date {
    if (!date) return NO;
    NSDateComponents *c1 = [self components:NSDayCalendarUnit|NSMonthCalendarUnit|NSYearCalendarUnit fromDate:date];
    NSDateComponents *c2 = [self components:NSDayCalendarUnit|NSMonthCalendarUnit|NSYearCalendarUnit fromDate:[NSDate date]];
    return (c1.year == c2.year && c1.month == c2.month && c1.day == c2.day);
}

@end

@implementation AVSpeechSynthesisVoice
+ (AVSpeechSynthesisVoice *)voiceWithLanguage:(NSString *)language {
    AVSpeechSynthesisVoice *v = [[self alloc] init];
    v.language = language;
    return v;
}
@end

@implementation AVSpeechUtterance
+ (instancetype)speechUtteranceWithString:(NSString *)string {
    AVSpeechUtterance *u = [[self alloc] init];
    u.speechString = string;
    return u;
}
@end

@implementation AVSpeechSynthesizer
- (void)speakUtterance:(AVSpeechUtterance *)utterance {
    AudioServicesPlaySystemSound(1057);
}
- (BOOL)stopSpeakingAtBoundary:(AVSpeechBoundary)boundary {
    return YES;
}
- (BOOL)isSpeaking {
    return NO;
}
@end

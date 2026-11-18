//
//  FoundationCompat.h
//  iOS 6 Compatibility helpers for Foundation and UIKit
//

#import <Foundation/Foundation.h>
#import <UIKit/UIKit.h>
#import <AVFoundation/AVFoundation.h>

#ifndef UIKeyboardAppearanceDark
#define UIKeyboardAppearanceDark UIKeyboardAppearanceAlert
#endif

#ifndef UISearchBarStyleMinimal
#define UISearchBarStyleMinimal 1
#endif

#ifndef NSCalendarUnitDay
#define NSCalendarUnitDay NSDayCalendarUnit
#define NSCalendarUnitMonth NSMonthCalendarUnit
#define NSCalendarUnitYear NSYearCalendarUnit
#endif

@interface NSCalendar (iOS6Compat)
- (BOOL)isDateInToday:(NSDate *)date;
@end

@interface NSString (iOS6Compat)
- (BOOL)containsString:(NSString *)str;
- (NSString *)stringByAddingPercentEncodingWithAllowedCharacters:(id)ignored;
@end

@interface NSArray (iOS6Compat)
- (id)firstObject;
@end

@interface AVAudioSession (RecordPermissionCompat)
- (void)requestRecordPermission:(void (^)(BOOL granted))responseBlock;
@end

@interface NSCharacterSet (iOS6Compat)
+ (id)URLQueryAllowedCharacterSet;
@end

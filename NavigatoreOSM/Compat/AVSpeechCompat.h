//
//  AVSpeechCompat.h
//  iOS 6 Compatibility definitions for AVSpeechSynthesizer
//

#import <Foundation/Foundation.h>

#ifndef __AVSpeechCompat_DEFINED__
#define __AVSpeechCompat_DEFINED__

typedef NS_ENUM(NSInteger, AVSpeechBoundary) {
    AVSpeechBoundaryImmediate,
    AVSpeechBoundaryWord
};

#define AVSpeechUtteranceDefaultSpeechRate 0.5f

@class AVSpeechUtterance;
@class AVSpeechSynthesisVoice;
@class AVSpeechSynthesizer;

@protocol AVSpeechSynthesizerDelegate <NSObject>
@optional
- (void)speechSynthesizer:(AVSpeechSynthesizer *)synthesizer didFinishSpeechUtterance:(AVSpeechUtterance *)utterance;
- (void)speechSynthesizer:(AVSpeechSynthesizer *)synthesizer didCancelSpeechUtterance:(AVSpeechUtterance *)utterance;
@end

@interface AVSpeechSynthesisVoice : NSObject
@property (nonatomic, copy) NSString *language;
+ (AVSpeechSynthesisVoice *)voiceWithLanguage:(NSString *)language;
@end

@interface AVSpeechUtterance : NSObject
@property (nonatomic, copy) NSString *speechString;
@property (nonatomic, retain) AVSpeechSynthesisVoice *voice;
@property (nonatomic) float rate;
@property (nonatomic) float pitchMultiplier;
@property (nonatomic) float volume;
+ (instancetype)speechUtteranceWithString:(NSString *)string;
@end

@interface AVSpeechSynthesizer : NSObject
@property (nonatomic, assign) id<AVSpeechSynthesizerDelegate> delegate;
@property (nonatomic, readonly, getter=isSpeaking) BOOL speaking;
@property (nonatomic, readonly, getter=isPaused) BOOL paused;
- (void)speakUtterance:(AVSpeechUtterance *)utterance;
- (BOOL)stopSpeakingAtBoundary:(AVSpeechBoundary)boundary;
@end

#endif

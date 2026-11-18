//
//  UIAlertControllerCompat.h
//  iOS 6 Compatibility shim for UIAlertController using UIAlertView and UIActionSheet
//

#import <UIKit/UIKit.h>

typedef NS_ENUM(NSInteger, UIAlertActionStyle) {
    UIAlertActionStyleDefault = 0,
    UIAlertActionStyleCancel,
    UIAlertActionStyleDestructive
};

typedef NS_ENUM(NSInteger, UIAlertControllerStyle) {
    UIAlertControllerStyleActionSheet = 0,
    UIAlertControllerStyleAlert
};

@class UIAlertAction;
typedef void (^UIAlertActionHandler)(UIAlertAction *action);

@interface UIAlertAction : NSObject

@property (nonatomic, copy, readonly) NSString *title;
@property (nonatomic, assign, readonly) UIAlertActionStyle style;
@property (nonatomic, copy, readonly) UIAlertActionHandler handler;

+ (instancetype)actionWithTitle:(NSString *)title style:(UIAlertActionStyle)style handler:(UIAlertActionHandler)handler;

@end

@interface UIPopoverPresentationControllerCompat : NSObject
@property (nonatomic, weak) UIView *sourceView;
@property (nonatomic, assign) CGRect sourceRect;
@end

@interface UIAlertController : UIViewController

@property (nonatomic, copy) NSString *message;
@property (nonatomic, assign, readonly) UIAlertControllerStyle preferredStyle;
@property (nonatomic, strong, readonly) NSArray *actions;
@property (nonatomic, strong, readonly) UIPopoverPresentationControllerCompat *popoverPresentationController;
@property (nonatomic, assign) BOOL showsProgressBar;
@property (nonatomic, strong, readonly) UIProgressView *progressView;

- (void)setProgress:(float)progress;

+ (instancetype)alertControllerWithTitle:(NSString *)title
                                 message:(NSString *)message
                          preferredStyle:(UIAlertControllerStyle)preferredStyle;

- (void)addAction:(UIAlertAction *)action;

- (void)showFromViewController:(UIViewController *)viewController animated:(BOOL)animated;

@end

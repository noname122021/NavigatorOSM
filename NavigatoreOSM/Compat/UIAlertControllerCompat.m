//
//  UIAlertControllerCompat.m
//  iOS 6 Compatibility shim for UIAlertController using UIAlertView and UIActionSheet
//

#import "UIAlertControllerCompat.h"
#import <objc/runtime.h>

@interface UIAlertAction ()
@property (nonatomic, copy, readwrite) NSString *title;
@property (nonatomic, assign, readwrite) UIAlertActionStyle style;
@property (nonatomic, copy, readwrite) UIAlertActionHandler handler;
@end

@implementation UIAlertAction

+ (instancetype)actionWithTitle:(NSString *)title style:(UIAlertActionStyle)style handler:(UIAlertActionHandler)handler {
    UIAlertAction *action = [[UIAlertAction alloc] init];
    action.title = title;
    action.style = style;
    action.handler = handler;
    return action;
}

@end

@implementation UIPopoverPresentationControllerCompat
@end

@interface UIAlertController () <UIAlertViewDelegate, UIActionSheetDelegate>
@property (nonatomic, assign, readwrite) UIAlertControllerStyle preferredStyle;
@property (nonatomic, strong, readwrite) NSMutableArray *internalActions;
@property (nonatomic, strong, readwrite) UIPopoverPresentationControllerCompat *popoverPresentationController;
@property (nonatomic, strong) UIAlertView *alertView;
@property (nonatomic, strong) UIActionSheet *actionSheet;
@property (nonatomic, strong, readwrite) UIProgressView *progressView;
@end

@implementation UIAlertController
@synthesize message = _message;

- (void)setMessage:(NSString *)message {
    _message = [message copy];
    if (self.alertView) {
        NSString *displayMsg = self.showsProgressBar ? [NSString stringWithFormat:@"%@\n\n", _message ?: @""] : _message;
        self.alertView.message = displayMsg;
    }
}

- (void)setTitle:(NSString *)title {
    [super setTitle:title];
    if (self.alertView) {
        self.alertView.title = title;
    }
}

- (void)setProgress:(float)progress {
    if (self.progressView) {
        [self.progressView setProgress:progress animated:YES];
        if (self.alertView.bounds.size.height > 100) {
            CGFloat y = self.alertView.bounds.size.height - 72;
            self.progressView.frame = CGRectMake(20, y, self.alertView.bounds.size.width - 40, 9);
        }
    }
}

+ (instancetype)alertControllerWithTitle:(NSString *)title
                                 message:(NSString *)message
                          preferredStyle:(UIAlertControllerStyle)preferredStyle {
    UIAlertController *ctrl = [[UIAlertController alloc] init];
    ctrl.title = title;
    ctrl.message = message;
    ctrl.preferredStyle = preferredStyle;
    ctrl.internalActions = [[NSMutableArray alloc] init];
    ctrl.popoverPresentationController = [[UIPopoverPresentationControllerCompat alloc] init];
    return ctrl;
}

- (NSArray *)actions {
    return [self.internalActions copy];
}

- (void)addAction:(UIAlertAction *)action {
    if (action) {
        [self.internalActions addObject:action];
    }
}

- (void)dismissViewControllerAnimated:(BOOL)flag completion:(void (^)(void))completion {
    if (self.progressView) {
        [self.progressView removeFromSuperview];
        self.progressView = nil;
    }
    if (self.alertView) {
        [self.alertView dismissWithClickedButtonIndex:-1 animated:flag];
        objc_setAssociatedObject(self.alertView, "kAlertControllerOwner", nil, OBJC_ASSOCIATION_RETAIN_NONATOMIC);
        self.alertView = nil;
    }
    if (self.actionSheet) {
        [self.actionSheet dismissWithClickedButtonIndex:-1 animated:flag];
        objc_setAssociatedObject(self.actionSheet, "kAlertControllerOwner", nil, OBJC_ASSOCIATION_RETAIN_NONATOMIC);
        self.actionSheet = nil;
    }
    if (completion) {
        dispatch_async(dispatch_get_main_queue(), completion);
    }
}

- (void)showFromViewController:(UIViewController *)viewController animated:(BOOL)animated {
    if (self.preferredStyle == UIAlertControllerStyleAlert) {
        NSString *cancelTitle = nil;
        NSMutableArray *otherTitles = [NSMutableArray array];

        for (UIAlertAction *act in self.internalActions) {
            if (act.style == UIAlertActionStyleCancel && !cancelTitle) {
                cancelTitle = act.title;
            } else {
                [otherTitles addObject:act.title];
            }
        }

        NSString *displayMsg = self.showsProgressBar ? [NSString stringWithFormat:@"%@\n\n", self.message ?: @""] : self.message;

        self.alertView = [[UIAlertView alloc] initWithTitle:self.title
                                                    message:displayMsg
                                                   delegate:self
                                          cancelButtonTitle:cancelTitle
                                          otherButtonTitles:nil];

        for (NSString *t in otherTitles) {
            [self.alertView addButtonWithTitle:t];
        }

        if (self.showsProgressBar) {
            self.progressView = [[UIProgressView alloc] initWithProgressViewStyle:UIProgressViewStyleDefault];
            self.progressView.frame = CGRectMake(20, 85, 244, 9);
            [self.alertView addSubview:self.progressView];
        }

        // Retain self while alert is visible to prevent premature deallocation and dangling pointer
        objc_setAssociatedObject(self.alertView, "kAlertControllerOwner", self, OBJC_ASSOCIATION_RETAIN_NONATOMIC);
        [self.alertView show];
    } else {
        // Action Sheet
        NSString *cancelTitle = nil;
        NSString *destructiveTitle = nil;
        NSMutableArray *otherTitles = [NSMutableArray array];

        for (UIAlertAction *act in self.internalActions) {
            if (act.style == UIAlertActionStyleCancel && !cancelTitle) {
                cancelTitle = act.title;
            } else if (act.style == UIAlertActionStyleDestructive && !destructiveTitle) {
                destructiveTitle = act.title;
            } else {
                [otherTitles addObject:act.title];
            }
        }

        self.actionSheet = [[UIActionSheet alloc] initWithTitle:self.title
                                                       delegate:self
                                              cancelButtonTitle:cancelTitle
                                         destructiveButtonTitle:destructiveTitle
                                              otherButtonTitles:nil];

        for (NSString *t in otherTitles) {
            [self.actionSheet addButtonWithTitle:t];
        }

        // Retain self while actionSheet is visible
        objc_setAssociatedObject(self.actionSheet, "kAlertControllerOwner", self, OBJC_ASSOCIATION_RETAIN_NONATOMIC);

        if (UI_USER_INTERFACE_IDIOM() == UIUserInterfaceIdiomPad && self.popoverPresentationController.sourceView) {
            UIView *src = self.popoverPresentationController.sourceView;
            CGRect rect = self.popoverPresentationController.sourceRect;
            if (CGRectIsEmpty(rect)) rect = src.bounds;
            [self.actionSheet showFromRect:rect inView:src animated:animated];
        } else {
            [self.actionSheet showInView:viewController.view];
        }
    }
}

#pragma mark - UIAlertViewDelegate

- (void)alertView:(UIAlertView *)alertView clickedButtonAtIndex:(NSInteger)buttonIndex {
    if (self.progressView) {
        [self.progressView removeFromSuperview];
        self.progressView = nil;
    }
    NSString *btnTitle = [alertView buttonTitleAtIndex:buttonIndex];
    for (UIAlertAction *act in self.internalActions) {
        if ([act.title isEqualToString:btnTitle]) {
            if (act.handler) {
                act.handler(act);
            }
            break;
        }
    }
    objc_setAssociatedObject(alertView, "kAlertControllerOwner", nil, OBJC_ASSOCIATION_RETAIN_NONATOMIC);
    self.alertView = nil;
}

#pragma mark - UIActionSheetDelegate

- (void)actionSheet:(UIActionSheet *)actionSheet clickedButtonAtIndex:(NSInteger)buttonIndex {
    NSString *btnTitle = [actionSheet buttonTitleAtIndex:buttonIndex];
    for (UIAlertAction *act in self.internalActions) {
        if ([act.title isEqualToString:btnTitle]) {
            if (act.handler) {
                act.handler(act);
            }
            break;
        }
    }
    objc_setAssociatedObject(actionSheet, "kAlertControllerOwner", nil, OBJC_ASSOCIATION_RETAIN_NONATOMIC);
    self.actionSheet = nil;
}

@end

// Category hook for UIViewController to intercept presentViewController:
@implementation UIViewController (UIAlertControllerCompat)

+ (void)load {
    static dispatch_once_t onceToken;
    dispatch_once(&onceToken, ^{
        Class cls = [UIViewController class];
        Method original = class_getInstanceMethod(cls, @selector(presentViewController:animated:completion:));
        Method swizzled = class_getInstanceMethod(cls, @selector(compat_presentViewController:animated:completion:));
        if (original && swizzled) {
            method_exchangeImplementations(original, swizzled);
        }
    });
}

- (void)compat_presentViewController:(UIViewController *)vc animated:(BOOL)flag completion:(void (^)(void))completion {
    if ([vc isKindOfClass:[UIAlertController class]]) {
        UIAlertController *alert = (UIAlertController *)vc;
        [alert showFromViewController:self animated:flag];
        if (completion) completion();
    } else {
        [self compat_presentViewController:vc animated:flag completion:completion];
    }
}

@end

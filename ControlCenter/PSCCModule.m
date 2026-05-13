#import <Foundation/Foundation.h>
#import <UIKit/UIKit.h>
#import <ControlCenterUIKit/CCUIContentModule.h>
#import "PSCCMenuViewController.h"

@interface PSCCModule : NSObject <CCUIContentModule>
@property (nonatomic, strong) PSCCMenuViewController *menuViewController;
@end

@implementation PSCCModule

- (UIViewController<CCUIContentModuleContentViewController> *)contentViewController {
    if (!self.menuViewController) {
        self.menuViewController = [[PSCCMenuViewController alloc] init];
    }
    [self.menuViewController refreshState];
    return self.menuViewController;
}

- (UIViewController *)backgroundViewController {
    return nil;
}

- (BOOL)providesOwnPlatter {
    return NO;
}

@end

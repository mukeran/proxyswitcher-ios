#import <UIKit/UIKit.h>

@protocol CCUIContentModuleContentViewController;

@interface CCUIToggleModule : NSObject

@property (nonatomic, assign, getter=isSelected) BOOL selected;

- (UIImage *)iconGlyph;
- (UIColor *)selectedColor;
- (void)setSelected:(BOOL)selected;
- (void)refreshState;
- (UIViewController<CCUIContentModuleContentViewController> *)contentViewController;

@end

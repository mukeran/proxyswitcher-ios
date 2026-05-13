#import "PSCCMenuViewController.h"
#import "../Shared/PSProxyManager.h"
#import <notify.h>

static UIImage *transparentImage() {
    UIGraphicsBeginImageContextWithOptions(CGSizeMake(24, 24), NO, 0.0);
    UIImage *image = UIGraphicsGetImageFromCurrentImageContext();
    UIGraphicsEndImageContext();
    return image;
}

@implementation PSCCMenuViewController {
    int _notifyToken;
}

- (void)willTransitionToExpandedContentMode:(BOOL)expanded {
    [super willTransitionToExpandedContentMode:expanded];
    if (expanded) {
        [self refreshActions];
    }
    [self refreshState];
}

- (BOOL)shouldBeginTransitionToExpandedContentModule {
    [self refreshActions];
    return [super shouldBeginTransitionToExpandedContentModule];
}

- (void)viewDidLoad {
    [super viewDidLoad];
    self.title = @"Proxy Switcher";
    
    [self refreshActions];
    [self refreshState];
    __weak typeof(self) weakSelf = self;
    notify_register_dispatch(PSProxyProfilesChangedNotification.UTF8String, &_notifyToken, dispatch_get_main_queue(), ^(int token) {
        [weakSelf refreshState];
    });
}

- (void)viewWillAppear:(BOOL)animated {
    [super viewWillAppear:animated];
    [self refreshActions];
    [self refreshState];
}

- (void)dealloc {
    if (_notifyToken) {
        notify_cancel(_notifyToken);
    }
}

- (void)refreshState {
    BOOL isDirect = [[[PSProxyManager sharedManager] activeIdentifier] isEqualToString:PSProxyDirectIdentifier];
    self.selected = !isDirect;
    UIImage *glyph = [UIImage imageNamed:@"ProxySwitcherCCGlyph" inBundle:[NSBundle bundleForClass:self.class] compatibleWithTraitCollection:nil];
    if (!glyph) {
        if (@available(iOS 13.0, *)) {
            glyph = [UIImage systemImageNamed:@"network"];
        }
    }
    if (glyph) {
        glyph = [glyph imageWithRenderingMode:UIImageRenderingModeAlwaysTemplate];
        self.glyphImage = glyph;
        self.selectedGlyphImage = glyph;
    }
    if (@available(iOS 13.0, *)) {
        self.selectedGlyphColor = UIColor.systemTealColor;
    }
}

- (void)applyDirect {
    NSError *error;
    [[PSProxyManager sharedManager] applyDirectWithError:&error];
    [self refreshState];
}

- (void)applyProfile:(PSProxyProfile *)profile {
    NSError *error;
    [[PSProxyManager sharedManager] applyProfileWithIdentifier:profile.identifier error:&error];
    [self refreshState];
}

- (void)refreshActions {
    [self removeAllActions];
    
    NSArray<PSProxyProfile *> *profiles = [[PSProxyManager sharedManager] profiles];
    NSString *activeIdentifier = [[PSProxyManager sharedManager] activeIdentifier];
    PSProxyProfile *temporaryProfile = [[PSProxyManager sharedManager] temporaryProfile];
    
    __weak typeof(self) weakSelf = self;
    
    // Add Direct
    UIImage *directGlyph = transparentImage();
    if (@available(iOS 13.0, *)) {
        directGlyph = [activeIdentifier isEqualToString:PSProxyDirectIdentifier] ? [UIImage systemImageNamed:@"checkmark"] : transparentImage();
    }
    NSString *directSubtitle = temporaryProfile ? [NSString stringWithFormat:@"Current: %@:%ld", temporaryProfile.host, (long)temporaryProfile.port] : @"No HTTP proxy";
    [self addActionWithTitle:@"Direct" subtitle:directSubtitle glyph:directGlyph handler:^{
        [weakSelf applyDirect];
    }];
    
    // Add Profiles
    for (PSProxyProfile *profile in profiles) {
        UIImage *glyph = transparentImage();
        if (@available(iOS 13.0, *)) {
            glyph = [activeIdentifier isEqualToString:profile.identifier] ? [UIImage systemImageNamed:@"checkmark"] : transparentImage();
        }
        [self addActionWithTitle:profile.name glyph:glyph handler:^{
            [weakSelf applyProfile:profile];
        }];
    }
}

- (void)buttonTapped:(id)arg1 forEvent:(id)arg2 {
    BOOL selected = !self.selected;
    NSError *error;
    if (selected) {
        NSString *lastIdentifier = [[PSProxyManager sharedManager] lastActiveProfileIdentifier];
        if (!lastIdentifier) {
            NSArray<PSProxyProfile *> *profiles = [[PSProxyManager sharedManager] profiles];
            if (profiles.count > 0) {
                lastIdentifier = profiles.firstObject.identifier;
            }
        }
        if (lastIdentifier) {
            [[PSProxyManager sharedManager] applyProfileWithIdentifier:lastIdentifier error:&error];
        }
    } else {
        [[PSProxyManager sharedManager] applyDirectWithError:&error];
    }
    [self refreshState];
    [super buttonTapped:arg1 forEvent:arg2];
}

@end

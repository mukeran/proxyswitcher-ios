#import "PSCCMenuViewController.h"
#import "../Shared/PSProxyManager.h"
#import <ControlCenterUIKit/CCUIMenuModuleItemView.h>
#import <notify.h>

static UIImage *transparentImage() {
    UIGraphicsBeginImageContextWithOptions(CGSizeMake(24, 24), NO, 0.0);
    UIImage *image = UIGraphicsGetImageFromCurrentImageContext();
    UIGraphicsEndImageContext();
    return image;
}

@implementation PSCCMenuViewController {
    int _notifyToken;
    NSMutableIndexSet *_sectionActionIndexes;
    NSUInteger _openAppActionIndex;
    NSUInteger _statusActionIndex;
    BOOL _operationInProgress;
    NSString *_operationTitle;
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

- (void)viewDidLayoutSubviews {
    [super viewDidLayoutSubviews];
    [self styleDecorativeMenuItems];
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
    if (_operationInProgress) {
        return;
    }
    [self beginOperationWithTitle:@"Applying Direct..."];
    __weak typeof(self) weakSelf = self;
    dispatch_async(dispatch_get_global_queue(QOS_CLASS_UTILITY, 0), ^{
        NSError *error;
        [[PSProxyManager sharedManager] applyDirectWithError:&error];
        dispatch_async(dispatch_get_main_queue(), ^{
            [weakSelf finishOperation];
        });
    });
}

- (void)applyProfile:(PSProxyProfile *)profile {
    if (_operationInProgress) {
        return;
    }
    NSString *identifier = profile.identifier;
    [self beginOperationWithTitle:[NSString stringWithFormat:@"Applying %@...", profile.name]];
    __weak typeof(self) weakSelf = self;
    dispatch_async(dispatch_get_global_queue(QOS_CLASS_UTILITY, 0), ^{
        NSError *error;
        [[PSProxyManager sharedManager] applyProfileWithIdentifier:identifier error:&error];
        dispatch_async(dispatch_get_main_queue(), ^{
            [weakSelf finishOperation];
        });
    });
}

- (void)switchToWiFiNetwork:(PSWiFiNetwork *)network {
    if (_operationInProgress) {
        return;
    }
    NSString *ssid = network.ssid;
    [self beginOperationWithTitle:[NSString stringWithFormat:@"Switching to %@...", network.displayName]];
    __weak typeof(self) weakSelf = self;
    dispatch_async(dispatch_get_global_queue(QOS_CLASS_UTILITY, 0), ^{
        NSError *error;
        [[PSProxyManager sharedManager] switchToWiFiSSID:ssid error:&error];
        dispatch_async(dispatch_get_main_queue(), ^{
            [weakSelf finishOperation];
        });
    });
}

- (void)beginOperationWithTitle:(NSString *)title {
    _operationInProgress = YES;
    _operationTitle = [title copy];
    [self refreshActions];
    [self refreshState];
}

- (void)finishOperation {
    _operationInProgress = NO;
    _operationTitle = nil;
    [self refreshActions];
    [self refreshState];
}

- (void)openApp {
    NSURL *url = [NSURL URLWithString:@"proxyswitcher://"];
    Class applicationClass = NSClassFromString(@"UIApplication");
    id application = [applicationClass respondsToSelector:@selector(sharedApplication)] ? [applicationClass sharedApplication] : nil;
    if (!application) {
        return;
    }
    [application openURL:url options:@{} completionHandler:nil];
}

- (NSUInteger)addMenuActionWithTitle:(NSString *)title subtitle:(NSString *)subtitle glyph:(UIImage *)glyph handler:(dispatch_block_t)handler {
    NSUInteger index = self.actionsCount;
    [self addActionWithTitle:title subtitle:subtitle glyph:glyph handler:handler];
    return index;
}

- (void)addSectionTitle:(NSString *)title {
    NSUInteger index = [self addMenuActionWithTitle:title subtitle:nil glyph:transparentImage() handler:^{}];
    [_sectionActionIndexes addIndex:index];
}

- (NSArray *)menuItemViews {
    id itemViews = nil;
    @try {
        itemViews = [self valueForKey:@"_menuItemsViews"];
    } @catch (__unused NSException *exception) {
        itemViews = nil;
    }
    return [itemViews isKindOfClass:NSArray.class] ? itemViews : @[];
}

- (void)styleDecorativeMenuItems {
    NSArray *itemViews = [self menuItemViews];
    [itemViews enumerateObjectsUsingBlock:^(id item, NSUInteger index, __unused BOOL *stop) {
        if (![item isKindOfClass:CCUIMenuModuleItemView.class]) {
            return;
        }

        CCUIMenuModuleItemView *itemView = item;
        UILabel *titleLabel = nil;
        UILabel *subtitleLabel = nil;
        UIImageView *glyphImageView = nil;
        UIView *highlightedBackgroundView = nil;

        @try {
            titleLabel = [itemView valueForKey:@"_titleLabel"];
            subtitleLabel = [itemView valueForKey:@"_subtitleLabel"];
            glyphImageView = [itemView valueForKey:@"_glyphImageView"];
            highlightedBackgroundView = [itemView valueForKey:@"_highlightedBackgroundView"];
        } @catch (__unused NSException *exception) {
            return;
        }

        if ([_sectionActionIndexes containsIndex:index]) {
            itemView.userInteractionEnabled = NO;
            itemView.separatorVisible = index > 0;
            titleLabel.font = [UIFont systemFontOfSize:13.0 weight:UIFontWeightHeavy];
            if (@available(iOS 13.0, *)) {
                titleLabel.textColor = UIColor.systemTealColor;
            } else {
                titleLabel.textColor = [UIColor colorWithRed:0.0 green:0.75 blue:0.7 alpha:1.0];
            }
            subtitleLabel.hidden = YES;
            glyphImageView.hidden = YES;
            highlightedBackgroundView.hidden = YES;
            return;
        }

        if (index == _statusActionIndex) {
            itemView.userInteractionEnabled = NO;
            itemView.separatorVisible = NO;
            titleLabel.font = [UIFont systemFontOfSize:titleLabel.font.pointSize weight:UIFontWeightSemibold];
            subtitleLabel.hidden = NO;
            highlightedBackgroundView.hidden = YES;
            if (@available(iOS 13.0, *)) {
                titleLabel.textColor = UIColor.systemOrangeColor;
                glyphImageView.tintColor = UIColor.systemOrangeColor;
            }
            return;
        }

        if (index == _openAppActionIndex) {
            itemView.separatorVisible = YES;
            if (@available(iOS 13.0, *)) {
                titleLabel.font = [UIFont systemFontOfSize:titleLabel.font.pointSize weight:UIFontWeightSemibold];
                titleLabel.textColor = UIColor.systemTealColor;
                glyphImageView.tintColor = UIColor.systemTealColor;
            }
        }
    }];
}

- (void)refreshActions {
    [self removeAllActions];
    _sectionActionIndexes = [NSMutableIndexSet indexSet];
    _openAppActionIndex = NSNotFound;
    _statusActionIndex = NSNotFound;
    
    NSArray<PSProxyProfile *> *profiles = [[PSProxyManager sharedManager] profiles];
    NSArray<PSWiFiNetwork *> *wifiNetworks = [[PSProxyManager sharedManager] quickWiFiNetworks];
    NSString *activeIdentifier = [[PSProxyManager sharedManager] activeIdentifier];
    PSProxyProfile *temporaryProfile = [[PSProxyManager sharedManager] temporaryProfile];
    NSString *currentSSID = [[PSProxyManager sharedManager] currentWiFiSSID];
    
    __weak typeof(self) weakSelf = self;

    if (_operationInProgress) {
        UIImage *statusGlyph = transparentImage();
        if (@available(iOS 13.0, *)) {
            statusGlyph = [UIImage systemImageNamed:@"hourglass"];
        }
        _statusActionIndex = [self addMenuActionWithTitle:@"Working..." subtitle:_operationTitle ?: @"Updating proxy settings..." glyph:statusGlyph handler:^{}];
    }
    
    [self addSectionTitle:@"🌐  PROXY"];

    UIImage *directGlyph = transparentImage();
    if (@available(iOS 13.0, *)) {
        directGlyph = [activeIdentifier isEqualToString:PSProxyDirectIdentifier] ? [UIImage systemImageNamed:@"checkmark"] : transparentImage();
    }
    NSString *directSubtitle = temporaryProfile ? [NSString stringWithFormat:@"Current: %@:%ld", temporaryProfile.host, (long)temporaryProfile.port] : @"No HTTP proxy";
    [self addMenuActionWithTitle:@"Direct" subtitle:directSubtitle glyph:directGlyph handler:^{
        [weakSelf applyDirect];
    }];
    
    for (PSProxyProfile *profile in profiles) {
        UIImage *glyph = transparentImage();
        if (@available(iOS 13.0, *)) {
            glyph = [activeIdentifier isEqualToString:profile.identifier] ? [UIImage systemImageNamed:@"checkmark"] : transparentImage();
        }
        [self addMenuActionWithTitle:profile.name subtitle:nil glyph:glyph handler:^{
            [weakSelf applyProfile:profile];
        }];
    }

    if (wifiNetworks.count > 0) {
        [self addSectionTitle:@"📶  WI-FI"];
        for (PSWiFiNetwork *network in wifiNetworks) {
            UIImage *glyph = transparentImage();
            if (@available(iOS 13.0, *)) {
                glyph = [network.ssid isEqualToString:currentSSID] ? [UIImage systemImageNamed:@"checkmark"] : [UIImage systemImageNamed:@"wifi"];
            }
            NSString *subtitle = network.proxyProfile ? [NSString stringWithFormat:@"%@:%ld", network.proxyProfile.host, (long)network.proxyProfile.port] : @"Direct";
            [self addMenuActionWithTitle:network.displayName subtitle:subtitle glyph:glyph handler:^{
                [weakSelf switchToWiFiNetwork:network];
            }];
        }
    }

    UIImage *openGlyph = transparentImage();
    if (@available(iOS 13.0, *)) {
        openGlyph = [[UIImage systemImageNamed:@"arrow.up.forward.app"] imageWithRenderingMode:UIImageRenderingModeAlwaysTemplate];
    }
    _openAppActionIndex = [self addMenuActionWithTitle:@"Open ProxySwitcher" subtitle:nil glyph:openGlyph handler:^{
        [weakSelf openApp];
    }];
    [self styleDecorativeMenuItems];
}

- (void)buttonTapped:(id)arg1 forEvent:(id)arg2 {
    if (_operationInProgress) {
        return;
    }
    BOOL selected = !self.selected;
    NSString *targetIdentifier = nil;
    if (selected) {
        NSString *lastIdentifier = [[PSProxyManager sharedManager] lastActiveProfileIdentifier];
        if (!lastIdentifier) {
            NSArray<PSProxyProfile *> *profiles = [[PSProxyManager sharedManager] profiles];
            if (profiles.count > 0) {
                lastIdentifier = profiles.firstObject.identifier;
            }
        }
        if (lastIdentifier) {
            targetIdentifier = lastIdentifier;
        }
    }
    __weak typeof(self) weakSelf = self;
    [self beginOperationWithTitle:targetIdentifier ? @"Applying proxy..." : @"Applying Direct..."];
    dispatch_async(dispatch_get_global_queue(QOS_CLASS_UTILITY, 0), ^{
        NSError *error;
        if (targetIdentifier) {
            [[PSProxyManager sharedManager] applyProfileWithIdentifier:targetIdentifier error:&error];
        } else {
            [[PSProxyManager sharedManager] applyDirectWithError:&error];
        }
        dispatch_async(dispatch_get_main_queue(), ^{
            [weakSelf finishOperation];
        });
    });
    [super buttonTapped:arg1 forEvent:arg2];
}

@end

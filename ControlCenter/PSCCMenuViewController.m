#import "PSCCMenuViewController.h"
#import "../Shared/PSProxyManager.h"
#import <ControlCenterUIKit/CCUIMenuModuleItemView.h>
#import <notify.h>
#import <objc/message.h>
#import <dlfcn.h>

static UIImage *transparentImage() {
    UIGraphicsBeginImageContextWithOptions(CGSizeMake(24, 24), NO, 0.0);
    UIImage *image = UIGraphicsGetImageFromCurrentImageContext();
    UIGraphicsEndImageContext();
    return image;
}

@implementation PSCCMenuViewController {
    int _notifyToken;
    int _operationNotifyToken;
    NSMutableIndexSet *_sectionActionIndexes;
    NSUInteger _openAppActionIndex;
    NSUInteger _statusActionIndex;
    NSUInteger _operationSerial;
    BOOL _operationInProgress;
    NSString *_operationTitle;
}

static BOOL PSLaunchAppByBundleIdentifier(NSString *bundleIdentifier) {
    if (![bundleIdentifier isKindOfClass:NSString.class] || bundleIdentifier.length == 0) {
        return NO;
    }
    Class workspaceClass = NSClassFromString(@"LSApplicationWorkspace");
    if (workspaceClass && [workspaceClass respondsToSelector:@selector(defaultWorkspace)]) {
        id workspace = ((id (*)(id, SEL))objc_msgSend)(workspaceClass, @selector(defaultWorkspace));
        SEL openSelector = NSSelectorFromString(@"openApplicationWithBundleID:");
        if (workspace && [workspace respondsToSelector:openSelector]) {
            BOOL ok = ((BOOL (*)(id, SEL, id))objc_msgSend)(workspace, openSelector, bundleIdentifier);
            if (ok) {
                return YES;
            }
        }
        SEL openWithConfigurationSelector = NSSelectorFromString(@"openApplicationWithBundleID:configuration:completionHandler:");
        if (workspace && [workspace respondsToSelector:openWithConfigurationSelector]) {
            ((void (*)(id, SEL, id, id, id))objc_msgSend)(workspace, openWithConfigurationSelector, bundleIdentifier, nil, nil);
            return YES;
        }
        SEL openUsingConfigurationSelector = NSSelectorFromString(@"openApplicationWithBundleID:usingConfiguration:completionHandler:");
        if (workspace && [workspace respondsToSelector:openUsingConfigurationSelector]) {
            ((void (*)(id, SEL, id, id, id))objc_msgSend)(workspace, openUsingConfigurationSelector, bundleIdentifier, nil, nil);
            return YES;
        }
    }

    void *handle = dlopen("/System/Library/PrivateFrameworks/SpringBoardServices.framework/SpringBoardServices", RTLD_LAZY);
    if (handle) {
        typedef int (*SBSLaunchApplicationWithIdentifierFn)(CFStringRef identifier, BOOL suspended);
        SBSLaunchApplicationWithIdentifierFn fn = (SBSLaunchApplicationWithIdentifierFn)dlsym(handle, "SBSLaunchApplicationWithIdentifier");
        if (fn) {
            int result = fn((__bridge CFStringRef)bundleIdentifier, NO);
            dlclose(handle);
            return result == 0;
        }
        dlclose(handle);
    }
    return NO;
}

static void PSLaunchAppByBundleIdentifierAsync(NSString *bundleIdentifier, void (^completion)(BOOL launched)) {
    dispatch_async(dispatch_get_global_queue(QOS_CLASS_UTILITY, 0), ^{
        BOOL launched = PSLaunchAppByBundleIdentifier(bundleIdentifier);
        dispatch_async(dispatch_get_main_queue(), ^{
            if (completion) {
                completion(launched);
            }
        });
    });
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
        [weakSelf refreshActions];
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
    if (_operationNotifyToken) {
        notify_cancel(_operationNotifyToken);
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
    PSProxyManager *manager = [PSProxyManager sharedManager];
    if ([manager isCompatibilityModeEnabled]) {
        [self beginOperationWithTitle:@"Switching via App..." waitForNotification:YES];
        [self dispatchURLAction:@"proxyswitcher://direct"];
        return;
    }
    [self beginOperationWithTitle:@"Applying Direct..." waitForNotification:NO];
    __weak typeof(self) weakSelf = self;
    dispatch_async(dispatch_get_global_queue(QOS_CLASS_UTILITY, 0), ^{
        NSError *error;
        BOOL ok = [manager applyDirectWithError:&error];
        dispatch_async(dispatch_get_main_queue(), ^{
            if (!ok && [manager isCompatibilityModeEnabled]) {
                [manager setPendingAppCommand:@{
                    @"action": @"direct",
                    @"source": @"cc"
                }];
                [weakSelf beginOperationWithTitle:@"Opening App..." waitForNotification:YES];
                [weakSelf openAppByBundleIdentifier];
                return;
            }
            [weakSelf finishOperation];
        });
    });
}

- (void)applyProfile:(PSProxyProfile *)profile {
    if (_operationInProgress) {
        return;
    }
    PSProxyManager *manager = [PSProxyManager sharedManager];
    if ([manager isCompatibilityModeEnabled]) {
        NSString *encodedIdentifier = [profile.identifier stringByAddingPercentEncodingWithAllowedCharacters:NSCharacterSet.URLQueryAllowedCharacterSet];
        NSString *urlString = [NSString stringWithFormat:@"proxyswitcher://apply?id=%@", encodedIdentifier ?: @""];
        [self beginOperationWithTitle:[NSString stringWithFormat:@"Switching %@ via App...", profile.name] waitForNotification:YES];
        [self dispatchURLAction:urlString];
        return;
    }
    NSString *identifier = profile.identifier;
    [self beginOperationWithTitle:[NSString stringWithFormat:@"Applying %@...", profile.name] waitForNotification:NO];
    __weak typeof(self) weakSelf = self;
    dispatch_async(dispatch_get_global_queue(QOS_CLASS_UTILITY, 0), ^{
        NSError *error;
        BOOL ok = [manager applyProfileWithIdentifier:identifier error:&error];
        dispatch_async(dispatch_get_main_queue(), ^{
            if (!ok && [manager isCompatibilityModeEnabled]) {
                [manager setPendingAppCommand:@{
                    @"action": @"apply",
                    @"identifier": profile.identifier ?: @"",
                    @"source": @"cc"
                }];
                [weakSelf beginOperationWithTitle:@"Opening App..." waitForNotification:YES];
                [weakSelf openAppByBundleIdentifier];
                return;
            }
            [weakSelf finishOperation];
        });
    });
}

- (void)switchToWiFiNetwork:(PSWiFiNetwork *)network {
    if (_operationInProgress) {
        return;
    }
    NSString *ssid = network.ssid;
    [self beginOperationWithTitle:[NSString stringWithFormat:@"Switching to %@...", network.displayName] waitForNotification:NO];
    __weak typeof(self) weakSelf = self;
    dispatch_async(dispatch_get_global_queue(QOS_CLASS_UTILITY, 0), ^{
        NSError *error;
        [[PSProxyManager sharedManager] switchToWiFiSSID:ssid error:&error];
        dispatch_async(dispatch_get_main_queue(), ^{
            [weakSelf finishOperation];
        });
    });
}

- (void)beginOperationWithTitle:(NSString *)title waitForNotification:(BOOL)waitForNotification {
    _operationSerial += 1;
    _operationInProgress = YES;
    _operationTitle = [title copy];
    if (_operationNotifyToken) {
        notify_cancel(_operationNotifyToken);
        _operationNotifyToken = 0;
    }
    if (waitForNotification) {
        NSUInteger operationSerial = _operationSerial;
        __weak typeof(self) weakSelf = self;
        notify_register_dispatch(PSProxyProfilesChangedNotification.UTF8String, &_operationNotifyToken, dispatch_get_main_queue(), ^(int token) {
            #pragma unused(token)
            __strong typeof(weakSelf) strongSelf = weakSelf;
            if (!strongSelf || operationSerial != strongSelf->_operationSerial || !strongSelf->_operationInProgress) {
                return;
            }
            [strongSelf finishOperation];
        });
        dispatch_after(dispatch_time(DISPATCH_TIME_NOW, (int64_t)(4.0 * NSEC_PER_SEC)), dispatch_get_main_queue(), ^{
            __strong typeof(weakSelf) strongSelf = weakSelf;
            if (!strongSelf || operationSerial != strongSelf->_operationSerial || !strongSelf->_operationInProgress) {
                return;
            }
            [[PSProxyManager sharedManager] clearPendingAppCommand];
            [strongSelf finishOperation];
        });
    }
    [self refreshActions];
    [self refreshState];
}

- (void)finishOperation {
    if (_operationNotifyToken) {
        notify_cancel(_operationNotifyToken);
        _operationNotifyToken = 0;
    }
    _operationInProgress = NO;
    _operationTitle = nil;
    [self refreshActions];
    [self refreshState];
}

- (void)openApp {
    NSURL *url = [NSURL URLWithString:@"proxyswitcher://"];
    [self dispatchURL:url];
}

- (void)dispatchURLAction:(NSString *)urlString {
    if (![urlString isKindOfClass:NSString.class] || urlString.length == 0) {
        return;
    }
    NSURL *url = [NSURL URLWithString:urlString];
    [self dispatchURL:url];
}

- (void)openAppByBundleIdentifier {
    __weak typeof(self) weakSelf = self;
    PSLaunchAppByBundleIdentifierAsync(@"codes.var.tweak.proxyswitcher", ^(BOOL launched) {
        if (launched) {
            return;
        }
        NSLog(@"[ProxySwitcherCC] Failed to launch app by bundle id.");
        [[PSProxyManager sharedManager] clearPendingAppCommand];
        [weakSelf finishOperation];
    });
}

- (void)dispatchURL:(NSURL *)url {
    if (![url isKindOfClass:NSURL.class]) {
        return;
    }
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
    
    PSProxyManager *manager = [PSProxyManager sharedManager];
    NSArray<PSProxyProfile *> *profiles = [manager profiles];
    NSArray<PSWiFiNetwork *> *wifiNetworks = [manager quickWiFiNetworks];
    BOOL wifiSwitchSupported = [manager isWiFiSwitchSupported] && ![manager isCompatibilityModeEnabled];
    NSString *activeIdentifier = [manager activeIdentifier];
    PSProxyProfile *temporaryProfile = [manager temporaryProfile];
    NSString *currentSSID = [manager currentWiFiSSID];
    
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

    if (wifiSwitchSupported && wifiNetworks.count > 0) {
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
    PSProxyManager *manager = [PSProxyManager sharedManager];
    if ([manager isCompatibilityModeEnabled]) {
        [self beginOperationWithTitle:@"Toggling via App..." waitForNotification:YES];
        [self dispatchURLAction:@"proxyswitcher://toggle"];
        [super buttonTapped:arg1 forEvent:arg2];
        return;
    }
    BOOL selected = !self.selected;
    NSString *targetIdentifier = nil;
    if (selected) {
        NSString *lastIdentifier = [manager lastActiveProfileIdentifier];
        if (!lastIdentifier) {
            NSArray<PSProxyProfile *> *profiles = [manager profiles];
            if (profiles.count > 0) {
                lastIdentifier = profiles.firstObject.identifier;
            }
        }
        if (lastIdentifier) {
            targetIdentifier = lastIdentifier;
        }
    }
    __weak typeof(self) weakSelf = self;
    [self beginOperationWithTitle:targetIdentifier ? @"Applying proxy..." : @"Applying Direct..." waitForNotification:NO];
    dispatch_async(dispatch_get_global_queue(QOS_CLASS_UTILITY, 0), ^{
        NSError *error;
        if (targetIdentifier) {
            [manager applyProfileWithIdentifier:targetIdentifier error:&error];
        } else {
            [manager applyDirectWithError:&error];
        }
        dispatch_async(dispatch_get_main_queue(), ^{
            [weakSelf finishOperation];
        });
    });
    [super buttonTapped:arg1 forEvent:arg2];
}

@end

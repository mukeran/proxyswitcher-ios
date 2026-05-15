#import "PSAppDelegate.h"
#import "PSRootViewController.h"
#import "PSProxyManager.h"
#import <notify.h>
#import <NetworkExtension/NetworkExtension.h>

static NSString * const PSVPNProxyDescription = @"ProxySwitcher HTTP Proxy";
static BOOL PSStateRefreshInFlight = NO;
static BOOL PSStateRefreshPending = NO;

static dispatch_queue_t PSStateRefreshQueue(void) {
	static dispatch_queue_t queue;
	static dispatch_once_t onceToken;
	dispatch_once(&onceToken, ^{
		queue = dispatch_queue_create("codes.var.tweak.proxyswitcher.state-refresh", DISPATCH_QUEUE_SERIAL);
	});
	return queue;
}

static NSString *PSURLQueryValue(NSURLComponents *components, NSString *name) {
	for (NSURLQueryItem *item in components.queryItems) {
		if ([item.name isEqualToString:name]) {
			return item.value;
		}
	}
	return nil;
}

@implementation PSAppDelegate

- (void)processPendingCommandIfNeeded {
	PSProxyManager *manager = [PSProxyManager sharedManager];
	NSDictionary<NSString *, id> *command = [manager pendingAppCommand];
	if (![command isKindOfClass:NSDictionary.class] || command.count == 0) {
		return;
	}
	[manager clearPendingAppCommand];
	NSString *action = [command[@"action"] isKindOfClass:NSString.class] ? [command[@"action"] lowercaseString] : @"";
	NSString *identifier = [command[@"identifier"] isKindOfClass:NSString.class] ? command[@"identifier"] : nil;
	NSError *error = nil;
	BOOL ok = NO;
	if ([action isEqualToString:@"direct"]) {
		ok = [manager applyDirectWithError:&error];
	} else if ([action isEqualToString:@"apply"] && identifier.length > 0) {
		ok = [manager applyProfileWithIdentifier:identifier error:&error];
	}
	if (!ok && error) {
		NSLog(@"[ProxySwitcher] Pending command failed: %@", error);
	}
	if (ok) {
		[self postProxyStateRefresh];
		if ([manager isCompatibilityModeEnabled]) {
			[self observeVPNStateAndRefresh];
		}
	}
}

- (void)refreshRootUIIfPossible {
	UIViewController *root = self.window.rootViewController;
	if ([root isKindOfClass:UINavigationController.class]) {
		root = ((UINavigationController *)root).topViewController ?: root;
	}
	if ([root respondsToSelector:@selector(reloadProfiles)]) {
#pragma clang diagnostic push
#pragma clang diagnostic ignored "-Warc-performSelector-leaks"
		[root performSelector:@selector(reloadProfiles)];
#pragma clang diagnostic pop
	}
}

- (void)postProxyStateRefresh {
	@synchronized (PSAppDelegate.class) {
		if (PSStateRefreshInFlight) {
			PSStateRefreshPending = YES;
			return;
		}
		PSStateRefreshInFlight = YES;
	}

	__weak typeof(self) weakSelf = self;
	dispatch_async(PSStateRefreshQueue(), ^{
		while (1) {
			[[PSProxyManager sharedManager] syncActiveProfileWithCurrentSystemProxy:nil];
			dispatch_async(dispatch_get_main_queue(), ^{
				notify_post(PSProxyProfilesChangedNotification.UTF8String);
				[weakSelf refreshRootUIIfPossible];
			});

			BOOL shouldContinue = NO;
			@synchronized (PSAppDelegate.class) {
				if (PSStateRefreshPending) {
					PSStateRefreshPending = NO;
					shouldContinue = YES;
				} else {
					PSStateRefreshInFlight = NO;
				}
			}
			if (!shouldContinue) {
				break;
			}
		}
	});
}

- (void)observeVPNStateAndRefresh {
	__weak typeof(self) weakSelf = self;
	[NETunnelProviderManager loadAllFromPreferencesWithCompletionHandler:^(NSArray<NETunnelProviderManager *> * _Nullable managers, NSError * _Nullable error) {
		#pragma unused(error)
		NETunnelProviderManager *target = nil;
		for (NETunnelProviderManager *candidate in managers) {
			if ([candidate.localizedDescription isEqualToString:PSVPNProxyDescription]) {
				target = candidate;
				break;
			}
		}
		if (!target) {
			target = managers.firstObject;
		}
		if (!target) {
			dispatch_async(dispatch_get_main_queue(), ^{
				[weakSelf postProxyStateRefresh];
			});
			return;
		}
		__block id observer = nil;
		observer = [NSNotificationCenter.defaultCenter addObserverForName:NEVPNStatusDidChangeNotification object:target.connection queue:NSOperationQueue.mainQueue usingBlock:^(NSNotification * _Nonnull note) {
			#pragma unused(note)
			[weakSelf postProxyStateRefresh];
			NEVPNStatus status = target.connection.status;
			if (status == NEVPNStatusConnected || status == NEVPNStatusDisconnected || status == NEVPNStatusInvalid) {
				if (observer) {
					[NSNotificationCenter.defaultCenter removeObserver:observer];
					observer = nil;
				}
			}
		}];
		dispatch_async(dispatch_get_main_queue(), ^{
			[weakSelf postProxyStateRefresh];
		});
		dispatch_after(dispatch_time(DISPATCH_TIME_NOW, (int64_t)(12.0 * NSEC_PER_SEC)), dispatch_get_main_queue(), ^{
			if (observer) {
				[NSNotificationCenter.defaultCenter removeObserver:observer];
			}
		});
	}];
}

- (BOOL)application:(UIApplication *)application didFinishLaunchingWithOptions:(NSDictionary *)launchOptions {
	self.window = [[UIWindow alloc] initWithFrame:UIScreen.mainScreen.bounds];
	PSRootViewController *rootViewController = [[PSRootViewController alloc] initWithStyle:UITableViewStyleInsetGrouped];
	UINavigationController *navigationController = [[UINavigationController alloc] initWithRootViewController:rootViewController];
	self.window.rootViewController = navigationController;
	[self.window makeKeyAndVisible];
	[self processPendingCommandIfNeeded];
	return YES;
}

- (void)applicationDidBecomeActive:(UIApplication *)application {
	#pragma unused(application)
	[self processPendingCommandIfNeeded];
}

- (BOOL)application:(UIApplication *)app openURL:(NSURL *)url options:(NSDictionary<UIApplicationOpenURLOptionsKey,id> *)options {
	#pragma unused(app, options)
	if ([url.scheme isEqualToString:@"proxyswitcher"]) {
		NSURLComponents *components = [NSURLComponents componentsWithURL:url resolvingAgainstBaseURL:NO];
		NSString *command = components.host.lowercaseString ?: @"";
		NSString *path = components.path.lowercaseString ?: @"";
		NSString *identifier = ([command isEqualToString:@"apply"] || [path isEqualToString:@"/apply"]) ? PSURLQueryValue(components, @"id") : nil;
		dispatch_async(dispatch_get_global_queue(QOS_CLASS_USER_INITIATED, 0), ^{
			PSProxyManager *manager = [PSProxyManager sharedManager];
			NSError *error = nil;
			BOOL ok = NO;
			if ([command isEqualToString:@"direct"] || [path isEqualToString:@"/direct"]) {
				ok = [manager applyDirectWithError:&error];
			} else if ([command isEqualToString:@"toggle"] || [path isEqualToString:@"/toggle"]) {
				NSString *active = [manager activeIdentifier];
				if ([active isEqualToString:PSProxyDirectIdentifier]) {
					NSString *lastIdentifier = [manager lastActiveProfileIdentifier];
					if (lastIdentifier.length > 0) {
						ok = [manager applyProfileWithIdentifier:lastIdentifier error:&error];
					} else {
						error = [NSError errorWithDomain:@"ProxySwitcher" code:406 userInfo:@{NSLocalizedDescriptionKey: @"No last profile available for toggle."}];
					}
				} else {
					ok = [manager applyDirectWithError:&error];
				}
			} else if (identifier.length > 0) {
				ok = [manager applyProfileWithIdentifier:identifier error:&error];
			}
			dispatch_async(dispatch_get_main_queue(), ^{
				if (!ok && error) {
					NSLog(@"[ProxySwitcher] URL action failed: %@", error);
				}
				[self postProxyStateRefresh];
				if ([manager isCompatibilityModeEnabled]) {
					[self observeVPNStateAndRefresh];
				}
			});
		});
		return YES;
	}
	return NO;
}

@end

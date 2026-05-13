#import "PSAppDelegate.h"
#import "PSRootViewController.h"

@implementation PSAppDelegate

- (BOOL)application:(UIApplication *)application didFinishLaunchingWithOptions:(NSDictionary *)launchOptions {
	self.window = [[UIWindow alloc] initWithFrame:UIScreen.mainScreen.bounds];
	PSRootViewController *rootViewController = [[PSRootViewController alloc] initWithStyle:UITableViewStyleInsetGrouped];
	UINavigationController *navigationController = [[UINavigationController alloc] initWithRootViewController:rootViewController];
	self.window.rootViewController = navigationController;
	[self.window makeKeyAndVisible];
	return YES;
}

- (BOOL)application:(UIApplication *)app openURL:(NSURL *)url options:(NSDictionary<UIApplicationOpenURLOptionsKey,id> *)options {
	if ([url.scheme isEqualToString:@"proxyswitcher"]) {
		return YES;
	}
	return NO;
}

@end

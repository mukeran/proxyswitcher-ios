#import <NetworkExtension/NetworkExtension.h>
#import <Foundation/Foundation.h>
#include "proxyswitcher_tun2http.h"

@interface PacketTunnelProvider : NEPacketTunnelProvider
@property (nonatomic, strong) dispatch_source_t keepaliveTimer;
@end

@implementation PacketTunnelProvider

- (void)startTunnelWithOptions:(NSDictionary<NSString *, NSObject *> *)options
             completionHandler:(void (^)(NSError * _Nullable))completionHandler {
	#pragma unused(options)
	NSDictionary *config = [self.protocolConfiguration isKindOfClass:NETunnelProviderProtocol.class] ? ((NETunnelProviderProtocol *)self.protocolConfiguration).providerConfiguration : nil;
	NSString *host = [config[@"httpHost"] isKindOfClass:NSString.class] ? config[@"httpHost"] : nil;
	NSNumber *portNumber = [config[@"httpPort"] respondsToSelector:@selector(integerValue)] ? config[@"httpPort"] : nil;
	NSInteger port = portNumber.integerValue;
	if (host.length == 0 || port < 1 || port > 65535) {
		completionHandler([NSError errorWithDomain:@"ProxySwitcherTunnel" code:100 userInfo:@{NSLocalizedDescriptionKey: @"Invalid HTTP proxy configuration."}]);
		return;
	}

	NEPacketTunnelNetworkSettings *settings = [[NEPacketTunnelNetworkSettings alloc] initWithTunnelRemoteAddress:host];
	settings.MTU = @1500;

	// Keep tunnel alive but avoid hijacking all routes. Actual HTTP/HTTPS proxy
	// behavior is controlled by protocol.proxySettings configured by the app.
	NEIPv4Settings *ipv4Settings = [[NEIPv4Settings alloc] initWithAddresses:@[@"198.18.0.2"] subnetMasks:@[@"255.255.255.255"]];
	ipv4Settings.includedRoutes = @[];
	ipv4Settings.excludedRoutes = @[[NEIPv4Route defaultRoute]];
	settings.IPv4Settings = ipv4Settings;

	NEProxySettings *proxySettings = [[NEProxySettings alloc] init];
	proxySettings.HTTPEnabled = YES;
	proxySettings.HTTPServer = [[NEProxyServer alloc] initWithAddress:host port:(NSInteger)port];
	proxySettings.HTTPSEnabled = YES;
	proxySettings.HTTPSServer = [[NEProxyServer alloc] initWithAddress:host port:(NSInteger)port];
	proxySettings.matchDomains = @[@""];
	NSArray<NSString *> *noProxy = [config[@"httpNoProxy"] isKindOfClass:NSArray.class] ? config[@"httpNoProxy"] : nil;
	if (noProxy.count > 0) {
		NSMutableArray<NSString *> *exceptions = [NSMutableArray array];
		for (NSString *value in noProxy) {
			if (![value isKindOfClass:NSString.class]) {
				continue;
			}
			NSString *trimmed = [value stringByTrimmingCharactersInSet:NSCharacterSet.whitespaceAndNewlineCharacterSet];
			if (trimmed.length > 0) {
				[exceptions addObject:trimmed];
			}
		}
		proxySettings.exceptionList = exceptions.copy;
	}
	settings.proxySettings = proxySettings;

	__weak typeof(self) weakSelf = self;
	[self setTunnelNetworkSettings:settings completionHandler:^(NSError * _Nullable error) {
		if (error) {
			completionHandler(error);
			return;
		}
		__strong typeof(weakSelf) strongSelf = weakSelf;
		int initRc = ps_t2h_android_init(NULL, NULL);
		if (initRc != 0) {
			completionHandler([NSError errorWithDomain:@"ProxySwitcherTunnel" code:107 userInfo:@{NSLocalizedDescriptionKey: [NSString stringWithFormat:@"tun2http init failed (%d).", initRc]}]);
			return;
		}
		int tunFd = [strongSelf packetFlowValueForKey:@"socket.fileDescriptor"];
		int startRc = ps_t2h_android_start(NULL, NULL, tunFd, 0, 0, host.UTF8String, (int)port);
		if (startRc != 0) {
			completionHandler([NSError errorWithDomain:@"ProxySwitcherTunnel" code:108 userInfo:@{NSLocalizedDescriptionKey: [NSString stringWithFormat:@"tun2http start failed (%d).", startRc]}]);
			return;
		}
		[strongSelf startKeepalive];
		completionHandler(nil);
	}];
}

- (int)packetFlowValueForKey:(NSString *)keyPath {
	id value = [self.packetFlow valueForKeyPath:keyPath];
	if ([value respondsToSelector:@selector(intValue)]) {
		return [value intValue];
	}
	return -1;
}

- (void)startKeepalive {
	if (self.keepaliveTimer) {
		return;
	}
	dispatch_queue_t queue = dispatch_get_global_queue(QOS_CLASS_BACKGROUND, 0);
	self.keepaliveTimer = dispatch_source_create(DISPATCH_SOURCE_TYPE_TIMER, 0, 0, queue);
	dispatch_source_set_timer(self.keepaliveTimer, dispatch_time(DISPATCH_TIME_NOW, 0), 30 * NSEC_PER_SEC, 2 * NSEC_PER_SEC);
	dispatch_source_set_event_handler(self.keepaliveTimer, ^{
		// No-op keepalive for the extension lifecycle.
	});
	dispatch_resume(self.keepaliveTimer);
}

- (void)stopTunnelWithReason:(NEProviderStopReason)reason completionHandler:(void (^)(void))completionHandler {
	#pragma unused(reason)
	(void)ps_t2h_android_stop(NULL, NULL, [self packetFlowValueForKey:@"socket.fileDescriptor"]);
	(void)ps_t2h_android_done(NULL, NULL);
	if (self.keepaliveTimer) {
		dispatch_source_cancel(self.keepaliveTimer);
		self.keepaliveTimer = nil;
	}
	completionHandler();
}

@end

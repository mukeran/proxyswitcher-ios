#import "PSProxyManager.h"
#import <Foundation/Foundation.h>
#import <SystemConfiguration/SystemConfiguration.h>
#import <dlfcn.h>
#import <fcntl.h>
#import <errno.h>
#import <sys/socket.h>
#import <sys/stat.h>
#import <sys/un.h>
#import <unistd.h>

static void WriteHelperStatus(NSString *message) {
	NSString *path = @"/private/var/mobile/Library/Preferences/codes.var.tweak.proxyswitcher.helper.log";
	NSString *line = [NSString stringWithFormat:@"%@\n", message ?: @""];
	[line writeToFile:path atomically:YES encoding:NSUTF8StringEncoding error:nil];
	chown(path.fileSystemRepresentation, 501, 501);
	chmod(path.fileSystemRepresentation, 0644);
}

static BOOL RunCommand(NSString *command, NSString *profileIdentifier, NSError **error) {
	if ([command isEqualToString:@"direct"]) {
		return [[PSProxyManager sharedManager] applyDirectWithError:error];
	}
	if ([command isEqualToString:@"apply"] && profileIdentifier.length > 0) {
		return [[PSProxyManager sharedManager] applyProfileWithIdentifier:profileIdentifier error:error];
	}
	if ([command isEqualToString:@"wifi"] && profileIdentifier.length > 0) {
		return [[PSProxyManager sharedManager] switchToWiFiSSID:profileIdentifier error:error];
	}
	if ([command isEqualToString:@"sync"]) {
		return [[PSProxyManager sharedManager] syncActiveProfileWithCurrentSystemProxy:error];
	}
	if (error) {
		*error = [NSError errorWithDomain:@"ProxySwitcher" code:64 userInfo:@{NSLocalizedDescriptionKey: @"Invalid helper request."}];
	}
	return NO;
}

static NSString *JSONStringForAvailableWiFiNetworks(void) {
	NSMutableArray *items = [NSMutableArray array];
	for (PSWiFiNetwork *network in [[PSProxyManager sharedManager] availableWiFiNetworks]) {
		NSMutableDictionary *item = [NSMutableDictionary dictionary];
		item[@"ssid"] = network.ssid ?: @"";
		item[@"displayName"] = network.displayName ?: network.ssid ?: @"";
		if (network.proxyProfile) {
			item[@"proxy"] = [network.proxyProfile dictionaryRepresentation];
		}
		[items addObject:item];
	}
	NSData *data = [NSJSONSerialization dataWithJSONObject:items options:0 error:nil];
	return data ? [[NSString alloc] initWithData:data encoding:NSUTF8StringEncoding] : @"[]";
}

static NSDictionary *RunRequest(NSDictionary *request) {
	@autoreleasepool {
		NSString *command = [request[@"command"] isKindOfClass:NSString.class] ? request[@"command"] : @"";
		NSString *profileIdentifier = [request[@"argument"] isKindOfClass:NSString.class] ? request[@"argument"] : @"";
		NSError *error = nil;
		BOOL ok = NO;
		NSString *message = @"";
		if ([command isEqualToString:@"listwifi"]) {
			ok = YES;
			message = JSONStringForAvailableWiFiNetworks();
		} else {
			ok = RunCommand(command, profileIdentifier, &error);
			message = ok ? @"" : (error.localizedDescription ?: @"Unable to update proxy settings.");
		}
		return @{@"ok": @(ok), @"message": message ?: @""};
	}
}

static void WriteResponse(int clientFD, NSDictionary *response) {
	NSData *data = [NSJSONSerialization dataWithJSONObject:response options:0 error:nil];
	NSMutableData *lineData = data ? [data mutableCopy] : [[@"{\"ok\":false,\"message\":\"Invalid helper response.\"}" dataUsingEncoding:NSUTF8StringEncoding] mutableCopy];
	[lineData appendData:[@"\n" dataUsingEncoding:NSUTF8StringEncoding]];
	const uint8_t *bytes = lineData.bytes;
	NSUInteger remaining = lineData.length;
	while (remaining > 0) {
		ssize_t written = write(clientFD, bytes, remaining);
		if (written <= 0) {
			break;
		}
		bytes += written;
		remaining -= (NSUInteger)written;
	}
}

static void HandleClient(int clientFD) {
	@autoreleasepool {
		NSMutableData *requestData = [NSMutableData data];
		uint8_t buffer[1024];
		BOOL sawNewline = NO;
		while (requestData.length < 1024 * 1024) {
			ssize_t count = read(clientFD, buffer, sizeof(buffer));
			if (count <= 0) {
				break;
			}
			NSUInteger length = (NSUInteger)count;
			for (NSUInteger index = 0; index < length; index++) {
				if (buffer[index] == '\n') {
					[requestData appendBytes:buffer length:index];
					sawNewline = YES;
					break;
				}
			}
			if (sawNewline) {
				break;
			}
			[requestData appendBytes:buffer length:length];
		}
		NSDictionary *request = requestData.length > 0 ? [NSJSONSerialization JSONObjectWithData:requestData options:0 error:nil] : nil;
		NSDictionary *response = [request isKindOfClass:NSDictionary.class] ? RunRequest(request) : @{@"ok": @NO, @"message": @"Invalid helper request."};
		WriteResponse(clientFD, response);
		close(clientFD);
	}
}

static BOOL StartSocketServer(void) {
	static dispatch_source_t acceptSource;
	static dispatch_queue_t operationQueue;
	int serverFD = socket(AF_UNIX, SOCK_STREAM, 0);
	if (serverFD < 0) {
		WriteHelperStatus([NSString stringWithFormat:@"socket failed errno=%d", errno]);
		return NO;
	}

	struct sockaddr_un address;
	memset(&address, 0, sizeof(address));
	address.sun_family = AF_UNIX;
	if (PSProxyHelperSocketPath.length >= sizeof(address.sun_path)) {
		WriteHelperStatus(@"socket path too long");
		close(serverFD);
		return NO;
	}
	strlcpy(address.sun_path, PSProxyHelperSocketPath.fileSystemRepresentation, sizeof(address.sun_path));
	unlink(address.sun_path);
	if (bind(serverFD, (struct sockaddr *)&address, sizeof(address)) != 0) {
		WriteHelperStatus([NSString stringWithFormat:@"bind failed errno=%d path=%@", errno, PSProxyHelperSocketPath]);
		close(serverFD);
		return NO;
	}
	chown(address.sun_path, 501, 501);
	chmod(address.sun_path, 0666);
	if (listen(serverFD, 8) != 0) {
		WriteHelperStatus([NSString stringWithFormat:@"listen failed errno=%d path=%@", errno, PSProxyHelperSocketPath]);
		close(serverFD);
		unlink(address.sun_path);
		return NO;
	}
	int flags = fcntl(serverFD, F_GETFL, 0);
	if (flags >= 0) {
		fcntl(serverFD, F_SETFL, flags | O_NONBLOCK);
	}

	operationQueue = dispatch_queue_create("codes.var.tweak.proxyswitcher.helper", DISPATCH_QUEUE_SERIAL);
	acceptSource = dispatch_source_create(DISPATCH_SOURCE_TYPE_READ, serverFD, 0, dispatch_get_main_queue());
	dispatch_source_set_event_handler(acceptSource, ^{
		while (1) {
			int clientFD = accept(serverFD, NULL, NULL);
			if (clientFD < 0) {
				if (errno == EAGAIN || errno == EWOULDBLOCK) {
					break;
				}
				break;
			}
			dispatch_async(operationQueue, ^{
				HandleClient(clientFD);
			});
		}
	});
	dispatch_source_set_cancel_handler(acceptSource, ^{
		close(serverFD);
		unlink(address.sun_path);
	});
	dispatch_resume(acceptSource);
	WriteHelperStatus([NSString stringWithFormat:@"listening path=%@", PSProxyHelperSocketPath]);
	return YES;
}

static void SyncActiveProfileForNetworkChange(SCDynamicStoreRef store, CFArrayRef changedKeys, void *info) {
	[[PSProxyManager sharedManager] syncActiveProfileWithCurrentSystemProxy:nil];
}

static void StartNetworkChangeListener(void) {
	typedef SCDynamicStoreRef (*SCDynamicStoreCreateFn)(CFAllocatorRef allocator, CFStringRef name, SCDynamicStoreCallBack callout, SCDynamicStoreContext *context);
	typedef Boolean (*SCDynamicStoreSetNotificationKeysFn)(SCDynamicStoreRef store, CFArrayRef keys, CFArrayRef patterns);
	typedef CFRunLoopSourceRef (*SCDynamicStoreCreateRunLoopSourceFn)(CFAllocatorRef allocator, SCDynamicStoreRef store, CFIndex order);
	SCDynamicStoreCreateFn storeCreate = (SCDynamicStoreCreateFn)dlsym(RTLD_DEFAULT, "SCDynamicStoreCreate");
	SCDynamicStoreSetNotificationKeysFn setNotificationKeys = (SCDynamicStoreSetNotificationKeysFn)dlsym(RTLD_DEFAULT, "SCDynamicStoreSetNotificationKeys");
	SCDynamicStoreCreateRunLoopSourceFn createRunLoopSource = (SCDynamicStoreCreateRunLoopSourceFn)dlsym(RTLD_DEFAULT, "SCDynamicStoreCreateRunLoopSource");
	if (!storeCreate || !setNotificationKeys || !createRunLoopSource) {
		return;
	}
	SCDynamicStoreContext context = {0, NULL, NULL, NULL, NULL};
	SCDynamicStoreRef store = storeCreate(NULL, CFSTR("ProxySwitcher"), SyncActiveProfileForNetworkChange, &context);
	if (!store) {
		return;
	}
	NSArray *keys = @[@"State:/Network/Global/IPv4"];
	NSArray *patterns = @[@"State:/Network/Interface/en0/.*", @"State:/Network/Service/.*/IPv4", @"State:/Network/Service/.*/Proxies"];
	if (!setNotificationKeys(store, (__bridge CFArrayRef)keys, (__bridge CFArrayRef)patterns)) {
		CFRelease(store);
		return;
	}
	CFRunLoopSourceRef source = createRunLoopSource(NULL, store, 0);
	if (!source) {
		CFRelease(store);
		return;
	}
	CFRunLoopAddSource(CFRunLoopGetMain(), source, kCFRunLoopCommonModes);
	CFRelease(source);
}

int main(int argc, char *argv[]) {
	@autoreleasepool {
		if (argc >= 2) {
			NSString *command = [NSString stringWithUTF8String:argv[1]];
			if ([command isEqualToString:@"listwifi"]) {
				printf("%s\n", JSONStringForAvailableWiFiNetworks().UTF8String);
				return 0;
			}
			NSString *profileIdentifier = argc >= 3 ? [NSString stringWithUTF8String:argv[2]] : nil;
			NSError *error = nil;
			BOOL ok = RunCommand(command, profileIdentifier, &error);
			if (!ok) {
				fprintf(stderr, "%s\n", (error.localizedDescription ?: @"Unable to update proxy settings.").UTF8String);
				return 1;
			}
			return 0;
		}

		if (!StartSocketServer()) {
			fprintf(stderr, "Unable to start ProxySwitcher socket server.\n");
			return 2;
		}
		[[PSProxyManager sharedManager] syncActiveProfileWithCurrentSystemProxy:nil];
		StartNetworkChangeListener();
		[[NSRunLoop mainRunLoop] run];
	}
	return 0;
}

#import "PSProxyManager.h"
#import <dlfcn.h>
#import <roothide.h>
#import <SystemConfiguration/SystemConfiguration.h>
#import <NetworkExtension/NetworkExtension.h>
#import <notify.h>
#import <spawn.h>
#import <errno.h>
#import <objc/message.h>
#import <string.h>
#import <sys/socket.h>
#import <sys/un.h>
#import <unistd.h>
#import <sys/wait.h>

NSString * const PSProxyDirectIdentifier = @"direct";
NSString * const PSProxyTemporaryIdentifier = @"temporary";
NSString * const PSProxyProfilesChangedNotification = @"codes.var.tweak.proxyswitcher.profiles.changed";
NSString * const PSProxyHelperSocketPath = @"/private/var/mobile/Library/Preferences/codes.var.tweak.proxyswitcher.sock";

static NSString * const PSProfilesKey = @"profiles";
static NSString * const PSActiveIdentifierKey = @"activeIdentifier";
static NSString * const PSTemporaryProfileKey = @"temporaryProfile";
static NSString * const PSLastTemporaryProfileKey = @"lastTemporaryProfile";
static NSString * const PSQuickWiFiSSIDsKey = @"quickWiFiSSIDs";
static NSString * const PSWiFiServiceIdentifiersKey = @"wifiServiceIdentifiers";
static NSString * const PSCompatibilityModeKey = @"compatibilityModeEnabled";
static NSString * const PSPendingAppCommandKey = @"pendingAppCommand";
static NSString * const PSProtocolVersion = @"1";
static NSString * const PSDiagnosticsErrorDomain = @"ProxySwitcher";
static NSString * const PSVPNProxyDescription = @"ProxySwitcher HTTP Proxy";
static NSString * const PSDefaultBundleIdentifier = @"codes.var.tweak.proxyswitcher";

typedef NS_ENUM(NSInteger, PSHelperErrorCode) {
	PSHelperErrorNotInstalled = 10,
	PSHelperErrorOperationFailed = 11,
	PSHelperErrorRequestWriteFailed = 12,
	PSHelperErrorUnreachable = 13,
	PSHelperErrorPathTooLong = 14,
	PSHelperErrorInvalidResponse = 15
};

#ifndef PROXYSWITCHER_HELPER
static const NSTimeInterval PSProxyHelperDefaultTimeout = 20.0;
static const NSUInteger PSProxyHelperMaxResponseLength = 1024 * 1024;
#endif
#if !defined(PROXYSWITCHER_HELPER) && !defined(PROXYSWITCHER_APP_ONLY)
static const NSTimeInterval PSProxyHelperWiFiTimeout = 60.0;
#endif

static NSString *PSRootfsPath(NSString *path) {
	if ([[NSFileManager defaultManager] fileExistsAtPath:[@"/rootfs" stringByAppendingString:path]]) {
		return [@"/rootfs" stringByAppendingString:path];
	}
	return path;
}

#if defined(PROXYSWITCHER_APP_ONLY)
static NSString *PSAppContainerPreferencesPath(NSString *filename) {
	NSArray<NSString *> *libraryPaths = NSSearchPathForDirectoriesInDomains(NSLibraryDirectory, NSUserDomainMask, YES);
	NSString *libraryPath = libraryPaths.firstObject ?: [NSHomeDirectory() stringByAppendingPathComponent:@"Library"];
	NSString *preferencesPath = [libraryPath stringByAppendingPathComponent:@"Preferences"];
	return [preferencesPath stringByAppendingPathComponent:filename];
}
#endif

static NSString *PSStorePath(void) {
#if defined(PROXYSWITCHER_APP_ONLY)
	return PSAppContainerPreferencesPath(@"codes.var.tweak.proxyswitcher.plist");
#else
	return @"/private/var/mobile/Library/Preferences/codes.var.tweak.proxyswitcher.plist";
#endif
}

static NSString *PSLegacyStorePath(void) {
#if defined(PROXYSWITCHER_APP_ONLY)
	return PSAppContainerPreferencesPath(@"com.example.proxyswitcher.plist");
#else
	return @"/private/var/mobile/Library/Preferences/com.example.proxyswitcher.plist";
#endif
}

static NSArray<NSString *> *PSPathCandidates(NSString *path) {
	NSString *rootfsPath = [@"/rootfs" stringByAppendingString:path];
	return @[rootfsPath, path];
}

static NSArray<NSString *> *PSStorePathCandidates(void) {
	return PSPathCandidates(PSStorePath());
}

static NSArray<NSString *> *PSLegacyStorePathCandidates(void) {
	return PSPathCandidates(PSLegacyStorePath());
}

static void PSMigrateLegacyStoreIfNeeded(void) {
	NSFileManager *fileManager = [NSFileManager defaultManager];
	for (NSString *storePath in PSStorePathCandidates()) {
		if ([fileManager fileExistsAtPath:storePath]) {
			return;
		}
	}
	NSString *legacyPath = nil;
	for (NSString *candidate in PSLegacyStorePathCandidates()) {
		if ([fileManager fileExistsAtPath:candidate]) {
			legacyPath = candidate;
			break;
		}
	}
	if (legacyPath.length == 0) {
		return;
	}
	for (NSString *storePath in PSStorePathCandidates()) {
		NSString *directory = [storePath stringByDeletingLastPathComponent];
		[fileManager createDirectoryAtPath:directory withIntermediateDirectories:YES attributes:nil error:nil];
		if ([fileManager copyItemAtPath:legacyPath toPath:storePath error:nil]) {
			return;
		}
	}
}

static NSString *PSKnownNetworksPath(void) {
	return PSRootfsPath(@"/var/preferences/com.apple.wifi.known-networks.plist");
}

static id PSPropertyListAtPath(NSString *path, NSPropertyListMutabilityOptions options) {
	NSData *data = [NSData dataWithContentsOfFile:path];
	if (!data) {
		return nil;
	}
	return [NSPropertyListSerialization propertyListWithData:data options:options format:nil error:nil];
}

static BOOL PSWritePropertyList(id plist, NSString *path) {
	NSData *data = [NSPropertyListSerialization dataWithPropertyList:plist format:NSPropertyListBinaryFormat_v1_0 options:0 error:nil];
	return data ? [data writeToFile:path atomically:YES] : NO;
}

static NSString *PSStringFromSSIDData(NSData *data) {
	if (![data isKindOfClass:NSData.class] || data.length == 0) {
		return nil;
	}
	NSString *ssid = [[NSString alloc] initWithData:data encoding:NSUTF8StringEncoding];
	return ssid.length > 0 ? ssid : nil;
}

static NSString *PSSSIDFromKnownNetworkKey(NSString *key) {
	static NSString *prefix = @"wifi.network.ssid.";
	return [key hasPrefix:prefix] ? [key substringFromIndex:prefix.length] : key;
}

static PSProxyProfile *PSProxyProfileFromSystemDictionary(NSDictionary *dictionary, NSString *name) {
	if (![dictionary isKindOfClass:NSDictionary.class]) {
		return nil;
	}
	NSString *type = [dictionary[@"ProxyType"] isKindOfClass:NSString.class] ? dictionary[@"ProxyType"] : nil;
	NSString *host = [dictionary[@"ProxyServer"] isKindOfClass:NSString.class] ? dictionary[@"ProxyServer"] : nil;
	id portObject = dictionary[@"ProxyServerPort"];
	if (![type isEqualToString:@"Manual"] || host.length == 0 || ![portObject respondsToSelector:@selector(integerValue)]) {
		return nil;
	}
	NSInteger port = [portObject integerValue];
	if (port < 1 || port > 65535) {
		return nil;
	}
	PSProxyProfile *profile = [[PSProxyProfile alloc] init];
	profile.identifier = PSProxyTemporaryIdentifier;
	profile.name = name.length > 0 ? name : [NSString stringWithFormat:@"%@:%ld", host, (long)port];
	profile.host = host;
	profile.port = port;
	profile.username = [dictionary[@"ProxyUsername"] isKindOfClass:NSString.class] ? dictionary[@"ProxyUsername"] : nil;
	profile.password = [dictionary[@"ProxyPassword"] isKindOfClass:NSString.class] ? dictionary[@"ProxyPassword"] : nil;
	return profile;
}

static PSProxyProfile *PSProxyProfileFromSCProxiesDictionary(NSDictionary *dictionary, NSString *name) {
	if (![dictionary isKindOfClass:NSDictionary.class] || ![dictionary[@"HTTPEnable"] boolValue]) {
		return nil;
	}
	NSString *host = [dictionary[@"HTTPProxy"] isKindOfClass:NSString.class] ? dictionary[@"HTTPProxy"] : nil;
	id portObject = dictionary[@"HTTPPort"];
	if (host.length == 0 || ![portObject respondsToSelector:@selector(integerValue)]) {
		return nil;
	}
	NSInteger port = [portObject integerValue];
	if (port < 1 || port > 65535) {
		return nil;
	}
	PSProxyProfile *profile = [[PSProxyProfile alloc] init];
	profile.identifier = PSProxyTemporaryIdentifier;
	profile.name = name.length > 0 ? name : [NSString stringWithFormat:@"%@:%ld", host, (long)port];
	profile.host = host;
	profile.port = port;
	return profile;
}

#if !defined(PROXYSWITCHER_APP_ONLY) && !defined(PROXYSWITCHER_HELPER)
static BOOL PSProxyProfilesEqual(PSProxyProfile *lhs, PSProxyProfile *rhs) {
	if (!lhs || !rhs) {
		return NO;
	}
	BOOL usernameEqual = (lhs.username.length == 0 && rhs.username.length == 0) || [lhs.username isEqualToString:rhs.username];
	BOOL passwordEqual = (lhs.password.length == 0 && rhs.password.length == 0) || [lhs.password isEqualToString:rhs.password];
	return [lhs.host isEqualToString:rhs.host] && lhs.port == rhs.port && usernameEqual && passwordEqual;
}
#endif

#ifdef PROXYSWITCHER_APP_CLIENT
static NSString *PSMainBundleIdentifier(void) {
	NSString *bundleIdentifier = [NSBundle mainBundle].bundleIdentifier;
	if (bundleIdentifier.length > 0) {
		NSString *lower = bundleIdentifier.lowercaseString;
		if ([lower hasSuffix:@".cc"] || [lower hasSuffix:@".controlcenter"] || [lower containsString:@"controlcenter"]) {
			return PSDefaultBundleIdentifier;
		}
		return bundleIdentifier;
	}
	return PSDefaultBundleIdentifier;
}
#endif

#ifdef PROXYSWITCHER_APP_CLIENT
static BOOL PSWaitForCondition(NSTimeInterval timeout, BOOL (^condition)(void)) {
	if (!condition) {
		return NO;
	}
	NSDate *deadline = [NSDate dateWithTimeIntervalSinceNow:timeout];
	while ([deadline timeIntervalSinceNow] > 0) {
		if (condition()) {
			return YES;
		}
		[[NSRunLoop currentRunLoop] runMode:NSDefaultRunLoopMode beforeDate:[NSDate dateWithTimeIntervalSinceNow:0.05]];
	}
	return condition();
}
#endif

#ifdef PROXYSWITCHER_APP_CLIENT
static void PSNormalizeAndApplyProxyExceptions(NEProxySettings *proxySettings, NSArray<NSString *> *noProxy) {
	if (![proxySettings isKindOfClass:NEProxySettings.class] || noProxy.count == 0) {
		return;
	}
	NSMutableArray<NSString *> *exceptions = [NSMutableArray array];
	for (NSString *entry in noProxy) {
		if (![entry isKindOfClass:NSString.class]) {
			continue;
		}
		NSString *trimmed = [entry stringByTrimmingCharactersInSet:NSCharacterSet.whitespaceAndNewlineCharacterSet];
		if (trimmed.length > 0) {
			[exceptions addObject:trimmed];
		}
	}
	if (exceptions.count > 0) {
		proxySettings.exceptionList = exceptions.copy;
	}
}
#endif

#if !defined(PROXYSWITCHER_HELPER) && !defined(PROXYSWITCHER_APP_ONLY)
static BOOL PSIsHelperUnreachableError(NSError *error) {
	return [error.domain isEqualToString:PSDiagnosticsErrorDomain] && error.code == PSHelperErrorUnreachable;
}
#endif

#ifndef PROXYSWITCHER_HELPER
static NSString *PSHelperPath(void) {
#ifdef THEOS_PACKAGE_SCHEME_ROOTHIDE
	return jbroot(@"/usr/bin/proxyswitcherctl");
#else
	return @"/usr/bin/proxyswitcherctl";
#endif
}

static NSString *PSHelperSocketPath(void) {
	return PSProxyHelperSocketPath;
}

static NSArray<NSString *> *PSHelperSocketPathCandidates(void) {
	return PSPathCandidates(PSHelperSocketPath());
}
#endif

typedef CFTypeRef (*PSDStoreCreateFn)(CFAllocatorRef allocator, CFStringRef name, void *callback, void *context);
typedef CFPropertyListRef (*PSDStoreCopyValueFn)(CFTypeRef store, CFStringRef key);
typedef CFArrayRef (*PSDStoreCopyKeyListFn)(CFTypeRef store, CFStringRef pattern);
typedef CFTypeRef (*PSPrefsCreateFn)(CFAllocatorRef allocator, CFStringRef name, CFStringRef prefsID);
typedef CFArrayRef (*PSServiceCopyAllFn)(CFTypeRef prefs);
typedef CFStringRef (*PSServiceGetServiceIDFn)(CFTypeRef service);
typedef CFTypeRef (*PSServiceCopyProtocolFn)(CFTypeRef service, CFStringRef protocolType);
typedef CFDictionaryRef (*PSProtocolGetConfigurationFn)(CFTypeRef protocol);
typedef Boolean (*PSProtocolSetConfigurationFn)(CFTypeRef protocol, CFDictionaryRef configuration);
typedef Boolean (*PSProtocolSetEnabledFn)(CFTypeRef protocol, Boolean enabled);
typedef Boolean (*PSPrefsCommitChangesFn)(CFTypeRef prefs);
typedef Boolean (*PSPrefsApplyChangesFn)(CFTypeRef prefs);
typedef Boolean (*PSPrefsLockFn)(CFTypeRef prefs, Boolean wait);
typedef Boolean (*PSPrefsUnlockFn)(CFTypeRef prefs);

static void *PSSystemConfigurationSymbol(const char *name) {
	return dlsym(RTLD_DEFAULT, name);
}

static void *PSMobileWiFiSymbol(const char *name) {
	static void *handle;
	static dispatch_once_t onceToken;
	dispatch_once(&onceToken, ^{
		handle = dlopen("/System/Library/PrivateFrameworks/MobileWiFi.framework/MobileWiFi", RTLD_LAZY);
	});
	return handle ? dlsym(handle, name) : NULL;
}

#ifdef PROXYSWITCHER_HELPER
static BOOL PSSwitchToWiFiSSIDUsingCoreWiFi(NSString *ssid, NSError **error) {
	dlopen("/System/Library/PrivateFrameworks/CoreWiFi.framework/CoreWiFi", RTLD_LAZY);
	Class interfaceClass = NSClassFromString(@"CWFInterface");
	Class autoJoinParametersClass = NSClassFromString(@"CWFAutoJoinParameters");
	Class assocParametersClass = NSClassFromString(@"CWFAssocParameters");
	if (!interfaceClass || !autoJoinParametersClass) {
		return NO;
	}

	id interface = ((id (*)(id, SEL))objc_msgSend)(((id (*)(id, SEL))objc_msgSend)(interfaceClass, @selector(alloc)), @selector(init));
	if (!interface) {
		return NO;
	}
	if ([interface respondsToSelector:@selector(activate)]) {
		((void (*)(id, SEL))objc_msgSend)(interface, @selector(activate));
	}

	NSArray *profiles = nil;
	if ([interface respondsToSelector:@selector(knownNetworkProfilesWithProperties:)]) {
		profiles = ((id (*)(id, SEL, id))objc_msgSend)(interface, @selector(knownNetworkProfilesWithProperties:), nil);
	}
	id targetProfile = nil;
	for (id profile in profiles) {
		NSString *profileSSID = nil;
		if ([profile respondsToSelector:@selector(SSID)]) {
			profileSSID = ((id (*)(id, SEL))objc_msgSend)(profile, @selector(SSID));
		}
		if (profileSSID.length == 0 && [profile respondsToSelector:@selector(ssid)]) {
			profileSSID = ((id (*)(id, SEL))objc_msgSend)(profile, @selector(ssid));
		}
		if ([profileSSID isEqualToString:ssid]) {
			targetProfile = profile;
			break;
		}
	}
	if (!targetProfile) {
		return NO;
	}

	NSError *joinError = nil;
	id autoJoinParameters = ((id (*)(id, SEL))objc_msgSend)(((id (*)(id, SEL))objc_msgSend)(autoJoinParametersClass, @selector(alloc)), @selector(init));
	if ([autoJoinParameters respondsToSelector:@selector(setTargetNetworkProfile:)]) {
		((void (*)(id, SEL, id))objc_msgSend)(autoJoinParameters, @selector(setTargetNetworkProfile:), targetProfile);
	}
	if ([autoJoinParameters respondsToSelector:@selector(setMode:)]) {
		((void (*)(id, SEL, NSInteger))objc_msgSend)(autoJoinParameters, @selector(setMode:), 1);
	}
	if ([autoJoinParameters respondsToSelector:@selector(setTrigger:)]) {
		((void (*)(id, SEL, NSInteger))objc_msgSend)(autoJoinParameters, @selector(setTrigger:), 1);
	}
	if ([interface respondsToSelector:@selector(performAutoJoinWithParameters:error:)]) {
		BOOL ok = ((BOOL (*)(id, SEL, id, NSError **))objc_msgSend)(interface, @selector(performAutoJoinWithParameters:error:), autoJoinParameters, &joinError);
		if (ok) {
			return YES;
		}
	}

	if (assocParametersClass && [interface respondsToSelector:@selector(associateWithParameters:error:)]) {
		id assocParameters = ((id (*)(id, SEL))objc_msgSend)(((id (*)(id, SEL))objc_msgSend)(assocParametersClass, @selector(alloc)), @selector(init));
		if ([assocParameters respondsToSelector:@selector(setKnownNetworkProfile:)]) {
			((void (*)(id, SEL, id))objc_msgSend)(assocParameters, @selector(setKnownNetworkProfile:), targetProfile);
		}
		BOOL ok = ((BOOL (*)(id, SEL, id, NSError **))objc_msgSend)(interface, @selector(associateWithParameters:error:), assocParameters, &joinError);
		if (ok) {
			return YES;
		}
	}

	if (error && joinError) {
		*error = joinError;
	}
	return NO;
}
#endif

#ifdef PROXYSWITCHER_HELPER
static void PSWiFiWaitCallback(SCDynamicStoreRef store, CFArrayRef changedKeys, void *info) {
	NSMutableDictionary *state = (__bridge NSMutableDictionary *)info;
	NSString *targetSSID = state[@"targetSSID"];
	if (targetSSID.length == 0) {
		return;
	}
	if ([[[PSProxyManager sharedManager] currentWiFiSSID] isEqualToString:targetSSID]) {
		state[@"matched"] = @YES;
		NSValue *runLoopValue = state[@"runLoop"];
		CFRunLoopRef runLoop = runLoopValue ? (CFRunLoopRef)runLoopValue.pointerValue : NULL;
		if (runLoop) {
			CFRunLoopStop(runLoop);
		}
	}
}

static BOOL PSWaitForWiFiSSID(NSString *ssid, NSTimeInterval timeout) {
	typedef SCDynamicStoreRef (*PSDStoreCreateCallbackFn)(CFAllocatorRef allocator, CFStringRef name, SCDynamicStoreCallBack callout, SCDynamicStoreContext *context);
	typedef Boolean (*PSDStoreSetNotificationKeysFn)(SCDynamicStoreRef store, CFArrayRef keys, CFArrayRef patterns);
	typedef CFRunLoopSourceRef (*PSDStoreCreateRunLoopSourceFn)(CFAllocatorRef allocator, SCDynamicStoreRef store, CFIndex order);
	PSDStoreCreateCallbackFn storeCreate = (PSDStoreCreateCallbackFn)dlsym(RTLD_DEFAULT, "SCDynamicStoreCreate");
	PSDStoreSetNotificationKeysFn setNotificationKeys = (PSDStoreSetNotificationKeysFn)dlsym(RTLD_DEFAULT, "SCDynamicStoreSetNotificationKeys");
	PSDStoreCreateRunLoopSourceFn createRunLoopSource = (PSDStoreCreateRunLoopSourceFn)dlsym(RTLD_DEFAULT, "SCDynamicStoreCreateRunLoopSource");
	if (!storeCreate || !setNotificationKeys || !createRunLoopSource) {
		return NO;
	}
	if ([[[PSProxyManager sharedManager] currentWiFiSSID] isEqualToString:ssid]) {
		return YES;
	}
	NSMutableDictionary *state = [@{
		@"targetSSID": ssid,
		@"matched": @NO,
		@"runLoop": [NSValue valueWithPointer:CFRunLoopGetCurrent()]
	} mutableCopy];
	SCDynamicStoreContext context = {0, (__bridge void *)state, NULL, NULL, NULL};
	SCDynamicStoreRef store = storeCreate(NULL, CFSTR("ProxySwitcherWiFiWait"), PSWiFiWaitCallback, &context);
	if (!store) {
		return NO;
	}
	NSArray *keys = @[@"State:/Network/Global/IPv4"];
	NSArray *patterns = @[@"State:/Network/Interface/en0/.*", @"State:/Network/Service/.*/IPv4", @"State:/Network/Service/.*/Proxies"];
	if (!setNotificationKeys(store, (__bridge CFArrayRef)keys, (__bridge CFArrayRef)patterns)) {
		CFRelease(store);
		return NO;
	}
	CFRunLoopSourceRef source = createRunLoopSource(NULL, store, 0);
	if (!source) {
		CFRelease(store);
		return NO;
	}
	CFRunLoopAddSource(CFRunLoopGetCurrent(), source, kCFRunLoopDefaultMode);
	NSDate *deadline = [NSDate dateWithTimeIntervalSinceNow:timeout];
	while (![state[@"matched"] boolValue]) {
		NSTimeInterval remaining = [deadline timeIntervalSinceNow];
		if (remaining <= 0) {
			break;
		}
		CFRunLoopRunInMode(kCFRunLoopDefaultMode, remaining, true);
		if ([[[PSProxyManager sharedManager] currentWiFiSSID] isEqualToString:ssid]) {
			state[@"matched"] = @YES;
		}
	}
	CFRunLoopRemoveSource(CFRunLoopGetCurrent(), source, kCFRunLoopDefaultMode);
	CFRelease(source);
	CFRelease(store);
	return [state[@"matched"] boolValue];
}
#endif

@implementation PSProxyProfile

+ (BOOL)supportsSecureCoding {
	return YES;
}

- (instancetype)init {
	self = [super init];
	if (self) {
		_identifier = [NSUUID UUID].UUIDString;
		_name = @"Proxy";
		_host = @"";
		_port = 8080;
	}
	return self;
}

- (instancetype)initWithCoder:(NSCoder *)coder {
	self = [super init];
	if (self) {
		_identifier = [coder decodeObjectOfClass:NSString.class forKey:@"identifier"] ?: [NSUUID UUID].UUIDString;
		_name = [coder decodeObjectOfClass:NSString.class forKey:@"name"] ?: @"Proxy";
		_host = [coder decodeObjectOfClass:NSString.class forKey:@"host"] ?: @"";
		_port = [coder decodeIntegerForKey:@"port"];
		_username = [coder decodeObjectOfClass:NSString.class forKey:@"username"];
		_password = [coder decodeObjectOfClass:NSString.class forKey:@"password"];
		_noProxy = [coder decodeObjectOfClass:NSArray.class forKey:@"noProxy"];
	}
	return self;
}

- (void)encodeWithCoder:(NSCoder *)coder {
	[coder encodeObject:self.identifier forKey:@"identifier"];
	[coder encodeObject:self.name forKey:@"name"];
	[coder encodeObject:self.host forKey:@"host"];
	[coder encodeInteger:self.port forKey:@"port"];
	[coder encodeObject:self.username forKey:@"username"];
	[coder encodeObject:self.password forKey:@"password"];
	[coder encodeObject:self.noProxy forKey:@"noProxy"];
}

- (NSDictionary *)dictionaryRepresentation {
	NSMutableDictionary *dictionary = [NSMutableDictionary dictionary];
	dictionary[@"identifier"] = self.identifier ?: [NSUUID UUID].UUIDString;
	dictionary[@"name"] = self.name ?: @"Proxy";
	dictionary[@"host"] = self.host ?: @"";
	dictionary[@"port"] = @(self.port);
	if (self.username.length > 0) {
		dictionary[@"username"] = self.username;
	}
	if (self.password.length > 0) {
		dictionary[@"password"] = self.password;
	}
	if (self.noProxy.count > 0) {
		dictionary[@"noProxy"] = self.noProxy;
	}
	return dictionary;
}

+ (instancetype)profileWithDictionary:(NSDictionary *)dictionary {
	if (![dictionary isKindOfClass:NSDictionary.class]) {
		return nil;
	}
	PSProxyProfile *profile = [[PSProxyProfile alloc] init];
	profile.identifier = [dictionary[@"identifier"] isKindOfClass:NSString.class] ? dictionary[@"identifier"] : [NSUUID UUID].UUIDString;
	profile.name = [dictionary[@"name"] isKindOfClass:NSString.class] ? dictionary[@"name"] : @"Proxy";
	profile.host = [dictionary[@"host"] isKindOfClass:NSString.class] ? dictionary[@"host"] : @"";
	profile.port = [dictionary[@"port"] respondsToSelector:@selector(integerValue)] ? [dictionary[@"port"] integerValue] : 8080;
	profile.username = [dictionary[@"username"] isKindOfClass:NSString.class] ? dictionary[@"username"] : nil;
	profile.password = [dictionary[@"password"] isKindOfClass:NSString.class] ? dictionary[@"password"] : nil;
	NSArray *rawNoProxy = [dictionary[@"noProxy"] isKindOfClass:NSArray.class] ? dictionary[@"noProxy"] : nil;
	if (rawNoProxy) {
		NSMutableArray<NSString *> *normalized = [NSMutableArray array];
		for (id value in rawNoProxy) {
			if (![value isKindOfClass:NSString.class]) {
				continue;
			}
			NSString *trimmed = [(NSString *)value stringByTrimmingCharactersInSet:NSCharacterSet.whitespaceAndNewlineCharacterSet];
			if (trimmed.length > 0) {
				[normalized addObject:trimmed];
			}
		}
		profile.noProxy = normalized.copy;
	}
	if (profile.host.length == 0 || profile.port < 1 || profile.port > 65535) {
		return nil;
	}
	return profile;
}

@end

@implementation PSWiFiNetwork
@end

@implementation PSProxyManager

+ (instancetype)sharedManager {
	static PSProxyManager *manager;
	static dispatch_once_t onceToken;
	dispatch_once(&onceToken, ^{
		manager = [[PSProxyManager alloc] init];
	});
	return manager;
}

- (BOOL)dispatchHelperCommand:(NSArray<NSString *> *)arguments error:(NSError **)error {
#ifdef PROXYSWITCHER_HELPER
	#pragma unused(arguments)
	if (error) {
		*error = [NSError errorWithDomain:@"ProxySwitcher" code:730 userInfo:@{NSLocalizedDescriptionKey: @"Helper cannot recursively dispatch helper command."}];
	}
	return NO;
#else
	return [self runHelperWithArguments:arguments error:error];
#endif
}

#include "PSProxyManager+Store.inc"
#include "PSProxyManager+VPNMode.inc"
#include "PSProxyManager+Actions.inc"
#ifndef PROXYSWITCHER_HELPER
#include "PSProxyManager+HelperIPC.inc"
#endif
#include "PSProxyManager+System.inc"
@end

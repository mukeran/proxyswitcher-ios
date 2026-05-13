#import "PSProxyManager.h"
#import <dlfcn.h>
#import <roothide.h>
#import <SystemConfiguration/SystemConfiguration.h>
#import <notify.h>
#import <spawn.h>
#import <errno.h>
#import <objc/message.h>
#import <string.h>
#import <sys/wait.h>

NSString * const PSProxyDirectIdentifier = @"direct";
NSString * const PSProxyTemporaryIdentifier = @"temporary";
NSString * const PSProxyProfilesChangedNotification = @"codes.var.tweak.proxyswitcher.profiles.changed";
NSString * const PSProxyRequestNotification = @"codes.var.tweak.proxyswitcher.request";

static NSString * const PSProfilesKey = @"profiles";
static NSString * const PSActiveIdentifierKey = @"activeIdentifier";
static NSString * const PSTemporaryProfileKey = @"temporaryProfile";
static NSString * const PSQuickWiFiSSIDsKey = @"quickWiFiSSIDs";

static NSString *PSRootfsPath(NSString *path) {
	if ([[NSFileManager defaultManager] fileExistsAtPath:[@"/rootfs" stringByAppendingString:path]]) {
		return [@"/rootfs" stringByAppendingString:path];
	}
	return path;
}

static NSString *PSStorePath(void) {
	return @"/private/var/mobile/Library/Preferences/codes.var.tweak.proxyswitcher.plist";
}

static NSString *PSLegacyStorePath(void) {
	return @"/private/var/mobile/Library/Preferences/com.example.proxyswitcher.plist";
}

static void PSMigrateLegacyStoreIfNeeded(void) {
	NSFileManager *fileManager = [NSFileManager defaultManager];
	NSString *storePath = PSStorePath();
	if ([fileManager fileExistsAtPath:storePath]) {
		return;
	}
	NSString *legacyPath = PSLegacyStorePath();
	if (![fileManager fileExistsAtPath:legacyPath]) {
		return;
	}
	[fileManager copyItemAtPath:legacyPath toPath:storePath error:nil];
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

static BOOL PSProxyProfilesEqual(PSProxyProfile *lhs, PSProxyProfile *rhs) {
	if (!lhs || !rhs) {
		return NO;
	}
	BOOL usernameEqual = (lhs.username.length == 0 && rhs.username.length == 0) || [lhs.username isEqualToString:rhs.username];
	BOOL passwordEqual = (lhs.password.length == 0 && rhs.password.length == 0) || [lhs.password isEqualToString:rhs.password];
	return [lhs.host isEqualToString:rhs.host] && lhs.port == rhs.port && usernameEqual && passwordEqual;
}

#ifndef PROXYSWITCHER_HELPER
static NSString *PSJailbreakPath(NSString *path) {
#ifdef THEOS_PACKAGE_SCHEME_ROOTHIDE
	return jbroot(path);
#else
	return path;
#endif
}

static NSString *PSRequestPath(void) {
	return PSJailbreakPath(@"/var/mobile/Library/Preferences/codes.var.tweak.proxyswitcher.request");
}

static NSString *PSResponsePath(void) {
	return PSJailbreakPath(@"/var/mobile/Library/Preferences/codes.var.tweak.proxyswitcher.response");
}

static NSString *PSHelperPath(void) {
	return PSJailbreakPath(@"/usr/bin/proxyswitcherctl");
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

- (NSDictionary *)storeDictionary {
	PSMigrateLegacyStoreIfNeeded();
	NSDictionary *dictionary = [NSDictionary dictionaryWithContentsOfFile:PSStorePath()];
	return [dictionary isKindOfClass:NSDictionary.class] ? dictionary : @{};
}

- (BOOL)writeStoreDictionary:(NSDictionary *)dictionary {
	NSString *path = PSStorePath();
	NSString *directory = [path stringByDeletingLastPathComponent];
	[[NSFileManager defaultManager] createDirectoryAtPath:directory withIntermediateDirectories:YES attributes:nil error:nil];
	BOOL ok = [dictionary writeToFile:path atomically:YES];
	if (ok) {
		notify_post(PSProxyProfilesChangedNotification.UTF8String);
	}
	return ok;
}

- (NSArray<PSProxyProfile *> *)profiles {
	NSArray *rawProfiles = [self storeDictionary][PSProfilesKey];
	if (![rawProfiles isKindOfClass:NSArray.class]) {
		return @[];
	}
	NSMutableArray<PSProxyProfile *> *profiles = [NSMutableArray array];
	for (NSDictionary *dictionary in rawProfiles) {
		PSProxyProfile *profile = [PSProxyProfile profileWithDictionary:dictionary];
		if (profile) {
			[profiles addObject:profile];
		}
	}
	return profiles.copy;
}

- (PSProxyProfile *)profileWithIdentifier:(NSString *)identifier {
	for (PSProxyProfile *profile in [self profiles]) {
		if ([profile.identifier isEqualToString:identifier]) {
			return profile;
		}
	}
	return nil;
}

- (void)saveProfile:(PSProxyProfile *)profile {
	NSMutableDictionary *store = [self storeDictionary].mutableCopy;
	NSMutableArray *rawProfiles = [[store[PSProfilesKey] isKindOfClass:NSArray.class] ? store[PSProfilesKey] : @[] mutableCopy];
	BOOL replaced = NO;
	for (NSUInteger index = 0; index < rawProfiles.count; index++) {
		NSDictionary *dictionary = rawProfiles[index];
		if ([[dictionary objectForKey:@"identifier"] isEqualToString:profile.identifier]) {
			rawProfiles[index] = [profile dictionaryRepresentation];
			replaced = YES;
			break;
		}
	}
	if (!replaced) {
		[rawProfiles addObject:[profile dictionaryRepresentation]];
	}
	store[PSProfilesKey] = rawProfiles;
	[self writeStoreDictionary:store];
}

- (void)deleteProfileWithIdentifier:(NSString *)identifier {
	NSMutableDictionary *store = [self storeDictionary].mutableCopy;
	NSArray *rawProfiles = [store[PSProfilesKey] isKindOfClass:NSArray.class] ? store[PSProfilesKey] : @[];
	NSMutableArray *remaining = [NSMutableArray array];
	for (NSDictionary *dictionary in rawProfiles) {
		if (![[dictionary objectForKey:@"identifier"] isEqualToString:identifier]) {
			[remaining addObject:dictionary];
		}
	}
	store[PSProfilesKey] = remaining;
	if ([[store objectForKey:PSActiveIdentifierKey] isEqualToString:identifier]) {
		store[PSActiveIdentifierKey] = PSProxyDirectIdentifier;
	}
	[self writeStoreDictionary:store];
}

- (NSString *)activeIdentifier {
	NSString *identifier = [self storeDictionary][PSActiveIdentifierKey];
	if (!identifier) {
		identifier = [self storeDictionary][@"ActiveIdentifier"];
	}
	return identifier ?: PSProxyDirectIdentifier;
}

- (NSString *)lastActiveProfileIdentifier {
	return [self storeDictionary][@"LastActiveProfileIdentifier"];
}

- (PSProxyProfile *)temporaryProfile {
	NSDictionary *dictionary = [self storeDictionary][PSTemporaryProfileKey];
	return [dictionary isKindOfClass:NSDictionary.class] ? [PSProxyProfile profileWithDictionary:dictionary] : nil;
}

- (void)setActiveIdentifier:(NSString *)identifier {
	NSMutableDictionary *store = [self storeDictionary].mutableCopy;
	store[PSActiveIdentifierKey] = identifier;
	[store removeObjectForKey:@"ActiveIdentifier"];
	if (![identifier isEqualToString:PSProxyTemporaryIdentifier]) {
		[store removeObjectForKey:PSTemporaryProfileKey];
	}
	if (identifier && ![identifier isEqualToString:PSProxyDirectIdentifier] && ![identifier isEqualToString:PSProxyTemporaryIdentifier]) {
		store[@"LastActiveProfileIdentifier"] = identifier;
	}
	[self writeStoreDictionary:store];
}

- (void)setTemporaryProfile:(PSProxyProfile *)profile {
	NSMutableDictionary *store = [self storeDictionary].mutableCopy;
	if (profile) {
		store[PSTemporaryProfileKey] = [profile dictionaryRepresentation];
		store[PSActiveIdentifierKey] = PSProxyTemporaryIdentifier;
		[store removeObjectForKey:@"ActiveIdentifier"];
	} else {
		[store removeObjectForKey:PSTemporaryProfileKey];
	}
	[self writeStoreDictionary:store];
}

- (NSString *)nextIdentifierAfterActive {
	NSArray<PSProxyProfile *> *profiles = [self profiles];
	if (profiles.count == 0) {
		return PSProxyDirectIdentifier;
	}
	NSString *active = [self activeIdentifier];
	if ([active isEqualToString:PSProxyDirectIdentifier]) {
		return profiles.firstObject.identifier;
	}
	for (NSUInteger index = 0; index < profiles.count; index++) {
		if ([profiles[index].identifier isEqualToString:active]) {
			NSUInteger next = index + 1;
			return next < profiles.count ? profiles[next].identifier : PSProxyDirectIdentifier;
		}
	}
	return profiles.firstObject.identifier;
}

- (NSString *)currentSetNameFromSystemPreferences {
	NSDictionary *preferences = PSPropertyListAtPath(PSRootfsPath(@"/var/preferences/SystemConfiguration/preferences.plist"), NSPropertyListImmutable);
	NSString *currentSet = [preferences[@"CurrentSet"] isKindOfClass:NSString.class] ? preferences[@"CurrentSet"] : nil;
	NSArray<NSString *> *parts = [currentSet componentsSeparatedByString:@"/"];
	NSString *setIdentifier = parts.lastObject;
	if (setIdentifier.length == 0) {
		return nil;
	}
	NSDictionary *sets = [preferences[@"Sets"] isKindOfClass:NSDictionary.class] ? preferences[@"Sets"] : nil;
	NSDictionary *set = [sets[setIdentifier] isKindOfClass:NSDictionary.class] ? sets[setIdentifier] : nil;
	NSString *name = [set[@"UserDefinedName"] isKindOfClass:NSString.class] ? set[@"UserDefinedName"] : nil;
	return name.length > 0 ? name : nil;
}

- (void)updateKnownNetworkProxyForProfile:(PSProxyProfile *)profile {
	NSString *networkName = [self currentSetNameFromSystemPreferences];
	NSString *path = PSKnownNetworksPath();
	NSMutableDictionary *knownNetworks = PSPropertyListAtPath(path, NSPropertyListMutableContainers);
	if (![knownNetworks isKindOfClass:NSMutableDictionary.class]) {
		return;
	}
	NSString *networkKey = networkName.length > 0 ? [@"wifi.network.ssid." stringByAppendingString:networkName] : nil;
	if (![knownNetworks[networkKey] isKindOfClass:NSDictionary.class]) {
		NSDate *latestDate = nil;
		NSString *latestKey = nil;
		for (NSString *key in knownNetworks) {
			NSDictionary *candidate = [knownNetworks[key] isKindOfClass:NSDictionary.class] ? knownNetworks[key] : nil;
			NSDate *joinedAt = [candidate[@"JoinedBySystemAt"] isKindOfClass:NSDate.class] ? candidate[@"JoinedBySystemAt"] : nil;
			if ([key hasPrefix:@"wifi.network.ssid."] && joinedAt && (!latestDate || [joinedAt compare:latestDate] == NSOrderedDescending)) {
				latestDate = joinedAt;
				latestKey = key;
			}
		}
		networkKey = latestKey;
	}
	NSMutableDictionary *network = [knownNetworks[networkKey] isKindOfClass:NSDictionary.class] ? [knownNetworks[networkKey] mutableCopy] : nil;
	if (!network) {
		return;
	}

	[network removeObjectsForKeys:@[
		@"ProxyType",
		@"ProxyServer",
		@"ProxyServerPort",
		@"ProxyUsername",
		@"ProxyPassword",
		@"ProxyPACURL"
	]];
	if (profile) {
		network[@"ProxyType"] = @"Manual";
		network[@"ProxyServer"] = profile.host;
		network[@"ProxyServerPort"] = @(profile.port);
		if (profile.username.length > 0) {
			network[@"ProxyUsername"] = profile.username;
		}
		if (profile.password.length > 0) {
			network[@"ProxyPassword"] = profile.password;
		}
	}
	knownNetworks[networkKey] = network;
	PSWritePropertyList(knownNetworks, path);
}

- (NSArray<PSWiFiNetwork *> *)knownWiFiNetworks {
	NSDictionary *knownNetworks = PSPropertyListAtPath(PSKnownNetworksPath(), NSPropertyListImmutable);
	if (![knownNetworks isKindOfClass:NSDictionary.class]) {
		return @[];
	}
	NSString *currentSSID = [self currentWiFiSSID];
	NSMutableArray<PSWiFiNetwork *> *networks = [NSMutableArray array];
	for (NSString *key in knownNetworks) {
		NSDictionary *dictionary = [knownNetworks[key] isKindOfClass:NSDictionary.class] ? knownNetworks[key] : nil;
		if (!dictionary) {
			continue;
		}
		NSString *ssid = PSStringFromSSIDData(dictionary[@"SSID"]) ?: PSSSIDFromKnownNetworkKey(key);
		if (ssid.length == 0) {
			continue;
		}
		PSWiFiNetwork *network = [[PSWiFiNetwork alloc] init];
		network.ssid = ssid;
		network.displayName = ssid;
		network.proxyProfile = PSProxyProfileFromSystemDictionary(dictionary, ssid);
		network.current = [ssid isEqualToString:currentSSID];
		[networks addObject:network];
	}
	[networks sortUsingComparator:^NSComparisonResult(PSWiFiNetwork *first, PSWiFiNetwork *second) {
		if (first.current != second.current) {
			return first.current ? NSOrderedAscending : NSOrderedDescending;
		}
		return [first.displayName localizedCaseInsensitiveCompare:second.displayName];
	}];
	return networks.copy;
}

- (NSArray<PSWiFiNetwork *> *)availableWiFiNetworks {
#ifdef PROXYSWITCHER_HELPER
	return [self knownWiFiNetworks];
#else
	__autoreleasing NSString *response = nil;
	NSError *error = nil;
	if (![self runHelperWithArguments:@[@"listwifi"] response:&response error:&error] || response.length == 0) {
		return @[];
	}
	NSData *data = [response dataUsingEncoding:NSUTF8StringEncoding];
	NSArray *rawNetworks = data ? [NSJSONSerialization JSONObjectWithData:data options:0 error:nil] : nil;
	if (![rawNetworks isKindOfClass:NSArray.class]) {
		return @[];
	}
	NSString *currentSSID = [self currentWiFiSSID];
	NSMutableArray<PSWiFiNetwork *> *networks = [NSMutableArray array];
	for (NSDictionary *dictionary in rawNetworks) {
		if (![dictionary isKindOfClass:NSDictionary.class]) {
			continue;
		}
		NSString *ssid = [dictionary[@"ssid"] isKindOfClass:NSString.class] ? dictionary[@"ssid"] : nil;
		if (ssid.length == 0) {
			continue;
		}
		PSWiFiNetwork *network = [[PSWiFiNetwork alloc] init];
		network.ssid = ssid;
		network.displayName = [dictionary[@"displayName"] isKindOfClass:NSString.class] ? dictionary[@"displayName"] : ssid;
		NSDictionary *proxy = [dictionary[@"proxy"] isKindOfClass:NSDictionary.class] ? dictionary[@"proxy"] : nil;
		network.proxyProfile = proxy ? [PSProxyProfile profileWithDictionary:proxy] : nil;
		network.current = [ssid isEqualToString:currentSSID];
		[networks addObject:network];
	}
	return networks.copy;
#endif
}

- (NSArray<NSString *> *)quickWiFiSSIDs {
	NSArray *ssids = [self storeDictionary][PSQuickWiFiSSIDsKey];
	return [ssids isKindOfClass:NSArray.class] ? ssids : @[];
}

- (NSArray<PSWiFiNetwork *> *)quickWiFiNetworks {
	NSArray<NSString *> *quickSSIDs = [self quickWiFiSSIDs];
	if (quickSSIDs.count == 0) {
		return @[];
	}
	NSDictionary<NSString *, PSWiFiNetwork *> *availableBySSID = nil;
	NSMutableDictionary *map = [NSMutableDictionary dictionary];
	for (PSWiFiNetwork *network in [self availableWiFiNetworks]) {
		if (network.ssid.length > 0) {
			map[network.ssid] = network;
		}
	}
	availableBySSID = map.copy;
	NSMutableArray<PSWiFiNetwork *> *networks = [NSMutableArray array];
	NSString *currentSSID = [self currentWiFiSSID];
	for (NSString *ssid in quickSSIDs) {
		if (![ssid isKindOfClass:NSString.class] || ssid.length == 0) {
			continue;
		}
		PSWiFiNetwork *network = availableBySSID[ssid];
		if (!network) {
			network = [[PSWiFiNetwork alloc] init];
			network.ssid = ssid;
			network.displayName = ssid;
		}
		network.current = [ssid isEqualToString:currentSSID];
		[networks addObject:network];
	}
	return networks.copy;
}

- (void)addQuickWiFiSSID:(NSString *)ssid {
	if (ssid.length == 0) {
		return;
	}
	NSMutableDictionary *store = [self storeDictionary].mutableCopy;
	NSMutableArray *ssids = [[store[PSQuickWiFiSSIDsKey] isKindOfClass:NSArray.class] ? store[PSQuickWiFiSSIDsKey] : @[] mutableCopy];
	if (![ssids containsObject:ssid]) {
		[ssids addObject:ssid];
		store[PSQuickWiFiSSIDsKey] = ssids;
		[self writeStoreDictionary:store];
	}
}

- (void)deleteQuickWiFiSSID:(NSString *)ssid {
	if (ssid.length == 0) {
		return;
	}
	NSMutableDictionary *store = [self storeDictionary].mutableCopy;
	NSArray *rawSSIDs = [store[PSQuickWiFiSSIDsKey] isKindOfClass:NSArray.class] ? store[PSQuickWiFiSSIDsKey] : @[];
	NSMutableArray *remaining = [NSMutableArray array];
	for (NSString *candidate in rawSSIDs) {
		if (![candidate isEqualToString:ssid]) {
			[remaining addObject:candidate];
		}
	}
	store[PSQuickWiFiSSIDsKey] = remaining;
	[self writeStoreDictionary:store];
}

- (PSProxyProfile *)currentSystemProxyProfile {
	NSString *serviceIdentifier = [self currentWiFiServiceIdentifier];
	if (serviceIdentifier.length == 0) {
		return nil;
	}

	PSPrefsCreateFn prefsCreate = (PSPrefsCreateFn)PSSystemConfigurationSymbol("SCPreferencesCreate");
	PSServiceCopyAllFn serviceCopyAll = (PSServiceCopyAllFn)PSSystemConfigurationSymbol("SCNetworkServiceCopyAll");
	PSServiceGetServiceIDFn serviceGetServiceID = (PSServiceGetServiceIDFn)PSSystemConfigurationSymbol("SCNetworkServiceGetServiceID");
	PSServiceCopyProtocolFn serviceCopyProtocol = (PSServiceCopyProtocolFn)PSSystemConfigurationSymbol("SCNetworkServiceCopyProtocol");
	PSProtocolGetConfigurationFn protocolGetConfiguration = (PSProtocolGetConfigurationFn)PSSystemConfigurationSymbol("SCNetworkProtocolGetConfiguration");
	if (!prefsCreate || !serviceCopyAll || !serviceGetServiceID || !serviceCopyProtocol || !protocolGetConfiguration) {
		return nil;
	}

	CFTypeRef preferences = prefsCreate(NULL, CFSTR("ProxySwitcher"), NULL);
	if (!preferences) {
		return nil;
	}
	PSProxyProfile *profile = nil;
	NSArray *services = CFBridgingRelease(serviceCopyAll(preferences));
	for (id serviceObject in services) {
		CFTypeRef service = (__bridge CFTypeRef)serviceObject;
		NSString *identifier = (__bridge NSString *)serviceGetServiceID(service);
		if (![identifier isEqualToString:serviceIdentifier]) {
			continue;
		}
		CFTypeRef protocol = serviceCopyProtocol(service, CFSTR("Proxies"));
		if (!protocol) {
			break;
		}
		CFDictionaryRef configurationRef = protocolGetConfiguration(protocol);
		NSDictionary *configuration = configurationRef ? (__bridge NSDictionary *)configurationRef : nil;
		if ([configuration[@"HTTPEnable"] boolValue] && [configuration[@"HTTPProxy"] isKindOfClass:NSString.class] && [configuration[@"HTTPPort"] respondsToSelector:@selector(integerValue)]) {
			PSProxyProfile *temporary = [[PSProxyProfile alloc] init];
			temporary.identifier = PSProxyTemporaryIdentifier;
			temporary.name = [self currentWiFiSSID] ?: @"Current Wi-Fi";
			temporary.host = configuration[@"HTTPProxy"];
			temporary.port = [configuration[@"HTTPPort"] integerValue];
			profile = temporary;
		}
		CFRelease(protocol);
		break;
	}
	CFRelease(preferences);
	return profile;
}

- (BOOL)syncActiveProfileWithCurrentSystemProxy:(NSError **)error {
	PSProxyProfile *systemProfile = [self currentSystemProxyProfile];
	NSString *targetIdentifier = PSProxyDirectIdentifier;
	PSProxyProfile *temporaryProfile = nil;
	if (systemProfile) {
		for (PSProxyProfile *profile in [self profiles]) {
			if (PSProxyProfilesEqual(profile, systemProfile)) {
				targetIdentifier = profile.identifier;
				break;
			}
		}
		if ([targetIdentifier isEqualToString:PSProxyDirectIdentifier]) {
			temporaryProfile = systemProfile;
			temporaryProfile.name = [NSString stringWithFormat:@"%@:%ld", systemProfile.host, (long)systemProfile.port];
			targetIdentifier = PSProxyTemporaryIdentifier;
		}
	}

	NSString *activeIdentifier = [self activeIdentifier];
	PSProxyProfile *existingTemporary = [self temporaryProfile];
	if ([activeIdentifier isEqualToString:targetIdentifier] && (!temporaryProfile || PSProxyProfilesEqual(existingTemporary, temporaryProfile))) {
		return YES;
	}
	if (temporaryProfile) {
		[self setTemporaryProfile:temporaryProfile];
	} else {
		[self setActiveIdentifier:targetIdentifier];
	}
	return YES;
}

- (BOOL)applyDirectWithError:(NSError **)error {
#ifndef PROXYSWITCHER_HELPER
	BOOL ok = [self runHelperWithArguments:@[@"direct"] error:error];
	if (ok) {
		[self setActiveIdentifier:PSProxyDirectIdentifier];
	}
	return ok;
#else
	BOOL ok = [self applyProxyConfiguration:nil error:error];
	if (ok) {
		[self updateKnownNetworkProxyForProfile:nil];
		[self setActiveIdentifier:PSProxyDirectIdentifier];
	}
	return ok;
#endif
}

- (BOOL)applyProfileWithIdentifier:(NSString *)identifier error:(NSError **)error {
	PSProxyProfile *profile = [self profileWithIdentifier:identifier];
	if (!profile) {
		if (error) {
			*error = [NSError errorWithDomain:@"ProxySwitcher" code:404 userInfo:@{NSLocalizedDescriptionKey: @"Proxy profile not found."}];
		}
		return NO;
	}
#ifndef PROXYSWITCHER_HELPER
	BOOL ok = [self runHelperWithArguments:@[@"apply", identifier] error:error];
	if (ok) {
		[self setActiveIdentifier:identifier];
	}
	return ok;
#else
	BOOL ok = [self applyProxyConfiguration:profile error:error];
	if (ok) {
		[self updateKnownNetworkProxyForProfile:profile];
		[self setActiveIdentifier:identifier];
	}
	return ok;
#endif
}

- (BOOL)switchToWiFiSSID:(NSString *)ssid error:(NSError **)error {
	if (ssid.length == 0) {
		if (error) {
			*error = [NSError errorWithDomain:@"ProxySwitcher" code:30 userInfo:@{NSLocalizedDescriptionKey: @"Wi-Fi SSID is empty."}];
		}
		return NO;
	}
#ifndef PROXYSWITCHER_HELPER
	return [self runHelperWithArguments:@[@"wifi", ssid] error:error];
#else
	typedef CFTypeRef (*WiFiManagerClientCreateFn)(CFAllocatorRef allocator, int flags);
	typedef CFArrayRef (*WiFiManagerClientCopyDevicesFn)(CFTypeRef manager);
	typedef CFArrayRef (*WiFiManagerClientCopyNetworksFn)(CFTypeRef manager);
	typedef CFArrayRef (*WiFiManagerClientCopyEnabledNetworksFn)(CFTypeRef manager);
	typedef CFArrayRef (*WiFiManagerClientCopyMutableNetworksFn)(CFTypeRef manager);
	typedef CFStringRef (*WiFiNetworkGetSSIDFn)(CFTypeRef network);
	typedef int (*WiFiDeviceClientAssociateAsyncFn)(CFTypeRef device, CFTypeRef network, CFDictionaryRef options, void *callback, void *context);

	WiFiManagerClientCreateFn managerCreate = (WiFiManagerClientCreateFn)PSMobileWiFiSymbol("WiFiManagerClientCreate");
	WiFiManagerClientCopyDevicesFn copyDevices = (WiFiManagerClientCopyDevicesFn)PSMobileWiFiSymbol("WiFiManagerClientCopyDevices");
	WiFiManagerClientCopyNetworksFn copyNetworks = (WiFiManagerClientCopyNetworksFn)PSMobileWiFiSymbol("WiFiManagerClientCopyNetworks");
	WiFiManagerClientCopyEnabledNetworksFn copyEnabledNetworks = (WiFiManagerClientCopyEnabledNetworksFn)PSMobileWiFiSymbol("WiFiManagerClientCopyEnabledNetworks");
	WiFiManagerClientCopyMutableNetworksFn copyMutableNetworks = (WiFiManagerClientCopyMutableNetworksFn)PSMobileWiFiSymbol("WiFiManagerClientCopyMutableNetworks");
	WiFiNetworkGetSSIDFn networkGetSSID = (WiFiNetworkGetSSIDFn)PSMobileWiFiSymbol("WiFiNetworkGetSSID");
	WiFiDeviceClientAssociateAsyncFn associateAsync = (WiFiDeviceClientAssociateAsyncFn)PSMobileWiFiSymbol("WiFiDeviceClientAssociateAsync");
	if (!managerCreate || !copyDevices || !networkGetSSID || !associateAsync || (!copyNetworks && !copyEnabledNetworks && !copyMutableNetworks)) {
		if (error) {
			*error = [NSError errorWithDomain:@"ProxySwitcher" code:31 userInfo:@{NSLocalizedDescriptionKey: @"Required MobileWiFi symbols are unavailable."}];
		}
		return NO;
	}

	CFTypeRef manager = managerCreate(NULL, 0);
	if (!manager) {
		if (error) {
			*error = [NSError errorWithDomain:@"ProxySwitcher" code:32 userInfo:@{NSLocalizedDescriptionKey: @"Unable to open MobileWiFi manager."}];
		}
		return NO;
	}

	NSArray *devices = CFBridgingRelease(copyDevices(manager));
	CFTypeRef device = devices.count > 0 ? (__bridge CFTypeRef)devices.firstObject : NULL;
	CFTypeRef targetNetwork = NULL;
	NSArray *networkLists = @[
		copyMutableNetworks ? CFBridgingRelease(copyMutableNetworks(manager)) ?: @[] : @[],
		copyEnabledNetworks ? CFBridgingRelease(copyEnabledNetworks(manager)) ?: @[] : @[],
		copyNetworks ? CFBridgingRelease(copyNetworks(manager)) ?: @[] : @[]
	];
	for (NSArray *networks in networkLists) {
		if (![networks isKindOfClass:NSArray.class]) {
			continue;
		}
		for (id networkObject in networks) {
			CFTypeRef network = (__bridge CFTypeRef)networkObject;
			NSString *networkSSID = (__bridge NSString *)networkGetSSID(network);
			if ([networkSSID isEqualToString:ssid]) {
				targetNetwork = network;
				break;
			}
		}
		if (targetNetwork) {
			break;
		}
	}
	if (!device || !targetNetwork) {
		NSError *coreWiFiError = nil;
		if (PSSwitchToWiFiSSIDUsingCoreWiFi(ssid, &coreWiFiError)) {
			NSDate *deadline = [NSDate dateWithTimeIntervalSinceNow:15.0];
			while ([deadline timeIntervalSinceNow] > 0) {
				if ([[self currentWiFiSSID] isEqualToString:ssid]) {
					[NSThread sleepForTimeInterval:1.0];
					[self syncActiveProfileWithCurrentSystemProxy:nil];
					CFRelease(manager);
					return YES;
				}
				[NSThread sleepForTimeInterval:0.5];
			}
			[self syncActiveProfileWithCurrentSystemProxy:nil];
			CFRelease(manager);
			return YES;
		}
		if (error) {
			*error = coreWiFiError ?: [NSError errorWithDomain:@"ProxySwitcher" code:33 userInfo:@{NSLocalizedDescriptionKey: @"Saved Wi-Fi network was not found."}];
		}
		CFRelease(manager);
		return NO;
	}

	int result = associateAsync(device, targetNetwork, NULL, NULL, NULL);
	if (result != 0) {
		if (error) {
			*error = [NSError errorWithDomain:@"ProxySwitcher" code:34 userInfo:@{NSLocalizedDescriptionKey: [NSString stringWithFormat:@"MobileWiFi association failed (%d).", result]}];
		}
		CFRelease(manager);
		return NO;
	}

	NSDate *deadline = [NSDate dateWithTimeIntervalSinceNow:15.0];
	while ([deadline timeIntervalSinceNow] > 0) {
		if ([[self currentWiFiSSID] isEqualToString:ssid]) {
			[NSThread sleepForTimeInterval:1.0];
			[self syncActiveProfileWithCurrentSystemProxy:nil];
			CFRelease(manager);
			return YES;
		}
		[NSThread sleepForTimeInterval:0.5];
	}
	[self syncActiveProfileWithCurrentSystemProxy:nil];
	CFRelease(manager);
	return YES;
#endif
}

#ifndef PROXYSWITCHER_HELPER
- (BOOL)runHelperWithArguments:(NSArray<NSString *> *)arguments error:(NSError **)error {
	return [self runHelperWithArguments:arguments response:nil error:error];
}

- (BOOL)runHelperWithArguments:(NSArray<NSString *> *)arguments response:(NSString **)responseMessage error:(NSError **)error {
	NSString *helperPath = PSHelperPath();
	if (![[NSFileManager defaultManager] fileExistsAtPath:helperPath]) {
		if (error) {
			*error = [NSError errorWithDomain:@"ProxySwitcher" code:10 userInfo:@{NSLocalizedDescriptionKey: @"ProxySwitcher helper is not installed."}];
		}
		return NO;
	}

	NSString *requestIdentifier = [NSUUID UUID].UUIDString;
	NSString *requestPath = PSRequestPath();
	NSString *responsePath = PSResponsePath();
	NSString *directory = [requestPath stringByDeletingLastPathComponent];
	[[NSFileManager defaultManager] createDirectoryAtPath:directory withIntermediateDirectories:YES attributes:nil error:nil];
	[[NSFileManager defaultManager] removeItemAtPath:responsePath error:nil];
	NSString *request = [@[requestIdentifier, arguments.firstObject ?: @"", arguments.count > 1 ? arguments[1] : @""] componentsJoinedByString:@"\n"];
	request = [request stringByAppendingString:@"\n"];
	if (![request writeToFile:requestPath atomically:YES encoding:NSUTF8StringEncoding error:nil]) {
		if (error) {
			*error = [NSError errorWithDomain:@"ProxySwitcher" code:12 userInfo:@{NSLocalizedDescriptionKey: @"Unable to write helper request."}];
		}
		return NO;
	}
	notify_post(PSProxyRequestNotification.UTF8String);

	NSDate *deadline = [NSDate dateWithTimeIntervalSinceNow:5.0];
	while ([deadline timeIntervalSinceNow] > 0) {
		NSString *response = [NSString stringWithContentsOfFile:responsePath encoding:NSUTF8StringEncoding error:nil];
		NSArray<NSString *> *lines = [response componentsSeparatedByCharactersInSet:NSCharacterSet.newlineCharacterSet];
		if (lines.count >= 2 && [lines[0] isEqualToString:requestIdentifier]) {
			if ([lines[1] isEqualToString:@"1"]) {
				if (responseMessage) {
					*responseMessage = lines.count > 2 ? lines[2] : @"";
				}
				return YES;
			}
			if (error) {
				NSString *message = lines.count > 2 && lines[2].length > 0 ? lines[2] : @"ProxySwitcher helper could not update proxy settings.";
				*error = [NSError errorWithDomain:@"ProxySwitcher" code:11 userInfo:@{NSLocalizedDescriptionKey: message}];
			}
			return NO;
		}
		[NSThread sleepForTimeInterval:0.1];
	}

	if (error) {
		*error = [NSError errorWithDomain:@"ProxySwitcher" code:13 userInfo:@{NSLocalizedDescriptionKey: @"ProxySwitcher helper did not respond."}];
	}
	return NO;
}
#endif

- (NSString *)currentWiFiSSID {
	typedef CFTypeRef (*WiFiManagerClientCreateFn)(CFAllocatorRef allocator, int flags);
	typedef CFArrayRef (*WiFiManagerClientCopyDevicesFn)(CFTypeRef manager);
	typedef CFTypeRef (*WiFiDeviceClientCopyCurrentNetworkFn)(CFTypeRef device);
	typedef CFStringRef (*WiFiNetworkGetSSIDFn)(CFTypeRef network);

	WiFiManagerClientCreateFn managerCreate = (WiFiManagerClientCreateFn)PSMobileWiFiSymbol("WiFiManagerClientCreate");
	WiFiManagerClientCopyDevicesFn copyDevices = (WiFiManagerClientCopyDevicesFn)PSMobileWiFiSymbol("WiFiManagerClientCopyDevices");
	WiFiDeviceClientCopyCurrentNetworkFn copyCurrentNetwork = (WiFiDeviceClientCopyCurrentNetworkFn)PSMobileWiFiSymbol("WiFiDeviceClientCopyCurrentNetwork");
	WiFiNetworkGetSSIDFn networkGetSSID = (WiFiNetworkGetSSIDFn)PSMobileWiFiSymbol("WiFiNetworkGetSSID");
	if (managerCreate && copyDevices && copyCurrentNetwork && networkGetSSID) {
		CFTypeRef manager = managerCreate(NULL, 0);
		if (manager) {
			NSArray *devices = CFBridgingRelease(copyDevices(manager));
			for (id deviceObject in devices) {
				CFTypeRef network = copyCurrentNetwork((__bridge CFTypeRef)deviceObject);
				if (!network) {
					continue;
				}
				NSString *ssid = [(__bridge NSString *)networkGetSSID(network) copy];
				CFRelease(network);
				if (ssid.length > 0) {
					CFRelease(manager);
					return ssid;
				}
			}
			CFRelease(manager);
		}
	}
	return [self currentSetNameFromSystemPreferences];
}

- (NSString *)currentWiFiServiceIdentifier {
	PSDStoreCreateFn storeCreate = (PSDStoreCreateFn)PSSystemConfigurationSymbol("SCDynamicStoreCreate");
	PSDStoreCopyValueFn storeCopyValue = (PSDStoreCopyValueFn)PSSystemConfigurationSymbol("SCDynamicStoreCopyValue");
	PSDStoreCopyKeyListFn storeCopyKeyList = (PSDStoreCopyKeyListFn)PSSystemConfigurationSymbol("SCDynamicStoreCopyKeyList");
	if (!storeCreate || !storeCopyValue || !storeCopyKeyList) {
		return nil;
	}

	CFTypeRef store = storeCreate(NULL, CFSTR("ProxySwitcher"), NULL, NULL);
	if (!store) {
		return nil;
	}

	NSDictionary *global = CFBridgingRelease(storeCopyValue(store, CFSTR("State:/Network/Global/IPv4")));
	NSString *primaryService = [global[@"PrimaryService"] isKindOfClass:NSString.class] ? global[@"PrimaryService"] : nil;
	NSString *primaryInterface = [global[@"PrimaryInterface"] isKindOfClass:NSString.class] ? global[@"PrimaryInterface"] : nil;
	if ([primaryInterface isEqualToString:@"en0"] && primaryService.length > 0) {
		CFRelease(store);
		return primaryService;
	}

	NSArray *keys = CFBridgingRelease(storeCopyKeyList(store, CFSTR("State:/Network/Service/.*/IPv4")));
	for (NSString *key in keys) {
		NSDictionary *state = CFBridgingRelease(storeCopyValue(store, (__bridge CFStringRef)key));
		NSString *interfaceName = [state[@"InterfaceName"] isKindOfClass:NSString.class] ? state[@"InterfaceName"] : nil;
		NSArray *addresses = [state[@"Addresses"] isKindOfClass:NSArray.class] ? state[@"Addresses"] : nil;
		if ([interfaceName isEqualToString:@"en0"] && addresses.count > 0) {
			NSArray *parts = [key componentsSeparatedByString:@"/"];
			NSUInteger serviceIndex = [parts indexOfObject:@"Service"];
			if (serviceIndex != NSNotFound && serviceIndex + 1 < parts.count) {
				CFRelease(store);
				return parts[serviceIndex + 1];
			}
		}
	}

	CFRelease(store);
	return nil;
}

- (BOOL)applyProxyConfiguration:(PSProxyProfile *)profile error:(NSError **)error {
	NSString *serviceIdentifier = [self currentWiFiServiceIdentifier];
	if (serviceIdentifier.length == 0) {
		if (error) {
			*error = [NSError errorWithDomain:@"ProxySwitcher" code:1 userInfo:@{NSLocalizedDescriptionKey: @"No active Wi-Fi service was found."}];
		}
		return NO;
	}

	PSPrefsCreateFn prefsCreate = (PSPrefsCreateFn)PSSystemConfigurationSymbol("SCPreferencesCreate");
	PSServiceCopyAllFn serviceCopyAll = (PSServiceCopyAllFn)PSSystemConfigurationSymbol("SCNetworkServiceCopyAll");
	PSServiceGetServiceIDFn serviceGetServiceID = (PSServiceGetServiceIDFn)PSSystemConfigurationSymbol("SCNetworkServiceGetServiceID");
	PSServiceCopyProtocolFn serviceCopyProtocol = (PSServiceCopyProtocolFn)PSSystemConfigurationSymbol("SCNetworkServiceCopyProtocol");
	PSProtocolGetConfigurationFn protocolGetConfiguration = (PSProtocolGetConfigurationFn)PSSystemConfigurationSymbol("SCNetworkProtocolGetConfiguration");
	PSProtocolSetConfigurationFn protocolSetConfiguration = (PSProtocolSetConfigurationFn)PSSystemConfigurationSymbol("SCNetworkProtocolSetConfiguration");
	PSProtocolSetEnabledFn protocolSetEnabled = (PSProtocolSetEnabledFn)PSSystemConfigurationSymbol("SCNetworkProtocolSetEnabled");
	PSPrefsCommitChangesFn prefsCommitChanges = (PSPrefsCommitChangesFn)PSSystemConfigurationSymbol("SCPreferencesCommitChanges");
	PSPrefsApplyChangesFn prefsApplyChanges = (PSPrefsApplyChangesFn)PSSystemConfigurationSymbol("SCPreferencesApplyChanges");
	PSPrefsLockFn prefsLock = (PSPrefsLockFn)PSSystemConfigurationSymbol("SCPreferencesLock");
	PSPrefsUnlockFn prefsUnlock = (PSPrefsUnlockFn)PSSystemConfigurationSymbol("SCPreferencesUnlock");
	if (!prefsCreate || !serviceCopyAll || !serviceGetServiceID || !serviceCopyProtocol || !protocolGetConfiguration || !protocolSetConfiguration || !protocolSetEnabled || !prefsCommitChanges || !prefsApplyChanges || !prefsLock || !prefsUnlock) {
		if (error) {
			*error = [NSError errorWithDomain:@"ProxySwitcher" code:2 userInfo:@{NSLocalizedDescriptionKey: @"Required SystemConfiguration symbols are unavailable."}];
		}
		return NO;
	}

	CFTypeRef preferences = prefsCreate(NULL, CFSTR("ProxySwitcher"), NULL);
	if (!preferences) {
		if (error) {
			*error = [NSError errorWithDomain:@"ProxySwitcher" code:2 userInfo:@{NSLocalizedDescriptionKey: @"Unable to open network preferences."}];
		}
		return NO;
	}

	if (!prefsLock(preferences, true)) {
		if (error) {
			const char *lastError = SCErrorString(SCError());
			NSString *message = lastError ? [NSString stringWithUTF8String:lastError] : @"Unable to lock network preferences.";
			*error = [NSError errorWithDomain:@"ProxySwitcher" code:3 userInfo:@{NSLocalizedDescriptionKey: message ?: @"Unable to lock network preferences."}];
		}
		CFRelease(preferences);
		return NO;
	}

	BOOL applied = NO;
	NSArray *services = CFBridgingRelease(serviceCopyAll(preferences));
	for (id serviceObject in services) {
		CFTypeRef service = (__bridge CFTypeRef)serviceObject;
		NSString *identifier = (__bridge NSString *)serviceGetServiceID(service);
		if (![identifier isEqualToString:serviceIdentifier]) {
			continue;
		}

		CFTypeRef protocol = serviceCopyProtocol(service, CFSTR("Proxies"));
		if (!protocol) {
			break;
		}

		CFDictionaryRef existingRef = protocolGetConfiguration(protocol);
		NSDictionary *existing = existingRef ? (__bridge NSDictionary *)existingRef : nil;
		NSMutableDictionary *configuration = existing ? existing.mutableCopy : [NSMutableDictionary dictionary];
		[configuration removeObjectsForKeys:@[
			@"HTTPEnable",
			@"HTTPProxy",
			@"HTTPPort",
			@"HTTPSEnable",
			@"HTTPSProxy",
			@"HTTPSPort",
			@"ProxyAutoConfigEnable",
			@"ProxyAutoConfigURLString",
			@"ProxyAutoDiscoveryEnable"
		]];

		if (profile) {
			configuration[@"HTTPEnable"] = @1;
			configuration[@"HTTPProxy"] = profile.host;
			configuration[@"HTTPPort"] = @(profile.port);
			configuration[@"HTTPSEnable"] = @1;
			configuration[@"HTTPSProxy"] = profile.host;
			configuration[@"HTTPSPort"] = @(profile.port);
		}

		if (protocolSetConfiguration(protocol, (__bridge CFDictionaryRef)configuration) &&
			protocolSetEnabled(protocol, true) &&
			prefsCommitChanges(preferences) &&
			prefsApplyChanges(preferences)) {
			applied = YES;
		}

		CFRelease(protocol);
		break;
	}

	if (!applied && error) {
		const char *lastError = SCErrorString(SCError());
		NSString *message = lastError ? [NSString stringWithUTF8String:lastError] : @"Unable to update Wi-Fi proxy settings.";
		*error = [NSError errorWithDomain:@"ProxySwitcher" code:3 userInfo:@{NSLocalizedDescriptionKey: message ?: @"Unable to update Wi-Fi proxy settings."}];
	}

	prefsUnlock(preferences);
	CFRelease(preferences);
	return applied;
}

@end

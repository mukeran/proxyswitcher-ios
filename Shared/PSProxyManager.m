#import "PSProxyManager.h"
#import <dlfcn.h>
#import <roothide.h>
#import <SystemConfiguration/SystemConfiguration.h>
#import <notify.h>
#import <spawn.h>
#import <errno.h>
#import <string.h>
#import <sys/wait.h>

NSString * const PSProxyDirectIdentifier = @"direct";
NSString * const PSProxyProfilesChangedNotification = @"codes.var.tweak.proxyswitcher.profiles.changed";
NSString * const PSProxyRequestNotification = @"codes.var.tweak.proxyswitcher.request";

static NSString * const PSProfilesKey = @"profiles";
static NSString * const PSActiveIdentifierKey = @"activeIdentifier";

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
	NSString *identifier = [self storeDictionary][@"ActiveIdentifier"];
	return identifier ?: PSProxyDirectIdentifier;
}

- (NSString *)lastActiveProfileIdentifier {
	return [self storeDictionary][@"LastActiveProfileIdentifier"];
}

- (void)setActiveIdentifier:(NSString *)identifier {
	NSMutableDictionary *store = [self storeDictionary].mutableCopy;
	store[@"ActiveIdentifier"] = identifier;
	if (identifier && ![identifier isEqualToString:PSProxyDirectIdentifier]) {
		store[@"LastActiveProfileIdentifier"] = identifier;
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

#ifndef PROXYSWITCHER_HELPER
- (BOOL)runHelperWithArguments:(NSArray<NSString *> *)arguments error:(NSError **)error {
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

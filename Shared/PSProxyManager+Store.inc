- (NSDictionary *)storeDictionary {
	PSMigrateLegacyStoreIfNeeded();
	for (NSString *path in PSStorePathCandidates()) {
		NSDictionary *dictionary = [NSDictionary dictionaryWithContentsOfFile:path];
		if ([dictionary isKindOfClass:NSDictionary.class]) {
			return dictionary;
		}
	}
	return @{};
}

- (BOOL)writeStoreDictionary:(NSDictionary *)dictionary {
	BOOL ok = NO;
	NSFileManager *fileManager = [NSFileManager defaultManager];
	for (NSString *path in PSStorePathCandidates()) {
		NSString *directory = [path stringByDeletingLastPathComponent];
		[fileManager createDirectoryAtPath:directory withIntermediateDirectories:YES attributes:nil error:nil];
		if ([dictionary writeToFile:path atomically:YES]) {
			ok = YES;
		}
	}
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
	if (![dictionary isKindOfClass:NSDictionary.class]) {
		return nil;
	}
	PSProxyProfile *profile = [PSProxyProfile profileWithDictionary:dictionary];
	profile.name = @"Temporary";
	return profile;
}

- (PSProxyProfile *)lastTemporaryProfile {
	NSDictionary *dictionary = [self storeDictionary][PSLastTemporaryProfileKey];
	if (![dictionary isKindOfClass:NSDictionary.class]) {
		return nil;
	}
	PSProxyProfile *profile = [PSProxyProfile profileWithDictionary:dictionary];
	profile.name = @"Temporary";
	return profile;
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
		profile.name = @"Temporary";
		store[PSTemporaryProfileKey] = [profile dictionaryRepresentation];
		store[PSLastTemporaryProfileKey] = [profile dictionaryRepresentation];
		store[PSActiveIdentifierKey] = PSProxyTemporaryIdentifier;
		[store removeObjectForKey:@"ActiveIdentifier"];
	} else {
		[store removeObjectForKey:PSTemporaryProfileKey];
	}
	[self writeStoreDictionary:store];
}

- (void)clearTemporaryProfile {
	NSMutableDictionary *store = [self storeDictionary].mutableCopy;
	[store removeObjectForKey:PSTemporaryProfileKey];
	[store removeObjectForKey:PSLastTemporaryProfileKey];
	if ([[store objectForKey:PSActiveIdentifierKey] isEqualToString:PSProxyTemporaryIdentifier]) {
		store[PSActiveIdentifierKey] = PSProxyDirectIdentifier;
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

- (NSDictionary<NSString *, id> *)pendingAppCommand {
	NSDictionary *command = [self storeDictionary][PSPendingAppCommandKey];
	return [command isKindOfClass:NSDictionary.class] ? command : nil;
}

- (void)setPendingAppCommand:(NSDictionary<NSString *, id> *)command {
	NSMutableDictionary *store = [self storeDictionary].mutableCopy;
	if ([command isKindOfClass:NSDictionary.class] && command.count > 0) {
		store[PSPendingAppCommandKey] = command;
	} else {
		[store removeObjectForKey:PSPendingAppCommandKey];
	}
	[self writeStoreDictionary:store];
}

- (void)clearPendingAppCommand {
	NSMutableDictionary *store = [self storeDictionary].mutableCopy;
	[store removeObjectForKey:PSPendingAppCommandKey];
	[self writeStoreDictionary:store];
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
	NSString *networkName = [self currentWiFiSSID];
	NSString *path = PSKnownNetworksPath();
	NSMutableDictionary *knownNetworks = PSPropertyListAtPath(path, NSPropertyListMutableContainers);
	if (![knownNetworks isKindOfClass:NSMutableDictionary.class]) {
		return;
	}
	NSString *networkKey = networkName.length > 0 ? [@"wifi.network.ssid." stringByAppendingString:networkName] : nil;
	if (![knownNetworks[networkKey] isKindOfClass:NSDictionary.class]) {
		return;
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
		@"ProxyPACURL",
		@"ExceptionsList"
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
		if (profile.noProxy.count > 0) {
			network[@"ExceptionsList"] = profile.noProxy;
		}
	}
	knownNetworks[networkKey] = network;
	PSWritePropertyList(knownNetworks, path);
}

- (void)setWiFiServiceIdentifier:(NSString *)serviceIdentifier forSSID:(NSString *)ssid {
	if (ssid.length == 0 || serviceIdentifier.length == 0) {
		return;
	}
	NSMutableDictionary *store = [self storeDictionary].mutableCopy;
	NSMutableDictionary *mapping = [[store[PSWiFiServiceIdentifiersKey] isKindOfClass:NSDictionary.class] ? store[PSWiFiServiceIdentifiersKey] : @{} mutableCopy];
	NSString *existing = [mapping[ssid] isKindOfClass:NSString.class] ? mapping[ssid] : nil;
	if ([existing isEqualToString:serviceIdentifier]) {
		return;
	}
	mapping[ssid] = serviceIdentifier;
	store[PSWiFiServiceIdentifiersKey] = mapping;
	[self writeStoreDictionary:store];
}

- (NSString *)wiFiServiceIdentifierForSSID:(NSString *)ssid {
	NSDictionary *preferences = PSPropertyListAtPath(PSRootfsPath(@"/var/preferences/SystemConfiguration/preferences.plist"), NSPropertyListImmutable);
	NSDictionary *sets = [preferences[@"Sets"] isKindOfClass:NSDictionary.class] ? preferences[@"Sets"] : nil;
	NSDictionary *services = [preferences[@"NetworkServices"] isKindOfClass:NSDictionary.class] ? preferences[@"NetworkServices"] : nil;
	for (NSString *setIdentifier in sets) {
		NSDictionary *set = [sets[setIdentifier] isKindOfClass:NSDictionary.class] ? sets[setIdentifier] : nil;
		NSString *setName = [set[@"UserDefinedName"] isKindOfClass:NSString.class] ? set[@"UserDefinedName"] : nil;
		if (![setName isEqualToString:ssid]) {
			continue;
		}
		NSArray *serviceOrder = set[@"Network"][@"Global"][@"IPv4"][@"ServiceOrder"];
		if (![serviceOrder isKindOfClass:NSArray.class]) {
			serviceOrder = [set[@"Network"][@"Service"] allKeys];
		}
		for (NSString *serviceIdentifier in serviceOrder) {
			NSDictionary *service = [services[serviceIdentifier] isKindOfClass:NSDictionary.class] ? services[serviceIdentifier] : nil;
			NSDictionary *interface = [service[@"Interface"] isKindOfClass:NSDictionary.class] ? service[@"Interface"] : nil;
			if ([interface[@"DeviceName"] isEqualToString:@"en0"] && [interface[@"Hardware"] isEqualToString:@"AirPort"]) {
				return serviceIdentifier;
			}
		}
	}
	NSDictionary *mapping = [self storeDictionary][PSWiFiServiceIdentifiersKey];
	return [mapping isKindOfClass:NSDictionary.class] && [mapping[ssid] isKindOfClass:NSString.class] ? mapping[ssid] : nil;
}

- (PSProxyProfile *)proxyProfileForWiFiServiceIdentifier:(NSString *)serviceIdentifier ssid:(NSString *)ssid {
	if (serviceIdentifier.length == 0) {
		return nil;
	}
	NSDictionary *preferences = PSPropertyListAtPath(PSRootfsPath(@"/var/preferences/SystemConfiguration/preferences.plist"), NSPropertyListImmutable);
	NSDictionary *services = [preferences[@"NetworkServices"] isKindOfClass:NSDictionary.class] ? preferences[@"NetworkServices"] : nil;
	NSDictionary *service = [services[serviceIdentifier] isKindOfClass:NSDictionary.class] ? services[serviceIdentifier] : nil;
	NSDictionary *proxies = [service[@"Proxies"] isKindOfClass:NSDictionary.class] ? service[@"Proxies"] : nil;
	return PSProxyProfileFromSCProxiesDictionary(proxies, ssid);
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
		if (!network.proxyProfile) {
			network.proxyProfile = [self proxyProfileForWiFiServiceIdentifier:[self wiFiServiceIdentifierForSSID:ssid] ssid:ssid];
		}
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
	}
	[self writeStoreDictionary:store];
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

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
#ifdef PROXYSWITCHER_APP_ONLY
	return nil;
#else
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
#endif
}

- (NSDictionary<NSString *, id> *)diagnosticsSnapshot {
	NSDictionary *store = [self storeDictionary];
	NSArray *profiles = [store[PSProfilesKey] isKindOfClass:NSArray.class] ? store[PSProfilesKey] : @[];
	NSArray *quickWiFi = [store[PSQuickWiFiSSIDsKey] isKindOfClass:NSArray.class] ? store[PSQuickWiFiSSIDsKey] : @[];
	NSString *transport = ([self isVPNModeAvailable] && [self isCompatibilityModeEnabled]) ? @"vpn" : @"system";
	return @{
		@"activeIdentifier": [self activeIdentifier] ?: PSProxyDirectIdentifier,
		@"currentSSID": [self currentWiFiSSID] ?: @"",
		@"profilesCount": @(profiles.count),
		@"quickWiFiCount": @(quickWiFi.count),
		@"helperSocketPath": PSProxyHelperSocketPath ?: @"",
		@"transportMode": transport,
		@"compatibilityModeEnabled": @([self isCompatibilityModeEnabled]),
		@"vpnModeAvailable": @([self isVPNModeAvailable])
	};
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
			@"ProxyAutoDiscoveryEnable",
			@"ExceptionsList"
		]];

		if (profile) {
			configuration[@"HTTPEnable"] = @1;
			configuration[@"HTTPProxy"] = profile.host;
			configuration[@"HTTPPort"] = @(profile.port);
			configuration[@"HTTPSEnable"] = @1;
			configuration[@"HTTPSProxy"] = profile.host;
			configuration[@"HTTPSPort"] = @(profile.port);
			if (profile.noProxy.count > 0) {
				configuration[@"ExceptionsList"] = profile.noProxy;
			}
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

- (BOOL)isWiFiSwitchSupported {
	if ([self isVPNModeAvailable] && [self isCompatibilityModeEnabled]) {
		return NO;
	}
	return YES;
}


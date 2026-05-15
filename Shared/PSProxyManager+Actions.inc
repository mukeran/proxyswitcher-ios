- (BOOL)syncActiveProfileWithCurrentSystemProxy:(NSError **)error {
#ifdef PROXYSWITCHER_HELPER
	#pragma unused(error)
	return YES;
#elif defined(PROXYSWITCHER_APP_ONLY)
	return [self appOnlySyncActiveProfileWithError:error];
#else
#ifdef PROXYSWITCHER_APP_CLIENT
	if ([self isVPNModeAvailable] && [self isCompatibilityModeEnabled]) {
		return [self appOnlySyncActiveProfileWithError:error];
	}
#endif
	[self setWiFiServiceIdentifier:[self currentWiFiServiceIdentifier] forSSID:[self currentWiFiSSID]];
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
			temporaryProfile.name = @"Temporary";
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
#endif
}

- (BOOL)applyDirectWithError:(NSError **)error {
#if defined(PROXYSWITCHER_APP_ONLY) || defined(PROXYSWITCHER_APP_CLIENT)
	if ([self isVPNModeAvailable] && [self isCompatibilityModeEnabled]) {
		return [self appOnlyStopTunnelWithError:error];
	}
#endif
#ifdef PROXYSWITCHER_APP_ONLY
	return [self appOnlyStopTunnelWithError:error];
#elif !defined(PROXYSWITCHER_HELPER)
	NSError *helperError = nil;
	BOOL ok = [self runHelperWithArguments:@[@"direct"] error:&helperError];
	if (ok) {
		[self setActiveIdentifier:PSProxyDirectIdentifier];
		return YES;
	}
	if (PSIsHelperUnreachableError(helperError)) {
		[self syncActiveProfileWithCurrentSystemProxy:nil];
		if ([self currentSystemProxyProfile] == nil) {
			return YES;
		}
	}
	if (error) {
		*error = helperError;
	}
	return NO;
#else
	BOOL ok = [self applyProxyConfiguration:nil error:error];
	if (ok) {
		[self setWiFiServiceIdentifier:[self currentWiFiServiceIdentifier] forSSID:[self currentWiFiSSID]];
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
#if defined(PROXYSWITCHER_APP_ONLY) || defined(PROXYSWITCHER_APP_CLIENT)
	if ([self isVPNModeAvailable] && [self isCompatibilityModeEnabled]) {
		return [self appOnlyConfigureAndStartWithProfile:profile identifier:identifier error:error];
	}
#endif
#ifdef PROXYSWITCHER_APP_ONLY
	return [self appOnlyConfigureAndStartWithProfile:profile identifier:identifier error:error];
#elif !defined(PROXYSWITCHER_HELPER)
	NSError *helperError = nil;
	BOOL ok = [self runHelperWithArguments:@[@"apply", identifier] error:&helperError];
	if (ok) {
		[self setActiveIdentifier:identifier];
		return YES;
	}
	if (PSIsHelperUnreachableError(helperError)) {
		[self syncActiveProfileWithCurrentSystemProxy:nil];
		PSProxyProfile *currentProfile = [self currentSystemProxyProfile];
		if (currentProfile && PSProxyProfilesEqual(currentProfile, profile)) {
			return YES;
		}
	}
	if (error) {
		*error = helperError;
	}
	return NO;
#else
	BOOL ok = [self applyProxyConfiguration:profile error:error];
	if (ok) {
		[self setWiFiServiceIdentifier:[self currentWiFiServiceIdentifier] forSSID:[self currentWiFiSSID]];
		[self setActiveIdentifier:identifier];
	}
	return ok;
#endif
}

- (BOOL)applyTemporaryProfileWithError:(NSError **)error {
	PSProxyProfile *temporary = [self temporaryProfile] ?: [self lastTemporaryProfile];
	if (!temporary) {
		if (error) {
			*error = [NSError errorWithDomain:@"ProxySwitcher" code:405 userInfo:@{NSLocalizedDescriptionKey: @"Temporary proxy profile not found."}];
		}
		return NO;
	}
#if defined(PROXYSWITCHER_APP_ONLY) || defined(PROXYSWITCHER_APP_CLIENT)
	if ([self isVPNModeAvailable] && [self isCompatibilityModeEnabled]) {
		return [self appOnlyConfigureAndStartWithProfile:temporary identifier:PSProxyTemporaryIdentifier error:error];
	}
#endif
#ifdef PROXYSWITCHER_APP_ONLY
	return [self appOnlyConfigureAndStartWithProfile:temporary identifier:PSProxyTemporaryIdentifier error:error];
#elif !defined(PROXYSWITCHER_HELPER)
	NSError *helperError = nil;
	BOOL ok = [self runHelperWithArguments:@[@"apply-temp"] error:&helperError];
	if (ok) {
		[self setTemporaryProfile:temporary];
		return YES;
	}
	if (PSIsHelperUnreachableError(helperError)) {
		[self syncActiveProfileWithCurrentSystemProxy:nil];
		PSProxyProfile *currentProfile = [self currentSystemProxyProfile];
		if (currentProfile && PSProxyProfilesEqual(currentProfile, temporary)) {
			return YES;
		}
	}
	if (error) {
		*error = helperError;
	}
	return NO;
#else
	BOOL ok = [self applyProxyConfiguration:temporary error:error];
	if (ok) {
		[self setWiFiServiceIdentifier:[self currentWiFiServiceIdentifier] forSSID:[self currentWiFiSSID]];
		[self setTemporaryProfile:temporary];
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
#if defined(PROXYSWITCHER_APP_ONLY) || defined(PROXYSWITCHER_APP_CLIENT)
	if ([self isVPNModeAvailable] && [self isCompatibilityModeEnabled]) {
		if (error) {
			*error = [NSError errorWithDomain:@"ProxySwitcher" code:35 userInfo:@{NSLocalizedDescriptionKey: @"Wi-Fi switching is disabled in compatibility (VPN) mode."}];
		}
		return NO;
	}
#endif
#ifdef PROXYSWITCHER_APP_ONLY
	if (error) {
		*error = [NSError errorWithDomain:@"ProxySwitcher" code:35 userInfo:@{NSLocalizedDescriptionKey: @"Wi-Fi switching requires jailbreak helper and is unavailable in app-only mode."}];
	}
	return NO;
#elif !defined(PROXYSWITCHER_HELPER)
	NSError *helperError = nil;
	BOOL ok = [self runHelperWithArguments:@[@"wifi", ssid] timeout:PSProxyHelperWiFiTimeout response:nil error:&helperError];
	if (ok) {
		[self setWiFiServiceIdentifier:[self currentWiFiServiceIdentifier] forSSID:[self currentWiFiSSID]];
		[self syncActiveProfileWithCurrentSystemProxy:nil];
		return YES;
	}
	if (PSIsHelperUnreachableError(helperError)) {
		NSString *currentSSID = [self currentWiFiSSID];
		if ([currentSSID isEqualToString:ssid]) {
			[self setWiFiServiceIdentifier:[self currentWiFiServiceIdentifier] forSSID:currentSSID];
			[self syncActiveProfileWithCurrentSystemProxy:nil];
			return YES;
		}
	}
	if (error) {
		*error = helperError;
	}
	return NO;
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
			PSWaitForWiFiSSID(ssid, 15.0);
			[self setWiFiServiceIdentifier:[self currentWiFiServiceIdentifier] forSSID:ssid];
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

	PSWaitForWiFiSSID(ssid, 15.0);
	[self setWiFiServiceIdentifier:[self currentWiFiServiceIdentifier] forSSID:ssid];
	[self syncActiveProfileWithCurrentSystemProxy:nil];
	CFRelease(manager);
	return YES;
#endif
}

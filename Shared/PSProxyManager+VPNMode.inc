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
			temporary.name = @"Temporary";
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

- (BOOL)isCompatibilityModeEnabled {
#ifdef PROXYSWITCHER_APP_ONLY
	return YES;
#else
	return [[self storeDictionary][PSCompatibilityModeKey] boolValue];
#endif
}

- (void)setCompatibilityModeEnabled:(BOOL)enabled {
#ifdef PROXYSWITCHER_APP_ONLY
	#pragma unused(enabled)
	return;
#else
	NSMutableDictionary *store = [self storeDictionary].mutableCopy;
	store[PSCompatibilityModeKey] = @(enabled);
	[self writeStoreDictionary:store];
#endif
}

- (BOOL)isVPNModeAvailable {
#ifdef PROXYSWITCHER_APP_CLIENT
	return YES;
#else
	return NO;
#endif
}

#ifdef PROXYSWITCHER_APP_CLIENT
- (NETunnelProviderManager *)appOnlyTunnelManager {
	__block NSArray<NETunnelProviderManager *> *managers = nil;
	__block NSError *loadError = nil;
	dispatch_semaphore_t semaphore = dispatch_semaphore_create(0);
	[NETunnelProviderManager loadAllFromPreferencesWithCompletionHandler:^(NSArray<NETunnelProviderManager *> *loadedManagers, NSError *error) {
		managers = loadedManagers;
		loadError = error;
		dispatch_semaphore_signal(semaphore);
	}];
	dispatch_time_t timeout = dispatch_time(DISPATCH_TIME_NOW, (int64_t)(5.0 * NSEC_PER_SEC));
	if (dispatch_semaphore_wait(semaphore, timeout) != 0 || loadError) {
		return nil;
	}
	for (NETunnelProviderManager *manager in managers) {
		if ([manager.localizedDescription isEqualToString:PSVPNProxyDescription]) {
			return manager;
		}
	}
	return managers.firstObject;
}

- (NSError *)appOnlyWaitForSaveCompletion:(void (^)(void (^completion)(NSError *error)))saveInvoker {
	if (!saveInvoker) {
		return [NSError errorWithDomain:PSDiagnosticsErrorDomain code:61 userInfo:@{NSLocalizedDescriptionKey: @"Invalid VPN save operation."}];
	}
	__block NSError *saveError = nil;
	__block BOOL done = NO;
	saveInvoker(^(NSError *error){
		saveError = error;
		done = YES;
	});
	if (!PSWaitForCondition(8.0, ^BOOL{
		return done;
	})) {
		return [NSError errorWithDomain:PSDiagnosticsErrorDomain code:62 userInfo:@{NSLocalizedDescriptionKey: @"VPN preference update timed out."}];
	}
	return saveError;
}

- (BOOL)appOnlySyncActiveProfileWithError:(NSError **)error {
	#pragma unused(error)
	NETunnelProviderManager *manager = [self appOnlyTunnelManager];
	if (!manager) {
		[self setActiveIdentifier:PSProxyDirectIdentifier];
		return YES;
	}
	NEVPNStatus status = manager.connection.status;
	if (status == NEVPNStatusConnecting || status == NEVPNStatusReasserting) {
		// Keep current in-memory/store selection while tunnel state is transitioning.
		// Forcing Direct here can race against deeplink-triggered profile switches.
		return YES;
	}
	if (status != NEVPNStatusConnected) {
		[self setActiveIdentifier:PSProxyDirectIdentifier];
		return YES;
	}
	NETunnelProviderProtocol *providerProtocol = [manager.protocolConfiguration isKindOfClass:NETunnelProviderProtocol.class] ? (NETunnelProviderProtocol *)manager.protocolConfiguration : nil;
	NSDictionary *settings = [providerProtocol.providerConfiguration isKindOfClass:NSDictionary.class] ? providerProtocol.providerConfiguration : nil;
	NSString *identifier = [settings[@"activeIdentifier"] isKindOfClass:NSString.class] ? settings[@"activeIdentifier"] : nil;
	if (identifier.length == 0) {
		identifier = PSProxyTemporaryIdentifier;
	}
	if ([identifier isEqualToString:PSProxyTemporaryIdentifier]) {
		NSString *host = [settings[@"httpHost"] isKindOfClass:NSString.class] ? settings[@"httpHost"] : nil;
		NSInteger port = [settings[@"httpPort"] respondsToSelector:@selector(integerValue)] ? [settings[@"httpPort"] integerValue] : 0;
		if (host.length > 0 && port > 0 && port <= 65535) {
			PSProxyProfile *temporary = [[PSProxyProfile alloc] init];
			temporary.identifier = PSProxyTemporaryIdentifier;
			temporary.name = @"Temporary";
			temporary.host = host;
			temporary.port = port;
			temporary.username = [settings[@"httpUsername"] isKindOfClass:NSString.class] ? settings[@"httpUsername"] : nil;
			temporary.password = [settings[@"httpPassword"] isKindOfClass:NSString.class] ? settings[@"httpPassword"] : nil;
			temporary.noProxy = [settings[@"httpNoProxy"] isKindOfClass:NSArray.class] ? settings[@"httpNoProxy"] : nil;
			[self setTemporaryProfile:temporary];
			return YES;
		}
	}
	if ([identifier isEqualToString:PSProxyDirectIdentifier] || [self profileWithIdentifier:identifier]) {
		[self setActiveIdentifier:identifier];
		return YES;
	}
	[self setActiveIdentifier:PSProxyDirectIdentifier];
	return YES;
}

- (BOOL)appOnlyConfigureAndStartWithProfile:(PSProxyProfile *)profile identifier:(NSString *)identifier error:(NSError **)error {
	NETunnelProviderManager *manager = [self appOnlyTunnelManager] ?: [[NETunnelProviderManager alloc] init];
	NETunnelProviderProtocol *protocol = [manager.protocolConfiguration isKindOfClass:NETunnelProviderProtocol.class] ? (NETunnelProviderProtocol *)manager.protocolConfiguration : [[NETunnelProviderProtocol alloc] init];
	protocol.providerBundleIdentifier = [PSMainBundleIdentifier() stringByAppendingString:@".tunnel"];
	protocol.serverAddress = profile.host.length > 0 ? profile.host : @"127.0.0.1";
	NSMutableDictionary *providerConfiguration = [NSMutableDictionary dictionary];
	providerConfiguration[@"activeIdentifier"] = identifier ?: PSProxyTemporaryIdentifier;
	providerConfiguration[@"httpHost"] = profile.host ?: @"";
	providerConfiguration[@"httpPort"] = @(profile.port);
	if (profile.username.length > 0) {
		providerConfiguration[@"httpUsername"] = profile.username;
	}
	if (profile.password.length > 0) {
		providerConfiguration[@"httpPassword"] = profile.password;
	}
	if (profile.noProxy.count > 0) {
		providerConfiguration[@"httpNoProxy"] = profile.noProxy;
	}
	protocol.providerConfiguration = providerConfiguration;

	NEProxySettings *proxySettings = [[NEProxySettings alloc] init];
	proxySettings.HTTPEnabled = YES;
	proxySettings.HTTPServer = [[NEProxyServer alloc] initWithAddress:profile.host port:(NSInteger)profile.port];
	proxySettings.HTTPSEnabled = YES;
	proxySettings.HTTPSServer = [[NEProxyServer alloc] initWithAddress:profile.host port:(NSInteger)profile.port];
	PSNormalizeAndApplyProxyExceptions(proxySettings, profile.noProxy);
	protocol.proxySettings = proxySettings;

	manager.localizedDescription = PSVPNProxyDescription;
	manager.enabled = YES;
	manager.protocolConfiguration = protocol;

	NSError *saveError = [self appOnlyWaitForSaveCompletion:^(void (^completion)(NSError *error)) {
		[manager saveToPreferencesWithCompletionHandler:completion];
	}];
	if (saveError) {
		if (error) {
			*error = saveError;
		}
		return NO;
	}
	__block NSError *reloadError = nil;
	__block BOOL reloadDone = NO;
	[manager loadFromPreferencesWithCompletionHandler:^(NSError * _Nullable error) {
		reloadError = error;
		reloadDone = YES;
	}];
	if (!PSWaitForCondition(8.0, ^BOOL{
		return reloadDone;
	})) {
		if (error) {
			*error = [NSError errorWithDomain:PSDiagnosticsErrorDomain code:64 userInfo:@{NSLocalizedDescriptionKey: @"VPN preference reload timed out."}];
		}
		return NO;
	}
	if (reloadError) {
		if (error) {
			*error = reloadError;
		}
		return NO;
	}

	NSError *startError = nil;
	BOOL started = [manager.connection startVPNTunnelAndReturnError:&startError];
	if (!started && manager.connection.status != NEVPNStatusConnected && manager.connection.status != NEVPNStatusConnecting) {
		[self setActiveIdentifier:PSProxyDirectIdentifier];
		if (error) {
			*error = startError ?: [NSError errorWithDomain:PSDiagnosticsErrorDomain code:63 userInfo:@{NSLocalizedDescriptionKey: @"Unable to start VPN proxy tunnel."}];
		}
		return NO;
	}
	if (started) {
		__block BOOL terminalEvent = NO;
		__block BOOL connected = NO;
		__block id observer = nil;
		NSOperationQueue *queue = NSOperationQueue.mainQueue;
		observer = [NSNotificationCenter.defaultCenter addObserverForName:NEVPNStatusDidChangeNotification object:manager.connection queue:queue usingBlock:^(NSNotification * _Nonnull note) {
			#pragma unused(note)
			NEVPNStatus status = manager.connection.status;
			if (status == NEVPNStatusConnected) {
				connected = YES;
				terminalEvent = YES;
				return;
			}
			if (status == NEVPNStatusDisconnected || status == NEVPNStatusInvalid) {
				terminalEvent = YES;
			}
		}];
		PSWaitForCondition(8.0, ^BOOL{
			return terminalEvent;
		});
		if (observer) {
			[NSNotificationCenter.defaultCenter removeObserver:observer];
		}
		if (!connected) {
			[self setActiveIdentifier:PSProxyDirectIdentifier];
			NSError *disconnectError = nil;
			if ([manager.connection respondsToSelector:@selector(lastDisconnectError)]) {
#pragma clang diagnostic push
#pragma clang diagnostic ignored "-Warc-performSelector-leaks"
				disconnectError = [manager.connection performSelector:@selector(lastDisconnectError)];
#pragma clang diagnostic pop
			}
			if (error) {
				*error = disconnectError ?: [NSError errorWithDomain:PSDiagnosticsErrorDomain code:65 userInfo:@{NSLocalizedDescriptionKey: @"VPN tunnel did not reach connected state."}];
			}
			return NO;
		}
	}
	if (![self profileWithIdentifier:identifier]) {
		[self setTemporaryProfile:profile];
	} else {
		[self setActiveIdentifier:identifier];
	}
	return YES;
}

- (BOOL)appOnlyStopTunnelWithError:(NSError **)error {
	NETunnelProviderManager *manager = [self appOnlyTunnelManager];
	if (!manager) {
		[self setActiveIdentifier:PSProxyDirectIdentifier];
		return YES;
	}
	[manager.connection stopVPNTunnel];
	NETunnelProviderProtocol *protocol = [manager.protocolConfiguration isKindOfClass:NETunnelProviderProtocol.class] ? (NETunnelProviderProtocol *)manager.protocolConfiguration : nil;
	if (protocol) {
		NSMutableDictionary *providerConfiguration = [protocol.providerConfiguration isKindOfClass:NSDictionary.class] ? [protocol.providerConfiguration mutableCopy] : [NSMutableDictionary dictionary];
		providerConfiguration[@"activeIdentifier"] = PSProxyDirectIdentifier;
		[providerConfiguration removeObjectForKey:@"httpHost"];
		[providerConfiguration removeObjectForKey:@"httpPort"];
		[providerConfiguration removeObjectForKey:@"httpUsername"];
		[providerConfiguration removeObjectForKey:@"httpPassword"];
		[providerConfiguration removeObjectForKey:@"httpNoProxy"];
		protocol.providerConfiguration = providerConfiguration;
		protocol.proxySettings = nil;
		manager.protocolConfiguration = protocol;
		NSError *saveError = [self appOnlyWaitForSaveCompletion:^(void (^completion)(NSError *)) {
			[manager saveToPreferencesWithCompletionHandler:completion];
		}];
		if (saveError && error) {
			*error = saveError;
		}
	}
	[self setActiveIdentifier:PSProxyDirectIdentifier];
	return YES;
}
#endif

- (BOOL)runHelperWithArguments:(NSArray<NSString *> *)arguments error:(NSError **)error {
	return [self runHelperWithArguments:arguments response:nil error:error];
}

- (BOOL)runHelperWithArguments:(NSArray<NSString *> *)arguments response:(NSString **)responseMessage error:(NSError **)error {
	return [self runHelperWithArguments:arguments timeout:PSProxyHelperDefaultTimeout response:responseMessage error:error];
}

- (BOOL)runHelperWithArguments:(NSArray<NSString *> *)arguments timeout:(NSTimeInterval)timeout response:(NSString **)responseMessage error:(NSError **)error {
	NSString *helperPath = PSHelperPath();
	if (![[NSFileManager defaultManager] fileExistsAtPath:helperPath]) {
		if (error) {
			*error = [NSError errorWithDomain:PSDiagnosticsErrorDomain code:PSHelperErrorNotInstalled userInfo:@{
				NSLocalizedDescriptionKey: @"ProxySwitcher helper is not installed.",
				@"reason": @"helper_missing"
			}];
		}
		return NO;
	}

	int socketFD = socket(AF_UNIX, SOCK_STREAM, 0);
	if (socketFD < 0) {
		if (error) {
			*error = [NSError errorWithDomain:PSDiagnosticsErrorDomain code:PSHelperErrorRequestWriteFailed userInfo:@{
				NSLocalizedDescriptionKey: @"Unable to open helper socket.",
				@"reason": @"socket_open_failed"
			}];
		}
		return NO;
	}

	struct timeval socketTimeout;
	socketTimeout.tv_sec = (time_t)timeout;
	socketTimeout.tv_usec = (suseconds_t)((timeout - socketTimeout.tv_sec) * 1000000.0);
	setsockopt(socketFD, SOL_SOCKET, SO_RCVTIMEO, &socketTimeout, sizeof(socketTimeout));
	setsockopt(socketFD, SOL_SOCKET, SO_SNDTIMEO, &socketTimeout, sizeof(socketTimeout));

	struct sockaddr_un address;
	BOOL connected = NO;
	for (NSString *socketPath in PSHelperSocketPathCandidates()) {
		memset(&address, 0, sizeof(address));
		address.sun_family = AF_UNIX;
		if (socketPath.length >= sizeof(address.sun_path)) {
			continue;
		}
		strlcpy(address.sun_path, socketPath.fileSystemRepresentation, sizeof(address.sun_path));
		if (connect(socketFD, (struct sockaddr *)&address, sizeof(address)) == 0) {
			connected = YES;
			break;
		}
	}
	if (!connected) {
		close(socketFD);
		if (error) {
			*error = [NSError errorWithDomain:PSDiagnosticsErrorDomain code:PSHelperErrorUnreachable userInfo:@{
				NSLocalizedDescriptionKey: @"ProxySwitcher helper did not respond.",
				@"reason": @"socket_connect_failed"
			}];
		}
		return NO;
	}

	NSDictionary *request = @{
		@"version": PSProtocolVersion,
		@"command": arguments.firstObject ?: @"",
		@"argument": arguments.count > 1 ? arguments[1] : @""
	};
	NSData *requestData = [NSJSONSerialization dataWithJSONObject:request options:0 error:nil];
	if (!requestData) {
		close(socketFD);
		if (error) {
			*error = [NSError errorWithDomain:PSDiagnosticsErrorDomain code:PSHelperErrorRequestWriteFailed userInfo:@{
				NSLocalizedDescriptionKey: @"Unable to encode helper request.",
				@"reason": @"request_encode_failed"
			}];
		}
		return NO;
	}
	NSMutableData *lineData = [requestData mutableCopy];
	[lineData appendData:[@"\n" dataUsingEncoding:NSUTF8StringEncoding]];
	const uint8_t *bytes = lineData.bytes;
	NSUInteger remaining = lineData.length;
	while (remaining > 0) {
		ssize_t written = write(socketFD, bytes, remaining);
		if (written <= 0) {
			close(socketFD);
			if (error) {
				*error = [NSError errorWithDomain:PSDiagnosticsErrorDomain code:PSHelperErrorRequestWriteFailed userInfo:@{
					NSLocalizedDescriptionKey: @"Unable to write helper request.",
					@"reason": @"request_write_failed"
				}];
			}
			return NO;
		}
		bytes += written;
		remaining -= (NSUInteger)written;
	}
	shutdown(socketFD, SHUT_WR);

	NSMutableData *responseData = [NSMutableData data];
	uint8_t buffer[1024];
	BOOL sawNewline = NO;
	while (responseData.length < PSProxyHelperMaxResponseLength) {
		ssize_t count = read(socketFD, buffer, sizeof(buffer));
		if (count < 0) {
			close(socketFD);
			if (error) {
				*error = [NSError errorWithDomain:PSDiagnosticsErrorDomain code:PSHelperErrorUnreachable userInfo:@{
					NSLocalizedDescriptionKey: @"ProxySwitcher helper did not respond.",
					@"reason": @"response_read_failed"
				}];
			}
			return NO;
		}
		if (count == 0) {
			break;
		}
		NSUInteger length = (NSUInteger)count;
		for (NSUInteger index = 0; index < length; index++) {
			if (buffer[index] == '\n') {
				[responseData appendBytes:buffer length:index];
				sawNewline = YES;
				break;
			}
		}
		if (sawNewline) {
			break;
		}
		[responseData appendBytes:buffer length:length];
	}
	close(socketFD);

	if (responseData.length == 0) {
		if (error) {
			*error = [NSError errorWithDomain:PSDiagnosticsErrorDomain code:PSHelperErrorUnreachable userInfo:@{
				NSLocalizedDescriptionKey: @"ProxySwitcher helper did not respond.",
				@"reason": @"response_empty"
			}];
		}
		return NO;
	}

	NSDictionary *response = [NSJSONSerialization JSONObjectWithData:responseData options:0 error:nil];
	if (![response isKindOfClass:NSDictionary.class]) {
		if (error) {
			*error = [NSError errorWithDomain:PSDiagnosticsErrorDomain code:PSHelperErrorInvalidResponse userInfo:@{
				NSLocalizedDescriptionKey: @"ProxySwitcher helper returned an invalid response.",
				@"reason": @"response_invalid_json"
			}];
		}
		return NO;
	}
	if (![response[@"version"] isKindOfClass:NSString.class] || ![response[@"version"] isEqualToString:PSProtocolVersion]) {
		if (error) {
			*error = [NSError errorWithDomain:PSDiagnosticsErrorDomain code:PSHelperErrorInvalidResponse userInfo:@{
				NSLocalizedDescriptionKey: @"ProxySwitcher helper protocol version mismatch.",
				@"reason": @"protocol_mismatch"
			}];
		}
		return NO;
	}
	BOOL ok = [response[@"ok"] boolValue];
	NSString *message = [response[@"message"] isKindOfClass:NSString.class] ? response[@"message"] : @"";
	if (ok) {
		if (responseMessage) {
			*responseMessage = message ?: @"";
		}
		return YES;
	}
	NSNumber *codeNumber = [response[@"code"] respondsToSelector:@selector(integerValue)] ? response[@"code"] : @(PSHelperErrorOperationFailed);
	NSString *reason = [response[@"reason"] isKindOfClass:NSString.class] ? response[@"reason"] : @"operation_failed";
	if (error) {
		*error = [NSError errorWithDomain:PSDiagnosticsErrorDomain code:codeNumber.integerValue userInfo:@{
			NSLocalizedDescriptionKey: message.length > 0 ? message : @"ProxySwitcher helper could not update proxy settings.",
			@"reason": reason
		}];
	}
	return NO;
}

#import "PSProxyManager.h"
#import <Foundation/Foundation.h>
#import <notify.h>
#import <roothide.h>
#import <sys/stat.h>
#import <unistd.h>

static NSString *StringFromLine(char *line) {
	if (!line) {
		return nil;
	}
	line[strcspn(line, "\r\n")] = '\0';
	return [NSString stringWithUTF8String:line] ?: @"";
}

static NSString *JailbreakPath(NSString *path) {
#ifdef THEOS_PACKAGE_SCHEME_ROOTHIDE
	return jbroot(path);
#else
	return path;
#endif
}

static BOOL RunCommand(NSString *command, NSString *profileIdentifier, NSError **error) {
	if ([command isEqualToString:@"direct"]) {
		return [[PSProxyManager sharedManager] applyDirectWithError:error];
	}
	if ([command isEqualToString:@"apply"] && profileIdentifier.length > 0) {
		return [[PSProxyManager sharedManager] applyProfileWithIdentifier:profileIdentifier error:error];
	}
	if (error) {
		*error = [NSError errorWithDomain:@"ProxySwitcher" code:64 userInfo:@{NSLocalizedDescriptionKey: @"Invalid helper request."}];
	}
	return NO;
}

static BOOL HandleRequest(void) {
	@autoreleasepool {
		NSString *requestPath = JailbreakPath(@"/var/mobile/Library/Preferences/codes.var.tweak.proxyswitcher.request");
		NSString *responsePath = JailbreakPath(@"/var/mobile/Library/Preferences/codes.var.tweak.proxyswitcher.response");
		FILE *requestFile = fopen(requestPath.fileSystemRepresentation, "r");
		if (!requestFile) {
			return NO;
		}
		char requestIdentifierLine[256] = {0};
		char commandLine[64] = {0};
		char profileIdentifierLine[256] = {0};
		fgets(requestIdentifierLine, sizeof(requestIdentifierLine), requestFile);
		fgets(commandLine, sizeof(commandLine), requestFile);
		fgets(profileIdentifierLine, sizeof(profileIdentifierLine), requestFile);
		fclose(requestFile);

		NSString *requestIdentifier = StringFromLine(requestIdentifierLine);
		NSString *command = StringFromLine(commandLine);
		NSString *profileIdentifier = StringFromLine(profileIdentifierLine);
		if (requestIdentifier.length == 0) {
			return NO;
		}

		NSError *error = nil;
		BOOL ok = RunCommand(command, profileIdentifier, &error);
		NSString *message = ok ? @"" : (error.localizedDescription ?: @"Unable to update proxy settings.");
		FILE *responseFile = fopen(responsePath.fileSystemRepresentation, "w");
		if (responseFile) {
			fprintf(responseFile, "%s\n%s\n%s\n", requestIdentifier.UTF8String, ok ? "1" : "0", message.UTF8String);
			fclose(responseFile);
		}
		chown(responsePath.fileSystemRepresentation, 501, 501);
		chmod(responsePath.fileSystemRepresentation, 0644);
	}
	return YES;
}

int main(int argc, char *argv[]) {
	@autoreleasepool {
		if (argc >= 2) {
			NSString *command = [NSString stringWithUTF8String:argv[1]];
			if ([command isEqualToString:@"once"]) {
				return HandleRequest() ? 0 : 2;
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

		HandleRequest();
		int token = 0;
		notify_register_dispatch(PSProxyRequestNotification.UTF8String, &token, dispatch_get_main_queue(), ^(int receivedToken) {
			HandleRequest();
		});
		[[NSRunLoop mainRunLoop] run];
	}
	return 0;
}

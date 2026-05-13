#import "PSRootViewController.h"
#import "PSProxyManager.h"
#import <notify.h>

@interface PSRootViewController ()

@property (nonatomic, copy) NSArray<PSProxyProfile *> *profiles;
@property (nonatomic, copy) NSArray<PSWiFiNetwork *> *wifiNetworks;
@property (nonatomic, copy) NSString *activeIdentifier;
@property (nonatomic, strong) PSProxyProfile *temporaryProfile;
@property (nonatomic, assign) int notifyToken;
@property (nonatomic, assign) NSUInteger reloadGeneration;

@end

@implementation PSRootViewController

- (void)viewDidLoad {
	[super viewDidLoad];
	self.title = @"ProxySwitcher";
	self.navigationItem.rightBarButtonItem = [[UIBarButtonItem alloc] initWithBarButtonSystemItem:UIBarButtonSystemItemAdd target:self action:@selector(showAddMenu)];
	[self.tableView registerClass:UITableViewCell.class forCellReuseIdentifier:@"Cell"];
	[NSNotificationCenter.defaultCenter addObserver:self selector:@selector(reloadProfiles) name:UIApplicationDidBecomeActiveNotification object:nil];
	__weak typeof(self) weakSelf = self;
	notify_register_dispatch(PSProxyProfilesChangedNotification.UTF8String, &_notifyToken, dispatch_get_main_queue(), ^(int token) {
		[weakSelf reloadProfiles];
	});
	[self reloadProfiles];
}

- (void)dealloc {
	[NSNotificationCenter.defaultCenter removeObserver:self];
	if (_notifyToken) {
		notify_cancel(_notifyToken);
	}
}

- (void)viewWillAppear:(BOOL)animated {
	[super viewWillAppear:animated];
	[self reloadProfiles];
}

- (void)reloadProfiles {
	NSUInteger generation = self.reloadGeneration + 1;
	self.reloadGeneration = generation;
	dispatch_async(dispatch_get_global_queue(QOS_CLASS_UTILITY, 0), ^{
		PSProxyManager *manager = [PSProxyManager sharedManager];
		[manager syncActiveProfileWithCurrentSystemProxy:nil];
		NSArray<PSProxyProfile *> *profiles = [manager profiles];
		NSArray<PSWiFiNetwork *> *wifiNetworks = [manager quickWiFiNetworks];
		NSString *activeIdentifier = [manager activeIdentifier];
		PSProxyProfile *temporaryProfile = [manager temporaryProfile];
		dispatch_async(dispatch_get_main_queue(), ^{
			if (generation != self.reloadGeneration) {
				return;
			}
			self.profiles = profiles;
			self.wifiNetworks = wifiNetworks;
			self.activeIdentifier = activeIdentifier;
			self.temporaryProfile = temporaryProfile;
			[self.tableView reloadData];
		});
	});
}

- (NSInteger)numberOfSectionsInTableView:(UITableView *)tableView {
	return 3;
}

- (NSInteger)tableView:(UITableView *)tableView numberOfRowsInSection:(NSInteger)section {
	if (section == 0) {
		return 1;
	}
	if (section == 1) {
		return self.profiles.count;
	}
	return self.wifiNetworks.count;
}

- (NSString *)tableView:(UITableView *)tableView titleForHeaderInSection:(NSInteger)section {
	if (section == 0) {
		return @"Direct";
	}
	if (section == 1) {
		return @"Profiles";
	}
	return @"Wi-Fi";
}

- (NSString *)tableView:(UITableView *)tableView titleForFooterInSection:(NSInteger)section {
	if (section == 0) {
		return @"Tap Direct or a saved proxy to immediately update the active Wi-Fi HTTP proxy. If the current Wi-Fi uses a proxy that does not match a profile, it is shown here temporarily.";
	}
	if (section == 1) {
		return self.profiles.count == 0 ? @"Add a proxy profile first. The Control Center module cycles through Direct and these profiles." : nil;
	}
	return self.wifiNetworks.count == 0 ? @"Add saved SSIDs here for quick switching." : @"Tap a saved SSID to join it. After the switch, ProxySwitcher follows the proxy configuration already saved by iOS for that Wi-Fi.";
}

- (UITableViewCell *)tableView:(UITableView *)tableView cellForRowAtIndexPath:(NSIndexPath *)indexPath {
	UITableViewCell *cell = [tableView dequeueReusableCellWithIdentifier:@"Cell" forIndexPath:indexPath];
	UIListContentConfiguration *content = UIListContentConfiguration.valueCellConfiguration;
	NSString *activeIdentifier = self.activeIdentifier ?: PSProxyDirectIdentifier;

	if (indexPath.section == 0) {
		PSProxyProfile *temporaryProfile = self.temporaryProfile;
		content.text = @"Direct";
		content.secondaryText = temporaryProfile ? [NSString stringWithFormat:@"Current Wi-Fi proxy: %@:%ld", temporaryProfile.host, (long)temporaryProfile.port] : @"No HTTP proxy";
		cell.accessoryType = [activeIdentifier isEqualToString:PSProxyDirectIdentifier] ? UITableViewCellAccessoryCheckmark : UITableViewCellAccessoryNone;
	} else if (indexPath.section == 1) {
		PSProxyProfile *profile = self.profiles[indexPath.row];
		content.text = profile.name;
		content.secondaryText = [NSString stringWithFormat:@"%@:%ld", profile.host, (long)profile.port];
		cell.accessoryType = [activeIdentifier isEqualToString:profile.identifier] ? UITableViewCellAccessoryCheckmark : UITableViewCellAccessoryNone;
	} else {
		PSWiFiNetwork *network = self.wifiNetworks[indexPath.row];
		content.text = network.displayName;
		content.secondaryText = network.proxyProfile ? [NSString stringWithFormat:@"Saved proxy: %@:%ld", network.proxyProfile.host, (long)network.proxyProfile.port] : @"Saved proxy: Direct";
		cell.accessoryType = network.current ? UITableViewCellAccessoryCheckmark : UITableViewCellAccessoryNone;
	}

	cell.contentConfiguration = content;
	return cell;
}

- (void)tableView:(UITableView *)tableView didSelectRowAtIndexPath:(NSIndexPath *)indexPath {
	[tableView deselectRowAtIndexPath:indexPath animated:YES];

	void (^operation)(void) = nil;
	if (indexPath.section == 0) {
		operation = ^{
			NSError *error;
			BOOL ok = [[PSProxyManager sharedManager] applyDirectWithError:&error];
			[self finishOperationWithSuccess:ok error:error];
		};
	} else if (indexPath.section == 1) {
		PSProxyProfile *profile = self.profiles[indexPath.row];
		NSString *identifier = profile.identifier;
		operation = ^{
			NSError *error;
			BOOL ok = [[PSProxyManager sharedManager] applyProfileWithIdentifier:identifier error:&error];
			[self finishOperationWithSuccess:ok error:error];
		};
	} else {
		PSWiFiNetwork *network = self.wifiNetworks[indexPath.row];
		NSString *ssid = network.ssid;
		operation = ^{
			NSError *error;
			BOOL ok = [[PSProxyManager sharedManager] switchToWiFiSSID:ssid error:&error];
			[self finishOperationWithSuccess:ok error:error];
		};
	}

	if (operation) {
		dispatch_async(dispatch_get_global_queue(QOS_CLASS_UTILITY, 0), operation);
	}
}

- (void)finishOperationWithSuccess:(BOOL)ok error:(NSError *)error {
	dispatch_async(dispatch_get_main_queue(), ^{
		if (!ok) {
			[self showError:error.localizedDescription ?: @"Unable to update settings."];
		}
		[self reloadProfiles];
	});
}

- (BOOL)tableView:(UITableView *)tableView canEditRowAtIndexPath:(NSIndexPath *)indexPath {
	return indexPath.section == 1 || indexPath.section == 2;
}

- (void)tableView:(UITableView *)tableView commitEditingStyle:(UITableViewCellEditingStyle)editingStyle forRowAtIndexPath:(NSIndexPath *)indexPath {
	if (editingStyle != UITableViewCellEditingStyleDelete) {
		return;
	}
	if (indexPath.section == 1) {
		PSProxyProfile *profile = self.profiles[indexPath.row];
		[[PSProxyManager sharedManager] deleteProfileWithIdentifier:profile.identifier];
	} else {
		PSWiFiNetwork *network = self.wifiNetworks[indexPath.row];
		[[PSProxyManager sharedManager] deleteQuickWiFiSSID:network.ssid];
	}
	[self reloadProfiles];
}

- (UIContextualAction *)editActionForProfile:(PSProxyProfile *)profile {
	return [UIContextualAction contextualActionWithStyle:UIContextualActionStyleNormal title:@"Edit" handler:^(__kindof UIContextualAction *action, __kindof UIView *sourceView, void (^completionHandler)(BOOL)) {
		[self showProfileEditorWithProfile:profile];
		completionHandler(YES);
	}];
}

- (UISwipeActionsConfiguration *)tableView:(UITableView *)tableView trailingSwipeActionsConfigurationForRowAtIndexPath:(NSIndexPath *)indexPath {
	if (indexPath.section == 2) {
		PSWiFiNetwork *network = self.wifiNetworks[indexPath.row];
		UIContextualAction *deleteAction = [UIContextualAction contextualActionWithStyle:UIContextualActionStyleDestructive title:@"Delete" handler:^(__kindof UIContextualAction *action, __kindof UIView *sourceView, void (^completionHandler)(BOOL)) {
			[[PSProxyManager sharedManager] deleteQuickWiFiSSID:network.ssid];
			[self reloadProfiles];
			completionHandler(YES);
		}];
		return [UISwipeActionsConfiguration configurationWithActions:@[deleteAction]];
	}
	if (indexPath.section != 1) {
		return nil;
	}
	PSProxyProfile *profile = self.profiles[indexPath.row];
	UIContextualAction *deleteAction = [UIContextualAction contextualActionWithStyle:UIContextualActionStyleDestructive title:@"Delete" handler:^(__kindof UIContextualAction *action, __kindof UIView *sourceView, void (^completionHandler)(BOOL)) {
		[[PSProxyManager sharedManager] deleteProfileWithIdentifier:profile.identifier];
		[self reloadProfiles];
		completionHandler(YES);
	}];
	return [UISwipeActionsConfiguration configurationWithActions:@[deleteAction, [self editActionForProfile:profile]]];
}

- (void)showAddMenu {
	UIAlertController *alert = [UIAlertController alertControllerWithTitle:@"Add" message:nil preferredStyle:UIAlertControllerStyleActionSheet];
	[alert addAction:[UIAlertAction actionWithTitle:@"Profile" style:UIAlertActionStyleDefault handler:^(__kindof UIAlertAction *action) {
		[self showProfileEditorWithProfile:nil];
	}]];
	[alert addAction:[UIAlertAction actionWithTitle:@"Saved Wi-Fi" style:UIAlertActionStyleDefault handler:^(__kindof UIAlertAction *action) {
		[self showWiFiPicker];
	}]];
	[alert addAction:[UIAlertAction actionWithTitle:@"Cancel" style:UIAlertActionStyleCancel handler:nil]];
	[self presentViewController:alert animated:YES completion:nil];
}

- (void)showWiFiPicker {
	NSMutableSet *existingSSIDs = [NSMutableSet set];
	for (PSWiFiNetwork *network in self.wifiNetworks) {
		if (network.ssid.length > 0) {
			[existingSSIDs addObject:network.ssid];
		}
	}
	dispatch_async(dispatch_get_global_queue(QOS_CLASS_UTILITY, 0), ^{
		NSArray<PSWiFiNetwork *> *availableNetworks = [[PSProxyManager sharedManager] availableWiFiNetworks];
		NSMutableArray<PSWiFiNetwork *> *candidates = [NSMutableArray array];
		for (PSWiFiNetwork *network in availableNetworks) {
			if (network.ssid.length > 0 && ![existingSSIDs containsObject:network.ssid]) {
				[candidates addObject:network];
			}
		}
		dispatch_async(dispatch_get_main_queue(), ^{
			if (candidates.count == 0) {
				[self showError:@"No additional saved Wi-Fi networks were found."];
				return;
			}

			UIAlertController *alert = [UIAlertController alertControllerWithTitle:@"Add Wi-Fi" message:nil preferredStyle:UIAlertControllerStyleActionSheet];
			for (PSWiFiNetwork *network in candidates) {
				NSString *title = network.proxyProfile ? [NSString stringWithFormat:@"%@  %@:%ld", network.displayName, network.proxyProfile.host, (long)network.proxyProfile.port] : network.displayName;
				[alert addAction:[UIAlertAction actionWithTitle:title style:UIAlertActionStyleDefault handler:^(__kindof UIAlertAction *action) {
					[[PSProxyManager sharedManager] addQuickWiFiSSID:network.ssid];
					[self reloadProfiles];
				}]];
			}
			[alert addAction:[UIAlertAction actionWithTitle:@"Cancel" style:UIAlertActionStyleCancel handler:nil]];
			[self presentViewController:alert animated:YES completion:nil];
		});
	});
}

- (void)showProfileEditorWithProfile:(PSProxyProfile *)profile {
	BOOL editing = profile != nil;
	UIAlertController *alert = [UIAlertController alertControllerWithTitle:editing ? @"Edit Proxy" : @"New Proxy" message:nil preferredStyle:UIAlertControllerStyleAlert];

	[alert addTextFieldWithConfigurationHandler:^(UITextField *textField) {
		textField.placeholder = @"Name";
		textField.text = editing ? profile.name : @"";
		textField.autocapitalizationType = UITextAutocapitalizationTypeWords;
	}];
	[alert addTextFieldWithConfigurationHandler:^(UITextField *textField) {
		textField.placeholder = @"Host";
		textField.text = editing ? profile.host : @"";
		textField.autocapitalizationType = UITextAutocapitalizationTypeNone;
		textField.autocorrectionType = UITextAutocorrectionTypeNo;
		textField.keyboardType = UIKeyboardTypeURL;
	}];
	[alert addTextFieldWithConfigurationHandler:^(UITextField *textField) {
		textField.placeholder = @"Port";
		textField.text = editing ? [NSString stringWithFormat:@"%ld", (long)profile.port] : @"8080";
		textField.keyboardType = UIKeyboardTypeNumberPad;
	}];
	[alert addTextFieldWithConfigurationHandler:^(UITextField *textField) {
		textField.placeholder = @"Username (optional)";
		textField.text = editing ? profile.username : @"";
		textField.autocapitalizationType = UITextAutocapitalizationTypeNone;
		textField.autocorrectionType = UITextAutocorrectionTypeNo;
	}];
	[alert addTextFieldWithConfigurationHandler:^(UITextField *textField) {
		textField.placeholder = @"Password (optional)";
		textField.text = editing ? profile.password : @"";
		textField.secureTextEntry = YES;
	}];

	__weak typeof(self) weakSelf = self;
	UIAlertAction *saveAction = [UIAlertAction actionWithTitle:@"Save" style:UIAlertActionStyleDefault handler:^(__kindof UIAlertAction *action) {
		PSProxyProfile *updated = editing ? profile : [[PSProxyProfile alloc] init];
		updated.name = alert.textFields[0].text.length > 0 ? alert.textFields[0].text : alert.textFields[1].text;
		updated.host = [alert.textFields[1].text stringByTrimmingCharactersInSet:NSCharacterSet.whitespaceAndNewlineCharacterSet];
		updated.port = alert.textFields[2].text.integerValue;
		updated.username = alert.textFields[3].text.length > 0 ? alert.textFields[3].text : nil;
		updated.password = alert.textFields[4].text.length > 0 ? alert.textFields[4].text : nil;

		if (updated.host.length == 0 || updated.port < 1 || updated.port > 65535) {
			[weakSelf showError:@"Host or port is invalid."];
			return;
		}

		[[PSProxyManager sharedManager] saveProfile:updated];
		[weakSelf reloadProfiles];
	}];
	[alert addAction:[UIAlertAction actionWithTitle:@"Cancel" style:UIAlertActionStyleCancel handler:nil]];
	[alert addAction:saveAction];
	[self presentViewController:alert animated:YES completion:nil];
}

- (void)showError:(NSString *)message {
	UIAlertController *alert = [UIAlertController alertControllerWithTitle:@"ProxySwitcher" message:message preferredStyle:UIAlertControllerStyleAlert];
	[alert addAction:[UIAlertAction actionWithTitle:@"OK" style:UIAlertActionStyleDefault handler:nil]];
	[self presentViewController:alert animated:YES completion:nil];
}

@end

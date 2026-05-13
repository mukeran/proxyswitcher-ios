#import "PSRootViewController.h"
#import "PSProxyManager.h"
#import <notify.h>

@interface PSRootViewController ()

@property (nonatomic, copy) NSArray<PSProxyProfile *> *profiles;
@property (nonatomic, copy) NSArray<PSWiFiNetwork *> *wifiNetworks;
@property (nonatomic, assign) int notifyToken;

@end

@implementation PSRootViewController

- (void)viewDidLoad {
	[super viewDidLoad];
	self.title = @"ProxySwitcher";
	self.navigationItem.rightBarButtonItem = [[UIBarButtonItem alloc] initWithBarButtonSystemItem:UIBarButtonSystemItemAdd target:self action:@selector(addProfile)];
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
	[[PSProxyManager sharedManager] syncActiveProfileWithCurrentSystemProxy:nil];
	self.profiles = [[PSProxyManager sharedManager] profiles];
	self.wifiNetworks = [[PSProxyManager sharedManager] quickWiFiNetworks];
	[self.tableView reloadData];
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
	return self.wifiNetworks.count + 1;
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
	NSString *activeIdentifier = [[PSProxyManager sharedManager] activeIdentifier];

	if (indexPath.section == 0) {
		PSProxyProfile *temporaryProfile = [[PSProxyManager sharedManager] temporaryProfile];
		content.text = @"Direct";
		content.secondaryText = temporaryProfile ? [NSString stringWithFormat:@"Current Wi-Fi proxy: %@:%ld", temporaryProfile.host, (long)temporaryProfile.port] : @"No HTTP proxy";
		cell.accessoryType = [activeIdentifier isEqualToString:PSProxyDirectIdentifier] ? UITableViewCellAccessoryCheckmark : UITableViewCellAccessoryNone;
	} else if (indexPath.section == 1) {
		PSProxyProfile *profile = self.profiles[indexPath.row];
		content.text = profile.name;
		content.secondaryText = [NSString stringWithFormat:@"%@:%ld", profile.host, (long)profile.port];
		cell.accessoryType = [activeIdentifier isEqualToString:profile.identifier] ? UITableViewCellAccessoryCheckmark : UITableViewCellAccessoryNone;
	} else {
		if (indexPath.row == 0) {
			content = UIListContentConfiguration.cellConfiguration;
			content.text = @"Add Saved Wi-Fi...";
			content.image = [UIImage systemImageNamed:@"plus.circle"];
			cell.accessoryType = UITableViewCellAccessoryNone;
			cell.contentConfiguration = content;
			return cell;
		}
		PSWiFiNetwork *network = self.wifiNetworks[indexPath.row - 1];
		content.text = network.displayName;
		content.secondaryText = network.proxyProfile ? [NSString stringWithFormat:@"Saved proxy: %@:%ld", network.proxyProfile.host, (long)network.proxyProfile.port] : @"Saved proxy: Direct";
		cell.accessoryType = network.current ? UITableViewCellAccessoryCheckmark : UITableViewCellAccessoryDisclosureIndicator;
	}

	cell.contentConfiguration = content;
	return cell;
}

- (void)tableView:(UITableView *)tableView didSelectRowAtIndexPath:(NSIndexPath *)indexPath {
	[tableView deselectRowAtIndexPath:indexPath animated:YES];

	NSError *error;
	BOOL ok;
	if (indexPath.section == 0) {
		ok = [[PSProxyManager sharedManager] applyDirectWithError:&error];
	} else if (indexPath.section == 1) {
		PSProxyProfile *profile = self.profiles[indexPath.row];
		ok = [[PSProxyManager sharedManager] applyProfileWithIdentifier:profile.identifier error:&error];
	} else {
		if (indexPath.row == 0) {
			[self showWiFiPicker];
			return;
		}
		PSWiFiNetwork *network = self.wifiNetworks[indexPath.row - 1];
		ok = [[PSProxyManager sharedManager] switchToWiFiSSID:network.ssid error:&error];
	}

	if (!ok) {
		[self showError:error.localizedDescription ?: @"Unable to update proxy settings."];
	}
	[self reloadProfiles];
}

- (BOOL)tableView:(UITableView *)tableView canEditRowAtIndexPath:(NSIndexPath *)indexPath {
	return indexPath.section == 1 || (indexPath.section == 2 && indexPath.row > 0);
}

- (void)tableView:(UITableView *)tableView commitEditingStyle:(UITableViewCellEditingStyle)editingStyle forRowAtIndexPath:(NSIndexPath *)indexPath {
	if (editingStyle != UITableViewCellEditingStyleDelete) {
		return;
	}
	if (indexPath.section == 1) {
		PSProxyProfile *profile = self.profiles[indexPath.row];
		[[PSProxyManager sharedManager] deleteProfileWithIdentifier:profile.identifier];
	} else {
		PSWiFiNetwork *network = self.wifiNetworks[indexPath.row - 1];
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
	if (indexPath.section == 2 && indexPath.row > 0) {
		PSWiFiNetwork *network = self.wifiNetworks[indexPath.row - 1];
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

- (void)addProfile {
	[self showProfileEditorWithProfile:nil];
}

- (void)showWiFiPicker {
	NSArray<PSWiFiNetwork *> *availableNetworks = [[PSProxyManager sharedManager] availableWiFiNetworks];
	NSMutableSet *existingSSIDs = [NSMutableSet set];
	for (PSWiFiNetwork *network in self.wifiNetworks) {
		if (network.ssid.length > 0) {
			[existingSSIDs addObject:network.ssid];
		}
	}
	NSMutableArray<PSWiFiNetwork *> *candidates = [NSMutableArray array];
	for (PSWiFiNetwork *network in availableNetworks) {
		if (network.ssid.length > 0 && ![existingSSIDs containsObject:network.ssid]) {
			[candidates addObject:network];
		}
	}
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

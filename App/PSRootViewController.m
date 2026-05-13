#import "PSRootViewController.h"
#import "PSProxyManager.h"
#import <notify.h>

@interface PSRootViewController ()

@property (nonatomic, copy) NSArray<PSProxyProfile *> *profiles;
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
	self.profiles = [[PSProxyManager sharedManager] profiles];
	[self.tableView reloadData];
}

- (NSInteger)numberOfSectionsInTableView:(UITableView *)tableView {
	return 2;
}

- (NSInteger)tableView:(UITableView *)tableView numberOfRowsInSection:(NSInteger)section {
	return section == 0 ? 1 : self.profiles.count;
}

- (NSString *)tableView:(UITableView *)tableView titleForHeaderInSection:(NSInteger)section {
	return section == 0 ? @"Direct" : @"Profiles";
}

- (NSString *)tableView:(UITableView *)tableView titleForFooterInSection:(NSInteger)section {
	if (section == 0) {
		return @"Tap Direct or a saved proxy to immediately update the active Wi-Fi HTTP proxy.";
	}
	return self.profiles.count == 0 ? @"Add a proxy profile first. The Control Center module cycles through Direct and these profiles." : nil;
}

- (UITableViewCell *)tableView:(UITableView *)tableView cellForRowAtIndexPath:(NSIndexPath *)indexPath {
	UITableViewCell *cell = [tableView dequeueReusableCellWithIdentifier:@"Cell" forIndexPath:indexPath];
	UIListContentConfiguration *content = UIListContentConfiguration.valueCellConfiguration;
	NSString *activeIdentifier = [[PSProxyManager sharedManager] activeIdentifier];

	if (indexPath.section == 0) {
		content.text = @"Direct";
		content.secondaryText = @"No HTTP proxy";
		cell.accessoryType = [activeIdentifier isEqualToString:PSProxyDirectIdentifier] ? UITableViewCellAccessoryCheckmark : UITableViewCellAccessoryNone;
	} else {
		PSProxyProfile *profile = self.profiles[indexPath.row];
		content.text = profile.name;
		content.secondaryText = [NSString stringWithFormat:@"%@:%ld", profile.host, (long)profile.port];
		cell.accessoryType = [activeIdentifier isEqualToString:profile.identifier] ? UITableViewCellAccessoryCheckmark : UITableViewCellAccessoryNone;
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
	} else {
		PSProxyProfile *profile = self.profiles[indexPath.row];
		ok = [[PSProxyManager sharedManager] applyProfileWithIdentifier:profile.identifier error:&error];
	}

	if (!ok) {
		[self showError:error.localizedDescription ?: @"Unable to update proxy settings."];
	}
	[self reloadProfiles];
}

- (BOOL)tableView:(UITableView *)tableView canEditRowAtIndexPath:(NSIndexPath *)indexPath {
	return indexPath.section == 1;
}

- (void)tableView:(UITableView *)tableView commitEditingStyle:(UITableViewCellEditingStyle)editingStyle forRowAtIndexPath:(NSIndexPath *)indexPath {
	if (editingStyle != UITableViewCellEditingStyleDelete) {
		return;
	}
	PSProxyProfile *profile = self.profiles[indexPath.row];
	[[PSProxyManager sharedManager] deleteProfileWithIdentifier:profile.identifier];
	[self reloadProfiles];
}

- (UIContextualAction *)editActionForProfile:(PSProxyProfile *)profile {
	return [UIContextualAction contextualActionWithStyle:UIContextualActionStyleNormal title:@"Edit" handler:^(__kindof UIContextualAction *action, __kindof UIView *sourceView, void (^completionHandler)(BOOL)) {
		[self showProfileEditorWithProfile:profile];
		completionHandler(YES);
	}];
}

- (UISwipeActionsConfiguration *)tableView:(UITableView *)tableView trailingSwipeActionsConfigurationForRowAtIndexPath:(NSIndexPath *)indexPath {
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

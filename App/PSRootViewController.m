#import "PSRootViewController.h"
#import "PSProxyManager.h"
#import <notify.h>

static NSArray<NSString *> *PSAppNormalizeNoProxyList(NSString *rawText) {
	if (![rawText isKindOfClass:NSString.class] || rawText.length == 0) {
		return @[];
	}
	NSCharacterSet *separators = [NSCharacterSet characterSetWithCharactersInString:@", \n\t"];
	NSMutableArray<NSString *> *values = [NSMutableArray array];
	for (NSString *part in [rawText componentsSeparatedByCharactersInSet:separators]) {
		NSString *trimmed = [part stringByTrimmingCharactersInSet:NSCharacterSet.whitespaceAndNewlineCharacterSet];
		if (trimmed.length > 0) {
			[values addObject:trimmed];
		}
	}
	return values.copy;
}

@interface PSWiFiPickerViewController : UITableViewController

@property (nonatomic, copy) NSArray<PSWiFiNetwork *> *networks;
@property (nonatomic, copy) NSSet<NSString *> *existingSSIDs;
@property (nonatomic, copy) void (^selectionHandler)(PSWiFiNetwork *network);

@end

@interface PSProfileEditorViewController : UITableViewController <UITextFieldDelegate>

@property (nonatomic, strong) PSProxyProfile *profile;
@property (nonatomic, assign) BOOL editingExisting;
@property (nonatomic, copy) void (^completionHandler)(PSProxyProfile *profile);

@end

@interface PSDiagnosticsViewController : UITableViewController

@property (nonatomic, copy) NSDictionary<NSString *, id> *snapshot;

@end

@interface PSRootViewController ()

@property (nonatomic, copy) NSArray<PSProxyProfile *> *profiles;
@property (nonatomic, copy) NSArray<PSWiFiNetwork *> *wifiNetworks;
@property (nonatomic, copy) NSString *activeIdentifier;
@property (nonatomic, strong) PSProxyProfile *temporaryProfile;
@property (nonatomic, strong) PSProxyProfile *lastTemporaryProfile;
@property (nonatomic, assign) int notifyToken;
@property (nonatomic, assign) NSUInteger reloadGeneration;
@property (nonatomic, assign) BOOL operationInProgress;
@property (nonatomic, copy) NSString *pendingProxyIdentifier;
@property (nonatomic, copy) NSString *pendingWiFiSSID;
@property (nonatomic, copy) NSString *pendingOperationTitle;
@property (nonatomic, assign) BOOL reloadScheduled;

@end

@implementation PSWiFiPickerViewController

- (NSArray<PSWiFiNetwork *> *)availableNetworks {
	NSMutableArray<PSWiFiNetwork *> *items = [NSMutableArray array];
	for (PSWiFiNetwork *network in self.networks) {
		if (![self.existingSSIDs containsObject:network.ssid]) {
			[items addObject:network];
		}
	}
	return items.copy;
}

- (NSArray<PSWiFiNetwork *> *)addedNetworks {
	NSMutableArray<PSWiFiNetwork *> *items = [NSMutableArray array];
	for (PSWiFiNetwork *network in self.networks) {
		if ([self.existingSSIDs containsObject:network.ssid]) {
			[items addObject:network];
		}
	}
	return items.copy;
}

- (void)viewDidLoad {
	[super viewDidLoad];
	self.title = @"Add Wi-Fi";
	[self.tableView registerClass:UITableViewCell.class forCellReuseIdentifier:@"WiFiCell"];
}

- (NSInteger)numberOfSectionsInTableView:(UITableView *)tableView {
	NSInteger sections = 0;
	if (self.availableNetworks.count > 0) {
		sections += 1;
	}
	if (self.addedNetworks.count > 0) {
		sections += 1;
	}
	return MAX(sections, 1);
}

- (NSString *)tableView:(UITableView *)tableView titleForHeaderInSection:(NSInteger)section {
	BOOL hasAvailable = self.availableNetworks.count > 0;
	BOOL hasAdded = self.addedNetworks.count > 0;
	if (!hasAvailable && !hasAdded) {
		return @"Wi-Fi";
	}
	if (hasAvailable && section == 0) {
		return @"Available";
	}
	return @"Already Added";
}

- (NSInteger)tableView:(UITableView *)tableView numberOfRowsInSection:(NSInteger)section {
	BOOL hasAvailable = self.availableNetworks.count > 0;
	BOOL hasAdded = self.addedNetworks.count > 0;
	if (!hasAvailable && !hasAdded) {
		return 0;
	}
	if (hasAvailable && section == 0) {
		return self.availableNetworks.count;
	}
	return self.addedNetworks.count;
}

- (UITableViewCell *)tableView:(UITableView *)tableView cellForRowAtIndexPath:(NSIndexPath *)indexPath {
	UITableViewCell *cell = [tableView dequeueReusableCellWithIdentifier:@"WiFiCell" forIndexPath:indexPath];
	BOOL hasAvailable = self.availableNetworks.count > 0;
	BOOL inAddedSection = !(hasAvailable && indexPath.section == 0);
	NSArray<PSWiFiNetwork *> *source = inAddedSection ? self.addedNetworks : self.availableNetworks;
	PSWiFiNetwork *network = source[indexPath.row];
	UIListContentConfiguration *content = UIListContentConfiguration.valueCellConfiguration;
	content.text = network.displayName;
	content.secondaryText = network.proxyProfile ? [NSString stringWithFormat:@"%@:%ld", network.proxyProfile.host, (long)network.proxyProfile.port] : @"Direct";
	if (inAddedSection) {
		content.textProperties.color = UIColor.secondaryLabelColor;
		content.secondaryTextProperties.color = UIColor.tertiaryLabelColor;
	}
	cell.contentConfiguration = content;
	cell.accessoryType = inAddedSection ? UITableViewCellAccessoryCheckmark : UITableViewCellAccessoryNone;
	cell.selectionStyle = inAddedSection ? UITableViewCellSelectionStyleNone : UITableViewCellSelectionStyleDefault;
	cell.userInteractionEnabled = !inAddedSection;
	return cell;
}

- (void)tableView:(UITableView *)tableView didSelectRowAtIndexPath:(NSIndexPath *)indexPath {
	[tableView deselectRowAtIndexPath:indexPath animated:YES];
	NSArray<PSWiFiNetwork *> *source = self.availableNetworks;
	if (indexPath.row < source.count && self.selectionHandler) {
		self.selectionHandler(source[indexPath.row]);
	}
	[self.navigationController popViewControllerAnimated:YES];
}

@end

@implementation PSProfileEditorViewController {
	UITextField *_nameField;
	UITextField *_hostField;
	UITextField *_portField;
	UITextField *_usernameField;
	UITextField *_passwordField;
	UITextField *_noProxyField;
}

- (void)viewDidLoad {
	[super viewDidLoad];
	self.title = self.editingExisting ? @"Edit Proxy" : @"New Proxy";
	self.navigationItem.rightBarButtonItem = [[UIBarButtonItem alloc] initWithTitle:@"Save" style:UIBarButtonItemStyleDone target:self action:@selector(save)];
	[self.tableView registerClass:UITableViewCell.class forCellReuseIdentifier:@"ProfileFieldCell"];
}

- (NSInteger)tableView:(UITableView *)tableView numberOfRowsInSection:(NSInteger)section {
	return 6;
}

- (UITextField *)configuredFieldForRow:(NSInteger)row {
	UITextField *field = [[UITextField alloc] initWithFrame:CGRectZero];
	field.translatesAutoresizingMaskIntoConstraints = NO;
	field.textAlignment = NSTextAlignmentRight;
	field.delegate = self;
	field.clearButtonMode = UITextFieldViewModeWhileEditing;
	field.autocapitalizationType = UITextAutocapitalizationTypeNone;
	field.autocorrectionType = UITextAutocorrectionTypeNo;
	if (row == 0) {
		field.placeholder = @"Name";
		field.text = self.profile.name;
		field.autocapitalizationType = UITextAutocapitalizationTypeWords;
		_nameField = field;
	} else if (row == 1) {
		field.placeholder = @"Host";
		field.text = self.profile.host;
		field.keyboardType = UIKeyboardTypeURL;
		_hostField = field;
	} else if (row == 2) {
		field.placeholder = @"Port";
		field.text = [NSString stringWithFormat:@"%ld", (long)self.profile.port];
		field.keyboardType = UIKeyboardTypeNumberPad;
		_portField = field;
	} else if (row == 3) {
		field.placeholder = @"Username";
		field.text = self.profile.username ?: @"";
		_usernameField = field;
	} else if (row == 4) {
		field.placeholder = @"Password";
		field.text = self.profile.password ?: @"";
		field.secureTextEntry = YES;
		_passwordField = field;
	} else {
		field.placeholder = @"localhost, 127.0.0.1";
		field.text = self.profile.noProxy.count > 0 ? [self.profile.noProxy componentsJoinedByString:@", "] : @"";
		_noProxyField = field;
	}
	return field;
}

- (UITableViewCell *)tableView:(UITableView *)tableView cellForRowAtIndexPath:(NSIndexPath *)indexPath {
	UITableViewCell *cell = [tableView dequeueReusableCellWithIdentifier:@"ProfileFieldCell" forIndexPath:indexPath];
	UILabel *label = [[UILabel alloc] initWithFrame:CGRectZero];
	label.translatesAutoresizingMaskIntoConstraints = NO;
	label.font = [UIFont systemFontOfSize:16.0 weight:UIFontWeightRegular];
	NSArray<NSString *> *titles = @[@"Name", @"Host", @"Port", @"Username", @"Password", @"No Proxy"];
	label.text = titles[indexPath.row];
	UITextField *field = [self configuredFieldForRow:indexPath.row];

	for (UIView *subview in cell.contentView.subviews) {
		[subview removeFromSuperview];
	}
	[cell.contentView addSubview:label];
	[cell.contentView addSubview:field];
	[NSLayoutConstraint activateConstraints:@[
		[label.leadingAnchor constraintEqualToAnchor:cell.contentView.layoutMarginsGuide.leadingAnchor],
		[label.centerYAnchor constraintEqualToAnchor:cell.contentView.centerYAnchor],
		[field.leadingAnchor constraintGreaterThanOrEqualToAnchor:label.trailingAnchor constant:12.0],
		[field.trailingAnchor constraintEqualToAnchor:cell.contentView.layoutMarginsGuide.trailingAnchor],
		[field.centerYAnchor constraintEqualToAnchor:cell.contentView.centerYAnchor],
		[field.widthAnchor constraintGreaterThanOrEqualToConstant:150.0]
	]];
	cell.selectionStyle = UITableViewCellSelectionStyleNone;
	return cell;
}

- (void)save {
	NSString *host = [_hostField.text stringByTrimmingCharactersInSet:NSCharacterSet.whitespaceAndNewlineCharacterSet];
	NSInteger port = _portField.text.integerValue;
	if (host.length == 0 || port < 1 || port > 65535) {
		UIAlertController *alert = [UIAlertController alertControllerWithTitle:@"ProxySwitcher" message:@"Host or port is invalid." preferredStyle:UIAlertControllerStyleAlert];
		[alert addAction:[UIAlertAction actionWithTitle:@"OK" style:UIAlertActionStyleDefault handler:nil]];
		[self presentViewController:alert animated:YES completion:nil];
		return;
	}
	self.profile.name = _nameField.text.length > 0 ? _nameField.text : host;
	self.profile.host = host;
	self.profile.port = port;
	self.profile.username = _usernameField.text.length > 0 ? _usernameField.text : nil;
	self.profile.password = _passwordField.text.length > 0 ? _passwordField.text : nil;
	self.profile.noProxy = PSAppNormalizeNoProxyList(_noProxyField.text);
	if (self.completionHandler) {
		self.completionHandler(self.profile);
	}
	[self.navigationController popViewControllerAnimated:YES];
}

- (BOOL)textFieldShouldReturn:(UITextField *)textField {
	[textField resignFirstResponder];
	return YES;
}

@end

@implementation PSDiagnosticsViewController {
	NSArray<NSDictionary<NSString *, NSString *> *> *_items;
}

- (void)viewDidLoad {
	[super viewDidLoad];
	self.title = @"Diagnostics";
	[self.tableView registerClass:UITableViewCell.class forCellReuseIdentifier:@"DiagnosticCell"];
	NSString *ssid = [self.snapshot[@"currentSSID"] isKindOfClass:NSString.class] ? self.snapshot[@"currentSSID"] : @"";
	NSString *active = [self.snapshot[@"activeIdentifier"] isKindOfClass:NSString.class] ? self.snapshot[@"activeIdentifier"] : @"";
	NSString *profiles = [self.snapshot[@"profilesCount"] respondsToSelector:@selector(stringValue)] ? [self.snapshot[@"profilesCount"] stringValue] : @"0";
	NSString *wifi = [self.snapshot[@"quickWiFiCount"] respondsToSelector:@selector(stringValue)] ? [self.snapshot[@"quickWiFiCount"] stringValue] : @"0";
	NSString *socket = [self.snapshot[@"helperSocketPath"] isKindOfClass:NSString.class] ? self.snapshot[@"helperSocketPath"] : @"";
	_items = @[
		@{@"title": @"SSID", @"value": ssid},
		@{@"title": @"Active", @"value": active},
		@{@"title": @"Profiles", @"value": profiles},
		@{@"title": @"Quick Wi-Fi", @"value": wifi},
		@{@"title": @"Socket", @"value": socket},
	];
}

- (NSInteger)tableView:(UITableView *)tableView numberOfRowsInSection:(NSInteger)section {
	return _items.count;
}

- (UITableViewCell *)tableView:(UITableView *)tableView cellForRowAtIndexPath:(NSIndexPath *)indexPath {
	UITableViewCell *cell = [tableView dequeueReusableCellWithIdentifier:@"DiagnosticCell" forIndexPath:indexPath];
	UIListContentConfiguration *content = UIListContentConfiguration.valueCellConfiguration;
	NSDictionary<NSString *, NSString *> *item = _items[indexPath.row];
	content.text = item[@"title"];
	content.secondaryText = item[@"value"];
	content.secondaryTextProperties.numberOfLines = 2;
	cell.contentConfiguration = content;
	cell.selectionStyle = UITableViewCellSelectionStyleNone;
	return cell;
}

@end

@implementation PSRootViewController

- (void)viewDidLoad {
	[super viewDidLoad];
	self.title = @"ProxySwitcher";
	self.navigationItem.rightBarButtonItem = [[UIBarButtonItem alloc] initWithBarButtonSystemItem:UIBarButtonSystemItemAdd target:self action:@selector(showAddMenu)];
	self.navigationItem.leftBarButtonItem = [[UIBarButtonItem alloc] initWithImage:[UIImage systemImageNamed:@"stethoscope"] style:UIBarButtonItemStylePlain target:self action:@selector(showDiagnostics)];
	[self.tableView registerClass:UITableViewCell.class forCellReuseIdentifier:@"Cell"];
	[NSNotificationCenter.defaultCenter addObserver:self selector:@selector(reloadProfiles) name:UIApplicationDidBecomeActiveNotification object:nil];
	__weak typeof(self) weakSelf = self;
	notify_register_dispatch(PSProxyProfilesChangedNotification.UTF8String, &_notifyToken, dispatch_get_main_queue(), ^(int token) {
		[weakSelf scheduleReloadProfiles];
	});
	[self scheduleReloadProfiles];
}

- (void)dealloc {
	[NSNotificationCenter.defaultCenter removeObserver:self];
	if (_notifyToken) {
		notify_cancel(_notifyToken);
	}
}

- (void)viewWillAppear:(BOOL)animated {
	[super viewWillAppear:animated];
	[self scheduleReloadProfiles];
}

- (void)scheduleReloadProfiles {
	if (self.reloadScheduled) {
		return;
	}
	self.reloadScheduled = YES;
	dispatch_after(dispatch_time(DISPATCH_TIME_NOW, (int64_t)(0.15 * NSEC_PER_SEC)), dispatch_get_main_queue(), ^{
		self.reloadScheduled = NO;
		[self reloadProfiles];
	});
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
		PSProxyProfile *lastTemporaryProfile = [manager lastTemporaryProfile];
		dispatch_async(dispatch_get_main_queue(), ^{
			if (generation != self.reloadGeneration) {
				return;
			}
			self.profiles = profiles;
			self.wifiNetworks = wifiNetworks;
			self.activeIdentifier = activeIdentifier;
			self.temporaryProfile = temporaryProfile;
			self.lastTemporaryProfile = lastTemporaryProfile;
			[self.tableView reloadData];
		});
	});
}

- (NSInteger)numberOfSectionsInTableView:(UITableView *)tableView {
	return 3;
}

- (NSInteger)tableView:(UITableView *)tableView numberOfRowsInSection:(NSInteger)section {
	if (section == 0) {
		return [self effectiveTemporaryProfile] ? 2 : 1;
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
		PSProxyProfile *temporaryProfile = [self effectiveTemporaryProfile];
		if (indexPath.row == 0) {
			content.text = @"Direct";
			BOOL pending = [self.pendingProxyIdentifier isEqualToString:PSProxyDirectIdentifier];
			content.secondaryText = pending ? @"Applying..." : @"No HTTP proxy";
			cell.accessoryType = !pending && [activeIdentifier isEqualToString:PSProxyDirectIdentifier] ? UITableViewCellAccessoryCheckmark : UITableViewCellAccessoryNone;
			cell.accessoryView = pending ? [self activityAccessoryView] : nil;
		} else {
			BOOL pending = [self.pendingProxyIdentifier isEqualToString:PSProxyTemporaryIdentifier];
			content.text = @"Temporary";
			content.secondaryText = pending ? @"Applying..." : [NSString stringWithFormat:@"%@:%ld", temporaryProfile.host, (long)temporaryProfile.port];
			cell.accessoryType = !pending && [activeIdentifier isEqualToString:PSProxyTemporaryIdentifier] ? UITableViewCellAccessoryCheckmark : UITableViewCellAccessoryNone;
			cell.accessoryView = pending ? [self activityAccessoryView] : nil;
		}
	} else if (indexPath.section == 1) {
		PSProxyProfile *profile = self.profiles[indexPath.row];
		BOOL pending = [self.pendingProxyIdentifier isEqualToString:profile.identifier];
		content.text = profile.name;
		content.secondaryText = pending ? @"Applying..." : [NSString stringWithFormat:@"%@:%ld", profile.host, (long)profile.port];
		cell.accessoryType = !pending && [activeIdentifier isEqualToString:profile.identifier] ? UITableViewCellAccessoryCheckmark : UITableViewCellAccessoryNone;
		cell.accessoryView = pending ? [self activityAccessoryView] : nil;
	} else {
		PSWiFiNetwork *network = self.wifiNetworks[indexPath.row];
		BOOL pending = [self.pendingWiFiSSID isEqualToString:network.ssid];
		content.text = network.displayName;
		content.secondaryText = pending ? @"Switching Wi-Fi..." : (network.proxyProfile ? [NSString stringWithFormat:@"Saved proxy: %@:%ld", network.proxyProfile.host, (long)network.proxyProfile.port] : @"Saved proxy: Direct");
		cell.accessoryType = !pending && network.current ? UITableViewCellAccessoryCheckmark : UITableViewCellAccessoryNone;
		cell.accessoryView = pending ? [self activityAccessoryView] : nil;
	}

	cell.userInteractionEnabled = !self.operationInProgress;
	cell.selectionStyle = self.operationInProgress ? UITableViewCellSelectionStyleNone : UITableViewCellSelectionStyleDefault;
	cell.contentConfiguration = content;
	return cell;
}

- (void)tableView:(UITableView *)tableView didSelectRowAtIndexPath:(NSIndexPath *)indexPath {
	[tableView deselectRowAtIndexPath:indexPath animated:YES];
	if (self.operationInProgress) {
		return;
	}

	void (^operation)(void) = nil;
	if (indexPath.section == 0) {
		if (indexPath.row == 0) {
			[self beginOperationWithTitle:@"Applying Direct..." proxyIdentifier:PSProxyDirectIdentifier wifiSSID:nil];
			operation = ^{
				NSError *error;
				BOOL ok = [[PSProxyManager sharedManager] applyDirectWithError:&error];
				[self finishOperationWithSuccess:ok error:error];
			};
		} else {
			[self beginOperationWithTitle:@"Applying temporary proxy..." proxyIdentifier:PSProxyTemporaryIdentifier wifiSSID:nil];
			operation = ^{
				NSError *error;
				BOOL ok = [[PSProxyManager sharedManager] applyTemporaryProfileWithError:&error];
				[self finishOperationWithSuccess:ok error:error];
			};
		}
	} else if (indexPath.section == 1) {
		PSProxyProfile *profile = self.profiles[indexPath.row];
		NSString *identifier = profile.identifier;
		[self beginOperationWithTitle:[NSString stringWithFormat:@"Applying %@...", profile.name] proxyIdentifier:identifier wifiSSID:nil];
		operation = ^{
			NSError *error;
			BOOL ok = [[PSProxyManager sharedManager] applyProfileWithIdentifier:identifier error:&error];
			[self finishOperationWithSuccess:ok error:error];
		};
	} else {
		PSWiFiNetwork *network = self.wifiNetworks[indexPath.row];
		NSString *ssid = network.ssid;
		[self beginOperationWithTitle:[NSString stringWithFormat:@"Switching to %@...", network.displayName] proxyIdentifier:nil wifiSSID:ssid];
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

- (UIActivityIndicatorView *)activityAccessoryView {
	UIActivityIndicatorView *activity = [[UIActivityIndicatorView alloc] initWithActivityIndicatorStyle:UIActivityIndicatorViewStyleMedium];
	[activity startAnimating];
	return activity;
}

- (void)beginOperationWithTitle:(NSString *)title proxyIdentifier:(NSString *)proxyIdentifier wifiSSID:(NSString *)wifiSSID {
	self.operationInProgress = YES;
	self.pendingOperationTitle = title;
	self.pendingProxyIdentifier = proxyIdentifier;
	self.pendingWiFiSSID = wifiSSID;
	self.navigationItem.prompt = title;
	self.navigationItem.rightBarButtonItem.enabled = NO;
	[self.tableView reloadData];
}

- (void)finishOperationWithSuccess:(BOOL)ok error:(NSError *)error {
	dispatch_async(dispatch_get_main_queue(), ^{
		self.operationInProgress = NO;
		self.pendingOperationTitle = nil;
		self.pendingProxyIdentifier = nil;
		self.pendingWiFiSSID = nil;
		self.navigationItem.prompt = nil;
		self.navigationItem.rightBarButtonItem.enabled = YES;
		if (!ok) {
			[self showError:error.localizedDescription ?: @"Unable to update settings."];
		}
		[self reloadProfiles];
	});
}

- (BOOL)tableView:(UITableView *)tableView canEditRowAtIndexPath:(NSIndexPath *)indexPath {
	if (indexPath.section == 0 && indexPath.row == 1 && [self effectiveTemporaryProfile]) {
		return YES;
	}
	return indexPath.section == 1 || indexPath.section == 2;
}

- (void)tableView:(UITableView *)tableView commitEditingStyle:(UITableViewCellEditingStyle)editingStyle forRowAtIndexPath:(NSIndexPath *)indexPath {
	if (editingStyle != UITableViewCellEditingStyleDelete) {
		return;
	}
	if (indexPath.section == 0 && indexPath.row == 1 && [self effectiveTemporaryProfile]) {
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
		[self showProfileEditorWithProfile:profile clearTemporaryOnSave:NO];
		completionHandler(YES);
	}];
}

- (UISwipeActionsConfiguration *)tableView:(UITableView *)tableView trailingSwipeActionsConfigurationForRowAtIndexPath:(NSIndexPath *)indexPath {
	if (indexPath.section == 0 && indexPath.row == 1 && [self effectiveTemporaryProfile]) {
		PSProxyProfile *temporary = [self effectiveTemporaryProfile];
		UIContextualAction *saveAction = [UIContextualAction contextualActionWithStyle:UIContextualActionStyleNormal title:@"Save" handler:^(__kindof UIContextualAction *action, __kindof UIView *sourceView, void (^completionHandler)(BOOL)) {
			PSProxyProfile *newProfile = [[PSProxyProfile alloc] init];
			newProfile.host = temporary.host;
			newProfile.port = temporary.port;
			newProfile.username = temporary.username;
			newProfile.password = temporary.password;
			newProfile.noProxy = temporary.noProxy;
			newProfile.name = temporary.name.length > 0 ? temporary.name : [NSString stringWithFormat:@"%@:%ld", temporary.host, (long)temporary.port];
			[self showProfileEditorWithProfile:newProfile clearTemporaryOnSave:YES];
			completionHandler(YES);
		}];
		saveAction.backgroundColor = UIColor.systemBlueColor;
		return [UISwipeActionsConfiguration configurationWithActions:@[saveAction]];
	}
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

- (PSProxyProfile *)effectiveTemporaryProfile {
	return self.temporaryProfile ?: self.lastTemporaryProfile;
}

- (void)showAddMenu {
	UIAlertController *alert = [UIAlertController alertControllerWithTitle:@"Add" message:nil preferredStyle:UIAlertControllerStyleActionSheet];
	[alert addAction:[UIAlertAction actionWithTitle:@"Profile" style:UIAlertActionStyleDefault handler:^(__kindof UIAlertAction *action) {
		[self showProfileEditorWithProfile:nil clearTemporaryOnSave:NO];
	}]];
	[alert addAction:[UIAlertAction actionWithTitle:@"Saved Wi-Fi" style:UIAlertActionStyleDefault handler:^(__kindof UIAlertAction *action) {
		[self showWiFiPicker];
	}]];
	[alert addAction:[UIAlertAction actionWithTitle:@"Cancel" style:UIAlertActionStyleCancel handler:nil]];
	[self presentViewController:alert animated:YES completion:nil];
}

- (void)showWiFiPicker {
	NSMutableSet<NSString *> *existingSSIDs = [NSMutableSet set];
	for (PSWiFiNetwork *network in self.wifiNetworks) {
		if (network.ssid.length > 0) {
			[existingSSIDs addObject:network.ssid];
		}
	}
	dispatch_async(dispatch_get_global_queue(QOS_CLASS_UTILITY, 0), ^{
		NSArray<PSWiFiNetwork *> *availableNetworks = [[PSProxyManager sharedManager] availableWiFiNetworks];
		NSMutableArray<PSWiFiNetwork *> *allItems = [NSMutableArray array];
		for (PSWiFiNetwork *network in availableNetworks) {
			if (network.ssid.length > 0) {
				[allItems addObject:network];
			}
		}
		dispatch_async(dispatch_get_main_queue(), ^{
			if (allItems.count == 0) {
				[self showError:@"No additional saved Wi-Fi networks were found."];
				return;
			}
			PSWiFiPickerViewController *picker = [[PSWiFiPickerViewController alloc] initWithStyle:UITableViewStyleInsetGrouped];
			picker.networks = allItems;
			picker.existingSSIDs = existingSSIDs.copy;
			__weak typeof(self) weakSelf = self;
			picker.selectionHandler = ^(PSWiFiNetwork *selectedNetwork) {
				[[PSProxyManager sharedManager] addQuickWiFiSSID:selectedNetwork.ssid];
				[weakSelf reloadProfiles];
			};
			[self.navigationController pushViewController:picker animated:YES];
		});
	});
}

- (void)showProfileEditorWithProfile:(PSProxyProfile *)profile clearTemporaryOnSave:(BOOL)clearTemporaryOnSave {
	BOOL editing = profile != nil && [self profileExistsWithIdentifier:profile.identifier];
	PSProxyProfile *editable = profile ?: [[PSProxyProfile alloc] init];
	PSProfileEditorViewController *editor = [[PSProfileEditorViewController alloc] initWithStyle:UITableViewStyleInsetGrouped];
	editor.profile = editable;
	editor.editingExisting = editing;
	__weak typeof(self) weakSelf = self;
	editor.completionHandler = ^(PSProxyProfile *savedProfile) {
		PSProxyManager *manager = [PSProxyManager sharedManager];
		[manager saveProfile:savedProfile];
		if (clearTemporaryOnSave) {
			[manager clearTemporaryProfile];
		}
		[weakSelf reloadProfiles];
	};
	[self.navigationController pushViewController:editor animated:YES];
}

- (BOOL)profileExistsWithIdentifier:(NSString *)identifier {
	if (identifier.length == 0) {
		return NO;
	}
	for (PSProxyProfile *profile in self.profiles) {
		if ([profile.identifier isEqualToString:identifier]) {
			return YES;
		}
	}
	return NO;
}

- (void)showError:(NSString *)message {
	UIAlertController *alert = [UIAlertController alertControllerWithTitle:@"ProxySwitcher" message:message preferredStyle:UIAlertControllerStyleAlert];
	[alert addAction:[UIAlertAction actionWithTitle:@"OK" style:UIAlertActionStyleDefault handler:nil]];
	[self presentViewController:alert animated:YES completion:nil];
}

- (void)showDiagnostics {
	NSDictionary *snapshot = [[PSProxyManager sharedManager] diagnosticsSnapshot];
	PSDiagnosticsViewController *controller = [[PSDiagnosticsViewController alloc] initWithStyle:UITableViewStyleInsetGrouped];
	controller.snapshot = snapshot;
	[self.navigationController pushViewController:controller animated:YES];
}

@end

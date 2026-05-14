#import <Foundation/Foundation.h>

NS_ASSUME_NONNULL_BEGIN

extern NSString * const PSProxyDirectIdentifier;
extern NSString * const PSProxyTemporaryIdentifier;
extern NSString * const PSProxyProfilesChangedNotification;
extern NSString * const PSProxyHelperSocketPath;

@interface PSProxyProfile : NSObject <NSSecureCoding>

@property (nonatomic, copy) NSString *identifier;
@property (nonatomic, copy) NSString *name;
@property (nonatomic, copy) NSString *host;
@property (nonatomic, assign) NSInteger port;
@property (nonatomic, copy, nullable) NSString *username;
@property (nonatomic, copy, nullable) NSString *password;
@property (nonatomic, copy, nullable) NSArray<NSString *> *noProxy;

- (NSDictionary *)dictionaryRepresentation;
+ (nullable instancetype)profileWithDictionary:(NSDictionary *)dictionary;

@end

@interface PSWiFiNetwork : NSObject

@property (nonatomic, copy) NSString *ssid;
@property (nonatomic, copy) NSString *displayName;
@property (nonatomic, strong, nullable) PSProxyProfile *proxyProfile;
@property (nonatomic, assign) BOOL current;

@end

@interface PSProxyManager : NSObject

+ (instancetype)sharedManager;

- (NSArray<PSProxyProfile *> *)profiles;
- (nullable PSProxyProfile *)profileWithIdentifier:(NSString *)identifier;
- (void)saveProfile:(PSProxyProfile *)profile;
- (void)deleteProfileWithIdentifier:(NSString *)identifier;

- (NSString *)activeIdentifier;
- (nullable NSString *)lastActiveProfileIdentifier;
- (nullable PSProxyProfile *)temporaryProfile;
- (nullable PSProxyProfile *)lastTemporaryProfile;
- (void)clearTemporaryProfile;
- (BOOL)applyDirectWithError:(NSError **)error;
- (BOOL)applyProfileWithIdentifier:(NSString *)identifier error:(NSError **)error;
- (BOOL)applyTemporaryProfileWithError:(NSError **)error;
- (NSString *)nextIdentifierAfterActive;
- (NSArray<PSWiFiNetwork *> *)availableWiFiNetworks;
- (NSArray<PSWiFiNetwork *> *)quickWiFiNetworks;
- (void)addQuickWiFiSSID:(NSString *)ssid;
- (void)deleteQuickWiFiSSID:(NSString *)ssid;
- (nullable NSString *)currentWiFiSSID;
- (BOOL)switchToWiFiSSID:(NSString *)ssid error:(NSError **)error;
- (BOOL)syncActiveProfileWithCurrentSystemProxy:(NSError **)error;
- (NSDictionary<NSString *, id> *)diagnosticsSnapshot;

@end

NS_ASSUME_NONNULL_END

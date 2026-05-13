#import <Foundation/Foundation.h>

NS_ASSUME_NONNULL_BEGIN

extern NSString * const PSProxyDirectIdentifier;
extern NSString * const PSProxyProfilesChangedNotification;
extern NSString * const PSProxyRequestNotification;

@interface PSProxyProfile : NSObject <NSSecureCoding>

@property (nonatomic, copy) NSString *identifier;
@property (nonatomic, copy) NSString *name;
@property (nonatomic, copy) NSString *host;
@property (nonatomic, assign) NSInteger port;
@property (nonatomic, copy, nullable) NSString *username;
@property (nonatomic, copy, nullable) NSString *password;

- (NSDictionary *)dictionaryRepresentation;
+ (nullable instancetype)profileWithDictionary:(NSDictionary *)dictionary;

@end

@interface PSProxyManager : NSObject

+ (instancetype)sharedManager;

- (NSArray<PSProxyProfile *> *)profiles;
- (nullable PSProxyProfile *)profileWithIdentifier:(NSString *)identifier;
- (void)saveProfile:(PSProxyProfile *)profile;
- (void)deleteProfileWithIdentifier:(NSString *)identifier;

- (NSString *)activeIdentifier;
- (nullable NSString *)lastActiveProfileIdentifier;
- (BOOL)applyDirectWithError:(NSError **)error;
- (BOOL)applyProfileWithIdentifier:(NSString *)identifier error:(NSError **)error;
- (NSString *)nextIdentifierAfterActive;

@end

NS_ASSUME_NONNULL_END

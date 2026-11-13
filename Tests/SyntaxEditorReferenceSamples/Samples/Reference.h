#import <Foundation/Foundation.h>

NS_ASSUME_NONNULL_BEGIN

NS_SWIFT_NAME(ReferenceState)
typedef NS_ENUM(NSInteger, REReferenceState) {
    REReferenceStateIdle,
    REReferenceStateLoading,
    REReferenceStateReady,
};

typedef NS_OPTIONS(NSUInteger, REReferenceOptions) {
    REReferenceOptionAllowsMissing = 1 << 0,
    REReferenceOptionUsesFallback = 1 << 1,
};

NS_SWIFT_NAME(ReferenceItem)
@interface ReferenceItem : NSObject
@property (nonatomic, copy) NSString *title;
@property (nonatomic, assign, getter=isEnabled) BOOL enabled;
@property (nonatomic, copy, nullable) NSDictionary<NSString *, id> *metadata;
- (NSString *)displayTitle;
- (BOOL)validateWithError:(NSError *_Nullable *_Nullable)error;
@end

typedef void (^REReferenceCompletion)(ReferenceItem *_Nullable item, NSError *_Nullable error);

@protocol ReferenceRendering <NSObject>
- (nullable NSString *)renderItem:(ReferenceItem *)item error:(NSError *_Nullable *_Nullable)error;
@end

NS_SWIFT_NAME(ReferenceCache)
@interface ReferenceCache : NSObject <ReferenceRendering>
+ (instancetype)sharedCache;
@property (nonatomic, copy, readonly) NSDictionary<NSString *, ReferenceItem *> *itemsByIdentifier;
- (ReferenceItem *)defaultItem;
- (nullable ReferenceItem *)itemForIdentifier:(NSString *)identifier effectiveRange:(NSRange *_Nullable)effectiveRange;
- (void)loadItemForIdentifier:(NSString *)identifier completion:(REReferenceCompletion)completion;
@end

@interface ReferenceItem (Formatting)
- (NSString *)formattedTitleForState:(REReferenceState)state;
@end

NS_ASSUME_NONNULL_END

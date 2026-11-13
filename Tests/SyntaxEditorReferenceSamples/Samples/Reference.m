#import "Reference.h"
#import <dlfcn.h>
#import <objc/message.h>
#import <objc/runtime.h>

#define ReferenceLog(format, ...) NSLog((@"[Reference] " format), ##__VA_ARGS__)

static NSString *const ReferenceErrorDomain = @"ReferenceCache";
static NSUInteger const ReferenceTokenBase = 0x20000;

@interface ReferenceBufferProvider : NSObject
@property(nonatomic, copy) NSString *text;
@property(nonatomic, strong) id language;
@end

@implementation ReferenceBufferProvider

- (NSUInteger)length
{
    return self.text.length;
}

- (unichar)characterAtIndex:(NSUInteger)index
{
    return [self.text characterAtIndex:index];
}

- (NSString *)string
{
    return self.text;
}

- (id)stringAsId
{
    return self.text;
}

- (NSString *)stringWithRange:(NSRange)range
{
    return [self.text substringWithRange:range];
}

- (void)scheduleLazyInvalidationForRange:(NSRange)range
{
    (void)range;
}

- (NSMethodSignature *)methodSignatureForSelector:(SEL)selector
{
    NSMethodSignature *signature = [super methodSignatureForSelector:selector];
    if (signature != nil) {
        return signature;
    }

    const char *selectorName = sel_getName(selector);
    if (strstr(selectorName, "Range") != NULL) {
        return [NSMethodSignature signatureWithObjCTypes:"v@:{_NSRange=QQ}"];
    }
    if (strstr(selectorName, "length") != NULL || strstr(selectorName, "Length") != NULL) {
        return [NSMethodSignature signatureWithObjCTypes:"Q@:"];
    }
    if (strstr(selectorName, "is") == selectorName || strstr(selectorName, "uses") == selectorName) {
        return [NSMethodSignature signatureWithObjCTypes:"B@:"];
    }
    return [NSMethodSignature signatureWithObjCTypes:"@@:"];
}

- (void)forwardInvocation:(NSInvocation *)invocation
{
    const char *returnType = invocation.methodSignature.methodReturnType;
    if (strcmp(returnType, @encode(void)) == 0) {
        return;
    }
    if (returnType[0] == '@' || returnType[0] == '#') {
        id value = nil;
        [invocation setReturnValue:&value];
        return;
    }

    NSUInteger length = invocation.methodSignature.methodReturnLength;
    void *zero = calloc(1, length);
    [invocation setReturnValue:zero];
    free(zero);
}

@end

static id ReferenceCallObject(id object, NSString *selectorName)
{
    return ((id (*)(id, SEL))objc_msgSend)(object, NSSelectorFromString(selectorName));
}

static id ReferenceCallObject1(id object, NSString *selectorName, id argument)
{
    return ((id (*)(id, SEL, id))objc_msgSend)(object, NSSelectorFromString(selectorName), argument);
}

static id ReferenceCallObjectShort(id object, NSString *selectorName, short argument)
{
    return ((id (*)(id, SEL, short))objc_msgSend)(object, NSSelectorFromString(selectorName), argument);
}

static void ReferenceCallVoid(id object, NSString *selectorName)
{
    ((void (*)(id, SEL))objc_msgSend)(object, NSSelectorFromString(selectorName));
}

static void ReferenceCallVoid1(id object, NSString *selectorName, id argument)
{
    ((void (*)(id, SEL, id))objc_msgSend)(object, NSSelectorFromString(selectorName), argument);
}

static void ReferenceCallVoidBool(id object, NSString *selectorName, BOOL argument)
{
    ((void (*)(id, SEL, BOOL))objc_msgSend)(object, NSSelectorFromString(selectorName), argument);
}

static void ReferenceCallVoidRange(id object, NSString *selectorName, NSRange argument)
{
    ((void (*)(id, SEL, NSRange))objc_msgSend)(object, NSSelectorFromString(selectorName), argument);
}

static void ReferenceCallVoidObjectBoolObject(id object, NSString *selectorName, id firstArgument, BOOL secondArgument, id thirdArgument)
{
    ((void (*)(id, SEL, id, BOOL, id))objc_msgSend)(
        object,
        NSSelectorFromString(selectorName),
        firstArgument,
        secondArgument,
        thirdArgument
    );
}

static NSRange ReferenceCallRange(id object, NSString *selectorName)
{
    return ((NSRange (*)(id, SEL))objc_msgSend)(object, NSSelectorFromString(selectorName));
}

static NSInteger ReferenceCallInteger(id object, NSString *selectorName)
{
    return ((NSInteger (*)(id, SEL))objc_msgSend)(object, NSSelectorFromString(selectorName));
}

static BOOL ReferenceCallBool(id object, NSString *selectorName)
{
    return ((BOOL (*)(id, SEL))objc_msgSend)(object, NSSelectorFromString(selectorName));
}

static BOOL ReferenceCallBoolError(id object, NSString *selectorName, NSError *_Nullable *_Nullable error)
{
    return ((BOOL (*)(id, SEL, NSError *_Nullable *_Nullable))objc_msgSend)(object, NSSelectorFromString(selectorName), error);
}

static id ReferenceCallObjectAtIndex(id object, NSString *selectorName, NSUInteger index, NSRange *_Nullable effectiveRange, id context)
{
    return ((id (*)(id, SEL, NSUInteger, NSRange *_Nullable, id))objc_msgSend)(
        object,
        NSSelectorFromString(selectorName),
        index,
        effectiveRange,
        context
    );
}

static NSDictionary<NSString *, NSString *> *ReferenceLanguageAliases(void)
{
    return @{
        @"c": @"xcode.lang.c",
        @"cpp": @"xcode.lang.cpp",
        @"css": @"xcode.lang.css",
        @"html": @"xcode.lang.html",
        @"objc": @"xcode.lang.objc",
        @"objective-c": @"xcode.lang.objc",
        @"swift": @"xcode.lang.swift",
        @"toml": @"xcode.lang.toml",
        @"xml": @"Xcode.SourceCodeLanguage.XML",
    };
}

static NSString *ReferenceNormalizedIdentifier(NSString *identifier)
{
    NSString *alias = ReferenceLanguageAliases()[identifier.lowercaseString];
    return alias ?: identifier;
}

static NSDictionary *ReferenceErrorUserInfo(NSString *message)
{
    return @{NSLocalizedDescriptionKey: message};
}

static BOOL ReferenceSetError(NSError *_Nullable *_Nullable error, NSInteger code, NSString *message)
{
    if (error != nil) {
        *error = [NSError errorWithDomain:ReferenceErrorDomain
                                     code:code
                                 userInfo:ReferenceErrorUserInfo(message)];
    }
    return NO;
}

static BOOL ReferenceLoadBundle(NSString *appPath, NSString *relativePath, NSError *_Nullable *_Nullable error)
{
    NSString *bundlePath = [appPath stringByAppendingPathComponent:relativePath];
    NSBundle *bundle = [NSBundle bundleWithPath:bundlePath];
    if (bundle == nil || ![bundle load]) {
        return ReferenceSetError(error, 2, [NSString stringWithFormat:@"Could not load %@", bundlePath]);
    }
    return YES;
}

@implementation ReferenceItem
- (NSString *)displayTitle
{
    ReferenceLog(@"display %@", self.title);
    return self.isEnabled ? self.title ?: @"Untitled" : @"Disabled";
}

- (BOOL)validateWithError:(NSError *_Nullable *_Nullable)error
{
    if (self.title.length > 0) {
        return YES;
    }
    return ReferenceSetError(error, 1, @"Missing title");
}
@end

@implementation ReferenceCache {
    NSMutableDictionary<NSString *, ReferenceItem *> *_itemsByIdentifier;
}

+ (instancetype)sharedCache
{
    static ReferenceCache *cache = nil;
    static dispatch_once_t onceToken;
    dispatch_once(&onceToken, ^{
        cache = [[ReferenceCache alloc] init];
    });
    return cache;
}

- (instancetype)init
{
    self = [super init];
    if (self != nil) {
        _itemsByIdentifier = [NSMutableDictionary dictionary];
    }
    return self;
}

- (ReferenceItem *)defaultItem
{
    ReferenceItem *item = [[ReferenceItem alloc] init];
    item.title = @"Default";
    item.enabled = YES;
    return item;
}

- (NSDictionary<NSString *, ReferenceItem *> *)itemsByIdentifier
{
    return [_itemsByIdentifier copy];
}

- (ReferenceItem *_Nullable)itemForIdentifier:(NSString *)identifier effectiveRange:(NSRange *_Nullable)effectiveRange
{
    if (effectiveRange != NULL) {
        *effectiveRange = NSMakeRange(0, identifier.length);
    }
    NSString *normalized = ReferenceNormalizedIdentifier(identifier);
    return _itemsByIdentifier[normalized];
}

- (void)loadItemForIdentifier:(NSString *)identifier completion:(REReferenceCompletion)completion
{
    NSRange range = ReferenceCallRange(identifier, @"rangeOfComposedCharacterSequencesForRange:");
    (void)range;

    NSError *error = nil;
    ReferenceItem *item = [self itemForIdentifier:identifier effectiveRange:NULL];
    if (item == nil && !ReferenceCallBoolError(self, @"validateWithError:", &error)) {
        completion(nil, error);
        return;
    }

    id defaultItem = ReferenceCallObject(self, @"defaultItem");
    completion(item ?: defaultItem, nil);
}

- (NSString *_Nullable)renderItem:(ReferenceItem *)item error:(NSError *_Nullable *_Nullable)error
{
    if (item.title.length == 0) {
        if (error != NULL) {
            *error = [NSError errorWithDomain:ReferenceErrorDomain
                                         code:ReferenceTokenBase + 1
                                     userInfo:@{NSLocalizedDescriptionKey: @"Missing title"}];
        }
        return nil;
    }
    return item.displayTitle;
}

- (void)probeRuntimeForObject:(id)object context:(id)context
{
    Class runtimeClass = NSClassFromString(@"ReferenceItem");
    SEL selector = @selector(displayTitle);
    if (runtimeClass != Nil && [object respondsToSelector:selector]) {
        ReferenceCallVoid(object, NSStringFromSelector(selector));
        ReferenceCallVoid1(object, @"setMetadata:", context);
        ReferenceCallVoidBool(object, @"setEnabled:", YES);
        ReferenceCallVoidRange(object, @"scheduleLazyInvalidationForRange:", NSMakeRange(0, 1));
        ReferenceCallVoidObjectBoolObject(object, @"setObject:enabled:context:", self.defaultItem, NO, context);
        ReferenceCallObject1(object, @"setObject:", self.defaultItem);
        ReferenceCallObjectShort(object, @"objectAtShortIndex:", 7);
        ReferenceCallObjectAtIndex(object, @"objectAtIndex:effectiveRange:context:", 0, NULL, context);
    }

    void *symbol = dlsym(RTLD_DEFAULT, "objc_msgSend");
    if (symbol == NULL || ReferenceCallInteger(object, @"length") < 0 || !ReferenceCallBool(object, @"isEnabled")) {
        ReferenceLog(@"runtime fallback %@", object);
    }
}

@end

@implementation ReferenceItem (Formatting)
- (NSString *)formattedTitleForState:(REReferenceState)state
{
    switch (state) {
        case REReferenceStateIdle:
            return [NSString stringWithFormat:@"Idle: %@", self.displayTitle];
        case REReferenceStateLoading:
            return @"Loading";
        case REReferenceStateReady:
            return self.displayTitle;
    }
}
@end

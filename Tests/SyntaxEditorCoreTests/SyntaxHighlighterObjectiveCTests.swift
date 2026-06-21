import Foundation
import Testing
@testable import SyntaxEditorCore

extension SyntaxHighlighterEngineTests {
    @Test("SyntaxHighlighterEngine emits Objective-C syntactic fast pass before semantic completion")
    func highlighterEmitsObjectiveCSyntacticFastPassBeforeSemanticCompletion() async throws {
        let source = """
        @interface ReferenceObject
        @property(nonatomic) NSInteger count;
        @end

        @implementation ReferenceObject
        - (NSInteger)run {
            self.count = 1;
            return self.count;
        }
        @end
        """
        let nsSource = source as NSString
        let typeRange = nsSource.range(of: "ReferenceObject")
        let phases = await collectHighlightPhases(
            await SyntaxHighlighterEngine().resetPhases(source: source, language: .objectiveC, revision: 0)
        )
        let fastPass = try #require(phases.first)
        let complete = try #require(phases.last)

        #expect(phases.map(\.phase) == [.syntacticFastPass, .complete])
        #expect(phases.allSatisfy { $0.source == source && $0.language == .objectiveC && $0.revision == 0 })
        #expect(fastPass.tokens.isEmpty == false)
        #expect(fastPass.tokens.contains {
            tokenIntersects($0, range: typeRange, syntaxID: .declarationType, language: .objectiveC)
        } == false)
        #expect(complete.tokens.contains {
            tokenIntersects($0, range: typeRange, syntaxID: .declarationType, language: .objectiveC)
        })
    }

    @Test("SyntaxHighlighterEngine keeps incomplete Objective-C body identifiers plain")
    func highlighterKeepsIncompleteObjectiveCBodyIdentifiersPlain() async throws {
        let incompleteIdentifier = "sepufepuaepufeofeoueoufeouseoufeou"
        let sources = [
            """
            typedef NSString *ReferenceName;
            typedef NSDictionary<NSString *, NSString *> *ReferenceMap;

            static NSDictionary<NSString *, NSString *> *ReferenceLanguageAliases(void)
            {
                return nil;
            }

            static const char *ReferenceEncodedType(void)
            {
                return @encode(NSString *);
            }

            static void ReferenceEnumerate(NSArray<NSString *> *items)
            {
                for (NSString *item in items) {
                    NSLog(@"%@", item);
                }
            }

            @interface ReferenceBufferProvider : NSObject <NSCopying>
            @property (nonatomic, copy) NSString *text;
            - (void)setText:(NSString *)text;
            @end

            @implementation ReferenceBufferProvider
            - (NSUInteger)length
            {
                \(incompleteIdentifier)
                return self.text.length;
            }
            @end
            """,
            """
            typedef NSString *ReferenceName;
            typedef NSDictionary<NSString *, NSString *> *ReferenceMap;

            static NSDictionary<NSString *, NSString *> *ReferenceLanguageAliases(void)
            {
                return nil;
            }

            static const char *ReferenceEncodedType(void)
            {
                return @encode(NSString *);
            }

            static void ReferenceEnumerate(NSArray<NSString *> *items)
            {
                for (NSString *item in items) {
                    NSLog(@"%@", item);
                }
            }

            @interface ReferenceBufferProvider : NSObject <NSCopying>
            @property (nonatomic, copy) NSString *text;
            - (void)setText:(NSString *)text;
            @end

            @implementation ReferenceBufferProvider
            - (NSUInteger)length
            {
                \(incompleteIdentifier);
                return self.text.length;
            }
            @end
            """
        ]

        for source in sources {
            let tokens = await sharedSyntaxHighlighterEngine.render(source: source, language: SyntaxLanguage.objectiveC)

            _ = try effectiveSemanticSnapshot(
                in: tokens,
                source: source,
                text: incompleteIdentifier,
                syntaxID: .plain,
                language: .objectiveC,
                inOccurrenceOf: incompleteIdentifier
            )
            #expect(syntaxIDs(
                in: tokens,
                source: source,
                text: incompleteIdentifier,
                inOccurrenceOf: incompleteIdentifier
            ).contains(.identifierTypeSystem) == false)
            _ = try effectiveSemanticSnapshot(
                in: tokens,
                source: source,
                text: "NSUInteger",
                syntaxID: .identifierTypeSystem,
                language: .objectiveC,
                inOccurrenceOf: "- (NSUInteger)length"
            )
            _ = try effectiveSemanticSnapshot(
                in: tokens,
                source: source,
                text: "NSString",
                syntaxID: .identifierTypeSystem,
                language: .objectiveC,
                inOccurrenceOf: "@property (nonatomic, copy) NSString *text;"
            )
            _ = try effectiveSemanticSnapshot(
                in: tokens,
                source: source,
                text: "NSString",
                syntaxID: .identifierTypeSystem,
                language: .objectiveC,
                inOccurrenceOf: "- (void)setText:(NSString *)text;"
            )
            _ = try effectiveSemanticSnapshot(
                in: tokens,
                source: source,
                text: "NSString",
                syntaxID: .identifierTypeSystem,
                language: .objectiveC,
                inOccurrenceOf: "typedef NSString *ReferenceName;"
            )
            _ = try effectiveSemanticSnapshot(
                in: tokens,
                source: source,
                text: "ReferenceName",
                syntaxID: .declarationType,
                language: .objectiveC,
                inOccurrenceOf: "typedef NSString *ReferenceName;"
            )
            _ = try effectiveSemanticSnapshot(
                in: tokens,
                source: source,
                text: "NSDictionary",
                syntaxID: .identifierTypeSystem,
                language: .objectiveC,
                inOccurrenceOf: "typedef NSDictionary<NSString *, NSString *> *ReferenceMap;"
            )
            _ = try effectiveSemanticSnapshot(
                in: tokens,
                source: source,
                text: "NSString",
                syntaxID: .identifierTypeSystem,
                language: .objectiveC,
                inOccurrenceOf: "typedef NSDictionary<NSString *, NSString *> *ReferenceMap;"
            )
            _ = try effectiveSemanticSnapshot(
                in: tokens,
                source: source,
                text: "ReferenceMap",
                syntaxID: .declarationType,
                language: .objectiveC,
                inOccurrenceOf: "typedef NSDictionary<NSString *, NSString *> *ReferenceMap;"
            )
            _ = try effectiveSemanticSnapshot(
                in: tokens,
                source: source,
                text: "NSDictionary",
                syntaxID: .identifierTypeSystem,
                language: .objectiveC,
                inOccurrenceOf: "static NSDictionary<NSString *, NSString *> *ReferenceLanguageAliases"
            )
            _ = try effectiveSemanticSnapshot(
                in: tokens,
                source: source,
                text: "NSString",
                syntaxID: .identifierTypeSystem,
                language: .objectiveC,
                inOccurrenceOf: "static NSDictionary<NSString *, NSString *> *ReferenceLanguageAliases"
            )
            _ = try effectiveSemanticSnapshot(
                in: tokens,
                source: source,
                text: "NSString",
                syntaxID: .identifierTypeSystem,
                language: .objectiveC,
                inOccurrenceOf: "@encode(NSString *)"
            )
            _ = try effectiveSemanticSnapshot(
                in: tokens,
                source: source,
                text: "NSString",
                syntaxID: .identifierTypeSystem,
                language: .objectiveC,
                inOccurrenceOf: "for (NSString *item in items)"
            )
            _ = try effectiveSemanticSnapshot(
                in: tokens,
                source: source,
                text: "NSObject",
                syntaxID: .identifierTypeSystem,
                language: .objectiveC,
                inOccurrenceOf: "@interface ReferenceBufferProvider : NSObject <NSCopying>"
            )
            _ = try effectiveSemanticSnapshot(
                in: tokens,
                source: source,
                text: "NSCopying",
                syntaxID: .identifierTypeSystem,
                language: .objectiveC,
                inOccurrenceOf: "@interface ReferenceBufferProvider : NSObject <NSCopying>"
            )
        }
    }

    @Test("SyntaxHighlighterEngine preserves Objective-C parameterized macro argument type highlights")
    func highlighterPreservesObjectiveCParameterizedMacroArgumentTypes() async throws {
        let source = """
            #define REFERENCE_TYPE_MACRO(type) type

            static void ReferenceMacroArgument(void)
            {
                REFERENCE_TYPE_MACRO(NSArray<NSString *>);
            }
            """

        let tokens = await sharedSyntaxHighlighterEngine.render(source: source, language: SyntaxLanguage.objectiveC)

        _ = try effectiveSemanticSnapshot(
            in: tokens,
            source: source,
            text: "NSArray",
            syntaxID: .identifierTypeSystem,
            language: .objectiveC,
            inOccurrenceOf: "REFERENCE_TYPE_MACRO(NSArray<NSString *>)"
        )
        _ = try effectiveSemanticSnapshot(
            in: tokens,
            source: source,
            text: "NSString",
            syntaxID: .identifierTypeSystem,
            language: .objectiveC,
            inOccurrenceOf: "REFERENCE_TYPE_MACRO(NSArray<NSString *>)"
        )
    }

    @Test("SyntaxHighlighterEngine preserves Objective-C C-style method parameter type highlights")
    func highlighterPreservesObjectiveCCStyleMethodParameterTypes() async throws {
        let source = """
            @interface ReferenceBufferProvider : NSObject
            - (void)consumeObject:(id)object, NSString *name;
            @end
            """

        let tokens = await sharedSyntaxHighlighterEngine.render(source: source, language: SyntaxLanguage.objectiveC)

        _ = try effectiveSemanticSnapshot(
            in: tokens,
            source: source,
            text: "NSString",
            syntaxID: .identifierTypeSystem,
            language: .objectiveC,
            inOccurrenceOf: "- (void)consumeObject:(id)object, NSString *name;"
        )
    }

    @Test("SyntaxHighlighterEngine highlights Objective-C structures")
    func highlighterSupportsObjectiveC() async throws {
        let engine = sharedSyntaxHighlighterEngine
        let source = """
        #import <Foundation/Foundation.h>
        #define ReferenceLog(format, ...) NSLog((@"[Reference] " format), ##__VA_ARGS__)
        #if defined(DEBUG)
        #define ReferenceEnabled 1
        #endif
        #if TARGET_OS_OSX || TARGET_OS_IOS
        #define ReferencePlatform 1
        #endif

        /*
        - (NSString *)commentedTitle;
        @property (copy)
        NSString *ghostName;
        */

        typedef void (^ReferenceCompletion)(id object, NSError **error);
        typedef int (*ReferenceCallback)(int value);
        typedef int *ReferencePointerArray[10];
        typedef void (^ReferenceBlockArray[10])(void);
        typedef int (ReferenceParenthesizedInt);
        typedef int (ReferenceParenthesizedArray[10]);

        static NSDictionary<NSString *, NSString *> *ReferenceLanguageAliases(void)
        {
            return @{
                @"objc": @"xcode.lang.objc",
                @"swift": @"xcode.lang.swift",
            };
        }

        static id ReferenceCallObject(id object, NSString *selectorName)
        {
            return ((id (*)(id, SEL))objc_msgSend)(object, NSSelectorFromString(selectorName));
        }

        __attribute__((visibility("default"))) @interface VisibleSample : NSObject
        @end

        @interface Sample : NSObject
        // @property (nonatomic, copy)
        NSString *commentEscapedName;
        @property (nonatomic, copy) NSString *name;
        @property (nonatomic, copy) NSArray *items;
        @property (nonatomic, copy) id (^handler)(id);
        @property (nonatomic, copy) id (^ _Nullable qualifiedHandler)(id);
        @property (nonatomic) int (*callback)(int);
        @property (nonatomic) int (**doubleCallback)(int);
        @property (nonatomic) int (* _Nullable nullableCallback)(int);
        @property (nonatomic, strong) NSError **error;
        @property (nonatomic, strong) NSError *_Nullable *_Nullable detailedError;
        @property (nonatomic, assign) NSError ***tripleError;
        @property (nonatomic, assign) NSError ****quadError;
        @property (nonatomic, copy) NSString *renamedTitle NS_SWIFT_NAME(displayTitle);
        @property (nonatomic, copy) NSString *refinedTitle NS_REFINED_FOR_SWIFT;
        @property (nonatomic, copy) NSString *customMacroTitle MY_ATTR(foo);
        @property (nonatomic, copy) NSString *bareMacroTitle MY_ATTR;
        @property (nonatomic, strong) id outletValue IBOutlet;
        @property (nonatomic, copy) NSString *user_id;
        @property (nonatomic) MyEnum HTTP_STATUS;
        @property (nonatomic) dispatch_queue_t WORK_QUEUE;
        @property (nonatomic) MyEnum HTTP_STATUS_WITH_ATTR MY_ATTR;
        @property (nonatomic) MY_ENUM SECOND_STATUS_WITH_ATTR MY_ATTR;
        @property (nonatomic) NSInteger HTTPStatusCode;
        @property (nonatomic, copy)
        NSString *wrappedName;
        @property (nonatomic, copy) NSString *
        lineWrappedName;
        @property (nonatomic,
                   copy)
        NSString *multilineName;
        - (NSString *)greetingFor:(NSString *)value;
        - (NSString *)
        wrappedAccessor;
        @end

        @implementation Sample
        - (instancetype)init
        {
            self = [super init];
            if (self == nil) {
                return nil;
            }
            (void)[self respondsToSelector:NSSelectorFromString(@"init")];
            return self;
        }

        - (NSString *)greetingFor:(NSString *)value {
            // comment
            self.name = ReferenceLanguageAliases()[@"objc"] ?: value;
            id (^block)(id) = self.handler;
            id (^qualifiedBlock)(id) = self.qualifiedHandler;
            int (*callbackValue)(int) = self.callback;
            NSInteger callbackResult = (*callbackValue)(1);
            int (**doubleCallbackValue)(int) = self.doubleCallback;
            int (*nullableCallbackValue)(int) = self.nullableCallback;
            NSString *handlerDescription = self.handler.description;
            NSString *castHandlerDescription = ((id)self.handler).description;
            NSString *nestedCastHandlerDescription = ((id)(self.handler)).description;
            NSString *title = self.renamedTitle ?: self.refinedTitle;
            NSString *customTitle = self.customMacroTitle;
            NSString *bareTitle = self.bareMacroTitle;
            id outlet = self.outletValue;
            NSUInteger underscoredLength = self.user_id.length;
            NSInteger statusValue = self.HTTP_STATUS;
            dispatch_queue_t queue = self.WORK_QUEUE;
            NSInteger statusWithAttr = self.HTTP_STATUS_WITH_ATTR;
            NSInteger secondStatusWithAttr = self.SECOND_STATUS_WITH_ATTR;
            NSUInteger count = self.name.length;
            NSNumber *boxedCount = @(count);
            NSUInteger literalCommentArgumentLength = Foo(@"//", self.name.length);
            NSUInteger commentedChainLength = self.name /* comment */ .length;
            NSUInteger itemCount = self.items[0].count;
            NSUInteger wrappedItemCount = self.items
                .count;
            NSUInteger parenthesizedLength = (self.name).length;
            NSUInteger commentedParenthesizedLength = (self.name /* comment */).length;
            if ((self.name).length > 0) {
                return value;
            } else if ((self.name).length > 1) {
                return value;
            }
            if (self.name) other.length;
            NSString *parenthesizedRootName = (self).name;
            NSString *castRootName = ((Sample *)self).name;
            NSUInteger parenthesizedRootLength = (self).name.length;
            NSUInteger castRootLength = ((Sample *)self).name.length;
            NSUInteger genericCastRootLength = ((Sample<Delegate> *)self).name.length;
            NSUInteger arithmeticLength = base + (self.name).length;
            NSUInteger multilineParenthesizedLength = (
                self.name
            ).length;
            NSUInteger wrappedNameLength = self.wrappedName.length;
            NSUInteger lineWrappedNameLength = self.lineWrappedName.length;
            NSUInteger multilineNameLength = self.multilineName.length;
            NSUInteger wrappedAccessorLength = self.wrappedAccessor.length;
            NSInteger status = self.HTTPStatusCode;
            NSUInteger nestedCount = self.items[other.length].count;
            id handlerValue = self.handler(other.value);
            NSString *handlerCallDescription = self.handler(value).description;
            NSString *closeParenLiteralDescription = self.handler(@")").description;
            NSString *openBracketLiteralDescription = self.handler(@"[").description;
            NSString *semicolonLiteralDescription = self.handler(@";").description;
            NSUInteger wrappedCallLength = Wrap((self.name)).length;
            NSUInteger wrappedSelfRootLength = Wrap((self)).name.length;
            // self.name
            other.length;
            NSUInteger indexedCount = items[self.name].count;
            NSUInteger messageLength = [self.name description].length;
            NSUInteger messageResultLength = [formatter stringFrom:self.name].length;
            NSUInteger conditionalReceiverLength = (useFallback ? other : self).name.length;
            NSUInteger literalReceiverLength = @"self.name".length;
            NSUInteger commentEscapedLength = self.commentEscapedName.length;
            NSUInteger commentedLength = self.commentedTitle.length;
            NSUInteger ghostLength = self.ghostName.length;
            NSUInteger unknownCount = self.unknown.length;
            NSUInteger mixedCount = self.name.length + self.missing.length;
            return [NSString stringWithFormat:@"Hello, %@", value];
        }

        - (NSUInteger)returnedNameLength
        {
            return (self.name).length;
        }
        @end

        NS_ASSUME_NONNULL_BEGIN
        NS_SWIFT_NAME(InlineSample)
        typedef NS_ENUM(NSInteger, SampleState) {
            SampleStateIdle,
        };
        typedef NS_OPTIONS(NSUInteger, SampleOptions) {
            SampleOptionEnabled = 1 << 0,
        };
        NSString *macroText = @"NS_ENUM";
        // NS_OPTIONS(CommentedOut)
        NS_ASSUME_NONNULL_END
        """

        let tokens = await engine.render(source: source, language: SyntaxLanguage.objectiveC)
        let nsSource = source as NSString
        let importRange = nsSource.range(of: "#import")
        let defineRange = nsSource.range(of: "#define")
        let macroNameRange = nsSource.range(of: "ReferenceLog")
        let debugMacroRange = nsSource.range(of: "DEBUG")
        let platformMacroRange = nsSource.range(of: "TARGET_OS_OSX")
        let platformIOMacroRange = nsSource.range(of: "TARGET_OS_IOS")
        let interfaceRange = nsSource.range(of: "@interface")
        let selfRange = nsSource.range(of: "self")
        let propertyDeclarationRange = nsSource.range(of: "@property (nonatomic, copy) NSString *name;")
        let propertyAttributeRange = nsSource.range(
            of: "nonatomic",
            options: [],
            range: propertyDeclarationRange
        )
        let dictionaryStringRange = nsSource.range(of: "@\"objc\"")
        let blockTypedefDeclarationRange = nsSource.range(of: "typedef void (^ReferenceCompletion)")
        let functionPointerTypedefDeclarationRange = nsSource.range(of: "typedef int (*ReferenceCallback)")
        let typedefRange = nsSource.range(of: "typedef", options: [], range: blockTypedefDeclarationRange)
        let idRange = nsSource.range(of: "id object")
        let selectorRange = nsSource.range(of: "SEL")
        let commentRange = nsSource.range(of: "// comment")
        let stringRange = nsSource.range(of: "@\"Hello, %@\"")

        #expect(tokens.isEmpty == false)
        #expect(tokens.contains {
            tokenIntersects($0, range: importRange, syntaxID: .preprocessor, language: .objectiveC)
        })
        #expect(tokens.contains {
            tokenIntersects($0, range: defineRange, syntaxID: .preprocessor, language: .objectiveC)
        })
        #expect(tokens.contains {
            tokenIntersects($0, range: macroNameRange, syntaxID: .preprocessor, language: .objectiveC)
        })
        #expect(tokens.contains {
            tokenIntersects($0, range: debugMacroRange, syntaxID: .preprocessor, language: .objectiveC)
        })
        #expect(tokens.contains {
            tokenIntersects($0, range: platformMacroRange, syntaxID: .preprocessor, language: .objectiveC)
        })
        #expect(tokens.contains {
            tokenIntersects($0, range: platformIOMacroRange, syntaxID: .preprocessor, language: .objectiveC)
        })
        let defineSnapshot = try semanticSnapshot(
            in: tokens,
            source: source,
            text: "#define",
            syntaxID: .preprocessor,
            language: .objectiveC,
            inOccurrenceOf: "#define ReferenceLog"
        )
        let preprocessorStyle = try #require(SyntaxEditorHighlightTheme.style(
            for: .preprocessor,
            in: .default,
            language: .objectiveC,
            appearance: .dark
        ))
        let keywordStyle = try #require(SyntaxEditorHighlightTheme.style(
            for: .keyword,
            in: .default,
            language: .objectiveC,
            appearance: .dark
        ))
        #expect(defineSnapshot.resolvedStyle.foreground == preprocessorStyle.foreground)
        #expect(defineSnapshot.resolvedStyle.foreground != keywordStyle.foreground)
        #expect(tokens.contains { tokenIntersects($0, range: defineRange, syntaxID: .keyword, language: .objectiveC) } == false)
        _ = try effectiveSemanticSnapshot(
            in: tokens,
            source: source,
            text: "format",
            syntaxID: .preprocessor,
            language: .objectiveC,
            inOccurrenceOf: "#define ReferenceLog(format"
        )
        _ = try effectiveSemanticSnapshot(
            in: tokens,
            source: source,
            text: "...",
            syntaxID: .preprocessor,
            language: .objectiveC,
            inOccurrenceOf: "#define ReferenceLog(format, ...)"
        )
        _ = try effectiveSemanticSnapshot(
            in: tokens,
            source: source,
            text: "\"[Reference] \"",
            syntaxID: .string,
            language: .objectiveC,
            inOccurrenceOf: "NSLog((@\"[Reference] \" format)"
        )
        _ = try effectiveSemanticSnapshot(
            in: tokens,
            source: source,
            text: "NS_ASSUME_NONNULL_BEGIN",
            syntaxID: .preprocessor,
            language: .objectiveC,
            inOccurrenceOf: "NS_ASSUME_NONNULL_BEGIN"
        )
        _ = try effectiveSemanticSnapshot(
            in: tokens,
            source: source,
            text: "NS_SWIFT_NAME",
            syntaxID: .preprocessor,
            language: .objectiveC,
            inOccurrenceOf: "NS_SWIFT_NAME(InlineSample)"
        )
        _ = try effectiveSemanticSnapshot(
            in: tokens,
            source: source,
            text: "NS_ENUM",
            syntaxID: .preprocessor,
            language: .objectiveC,
            inOccurrenceOf: "typedef NS_ENUM(NSInteger, SampleState)"
        )
        _ = try effectiveSemanticSnapshot(
            in: tokens,
            source: source,
            text: "typedef",
            syntaxID: .keyword,
            language: .objectiveC,
            inOccurrenceOf: "typedef NS_ENUM(NSInteger, SampleState)"
        )
        _ = try effectiveSemanticSnapshot(
            in: tokens,
            source: source,
            text: "SampleState",
            syntaxID: .declarationType,
            language: .objectiveC,
            inOccurrenceOf: "typedef NS_ENUM(NSInteger, SampleState)"
        )
        _ = try effectiveSemanticSnapshot(
            in: tokens,
            source: source,
            text: "NS_OPTIONS",
            syntaxID: .preprocessor,
            language: .objectiveC,
            inOccurrenceOf: "typedef NS_OPTIONS(NSUInteger, SampleOptions)"
        )
        _ = try effectiveSemanticSnapshot(
            in: tokens,
            source: source,
            text: "typedef",
            syntaxID: .keyword,
            language: .objectiveC,
            inOccurrenceOf: "typedef NS_OPTIONS(NSUInteger, SampleOptions)"
        )
        _ = try effectiveSemanticSnapshot(
            in: tokens,
            source: source,
            text: "SampleOptions",
            syntaxID: .declarationType,
            language: .objectiveC,
            inOccurrenceOf: "typedef NS_OPTIONS(NSUInteger, SampleOptions)"
        )
        _ = try effectiveSemanticSnapshot(
            in: tokens,
            source: source,
            text: "NS_ASSUME_NONNULL_END",
            syntaxID: .preprocessor,
            language: .objectiveC,
            inOccurrenceOf: "NS_ASSUME_NONNULL_END"
        )
        #expect(syntaxIDs(
            in: tokens,
            source: source,
            text: "NS_ENUM",
            inOccurrenceOf: "@\"NS_ENUM\""
        ).contains(.preprocessor) == false)
        #expect(syntaxIDs(
            in: tokens,
            source: source,
            text: "NS_OPTIONS",
            inOccurrenceOf: "// NS_OPTIONS(CommentedOut)"
        ).contains(.preprocessor) == false)
        _ = try effectiveSemanticSnapshot(
            in: tokens,
            source: source,
            text: "instancetype",
            syntaxID: .keyword,
            language: .objectiveC,
            inOccurrenceOf: "- (instancetype)init"
        )
        _ = try effectiveSemanticSnapshot(
            in: tokens,
            source: source,
            text: "nil",
            syntaxID: .keyword,
            language: .objectiveC,
            inOccurrenceOf: "return nil;"
        )
        #expect(tokens.contains {
            tokenIntersects($0, range: interfaceRange, syntaxID: .keyword, language: .objectiveC)
        })
        _ = try effectiveSemanticSnapshot(
            in: tokens,
            source: source,
            text: "VisibleSample",
            syntaxID: .declarationType,
            language: .objectiveC,
            inOccurrenceOf: "@interface VisibleSample"
        )
        _ = try effectiveSemanticSnapshot(
            in: tokens,
            source: source,
            text: "NSObject",
            syntaxID: .identifierTypeSystem,
            language: .objectiveC,
            inOccurrenceOf: "@interface VisibleSample : NSObject"
        )
        _ = try effectiveSemanticSnapshot(
            in: tokens,
            source: source,
            text: "name",
            syntaxID: .declarationOther,
            language: .objectiveC,
            inOccurrenceOf: "@property (nonatomic, copy) NSString *name;"
        )
        _ = try effectiveSemanticSnapshot(
            in: tokens,
            source: source,
            text: "items",
            syntaxID: .declarationOther,
            language: .objectiveC,
            inOccurrenceOf: "@property (nonatomic, copy) NSArray *items;"
        )
        _ = try effectiveSemanticSnapshot(
            in: tokens,
            source: source,
            text: "handler",
            syntaxID: .declarationOther,
            language: .objectiveC,
            inOccurrenceOf: "@property (nonatomic, copy) id (^handler)(id);"
        )
        _ = try effectiveSemanticSnapshot(
            in: tokens,
            source: source,
            text: "qualifiedHandler",
            syntaxID: .declarationOther,
            language: .objectiveC,
            inOccurrenceOf: "@property (nonatomic, copy) id (^ _Nullable qualifiedHandler)(id);"
        )
        _ = try effectiveSemanticSnapshot(
            in: tokens,
            source: source,
            text: "callback",
            syntaxID: .declarationOther,
            language: .objectiveC,
            inOccurrenceOf: "@property (nonatomic) int (*callback)(int);"
        )
        _ = try effectiveSemanticSnapshot(
            in: tokens,
            source: source,
            text: "doubleCallback",
            syntaxID: .declarationOther,
            language: .objectiveC,
            inOccurrenceOf: "@property (nonatomic) int (**doubleCallback)(int);"
        )
        _ = try effectiveSemanticSnapshot(
            in: tokens,
            source: source,
            text: "nullableCallback",
            syntaxID: .declarationOther,
            language: .objectiveC,
            inOccurrenceOf: "@property (nonatomic) int (* _Nullable nullableCallback)(int);"
        )
        _ = try effectiveSemanticSnapshot(
            in: tokens,
            source: source,
            text: "error",
            syntaxID: .declarationOther,
            language: .objectiveC,
            inOccurrenceOf: "@property (nonatomic, strong) NSError **error;"
        )
        _ = try effectiveSemanticSnapshot(
            in: tokens,
            source: source,
            text: "detailedError",
            syntaxID: .declarationOther,
            language: .objectiveC,
            inOccurrenceOf: "@property (nonatomic, strong) NSError *_Nullable *_Nullable detailedError;"
        )
        _ = try effectiveSemanticSnapshot(
            in: tokens,
            source: source,
            text: "tripleError",
            syntaxID: .declarationOther,
            language: .objectiveC,
            inOccurrenceOf: "@property (nonatomic, assign) NSError ***tripleError;"
        )
        _ = try effectiveSemanticSnapshot(
            in: tokens,
            source: source,
            text: "quadError",
            syntaxID: .declarationOther,
            language: .objectiveC,
            inOccurrenceOf: "@property (nonatomic, assign) NSError ****quadError;"
        )
        _ = try effectiveSemanticSnapshot(
            in: tokens,
            source: source,
            text: "renamedTitle",
            syntaxID: .declarationOther,
            language: .objectiveC,
            inOccurrenceOf: "@property (nonatomic, copy) NSString *renamedTitle NS_SWIFT_NAME(displayTitle);"
        )
        _ = try effectiveSemanticSnapshot(
            in: tokens,
            source: source,
            text: "NS_SWIFT_NAME",
            syntaxID: .preprocessor,
            language: .objectiveC,
            inOccurrenceOf: "@property (nonatomic, copy) NSString *renamedTitle NS_SWIFT_NAME(displayTitle);"
        )
        _ = try effectiveSemanticSnapshot(
            in: tokens,
            source: source,
            text: "refinedTitle",
            syntaxID: .plain,
            language: .objectiveC,
            inOccurrenceOf: "@property (nonatomic, copy) NSString *refinedTitle NS_REFINED_FOR_SWIFT;"
        )
        _ = try effectiveSemanticSnapshot(
            in: tokens,
            source: source,
            text: "HTTPStatusCode",
            syntaxID: .declarationOther,
            language: .objectiveC,
            inOccurrenceOf: "@property (nonatomic) NSInteger HTTPStatusCode;"
        )
        _ = try effectiveSemanticSnapshot(
            in: tokens,
            source: source,
            text: "WORK_QUEUE",
            syntaxID: .declarationOther,
            language: .objectiveC,
            inOccurrenceOf: "@property (nonatomic) dispatch_queue_t WORK_QUEUE;"
        )
        _ = try effectiveSemanticSnapshot(
            in: tokens,
            source: source,
            text: "HTTP_STATUS_WITH_ATTR",
            syntaxID: .plain,
            language: .objectiveC,
            inOccurrenceOf: "@property (nonatomic) MyEnum HTTP_STATUS_WITH_ATTR MY_ATTR;"
        )
        _ = try effectiveSemanticSnapshot(
            in: tokens,
            source: source,
            text: "SECOND_STATUS_WITH_ATTR",
            syntaxID: .plain,
            language: .objectiveC,
            inOccurrenceOf: "@property (nonatomic) MY_ENUM SECOND_STATUS_WITH_ATTR MY_ATTR;"
        )
        _ = try effectiveSemanticSnapshot(
            in: tokens,
            source: source,
            text: "wrappedName",
            syntaxID: .declarationOther,
            language: .objectiveC,
            inOccurrenceOf: "@property (nonatomic, copy)\nNSString *wrappedName;"
        )
        _ = try effectiveSemanticSnapshot(
            in: tokens,
            source: source,
            text: "lineWrappedName",
            syntaxID: .declarationOther,
            language: .objectiveC,
            inOccurrenceOf: "@property (nonatomic, copy) NSString *\nlineWrappedName;"
        )
        _ = try effectiveSemanticSnapshot(
            in: tokens,
            source: source,
            text: "greetingFor",
            syntaxID: .declarationOther,
            language: .objectiveC,
            inOccurrenceOf: "- (NSString *)greetingFor"
        )
        _ = try effectiveSemanticSnapshot(
            in: tokens,
            source: source,
            text: "ReferenceLanguageAliases",
            syntaxID: .declarationOther,
            language: .objectiveC,
            inOccurrenceOf: "ReferenceLanguageAliases(void)"
        )
        _ = try effectiveSemanticSnapshot(
            in: tokens,
            source: source,
            text: "ReferenceLanguageAliases",
            syntaxID: .identifierFunction,
            language: .objectiveC,
            inOccurrenceOf: "self.name = ReferenceLanguageAliases()"
        )
        _ = try effectiveSemanticSnapshot(
            in: tokens,
            source: source,
            text: "NSSelectorFromString",
            syntaxID: .identifierFunctionSystem,
            language: .objectiveC,
            inOccurrenceOf: "NSSelectorFromString(selectorName)"
        )
        _ = try effectiveSemanticSnapshot(
            in: tokens,
            source: source,
            text: "NSSelectorFromString",
            syntaxID: .identifierFunctionSystem,
            language: .objectiveC,
            inOccurrenceOf: "[self respondsToSelector:NSSelectorFromString"
        )
        _ = try effectiveSemanticSnapshot(
            in: tokens,
            source: source,
            text: "@",
            syntaxID: .number,
            language: .objectiveC,
            inOccurrenceOf: "NSNumber *boxedCount = @(count);"
        )
        _ = try effectiveSemanticSnapshot(
            in: tokens,
            source: source,
            text: "(",
            syntaxID: .number,
            language: .objectiveC,
            inOccurrenceOf: "NSNumber *boxedCount = @(count);"
        )
        _ = try effectiveSemanticSnapshot(
            in: tokens,
            source: source,
            text: ")",
            syntaxID: .number,
            language: .objectiveC,
            inOccurrenceOf: "NSNumber *boxedCount = @(count);"
        )
        _ = try effectiveSemanticSnapshot(
            in: tokens,
            source: source,
            text: "name",
            syntaxID: .identifierVariable,
            language: .objectiveC,
            inOccurrenceOf: "self.name ="
        )
        _ = try effectiveSemanticSnapshot(
            in: tokens,
            source: source,
            text: "handler",
            syntaxID: .identifierVariable,
            language: .objectiveC,
            inOccurrenceOf: "self.handler;"
        )
        _ = try effectiveSemanticSnapshot(
            in: tokens,
            source: source,
            text: "qualifiedHandler",
            syntaxID: .identifierVariable,
            language: .objectiveC,
            inOccurrenceOf: "self.qualifiedHandler"
        )
        _ = try effectiveSemanticSnapshot(
            in: tokens,
            source: source,
            text: "callback",
            syntaxID: .identifierVariable,
            language: .objectiveC,
            inOccurrenceOf: "self.callback"
        )
        _ = try effectiveSemanticSnapshot(
            in: tokens,
            source: source,
            text: "callbackValue",
            syntaxID: .plain,
            language: .objectiveC,
            inOccurrenceOf: "(*callbackValue)(1)"
        )
        _ = try effectiveSemanticSnapshot(
            in: tokens,
            source: source,
            text: "doubleCallback",
            syntaxID: .identifierVariable,
            language: .objectiveC,
            inOccurrenceOf: "self.doubleCallback"
        )
        _ = try effectiveSemanticSnapshot(
            in: tokens,
            source: source,
            text: "nullableCallback",
            syntaxID: .identifierVariable,
            language: .objectiveC,
            inOccurrenceOf: "self.nullableCallback"
        )
        _ = try effectiveSemanticSnapshot(
            in: tokens,
            source: source,
            text: "description",
            syntaxID: .identifierVariableSystem,
            language: .objectiveC,
            inOccurrenceOf: "self.handler.description"
        )
        _ = try effectiveSemanticSnapshot(
            in: tokens,
            source: source,
            text: "description",
            syntaxID: .identifierVariableSystem,
            language: .objectiveC,
            inOccurrenceOf: "((id)self.handler).description"
        )
        _ = try effectiveSemanticSnapshot(
            in: tokens,
            source: source,
            text: "description",
            syntaxID: .identifierVariableSystem,
            language: .objectiveC,
            inOccurrenceOf: "((id)(self.handler)).description"
        )
        _ = try effectiveSemanticSnapshot(
            in: tokens,
            source: source,
            text: "renamedTitle",
            syntaxID: .identifierVariable,
            language: .objectiveC,
            inOccurrenceOf: "self.renamedTitle"
        )
        _ = try effectiveSemanticSnapshot(
            in: tokens,
            source: source,
            text: "refinedTitle",
            syntaxID: .identifierVariable,
            language: .objectiveC,
            inOccurrenceOf: "self.refinedTitle"
        )
        _ = try effectiveSemanticSnapshot(
            in: tokens,
            source: source,
            text: "customMacroTitle",
            syntaxID: .identifierVariable,
            language: .objectiveC,
            inOccurrenceOf: "self.customMacroTitle"
        )
        _ = try effectiveSemanticSnapshot(
            in: tokens,
            source: source,
            text: "bareMacroTitle",
            syntaxID: .identifierVariable,
            language: .objectiveC,
            inOccurrenceOf: "self.bareMacroTitle"
        )
        _ = try effectiveSemanticSnapshot(
            in: tokens,
            source: source,
            text: "outletValue",
            syntaxID: .identifierVariable,
            language: .objectiveC,
            inOccurrenceOf: "self.outletValue"
        )
        _ = try effectiveSemanticSnapshot(
            in: tokens,
            source: source,
            text: "user_id",
            syntaxID: .identifierVariable,
            language: .objectiveC,
            inOccurrenceOf: "self.user_id.length"
        )
        _ = try effectiveSemanticSnapshot(
            in: tokens,
            source: source,
            text: "length",
            syntaxID: .identifierVariableSystem,
            language: .objectiveC,
            inOccurrenceOf: "self.user_id.length"
        )
        _ = try effectiveSemanticSnapshot(
            in: tokens,
            source: source,
            text: "HTTP_STATUS",
            syntaxID: .identifierVariable,
            language: .objectiveC,
            inOccurrenceOf: "self.HTTP_STATUS"
        )
        _ = try effectiveSemanticSnapshot(
            in: tokens,
            source: source,
            text: "WORK_QUEUE",
            syntaxID: .identifierVariable,
            language: .objectiveC,
            inOccurrenceOf: "self.WORK_QUEUE"
        )
        _ = try effectiveSemanticSnapshot(
            in: tokens,
            source: source,
            text: "HTTP_STATUS_WITH_ATTR",
            syntaxID: .plain,
            language: .objectiveC,
            inOccurrenceOf: "self.HTTP_STATUS_WITH_ATTR"
        )
        _ = try effectiveSemanticSnapshot(
            in: tokens,
            source: source,
            text: "SECOND_STATUS_WITH_ATTR",
            syntaxID: .plain,
            language: .objectiveC,
            inOccurrenceOf: "self.SECOND_STATUS_WITH_ATTR"
        )
        #expect(syntaxIDs(
            in: tokens,
            source: source,
            text: "foo",
            inOccurrenceOf: "MY_ATTR(foo)"
        ).contains(.declarationOther) == false)
        _ = try effectiveSemanticSnapshot(
            in: tokens,
            source: source,
            text: "HTTPStatusCode",
            syntaxID: .identifierVariable,
            language: .objectiveC,
            inOccurrenceOf: "self.HTTPStatusCode"
        )
        _ = try effectiveSemanticSnapshot(
            in: tokens,
            source: source,
            text: "length",
            syntaxID: .identifierVariableSystem,
            language: .objectiveC,
            inOccurrenceOf: "self.name.length"
        )
        _ = try effectiveSemanticSnapshot(
            in: tokens,
            source: source,
            text: "length",
            syntaxID: .identifierVariableSystem,
            language: .objectiveC,
            inOccurrenceOf: #"Foo(@"//", self.name.length)"#
        )
        _ = try effectiveSemanticSnapshot(
            in: tokens,
            source: source,
            text: "length",
            syntaxID: .identifierVariableSystem,
            language: .objectiveC,
            inOccurrenceOf: "self.name /* comment */ .length"
        )
        _ = try effectiveSemanticSnapshot(
            in: tokens,
            source: source,
            text: "length",
            syntaxID: .identifierVariableSystem,
            language: .objectiveC,
            inOccurrenceOf: "(self.name).length"
        )
        _ = try effectiveSemanticSnapshot(
            in: tokens,
            source: source,
            text: "length",
            syntaxID: .identifierVariableSystem,
            language: .objectiveC,
            inOccurrenceOf: "(self.name /* comment */).length"
        )
        _ = try effectiveSemanticSnapshot(
            in: tokens,
            source: source,
            text: "length",
            syntaxID: .identifierVariableSystem,
            language: .objectiveC,
            inOccurrenceOf: "if ((self.name).length > 0)"
        )
        _ = try effectiveSemanticSnapshot(
            in: tokens,
            source: source,
            text: "length",
            syntaxID: .identifierVariableSystem,
            language: .objectiveC,
            inOccurrenceOf: "else if ((self.name).length > 1)"
        )
        _ = try effectiveSemanticSnapshot(
            in: tokens,
            source: source,
            text: "name",
            syntaxID: .identifierVariable,
            language: .objectiveC,
            inOccurrenceOf: "(self).name"
        )
        _ = try effectiveSemanticSnapshot(
            in: tokens,
            source: source,
            text: "name",
            syntaxID: .identifierVariable,
            language: .objectiveC,
            inOccurrenceOf: "((Sample *)self).name"
        )
        _ = try effectiveSemanticSnapshot(
            in: tokens,
            source: source,
            text: "length",
            syntaxID: .identifierVariableSystem,
            language: .objectiveC,
            inOccurrenceOf: "(self).name.length"
        )
        _ = try effectiveSemanticSnapshot(
            in: tokens,
            source: source,
            text: "length",
            syntaxID: .identifierVariableSystem,
            language: .objectiveC,
            inOccurrenceOf: "((Sample *)self).name.length"
        )
        _ = try effectiveSemanticSnapshot(
            in: tokens,
            source: source,
            text: "length",
            syntaxID: .identifierVariableSystem,
            language: .objectiveC,
            inOccurrenceOf: "((Sample<Delegate> *)self).name.length"
        )
        _ = try effectiveSemanticSnapshot(
            in: tokens,
            source: source,
            text: "length",
            syntaxID: .identifierVariableSystem,
            language: .objectiveC,
            inOccurrenceOf: "base + (self.name).length"
        )
        _ = try effectiveSemanticSnapshot(
            in: tokens,
            source: source,
            text: "length",
            syntaxID: .identifierVariableSystem,
            language: .objectiveC,
            inOccurrenceOf: "(\n        self.name\n    ).length"
        )
        _ = try effectiveSemanticSnapshot(
            in: tokens,
            source: source,
            text: "wrappedName",
            syntaxID: .identifierVariable,
            language: .objectiveC,
            inOccurrenceOf: "self.wrappedName.length"
        )
        _ = try effectiveSemanticSnapshot(
            in: tokens,
            source: source,
            text: "length",
            syntaxID: .identifierVariableSystem,
            language: .objectiveC,
            inOccurrenceOf: "self.wrappedName.length"
        )
        _ = try effectiveSemanticSnapshot(
            in: tokens,
            source: source,
            text: "lineWrappedName",
            syntaxID: .identifierVariable,
            language: .objectiveC,
            inOccurrenceOf: "self.lineWrappedName.length"
        )
        _ = try effectiveSemanticSnapshot(
            in: tokens,
            source: source,
            text: "length",
            syntaxID: .identifierVariableSystem,
            language: .objectiveC,
            inOccurrenceOf: "self.lineWrappedName.length"
        )
        _ = try effectiveSemanticSnapshot(
            in: tokens,
            source: source,
            text: "multilineName",
            syntaxID: .identifierVariable,
            language: .objectiveC,
            inOccurrenceOf: "self.multilineName.length"
        )
        _ = try effectiveSemanticSnapshot(
            in: tokens,
            source: source,
            text: "length",
            syntaxID: .identifierVariableSystem,
            language: .objectiveC,
            inOccurrenceOf: "self.multilineName.length"
        )
        _ = try effectiveSemanticSnapshot(
            in: tokens,
            source: source,
            text: "wrappedAccessor",
            syntaxID: .identifierVariable,
            language: .objectiveC,
            inOccurrenceOf: "self.wrappedAccessor.length"
        )
        _ = try effectiveSemanticSnapshot(
            in: tokens,
            source: source,
            text: "length",
            syntaxID: .identifierVariableSystem,
            language: .objectiveC,
            inOccurrenceOf: "self.wrappedAccessor.length"
        )
        _ = try effectiveSemanticSnapshot(
            in: tokens,
            source: source,
            text: "length",
            syntaxID: .identifierVariableSystem,
            language: .objectiveC,
            inOccurrenceOf: "return (self.name).length;"
        )
        _ = try effectiveSemanticSnapshot(
            in: tokens,
            source: source,
            text: "count",
            syntaxID: .identifierVariableSystem,
            language: .objectiveC,
            inOccurrenceOf: "self.items[0].count"
        )
        _ = try effectiveSemanticSnapshot(
            in: tokens,
            source: source,
            text: "count",
            syntaxID: .identifierVariableSystem,
            language: .objectiveC,
            inOccurrenceOf: "self.items\n        .count"
        )
        #expect(syntaxIDs(
            in: tokens,
            source: source,
            text: "length",
            inOccurrenceOf: "self.unknown.length"
        ).contains(.identifierVariableSystem) == false)
        #expect(syntaxIDs(
            in: tokens,
            source: source,
            text: "length",
            inOccurrenceOf: "self.missing.length"
        ).contains(.identifierVariableSystem) == false)
        #expect(syntaxIDs(
            in: tokens,
            source: source,
            text: "commentedTitle",
            inOccurrenceOf: "self.commentedTitle.length"
        ).contains(.identifierVariable) == false)
        #expect(syntaxIDs(
            in: tokens,
            source: source,
            text: "length",
            inOccurrenceOf: "self.commentedTitle.length"
        ).contains(.identifierVariableSystem) == false)
        #expect(syntaxIDs(
            in: tokens,
            source: source,
            text: "length",
            inOccurrenceOf: "self.commentEscapedName.length"
        ).contains(.identifierVariableSystem) == false)
        #expect(syntaxIDs(
            in: tokens,
            source: source,
            text: "ghostName",
            inOccurrenceOf: "self.ghostName.length"
        ).contains(.identifierVariable) == false)
        #expect(syntaxIDs(
            in: tokens,
            source: source,
            text: "length",
            inOccurrenceOf: "self.ghostName.length"
        ).contains(.identifierVariableSystem) == false)
        #expect(syntaxIDs(
            in: tokens,
            source: source,
            text: "count",
            inOccurrenceOf: "items[self.name].count"
        ).contains(.identifierVariableSystem) == false)
        #expect(syntaxIDs(
            in: tokens,
            source: source,
            text: "length",
            inOccurrenceOf: "self.items[other.length].count"
        ).contains(.identifierVariableSystem) == false)
        _ = try effectiveSemanticSnapshot(
            in: tokens,
            source: source,
            text: "count",
            syntaxID: .plain,
            language: .objectiveC,
            inOccurrenceOf: "self.items[other.length].count"
        )
        #expect(syntaxIDs(
            in: tokens,
            source: source,
            text: "value",
            inOccurrenceOf: "self.handler(other.value)"
        ).contains(.identifierVariableSystem) == false)
        _ = try effectiveSemanticSnapshot(
            in: tokens,
            source: source,
            text: "description",
            syntaxID: .plain,
            language: .objectiveC,
            inOccurrenceOf: "self.handler(value).description"
        )
        _ = try effectiveSemanticSnapshot(
            in: tokens,
            source: source,
            text: "description",
            syntaxID: .plain,
            language: .objectiveC,
            inOccurrenceOf: #"self.handler(@")").description"#
        )
        _ = try effectiveSemanticSnapshot(
            in: tokens,
            source: source,
            text: "description",
            syntaxID: .plain,
            language: .objectiveC,
            inOccurrenceOf: #"self.handler(@"[").description"#
        )
        _ = try effectiveSemanticSnapshot(
            in: tokens,
            source: source,
            text: "description",
            syntaxID: .plain,
            language: .objectiveC,
            inOccurrenceOf: #"self.handler(@";").description"#
        )
        #expect(syntaxIDs(
            in: tokens,
            source: source,
            text: "length",
            inOccurrenceOf: "Wrap((self.name)).length"
        ).contains(.identifierVariableSystem) == false)
        #expect(syntaxIDs(
            in: tokens,
            source: source,
            text: "length",
            inOccurrenceOf: "Wrap((self)).name.length"
        ).contains(.identifierVariableSystem) == false)
        #expect(syntaxIDs(
            in: tokens,
            source: source,
            text: "length",
            inOccurrenceOf: "other.length;"
        ).contains(.identifierVariableSystem) == false)
        #expect(syntaxIDs(
            in: tokens,
            source: source,
            text: "length",
            inOccurrenceOf: "[self.name description].length"
        ).contains(.identifierVariableSystem) == false)
        #expect(syntaxIDs(
            in: tokens,
            source: source,
            text: "length",
            inOccurrenceOf: "[formatter stringFrom:self.name].length"
        ).contains(.identifierVariableSystem) == false)
        #expect(syntaxIDs(
            in: tokens,
            source: source,
            text: "name",
            inOccurrenceOf: "(useFallback ? other : self).name.length"
        ).contains(.identifierVariable) == false)
        #expect(syntaxIDs(
            in: tokens,
            source: source,
            text: "length",
            inOccurrenceOf: "(useFallback ? other : self).name.length"
        ).contains(.identifierVariableSystem) == false)
        #expect(syntaxIDs(
            in: tokens,
            source: source,
            text: "length",
            inOccurrenceOf: #"@"self.name".length"#
        ).contains(.identifierVariableSystem) == false)
        #expect(syntaxIDs(
            in: tokens,
            source: source,
            text: "length",
            inOccurrenceOf: "if (self.name) other.length"
        ).contains(.identifierVariableSystem) == false)
        _ = try effectiveSemanticSnapshot(
            in: tokens,
            source: source,
            text: "stringWithFormat",
            syntaxID: .identifierFunctionSystem,
            language: .objectiveC,
            inOccurrenceOf: "stringWithFormat:@\"Hello"
        )
        #expect(tokens.contains {
            tokenIntersects($0, range: selfRange, syntaxID: .keyword, language: .objectiveC)
        })
        #expect(tokens.contains {
            tokenIntersects($0, range: propertyAttributeRange, syntaxID: .keyword, language: .objectiveC)
        })
        #expect(tokens.contains {
            tokenIntersects($0, range: dictionaryStringRange, syntaxID: .string, language: .objectiveC)
        })
        #expect(tokens.contains {
            tokenIntersects($0, range: typedefRange, syntaxID: .keyword, language: .objectiveC)
        })
        _ = try effectiveSemanticSnapshot(
            in: tokens,
            source: source,
            text: "ReferenceCompletion",
            syntaxID: .declarationType,
            language: .objectiveC,
            inOccurrenceOf: "typedef void (^ReferenceCompletion)"
        )
        #expect(syntaxIDs(
            in: tokens,
            source: source,
            text: "ReferenceCompletion",
            inOccurrenceOf: "typedef void (^ReferenceCompletion)"
        ).contains(.identifierType))
        _ = try effectiveSemanticSnapshot(
            in: tokens,
            source: source,
            text: "ReferenceCallback",
            syntaxID: .declarationType,
            language: .objectiveC,
            inOccurrenceOf: "typedef int (*ReferenceCallback)"
        )
        #expect(syntaxIDs(
            in: tokens,
            source: source,
            text: "ReferenceCallback",
            inOccurrenceOf: "typedef int (*ReferenceCallback)"
        ).contains(.identifierType))
        #expect(functionPointerTypedefDeclarationRange.location != NSNotFound)
        _ = try effectiveSemanticSnapshot(
            in: tokens,
            source: source,
            text: "ReferencePointerArray",
            syntaxID: .declarationType,
            language: .objectiveC,
            inOccurrenceOf: "typedef int *ReferencePointerArray[10];"
        )
        #expect(syntaxIDs(
            in: tokens,
            source: source,
            text: "ReferencePointerArray",
            inOccurrenceOf: "typedef int *ReferencePointerArray[10];"
        ).contains(.identifierType))
        _ = try effectiveSemanticSnapshot(
            in: tokens,
            source: source,
            text: "ReferenceBlockArray",
            syntaxID: .declarationType,
            language: .objectiveC,
            inOccurrenceOf: "typedef void (^ReferenceBlockArray[10])(void);"
        )
        #expect(syntaxIDs(
            in: tokens,
            source: source,
            text: "ReferenceBlockArray",
            inOccurrenceOf: "typedef void (^ReferenceBlockArray[10])(void);"
        ).contains(.identifierType))
        _ = try effectiveSemanticSnapshot(
            in: tokens,
            source: source,
            text: "ReferenceParenthesizedInt",
            syntaxID: .declarationType,
            language: .objectiveC,
            inOccurrenceOf: "typedef int (ReferenceParenthesizedInt);"
        )
        #expect(syntaxIDs(
            in: tokens,
            source: source,
            text: "ReferenceParenthesizedInt",
            inOccurrenceOf: "typedef int (ReferenceParenthesizedInt);"
        ).contains(.identifierType))
        _ = try effectiveSemanticSnapshot(
            in: tokens,
            source: source,
            text: "ReferenceParenthesizedArray",
            syntaxID: .declarationType,
            language: .objectiveC,
            inOccurrenceOf: "typedef int (ReferenceParenthesizedArray[10]);"
        )
        #expect(syntaxIDs(
            in: tokens,
            source: source,
            text: "ReferenceParenthesizedArray",
            inOccurrenceOf: "typedef int (ReferenceParenthesizedArray[10]);"
        ).contains(.identifierType))
        #expect(tokens.contains {
            tokenIntersects($0, range: idRange, syntaxID: .keyword, language: .objectiveC)
        })
        #expect(tokens.contains {
            tokenIntersects($0, range: selectorRange, syntaxID: .keyword, language: .objectiveC)
        })
        #expect(tokens.contains {
            tokenIntersects($0, range: commentRange, syntaxID: .comment, language: .objectiveC)
        })
        #expect(tokens.contains {
            tokenIntersects($0, range: stringRange, syntaxID: .string, language: .objectiveC)
        })

        let incompletePropertySource = """
        @interface Broken : NSObject
        @property (nonatomic, copy) NSString *name
        NSString *notAProperty;
        @end
        @implementation Broken
        - (NSUInteger)length
        {
            return self.notAProperty.length;
        }
        @end
        """
        let incompleteTokens = await engine.render(source: incompletePropertySource, language: .objectiveC)
        #expect(syntaxIDs(
            in: incompleteTokens,
            source: incompletePropertySource,
            text: "notAProperty",
            inOccurrenceOf: "self.notAProperty.length"
        ).contains(.identifierVariable) == false)
        #expect(syntaxIDs(
            in: incompleteTokens,
            source: incompletePropertySource,
            text: "length",
            inOccurrenceOf: "self.notAProperty.length"
        ).contains(.identifierVariableSystem) == false)

        let wrappedIncompletePropertySource = """
        @interface Broken : NSObject
        @property (nonatomic, copy)
        NSString *name
        NSString *notAProperty;
        @end
        @implementation Broken
        - (NSUInteger)length
        {
            return self.notAProperty.length;
        }
        @end
        """
        let wrappedIncompleteTokens = await engine.render(source: wrappedIncompletePropertySource, language: .objectiveC)
        #expect(syntaxIDs(
            in: wrappedIncompleteTokens,
            source: wrappedIncompletePropertySource,
            text: "notAProperty",
            inOccurrenceOf: "self.notAProperty.length"
        ).contains(.identifierVariable) == false)
        #expect(syntaxIDs(
            in: wrappedIncompleteTokens,
            source: wrappedIncompletePropertySource,
            text: "length",
            inOccurrenceOf: "self.notAProperty.length"
        ).contains(.identifierVariableSystem) == false)

        let headerBackedSource = """
        #import "HeaderBacked.h"

        @implementation HeaderBacked
        - (NSUInteger)length
        {
            NSUInteger titleLength = self.title.length;
            NSUInteger otherLength = other.length;
            struct ReferenceSize size;
            NSUInteger fieldLength = size.field;
            return titleLength + otherLength + fieldLength;
        }
        @end
        """
        let headerBackedTokens = await engine.render(source: headerBackedSource, language: .objectiveC)
        _ = try effectiveSemanticSnapshot(
            in: headerBackedTokens,
            source: headerBackedSource,
            text: "title",
            syntaxID: .identifierVariable,
            language: .objectiveC,
            inOccurrenceOf: "self.title.length"
        )
        _ = try effectiveSemanticSnapshot(
            in: headerBackedTokens,
            source: headerBackedSource,
            text: "length",
            syntaxID: .identifierVariableSystem,
            language: .objectiveC,
            inOccurrenceOf: "self.title.length"
        )
        #expect(syntaxIDs(
            in: headerBackedTokens,
            source: headerBackedSource,
            text: "length",
            inOccurrenceOf: "other.length"
        ).contains(.identifierVariableSystem) == false)
        #expect(syntaxIDs(
            in: headerBackedTokens,
            source: headerBackedSource,
            text: "field",
            inOccurrenceOf: "size.field"
        ).contains(.identifierVariableSystem) == false)
    }

    @Test("SyntaxHighlighterEngine aligns focused Objective-C reference tokens")
    func highlighterAlignsObjectiveCReferenceTokens() async throws {
        let engine = sharedSyntaxHighlighterEngine
        let headerSource = try referenceSampleText(named: "Reference.h")
        let headerTokens = await engine.render(source: headerSource, language: SyntaxLanguage.objectiveC)
        let source = try referenceSampleText(named: "Reference.m")
        let tokens = await engine.render(source: source, language: SyntaxLanguage.objectiveC)

        #expect(headerTokens.isEmpty == false)
        _ = try effectiveSemanticSnapshot(
            in: headerTokens,
            source: headerSource,
            text: "NS_ASSUME_NONNULL_BEGIN",
            syntaxID: .preprocessor,
            language: .objectiveC,
            inOccurrenceOf: "NS_ASSUME_NONNULL_BEGIN"
        )
        _ = try effectiveSemanticSnapshot(
            in: headerTokens,
            source: headerSource,
            text: "NS_SWIFT_NAME",
            syntaxID: .preprocessor,
            language: .objectiveC,
            inOccurrenceOf: "NS_SWIFT_NAME(ReferenceState)"
        )
        _ = try effectiveSemanticSnapshot(
            in: headerTokens,
            source: headerSource,
            text: "NS_ENUM",
            syntaxID: .preprocessor,
            language: .objectiveC,
            inOccurrenceOf: "typedef NS_ENUM(NSInteger, REReferenceState)"
        )
        _ = try effectiveSemanticSnapshot(
            in: headerTokens,
            source: headerSource,
            text: "typedef",
            syntaxID: .keyword,
            language: .objectiveC,
            inOccurrenceOf: "typedef NS_ENUM(NSInteger, REReferenceState)"
        )
        _ = try effectiveSemanticSnapshot(
            in: headerTokens,
            source: headerSource,
            text: "REReferenceState",
            syntaxID: .declarationType,
            language: .objectiveC,
            inOccurrenceOf: "typedef NS_ENUM(NSInteger, REReferenceState)"
        )
        _ = try effectiveSemanticSnapshot(
            in: headerTokens,
            source: headerSource,
            text: "NS_OPTIONS",
            syntaxID: .preprocessor,
            language: .objectiveC,
            inOccurrenceOf: "typedef NS_OPTIONS(NSUInteger, REReferenceOptions)"
        )
        _ = try effectiveSemanticSnapshot(
            in: headerTokens,
            source: headerSource,
            text: "typedef",
            syntaxID: .keyword,
            language: .objectiveC,
            inOccurrenceOf: "typedef NS_OPTIONS(NSUInteger, REReferenceOptions)"
        )
        _ = try effectiveSemanticSnapshot(
            in: headerTokens,
            source: headerSource,
            text: "REReferenceOptions",
            syntaxID: .declarationType,
            language: .objectiveC,
            inOccurrenceOf: "typedef NS_OPTIONS(NSUInteger, REReferenceOptions)"
        )
        _ = try effectiveSemanticSnapshot(
            in: headerTokens,
            source: headerSource,
            text: "NS_ASSUME_NONNULL_END",
            syntaxID: .preprocessor,
            language: .objectiveC,
            inOccurrenceOf: "NS_ASSUME_NONNULL_END"
        )

        #expect(tokens.isEmpty == false)
        _ = try effectiveSemanticSnapshot(
            in: tokens,
            source: source,
            text: "text",
            syntaxID: .declarationOther,
            language: .objectiveC,
            inOccurrenceOf: "@property(nonatomic, copy) NSString *text;"
        )
        _ = try effectiveSemanticSnapshot(
            in: tokens,
            source: source,
            text: "language",
            syntaxID: .declarationOther,
            language: .objectiveC,
            inOccurrenceOf: "@property(nonatomic, strong) id language;"
        )
        _ = try effectiveSemanticSnapshot(
            in: tokens,
            source: source,
            text: "text",
            syntaxID: .identifierVariable,
            language: .objectiveC,
            inOccurrenceOf: "return self.text.length;"
        )
        _ = try effectiveSemanticSnapshot(
            in: tokens,
            source: source,
            text: "length",
            syntaxID: .identifierVariableSystem,
            language: .objectiveC,
            inOccurrenceOf: "return self.text.length;"
        )
        _ = try effectiveSemanticSnapshot(
            in: tokens,
            source: source,
            text: "ReferenceErrorDomain",
            syntaxID: .plain,
            language: .objectiveC,
            inOccurrenceOf: "static NSString *const ReferenceErrorDomain"
        )
        _ = try effectiveSemanticSnapshot(
            in: tokens,
            source: source,
            text: "index",
            syntaxID: .plain,
            language: .objectiveC,
            inOccurrenceOf: "- (unichar)characterAtIndex:(NSUInteger)index"
        )
        _ = try effectiveSemanticSnapshot(
            in: tokens,
            source: source,
            text: "symbol",
            syntaxID: .plain,
            language: .objectiveC,
            inOccurrenceOf: "void *symbol = dlsym"
        )
        _ = try effectiveSemanticSnapshot(
            in: tokens,
            source: source,
            text: "NSMethodSignature",
            syntaxID: .identifierTypeSystem,
            language: .objectiveC,
            inOccurrenceOf: "[NSMethodSignature signatureWithObjCTypes:\"v@:{_NSRange=QQ}\"]"
        )
        _ = try effectiveSemanticSnapshot(
            in: tokens,
            source: source,
            text: "objc_msgSend",
            syntaxID: .identifierFunctionSystem,
            language: .objectiveC,
            inOccurrenceOf: "return ((id (*)(id, SEL))objc_msgSend)"
        )
        _ = try effectiveSemanticSnapshot(
            in: tokens,
            source: source,
            text: "NSSelectorFromString",
            syntaxID: .identifierFunctionSystem,
            language: .objectiveC,
            inOccurrenceOf: "NSSelectorFromString(selectorName)"
        )
        _ = try effectiveSemanticSnapshot(
            in: tokens,
            source: source,
            text: "ReferenceLog",
            syntaxID: .preprocessor,
            language: .objectiveC,
            inOccurrenceOf: "ReferenceLog(@\"display %@\""
        )
        _ = try effectiveSemanticSnapshot(
            in: tokens,
            source: source,
            text: "ReferenceSetError",
            syntaxID: .identifierFunction,
            language: .objectiveC,
            inOccurrenceOf: "return ReferenceSetError(error, 1"
        )
        _ = try effectiveSemanticSnapshot(
            in: tokens,
            source: source,
            text: "ReferenceErrorDomain",
            syntaxID: .identifierVariableSystem,
            language: .objectiveC,
            inOccurrenceOf: "errorWithDomain:ReferenceErrorDomain"
        )
        _ = try effectiveSemanticSnapshot(
            in: tokens,
            source: source,
            text: "ReferenceTokenBase",
            syntaxID: .identifierVariableSystem,
            language: .objectiveC,
            inOccurrenceOf: "code:ReferenceTokenBase + 1"
        )
        _ = try effectiveSemanticSnapshot(
            in: tokens,
            source: source,
            text: "_itemsByIdentifier",
            syntaxID: .identifierVariable,
            language: .objectiveC,
            inOccurrenceOf: "return [_itemsByIdentifier copy];"
        )
        _ = try effectiveSemanticSnapshot(
            in: tokens,
            source: source,
            text: "_Nullable",
            syntaxID: .keyword,
            language: .objectiveC,
            inOccurrenceOf: "ReferenceCallBoolError(id object, NSString *selectorName, NSError *_Nullable *_Nullable error)"
        )
        _ = try effectiveSemanticSnapshot(
            in: tokens,
            source: source,
            text: "@",
            syntaxID: .number,
            language: .objectiveC,
            inOccurrenceOf: "return @{NSLocalizedDescriptionKey: message};"
        )
        _ = try effectiveSemanticSnapshot(
            in: tokens,
            source: source,
            text: "{",
            syntaxID: .number,
            language: .objectiveC,
            inOccurrenceOf: "return @{NSLocalizedDescriptionKey: message};"
        )
        _ = try effectiveSemanticSnapshot(
            in: tokens,
            source: source,
            text: "}",
            syntaxID: .number,
            language: .objectiveC,
            inOccurrenceOf: "return @{NSLocalizedDescriptionKey: message};"
        )
        _ = try effectiveSemanticSnapshot(
            in: tokens,
            source: source,
            text: "NSLocalizedDescriptionKey",
            syntaxID: .plain,
            language: .objectiveC,
            inOccurrenceOf: "return @{NSLocalizedDescriptionKey: message};"
        )
    }

    @Test("SyntaxHighlighterEngine strips stale Objective-C overlays before incremental symbol indexing")
    func highlighterStripsStaleObjectiveCOverlaysBeforeIncrementalSymbolIndexing() async throws {
        let source = """
        int LocalFunction(void);

        void run(void) {
            LocalFunction();
        }
        """
        let removedDeclaration = "int LocalFunction(void);\n\n"
        let updatedSource = source.replacingOccurrences(of: removedDeclaration, with: "")
        let mutation = SyntaxEditorTextChange.Replacement(
            location: 0,
            length: (removedDeclaration as NSString).length,
            replacement: ""
        )
        let incrementalEngine = SyntaxHighlighterEngine()
        let fullEngine = SyntaxHighlighterEngine()

        _ = await incrementalEngine.reset(source: source, language: SyntaxLanguage.objectiveC)
        let incremental = await incrementalEngine.update(
            previousSource: source,
            source: updatedSource,
            language: SyntaxLanguage.objectiveC,
            mutation: mutation
        )
        let full = await fullEngine.reset(source: updatedSource, language: SyntaxLanguage.objectiveC)

        #expect(incremental.tokens == full.tokens)
        let functionCall = try effectiveSemanticSnapshot(
            in: incremental.tokens,
            source: updatedSource,
            text: "LocalFunction",
            syntaxID: .plain,
            language: .objectiveC,
            inOccurrenceOf: "LocalFunction();"
        )
        #expect(functionCall.styleKeys.first == "editor.syntax.plain")
        #expect(syntaxIDs(
            in: incremental.tokens,
            source: updatedSource,
            text: "LocalFunction",
            inOccurrenceOf: "LocalFunction();"
        ).contains(.identifierFunction) == false)
    }

    @Test("SyntaxHighlighterEngine strips stale Objective-C self member overlays after property removal")
    func highlighterStripsStaleObjectiveCSelfMemberOverlaysAfterPropertyRemoval() async throws {
        let source = """
        @interface Sample : NSObject
        @property(nonatomic, copy) NSString *name;
        @end

        @implementation Sample
        - (NSUInteger)length
        {
            return self.name.length;
        }
        @end
        """
        let removedProperty = "@property(nonatomic, copy) NSString *name;\n"
        let updatedSource = source.replacingOccurrences(of: removedProperty, with: "")
        let mutation = SyntaxEditorTextChange.Replacement(
            location: (source as NSString).range(of: removedProperty).location,
            length: (removedProperty as NSString).length,
            replacement: ""
        )
        let incrementalEngine = SyntaxHighlighterEngine()
        let fullEngine = SyntaxHighlighterEngine()

        _ = await incrementalEngine.reset(source: source, language: SyntaxLanguage.objectiveC)
        let incremental = await incrementalEngine.update(
            previousSource: source,
            source: updatedSource,
            language: SyntaxLanguage.objectiveC,
            mutation: mutation
        )
        let full = await fullEngine.reset(source: updatedSource, language: SyntaxLanguage.objectiveC)

        #expect(incremental.tokens == full.tokens)
        #expect(syntaxIDs(
            in: incremental.tokens,
            source: updatedSource,
            text: "name",
            inOccurrenceOf: "return self.name.length;"
        ).contains(.identifierVariable) == false)
    }

    @Test("SyntaxHighlighterEngine rebuilds Objective-C semantic index after self member root edits")
    func highlighterRebuildsObjectiveCSemanticIndexAfterSelfMemberRootEdits() async throws {
        let source = """
        @interface Sample : NSObject
        @property(nonatomic, copy) NSString *name;
        @end

        @implementation Sample
        - (NSUInteger)lengthForObject:(id)other
        {
            return self.name.length;
        }
        @end
        """
        let updatedSource = source.replacingOccurrences(of: "self.name.length", with: "other.name.length")
        let mutation = try #require(SyntaxEditorTextChange.Replacement.singleReplacement(from: source, to: updatedSource))
        let incrementalEngine = SyntaxHighlighterEngine()
        let fullEngine = SyntaxHighlighterEngine()

        _ = await incrementalEngine.reset(source: source, language: SyntaxLanguage.objectiveC)
        let incremental = await incrementalEngine.update(
            previousSource: source,
            source: updatedSource,
            language: SyntaxLanguage.objectiveC,
            mutation: mutation
        )
        let full = await fullEngine.reset(source: updatedSource, language: SyntaxLanguage.objectiveC)

        #expect(incremental.tokens == full.tokens)
        #expect(syntaxIDs(
            in: incremental.tokens,
            source: updatedSource,
            text: "name",
            inOccurrenceOf: "return other.name.length;"
        ).contains(.identifierVariable) == false)
    }

    @Test("SyntaxHighlighterEngine rebuilds Objective-C semantic index after self member receiver deletion")
    func highlighterRebuildsObjectiveCSemanticIndexAfterSelfMemberReceiverDeletion() async throws {
        let source = """
        @interface Sample : NSObject
        @property(nonatomic, copy) NSString *name;
        @end

        @implementation Sample
        - (NSUInteger)length
        {
            return self.name.length;
        }
        @end
        """
        let updatedSource = source.replacingOccurrences(of: "self.name.length", with: ".name.length")
        let mutation = try #require(SyntaxEditorTextChange.Replacement.singleReplacement(from: source, to: updatedSource))
        let incrementalEngine = SyntaxHighlighterEngine()
        let fullEngine = SyntaxHighlighterEngine()

        _ = await incrementalEngine.reset(source: source, language: SyntaxLanguage.objectiveC)
        let incremental = await incrementalEngine.update(
            previousSource: source,
            source: updatedSource,
            language: SyntaxLanguage.objectiveC,
            mutation: mutation
        )
        let full = await fullEngine.reset(source: updatedSource, language: SyntaxLanguage.objectiveC)

        #expect(incremental.tokens == full.tokens)
        #expect(syntaxIDs(
            in: incremental.tokens,
            source: updatedSource,
            text: "name",
            inOccurrenceOf: "return .name.length;"
        ).contains(.identifierVariable) == false)
    }

    @Test("SyntaxHighlighterEngine rebuilds Objective-C semantic index after self member operator deletion")
    func highlighterRebuildsObjectiveCSemanticIndexAfterSelfMemberOperatorDeletion() async throws {
        let source = """
        @interface Sample : NSObject
        @property(nonatomic, copy) NSString *name;
        @end

        @implementation Sample
        - (NSUInteger)length
        {
            return self.name.length;
        }
        @end
        """
        let updatedSource = source.replacingOccurrences(of: "self.name.length", with: "self name.length")
        let mutation = try #require(SyntaxEditorTextChange.Replacement.singleReplacement(from: source, to: updatedSource))
        let incrementalEngine = SyntaxHighlighterEngine()
        let fullEngine = SyntaxHighlighterEngine()

        _ = await incrementalEngine.reset(source: source, language: SyntaxLanguage.objectiveC)
        let incremental = await incrementalEngine.update(
            previousSource: source,
            source: updatedSource,
            language: SyntaxLanguage.objectiveC,
            mutation: mutation
        )
        let full = await fullEngine.reset(source: updatedSource, language: SyntaxLanguage.objectiveC)

        #expect(incremental.tokens == full.tokens)
        #expect(syntaxIDs(
            in: incremental.tokens,
            source: updatedSource,
            text: "name",
            inOccurrenceOf: "return self name.length;"
        ).contains(.identifierVariable) == false)
    }

    @Test("SyntaxHighlighterEngine rebuilds Objective-C semantic index after spaced self member operator deletion")
    func highlighterRebuildsObjectiveCSemanticIndexAfterSpacedSelfMemberOperatorDeletion() async throws {
        let source = """
        @interface Sample : NSObject
        @property(nonatomic, copy) NSString *name;
        @end

        @implementation Sample
        - (NSUInteger)length
        {
            return self.   name.length;
        }
        @end
        """
        let updatedSource = source.replacingOccurrences(of: "self.   name.length", with: "self   name.length")
        let mutation = try #require(SyntaxEditorTextChange.Replacement.singleReplacement(from: source, to: updatedSource))
        let incrementalEngine = SyntaxHighlighterEngine()
        let fullEngine = SyntaxHighlighterEngine()

        _ = await incrementalEngine.reset(source: source, language: SyntaxLanguage.objectiveC)
        let incremental = await incrementalEngine.update(
            previousSource: source,
            source: updatedSource,
            language: SyntaxLanguage.objectiveC,
            mutation: mutation
        )
        let full = await fullEngine.reset(source: updatedSource, language: SyntaxLanguage.objectiveC)

        #expect(incremental.tokens == full.tokens)
        #expect(syntaxIDs(
            in: incremental.tokens,
            source: updatedSource,
            text: "name",
            inOccurrenceOf: "return self   name.length;"
        ).contains(.identifierVariable) == false)
    }

    @Test("SyntaxHighlighterEngine rebuilds Objective-C semantic index after self member operator insertion")
    func highlighterRebuildsObjectiveCSemanticIndexAfterSelfMemberOperatorInsertion() async throws {
        let source = """
        @interface Sample : NSObject
        @property(nonatomic, copy) NSString *name;
        @end

        @implementation Sample
        - (NSUInteger)length
        {
            return self.name length;
        }
        @end
        """
        let updatedSource = source.replacingOccurrences(of: "self.name length", with: "self.name.length")
        let mutation = try #require(SyntaxEditorTextChange.Replacement.singleReplacement(from: source, to: updatedSource))
        let incrementalEngine = SyntaxHighlighterEngine()
        let fullEngine = SyntaxHighlighterEngine()

        _ = await incrementalEngine.reset(source: source, language: SyntaxLanguage.objectiveC)
        let incremental = await incrementalEngine.update(
            previousSource: source,
            source: updatedSource,
            language: SyntaxLanguage.objectiveC,
            mutation: mutation
        )
        let full = await fullEngine.reset(source: updatedSource, language: SyntaxLanguage.objectiveC)

        #expect(incremental.tokens == full.tokens)
        #expect(syntaxIDs(
            in: incremental.tokens,
            source: updatedSource,
            text: "length",
            inOccurrenceOf: "return self.name.length;"
        ).contains(.identifierVariableSystem))
    }

    @Test("SyntaxHighlighterEngine invalidates Objective-C semantic ranges after interior insertions")
    func highlighterInvalidatesObjectiveCSemanticRangesAfterInteriorInsertions() async throws {
        let source = """
        @interface Sample : NSObject
        @property(nonatomic, copy) NSString *name;
        @end

        @implementation Sample
        - (NSUInteger)length
        {
            return self.name.length;
        }
        @end
        """
        let insertedSource = source.replacingOccurrences(of: "self.name.length", with: "self.nxame.length")
        let finalSource = insertedSource.replacingOccurrences(of: "self.nxame.length", with: "self.nxam.length")
        let insertionMutation = try #require(SyntaxEditorTextChange.Replacement.singleReplacement(from: source, to: insertedSource))
        let deletionMutation = try #require(SyntaxEditorTextChange.Replacement.singleReplacement(from: insertedSource, to: finalSource))
        let incrementalEngine = SyntaxHighlighterEngine()
        let fullEngine = SyntaxHighlighterEngine()

        _ = await incrementalEngine.reset(source: source, language: SyntaxLanguage.objectiveC)
        _ = await incrementalEngine.update(
            previousSource: source,
            source: insertedSource,
            language: SyntaxLanguage.objectiveC,
            mutation: insertionMutation
        )
        let incremental = await incrementalEngine.update(
            previousSource: insertedSource,
            source: finalSource,
            language: SyntaxLanguage.objectiveC,
            mutation: deletionMutation
        )
        let full = await fullEngine.reset(source: finalSource, language: SyntaxLanguage.objectiveC)

        #expect(incremental.tokens == full.tokens)
        #expect(syntaxIDs(
            in: incremental.tokens,
            source: finalSource,
            text: "nxam",
            inOccurrenceOf: "return self.nxam.length;"
        ).contains(.identifierVariable) == false)
    }

    @Test("SyntaxHighlighterEngine invalidates Objective-C semantic range keys after interior insertions")
    func highlighterInvalidatesObjectiveCSemanticRangeKeysAfterInteriorInsertions() async throws {
        let source = """
        @interface Sample : NSObject
        @property(nonatomic, copy) NSString *name;
        @end

        @implementation Sample
        - (NSUInteger)length
        {
            return self.name.length;
        }
        @end
        """
        let updatedSource = source.replacingOccurrences(of: "self.name.length", with: "self.name.lexngth")
        let mutation = try #require(SyntaxEditorTextChange.Replacement.singleReplacement(from: source, to: updatedSource))
        let incrementalEngine = SyntaxHighlighterEngine()
        let fullEngine = SyntaxHighlighterEngine()

        _ = await incrementalEngine.reset(source: source, language: SyntaxLanguage.objectiveC)
        let incremental = await incrementalEngine.update(
            previousSource: source,
            source: updatedSource,
            language: SyntaxLanguage.objectiveC,
            mutation: mutation
        )
        let full = await fullEngine.reset(source: updatedSource, language: SyntaxLanguage.objectiveC)

        #expect(incremental.tokens == full.tokens)
        #expect(syntaxIDs(
            in: incremental.tokens,
            source: updatedSource,
            text: "lexngth",
            inOccurrenceOf: "return self.name.lexngth;"
        ).contains(.identifierVariableSystem))
    }

    @Test("SyntaxHighlighterEngine strips stale Objective-C property declaration overlays after syntax edits")
    func highlighterStripsStaleObjectiveCPropertyDeclarationOverlaysAfterSyntaxEdits() async throws {
        let source = """
        @interface Sample : NSObject
        @property(nonatomic, copy)
        NSString *name;
        @end
        """
        let semicolonRange = (source as NSString).range(of: "name;")
        let semicolonLocation = semicolonRange.location + "name".utf16.count
        let updatedSource = (source as NSString).replacingCharacters(
            in: NSRange(location: semicolonLocation, length: 1),
            with: ""
        )
        let mutation = SyntaxEditorTextChange.Replacement(
            location: semicolonLocation,
            length: 1,
            replacement: ""
        )
        let incrementalEngine = SyntaxHighlighterEngine()
        let fullEngine = SyntaxHighlighterEngine()

        _ = await incrementalEngine.reset(source: source, language: SyntaxLanguage.objectiveC)
        let incremental = await incrementalEngine.update(
            previousSource: source,
            source: updatedSource,
            language: SyntaxLanguage.objectiveC,
            mutation: mutation
        )
        let full = await fullEngine.reset(source: updatedSource, language: SyntaxLanguage.objectiveC)

        #expect(incremental.tokens == full.tokens)
    }

    @Test("SyntaxHighlighterEngine keeps Objective-C semantic refresh ranges local")
    func highlighterKeepsObjectiveCSemanticRefreshRangesLocal() async throws {
        let source = """
        int LocalFunction(void);

        void run(void) {
            LocalFunction();
            int value = 1;
        }
        """
        let updatedSource = source.replacingOccurrences(of: "value = 1", with: "value = 2")
        let mutation = try #require(SyntaxEditorTextChange.Replacement.singleReplacement(from: source, to: updatedSource))
        let incrementalEngine = SyntaxHighlighterEngine()
        let fullEngine = SyntaxHighlighterEngine()

        _ = await incrementalEngine.reset(source: source, language: SyntaxLanguage.objectiveC)
        let incremental = await incrementalEngine.update(
            previousSource: source,
            source: updatedSource,
            language: SyntaxLanguage.objectiveC,
            mutation: mutation
        )
        let full = await fullEngine.reset(source: updatedSource, language: SyntaxLanguage.objectiveC)

        #expect(incremental.tokens == full.tokens)
        #expect(refreshRangeUnion(incremental).length < updatedSource.utf16.count)
    }

    @Test("SyntaxHighlighterEngine keeps Objective-C property-heavy reference edits equal to full reset")
    func highlighterKeepsObjectiveCPropertyHeavyReferenceEditsEqualToFullReset() async throws {
        let properties = (0..<120)
            .map { "@property(nonatomic, copy) NSString *name\($0);" }
            .joined(separator: "\n")
        let source = """
        @interface Heavy : NSObject
        \(properties)
        @end

        @implementation Heavy
        - (NSUInteger)length
        {
            NSUInteger value = self.name42.length + 1;
            return value;
        }
        @end
        """
        let updatedSource = source.replacingOccurrences(of: "self.name42.length + 1", with: "self.name42.length + 2")
        let mutation = try #require(SyntaxEditorTextChange.Replacement.singleReplacement(from: source, to: updatedSource))
        let incrementalEngine = SyntaxHighlighterEngine()
        let fullEngine = SyntaxHighlighterEngine()

        _ = await incrementalEngine.reset(source: source, language: SyntaxLanguage.objectiveC)
        let incremental = await incrementalEngine.update(
            previousSource: source,
            source: updatedSource,
            language: SyntaxLanguage.objectiveC,
            mutation: mutation
        )
        let full = await fullEngine.reset(source: updatedSource, language: SyntaxLanguage.objectiveC)

        #expect(incremental.tokens == full.tokens)
        #expect(refreshRangeUnion(incremental).length < updatedSource.utf16.count)
        _ = try effectiveSemanticSnapshot(
            in: incremental.tokens,
            source: updatedSource,
            text: "name42",
            syntaxID: .identifierVariable,
            language: .objectiveC,
            inOccurrenceOf: "self.name42.length"
        )
        _ = try effectiveSemanticSnapshot(
            in: incremental.tokens,
            source: updatedSource,
            text: "length",
            syntaxID: .identifierVariableSystem,
            language: .objectiveC,
            inOccurrenceOf: "self.name42.length"
        )
    }

    @Test("SyntaxHighlighterEngine rebuilds Objective-C semantic index after same-length property declaration edits")
    func highlighterRebuildsObjectiveCSemanticIndexAfterSameLengthPropertyDeclarationEdits() async throws {
        let source = """
        @interface Sample : NSObject
        @property(nonatomic) NSInteger foo;
        @end

        @implementation Sample
        - (NSInteger)value
        {
            return self.foo;
        }
        @end
        """
        let nsSource = source as NSString
        let declarationRange = nsSource.range(of: "@property(nonatomic) NSInteger foo;")
        let declarationNameRange = nsSource.range(of: "foo", options: [], range: declarationRange)
        let updatedSource = nsSource.replacingCharacters(in: declarationNameRange, with: "bar")
        let mutation = SyntaxEditorTextChange.Replacement(location: declarationNameRange.location, length: declarationNameRange.length, replacement: "bar")
        let incrementalEngine = SyntaxHighlighterEngine()
        let fullEngine = SyntaxHighlighterEngine()

        _ = await incrementalEngine.reset(source: source, language: SyntaxLanguage.objectiveC)
        let incremental = await incrementalEngine.update(
            previousSource: source,
            source: updatedSource,
            language: SyntaxLanguage.objectiveC,
            mutation: mutation
        )
        let full = await fullEngine.reset(source: updatedSource, language: SyntaxLanguage.objectiveC)
        let nsUpdatedSource = updatedSource as NSString
        let referenceRange = nsUpdatedSource.range(of: "self.foo")
        let referenceNameRange = nsUpdatedSource.range(of: "foo", options: [], range: referenceRange)

        #expect(incremental.tokens == full.tokens)
        #expect(incremental.tokens.contains {
            tokenIntersects($0, range: referenceNameRange, syntaxID: .identifierVariable, language: .objectiveC)
        } == false)
        #expect(SyntaxEditorRangeUtilities.intersection(of: refreshRangeUnion(incremental), and: referenceNameRange) == referenceNameRange)
    }

    @Test("SyntaxHighlighterEngine rebuilds Objective-C semantic index after property keyword edits")
    func highlighterRebuildsObjectiveCSemanticIndexAfterPropertyKeywordEdits() async throws {
        let source = """
        @interface Sample : NSObject
        @property(nonatomic) NSString *name;
        @end

        @implementation Sample
        - (NSString *)value
        {
            return self.name;
        }
        @end
        """
        let keywordRange = (source as NSString).range(of: "@property")
        let mutationRange = NSRange(location: keywordRange.location + 1, length: 1)
        let updatedSource = (source as NSString).replacingCharacters(in: mutationRange, with: "x")
        let mutation = SyntaxEditorTextChange.Replacement(
            location: mutationRange.location,
            length: mutationRange.length,
            replacement: "x"
        )
        let incrementalEngine = SyntaxHighlighterEngine()
        let fullEngine = SyntaxHighlighterEngine()

        _ = await incrementalEngine.reset(source: source, language: SyntaxLanguage.objectiveC)
        let incremental = await incrementalEngine.update(
            previousSource: source,
            source: updatedSource,
            language: SyntaxLanguage.objectiveC,
            mutation: mutation
        )
        let full = await fullEngine.reset(source: updatedSource, language: SyntaxLanguage.objectiveC)

        #expect(incremental.tokens == full.tokens)
        #expect(syntaxIDs(
            in: incremental.tokens,
            source: updatedSource,
            text: "name",
            inOccurrenceOf: "self.name"
        ).contains(.identifierVariable) == false)
    }

    @Test("SyntaxHighlighterEngine rebuilds Objective-C semantic index after file-scope variable rename")
    func highlighterRebuildsObjectiveCSemanticIndexAfterFileScopeVariableRename() async throws {
        let source = """
        static NSString *const Foo = @"value";

        NSString *readValue(void)
        {
            return Foo;
        }
        """
        let updatedSource = source.replacingOccurrences(of: "Foo = @\"value\"", with: "Bar = @\"value\"")
        let mutation = try #require(SyntaxEditorTextChange.Replacement.singleReplacement(from: source, to: updatedSource))
        let incrementalEngine = SyntaxHighlighterEngine()
        let fullEngine = SyntaxHighlighterEngine()

        _ = await incrementalEngine.reset(source: source, language: SyntaxLanguage.objectiveC)
        let incremental = await incrementalEngine.update(
            previousSource: source,
            source: updatedSource,
            language: SyntaxLanguage.objectiveC,
            mutation: mutation
        )
        let full = await fullEngine.reset(source: updatedSource, language: SyntaxLanguage.objectiveC)

        #expect(incremental.tokens == full.tokens)
    }

    @Test("SyntaxHighlighterEngine rebuilds Objective-C semantic index after declarations become non-code")
    func highlighterRebuildsObjectiveCSemanticIndexAfterDeclarationsBecomeNonCode() async throws {
        let source = """
        static NSString *Token;

        NSString *readValue(void)
        {
            return Token;
        }
        """
        for prefix in ["// ", "/* ", "\""] {
            let updatedSource = prefix + source
            let mutation = SyntaxEditorTextChange.Replacement(
                location: 0,
                length: 0,
                replacement: prefix
            )
            let incrementalEngine = SyntaxHighlighterEngine()
            let fullEngine = SyntaxHighlighterEngine()

            _ = await incrementalEngine.reset(source: source, language: SyntaxLanguage.objectiveC)
            let incremental = await incrementalEngine.update(
                previousSource: source,
                source: updatedSource,
                language: SyntaxLanguage.objectiveC,
                mutation: mutation
            )
            let full = await fullEngine.reset(source: updatedSource, language: SyntaxLanguage.objectiveC)

            #expect(incremental.tokens == full.tokens)
            #expect(syntaxIDs(
                in: incremental.tokens,
                source: updatedSource,
                text: "Token",
                inOccurrenceOf: "return Token"
            ).contains(.identifierVariable) == false)
        }
    }

    @Test("SyntaxHighlighterEngine rebuilds Objective-C semantic index after declaration prefix punctuation")
    func highlighterRebuildsObjectiveCSemanticIndexAfterDeclarationPrefixPunctuation() async throws {
        let source = """
        static NSString *Token;

        NSString *readValue(void)
        {
            return Token;
        }
        """
        let updatedSource = "/\(source)"
        let mutation = SyntaxEditorTextChange.Replacement(
            location: 0,
            length: 0,
            replacement: "/"
        )
        let incrementalEngine = SyntaxHighlighterEngine()
        let fullEngine = SyntaxHighlighterEngine()

        _ = await incrementalEngine.reset(source: source, language: SyntaxLanguage.objectiveC)
        let incremental = await incrementalEngine.update(
            previousSource: source,
            source: updatedSource,
            language: SyntaxLanguage.objectiveC,
            mutation: mutation
        )
        let full = await fullEngine.reset(source: updatedSource, language: SyntaxLanguage.objectiveC)

        #expect(incremental.tokens == full.tokens)
        #expect(syntaxIDs(
            in: incremental.tokens,
            source: updatedSource,
            text: "Token",
            inOccurrenceOf: "return Token"
        ).contains(.identifierVariable) == false)
    }

    @Test("SyntaxHighlighterEngine rebuilds Objective-C semantic index after ivar declaration rename")
    func highlighterRebuildsObjectiveCSemanticIndexAfterIvarDeclarationRename() async throws {
        let source = """
        @implementation Sample {
            BOOL foo;
        }

        - (BOOL)value
        {
            return foo;
        }
        @end
        """
        let updatedSource = source.replacingOccurrences(of: "BOOL foo;", with: "BOOL bar;")
        let mutation = try #require(SyntaxEditorTextChange.Replacement.singleReplacement(from: source, to: updatedSource))
        let incrementalEngine = SyntaxHighlighterEngine()
        let fullEngine = SyntaxHighlighterEngine()

        _ = await incrementalEngine.reset(source: source, language: SyntaxLanguage.objectiveC)
        let incremental = await incrementalEngine.update(
            previousSource: source,
            source: updatedSource,
            language: SyntaxLanguage.objectiveC,
            mutation: mutation
        )
        let full = await fullEngine.reset(source: updatedSource, language: SyntaxLanguage.objectiveC)

        #expect(incremental.tokens == full.tokens)
    }

    @Test("SyntaxHighlighterEngine rebuilds Objective-C semantic index after initialized local shadow renames")
    func highlighterRebuildsObjectiveCSemanticIndexAfterInitializedLocalShadowRename() async throws {
        let source = """
        static NSString *const Token = @"global";

        void run(void)
        {
            NSString *Other = @"local";
            NSLog(@"%@", Token);
        }
        """
        let updatedSource = source.replacingOccurrences(of: "Other", with: "Token")
        let mutation = try #require(SyntaxEditorTextChange.Replacement.singleReplacement(from: source, to: updatedSource))
        let incrementalEngine = SyntaxHighlighterEngine()
        let fullEngine = SyntaxHighlighterEngine()

        _ = await incrementalEngine.reset(source: source, language: SyntaxLanguage.objectiveC)
        let incremental = await incrementalEngine.update(
            previousSource: source,
            source: updatedSource,
            language: SyntaxLanguage.objectiveC,
            mutation: mutation
        )
        let full = await fullEngine.reset(source: updatedSource, language: SyntaxLanguage.objectiveC)

        #expect(incremental.tokens == full.tokens)
        _ = try effectiveSemanticSnapshot(
            in: incremental.tokens,
            source: updatedSource,
            text: "Token",
            syntaxID: .plain,
            language: .objectiveC,
            inOccurrenceOf: "NSLog(@\"%@\", Token);"
        )
    }

    @Test("SyntaxHighlighterEngine ignores Objective-C declaration-like text inside comments and strings")
    func highlighterIgnoresObjectiveCDeclarationLikeTextInsideCommentsAndStrings() async throws {
        let source = """
        static NSString *const Token = @"global";

        void run(void)
        {
            /*
            NSString *Token = @"local";
            */
            NSString *text = @"NSString *Token = @\\"local\\";";
            NSLog(@"%@", Token);
        }
        """
        let tokens = await sharedSyntaxHighlighterEngine.render(source: source, language: SyntaxLanguage.objectiveC)

        _ = try effectiveSemanticSnapshot(
            in: tokens,
            source: source,
            text: "Token",
            syntaxID: .identifierVariableSystem,
            language: .objectiveC,
            inOccurrenceOf: "NSLog(@\"%@\", Token);"
        )
    }

    @Test("SyntaxHighlighterEngine rebuilds Objective-C semantic index after split parameter shadow renames")
    func highlighterRebuildsObjectiveCSemanticIndexAfterSplitParameterShadowRename() async throws {
        let source = """
        static NSString *const Token = @"global";

        void run(NSString *Other)
        {
            NSLog(@"%@", Token);
        }
        """
        let updatedSource = source.replacingOccurrences(of: "Other", with: "Token")
        let mutation = try #require(SyntaxEditorTextChange.Replacement.singleReplacement(from: source, to: updatedSource))
        let incrementalEngine = SyntaxHighlighterEngine()
        let fullEngine = SyntaxHighlighterEngine()

        _ = await incrementalEngine.reset(source: source, language: SyntaxLanguage.objectiveC)
        let incremental = await incrementalEngine.update(
            previousSource: source,
            source: updatedSource,
            language: SyntaxLanguage.objectiveC,
            mutation: mutation
        )
        let full = await fullEngine.reset(source: updatedSource, language: SyntaxLanguage.objectiveC)

        #expect(incremental.tokens == full.tokens)
        _ = try effectiveSemanticSnapshot(
            in: incremental.tokens,
            source: updatedSource,
            text: "Token",
            syntaxID: .plain,
            language: .objectiveC,
            inOccurrenceOf: "NSLog(@\"%@\", Token);"
        )
    }

    @Test("SyntaxHighlighterEngine rebuilds Objective-C semantic index after for-loop shadow renames")
    func highlighterRebuildsObjectiveCSemanticIndexAfterForLoopShadowRename() async throws {
        let source = """
        static NSString *const Token = @"global";

        void run(NSArray<NSString *> *values)
        {
            for (NSString *Other in values) {
                NSLog(@"%@", Token);
            }
            NSLog(@"%@", Token);
        }
        """
        let updatedSource = source.replacingOccurrences(of: "Other", with: "Token")
        let mutation = try #require(SyntaxEditorTextChange.Replacement.singleReplacement(from: source, to: updatedSource))
        let incrementalEngine = SyntaxHighlighterEngine()
        let fullEngine = SyntaxHighlighterEngine()

        _ = await incrementalEngine.reset(source: source, language: SyntaxLanguage.objectiveC)
        let incremental = await incrementalEngine.update(
            previousSource: source,
            source: updatedSource,
            language: SyntaxLanguage.objectiveC,
            mutation: mutation
        )
        let full = await fullEngine.reset(source: updatedSource, language: SyntaxLanguage.objectiveC)

        #expect(incremental.tokens == full.tokens)
        _ = try effectiveSemanticSnapshot(
            in: incremental.tokens,
            source: updatedSource,
            text: "Token",
            syntaxID: .plain,
            language: .objectiveC,
            inOccurrenceOf: "values) {\n        NSLog(@\"%@\", Token);"
        )
        _ = try effectiveSemanticSnapshot(
            in: incremental.tokens,
            source: updatedSource,
            text: "Token",
            syntaxID: .identifierVariableSystem,
            language: .objectiveC,
            inOccurrenceOf: "}\n    NSLog(@\"%@\", Token);"
        )
    }

    @Test("SyntaxHighlighterEngine strips stale Objective-C local macro call overlays after macro removal")
    func highlighterStripsStaleObjectiveCLocalMacroCallOverlaysAfterMacroRemoval() async throws {
        let source = """
        #define ReferenceLog(format, ...) NSLog(format, ##__VA_ARGS__)

        void run(void)
        {
            ReferenceLog(@"value");
        }
        """
        let updatedSource = source.replacingOccurrences(
            of: "#define ReferenceLog(format, ...) NSLog(format, ##__VA_ARGS__)\n\n",
            with: ""
        )
        let mutation = try #require(SyntaxEditorTextChange.Replacement.singleReplacement(from: source, to: updatedSource))
        let incrementalEngine = SyntaxHighlighterEngine()
        let fullEngine = SyntaxHighlighterEngine()

        _ = await incrementalEngine.reset(source: source, language: SyntaxLanguage.objectiveC)
        let incremental = await incrementalEngine.update(
            previousSource: source,
            source: updatedSource,
            language: SyntaxLanguage.objectiveC,
            mutation: mutation
        )
        let full = await fullEngine.reset(source: updatedSource, language: SyntaxLanguage.objectiveC)

        #expect(incremental.tokens == full.tokens)
        #expect(syntaxIDs(
            in: incremental.tokens,
            source: updatedSource,
            text: "ReferenceLog",
            inOccurrenceOf: "ReferenceLog(@\"value\")"
        ).contains(.preprocessor) == false)
    }

    @Test("SyntaxHighlighterEngine strips stale Objective-C local macro overlays after call opener deletion")
    func highlighterStripsStaleObjectiveCLocalMacroOverlaysAfterCallOpenerDeletion() async throws {
        let source = """
        #define ReferenceLog(format, ...) NSLog(format, ##__VA_ARGS__)

        void run(void)
        {
            ReferenceLog(@"value");
        }
        """
        let updatedSource = source.replacingOccurrences(of: "ReferenceLog(", with: "ReferenceLog ")
        let mutation = try #require(SyntaxEditorTextChange.Replacement.singleReplacement(from: source, to: updatedSource))
        let incrementalEngine = SyntaxHighlighterEngine()
        let fullEngine = SyntaxHighlighterEngine()

        _ = await incrementalEngine.reset(source: source, language: SyntaxLanguage.objectiveC)
        let incremental = await incrementalEngine.update(
            previousSource: source,
            source: updatedSource,
            language: SyntaxLanguage.objectiveC,
            mutation: mutation
        )
        let full = await fullEngine.reset(source: updatedSource, language: SyntaxLanguage.objectiveC)

        #expect(incremental.tokens == full.tokens)
        #expect(syntaxIDs(
            in: incremental.tokens,
            source: updatedSource,
            text: "ReferenceLog",
            inOccurrenceOf: "ReferenceLog @\"value\")"
        ).contains(.preprocessor) == false)
    }

    @Test("SyntaxHighlighterEngine rebuilds Objective-C semantic index after macro marker deletion")
    func highlighterRebuildsObjectiveCSemanticIndexAfterMacroMarkerDeletion() async throws {
        let source = """
        #define ReferenceLog(format, ...) NSLog(format, ##__VA_ARGS__)

        void run(void)
        {
            ReferenceLog(@"value");
        }
        """
        let updatedSource = source.replacingOccurrences(
            of: "#define ReferenceLog",
            with: "define ReferenceLog"
        )
        let mutation = try #require(SyntaxEditorTextChange.Replacement.singleReplacement(from: source, to: updatedSource))
        let incrementalEngine = SyntaxHighlighterEngine()
        let fullEngine = SyntaxHighlighterEngine()

        _ = await incrementalEngine.reset(source: source, language: SyntaxLanguage.objectiveC)
        let incremental = await incrementalEngine.update(
            previousSource: source,
            source: updatedSource,
            language: SyntaxLanguage.objectiveC,
            mutation: mutation
        )
        let full = await fullEngine.reset(source: updatedSource, language: SyntaxLanguage.objectiveC)

        #expect(incremental.tokens == full.tokens)
        #expect(syntaxIDs(
            in: incremental.tokens,
            source: updatedSource,
            text: "ReferenceLog",
            inOccurrenceOf: "ReferenceLog(@\"value\")"
        ).contains(.preprocessor) == false)
    }

    @Test("SyntaxHighlighterEngine recomputes Objective-C structural ranges after failed index shifts")
    func highlighterRecomputesObjectiveCStructuralRangesAfterFailedIndexShifts() async throws {
        let source = """
        @interface Sample : NSObject
        @property(nonatomic, copy) NSString *name;
        @end

        @implementation Sample
        - (NSUInteger)length
        {
            return self.name.length;
        }
        @end

        #define ReferenceLog(format, ...) NSLog(format, ##__VA_ARGS__)

        void run(void)
        {
            ReferenceLog(@"value");
        }
        """
        let insertedSource = source.replacingOccurrences(of: "self.name.length", with: "self.nxame.length")
        let finalSource = insertedSource.replacingOccurrences(
            of: "#define ReferenceLog",
            with: "define ReferenceLog"
        )
        let insertionMutation = try #require(SyntaxEditorTextChange.Replacement.singleReplacement(from: source, to: insertedSource))
        let macroMutation = try #require(SyntaxEditorTextChange.Replacement.singleReplacement(from: insertedSource, to: finalSource))
        let incrementalEngine = SyntaxHighlighterEngine()
        let fullEngine = SyntaxHighlighterEngine()

        _ = await incrementalEngine.reset(source: source, language: SyntaxLanguage.objectiveC)
        _ = await incrementalEngine.update(
            previousSource: source,
            source: insertedSource,
            language: SyntaxLanguage.objectiveC,
            mutation: insertionMutation
        )
        let incremental = await incrementalEngine.update(
            previousSource: insertedSource,
            source: finalSource,
            language: SyntaxLanguage.objectiveC,
            mutation: macroMutation
        )
        let full = await fullEngine.reset(source: finalSource, language: SyntaxLanguage.objectiveC)

        #expect(incremental.tokens == full.tokens)
        #expect(syntaxIDs(
            in: incremental.tokens,
            source: finalSource,
            text: "ReferenceLog",
            inOccurrenceOf: "ReferenceLog(@\"value\")"
        ).contains(.preprocessor) == false)
    }

    @Test("SyntaxHighlighterEngine keeps Objective-C local statics out of file-scope overlays")
    func highlighterKeepsObjectiveCLocalStaticsOutOfFileScopeOverlays() async throws {
        let source = """
        void run(void)
        {
        static NSInteger counter = 0;
        counter += 1;
        }
        """
        let tokens = await sharedSyntaxHighlighterEngine.render(source: source, language: SyntaxLanguage.objectiveC)

        _ = try effectiveSemanticSnapshot(
            in: tokens,
            source: source,
            text: "counter",
            syntaxID: .plain,
            language: .objectiveC,
            inOccurrenceOf: "counter += 1"
        )
    }

    @Test("SyntaxHighlighterEngine recognizes Objective-C comma-separated variable declarations")
    func highlighterRecognizesObjectiveCCommaSeparatedVariableDeclarations() async throws {
        let source = """
        static NSString *const Foo = @"foo", *Bar = @"bar";

        @implementation Sample {
            BOOL firstFlag, secondFlag;
        }

        - (BOOL)value
        {
            return secondFlag;
        }
        @end

        NSString *readValue(void)
        {
            return Bar;
        }
        """
        let tokens = await sharedSyntaxHighlighterEngine.render(source: source, language: SyntaxLanguage.objectiveC)

        _ = try effectiveSemanticSnapshot(
            in: tokens,
            source: source,
            text: "secondFlag",
            syntaxID: .identifierVariable,
            language: .objectiveC,
            inOccurrenceOf: "return secondFlag;"
        )
        _ = try effectiveSemanticSnapshot(
            in: tokens,
            source: source,
            text: "Bar",
            syntaxID: .identifierVariableSystem,
            language: .objectiveC,
            inOccurrenceOf: "return Bar;"
        )
    }

    @Test("SyntaxHighlighterEngine rebuilds Objective-C semantic index after variable semicolon deletion")
    func highlighterRebuildsObjectiveCSemanticIndexAfterVariableSemicolonDeletion() async throws {
        let source = """
        static NSString *Token;

        void run(void)
        {
            NSLog(@"%@", Token);
        }
        """
        let updatedSource = source.replacingOccurrences(
            of: "static NSString *Token;",
            with: "static NSString *Token"
        )
        let mutation = try #require(SyntaxEditorTextChange.Replacement.singleReplacement(from: source, to: updatedSource))
        let incrementalEngine = SyntaxHighlighterEngine()
        let fullEngine = SyntaxHighlighterEngine()

        _ = await incrementalEngine.reset(source: source, language: SyntaxLanguage.objectiveC)
        let incremental = await incrementalEngine.update(
            previousSource: source,
            source: updatedSource,
            language: SyntaxLanguage.objectiveC,
            mutation: mutation
        )
        let full = await fullEngine.reset(source: updatedSource, language: SyntaxLanguage.objectiveC)

        #expect(incremental.tokens == full.tokens)
        #expect(syntaxIDs(
            in: incremental.tokens,
            source: updatedSource,
            text: "Token",
            inOccurrenceOf: "NSLog(@\"%@\", Token)"
        ).contains(.identifierVariableSystem) == false)
    }

    @Test("SyntaxHighlighterEngine rebuilds Objective-C semantic index after variable qualifier changes")
    func highlighterRebuildsObjectiveCSemanticIndexAfterVariableQualifierChanges() async throws {
        let source = """
        static NSString *Token;

        void run(void)
        {
            NSLog(@"%@", Token);
        }
        """
        let updatedSource = source.replacingOccurrences(
            of: "static NSString *Token;",
            with: "extern NSString *Token;"
        )
        let mutation = try #require(SyntaxEditorTextChange.Replacement.singleReplacement(from: source, to: updatedSource))
        let incrementalEngine = SyntaxHighlighterEngine()
        let fullEngine = SyntaxHighlighterEngine()

        _ = await incrementalEngine.reset(source: source, language: SyntaxLanguage.objectiveC)
        let incremental = await incrementalEngine.update(
            previousSource: source,
            source: updatedSource,
            language: SyntaxLanguage.objectiveC,
            mutation: mutation
        )
        let full = await fullEngine.reset(source: updatedSource, language: SyntaxLanguage.objectiveC)

        #expect(incremental.tokens == full.tokens)
        #expect(syntaxIDs(
            in: incremental.tokens,
            source: updatedSource,
            text: "Token",
            inOccurrenceOf: "NSLog(@\"%@\", Token)"
        ).contains(.identifierVariableSystem) == false)
    }

    @Test("SyntaxHighlighterEngine keeps Objective-C value edits local")
    func highlighterKeepsObjectiveCValueEditsLocal() async throws {
        let source = """
        static NSInteger Token = 1;

        void run(void)
        {
            NSInteger local = 1;
            NSLog(@"%ld", (long)local);
            NSLog(@"%ld", (long)Token);
        }
        """
        let updatedSource = source.replacingOccurrences(
            of: "NSInteger local = 1;",
            with: "NSInteger local = 2;"
        )
        let mutation = try #require(SyntaxEditorTextChange.Replacement.singleReplacement(from: source, to: updatedSource))
        let incrementalEngine = SyntaxHighlighterEngine()
        let fullEngine = SyntaxHighlighterEngine()

        _ = await incrementalEngine.reset(source: source, language: SyntaxLanguage.objectiveC)
        let incremental = await incrementalEngine.update(
            previousSource: source,
            source: updatedSource,
            language: SyntaxLanguage.objectiveC,
            mutation: mutation
        )
        let full = await fullEngine.reset(source: updatedSource, language: SyntaxLanguage.objectiveC)

        #expect(incremental.tokens == full.tokens)
        #expect(refreshRangeUnion(incremental).length < updatedSource.utf16.count / 2)
    }

    @Test("SyntaxHighlighterEngine keeps large Objective-C value edits scoped")
    func highlighterKeepsLargeObjectiveCValueEditsScoped() async throws {
        let declarations = (0..<100)
            .map { "static NSInteger Value\($0) = \($0);" }
            .joined(separator: "\n")
        let source = """
        \(declarations)

        void run(void)
        {
            NSInteger local = 1;
            NSLog(@"%ld", (long)local);
        }
        """
        let updatedSource = source.replacingOccurrences(
            of: "NSInteger local = 1;",
            with: "NSInteger local = 2;"
        )
        let mutation = try #require(SyntaxEditorTextChange.Replacement.singleReplacement(from: source, to: updatedSource))
        let incrementalEngine = SyntaxHighlighterEngine()
        let fullEngine = SyntaxHighlighterEngine()

        _ = await incrementalEngine.reset(source: source, language: SyntaxLanguage.objectiveC)
        let incremental = await incrementalEngine.update(
            previousSource: source,
            source: updatedSource,
            language: SyntaxLanguage.objectiveC,
            mutation: mutation
        )
        let full = await fullEngine.reset(source: updatedSource, language: SyntaxLanguage.objectiveC)

        #expect(incremental.tokens == full.tokens)
        #expect(refreshRangeUnion(incremental).length < 256)
    }

    @Test("SyntaxHighlighterEngine keeps large Objective-C multiline body edits scoped")
    func highlighterKeepsLargeObjectiveCMultilineBodyEditsScoped() async throws {
        let declarations = (0..<100)
            .map { "static NSInteger Value\($0) = \($0);" }
            .joined(separator: "\n")
        let source = """
        \(declarations)

        static NSInteger ReferenceCallInteger(id object, NSString *selectorName)
        {
            return ((NSInteger (*)(id, SEL))objc_msgSend)(object, NSSelectorFromString(selectorName));
        }

        static BOOL ReferenceCallBool(id object, NSString *selectorName)
        {
            return ((BOOL (*)(id, SEL))objc_msgSend)(object, NSSelectorFromString(selectorName));
        }
        """
        let updatedSource = source.replacingOccurrences(
            of: "    return ((NSInteger (*)(id, SEL))objc_msgSend)(object, NSSelectorFromString(selectorName));",
            with: """
                return aa;
                sefepuaepufepua
                feousoueoufeouseoure;
                return ((NSInteger (*)(id, SEL))objc_msgSend)(object, NSSelectorFromString(selectorName));
            """
        )
        let mutation = try #require(SyntaxEditorTextChange.Replacement.singleReplacement(from: source, to: updatedSource))
        let incrementalEngine = SyntaxHighlighterEngine()
        let fullEngine = SyntaxHighlighterEngine()

        _ = await incrementalEngine.reset(source: source, language: SyntaxLanguage.objectiveC)
        let incremental = await incrementalEngine.update(
            previousSource: source,
            source: updatedSource,
            language: SyntaxLanguage.objectiveC,
            mutation: mutation
        )
        let full = await fullEngine.reset(source: updatedSource, language: SyntaxLanguage.objectiveC)

        #expect(incremental.tokens == full.tokens)
        #expect(refreshRangeUnion(incremental).length < 512)
    }

    @Test("SyntaxHighlighterEngine keeps Objective-C macro continuation edits scoped")
    func highlighterKeepsObjectiveCMacroContinuationEditsScoped() async throws {
        let source = """
        #define LOG_VALUE(value) \\
            NSLog(@"%ld", (long)(value))

        void run(void)
        {
            NSInteger local = 1;
            LOG_VALUE(local);
        }
        """
        let updatedSource = source.replacingOccurrences(
            of: "LOG_VALUE(local);",
            with: "LOG_VALUE(local + 1);"
        )
        let mutation = try #require(SyntaxEditorTextChange.Replacement.singleReplacement(from: source, to: updatedSource))
        let incrementalEngine = SyntaxHighlighterEngine()
        let fullEngine = SyntaxHighlighterEngine()

        _ = await incrementalEngine.reset(source: source, language: SyntaxLanguage.objectiveC)
        let incremental = await incrementalEngine.update(
            previousSource: source,
            source: updatedSource,
            language: SyntaxLanguage.objectiveC,
            mutation: mutation
        )
        let full = await fullEngine.reset(source: updatedSource, language: SyntaxLanguage.objectiveC)

        #expect(incremental.tokens == full.tokens)
        #expect(refreshRangeUnion(incremental).length < updatedSource.utf16.count)
    }

    @Test("SyntaxHighlighterEngine rebuilds Objective-C semantic index after declaration value member edits")
    func highlighterRebuildsObjectiveCSemanticIndexAfterDeclarationValueMemberEdits() async throws {
        let source = """
        @interface Sample : NSObject
        @property(nonatomic) NSInteger bar;
        @end

        @implementation Sample
        - (void)run
        {
            NSInteger value = self.foo;
            NSLog(@"%ld", (long)value);
        }
        @end
        """
        let updatedSource = source.replacingOccurrences(of: "self.foo", with: "self.bar")
        let mutation = try #require(SyntaxEditorTextChange.Replacement.singleReplacement(from: source, to: updatedSource))
        let incrementalEngine = SyntaxHighlighterEngine()
        let fullEngine = SyntaxHighlighterEngine()

        _ = await incrementalEngine.reset(source: source, language: SyntaxLanguage.objectiveC)
        let incremental = await incrementalEngine.update(
            previousSource: source,
            source: updatedSource,
            language: SyntaxLanguage.objectiveC,
            mutation: mutation
        )
        let full = await fullEngine.reset(source: updatedSource, language: SyntaxLanguage.objectiveC)

        #expect(incremental.tokens == full.tokens)
        #expect(syntaxIDs(
            in: incremental.tokens,
            source: updatedSource,
            text: "bar",
            inOccurrenceOf: "NSInteger value = self.bar;"
        ).contains(.identifierVariable))
    }

    @Test("SyntaxHighlighterEngine keeps Objective-C local shadows plain")
    func highlighterKeepsObjectiveCLocalShadowsPlain() async throws {
        let source = """
        static NSString *const Token = @"global";

        @implementation Sample {
            BOOL enabled;
        }

        - (BOOL)value
        {
            BOOL enabled;
            return enabled;
        }

        void run(void)
        {
            if (YES) {
                NSString *Token = @"local";
                NSLog(@"%@", Token);
            }
            NSLog(@"%@", Token);
        }

        NSString *readValue(void)
        {
            NSString *Token = @"local";
            return Token;
        }

        void loop(NSArray<NSString *> *values)
        {
            for (NSString *Token in values) {
                NSLog(@"%@", Token);
            }
            NSLog(@"%@", Token);
        }

        void
        splitRun(void)
        {
            NSString *Token = @"local";
            NSLog(@"%@", Token);
        }

        void
        splitParameter(NSString *Token)
        {
            NSLog(@"%@", Token);
        }

        void commented(void)
        {
            /*
            NSString *Token = nil;
            */
            NSLog(@"%@", Token);
        }

        void commentBrace(void)
        {
            NSString *Token = @"local";
            // }
            NSLog(@"%@", Token);
        }

        void commentBraceSignature(void) // {
        {
            NSString *Token = @"local";
            NSLog(@"%@", Token);
        }

        void blockScope(void)
        {
            {
                NSString *Token = @"local";
                NSLog(@"%@", Token);
            }
            NSLog(@"%@", Token);
        }

        void commaLocal(void)
        {
            NSString *Other = @"other", *Token = @"local";
            // comma local use
            NSLog(@"%@", Token);
        }
        @end
        """
        let tokens = await sharedSyntaxHighlighterEngine.render(source: source, language: SyntaxLanguage.objectiveC)

        _ = try effectiveSemanticSnapshot(
            in: tokens,
            source: source,
            text: "enabled",
            syntaxID: .plain,
            language: .objectiveC,
            inOccurrenceOf: "return enabled"
        )
        _ = try effectiveSemanticSnapshot(
            in: tokens,
            source: source,
            text: "Token",
            syntaxID: .plain,
            language: .objectiveC,
            inOccurrenceOf: "values) {\n        NSLog(@\"%@\", Token);"
        )
        _ = try effectiveSemanticSnapshot(
            in: tokens,
            source: source,
            text: "Token",
            syntaxID: .identifierVariableSystem,
            language: .objectiveC,
            inOccurrenceOf: "}\n    NSLog(@\"%@\", Token);"
        )
        _ = try effectiveSemanticSnapshot(
            in: tokens,
            source: source,
            text: "Token",
            syntaxID: .plain,
            language: .objectiveC,
            inOccurrenceOf: "return Token;"
        )
        _ = try effectiveSemanticSnapshot(
            in: tokens,
            source: source,
            text: "Token",
            syntaxID: .plain,
            language: .objectiveC,
            inOccurrenceOf: "for (NSString *Token in values)"
        )
        _ = try effectiveSemanticSnapshot(
            in: tokens,
            source: source,
            text: "Token",
            syntaxID: .plain,
            language: .objectiveC,
            inOccurrenceOf: "NSLog(@\"%@\", Token);\n    }"
        )
        _ = try effectiveSemanticSnapshot(
            in: tokens,
            source: source,
            text: "Token",
            syntaxID: .identifierVariableSystem,
            language: .objectiveC,
            inOccurrenceOf: "}\n    NSLog(@\"%@\", Token);\n}\n\nvoid\nsplitRun"
        )
        _ = try effectiveSemanticSnapshot(
            in: tokens,
            source: source,
            text: "Token",
            syntaxID: .plain,
            language: .objectiveC,
            inOccurrenceOf: "splitRun(void)\n{\n    NSString *Token"
        )
        _ = try effectiveSemanticSnapshot(
            in: tokens,
            source: source,
            text: "Token",
            syntaxID: .plain,
            language: .objectiveC,
            inOccurrenceOf: "NSLog(@\"%@\", Token);\n}\n\nvoid\nsplitParameter"
        )
        _ = try effectiveSemanticSnapshot(
            in: tokens,
            source: source,
            text: "Token",
            syntaxID: .plain,
            language: .objectiveC,
            inOccurrenceOf: "splitParameter(NSString *Token)"
        )
        _ = try effectiveSemanticSnapshot(
            in: tokens,
            source: source,
            text: "Token",
            syntaxID: .plain,
            language: .objectiveC,
            inOccurrenceOf: "NSLog(@\"%@\", Token);\n}\n\nvoid commented"
        )
        _ = try effectiveSemanticSnapshot(
            in: tokens,
            source: source,
            text: "Token",
            syntaxID: .identifierVariableSystem,
            language: .objectiveC,
            inOccurrenceOf: "*/\n    NSLog(@\"%@\", Token);\n}\n\nvoid commentBrace"
        )
        _ = try effectiveSemanticSnapshot(
            in: tokens,
            source: source,
            text: "Token",
            syntaxID: .plain,
            language: .objectiveC,
            inOccurrenceOf: "// }\n    NSLog(@\"%@\", Token);"
        )
        _ = try effectiveSemanticSnapshot(
            in: tokens,
            source: source,
            text: "Token",
            syntaxID: .plain,
            language: .objectiveC,
            inOccurrenceOf: "commentBraceSignature(void) // {\n{\n    NSString *Token"
        )
        _ = try effectiveSemanticSnapshot(
            in: tokens,
            source: source,
            text: "Token",
            syntaxID: .plain,
            language: .objectiveC,
            inOccurrenceOf: "NSString *Token = @\"local\";\n        NSLog(@\"%@\", Token);"
        )
        _ = try effectiveSemanticSnapshot(
            in: tokens,
            source: source,
            text: "Token",
            syntaxID: .identifierVariableSystem,
            language: .objectiveC,
            inOccurrenceOf: "}\n    NSLog(@\"%@\", Token);\n}\n\nvoid commaLocal"
        )
        _ = try effectiveSemanticSnapshot(
            in: tokens,
            source: source,
            text: "Token",
            syntaxID: .plain,
            language: .objectiveC,
            inOccurrenceOf: "// comma local use\n    NSLog(@\"%@\", Token);"
        )
    }

    @Test("SyntaxHighlighterEngine recognizes indented Objective-C file-scope variables after comments")
    func highlighterRecognizesIndentedObjectiveCFileScopeVariablesAfterComments() async throws {
        let source = """
        // {
            static NSString *const Token = @"global";

        void run(void)
        {
            NSLog(@"%@", Token);
        }
        """
        let tokens = await sharedSyntaxHighlighterEngine.render(source: source, language: SyntaxLanguage.objectiveC)

        _ = try effectiveSemanticSnapshot(
            in: tokens,
            source: source,
            text: "Token",
            syntaxID: .identifierVariableSystem,
            language: .objectiveC,
            inOccurrenceOf: "NSLog(@\"%@\", Token);"
        )
    }

    @Test("SyntaxHighlighterEngine handles inline Objective-C implementation ivar blocks")
    func highlighterHandlesInlineObjectiveCImplementationIvarBlocks() async throws {
        let source = """
        @implementation Sample { BOOL _flag; NSString *_name; }
        - (BOOL)value
        {
            BOOL temporary;
            return _flag;
        }
        - (NSString *)name
        {
            return _name;
        }
        - (BOOL)other
        {
            return temporary;
        }
        @end
        """
        let tokens = await sharedSyntaxHighlighterEngine.render(source: source, language: SyntaxLanguage.objectiveC)

        _ = try effectiveSemanticSnapshot(
            in: tokens,
            source: source,
            text: "_flag",
            syntaxID: .identifierVariable,
            language: .objectiveC,
            inOccurrenceOf: "return _flag;"
        )
        _ = try effectiveSemanticSnapshot(
            in: tokens,
            source: source,
            text: "NSString",
            syntaxID: .identifierTypeSystem,
            language: .objectiveC,
            inOccurrenceOf: "NSString *_name;"
        )
        _ = try effectiveSemanticSnapshot(
            in: tokens,
            source: source,
            text: "_name",
            syntaxID: .identifierVariable,
            language: .objectiveC,
            inOccurrenceOf: "return _name;"
        )
        #expect(syntaxIDs(
            in: tokens,
            source: source,
            text: "temporary",
            inOccurrenceOf: "return temporary;"
        ).contains(.identifierVariable) == false)
    }

    @Test("SyntaxHighlighterEngine keeps Objective-C ivars after implementation comments")
    func highlighterKeepsObjectiveCIvarsAfterImplementationComments() async throws {
        let source = """
        @implementation Sample
        // storage
        {
            BOOL enabled;
        }

        - (BOOL)value
        {
            return enabled;
        }
        @end
        """
        let tokens = await sharedSyntaxHighlighterEngine.render(source: source, language: SyntaxLanguage.objectiveC)

        _ = try effectiveSemanticSnapshot(
            in: tokens,
            source: source,
            text: "enabled",
            syntaxID: .identifierVariable,
            language: .objectiveC,
            inOccurrenceOf: "return enabled;"
        )
    }

    @Test("SyntaxHighlighterEngine ignores Objective-C comment braces before ivar blocks")
    func highlighterIgnoresObjectiveCCommentBracesBeforeIvarBlocks() async throws {
        let source = """
        @implementation Sample
        // {
        - (BOOL)value
        {
            BOOL temporary;
            return temporary;
        }
        - (BOOL)other
        {
            return temporary;
        }
        @end
        """
        let tokens = await sharedSyntaxHighlighterEngine.render(source: source, language: SyntaxLanguage.objectiveC)

        #expect(syntaxIDs(
            in: tokens,
            source: source,
            text: "temporary",
            inOccurrenceOf: "return temporary;\n}"
        ).contains(.identifierVariable) == false)
    }

    @Test("SyntaxHighlighterEngine keeps Objective-C semantic overlays after source-length edits")
    func highlighterKeepsObjectiveCSemanticOverlaysAfterSourceLengthEdits() async throws {
        let source = """
        @interface Sample : NSObject
        @property(nonatomic, copy) NSString *name;
        @end

        @implementation Sample
        - (NSUInteger)length
        {
            return self.name.length + 1;
        }
        @end
        """
        let prefix = "// inserted comment\n"
        let prefixedSource = prefix + source
        let updatedSource = prefixedSource.replacingOccurrences(of: "self.name.length + 1", with: "self.name.length + 2")
        let referenceMutation = try #require(SyntaxEditorTextChange.Replacement.singleReplacement(from: prefixedSource, to: updatedSource))
        let incrementalEngine = SyntaxHighlighterEngine()
        let fullEngine = SyntaxHighlighterEngine()

        _ = await incrementalEngine.reset(source: source, language: SyntaxLanguage.objectiveC)
        _ = await incrementalEngine.update(
            previousSource: source,
            source: prefixedSource,
            language: SyntaxLanguage.objectiveC,
            mutation: SyntaxEditorTextChange.Replacement(location: 0, length: 0, replacement: prefix)
        )
        let incremental = await incrementalEngine.update(
            previousSource: prefixedSource,
            source: updatedSource,
            language: SyntaxLanguage.objectiveC,
            mutation: referenceMutation
        )
        let full = await fullEngine.reset(source: updatedSource, language: SyntaxLanguage.objectiveC)

        #expect(incremental.tokens == full.tokens)
        #expect(refreshRangeUnion(incremental).length < updatedSource.utf16.count)
        _ = try effectiveSemanticSnapshot(
            in: incremental.tokens,
            source: updatedSource,
            text: "name",
            syntaxID: .identifierVariable,
            language: .objectiveC,
            inOccurrenceOf: "self.name.length"
        )
    }

    @Test("SyntaxHighlighterEngine removes Objective-C semantic overlays after property declaration removal")
    func highlighterRemovesObjectiveCSemanticOverlaysAfterPropertyDeclarationRemoval() async throws {
        let source = """
        @interface Sample : NSObject
        @property(nonatomic, copy) NSString *name;
        @end

        @implementation Sample
        - (NSUInteger)length
        {
            return self.name.length + 1;
        }
        @end
        """
        let updatedSource = source.replacingOccurrences(
            of: "@property(nonatomic, copy) NSString *name;\n",
            with: ""
        )
        let mutation = try #require(SyntaxEditorTextChange.Replacement.singleReplacement(from: source, to: updatedSource))
        let incrementalEngine = SyntaxHighlighterEngine()
        let fullEngine = SyntaxHighlighterEngine()

        _ = await incrementalEngine.reset(source: source, language: SyntaxLanguage.objectiveC)
        let incremental = await incrementalEngine.update(
            previousSource: source,
            source: updatedSource,
            language: SyntaxLanguage.objectiveC,
            mutation: mutation
        )
        let full = await fullEngine.reset(source: updatedSource, language: SyntaxLanguage.objectiveC)
        let nsSource = updatedSource as NSString
        let returnRange = nsSource.range(of: "self.name.length")
        let nameRange = nsSource.range(of: "name", options: [], range: returnRange)

        #expect(incremental.tokens == full.tokens)
        #expect(incremental.tokens.contains {
            tokenIntersects($0, range: nameRange, syntaxID: .identifierVariable, language: .objectiveC)
        } == false)
    }

    @Test("SyntaxHighlighterEngine removes Objective-C semantic overlays after property line break deletion")
    func highlighterRemovesObjectiveCSemanticOverlaysAfterPropertyLineBreakDeletion() async throws {
        let source = """
        @interface Sample : NSObject
        // disabled
        @property(nonatomic, copy) NSString *name;
        @end

        @implementation Sample
        - (NSUInteger)length
        {
            return self.name.length + 1;
        }
        @end
        """
        let nsSource = source as NSString
        let deletedLineBreakRange = nsSource.range(of: "\n@property")
        let deletedLineBreakLocation = try #require(
            deletedLineBreakRange.location == NSNotFound ? nil : deletedLineBreakRange.location
        )
        let mutation = SyntaxEditorTextChange.Replacement(
            location: deletedLineBreakLocation,
            length: 1,
            replacement: ""
        )
        let updatedSource = nsSource.replacingCharacters(
            in: NSRange(location: deletedLineBreakLocation, length: 1),
            with: ""
        )
        let incrementalEngine = SyntaxHighlighterEngine()
        let fullEngine = SyntaxHighlighterEngine()

        _ = await incrementalEngine.reset(source: source, language: SyntaxLanguage.objectiveC)
        let incremental = await incrementalEngine.update(
            previousSource: source,
            source: updatedSource,
            language: SyntaxLanguage.objectiveC,
            mutation: mutation
        )
        let full = await fullEngine.reset(source: updatedSource, language: SyntaxLanguage.objectiveC)
        let updatedNSString = updatedSource as NSString
        let returnRange = updatedNSString.range(of: "self.name.length")
        let nameRange = updatedNSString.range(of: "name", options: [], range: returnRange)

        #expect(incremental.tokens == full.tokens)
        #expect(incremental.tokens.contains {
            tokenIntersects($0, range: nameRange, syntaxID: .identifierVariable, language: .objectiveC)
        } == false)
    }

    @Test("SyntaxHighlighterEngine uses Objective-C parser invalidation beyond semantic line ranges")
    func highlighterUsesObjectiveCParserInvalidationBeyondSemanticLineRanges() async throws {
        let source = """
        int first = 1;
        int second = 2;
        int third = 3;
        """
        let updatedSource = source.replacingOccurrences(of: "int second = 2;", with: "/* int second = 2;")
        let mutation = try #require(SyntaxEditorTextChange.Replacement.singleReplacement(from: source, to: updatedSource))
        let incrementalEngine = SyntaxHighlighterEngine()
        let fullEngine = SyntaxHighlighterEngine()

        _ = await incrementalEngine.reset(source: source, language: SyntaxLanguage.objectiveC)
        let incremental = await incrementalEngine.update(
            previousSource: source,
            source: updatedSource,
            language: SyntaxLanguage.objectiveC,
            mutation: mutation
        )
        let full = await fullEngine.reset(source: updatedSource, language: SyntaxLanguage.objectiveC)

        #expect(incremental.tokens == full.tokens)
    }

    @Test("SyntaxHighlighterEngine replaces Objective-C semantic overlays inside partial target range")
    func highlighterReplacesObjectiveCSemanticOverlaysInsidePartialTargetRange() async throws {
        let source = """
        @interface Sample : NSObject
        @property(nonatomic, copy) NSString *name;
        @property(nonatomic, copy) NSString *title;
        @end

        @implementation Sample
        - (NSUInteger)length
        {
            return self.name.length + self.title.length;
        }
        @end
        """
        let updatedSource = source.replacingOccurrences(
            of: "self.name.length",
            with: "self.title.length",
            options: [],
            range: source.range(of: "self.name.length")
        )
        let mutation = try #require(SyntaxEditorTextChange.Replacement.singleReplacement(from: source, to: updatedSource))
        let incrementalEngine = SyntaxHighlighterEngine()
        let fullEngine = SyntaxHighlighterEngine()

        _ = await incrementalEngine.reset(source: source, language: SyntaxLanguage.objectiveC)
        let incremental = await incrementalEngine.update(
            previousSource: source,
            source: updatedSource,
            language: SyntaxLanguage.objectiveC,
            mutation: mutation
        )
        let full = await fullEngine.reset(source: updatedSource, language: SyntaxLanguage.objectiveC)

        #expect(incremental.tokens == full.tokens)
        #expect(refreshRangeUnion(incremental).length < updatedSource.utf16.count)
        _ = try effectiveSemanticSnapshot(
            in: incremental.tokens,
            source: updatedSource,
            text: "title",
            syntaxID: .identifierVariable,
            language: .objectiveC,
            inOccurrenceOf: "return self.title.length"
        )
    }

    @Test("SyntaxHighlighterEngine inserts Objective-C semantic overlays inside partial target range")
    func highlighterInsertsObjectiveCSemanticOverlaysInsidePartialTargetRange() async throws {
        let source = """
        id boxed(void)
        {
            return ;
        }
        """
        let updatedSource = source.replacingOccurrences(of: "return ;", with: "return @YES;")
        let mutation = try #require(SyntaxEditorTextChange.Replacement.singleReplacement(from: source, to: updatedSource))
        let incrementalEngine = SyntaxHighlighterEngine()
        let fullEngine = SyntaxHighlighterEngine()

        _ = await incrementalEngine.reset(source: source, language: SyntaxLanguage.objectiveC)
        let incremental = await incrementalEngine.update(
            previousSource: source,
            source: updatedSource,
            language: SyntaxLanguage.objectiveC,
            mutation: mutation
        )
        let full = await fullEngine.reset(source: updatedSource, language: SyntaxLanguage.objectiveC)

        #expect(incremental.tokens == full.tokens)
        #expect(refreshRangeUnion(incremental).length < updatedSource.utf16.count)
        #expect(syntaxIDs(
            in: incremental.tokens,
            source: updatedSource,
            text: "@YES",
            inOccurrenceOf: "return @YES;"
        ).contains(.number))
    }

    @Test("SyntaxHighlighterEngine strips stale Objective-C boxed expression delimiters across partial ranges")
    func highlighterStripsStaleObjectiveCBoxedExpressionDelimitersAcrossPartialRanges() async throws {
        let source = """
        NSNumber *boxed(NSUInteger count)
        {
            return @(
                count
            );
        }
        """
        let updatedSource = source.replacingOccurrences(of: "return @(", with: "return (")
        let mutation = try #require(SyntaxEditorTextChange.Replacement.singleReplacement(from: source, to: updatedSource))
        let incrementalEngine = SyntaxHighlighterEngine()
        let fullEngine = SyntaxHighlighterEngine()

        _ = await incrementalEngine.reset(source: source, language: SyntaxLanguage.objectiveC)
        let incremental = await incrementalEngine.update(
            previousSource: source,
            source: updatedSource,
            language: SyntaxLanguage.objectiveC,
            mutation: mutation
        )
        let full = await fullEngine.reset(source: updatedSource, language: SyntaxLanguage.objectiveC)

        #expect(incremental.tokens == full.tokens)
        #expect(syntaxIDs(
            in: incremental.tokens,
            source: updatedSource,
            text: ")",
            inOccurrenceOf: "count\n    );"
        ).contains(.number) == false)
    }

    @Test("SyntaxHighlighterEngine strips stale Objective-C boxed expression delimiters after opener deletion")
    func highlighterStripsStaleObjectiveCBoxedExpressionDelimitersAfterOpenerDeletion() async throws {
        let source = """
        NSNumber *boxed(NSUInteger count)
        {
            return @(
                count
            );
        }
        """
        let updatedSource = source.replacingOccurrences(of: "return @(", with: "return @")
        let mutation = try #require(SyntaxEditorTextChange.Replacement.singleReplacement(from: source, to: updatedSource))
        let incrementalEngine = SyntaxHighlighterEngine()
        let fullEngine = SyntaxHighlighterEngine()

        _ = await incrementalEngine.reset(source: source, language: SyntaxLanguage.objectiveC)
        let incremental = await incrementalEngine.update(
            previousSource: source,
            source: updatedSource,
            language: SyntaxLanguage.objectiveC,
            mutation: mutation
        )
        let full = await fullEngine.reset(source: updatedSource, language: SyntaxLanguage.objectiveC)

        #expect(incremental.tokens == full.tokens)
        #expect(syntaxIDs(
            in: incremental.tokens,
            source: updatedSource,
            text: ")",
            inOccurrenceOf: "count\n    );"
        ).contains(.number) == false)
    }

    @Test("SyntaxHighlighterEngine strips stale Objective-C boxed boolean overlays after identifier replacement")
    func highlighterStripsStaleObjectiveCBoxedBooleanOverlaysAfterIdentifierReplacement() async throws {
        let source = """
        id boxed(BOOL flag)
        {
            return @YES;
        }
        """
        let updatedSource = source.replacingOccurrences(of: "@YES", with: "flag")
        let mutation = try #require(SyntaxEditorTextChange.Replacement.singleReplacement(from: source, to: updatedSource))
        let incrementalEngine = SyntaxHighlighterEngine()
        let fullEngine = SyntaxHighlighterEngine()

        _ = await incrementalEngine.reset(source: source, language: SyntaxLanguage.objectiveC)
        let incremental = await incrementalEngine.update(
            previousSource: source,
            source: updatedSource,
            language: SyntaxLanguage.objectiveC,
            mutation: mutation
        )
        let full = await fullEngine.reset(source: updatedSource, language: SyntaxLanguage.objectiveC)

        #expect(incremental.tokens == full.tokens)
        #expect(syntaxIDs(
            in: incremental.tokens,
            source: updatedSource,
            text: "flag",
            inOccurrenceOf: "return flag;"
        ).contains(.number) == false)
    }

    @Test("SyntaxHighlighterEngine incrementally updates Objective-C reference sample like a full reset")
    func highlighterIncrementallyUpdatesObjectiveCReferenceSampleLikeFullReset() async throws {
        let source = try referenceSampleText(named: "Reference.m")
        let updatedSource = source.replacingOccurrences(
            of: "ReferenceTokenBase + 1",
            with: "ReferenceTokenBase + 2",
            options: [],
            range: source.range(of: "ReferenceTokenBase + 1")
        )
        let mutation = try #require(SyntaxEditorTextChange.Replacement.singleReplacement(from: source, to: updatedSource))
        let incrementalEngine = SyntaxHighlighterEngine()
        let fullEngine = SyntaxHighlighterEngine()

        _ = await incrementalEngine.reset(source: source, language: SyntaxLanguage.objectiveC)
        let incremental = await incrementalEngine.update(
            previousSource: source,
            source: updatedSource,
            language: SyntaxLanguage.objectiveC,
            mutation: mutation
        )
        let full = await fullEngine.reset(source: updatedSource, language: SyntaxLanguage.objectiveC)

        #expect(incremental.tokens == full.tokens)
        #expect(refreshRangeUnion(incremental).length < updatedSource.utf16.count)
    }

    @Test("SyntaxHighlighterEngine strips stale Objective-C type shadows after declaration removal")
    func highlighterStripsStaleObjectiveCTypeShadowsAfterDeclarationRemoval() async throws {
        let source = """
        @interface NSString : NSObject
        @end

        void run(void) {
            NSString *value = nil;
        }
        """
        let removedDeclaration = """
        @interface NSString : NSObject
        @end

        """
        let updatedSource = source.replacingOccurrences(of: removedDeclaration, with: "")
        let mutation = SyntaxEditorTextChange.Replacement(
            location: 0,
            length: (removedDeclaration as NSString).length,
            replacement: ""
        )
        let incrementalEngine = SyntaxHighlighterEngine()
        let fullEngine = SyntaxHighlighterEngine()

        _ = await incrementalEngine.reset(source: source, language: SyntaxLanguage.objectiveC)
        let incremental = await incrementalEngine.update(
            previousSource: source,
            source: updatedSource,
            language: SyntaxLanguage.objectiveC,
            mutation: mutation
        )
        let full = await fullEngine.reset(source: updatedSource, language: SyntaxLanguage.objectiveC)

        #expect(incremental.tokens == full.tokens)
        let systemType = try effectiveSemanticSnapshot(
            in: incremental.tokens,
            source: updatedSource,
            text: "NSString",
            syntaxID: .identifierTypeSystem,
            language: .objectiveC,
            inOccurrenceOf: "NSString *value"
        )
        #expect(systemType.styleKeys.first == "editor.syntax.identifier.type.system")
    }

    @Test("SyntaxHighlighterEngine rebuilds Objective-C semantic index after type declaration rename")
    func highlighterRebuildsObjectiveCSemanticIndexAfterTypeDeclarationRename() async throws {
        let source = """
        @interface NSString : NSObject
        @end

        void run(void) {
            NSString *value = nil;
        }
        """
        let updatedSource = source.replacingOccurrences(of: "@interface NSString", with: "@interface NSStringShadow")
        let mutation = try #require(SyntaxEditorTextChange.Replacement.singleReplacement(from: source, to: updatedSource))
        let incrementalEngine = SyntaxHighlighterEngine()
        let fullEngine = SyntaxHighlighterEngine()

        _ = await incrementalEngine.reset(source: source, language: SyntaxLanguage.objectiveC)
        let incremental = await incrementalEngine.update(
            previousSource: source,
            source: updatedSource,
            language: SyntaxLanguage.objectiveC,
            mutation: mutation
        )
        let full = await fullEngine.reset(source: updatedSource, language: SyntaxLanguage.objectiveC)

        #expect(incremental.tokens == full.tokens)
        let systemType = try effectiveSemanticSnapshot(
            in: incremental.tokens,
            source: updatedSource,
            text: "NSString",
            syntaxID: .identifierTypeSystem,
            language: .objectiveC,
            inOccurrenceOf: "NSString *value"
        )
        #expect(systemType.styleKeys.first == "editor.syntax.identifier.type.system")
    }

    @Test("SyntaxHighlighterEngine rebuilds Objective-C semantic index after type keyword edits")
    func highlighterRebuildsObjectiveCSemanticIndexAfterTypeKeywordEdits() async throws {
        let source = """
        @interface NSString : NSObject
        @end

        void run(void) {
            NSString *value = nil;
        }
        """
        let keywordRange = (source as NSString).range(of: "@interface")
        let mutationRange = NSRange(location: keywordRange.location + 1, length: 1)
        let updatedSource = (source as NSString).replacingCharacters(in: mutationRange, with: "x")
        let mutation = SyntaxEditorTextChange.Replacement(
            location: mutationRange.location,
            length: mutationRange.length,
            replacement: "x"
        )
        let incrementalEngine = SyntaxHighlighterEngine()
        let fullEngine = SyntaxHighlighterEngine()

        _ = await incrementalEngine.reset(source: source, language: SyntaxLanguage.objectiveC)
        let incremental = await incrementalEngine.update(
            previousSource: source,
            source: updatedSource,
            language: SyntaxLanguage.objectiveC,
            mutation: mutation
        )
        let full = await fullEngine.reset(source: updatedSource, language: SyntaxLanguage.objectiveC)

        #expect(incremental.tokens == full.tokens)
        let systemType = try effectiveSemanticSnapshot(
            in: incremental.tokens,
            source: updatedSource,
            text: "NSString",
            syntaxID: .identifierTypeSystem,
            language: .objectiveC,
            inOccurrenceOf: "NSString *value"
        )
        #expect(systemType.styleKeys.first == "editor.syntax.identifier.type.system")
    }
}

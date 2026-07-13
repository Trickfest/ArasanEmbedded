#import <Foundation/Foundation.h>

NS_ASSUME_NONNULL_BEGIN

typedef void (^NS_SWIFT_SENDABLE AELineHandler)(NSString *line);

/// Package-internal Objective-C++ transport used by the public Swift
/// `ArasanEngine` API. External consumers should depend on the
/// `ArasanEmbedded` library product rather than importing this module directly.
@interface AEEngine : NSObject

- (instancetype)init NS_UNAVAILABLE;
+ (instancetype)new NS_UNAVAILABLE;

- (instancetype)initWithLineHandler:(AELineHandler)handler NS_DESIGNATED_INITIALIZER;

/// Starts only when the atomic batch contains a canonical, preflighted NNUE
/// option. The no-argument entry point therefore returns `NO`; it remains for
/// source compatibility with older bridge builds.
- (BOOL)startEngine;
- (BOOL)startEngineWithCommands:(NSArray<NSString *> *)commands NS_SWIFT_NAME(startEngine(commands:));
- (void)sendCommand:(NSString *)command;
- (void)stop;

@property(nonatomic, readonly, getter=isRunning) BOOL running;
@property(nonatomic, readonly) NSUInteger engineThreadStackSize;

@end

NS_ASSUME_NONNULL_END

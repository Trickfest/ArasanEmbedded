#import <Foundation/Foundation.h>

NS_ASSUME_NONNULL_BEGIN

typedef void (^AELineHandler)(NSString *line);

@interface AEEngine : NSObject

- (instancetype)initWithLineHandler:(AELineHandler)handler;

- (BOOL)startEngine;
- (void)sendCommand:(NSString *)command;
- (void)stop;

@property(nonatomic, readonly, getter=isRunning) BOOL running;

@end

NS_ASSUME_NONNULL_END

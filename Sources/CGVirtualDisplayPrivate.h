// CoreGraphics의 비공개 가상 디스플레이 API 선언.
// 공개 헤더에는 없지만 CoreGraphics 프레임워크에 들어 있는 클래스들이다.

#import <Cocoa/Cocoa.h>
#import <CoreGraphics/CoreGraphics.h>

NS_ASSUME_NONNULL_BEGIN

@class CGVirtualDisplay;

@interface CGVirtualDisplayMode : NSObject
@property(readonly, nonatomic) NSUInteger width;
@property(readonly, nonatomic) NSUInteger height;
@property(readonly, nonatomic) double refreshRate;
- (instancetype)initWithWidth:(NSUInteger)width
                       height:(NSUInteger)height
                  refreshRate:(double)refreshRate;
@end

@interface CGVirtualDisplaySettings : NSObject
@property(retain, nonatomic) NSArray<CGVirtualDisplayMode *> *modes;
@property(nonatomic) unsigned int hiDPI;
- (instancetype)init;
@end

@interface CGVirtualDisplayDescriptor : NSObject
@property(retain, nonatomic) NSString *name;
@property(nonatomic) unsigned int maxPixelsWide;
@property(nonatomic) unsigned int maxPixelsHigh;
@property(nonatomic) CGSize sizeInMillimeters;
@property(nonatomic) unsigned int serialNum;
@property(nonatomic) unsigned int productID;
@property(nonatomic) unsigned int vendorID;
@property(copy, nonatomic, nullable) void (^terminationHandler)(id, CGVirtualDisplay *);
- (instancetype)init;
- (void)setDispatchQueue:(dispatch_queue_t)queue;
@end

@interface CGVirtualDisplay : NSObject
@property(readonly, nonatomic) CGDirectDisplayID displayID;
- (nullable instancetype)initWithDescriptor:(CGVirtualDisplayDescriptor *)descriptor;
- (BOOL)applySettings:(CGVirtualDisplaySettings *)settings;
@end

NS_ASSUME_NONNULL_END

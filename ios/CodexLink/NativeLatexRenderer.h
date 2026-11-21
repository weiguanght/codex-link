#import <UIKit/UIKit.h>

@interface NativeLatexImage : NSObject
@property(nonatomic, strong, readonly) UIImage *image;
@property(nonatomic, readonly) CGFloat baseline;
- (instancetype)init NS_UNAVAILABLE;
@end

@interface NativeLatexRenderer : NSObject
+ (nullable NativeLatexImage *)render:(NSString *)latex
                           widthLimit:(CGFloat)widthLimit
                             fontSize:(CGFloat)fontSize
                            textColor:(UIColor *)textColor
                              display:(BOOL)display;
@end

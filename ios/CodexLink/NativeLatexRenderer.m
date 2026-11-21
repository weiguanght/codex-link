#import "NativeLatexRenderer.h"
#import <TargetConditionals.h>

#if !TARGET_OS_SIMULATOR
@interface CDSLatexRender : NSObject
- (nullable instancetype)initWith:(NSString *)latex
                            width:(float)width
                             argb:(uint32_t)argb
                         fontSize:(int32_t)fontSize
                        lineSpace:(float)lineSpace
                            error:(NSError * _Nullable __autoreleasing *)error;
@property(nonatomic, readonly) int width;
@property(nonatomic, readonly) int height;
@property(nonatomic, readonly) int baseline;
- (void)draw:(CGContextRef)context;
@end
#endif

@interface NativeLatexImage ()
@property(nonatomic, strong, readwrite) UIImage *image;
@property(nonatomic, readwrite) CGFloat baseline;
- (instancetype)initWithImage:(UIImage *)image baseline:(CGFloat)baseline;
@end

@implementation NativeLatexImage
- (instancetype)initWithImage:(UIImage *)image baseline:(CGFloat)baseline {
    self = [super init];
    if (self) {
        _image = image;
        _baseline = baseline;
    }
    return self;
}
@end

@implementation NativeLatexRenderer
+ (NativeLatexImage *)render:(NSString *)latex
                  widthLimit:(CGFloat)widthLimit
                    fontSize:(CGFloat)fontSize
                   textColor:(UIColor *)textColor {
#if TARGET_OS_SIMULATOR
    return nil;
#else
    if (latex.length == 0 || widthLimit <= 0 || fontSize <= 0) return nil;

    CGFloat red = 0, green = 0, blue = 0, alpha = 0;
    if (![textColor getRed:&red green:&green blue:&blue alpha:&alpha]) return nil;
    uint32_t argb = ((uint32_t)lrint(alpha * 255) << 24)
        | ((uint32_t)lrint(red * 255) << 16)
        | ((uint32_t)lrint(green * 255) << 8)
        | (uint32_t)lrint(blue * 255);

    NSError *error = nil;
    CDSLatexRender *render = [[CDSLatexRender alloc] initWith:latex
                                                       width:(float)widthLimit
                                                        argb:argb
                                                    fontSize:(int32_t)lrint(fontSize)
                                                   lineSpace:(float)(fontSize * 0.2)
                                                       error:&error];
    if (!render || render.width <= 0 || render.height <= 0) return nil;

    CGSize size = CGSizeMake(render.width, render.height);
    UIGraphicsImageRendererFormat *format = [UIGraphicsImageRendererFormat defaultFormat];
    format.scale = UIScreen.mainScreen.scale;
    format.opaque = NO;
    UIGraphicsImageRenderer *renderer = [[UIGraphicsImageRenderer alloc] initWithSize:size format:format];
    UIImage *image = [renderer imageWithActions:^(UIGraphicsImageRendererContext *context) {
        [render draw:context.CGContext];
    }];
    if (!image.CGImage) return nil;
    return [[NativeLatexImage alloc] initWithImage:image baseline:render.baseline];
#endif
}
@end

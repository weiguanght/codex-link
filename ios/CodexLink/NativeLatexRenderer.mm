#import "NativeLatexRenderer.h"

#include "core/formula.h"
#include "latex.h"
#include "platform/apple/graphic_apple.h"
#include "utils/utf.h"

#include <cmath>
#include <memory>
#include <mutex>
#include <string>

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
                   textColor:(UIColor *)textColor
                     display:(BOOL)display {
    if (latex.length == 0 || widthLimit <= 0 || fontSize <= 0 || !textColor) return nil;
    if (latex.length > 1000 || widthLimit > 4096 || fontSize > 256) return nil;

    static std::once_flag initialization;
    static std::mutex renderMutex;
    static bool initialized = false;
    std::lock_guard<std::mutex> lock(renderMutex);

    std::call_once(initialization, [] {
        @autoreleasepool {
            NSURL *resourceRoot = [[NSBundle mainBundle].resourceURL URLByAppendingPathComponent:@"res" isDirectory:YES];
            NSURL *marker = [resourceRoot URLByAppendingPathComponent:@".clatexmath-res_root"];
            if (![[NSFileManager defaultManager] fileExistsAtPath:marker.path]) return;
            const char *path = resourceRoot.fileSystemRepresentation;
            if (!path) return;
            try {
                tex::Formula::setDPITarget(72.f);
                tex::LaTeX::init(std::string(path));
                initialized = true;
            } catch (...) {
                initialized = false;
            }
        }
    });
    if (!initialized) return nil;

    CGFloat red = 0, green = 0, blue = 0, alpha = 0;
    if (![textColor getRed:&red green:&green blue:&blue alpha:&alpha]) return nil;
    const tex::color foreground = tex::argb(
        static_cast<int>(std::lround(alpha * 255)),
        static_cast<int>(std::lround(red * 255)),
        static_cast<int>(std::lround(green * 255)),
        static_cast<int>(std::lround(blue * 255)));

    std::string source(latex.UTF8String ?: "");
    if (source.empty()) return nil;
    std::wstring wrapped = display ? L"\\[" : L"\\(";
    wrapped += tex::utf82wide(source);
    wrapped += display ? L"\\]" : L"\\)";

    std::unique_ptr<tex::TeXRender> layout;
    try {
        auto *render = tex::LaTeX::parse(wrapped,
            static_cast<int>(std::floor(widthLimit)),
            static_cast<float>(fontSize),
            static_cast<float>(fontSize * 0.2),
            foreground);
        layout.reset(render);
    } catch (...) {
        return nil;
    }
    if (!layout) return nil;

    const CGFloat width = layout->getWidth();
    const CGFloat height = layout->getHeight();
    if (!std::isfinite(width) || !std::isfinite(height) || width <= 0 || height <= 0 || width > 8192 || height > 8192) return nil;

    CGSize size = CGSizeMake(width, height);
    UIGraphicsImageRendererFormat *format = [UIGraphicsImageRendererFormat defaultFormat];
    format.scale = UIScreen.mainScreen.scale;
    format.opaque = NO;
    UIGraphicsImageRenderer *renderer = [[UIGraphicsImageRenderer alloc] initWithSize:size format:format];
    tex::TeXRender *renderPointer = layout.get();
    UIImage *image = [renderer imageWithActions:^(UIGraphicsImageRendererContext *context) {
        tex::drawAppleFormula(*renderPointer, context.CGContext);
    }];
    if (!image.CGImage) return nil;

    const CGFloat baseline = layout->getBaseline() * height;
    if (!std::isfinite(baseline) || baseline < 0 || baseline > height) return nil;
    return [[NativeLatexImage alloc] initWithImage:image baseline:baseline];
}
@end

#ifndef GRAPHIC_APPLE_H_INCLUDED
#define GRAPHIC_APPLE_H_INCLUDED

#include "render.h"

#import <CoreGraphics/CoreGraphics.h>

namespace tex {

void drawAppleFormula(TeXRender& render, CGContextRef context);

}  // namespace tex

#endif  // GRAPHIC_APPLE_H_INCLUDED

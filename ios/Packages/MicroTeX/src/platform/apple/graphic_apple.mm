#include "graphic/graphic.h"
#include "platform/apple/graphic_apple.h"

#import <CoreText/CoreText.h>
#import <Foundation/Foundation.h>

#include <cmath>
#include <vector>

using namespace std;

namespace tex {

static vector<UniChar> toUTF16(const wstring& text) {
  vector<UniChar> result;
  result.reserve(text.size());
  for (wchar_t value : text) {
    uint32_t codepoint = static_cast<uint32_t>(value);
    if (codepoint >= 0xd800 && codepoint <= 0xdbff) {
      result.push_back(static_cast<UniChar>(codepoint));
    } else if (codepoint >= 0xdc00 && codepoint <= 0xdfff) {
      result.push_back(static_cast<UniChar>(codepoint));
    } else if (codepoint > 0xffff && codepoint <= 0x10ffff) {
      codepoint -= 0x10000;
      result.push_back(static_cast<UniChar>(0xd800 + (codepoint >> 10)));
      result.push_back(static_cast<UniChar>(0xdc00 + (codepoint & 0x3ff)));
    } else if (codepoint <= 0xffff) {
      result.push_back(static_cast<UniChar>(codepoint));
    }
  }
  return result;
}

static NSString* toNSString(const wstring& text) {
  const auto chars = toUTF16(text);
  return [[NSString alloc] initWithCharacters:chars.data() length:chars.size()];
}

static CTFontSymbolicTraits symbolicTraits(int style) {
  CTFontSymbolicTraits traits = 0;
  if (style & BOLD) traits |= kCTFontBoldTrait;
  if (style & ITALIC) traits |= kCTFontItalicTrait;
  return traits;
}

class FontApple final : public Font {
  string _name;
  float _size;
  int _style;
  bool _isPath;
  CTFontRef _font = nullptr;

public:
  FontApple(const string& name, int style, float size)
    : _name(name), _size(size), _style(style), _isPath(false) {
    string family = name;
    if (family.empty() || family == "SansSerif") family = "Helvetica";
    else if (family == "Serif") family = "Times New Roman";
    else if (family == "Monospaced") family = "Menlo";
    NSString* familyName = [[NSString alloc] initWithBytes:family.data()
                                                    length:family.size()
                                                  encoding:NSUTF8StringEncoding];
    CTFontRef base = CTFontCreateWithName((__bridge CFStringRef)familyName, size, nullptr);
    _font = CTFontCreateCopyWithSymbolicTraits(base, size, nullptr,
                                                symbolicTraits(style),
                                                kCTFontBoldTrait | kCTFontItalicTrait);
    if (!_font) _font = base ? (CTFontRef)CFRetain(base) : nullptr;
    if (base) CFRelease(base);
  }

  FontApple(const string& path, float size)
    : _name(path), _size(size), _style(PLAIN), _isPath(true) {
    NSURL* url = [NSURL fileURLWithFileSystemRepresentation:path.c_str()
                                              isDirectory:NO
                                            relativeToURL:nil];
    CGDataProviderRef provider = url ? CGDataProviderCreateWithURL((__bridge CFURLRef)url) : nullptr;
    CGFontRef graphicsFont = provider ? CGFontCreateWithDataProvider(provider) : nullptr;
    if (graphicsFont) _font = CTFontCreateWithGraphicsFont(graphicsFont, size, nullptr, nullptr);
    if (graphicsFont) CGFontRelease(graphicsFont);
    if (provider) CGDataProviderRelease(provider);
  }

  ~FontApple() override {
    if (_font) CFRelease(_font);
  }

  CTFontRef nativeFont() const { return _font; }
  float getSize() const override { return _size; }

  sptr<Font> deriveFont(int style) const override {
    return _isPath ? sptrOf<FontApple>(_name, _size) : sptrOf<FontApple>(_name, style, _size);
  }

  bool operator==(const Font& font) const override {
    const auto* other = dynamic_cast<const FontApple*>(&font);
    return other && _name == other->_name && _size == other->_size && _style == other->_style;
  }

  bool operator!=(const Font& font) const override { return !(*this == font); }
};

class TextLayoutApple final : public TextLayout {
  CTLineRef _line = nullptr;
  double _width = 0;
  CGFloat _ascent = 0;
  CGFloat _descent = 0;
  CGFloat _leading = 0;

public:
  TextLayoutApple(const wstring& source, const sptr<FontApple>& font) {
    NSString* text = toNSString(source);
    NSDictionary* attributes = font->nativeFont()
      ? @{(__bridge NSString*)kCTFontAttributeName: (__bridge id)font->nativeFont()}
      : @{};
    NSAttributedString* attributed = [[NSAttributedString alloc] initWithString:text attributes:attributes];
    _line = CTLineCreateWithAttributedString((__bridge CFAttributedStringRef)attributed);
    if (_line) _width = CTLineGetTypographicBounds(_line, &_ascent, &_descent, &_leading);
  }

  ~TextLayoutApple() {
    if (_line) CFRelease(_line);
  }

  void getBounds(Rect& bounds) override {
    bounds = Rect(0, -_ascent, static_cast<float>(_width), _ascent + _descent + _leading);
  }

  void draw(Graphics2D& graphics, float x, float y) override;
};

class Graphics2DApple final : public Graphics2D {
  CGContextRef _context;
  CGAffineTransform _initialTransform;
  color _color = black;
  Stroke _stroke;
  const FontApple* _font = nullptr;
  float _sx = 1;
  float _sy = 1;

  void drawGlyphs(const vector<UniChar>& chars, float x, float y) {
    if (!_font || !_font->nativeFont() || chars.empty()) return;
    vector<CGGlyph> glyphs(chars.size());
    if (!CTFontGetGlyphsForCharacters(_font->nativeFont(), chars.data(), glyphs.data(), chars.size())) return;
    vector<CGPoint> positions(chars.size(), CGPointMake(x, y));
    CGContextSaveGState(_context);
    CGContextTranslateCTM(_context, 0, 2 * y);
    CGContextScaleCTM(_context, 1, -1);
    CTFontDrawGlyphs(_font->nativeFont(), glyphs.data(), positions.data(), glyphs.size(), _context);
    CGContextRestoreGState(_context);
  }

  void addRoundedRect(float x, float y, float width, float height, float rx, float ry) {
    CGRect rect = CGRectMake(x, y, width, height);
    CGPathRef path = CGPathCreateWithRoundedRect(rect, max(0.f, rx), max(0.f, ry), nullptr);
    CGContextAddPath(_context, path);
    CGPathRelease(path);
  }

public:
  static FontApple defaultFont;

  explicit Graphics2DApple(CGContextRef context)
    : _context(CGContextRetain(context)), _initialTransform(CGContextGetCTM(context)), _font(&defaultFont) {
    setColor(BLACK);
    setStroke(Stroke());
  }

  ~Graphics2DApple() { CGContextRelease(_context); }

  CGContextRef context() const { return _context; }

  void setColor(color value) override {
    _color = value;
    CGFloat alpha = color_a(value) / 255.0;
    CGFloat red = color_r(value) / 255.0;
    CGFloat green = color_g(value) / 255.0;
    CGFloat blue = color_b(value) / 255.0;
    CGContextSetRGBFillColor(_context, red, green, blue, alpha);
    CGContextSetRGBStrokeColor(_context, red, green, blue, alpha);
  }

  color getColor() const override { return _color; }

  void setStroke(const Stroke& stroke) override {
    _stroke = stroke;
    CGContextSetLineWidth(_context, stroke.lineWidth);
    switch (stroke.cap) {
      case CAP_BUTT: CGContextSetLineCap(_context, kCGLineCapButt); break;
      case CAP_ROUND: CGContextSetLineCap(_context, kCGLineCapRound); break;
      case CAP_SQUARE: CGContextSetLineCap(_context, kCGLineCapSquare); break;
    }
    switch (stroke.join) {
      case JOIN_BEVEL: CGContextSetLineJoin(_context, kCGLineJoinBevel); break;
      case JOIN_MITER: CGContextSetLineJoin(_context, kCGLineJoinMiter); break;
      case JOIN_ROUND: CGContextSetLineJoin(_context, kCGLineJoinRound); break;
    }
    CGContextSetMiterLimit(_context, stroke.miterLimit);
  }

  const Stroke& getStroke() const override { return _stroke; }
  void setStrokeWidth(float width) override { _stroke.lineWidth = width; setStroke(_stroke); }
  const Font* getFont() const override { return _font; }
  void setFont(const Font* font) override { _font = static_cast<const FontApple*>(font); }
  void translate(float dx, float dy) override { CGContextTranslateCTM(_context, dx, dy); }

  void scale(float sx, float sy) override {
    _sx *= sx;
    _sy *= sy;
    CGContextScaleCTM(_context, sx, sy);
  }

  void rotate(float angle) override { CGContextRotateCTM(_context, angle); }

  void rotate(float angle, float px, float py) override {
    CGContextTranslateCTM(_context, px, py);
    CGContextRotateCTM(_context, angle);
    CGContextTranslateCTM(_context, -px, -py);
  }

  void reset() override {
    CGAffineTransform current = CGContextGetCTM(_context);
    CGContextConcatCTM(_context, CGAffineTransformInvert(current));
    CGContextConcatCTM(_context, _initialTransform);
    _sx = _sy = 1;
  }

  float sx() const override { return _sx; }
  float sy() const override { return _sy; }
  void drawChar(wchar_t value, float x, float y) override { drawGlyphs(toUTF16(wstring(1, value)), x, y); }
  void drawText(const wstring& text, float x, float y) override { drawGlyphs(toUTF16(text), x, y); }

  void drawLine(float x1, float y1, float x2, float y2) override {
    CGContextBeginPath(_context);
    CGContextMoveToPoint(_context, x1, y1);
    CGContextAddLineToPoint(_context, x2, y2);
    CGContextStrokePath(_context);
  }

  void drawRect(float x, float y, float width, float height) override {
    CGContextStrokeRect(_context, CGRectMake(x, y, width, height));
  }

  void fillRect(float x, float y, float width, float height) override {
    CGContextFillRect(_context, CGRectMake(x, y, width, height));
  }

  void drawRoundRect(float x, float y, float width, float height, float rx, float ry) override {
    addRoundedRect(x, y, width, height, rx, ry);
    CGContextStrokePath(_context);
  }

  void fillRoundRect(float x, float y, float width, float height, float rx, float ry) override {
    addRoundedRect(x, y, width, height, rx, ry);
    CGContextFillPath(_context);
  }
};

FontApple Graphics2DApple::defaultFont("Helvetica", PLAIN, 20.f);

void drawAppleFormula(TeXRender& render, CGContextRef context) {
  Graphics2DApple graphics(context);
  render.draw(graphics, 0, 0);
}

Font* Font::create(const string& file, float size) {
  return new FontApple(file, size);
}

sptr<Font> Font::_create(const string& name, int style, float size) {
  return sptrOf<FontApple>(name, style, size);
}

sptr<TextLayout> TextLayout::create(const wstring& source, const sptr<Font>& font) {
  return sptrOf<TextLayoutApple>(source, static_pointer_cast<FontApple>(font));
}

void TextLayoutApple::draw(Graphics2D& graphics, float x, float y) {
  auto& target = static_cast<Graphics2DApple&>(graphics);
  CGContextRef context = target.context();
  if (!_line) return;
  CGContextSaveGState(context);
  CGContextTranslateCTM(context, 0, 2 * y);
  CGContextScaleCTM(context, 1, -1);
  CGContextSetTextMatrix(context, CGAffineTransformIdentity);
  CGContextSetTextPosition(context, x, y);
  CTLineDraw(_line, context);
  CGContextRestoreGState(context);
}

}  // namespace tex

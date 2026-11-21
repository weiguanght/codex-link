#ifndef IOS_LATEX_FFI_H
#define IOS_LATEX_FFI_H
#include <stddef.h>
#include <stdint.h>
#ifdef __cplusplus
extern "C" {
#endif

typedef struct {
    float r, g, b, a;
} IOSLaTeXColor;

typedef struct {
    const uint8_t *data;
    size_t length;
} IOSLaTeXResult;

/* data stays valid until ios_latex_free(result). A null data pointer means failure.
 * style: -1 infers outer delimiters (display by default), 0 is text, 1 is display.
 * The caller owns the UTF-8 input and guarantees readability for the entire call.
 */
IOSLaTeXResult ios_latex_layout(const uint8_t *utf8, size_t length, int32_t style, IOSLaTeXColor color);
void ios_latex_free(IOSLaTeXResult result);
/* UTF-8 error message. Read on the calling thread before calling ios_latex_layout again. */
const char *ios_latex_last_error(void);
uint32_t ios_latex_has_chemistry(void);

#ifdef __cplusplus
}
#endif
#endif

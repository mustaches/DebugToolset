#ifndef UI_PORT_H
#define UI_PORT_H

#include <stdint.h>
#include <stdbool.h>

#ifdef __cplusplus
extern "C" {
#endif

/* ---------------------------------------------------------------
 * Porting layer: implement these functions for your display.
 * Colors are RGB565 (0xRRGGBB packed to 16-bit 5-6-5).
 * --------------------------------------------------------------- */

void ui_port_fill_rect(int16_t x, int16_t y, int16_t w, int16_t h,
                       uint16_t color);

/* align: 0 left, 1 center, 2 right; area_w is the available width. */
void ui_port_draw_text(int16_t x, int16_t y, const char* text,
                       uint8_t font_size, uint16_t color,
                       uint8_t align, int16_t area_w);

/* format: 0 rgb565, 1 rgb888, 2 argb8888, 3 gray8, 4 mono1.
 * scale_mode: 0 fit, 1 fill, 2 stretch. */
void ui_port_draw_image(int16_t x, int16_t y, int16_t w, int16_t h,
                        const uint8_t* data, uint16_t img_w, uint16_t img_h,
                        uint8_t format, uint8_t scale_mode);

/* Milliseconds since boot, for ui_tick timing if you prefer to let the
 * port supply time (optional; you may also track time yourself). */
uint32_t ui_port_millis(void);

#ifdef __cplusplus
}
#endif

#endif /* UI_PORT_H */

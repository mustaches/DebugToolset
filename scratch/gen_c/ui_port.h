#ifndef UI_PORT_H
#define UI_PORT_H

#include <stdint.h>
#include <stdbool.h>

#include "ui_runtime.h" /* ui_page_t for the transition hook */

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

/* Optional GPU hook: animate a page transition (slide/fade/cube...).
 * Return true when the port handles the animation; it MUST call
 * ui_set_page(to) when the animation finishes. The weak default returns
 * false and the runtime switches pages instantly. */
bool ui_port_page_transition(const ui_page_t* from, const ui_page_t* to,
                             uint8_t type);

/* Optional GPU hook: brackets drawing of a widget with a non-identity
 * transform (rotation in degrees, scale/opacity in percent). The weak
 * defaults do nothing and the widget is drawn untransformed. */
void ui_port_begin_transform(int16_t widget_id, int16_t cx, int16_t cy,
                             uint8_t rotation, uint8_t scale,
                             uint8_t opacity);
void ui_port_end_transform(int16_t widget_id);

/* Optional GPU hook: draw one frame of an animated image background
 * (anim: 1 kenburns, 2 parallax; ms = running animation clock).
 * Return true when the port drew the background; the weak default
 * returns false and the runtime draws the static image. */
bool ui_port_bg_anim_frame(const ui_page_t* page, uint8_t anim,
                           uint32_t ms);

#ifdef __cplusplus
}
#endif

#endif /* UI_PORT_H */

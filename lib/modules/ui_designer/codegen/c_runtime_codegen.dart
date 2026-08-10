/// Generates the platform-independent UI runtime (`ui_runtime.c/h`) and the
/// porting layer declaration (`ui_port.h`). The runtime is static C99 text;
/// only the project tables and callbacks vary per project.
class CRuntimeCodegen {
  CRuntimeCodegen._();

  static String runtimeHeader() => r'''
#ifndef UI_RUNTIME_H
#define UI_RUNTIME_H

#include <stdint.h>
#include <stdbool.h>

#ifdef __cplusplus
extern "C" {
#endif

#ifndef UI_RUNTIME_MAX_WIDGETS
#define UI_RUNTIME_MAX_WIDGETS 128
#endif

typedef enum {
  UI_W_LABEL = 0,
  UI_W_IMAGE,
  UI_W_BUTTON,
  UI_W_PANEL,
  UI_W_LINE,
  UI_W_PROGRESS,
  UI_W_SLIDER,
  UI_W_CHECKBOX,
  UI_W_SWITCH,
  UI_W_RADIO,
  UI_W_DROPDOWN,
  UI_W_TEXTFIELD,
  UI_W_LIST,
  UI_W_MENU,
  UI_W_VALUE_ITEM,
  UI_W_OPTION_ITEM
} ui_widget_type_t;

typedef enum {
  UI_EV_CLICK = 0,
  UI_EV_FOCUS,
  UI_EV_VALUE_CHANGE,
  UI_EV_SHOW,
  UI_EV_HIDE,
  UI_EV_TIMER
} ui_event_type_t;

typedef enum {
  UI_ACT_CALLBACK = 0,
  UI_ACT_GOTO_PAGE
} ui_action_type_t;

/* Page transition effects (ui_event_t.transition). */
enum {
  UI_TRANS_NONE = 0,
  UI_TRANS_SLIDE_LEFT,
  UI_TRANS_SLIDE_RIGHT,
  UI_TRANS_FADE,
  UI_TRANS_PUSH_LEFT,
  UI_TRANS_CUBE
};

/* Keypad / remote keys for OSD focus navigation. */
typedef enum {
  UI_KEY_UP = 0,
  UI_KEY_DOWN,
  UI_KEY_LEFT,
  UI_KEY_RIGHT,
  UI_KEY_OK
} ui_key_t;

/* All generated callbacks share this signature:
 * widget_id = index of the widget in its page (or -1 for page events),
 * value     = current widget value (0 when not applicable). */
typedef void (*ui_callback_t)(int32_t widget_id, int32_t value);

typedef struct {
  uint8_t type;            /* ui_event_type_t */
  uint8_t action;          /* ui_action_type_t */
  ui_callback_t callback;  /* used when action == UI_ACT_CALLBACK */
  const void* target_page; /* const ui_page_t*, used when action == UI_ACT_GOTO_PAGE */
  uint32_t timer_ms;       /* period, only for UI_EV_TIMER */
  uint8_t transition;      /* UI_TRANS_*, only for UI_ACT_GOTO_PAGE */
} ui_event_t;

typedef struct {
  const char* text;        /* label/button/checkbox/radio text, textfield text */
  const char* text2;       /* textfield hint / radio group / dropdown options (csv) */
  const uint8_t* image;    /* raw pixel data (image widgets only) */
  int32_t value;
  int32_t value_min;
  int32_t value_max;
  uint16_t color;          /* RGB565: accent. label=text, button=bg, panel=fill, progress=bar, slider=thumb+track accent */
  uint16_t color2;         /* RGB565: secondary. button=pressed, progress/switch/slider=track or bg */
  uint16_t border_color;   /* RGB565: panel border; doubles as button text color */
  uint16_t image_w;
  uint16_t image_h;
  uint8_t font_size;
  uint8_t align;           /* text: 0 left, 1 center, 2 right; UI_W_LIST: 0 vertical, 1 horizontal */
  uint8_t radius;          /* corner radius; line thickness for UI_W_LINE */
  uint8_t border_width;
  uint8_t flags;           /* bit0: bold, bit1: checked/on */
  uint8_t scale_mode;      /* image: 0 fit, 1 fill, 2 stretch */
  uint8_t image_format;    /* 0 rgb565, 1 rgb888, 2 argb8888, 3 gray8, 4 mono1 */
} ui_props_t;

typedef struct {
  int16_t x, y, w, h;
  uint8_t type;            /* ui_widget_type_t */
  const char* name;
  ui_props_t props;
  const ui_event_t* events;
  uint8_t event_count;
  uint8_t rotation;        /* degrees, 0 = none */
  uint8_t scale;           /* percent, 100 = none */
  uint8_t opacity;         /* percent, 100 = opaque */
} ui_widget_t;

typedef struct {
  const char* name;
  uint16_t bg_color;       /* RGB565 */
  const ui_widget_t* widgets;
  uint16_t widget_count;
  const ui_event_t* events;   /* UI_EV_SHOW / UI_EV_HIDE / UI_EV_TIMER */
  uint8_t event_count;
  uint8_t bg_type;         /* 0 color, 1 image, 2 video (OSD over stream) */
  const uint8_t* bg_image; /* raw pixel data when bg_type == 1 */
  uint16_t bg_image_w;
  uint16_t bg_image_h;
  uint8_t bg_image_format; /* same encoding as ui_props_t.image_format */
  uint8_t bg_anim;         /* 0 none, 1 kenburns, 2 parallax */
} ui_page_t;

void ui_init(const ui_page_t* start_page);
void ui_set_page(const ui_page_t* page);
const ui_page_t* ui_current_page(void);

/* Full redraw of the current page via ui_port_* primitives. */
void ui_draw(void);

/* Touch input. Returns true when a widget consumed the event. */
bool ui_touch_down(uint16_t x, uint16_t y);
bool ui_touch_up(uint16_t x, uint16_t y);
bool ui_touch_move(uint16_t x, uint16_t y);

/* Keypad/remote input: OSD focus navigation (up/down/left/right/ok). */
void ui_key(ui_key_t key);

/* Currently focused widget id, -1 when none. */
int ui_focused_widget(void);

/* Call periodically with elapsed milliseconds; drives UI_EV_TIMER. */
void ui_tick(uint32_t elapsed_ms);

/* Dynamic value access (slider position, checked state, selected index...).
 * widget_id is the index of the widget within its page. */
int32_t ui_get_widget_value(uint16_t widget_id);
void ui_set_widget_value(uint16_t widget_id, int32_t value);

#ifdef __cplusplus
}
#endif

#endif /* UI_RUNTIME_H */
''';

  static String portHeader() => r'''
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
''';

  static String runtimeSource() => r'''
#include "ui_runtime.h"
#include "ui_port.h"

#include <string.h>

#if defined(__GNUC__)
__attribute__((weak))
#endif
bool ui_port_page_transition(const ui_page_t* from, const ui_page_t* to,
                             uint8_t type) {
  (void)from;
  (void)to;
  (void)type;
  return false; /* weak default: instant page switch */
}

#if defined(__GNUC__)
__attribute__((weak))
#endif
void ui_port_begin_transform(int16_t widget_id, int16_t cx, int16_t cy,
                             uint8_t rotation, uint8_t scale,
                             uint8_t opacity) {
  (void)widget_id;
  (void)cx;
  (void)cy;
  (void)rotation;
  (void)scale;
  (void)opacity;
}

#if defined(__GNUC__)
__attribute__((weak))
#endif
void ui_port_end_transform(int16_t widget_id) {
  (void)widget_id;
}

#if defined(__GNUC__)
__attribute__((weak))
#endif
bool ui_port_bg_anim_frame(const ui_page_t* page, uint8_t anim,
                           uint32_t ms) {
  (void)page;
  (void)anim;
  (void)ms;
  return false; /* weak default: static background */
}

static const ui_page_t* s_page = 0;
static int32_t s_values[UI_RUNTIME_MAX_WIDGETS];
static int s_focused = -1;
static int s_pressed = -1;
static uint32_t s_timer_acc = 0;
static uint32_t s_anim_ms = 0;
static bool s_anim_active = false; /* page contains animated widgets */

static uint16_t widget_count(void) {
  return s_page ? s_page->widget_count : 0;
}

static void fire_event(const ui_event_t* ev, int32_t widget_id, int32_t value) {
  if (ev->action == UI_ACT_CALLBACK && ev->callback) {
    ev->callback(widget_id, value);
  } else if (ev->action == UI_ACT_GOTO_PAGE && ev->target_page) {
    const ui_page_t* to = (const ui_page_t*)ev->target_page;
    if (ev->transition != UI_TRANS_NONE &&
        ui_port_page_transition(s_page, to, ev->transition)) {
      /* The port is animating the transition; it calls ui_set_page(to). */
    } else {
      ui_set_page(to);
    }
  }
}

static void fire_widget_events(const ui_widget_t* w, uint8_t type,
                               int32_t widget_id, int32_t value) {
  uint8_t i;
  for (i = 0; i < w->event_count; i++) {
    if (w->events[i].type == type) {
      fire_event(&w->events[i], widget_id, value);
    }
  }
}

static void fire_page_events(uint8_t type) {
  uint8_t i;
  if (!s_page) return;
  for (i = 0; i < s_page->event_count; i++) {
    if (s_page->events[i].type == type) {
      fire_event(&s_page->events[i], -1, 0);
    }
  }
}

static void init_values(void) {
  uint16_t i;
  if (!s_page) return;
  for (i = 0; i < s_page->widget_count && i < UI_RUNTIME_MAX_WIDGETS; i++) {
    const ui_widget_t* w = &s_page->widgets[i];
    switch (w->type) {
      case UI_W_SLIDER:
      case UI_W_PROGRESS:
      case UI_W_DROPDOWN:
      case UI_W_LIST:
      case UI_W_MENU:
      case UI_W_VALUE_ITEM:
      case UI_W_OPTION_ITEM:
        s_values[i] = w->props.value;
        break;
      case UI_W_CHECKBOX:
      case UI_W_SWITCH:
      case UI_W_RADIO:
        s_values[i] = (w->props.flags & 0x02) ? 1 : 0;
        break;
      default:
        s_values[i] = 0;
        break;
    }
  }
}

void ui_init(const ui_page_t* start_page) {
  s_page = 0;
  s_focused = -1;
  s_pressed = -1;
  s_timer_acc = 0;
  if (start_page) {
    ui_set_page(start_page);
  }
}

void ui_set_page(const ui_page_t* page) {
  uint16_t i;
  if (s_page) {
    fire_page_events(UI_EV_HIDE);
  }
  s_page = page;
  s_focused = -1;
  s_pressed = -1;
  s_timer_acc = 0;
  s_anim_active = false;
  if (page) {
    for (i = 0; i < page->widget_count; i++) {
      if (page->widgets[i].type == UI_W_PROGRESS) {
        s_anim_active = true; /* flowing stripes need redraws on tick */
        break;
      }
    }
    if (page->bg_type == 1 && page->bg_anim != 0) {
      s_anim_active = true; /* animated background needs redraws too */
    }
  }
  init_values();
  fire_page_events(UI_EV_SHOW);
  ui_draw();
}

const ui_page_t* ui_current_page(void) {
  return s_page;
}

/* ------------------------------------------------------------------ */
/* Drawing                                                             */
/* ------------------------------------------------------------------ */

static void stroke_rect(int16_t x, int16_t y, int16_t w, int16_t h,
                        int16_t t, uint16_t color) {
  ui_port_fill_rect(x, y, w, t, color);
  ui_port_fill_rect(x, y + h - t, w, t, color);
  ui_port_fill_rect(x, y, t, h, color);
  ui_port_fill_rect(x + w - t, y, t, h, color);
}

/* Minimal signed itoa (avoids stdio on small targets). */
static void int_to_str(int32_t v, char* buf, int buf_size) {
  char tmp[12];
  int n = 0, i = 0;
  uint32_t u;
  bool neg = v < 0;
  if (buf_size < 2) return;
  u = neg ? (uint32_t)(-(v + 1)) + 1u : (uint32_t)v;
  do {
    tmp[n++] = (char)('0' + (u % 10u));
    u /= 10u;
  } while (u && n < (int)sizeof(tmp));
  if (neg && i < buf_size - 1) buf[i++] = '-';
  while (n > 0 && i < buf_size - 1) buf[i++] = tmp[--n];
  buf[i] = '\0';
}

/* Number of entries in a comma-separated list ("" -> 0). */
static int csv_count(const char* s) {
  int count = 0;
  if (!s || !*s) return 0;
  count = 1;
  while (*s) {
    if (*s == ',') count++;
    s++;
  }
  return count;
}

/* Copies the idx-th csv entry into buf (trimmed), returns false when the
 * index is out of range. */
static bool csv_item(const char* s, int idx, char* buf, int buf_size) {
  int k, n = 0;
  if (!s) return false;
  for (k = 0; k < idx; k++) {
    s = strchr(s, ',');
    if (!s) return false;
    s++;
  }
  while (*s == ' ') s++;
  while (s[n] && s[n] != ',' && n < buf_size - 1) {
    buf[n] = s[n];
    n++;
  }
  while (n > 0 && buf[n - 1] == ' ') n--;
  buf[n] = '\0';
  return true;
}

/* Visible item count and first visible index for a UI_W_LIST widget,
 * centred on sel. */
static void list_window(const ui_widget_t* w, int sel, int count,
                        int* visible, int* start) {
  int16_t step = (int16_t)(w->props.radius + w->props.border_width);
  int16_t main;
  int v, s;
  if (step <= 0) step = 1;
  main = (w->props.align == 0) ? w->h : w->w;
  v = main / step;
  if (v < 1) v = 1;
  if (v > count) v = count;
  s = sel - v / 2;
  if (s < 0) s = 0;
  if (s > count - v) s = count - v;
  if (s < 0) s = 0;
  *visible = v;
  *start = s;
}

static void draw_widget(const ui_widget_t* w, int16_t id) {
  const ui_props_t* p = &w->props;
  int32_t value = (id >= 0 && id < UI_RUNTIME_MAX_WIDGETS)
                      ? s_values[id]
                      : p->value;
  switch (w->type) {
    case UI_W_PANEL:
      ui_port_fill_rect(w->x, w->y, w->w, w->h, p->color);
      if (p->border_width > 0) {
        stroke_rect(w->x, w->y, w->w, w->h, p->border_width, p->border_color);
      }
      break;
    case UI_W_LINE: {
      int16_t t = (int16_t)(p->radius > 0 ? p->radius : 1); /* thickness stored in radius */
      if (w->w >= w->h) {
        ui_port_fill_rect(w->x, w->y + (w->h - t) / 2, w->w, t, p->color);
      } else {
        ui_port_fill_rect(w->x + (w->w - t) / 2, w->y, t, w->h, p->color);
      }
      break;
    }
    case UI_W_LABEL:
      ui_port_draw_text(w->x, w->y + (w->h - p->font_size) / 2, p->text,
                        p->font_size, p->color, p->align, w->w);
      break;
    case UI_W_BUTTON: {
      uint16_t bg = (s_pressed == id) ? p->color2 : p->color;
      ui_port_fill_rect(w->x, w->y, w->w, w->h, bg);
      ui_port_draw_text(w->x, w->y + (w->h - p->font_size) / 2, p->text,
                        p->font_size, p->border_color /* textColor */, 1, w->w);
      break;
    }
    case UI_W_IMAGE:
      if (p->image) {
        ui_port_draw_image(w->x, w->y, w->w, w->h, p->image,
                           p->image_w, p->image_h, p->image_format,
                           p->scale_mode);
      }
      break;
    case UI_W_PROGRESS: {
      /* Striped bar: color = bar, color2 = background, border_color =
         stripes; info text + percentage above the bar. */
      int32_t max = p->value_max > 0 ? p->value_max : 100;
      int16_t text_h = (int16_t)(p->font_size + 4);
      int16_t bar_y = (int16_t)(w->y + text_h);
      int16_t bar_h = (int16_t)(w->h - text_h);
      int32_t frac_w;
      int16_t yy;
      char num[12];
      char pct[16];
      if (bar_h < 2) {
        bar_y = w->y;
        bar_h = w->h;
        text_h = 0;
      }
      frac_w = (int32_t)w->w * value / max;
      if (text_h > 0) {
        int_to_str((int32_t)(value * 100 / max), num, (int)sizeof(num));
        pct[0] = '\0';
        {
          int i = 0, j = 0;
          while (num[i] && j < (int)sizeof(pct) - 2) pct[j++] = num[i++];
          pct[j++] = '%';
          pct[j] = '\0';
        }
        ui_port_draw_text(w->x, w->y, p->text, p->font_size, 0xFFFF, 0,
                          (int16_t)(w->w / 2));
        ui_port_draw_text((int16_t)(w->x + w->w / 2), w->y, pct,
                          p->font_size, 0xFFFF, 2,
                          (int16_t)(w->w / 2));
      }
      ui_port_fill_rect(w->x, bar_y, w->w, bar_h, p->color2);
      if (frac_w > 0) {
        /* 45-degree stripes: stripe color where (x + yy + off) % 12 < 6;
           off flows with the animation clock. */
        int16_t off = (int16_t)((s_anim_ms / 50u) % 12u);
        ui_port_fill_rect(w->x, bar_y, (int16_t)frac_w, bar_h, p->color);
        for (yy = 0; yy < bar_h; yy++) {
          int16_t xx;
          for (xx = (int16_t)(-yy - off); xx < frac_w; xx += 12) {
            int16_t sx = xx < 0 ? 0 : xx;
            int16_t ex = (int16_t)(xx + 6);
            if (ex > frac_w) ex = (int16_t)frac_w;
            if (ex > sx) {
              ui_port_fill_rect((int16_t)(w->x + sx),
                                (int16_t)(bar_y + yy),
                                (int16_t)(ex - sx), 1, p->border_color);
            }
          }
        }
      }
      break;
    }
    case UI_W_SLIDER: {
      int32_t min = p->value_min, max = p->value_max > min ? p->value_max : min + 1;
      int16_t cy = (int16_t)(w->y + w->h / 2);
      int16_t thumb = 12;
      int16_t tx = (int16_t)(w->x + (int32_t)(w->w - thumb) * (value - min) / (max - min));
      ui_port_fill_rect(w->x, cy - 2, w->w, 4, p->color2);
      ui_port_fill_rect(tx, cy - thumb / 2, thumb, thumb, p->color);
      break;
    }
    case UI_W_CHECKBOX: {
      int16_t box = (int16_t)(w->h > 20 ? 18 : w->h - 2);
      stroke_rect(w->x, w->y + (w->h - box) / 2, box, box, 2, p->color);
      if (value) {
        ui_port_fill_rect(w->x + 4, w->y + (w->h - box) / 2 + 4,
                          (int16_t)(box - 8), (int16_t)(box - 8), p->color);
      }
      ui_port_draw_text(w->x + box + 6, w->y + (w->h - p->font_size) / 2,
                        p->text, p->font_size, 0xFFFF, 0,
                        (int16_t)(w->w - box - 6));
      break;
    }
    case UI_W_RADIO: {
      int16_t box = (int16_t)(w->h > 20 ? 18 : w->h - 2);
      stroke_rect(w->x, w->y + (w->h - box) / 2, box, box, 2, p->color);
      if (value) {
        ui_port_fill_rect(w->x + 4, w->y + (w->h - box) / 2 + 4,
                          (int16_t)(box - 8), (int16_t)(box - 8), p->color);
      }
      ui_port_draw_text(w->x + box + 6, w->y + (w->h - p->font_size) / 2,
                        p->text, p->font_size, 0xFFFF, 0,
                        (int16_t)(w->w - box - 6));
      break;
    }
    case UI_W_SWITCH: {
      int16_t knob = (int16_t)(w->h - 4);
      ui_port_fill_rect(w->x, w->y, w->w, w->h, value ? p->color : p->color2);
      ui_port_fill_rect(value ? (int16_t)(w->x + w->w - knob - 2)
                              : (int16_t)(w->x + 2),
                        (int16_t)(w->y + 2), knob, knob, 0xFFFF);
      break;
    }
    case UI_W_DROPDOWN:
      ui_port_fill_rect(w->x, w->y, w->w, w->h, p->color2);
      stroke_rect(w->x, w->y, w->w, w->h, 1, 0x7BEF /* mid grey */);
      ui_port_draw_text(w->x + 4, w->y + (w->h - p->font_size) / 2, p->text,
                        p->font_size, p->color, 0, (int16_t)(w->w - 8));
      break;
    case UI_W_TEXTFIELD:
      ui_port_fill_rect(w->x, w->y, w->w, w->h, p->color2);
      stroke_rect(w->x, w->y, w->w, w->h, 1,
                  s_focused == id ? 0x07FF : 0x7BEF);
      ui_port_draw_text(w->x + 4, w->y + (w->h - p->font_size) / 2,
                        (p->text && p->text[0]) ? p->text : p->text2,
                        p->font_size, p->color, 0, (int16_t)(w->w - 8));
      break;
    case UI_W_LIST: {
      /* items csv in text2; value = selected index; align: 0 vertical,
         1 horizontal; radius = item extent; border_width = spacing */
      int16_t step = (int16_t)(p->radius + p->border_width);
      int count = csv_count(p->text2);
      int visible, start, slot;
      int sel = (int)value;
      if (step <= 0) step = 1;
      if (count == 0) break;
      if (sel < 0) sel = 0;
      if (sel > count - 1) sel = count - 1;
      list_window(w, sel, count, &visible, &start);
      for (slot = 0; slot < visible; slot++) {
        int idx = start + slot;
        char buf[48];
        int16_t ix, iy, iw, ih;
        if (!csv_item(p->text2, idx, buf, (int)sizeof(buf))) break;
        ix = (p->align == 0) ? w->x : (int16_t)(w->x + slot * step);
        iy = (p->align == 0) ? (int16_t)(w->y + slot * step) : w->y;
        iw = (p->align == 0) ? w->w : (int16_t)(step - p->border_width);
        ih = (p->align == 0) ? (int16_t)(step - p->border_width) : w->h;
        if (idx == sel) {
          ui_port_fill_rect(ix, iy, iw, ih, p->color2);
        }
        ui_port_draw_text(ix, (int16_t)(iy + (ih - p->font_size) / 2),
                          buf, p->font_size, p->color, 1, iw);
      }
      break;
    }
    case UI_W_MENU: {
      /* items csv in text2; value = highlight index; radius = item
         extent; flags bit2: wrap; color = text, color2 = highlight */
      int16_t step = p->radius > 0 ? p->radius : 1;
      int count = csv_count(p->text2);
      int visible, start, slot;
      int sel = (int)value;
      if (count == 0) break;
      if (sel < 0) sel = 0;
      if (sel > count - 1) sel = count - 1;
      list_window(w, sel, count, &visible, &start);
      for (slot = 0; slot < visible; slot++) {
        int idx = start + slot;
        char buf[48];
        int16_t iy = (int16_t)(w->y + slot * step);
        if (!csv_item(p->text2, idx, buf, (int)sizeof(buf))) break;
        if (idx == sel) {
          ui_port_fill_rect(w->x, iy, w->w, step, p->color2);
        }
        ui_port_draw_text((int16_t)(w->x + 8),
                          (int16_t)(iy + (step - p->font_size) / 2),
                          buf, p->font_size, p->color, 0,
                          (int16_t)(w->w - 8));
      }
      break;
    }
    case UI_W_VALUE_ITEM: {
      /* text = label; value in [value_min, value_max]; radius = step;
         color = label, color2 = value */
      char num[12];
      int_to_str(value, num, (int)sizeof(num));
      ui_port_draw_text((int16_t)(w->x + 4),
                        (int16_t)(w->y + (w->h - p->font_size) / 2),
                        p->text, p->font_size, p->color, 0,
                        (int16_t)(w->w / 2));
      ui_port_draw_text((int16_t)(w->x + w->w / 2),
                        (int16_t)(w->y + (w->h - p->font_size) / 2),
                        num, p->font_size, p->color2, 2,
                        (int16_t)(w->w / 2 - 4));
      break;
    }
    case UI_W_OPTION_ITEM: {
      /* text = label; text2 = options csv; value = selected index;
         color = label, color2 = option */
      char buf[52] = "< ";
      int len = 2;
      char item[44];
      int count = csv_count(p->text2);
      int sel = (int)value;
      if (count > 0) {
        if (sel < 0) sel = 0;
        if (sel > count - 1) sel = count - 1;
        if (csv_item(p->text2, sel, item, (int)sizeof(item))) {
          int i = 0;
          while (item[i] && len < (int)sizeof(buf) - 3) {
            buf[len++] = item[i++];
          }
        }
      }
      buf[len++] = ' ';
      buf[len++] = '>';
      buf[len] = '\0';
      ui_port_draw_text((int16_t)(w->x + 4),
                        (int16_t)(w->y + (w->h - p->font_size) / 2),
                        p->text, p->font_size, p->color, 0,
                        (int16_t)(w->w / 2));
      ui_port_draw_text((int16_t)(w->x + w->w / 2),
                        (int16_t)(w->y + (w->h - p->font_size) / 2),
                        buf, p->font_size, p->color2, 2,
                        (int16_t)(w->w / 2 - 4));
      break;
    }
    default:
      break;
  }
}

void ui_draw(void) {
  uint16_t i;
  if (!s_page) return;
#ifdef UI_SCREEN_WIDTH
  if (s_page->bg_type == 2) {
    /* Video background: leave the live stream untouched, draw OSD only. */
  } else if (s_page->bg_type == 1 && s_page->bg_image) {
    if (s_page->bg_anim != 0 &&
        ui_port_bg_anim_frame(s_page, s_page->bg_anim, s_anim_ms)) {
      /* The port drew the animated background frame. */
    } else {
      ui_port_draw_image(0, 0, UI_SCREEN_WIDTH, UI_SCREEN_HEIGHT,
                         s_page->bg_image, s_page->bg_image_w,
                         s_page->bg_image_h, s_page->bg_image_format,
                         2 /* stretch to screen */);
    }
  } else {
    ui_port_fill_rect(0, 0, UI_SCREEN_WIDTH, UI_SCREEN_HEIGHT,
                      s_page->bg_color);
  }
#else
  ui_port_fill_rect(0, 0, 320, 240, s_page->bg_color);
#endif
  for (i = 0; i < s_page->widget_count; i++) {
    const ui_widget_t* w = &s_page->widgets[i];
    uint8_t scale = w->scale;
    if (s_pressed == (int)i) {
      scale = (uint8_t)((uint16_t)scale * 92u / 100u); /* press bounce */
    }
    if (w->rotation != 0 || scale != 100 || w->opacity != 100) {
      ui_port_begin_transform((int16_t)i, (int16_t)(w->x + w->w / 2),
                              (int16_t)(w->y + w->h / 2), w->rotation,
                              scale, w->opacity);
      draw_widget(w, (int16_t)i);
      ui_port_end_transform((int16_t)i);
    } else {
      draw_widget(w, (int16_t)i);
    }
  }
  /* Focus ring for key navigation. */
  if (s_focused >= 0 && s_focused < (int)s_page->widget_count) {
    const ui_widget_t* fw = &s_page->widgets[s_focused];
    stroke_rect((int16_t)(fw->x - 1), (int16_t)(fw->y - 1),
                (int16_t)(fw->w + 2), (int16_t)(fw->h + 2), 1,
                0x07FF /* cyan */);
  }
}

/* ------------------------------------------------------------------ */
/* Touch                                                               */
/* ------------------------------------------------------------------ */

static int hit_test(uint16_t x, uint16_t y) {
  int i;
  if (!s_page) return -1;
  for (i = (int)s_page->widget_count - 1; i >= 0; i--) {
    const ui_widget_t* w = &s_page->widgets[i];
    if (x >= w->x && x < w->x + w->w && y >= w->y && y < w->y + w->h) {
      return i;
    }
  }
  return -1;
}

static void slider_set_from_x(const ui_widget_t* w, int16_t id, uint16_t x) {
  int32_t min = w->props.value_min;
  int32_t max = w->props.value_max > min ? w->props.value_max : min + 1;
  int32_t v = min + (int32_t)(x - w->x) * (max - min) / (w->w > 0 ? w->w : 1);
  if (v < min) v = min;
  if (v > max) v = max;
  ui_set_widget_value((uint16_t)id, v);
}

/* ------------------------------------------------------------------ */
/* Key navigation (OSD remote model)                                   */
/* ------------------------------------------------------------------ */

/* Purely visual widgets (line, progress) cannot take focus; matches the
 * designer rule "widget type with no events is not focusable". */
static bool key_focusable(const ui_widget_t* w) {
  return w->type != UI_W_LINE && w->type != UI_W_PROGRESS;
}

/* Built-in activation shared by touch-up and UI_KEY_OK: toggles value
 * widgets. The click event is fired by the caller. */
static void activate_builtin(const ui_widget_t* w, int id) {
  switch (w->type) {
    case UI_W_CHECKBOX:
    case UI_W_SWITCH:
      ui_set_widget_value((uint16_t)id, s_values[id] ? 0 : 1);
      break;
    case UI_W_RADIO:
      ui_set_widget_value((uint16_t)id, 1);
      break;
    case UI_W_DROPDOWN: {
      int count = csv_count(w->props.text2);
      if (count > 0) {
        ui_set_widget_value((uint16_t)id,
                            (int32_t)((s_values[id] + 1) % count));
      }
      break;
    }
    default:
      break;
  }
}

static void set_focus(int id) {
  if (id == s_focused) return;
  s_focused = id;
  if (id >= 0 && id < (int)widget_count()) {
    fire_widget_events(&s_page->widgets[id], UI_EV_FOCUS, (int32_t)id,
                       s_values[id]);
  }
}

/* Spatial nearest-neighbour focus move. dir: 0 up, 1 down, 2 left,
 * 3 right. Wraps to the opposite extreme when no candidate. */
static int focus_move(uint8_t dir) {
  int i, best = -1;
  int32_t best_score = 0;
  int32_t cx, cy;
  int n = (int)widget_count();
  if (n == 0) return -1;
  if (s_focused < 0 || s_focused >= n) {
    for (i = 0; i < n; i++) {
      if (key_focusable(&s_page->widgets[i])) return i;
    }
    return -1;
  }
  cx = s_page->widgets[s_focused].x + s_page->widgets[s_focused].w / 2;
  cy = s_page->widgets[s_focused].y + s_page->widgets[s_focused].h / 2;
  for (i = 0; i < n; i++) {
    const ui_widget_t* w;
    int32_t dx, dy, primary, perp, score;
    if (i == s_focused) continue;
    w = &s_page->widgets[i];
    if (!key_focusable(w)) continue;
    dx = w->x + w->w / 2 - cx;
    dy = w->y + w->h / 2 - cy;
    switch (dir) {
      case 0:
        if (dy >= 0) continue;
        primary = -dy;
        perp = dx < 0 ? -dx : dx;
        break;
      case 1:
        if (dy <= 0) continue;
        primary = dy;
        perp = dx < 0 ? -dx : dx;
        break;
      case 2:
        if (dx >= 0) continue;
        primary = -dx;
        perp = dy < 0 ? -dy : dy;
        break;
      default:
        if (dx <= 0) continue;
        primary = dx;
        perp = dy < 0 ? -dy : dy;
        break;
    }
    score = primary + perp * 2;
    if (best < 0 || score < best_score) {
      best_score = score;
      best = i;
    }
  }
  if (best < 0) {
    /* Wrap around: up/left -> max coordinate, down/right -> min. */
    bool want_max = (dir == 0 || dir == 2);
    for (i = 0; i < n; i++) {
      const ui_widget_t* w = &s_page->widgets[i];
      int32_t v;
      if (!key_focusable(w)) continue;
      v = (dir < 2) ? (int32_t)w->y + w->h / 2 : (int32_t)w->x + w->w / 2;
      if (best < 0 || (want_max && v > best_score) ||
          (!want_max && v < best_score)) {
        best_score = v;
        best = i;
      }
    }
  }
  return best;
}

int ui_focused_widget(void) {
  return s_focused;
}

void ui_key(ui_key_t key) {
  const ui_widget_t* w;
  if (!s_page) return;
  w = (s_focused >= 0 && s_focused < (int)widget_count())
          ? &s_page->widgets[s_focused]
          : 0;
  if (key == UI_KEY_UP || key == UI_KEY_DOWN) {
    if (w && w->type == UI_W_MENU) {
      /* Up/down move the menu highlight instead of the focus. */
      int count = csv_count(w->props.text2);
      if (count > 0) {
        int32_t next = s_values[s_focused] + (key == UI_KEY_UP ? -1 : 1);
        if (w->props.flags & 0x04) { /* wrap */
          next = ((next % count) + count) % count;
        } else {
          if (next < 0) next = 0;
          if (next > count - 1) next = count - 1;
        }
        ui_set_widget_value((uint16_t)s_focused, next);
      }
    } else {
      set_focus(focus_move(key == UI_KEY_UP ? 0 : 1));
    }
  } else if (key == UI_KEY_LEFT || key == UI_KEY_RIGHT) {
    int32_t delta = (key == UI_KEY_LEFT) ? -1 : 1;
    if (w && w->type == UI_W_VALUE_ITEM) {
      /* radius carries the step. */
      int32_t step = w->props.radius > 0 ? w->props.radius : 1;
      int32_t v = s_values[s_focused] + delta * step;
      if (v < w->props.value_min) v = w->props.value_min;
      if (v > w->props.value_max) v = w->props.value_max;
      ui_set_widget_value((uint16_t)s_focused, v);
    } else if (w && w->type == UI_W_OPTION_ITEM) {
      int count = csv_count(w->props.text2);
      if (count > 0) {
        int32_t v = ((s_values[s_focused] + delta) % count + count) % count;
        ui_set_widget_value((uint16_t)s_focused, v);
      }
    } else if (w && w->type == UI_W_SLIDER) {
      int32_t min = w->props.value_min;
      int32_t max = w->props.value_max > min ? w->props.value_max : min + 1;
      int32_t v = s_values[s_focused] + delta;
      if (v < min) v = min;
      if (v > max) v = max;
      ui_set_widget_value((uint16_t)s_focused, v);
    } else {
      set_focus(focus_move(key == UI_KEY_LEFT ? 2 : 3));
    }
  } else if (key == UI_KEY_OK) {
    if (w) {
      activate_builtin(w, s_focused);
      fire_widget_events(w, UI_EV_CLICK, s_focused, s_values[s_focused]);
    }
  }
  ui_draw();
}

bool ui_touch_down(uint16_t x, uint16_t y) {
  int id = hit_test(x, y);
  if (id < 0) return false;
  const ui_widget_t* w = &s_page->widgets[id];
  s_pressed = id;
  if (s_focused != id) {
    s_focused = id;
    fire_widget_events(w, UI_EV_FOCUS, id, s_values[id]);
  }
  if (w->type == UI_W_SLIDER) {
    slider_set_from_x(w, (int16_t)id, x);
  }
  ui_draw();
  return true;
}

bool ui_touch_move(uint16_t x, uint16_t y) {
  (void)y;
  if (s_pressed < 0 || !s_page) return false;
  const ui_widget_t* w = &s_page->widgets[s_pressed];
  if (w->type == UI_W_SLIDER) {
    slider_set_from_x(w, (int16_t)s_pressed, x);
    ui_draw();
    return true;
  }
  return false;
}

bool ui_touch_up(uint16_t x, uint16_t y) {
  if (s_pressed < 0 || !s_page) {
    s_pressed = -1;
    return false;
  }
  int id = s_pressed;
  const ui_widget_t* w = &s_page->widgets[id];
  s_pressed = -1;
  if (hit_test(x, y) != id) {
    ui_draw();
    return false;
  }
  switch (w->type) {
    case UI_W_LIST: {
      /* tap selects the item under the finger */
      int16_t step = (int16_t)(w->props.radius + w->props.border_width);
      int count = csv_count(w->props.text2);
      int visible, start, slot, idx;
      if (step <= 0 || count == 0) break;
      list_window(w, s_values[id], count, &visible, &start);
      slot = (w->props.align == 0)
                 ? (int)((int16_t)y - w->y) / step
                 : (int)((int16_t)x - w->x) / step;
      idx = start + slot;
      if (idx < 0) idx = 0;
      if (idx > count - 1) idx = count - 1;
      ui_set_widget_value((uint16_t)id, idx);
      break;
    }
    default:
      activate_builtin(w, id);
      break;
  }
  fire_widget_events(w, UI_EV_CLICK, id, s_values[id]);
  ui_draw();
  return true;
}

/* ------------------------------------------------------------------ */
/* Timer / values                                                      */
/* ------------------------------------------------------------------ */

void ui_tick(uint32_t elapsed_ms) {
  uint8_t i;
  if (!s_page) return;
  s_timer_acc += elapsed_ms;
  s_anim_ms += elapsed_ms;
  for (i = 0; i < s_page->event_count; i++) {
    const ui_event_t* ev = &s_page->events[i];
    if (ev->type == UI_EV_TIMER && ev->timer_ms > 0 &&
        s_timer_acc >= ev->timer_ms) {
      s_timer_acc = 0;
      fire_event(ev, -1, 0);
    }
  }
  if (s_anim_active) {
    ui_draw(); /* drive micro-animations (progress stripe flow) */
  }
}

int32_t ui_get_widget_value(uint16_t widget_id) {
  if (widget_id >= widget_count() || widget_id >= UI_RUNTIME_MAX_WIDGETS) {
    return 0;
  }
  return s_values[widget_id];
}

void ui_set_widget_value(uint16_t widget_id, int32_t value) {
  if (!s_page || widget_id >= s_page->widget_count ||
      widget_id >= UI_RUNTIME_MAX_WIDGETS) {
    return;
  }
  if (s_values[widget_id] != value) {
    s_values[widget_id] = value;
    fire_widget_events(&s_page->widgets[widget_id], UI_EV_VALUE_CHANGE,
                       widget_id, value);
  }
}
''';
}

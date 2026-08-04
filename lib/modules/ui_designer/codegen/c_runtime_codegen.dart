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
  UI_W_LIST
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
} ui_widget_t;

typedef struct {
  const char* name;
  uint16_t bg_color;       /* RGB565 */
  const ui_widget_t* widgets;
  uint16_t widget_count;
  const ui_event_t* events;   /* UI_EV_SHOW / UI_EV_HIDE / UI_EV_TIMER */
  uint8_t event_count;
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
''';

  static String runtimeSource() => r'''
#include "ui_runtime.h"
#include "ui_port.h"

#include <string.h>

static const ui_page_t* s_page = 0;
static int32_t s_values[UI_RUNTIME_MAX_WIDGETS];
static int s_focused = -1;
static int s_pressed = -1;
static uint32_t s_timer_acc = 0;

static uint16_t widget_count(void) {
  return s_page ? s_page->widget_count : 0;
}

static void fire_event(const ui_event_t* ev, int32_t widget_id, int32_t value) {
  if (ev->action == UI_ACT_CALLBACK && ev->callback) {
    ev->callback(widget_id, value);
  } else if (ev->action == UI_ACT_GOTO_PAGE && ev->target_page) {
    ui_set_page((const ui_page_t*)ev->target_page);
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
  if (s_page) {
    fire_page_events(UI_EV_HIDE);
  }
  s_page = page;
  s_focused = -1;
  s_pressed = -1;
  s_timer_acc = 0;
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
      int32_t max = p->value_max > 0 ? p->value_max : 100;
      int32_t frac_w = (int32_t)w->w * value / max;
      ui_port_fill_rect(w->x, w->y, w->w, w->h, p->color2);
      if (frac_w > 0) {
        ui_port_fill_rect(w->x, w->y, (int16_t)frac_w, w->h, p->color);
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
    default:
      break;
  }
}

void ui_draw(void) {
  uint16_t i;
  if (!s_page) return;
#ifdef UI_SCREEN_WIDTH
  ui_port_fill_rect(0, 0, UI_SCREEN_WIDTH, UI_SCREEN_HEIGHT, s_page->bg_color);
#else
  ui_port_fill_rect(0, 0, 320, 240, s_page->bg_color);
#endif
  for (i = 0; i < s_page->widget_count; i++) {
    draw_widget(&s_page->widgets[i], (int16_t)i);
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
    case UI_W_CHECKBOX:
    case UI_W_SWITCH:
      ui_set_widget_value((uint16_t)id, s_values[id] ? 0 : 1);
      break;
    case UI_W_RADIO:
      ui_set_widget_value((uint16_t)id, 1);
      break;
    case UI_W_DROPDOWN: {
      /* options are a csv in text2; count commas to wrap around */
      int count = 1;
      const char* s = w->props.text2;
      if (s) {
        while (*s) {
          if (*s == ',') count++;
          s++;
        }
      }
      ui_set_widget_value((uint16_t)id, (s_values[id] + 1) % count);
      break;
    }
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
  for (i = 0; i < s_page->event_count; i++) {
    const ui_event_t* ev = &s_page->events[i];
    if (ev->type == UI_EV_TIMER && ev->timer_ms > 0 &&
        s_timer_acc >= ev->timer_ms) {
      s_timer_acc = 0;
      fire_event(ev, -1, 0);
    }
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

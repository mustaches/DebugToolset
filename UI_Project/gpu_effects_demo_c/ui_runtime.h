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

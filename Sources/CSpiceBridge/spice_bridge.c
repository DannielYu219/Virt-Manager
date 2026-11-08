#include "spice_bridge.h"

#include <IOSurface/IOSurfaceRef.h>
#include <dlfcn.h>
#include <errno.h>
#include <limits.h>
#include <poll.h>
#include <unistd.h>
#include <pthread.h>
#include <stdarg.h>
#include <stdio.h>
#include <stdlib.h>
#include <string.h>

// Minimal GLib/GObject/SPICE type declarations; the real headers are not shipped with UTM.app.
typedef void *gpointer;
typedef int gint;
typedef unsigned int guint;
typedef int gboolean;
typedef unsigned long gulong;
typedef gboolean (*GSourceFunc)(gpointer);
typedef void (*GCallback)(void);
typedef void (*GClosureNotify)(gpointer, gpointer);

enum { SB_CHANNEL_MAIN = 1, SB_CHANNEL_DISPLAY = 2, SB_CHANNEL_INPUTS = 3, SB_CHANNEL_CURSOR = 4 };
enum { SB_EVENT_OPENED = 10, SB_EVENT_CLOSED = 12, SB_EVENT_ERROR_FIRST = 20 };
enum { SB_MOUSE_SERVER = 1, SB_MOUSE_CLIENT = 2 };
enum { SB_CLIPBOARD_NONE = 0, SB_CLIPBOARD_UTF8_TEXT = 1 };
enum { SB_SURFACE_16_555 = 16, SB_SURFACE_32_XRGB = 32 };
// Bound allocations independently of guest-provided dimensions and lengths.
#define SB_MAX_FRAME_BYTES ((size_t)512 * 1024 * 1024)
#define SB_MAX_CLIPBOARD_BYTES (100 * 1024 * 1024)

typedef struct { int fd; guint width, height, stride, format; gboolean y0top; } SBGlScanout;

typedef struct {
    void *glib, *gobject, *spice;
    gpointer (*main_loop_new)(gpointer, gboolean);
    void (*main_loop_run)(gpointer);
    void (*main_loop_unref)(gpointer);
    gpointer (*idle_source_new)(void);
    void (*source_set_callback)(gpointer, GSourceFunc, gpointer, void (*)(gpointer));
    void (*source_set_priority)(gpointer, gint);
    guint (*source_attach)(gpointer, gpointer);
    void (*source_unref)(gpointer);
    guint (*signal_handlers_disconnect_matched)(gpointer, guint, guint, guint, gpointer, gpointer, gpointer);
    gpointer (*main_context_default)(void);
    gulong (*signal_connect_data)(gpointer, const char *, GCallback, gpointer, GClosureNotify, int);
    void (*object_set)(gpointer, const char *, ...);
    void (*object_get)(gpointer, const char *, ...);
    gpointer (*object_ref)(gpointer);
    void (*object_unref)(gpointer);
    gpointer (*session_new)(void);
    gboolean (*session_connect)(gpointer);
    void (*session_disconnect)(gpointer);
    gboolean (*channel_connect)(gpointer);
    void (*channel_disconnect)(gpointer, int);
    void (*inputs_key_press)(gpointer, guint);
    void (*inputs_key_release)(gpointer, guint);
    void (*inputs_position)(gpointer, gint, gint, gint, gint);
    void (*inputs_motion)(gpointer, gint, gint, gint);
    void (*inputs_button_press)(gpointer, gint, gint);
    void (*inputs_button_release)(gpointer, gint, gint);
    void (*main_update_display)(gpointer, gint, gint, gint, gint, gint, gboolean);
    void (*main_update_display_enabled)(gpointer, gint, gboolean, gboolean);
    gboolean (*main_send_monitor_config)(gpointer);
    gboolean (*agent_test_capability)(gpointer, guint);
    void (*main_request_mouse_mode)(gpointer, gint);
    void (*clip_grab)(gpointer, guint, unsigned int *, int);
    void (*clip_release)(gpointer, guint);
    void (*clip_request)(gpointer, guint, guint);
    void (*clip_notify)(gpointer, guint, guint, const unsigned char *, size_t);
    const SBGlScanout *(*display_get_gl_scanout)(gpointer);
    void (*display_gl_draw_done)(gpointer);
    void (*util_set_main_context)(gpointer);
} SBAPI;

typedef struct SBChannel { gpointer object; struct SBChannel *next; } SBChannel;
typedef struct SBGLFrame SBGLFrame;

struct SBSession {
    SBAPI api;
    SBCallbacks callbacks;
    gpointer session;
    SBChannel *channels;
    pthread_mutex_t state_lock;
    unsigned references;
    int closing, closed;
    gpointer main_channel, inputs_channel, display_channel, cursor_channel;
    int agent_connected;
    pthread_mutex_t lock;
    uint8_t *frame;
    int width, height, frame_dirty;
    unsigned diagnostics;
    int gl_first_draw;
    int gl_log_geometry;
    uint8_t gl_id_bytes[sizeof(uint32_t)];
    size_t gl_id_used;
    int gl_lookup_failed;
    unsigned display_generation;
    int clipboard_requested, host_clipboard_grabbed;
    const uint8_t *source;
    int source_stride, source_width, source_height, source_format;
    unsigned gl_pending;
    char *host_text;
    int host_text_length;
    IOSurfaceRef gl_surface;
    int gl_fd;
    guint gl_width, gl_height;
    gboolean gl_y0top;
    int gl_active;
};

typedef struct { pthread_mutex_t lock; pthread_cond_t condition; int done, result; } SBCompletion;
struct SBGLFrame {
    SBSession *session;
    gpointer channel;
    IOSurfaceRef surface;
    unsigned display_generation;
};
typedef struct { SBSession *session; SBCompletion *completion; int kind; int a,b,c,d; unsigned int scancode; char *text; } SBCommand;

static SBAPI runtime_api;
static pthread_mutex_t runtime_lock = PTHREAD_MUTEX_INITIALIZER;
static pthread_cond_t runtime_condition = PTHREAD_COND_INITIALIZER;
static pthread_once_t runtime_once = PTHREAD_ONCE_INIT;
static pthread_t runtime_thread;
static gpointer runtime_context, runtime_loop;
static int runtime_loaded, runtime_started, runtime_error;
static void session_release(SBSession *s);
static void on_channel_new(gpointer session, gpointer channel, gpointer user);
static void on_channel_destroy(gpointer session, gpointer channel, gpointer user);
static void on_channel_event(gpointer channel, gint event, gpointer user);
static void on_primary_create(gpointer channel,gint format,gint width,gint height,gint stride,gint shmid,gpointer data,gpointer user);
static void on_primary_destroy(gpointer channel,gpointer user);
static void on_invalidate(gpointer channel,gint x,gint y,gint w,gint h,gpointer user);
static void on_gl_scanout_notify(gpointer channel,gpointer pspec,gpointer user);
static void on_gl_draw(gpointer channel,guint x,guint y,guint w,guint h,gpointer user);
static void on_cursor_set(gpointer channel,gint w,gint h,gint hx,gint hy,gpointer rgba,gpointer user);
static void on_cursor_hide(gpointer channel,gpointer user);
static void on_mouse_update(gpointer channel,gpointer user);
static void on_agent_update(gpointer channel,gpointer user);
static gboolean on_clipboard_grab(gpointer channel,guint selection,gpointer types,guint count,gpointer user);
static void on_clipboard_release(gpointer channel,guint selection,gpointer user);
static void on_clipboard_data(gpointer channel,guint selection,guint type,gpointer data,guint size,gpointer user);
static gboolean on_clipboard_request(gpointer channel,guint selection,guint type,gpointer user);
static void connect_signal(SBSession *s,gpointer object,const char *name,void *handler);
static void disconnect_signals(SBSession *s,gpointer object);
static void destroy_session(SBSession *s);
static gboolean run_command(gpointer data);
static void enqueue(SBCommand *c);
static void post(SBSession *s,SBCommand *command);
static int perform_sync(SBSession *s,SBCommand *command);

static void *load_symbol(void *handle,const char *name) { void *p=dlsym(handle,name); if(!p) fprintf(stderr,"spice-bridge: missing symbol %s\n",name); return p; }
#define LOAD(field,handle,name) do { *(void **)&api->field=load_symbol(handle,name); if(!api->field)return -1; } while(0)

static int load_api(SBAPI *api,const char *dir,char *error,int error_size) {
    char path[4096];
    snprintf(path,sizeof path,"%s/glib-2.0.0.framework/Versions/A/glib-2.0.0",dir); api->glib=dlopen(path,RTLD_NOW|RTLD_GLOBAL); if(!api->glib){snprintf(error,error_size,"%s",dlerror());return -1;}
    snprintf(path,sizeof path,"%s/gobject-2.0.0.framework/Versions/A/gobject-2.0.0",dir); api->gobject=dlopen(path,RTLD_NOW|RTLD_GLOBAL); if(!api->gobject){snprintf(error,error_size,"%s",dlerror());return -1;}
    snprintf(path,sizeof path,"%s/spice-client-glib-2.0.8.framework/Versions/A/spice-client-glib-2.0.8",dir); api->spice=dlopen(path,RTLD_NOW|RTLD_GLOBAL); if(!api->spice){snprintf(error,error_size,"%s",dlerror());return -1;}
    LOAD(main_loop_new,api->glib,"g_main_loop_new"); LOAD(main_loop_run,api->glib,"g_main_loop_run"); LOAD(main_loop_unref,api->glib,"g_main_loop_unref"); LOAD(idle_source_new,api->glib,"g_idle_source_new"); LOAD(source_set_callback,api->glib,"g_source_set_callback"); LOAD(source_set_priority,api->glib,"g_source_set_priority"); LOAD(source_attach,api->glib,"g_source_attach"); LOAD(source_unref,api->glib,"g_source_unref"); LOAD(main_context_default,api->glib,"g_main_context_default");
    LOAD(signal_connect_data,api->gobject,"g_signal_connect_data"); LOAD(signal_handlers_disconnect_matched,api->gobject,"g_signal_handlers_disconnect_matched"); LOAD(object_ref,api->gobject,"g_object_ref"); LOAD(object_set,api->gobject,"g_object_set"); LOAD(object_get,api->gobject,"g_object_get"); LOAD(object_unref,api->gobject,"g_object_unref");
    LOAD(session_new,api->spice,"spice_session_new"); LOAD(session_connect,api->spice,"spice_session_connect"); LOAD(session_disconnect,api->spice,"spice_session_disconnect"); LOAD(channel_connect,api->spice,"spice_channel_connect"); LOAD(channel_disconnect,api->spice,"spice_channel_disconnect"); LOAD(inputs_key_press,api->spice,"spice_inputs_channel_key_press"); LOAD(inputs_key_release,api->spice,"spice_inputs_channel_key_release"); LOAD(inputs_position,api->spice,"spice_inputs_channel_position"); LOAD(inputs_motion,api->spice,"spice_inputs_channel_motion"); LOAD(inputs_button_press,api->spice,"spice_inputs_channel_button_press"); LOAD(inputs_button_release,api->spice,"spice_inputs_channel_button_release");
    LOAD(main_update_display,api->spice,"spice_main_channel_update_display"); LOAD(main_update_display_enabled,api->spice,"spice_main_channel_update_display_enabled"); LOAD(main_send_monitor_config,api->spice,"spice_main_channel_send_monitor_config"); LOAD(main_request_mouse_mode,api->spice,"spice_main_channel_request_mouse_mode"); LOAD(clip_grab,api->spice,"spice_main_channel_clipboard_selection_grab"); LOAD(clip_release,api->spice,"spice_main_channel_clipboard_selection_release"); LOAD(clip_request,api->spice,"spice_main_channel_clipboard_selection_request"); LOAD(clip_notify,api->spice,"spice_main_channel_clipboard_selection_notify"); LOAD(display_get_gl_scanout,api->spice,"spice_display_channel_get_gl_scanout"); LOAD(display_gl_draw_done,api->spice,"spice_display_channel_gl_draw_done");
    LOAD(agent_test_capability,api->spice,"spice_main_channel_agent_test_capability");
    *(void **)&api->util_set_main_context=dlsym(api->spice,"spice_util_set_main_context"); return 0;
}
static void *loop_thread(void *arg){(void)arg;runtime_context=runtime_api.main_context_default();if(runtime_api.util_set_main_context)runtime_api.util_set_main_context(runtime_context);runtime_loop=runtime_api.main_loop_new(runtime_context,0);pthread_mutex_lock(&runtime_lock);runtime_error=runtime_loop?0:-1;runtime_started=1;pthread_cond_broadcast(&runtime_condition);pthread_mutex_unlock(&runtime_lock);if(runtime_loop)runtime_api.main_loop_run(runtime_loop);return NULL;}
static void start_runtime(void){runtime_error=pthread_create(&runtime_thread,NULL,loop_thread,NULL);if(runtime_error)runtime_started=1;else pthread_detach(runtime_thread);}
static int ensure_runtime(const char *dir,char *error,int size){pthread_mutex_lock(&runtime_lock);if(!runtime_loaded){SBAPI api={0};if(load_api(&api,dir,error,size)){if(api.spice)dlclose(api.spice);if(api.gobject)dlclose(api.gobject);if(api.glib)dlclose(api.glib);pthread_mutex_unlock(&runtime_lock);return -1;}runtime_api=api;runtime_loaded=1;}pthread_once(&runtime_once,start_runtime);while(!runtime_started)pthread_cond_wait(&runtime_condition,&runtime_lock);int result=runtime_error;pthread_mutex_unlock(&runtime_lock);if(result&&error&&size>0)snprintf(error,size,"Unable to start SPICE loop thread");return result;}
static gboolean free_session_storage(gpointer data){SBSession*s=data;pthread_mutex_destroy(&s->lock);pthread_mutex_destroy(&s->state_lock);free(s);return 0;}
static void session_release(SBSession*s){pthread_mutex_lock(&s->state_lock);int last=--s->references==0;pthread_mutex_unlock(&s->state_lock);if(last){gpointer src=runtime_api.idle_source_new();runtime_api.source_set_priority(src,0);runtime_api.source_set_callback(src,free_session_storage,s,NULL);runtime_api.source_attach(src,runtime_context);runtime_api.source_unref(src);}}
static void disconnect_signals(SBSession*s,gpointer obj){s->api.signal_handlers_disconnect_matched(obj,1u<<4,0,0,NULL,NULL,s);}
static void bridge_log(const char *format, ...) {
    va_list args;
    va_start(args, format);
    fputs("spice-bridge: ", stderr);
    vfprintf(stderr, format, args);
    fputc('\n', stderr);
    va_end(args);
}

static void log_once(SBSession *s, unsigned bit, const char *message) {
    if (s->diagnostics & bit) return;
    s->diagnostics |= bit;
    bridge_log("%s", message);
}

static void gl_release(SBSession *s) {
    if (s->gl_surface) CFRelease(s->gl_surface);
    s->gl_surface = NULL;
    // gl_fd is borrowed from SpiceGlScanout; only SPICE may close it.
    s->gl_fd = -1;
    s->gl_id_used = 0;
    s->gl_lookup_failed = 0;
}

static void gl_lookup_surface(SBSession *s, int wait) {
    if (s->gl_surface || s->gl_fd < 0 || s->gl_lookup_failed) return;
    while (s->gl_id_used < sizeof(uint32_t)) {
        struct pollfd p = { .fd = s->gl_fd, .events = POLLIN };
        int ready;
        do { ready = poll(&p, 1, wait); } while (ready < 0 && errno == EINTR);
        if (ready == 0) return;
        if (ready < 0 || (p.revents & POLLNVAL)) goto failed;
        // A writer may close immediately after sending the ID. Drain POLLIN
        // even when POLLHUP is also set; HUP does not discard buffered bytes.
        if (!(p.revents & (POLLIN | POLLHUP))) {
            if (p.revents & POLLERR) goto failed;
            return;
        }
        ssize_t n;
        do {
            n = read(s->gl_fd, s->gl_id_bytes + s->gl_id_used,
                     sizeof(uint32_t) - s->gl_id_used);
        } while (n < 0 && errno == EINTR);
        if (n < 0 && (errno == EAGAIN || errno == EWOULDBLOCK)) return;
        if (n <= 0) goto failed;
        s->gl_id_used += (size_t)n;
        wait = 0; // Never block the GLib/input thread waiting for a partial ID.
    }
    uint32_t id;
    memcpy(&id, s->gl_id_bytes, sizeof id);
    s->gl_surface = IOSurfaceLookup(id);
    if (!s->gl_surface) goto failed;
    size_t width = IOSurfaceGetWidth(s->gl_surface);
    size_t height = IOSurfaceGetHeight(s->gl_surface);
    size_t stride = IOSurfaceGetBytesPerRow(s->gl_surface);
    if (!width || !height || width > INT_MAX || height > INT_MAX ||
        width > SIZE_MAX / 4 || stride < width * 4 ||
        height > SIZE_MAX / stride ||
        IOSurfaceGetAllocSize(s->gl_surface) < height * stride ||
        IOSurfaceGetPlaneCount(s->gl_surface) != 0) {
        CFRelease(s->gl_surface);
        s->gl_surface = NULL;
        goto failed;
    }
    if (s->gl_log_geometry) {
        bridge_log("IOSurface ready id=%u size=%zux%zu stride=%zu format=%08x", id,
                   width, height, stride, IOSurfaceGetPixelFormat(s->gl_surface));
        s->gl_log_geometry = 0;
    }
    return;
failed:
    s->gl_lookup_failed = 1;
    bridge_log("GL surface lookup failed fd=%d id-bytes=%zu; retaining software fallback",
               s->gl_fd, s->gl_id_used);
}

static gboolean finish_gl_frame(gpointer data) {
    SBGLFrame *f = data;
    SBSession *s = f->session;
    if (s->gl_pending) --s->gl_pending;
    // A retained GObject can outlive its connection. Never send an ACK into
    // a closed/replaced channel; disconnect cancels its outstanding draws.
    if (!s->closed && f->channel == s->display_channel &&
        f->display_generation == s->display_generation)
        s->api.display_gl_draw_done(f->channel);
    CFRelease(f->surface);
    s->api.object_unref(f->channel);
    free(f);
    session_release(s);
    return 0;
}

void sb_gl_surface_complete(void *token) {
    SBGLFrame *f = token;
    if (!f) return;
    gpointer src = runtime_api.idle_source_new();
    runtime_api.source_set_priority(src, 0);
    runtime_api.source_set_callback(src, finish_gl_frame, f, NULL);
    runtime_api.source_attach(src, runtime_context);
    runtime_api.source_unref(src);
}

static int valid_primary(int format, int width, int height, int stride, const void *data) {
    int bpp = format == SB_SURFACE_32_XRGB ? 4 : format == SB_SURFACE_16_555 ? 2 : 0;
    if (!bpp || !data || width <= 0 || height <= 0 || stride <= 0) return 0;
    if ((size_t)width > SIZE_MAX / 4 || (size_t)width * bpp > (size_t)stride) return 0;
    size_t row = (size_t)width * 4;
    return (size_t)height <= SB_MAX_FRAME_BYTES / row &&
           (size_t)height <= SB_MAX_FRAME_BYTES / (size_t)stride;
}

// Caller holds lock. Source metadata was validated at primary-create.
static void copy_primary_rect(SBSession *s, int x, int y, int w, int h) {
    for (int row = y; row < y + h; ++row) {
        uint8_t *dst = s->frame + ((size_t)row * s->width + x) * 4;
        const uint8_t *src = s->source + (size_t)row * s->source_stride;
        if (s->source_format == SB_SURFACE_32_XRGB) {
            memcpy(dst, src + (size_t)x * 4, (size_t)w * 4);
        } else {
            for (int col = 0; col < w; ++col) {
                uint16_t pixel;
                memcpy(&pixel, src + ((size_t)x + col) * 2, sizeof pixel);
                unsigned b = pixel & 31, g = (pixel >> 5) & 31, r = (pixel >> 10) & 31;
                dst[col * 4] = (uint8_t)((b << 3) | (b >> 2));
                dst[col * 4 + 1] = (uint8_t)((g << 3) | (g >> 2));
                dst[col * 4 + 2] = (uint8_t)((r << 3) | (r >> 2));
                dst[col * 4 + 3] = 255;
            }
        }
    }
    s->frame_dirty = 1;
}

static void report_primary(SBSession *s) {
    if (s->callbacks.surface) s->callbacks.surface(s->callbacks.context, s->width, s->height);
    if (s->frame && s->callbacks.damage) s->callbacks.damage(s->callbacks.context);
}

static void on_primary_create(gpointer ch, gint fmt, gint w, gint h, gint stride,
                              gint shmid, gpointer data, gpointer user) {
    (void)ch; (void)shmid;
    SBSession *s = user;
    int valid = valid_primary(fmt, w, h, stride, data);
    uint8_t *frame = valid ? malloc((size_t)w * (size_t)h * 4) : NULL;
    bridge_log("primary create %dx%d stride=%d format=%d GL=%d accepted=%d",
               w, h, stride, fmt, s->gl_active, frame != NULL);
    pthread_mutex_lock(&s->lock);
    free(s->frame);
    s->frame = frame;
    s->source = frame ? data : NULL;
    s->source_stride = frame ? stride : 0;
    s->source_width = s->width = frame ? w : 0;
    s->source_height = s->height = frame ? h : 0;
    s->source_format = frame ? fmt : 0;
    s->frame_dirty = 0;
    if (frame) copy_primary_rect(s, 0, 0, w, h);
    pthread_mutex_unlock(&s->lock);
    // Keep a software copy during GL, but do not switch presentation modes.
    if (!s->gl_active) report_primary(s);
}

static void on_primary_destroy(gpointer ch, gpointer user) {
    (void)ch;
    SBSession *s = user;
    bridge_log("primary destroy GL=%d", s->gl_active);
    pthread_mutex_lock(&s->lock);
    s->source = NULL;
    s->source_width = s->source_height = s->source_stride = s->source_format = 0;
    free(s->frame);
    s->frame = NULL;
    s->width = s->height = s->frame_dirty = 0;
    pthread_mutex_unlock(&s->lock);
    if (!s->gl_active) report_primary(s);
}

static void on_invalidate(gpointer ch, gint x, gint y, gint w, gint h, gpointer user) {
    (void)ch;
    SBSession *s = user;
    if (w <= 0 || h <= 0) return;
    // Widen before addition: even INT_MIN/INT_MAX rectangles cannot wrap.
    int64_t left = x > 0 ? x : 0, top = y > 0 ? y : 0;
    int64_t right = (int64_t)x + w, bottom = (int64_t)y + h;
    int copied = 0;
    pthread_mutex_lock(&s->lock);
    if (right > s->width) right = s->width;
    if (bottom > s->height) bottom = s->height;
    if (s->frame && s->source && s->width == s->source_width &&
        s->height == s->source_height && left < right && top < bottom) {
        copy_primary_rect(s, (int)left, (int)top, (int)(right - left), (int)(bottom - top));
        copied = 1;
    }
    pthread_mutex_unlock(&s->lock);
    if (copied && !s->gl_active && s->callbacks.damage) s->callbacks.damage(s->callbacks.context);
}

static void on_gl_scanout_notify(gpointer ch, gpointer pspec, gpointer user) {
    (void)pspec;
    SBSession *s = user;
    const SBGlScanout *scan = s->api.display_get_gl_scanout(ch);
    int changed = !s->gl_active || !scan || s->gl_width != scan->width ||
                  s->gl_height != scan->height || s->gl_y0top != scan->y0top;
    gl_release(s);
    if (changed) s->diagnostics = 0;
    s->gl_log_geometry = changed;
    if (!scan || scan->fd < 0 || !scan->width || !scan->height ||
        scan->width > INT_MAX || scan->height > INT_MAX) {
        s->gl_active = 0;
        bridge_log("GL scanout removed; software=%dx%d", s->width, s->height);
        pthread_mutex_lock(&s->lock);
        if (s->frame && s->source) copy_primary_rect(s, 0, 0, s->width, s->height);
        pthread_mutex_unlock(&s->lock);
        report_primary(s);
        return;
    }
    s->gl_active = 1;
    s->gl_fd = scan->fd;
    s->gl_width = scan->width;
    s->gl_height = scan->height;
    s->gl_y0top = scan->y0top;
    if (changed) {
        s->gl_first_draw = 1;
        bridge_log("GL scanout fd=%d size=%ux%u stride=%u format=%08x y0top=%d pending=%u",
                   scan->fd, scan->width, scan->height, scan->stride, scan->format,
                   scan->y0top, s->gl_pending);
    }
    gl_lookup_surface(s, 0);
}

static void on_gl_draw(gpointer ch, guint x, guint y, guint w, guint h, gpointer user) {
    (void)x; (void)y; (void)w; (void)h;
    SBSession *s = user;
    gl_lookup_surface(s, 0);
    if (s->gl_active && s->gl_surface && s->callbacks.gl_surface && s->gl_pending < 2) {
        SBGLFrame *f = malloc(sizeof *f);
        if (f) {
            f->session = s;
            f->channel = s->api.object_ref(ch);
            f->surface = (IOSurfaceRef)CFRetain(s->gl_surface);
            f->display_generation = s->display_generation;
            pthread_mutex_lock(&s->state_lock);
            ++s->references;
            pthread_mutex_unlock(&s->state_lock);
            ++s->gl_pending;
            if (s->gl_first_draw) {
                bridge_log("GL first frame delivered");
                s->gl_first_draw = 0;
            }
            s->callbacks.gl_surface(s->callbacks.context, f->surface, f,
                (int)IOSurfaceGetWidth(f->surface), (int)IOSurfaceGetHeight(f->surface),
                // UTM's macOS transport exports a Metal IOSurface with top-left
                // rows even when the GL protocol flag is y0top=0. CocoaSpice also
                // maps these IOSurfaces without a GL-coordinate inversion.
                IOSurfaceGetBytesPerRow(f->surface), IOSurfaceGetPixelFormat(f->surface), 1);
            return; // Client owns exactly one completion, including rejected frames.
        }
    }
    log_once(s, 1, "GL frame skipped (surface/callback unavailable or renderer busy); acknowledging");
    s->api.display_gl_draw_done(ch);
}
static void on_cursor_set(gpointer ch,gint w,gint h,gint hx,gint hy,gpointer rgba,gpointer user){(void)ch;SBSession*s=user;if(!rgba||w<=0||h<=0||w>1024||h>1024||hx<0||hy<0||hx>=w||hy>=h)return;if(s->callbacks.cursor)s->callbacks.cursor(s->callbacks.context,w,h,hx,hy,rgba);}
static void on_cursor_hide(gpointer ch,gpointer user){(void)ch;SBSession*s=user;if(s->callbacks.cursor)s->callbacks.cursor(s->callbacks.context,0,0,0,0,NULL);}
static void on_channel_event(gpointer ch, gint event, gpointer user) {
    SBSession *s = user;
    bridge_log("display channel event=%d", event);
    if (event == SB_EVENT_OPENED) {
        if (s->callbacks.connection) s->callbacks.connection(s->callbacks.context, 1);
    } else if (event == SB_EVENT_CLOSED || event >= SB_EVENT_ERROR_FIRST) {
        ++s->display_generation;
        s->gl_active = 0;
        gl_release(s);
        on_primary_destroy(ch, s);
        if (s->callbacks.connection) s->callbacks.connection(s->callbacks.context, 0);
    }
}
static void on_mouse_update(gpointer ch,gpointer user){SBSession*s=user;gint mode=0;s->api.object_get(ch,"mouse-mode",&mode,NULL);if(mode==SB_MOUSE_SERVER)s->api.main_request_mouse_mode(ch,SB_MOUSE_CLIENT);if(s->callbacks.mouse_mode)s->callbacks.mouse_mode(s->callbacks.context,mode==SB_MOUSE_CLIENT);}
static void on_agent_update(gpointer ch, gpointer user) {
    SBSession *s = user;
    gboolean connected = 0;
    s->api.object_get(ch, "agent-connected", &connected, NULL);
    connected = !!connected;
    if (s->agent_connected != connected) bridge_log("agent connected=%d", connected);
    s->agent_connected = connected;
    if (!connected) {
        s->clipboard_requested = 0;
        s->host_clipboard_grabbed = 0;
    }
    // Also forward capability updates while connected. SPICE announces these
    // through the same signal; the client may retry its host clipboard grab.
    int clipboard_ready = connected && s->api.agent_test_capability && s->api.agent_test_capability(ch, 5);
    bridge_log("agent connected=%d clipboard-by-demand=%d", connected, clipboard_ready);
    if (s->callbacks.clipboard_status)
        s->callbacks.clipboard_status(s->callbacks.context, !connected ? 0 : clipboard_ready ? 2 : 1);
    if (s->callbacks.agent) s->callbacks.agent(s->callbacks.context, connected);
}

static gboolean on_clipboard_grab(gpointer ch, guint sel, gpointer types, guint count, gpointer user) {
    SBSession *s = user;
    if (s->closed || !s->agent_connected || ch != s->main_channel || sel != 0) return 0;
    s->clipboard_requested = 0;
    s->host_clipboard_grabbed = 0;
    if (!types || count > 256) return 0;
    const unsigned int *list = types;
    for (guint i = 0; i < count; ++i) {
        if (list[i] != SB_CLIPBOARD_UTF8_TEXT) continue;
        s->clipboard_requested = 1;
        s->api.clip_request(ch, 0, SB_CLIPBOARD_UTF8_TEXT);
        return 1; // The signal has gboolean return type, not void.
    }
    return 0;
}

static void on_clipboard_release(gpointer ch, guint sel, gpointer user) {
    SBSession *s = user;
    if (ch != s->main_channel || sel != 0) return;
    // Do not erase the macOS pasteboard when the guest merely releases ownership.
    s->clipboard_requested = 0;
}

static void on_clipboard_data(gpointer ch, guint sel, guint type, gpointer data, guint size, gpointer user) {
    SBSession *s = user;
    if (s->closed || !s->agent_connected || ch != s->main_channel || sel != 0 ||
        !s->clipboard_requested) return;
    s->clipboard_requested = 0;
    if (type != SB_CLIPBOARD_UTF8_TEXT || size > SB_MAX_CLIPBOARD_BYTES || (!data && size)) return;
    bridge_log("clipboard guest data type=%u bytes=%u", type, size);
    if (s->callbacks.clipboard_status) s->callbacks.clipboard_status(s->callbacks.context, 5);
    if (s->callbacks.clipboard_text)
        s->callbacks.clipboard_text(s->callbacks.context, data ? data : "", (int)size);
}

static gboolean on_clipboard_request(gpointer ch, guint sel, guint type, gpointer user) {
    SBSession *s = user;
    if (s->closed || !s->agent_connected || ch != s->main_channel || sel != 0) return 0;
    if (type != SB_CLIPBOARD_UTF8_TEXT || !s->host_clipboard_grabbed || !s->host_text) {
        // Complete a request we cannot satisfy instead of leaving the agent waiting.
        s->api.clip_notify(ch, 0, SB_CLIPBOARD_NONE, NULL, 0);
        return 1;
    }
    bridge_log("clipboard host text requested bytes=%d", s->host_text_length);
    if (s->callbacks.clipboard_status) s->callbacks.clipboard_status(s->callbacks.context, 4);
    s->api.clip_notify(ch, 0, type, (const unsigned char *)s->host_text, (size_t)s->host_text_length);
    return 1;
}
static void connect_signal(SBSession*s,gpointer obj,const char*name,void*handler){s->api.signal_connect_data(obj,name,(GCallback)handler,s,NULL,0);}
static void on_channel_new(gpointer session,gpointer channel,gpointer user){(void)session;SBSession*s=user;SBChannel*e=malloc(sizeof*e);if(!e){s->api.channel_disconnect(channel,0);return;}e->object=s->api.object_ref(channel);e->next=s->channels;s->channels=e;gint type=0,id=0;s->api.object_get(channel,"channel-type",&type,"channel-id",&id,NULL);switch(type){case SB_CHANNEL_MAIN:s->main_channel=channel;connect_signal(s,channel,"main-mouse-update",on_mouse_update);connect_signal(s,channel,"main-agent-update",on_agent_update);connect_signal(s,channel,"main-clipboard-selection-grab",on_clipboard_grab);connect_signal(s,channel,"main-clipboard-selection",on_clipboard_data);connect_signal(s,channel,"main-clipboard-selection-request",on_clipboard_request);connect_signal(s,channel,"main-clipboard-selection-release",on_clipboard_release);break;case SB_CHANNEL_DISPLAY:if(id!=0)return;++s->display_generation;s->display_channel=channel;connect_signal(s,channel,"display-primary-create",on_primary_create);connect_signal(s,channel,"display-primary-destroy",on_primary_destroy);connect_signal(s,channel,"display-invalidate",on_invalidate);connect_signal(s,channel,"notify::gl-scanout",on_gl_scanout_notify);connect_signal(s,channel,"gl-draw",on_gl_draw);connect_signal(s,channel,"channel-event",on_channel_event);s->api.channel_connect(channel);break;case SB_CHANNEL_INPUTS:s->inputs_channel=channel;s->api.channel_connect(channel);break;case SB_CHANNEL_CURSOR:if(id!=0)return;s->cursor_channel=channel;connect_signal(s,channel,"cursor-set",on_cursor_set);connect_signal(s,channel,"cursor-hide",on_cursor_hide);s->api.channel_connect(channel);break;default:break;}}
static void on_channel_destroy(gpointer session, gpointer ch, gpointer user) {
    (void)session;
    SBSession *s = user;
    if (ch == s->main_channel) {
        s->main_channel = NULL;
        s->agent_connected = s->clipboard_requested = s->host_clipboard_grabbed = 0;
        free(s->host_text);
        s->host_text = NULL;
        s->host_text_length = 0;
        if (s->callbacks.agent) s->callbacks.agent(s->callbacks.context, 0);
    }
    if (ch == s->inputs_channel) s->inputs_channel = NULL;
    if (ch == s->display_channel) {
        bridge_log("display channel destroyed pending=%u", s->gl_pending);
        s->display_channel = NULL;
        ++s->display_generation;
        s->gl_active = 0;
        gl_release(s);
        on_primary_destroy(ch, s);
        if (s->callbacks.connection) s->callbacks.connection(s->callbacks.context, 0);
    }
    if (ch == s->cursor_channel) s->cursor_channel = NULL;
    disconnect_signals(s, ch);
    SBChannel **p = &s->channels;
    while (*p && (*p)->object != ch) p = &(*p)->next;
    if (*p) {
        SBChannel *e = *p;
        *p = e->next;
        s->api.object_unref(e->object);
        free(e);
    }
}
static void destroy_session(SBSession*s){memset(&s->callbacks,0,sizeof s->callbacks);s->closed=1;if(s->session)disconnect_signals(s,s->session);for(SBChannel*e=s->channels;e;e=e->next)disconnect_signals(s,e->object);if(s->session)s->api.session_disconnect(s->session);while(s->channels){SBChannel*e=s->channels;s->channels=e->next;s->api.channel_disconnect(e->object,0);s->api.object_unref(e->object);free(e);}if(s->session){s->api.object_unref(s->session);s->session=NULL;}s->main_channel=s->inputs_channel=s->display_channel=s->cursor_channel=NULL;s->source=NULL;gl_release(s);s->gl_fd=-1;s->gl_active=0;pthread_mutex_lock(&s->lock);free(s->frame);s->frame=NULL;s->width=s->height=0;pthread_mutex_unlock(&s->lock);free(s->host_text);s->host_text=NULL;}
enum{CMD_CONNECT,CMD_KEY,CMD_POSITION,CMD_MOTION,CMD_BUTTON,CMD_SCROLL,CMD_RESIZE,CMD_CLIPBOARD,CMD_DISCONNECT};
static gboolean run_command(gpointer data){SBCommand*c=data;SBSession*s=c->session;SBAPI*a=&s->api;int result=0;if(s->closed)goto finished;switch(c->kind){case CMD_CONNECT:s->session=a->session_new();if(!s->session){result=-1;break;}a->object_set(s->session,"unix-path",c->text,"gl-scanout",1,"read-only",0,NULL);connect_signal(s,s->session,"channel-new",on_channel_new);connect_signal(s,s->session,"channel-destroy",on_channel_destroy);if(!a->session_connect(s->session)&&s->callbacks.connection)s->callbacks.connection(s->callbacks.context,0);break;case CMD_KEY:if(s->inputs_channel){if(c->a)a->inputs_key_press(s->inputs_channel,c->scancode);else a->inputs_key_release(s->inputs_channel,c->scancode);}break;case CMD_POSITION:if(s->inputs_channel)a->inputs_position(s->inputs_channel,c->a,c->b,0,c->c);break;case CMD_MOTION:if(s->inputs_channel)a->inputs_motion(s->inputs_channel,c->a,c->b,c->c);break;case CMD_BUTTON:if(s->inputs_channel){if(c->b)a->inputs_button_press(s->inputs_channel,c->a,c->c);else a->inputs_button_release(s->inputs_channel,c->a,c->c);}break;case CMD_SCROLL:if(s->inputs_channel){int b=c->a?4:5;a->inputs_button_press(s->inputs_channel,b,c->c);a->inputs_button_release(s->inputs_channel,b,c->c);}break;case CMD_RESIZE:if(s->main_channel&&s->agent_connected&&c->a>0&&c->b>0){a->main_update_display_enabled(s->main_channel,0,1,0);a->main_update_display(s->main_channel,0,0,0,c->a,c->b,0);a->main_send_monitor_config(s->main_channel);}break;case CMD_CLIPBOARD:free(s->host_text);s->host_text=c->text;s->host_text_length=c->a;c->text=NULL;s->clipboard_requested=0;if(s->main_channel&&s->agent_connected){if(s->host_text){unsigned int t[1]={SB_CLIPBOARD_UTF8_TEXT};s->host_clipboard_grabbed=1;a->clip_grab(s->main_channel,0,t,1);}else{if(s->host_clipboard_grabbed)a->clip_release(s->main_channel,0);s->host_clipboard_grabbed=0;}}else s->host_clipboard_grabbed=0;break;case CMD_DISCONNECT:destroy_session(s);break;}finished:free(c->text);SBCompletion*completion=c->completion;if(!completion)free(c);session_release(s);if(completion){pthread_mutex_lock(&completion->lock);completion->result=result;completion->done=1;pthread_cond_signal(&completion->condition);pthread_mutex_unlock(&completion->lock);}return 0;}
static void enqueue(SBCommand*c){gpointer src=runtime_api.idle_source_new();runtime_api.source_set_priority(src,0);runtime_api.source_set_callback(src,run_command,c,NULL);runtime_api.source_attach(src,runtime_context);runtime_api.source_unref(src);}
static void post(SBSession*s,SBCommand*t){if(!s){free(t->text);return;}SBCommand*c=malloc(sizeof*c);if(!c){free(t->text);return;}*c=*t;c->session=s;pthread_mutex_lock(&s->state_lock);if(s->closing){pthread_mutex_unlock(&s->state_lock);free(c->text);free(c);return;}++s->references;enqueue(c);pthread_mutex_unlock(&s->state_lock);}
static int perform_sync(SBSession*s,SBCommand*c){SBCompletion done={.lock=PTHREAD_MUTEX_INITIALIZER,.condition=PTHREAD_COND_INITIALIZER};c->session=s;c->completion=&done;pthread_mutex_lock(&s->state_lock);++s->references;pthread_mutex_unlock(&s->state_lock);if(pthread_equal(pthread_self(),runtime_thread))run_command(c);else enqueue(c);pthread_mutex_lock(&done.lock);while(!done.done)pthread_cond_wait(&done.condition,&done.lock);int result=done.result;pthread_mutex_unlock(&done.lock);pthread_cond_destroy(&done.condition);pthread_mutex_destroy(&done.lock);return result;}
SBSession*sb_open(const char*dir,const char*socket,SBCallbacks callbacks,char*error,int error_size){if(error&&error_size>0)error[0]=0;if(ensure_runtime(dir,error,error_size))return NULL;SBSession*s=calloc(1,sizeof*s);SBCommand c={.kind=CMD_CONNECT};if(!s)return NULL;pthread_mutex_init(&s->lock,NULL);pthread_mutex_init(&s->state_lock,NULL);s->references=1;s->callbacks=callbacks;s->api=runtime_api;s->gl_fd=-1;c.text=strdup(socket);if(!c.text){session_release(s);return NULL;}if(perform_sync(s,&c)){if(error&&error_size>0)snprintf(error,error_size,"Unable to create SPICE session");session_release(s);return NULL;}return s;}
void sb_close(SBSession*s){if(!s)return;SBCommand c={.kind=CMD_DISCONNECT};pthread_mutex_lock(&s->state_lock);s->closing=1;pthread_mutex_unlock(&s->state_lock);perform_sync(s,&c);session_release(s);}
uint8_t*sb_copy_frame(SBSession*s,int*w,int*h){uint8_t*copy=NULL;if(!s||!w||!h||pthread_mutex_trylock(&s->lock))return NULL;if(s->frame&&s->width>0&&s->height>0){size_t n=(size_t)s->width*s->height*4;copy=malloc(n);if(copy){memcpy(copy,s->frame,n);*w=s->width;*h=s->height;}}pthread_mutex_unlock(&s->lock);return copy;}
uint8_t*sb_copy_changed_frame(SBSession*s,int*w,int*h){if(!s||!w||!h||pthread_mutex_trylock(&s->lock))return NULL;uint8_t*copy=NULL;if(s->frame_dirty&&s->frame&&s->width>0&&s->height>0){size_t n=(size_t)s->width*s->height*4;copy=malloc(n);if(copy){memcpy(copy,s->frame,n);*w=s->width;*h=s->height;s->frame_dirty=0;}}pthread_mutex_unlock(&s->lock);return copy;}
void sb_free(void*p){free(p);} void sb_key(SBSession*s,uint32_t code,int down){SBCommand c={.kind=CMD_KEY,.a=down,.scancode=code};post(s,&c);} void sb_pointer_position(SBSession*s,int x,int y,int state){SBCommand c={.kind=CMD_POSITION,.a=x,.b=y,.c=state};post(s,&c);} void sb_pointer_motion(SBSession*s,int x,int y,int state){SBCommand c={.kind=CMD_MOTION,.a=x,.b=y,.c=state};post(s,&c);} void sb_button(SBSession*s,int b,int down,int state){SBCommand c={.kind=CMD_BUTTON,.a=b,.b=down,.c=state};post(s,&c);} void sb_scroll(SBSession*s,int up,int state){SBCommand c={.kind=CMD_SCROLL,.a=up,.c=state};post(s,&c);} void sb_resize(SBSession*s,int w,int h){SBCommand c={.kind=CMD_RESIZE,.a=w,.b=h};post(s,&c);} void sb_clipboard_set(SBSession *s, const char *text, int length) {
    if (length < 0 || length > SB_MAX_CLIPBOARD_BYTES || (!text && length != 0)) return;
    SBCommand c = { .kind = CMD_CLIPBOARD, .a = length };
    if (text) {
        c.text = malloc((size_t)length + 1);
        if (!c.text) return; // Allocation failure must not release a valid grab.
        memcpy(c.text, text, (size_t)length);
        c.text[length] = 0;
    }
    post(s, &c);
}

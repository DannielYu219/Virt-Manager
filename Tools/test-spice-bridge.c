// Standalone macOS regression tests; deliberately outside the SwiftPM target.
// xcrun clang -std=c11 -Wall -Wextra -Werror -g -fsanitize=address,undefined \
//   -I Sources/CSpiceBridge/include Tools/test-spice-bridge.c \
//   -framework IOSurface -framework CoreFoundation -o /tmp/test-spice-bridge
// /tmp/test-spice-bridge
// No VM, SPICE framework, GPU renderer or app build is started.
#include "../Sources/CSpiceBridge/spice_bridge.c"
#include <assert.h>
#include <fcntl.h>

static int ack_count, ref_count, unref_count, damage_count, surface_count;
static int clip_requests, clip_notifications, clip_deliveries, agent_value;
static guint notified_type;
static size_t notified_length;
static SBGlScanout scanout;
static void *tokens[16];
static size_t token_count;

typedef struct TestSource {
    GSourceFunc callback;
    gpointer data;
    struct TestSource *next;
} TestSource;
static TestSource *queue_head, *queue_tail;

static gpointer source_new(void) { return calloc(1, sizeof(TestSource)); }
static void source_callback(gpointer p, GSourceFunc callback, gpointer data, void (*destroy)(gpointer)) {
    (void)destroy;
    TestSource *source = p;
    source->callback = callback;
    source->data = data;
}
static void source_priority(gpointer p, gint priority) { (void)p; (void)priority; }
static guint source_attach(gpointer p, gpointer context) {
    (void)context;
    TestSource *source = p;
    if (queue_tail) queue_tail->next = source; else queue_head = source;
    queue_tail = source;
    return 1;
}
static void source_unref(gpointer p) { (void)p; }
static void pump(void) {
    while (queue_head) {
        TestSource *source = queue_head;
        queue_head = source->next;
        if (!queue_head) queue_tail = NULL;
        assert(source->callback(source->data) == 0);
        free(source);
    }
}
static gpointer object_ref(gpointer p) { ++ref_count; return p; }
static void object_unref(gpointer p) { assert(p); ++unref_count; }
static void draw_done(gpointer p) { assert(p); ++ack_count; }
static const SBGlScanout *get_scanout(gpointer p) { (void)p; return &scanout; }
static void damage(gpointer p) { (void)p; ++damage_count; }
static void surface(gpointer p, int w, int h) { (void)p; assert(w >= 0 && h >= 0); ++surface_count; }
static void gl_frame(gpointer context, void *image, void *token, int w, int h,
                     size_t stride, uint32_t format, int top) {
    (void)context; (void)format; (void)top;
    assert(image && token && w == 4 && h == 3 && stride >= 16);
    assert(token_count < sizeof tokens / sizeof tokens[0]);
    tokens[token_count++] = token;
}
static void clip_request(gpointer ch, guint selection, guint type) {
    assert(ch && selection == 0 && type == SB_CLIPBOARD_UTF8_TEXT);
    ++clip_requests;
}
static void clip_notify(gpointer ch, guint selection, guint type, const unsigned char *data, size_t size) {
    assert(ch && selection == 0 && (data || size == 0));
    ++clip_notifications;
    notified_type = type;
    notified_length = size;
}
static void clipboard(gpointer context, const char *text, int length) {
    (void)context;
    assert(text && length >= 0);
    ++clip_deliveries;
}
static void object_get(gpointer ch, const char *key, ...) {
    (void)ch;
    assert(!strcmp(key, "agent-connected"));
    va_list args;
    va_start(args, key);
    *va_arg(args, gboolean *) = agent_value;
    va_end(args);
}
static guint disconnect_signals_stub(gpointer p, guint a, guint b, guint c, gpointer d, gpointer e, gpointer f) {
    (void)p; (void)a; (void)b; (void)c; (void)d; (void)e; (void)f;
    return 0;
}
static void channel_disconnect_stub(gpointer p, int reason) { (void)p; (void)reason; }
static void clipboard_grab(gpointer ch, guint selection, unsigned int *types, int count) {
    assert(ch && selection == 0 && count == 1 && types[0] == SB_CLIPBOARD_UTF8_TEXT);
}
static void clipboard_release(gpointer ch, guint selection) { assert(ch && selection == 0); }

static void init_session(SBSession *s) {
    memset(s, 0, sizeof *s);
    pthread_mutex_init(&s->lock, NULL);
    pthread_mutex_init(&s->state_lock, NULL);
    s->references = 1;
    s->gl_fd = -1;
    s->main_channel = (void *)1;
    s->display_channel = (void *)2;
    s->api.object_ref = object_ref;
    s->api.object_unref = object_unref;
    s->api.object_get = object_get;
    s->api.display_gl_draw_done = draw_done;
    s->api.display_get_gl_scanout = get_scanout;
    s->api.clip_request = clip_request;
    s->api.clip_notify = clip_notify;
    s->api.clip_grab = clipboard_grab;
    s->api.clip_release = clipboard_release;
    s->api.signal_handlers_disconnect_matched = disconnect_signals_stub;
    s->api.channel_disconnect = channel_disconnect_stub;
    s->callbacks.surface = surface;
    s->callbacks.damage = damage;
    s->callbacks.gl_surface = gl_frame;
    s->callbacks.clipboard_text = clipboard;
}
static void clear_session(SBSession *s) {
    assert(s->references == 1 && s->gl_pending == 0);
    gl_release(s);
    free(s->frame);
    free(s->host_text);
    pthread_mutex_destroy(&s->lock);
    pthread_mutex_destroy(&s->state_lock);
}

static IOSurfaceRef make_surface(void) {
    CFMutableDictionaryRef properties = CFDictionaryCreateMutable(NULL, 0,
        &kCFTypeDictionaryKeyCallBacks, &kCFTypeDictionaryValueCallBacks);
    const CFStringRef keys[] = { kIOSurfaceWidth, kIOSurfaceHeight, kIOSurfaceBytesPerElement,
        kIOSurfaceBytesPerRow, kIOSurfaceAllocSize, kIOSurfacePixelFormat };
    int values[] = { 4, 3, 4, 64, 192, 0x42475241 }; // BGRA
    for (size_t i = 0; i < sizeof values / sizeof values[0]; ++i) {
        CFNumberRef n = CFNumberCreate(NULL, kCFNumberIntType, &values[i]);
        CFDictionarySetValue(properties, keys[i], n);
        CFRelease(n);
    }
    IOSurfaceRef image = IOSurfaceCreate(properties);
    CFRelease(properties);
    assert(image);
    return image;
}

static void test_primary_bounds_and_formats(void) {
    SBSession s;
    init_session(&s);
    uint8_t src[3 * 24];
    memset(src, 0x44, sizeof src);
    on_primary_create(s.display_channel, SB_SURFACE_32_XRGB, 4, 3, 24, 0, src, &s);
    assert(s.width == 4 && s.height == 3 && s.frame[47] == 0x44);
    memset(src, 0x55, sizeof src);
    on_invalidate(NULL, 2, 1, INT_MAX, INT_MAX, &s);
    assert(s.frame[0] == 0x44 && s.frame[(1 * 4 + 2) * 4] == 0x55);
    const int values[] = { INT_MIN, -100, -1, 0, 1, 3, 4, 100, INT_MAX };
    for (size_t x = 0; x < sizeof values / sizeof values[0]; ++x)
        for (size_t y = 0; y < sizeof values / sizeof values[0]; ++y)
            for (size_t w = 0; w < sizeof values / sizeof values[0]; ++w)
                for (size_t h = 0; h < sizeof values / sizeof values[0]; ++h)
                    on_invalidate(NULL, values[x], values[y], values[w], values[h], &s);
    int width, height;
    assert(!sb_copy_changed_frame(&s, NULL, &height));
    assert(!sb_copy_changed_frame(&s, &width, NULL));
    uint8_t *copy = sb_copy_changed_frame(&s, &width, &height);
    assert(copy && width == 4 && height == 3);
    free(copy);
    assert(!sb_copy_changed_frame(&s, &width, &height));
    assert(!valid_primary(32, INT_MAX, INT_MAX, INT_MAX, src));
    assert(!valid_primary(32, 4, 3, 15, src));
    assert(!valid_primary(32, 4, 3, -24, src));
    assert(!valid_primary(99, 4, 3, 24, src));
    assert(!valid_primary(32, 4, 3, 24, NULL));
    assert(!valid_primary(32, 0, 3, 24, src));
    uint16_t rgb555[] = { 0x001f, 0x03e0, 0x7c00, 0x7fff };
    on_primary_create(NULL, SB_SURFACE_16_555, 4, 1, 8, 0, rgb555, &s);
    assert(s.frame[0] == 255 && s.frame[1] == 0 && s.frame[2] == 0);
    assert(s.frame[4] == 0 && s.frame[5] == 255 && s.frame[6] == 0);
    assert(s.frame[8] == 0 && s.frame[9] == 0 && s.frame[10] == 255);
    on_primary_create(NULL, 99, 4, 3, 24, 0, src, &s);
    assert(!s.frame && !s.source);
    on_primary_destroy(NULL, &s);
    clear_session(&s);
    puts("PASS primary formats, padded rows, 6561 extreme rectangles, invalid sizes/stride/format");
}

static void test_gl_pipe_and_lifetime(void) {
    SBSession s;
    init_session(&s);
    IOSurfaceRef image = make_surface();
    uint32_t id = IOSurfaceGetID(image);
    int fd[2];
    assert(pipe(fd) == 0);
    assert(write(fd[1], &id, sizeof id) == sizeof id);
    close(fd[1]);
    struct pollfd p = { .fd = fd[0], .events = POLLIN };
    assert(poll(&p, 1, 0) == 1 && (p.revents & POLLIN) && (p.revents & POLLHUP));
    scanout = (SBGlScanout){ fd[0], 4, 3, 64, 0x42475241, 1 };
    on_gl_scanout_notify(s.display_channel, NULL, &s);
    assert(s.gl_surface && IOSurfaceGetID(s.gl_surface) == id);
    assert(fcntl(fd[0], F_GETFD) >= 0); // Borrowed descriptor remains open.
    int before = ack_count;
    on_gl_draw(s.display_channel, 0, 0, 4, 3, &s);
    assert(s.gl_pending == 1 && ack_count == before);
    sb_gl_surface_complete(tokens[--token_count]);
    assert(ack_count == before);
    pump();
    assert(s.gl_pending == 0 && ack_count == before + 1 && s.references == 1);

    // A scanout replacement must not cancel an ACK on the same live channel.
    on_gl_draw(s.display_channel, 0, 0, 4, 3, &s);
    uint8_t src[48] = {0};
    int surfaces_before = surface_count;
    on_primary_create(NULL, 32, 4, 3, 16, 0, src, &s);
    assert(surface_count == surfaces_before && s.frame);
    scanout.fd = -1;
    on_gl_scanout_notify(s.display_channel, NULL, &s);
    assert(!s.gl_active && s.frame && surface_count == surfaces_before + 1);
    sb_gl_surface_complete(tokens[--token_count]);
    pump();
    assert(ack_count == before + 2);
    close(fd[0]);

    // Partial ID must survive until a later notification/draw, without blocking.
    assert(pipe(fd) == 0);
    s.gl_fd = fd[0];
    assert(write(fd[1], &id, 2) == 2);
    gl_lookup_surface(&s, 0);
    assert(!s.gl_surface && s.gl_id_used == 2 && !s.gl_lookup_failed);
    assert(write(fd[1], ((uint8_t *)&id) + 2, 2) == 2);
    close(fd[1]);
    gl_lookup_surface(&s, 0);
    assert(s.gl_surface);
    s.gl_active = 1;
    on_gl_draw(s.display_channel, 0, 0, 4, 3, &s);
    on_gl_draw(s.display_channel, 0, 0, 4, 3, &s);
    on_gl_draw(s.display_channel, 0, 0, 4, 3, &s); // Bounded queue drops with ACK.
    assert(s.gl_pending == 2 && ack_count == before + 3);
    on_channel_destroy(NULL, s.display_channel, &s);
    assert(!s.source && !s.frame && !s.gl_surface);
    while (token_count) sb_gl_surface_complete(tokens[--token_count]);
    pump();
    assert(s.gl_pending == 0 && s.references == 1 && ack_count == before + 3);
    close(fd[0]);

    // EOF without a complete ID is terminal for this scanout, not a busy retry.
    assert(pipe(fd) == 0);
    s.gl_fd = fd[0];
    assert(write(fd[1], &id, 1) == 1);
    close(fd[1]);
    gl_lookup_surface(&s, 0);
    assert(s.gl_lookup_failed && !s.gl_surface);
    close(fd[0]);
    clear_session(&s);
    CFRelease(image);
    assert(ref_count == unref_count);
    puts("PASS POLLIN|POLLHUP, partial ID, scanout transitions, bounded draws, delayed ACK/channel teardown");
}

static void test_close_with_pending_gpu(void) {
    SBSession *s = malloc(sizeof *s);
    init_session(s);
    s->gl_surface = make_surface();
    s->gl_active = 1;
    int before = ack_count;
    on_gl_draw(s->display_channel, 0, 0, 4, 3, s);
    assert(s->references == 2);
    destroy_session(s);
    assert(s->closed && !s->gl_surface && s->references == 2);
    session_release(s); // Release caller ownership; frame is now the sole owner.
    sb_gl_surface_complete(tokens[--token_count]);
    pump(); // Also frees session storage; ASan checks deferred lifetime.
    assert(ack_count == before && ref_count == unref_count);
    puts("PASS completion after session close releases resources without ACK to dead channel");
}

static void test_clipboard(void) {
    SBSession s;
    init_session(&s);
    s.agent_connected = 1;
    unsigned int types[] = { 99, SB_CLIPBOARD_UTF8_TEXT };
    assert(!on_clipboard_grab(s.main_channel, 1, types, 2, &s));
    assert(!on_clipboard_grab(s.main_channel, 0, NULL, 2, &s));
    assert(on_clipboard_grab(s.main_channel, 0, types, 2, &s));
    assert(clip_requests == 1);
    on_clipboard_data(s.main_channel, 1, 1, "bad", 3, &s);
    assert(clip_deliveries == 0 && s.clipboard_requested);
    on_clipboard_data(s.main_channel, 0, 1, "\xe4\xb8\xad\xe6\x96\x87", 6, &s);
    assert(clip_deliveries == 1 && !s.clipboard_requested);
    on_clipboard_data(s.main_channel, 0, 1, "unsolicited", 11, &s);
    assert(clip_deliveries == 1);
    assert(on_clipboard_grab(s.main_channel, 0, types, 2, &s));
    on_clipboard_data(s.main_channel, 0, 1, NULL, UINT_MAX, &s);
    assert(clip_deliveries == 1);
    assert(on_clipboard_grab(s.main_channel, 0, types, 2, &s));
    on_clipboard_release(s.main_channel, 0, &s);
    assert(!s.clipboard_requested);
    sb_clipboard_set(&s, "", 0);
    pump();
    assert(s.host_text && s.host_text_length == 0 && s.host_clipboard_grabbed);
    assert(on_clipboard_request(s.main_channel, 0, 1, &s));
    assert(notified_type == 1 && notified_length == 0);
    assert(on_clipboard_request(s.main_channel, 0, 99, &s));
    assert(notified_type == SB_CLIPBOARD_NONE);
    int notifications = clip_notifications;
    assert(!on_clipboard_request(s.main_channel, 1, 1, &s));
    assert(clip_notifications == notifications);
    sb_clipboard_set(&s, "bad", -1);
    sb_clipboard_set(&s, NULL, 10);
    sb_clipboard_set(&s, "bad", SB_MAX_CLIPBOARD_BYTES + 1);
    assert(!queue_head && s.host_text);
    agent_value = 0;
    on_agent_update(s.main_channel, &s);
    assert(!s.agent_connected && !s.host_clipboard_grabbed && !s.clipboard_requested);
    assert(!on_clipboard_grab(s.main_channel, 0, types, 2, &s));
    on_channel_destroy(NULL, s.main_channel, &s);
    assert(!s.host_text && !s.main_channel);
    clear_session(&s);
    puts("PASS clipboard boolean callbacks, selection 0, empty/UTF-8 text, bounds, release and agent loss");
}

int main(void) {
    runtime_api.idle_source_new = source_new;
    runtime_api.source_set_callback = source_callback;
    runtime_api.source_set_priority = source_priority;
    runtime_api.source_attach = source_attach;
    runtime_api.source_unref = source_unref;
    test_primary_bounds_and_formats();
    test_gl_pipe_and_lifetime();
    test_close_with_pending_gpu();
    test_clipboard();
    assert(!queue_head && !token_count && ref_count == unref_count);
    puts("All bridge standalone tests passed (not a Windows/SPICE integration test).");
    return 0;
}

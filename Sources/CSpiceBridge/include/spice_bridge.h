#ifndef SPICE_BRIDGE_H
#define SPICE_BRIDGE_H

#include <stdint.h>
#include <stddef.h>

// Thin bridge to the spice-client-glib / GLib frameworks shipped inside UTM.app.
// The frameworks are loaded at run time (no headers or link-time dependency).
// All callbacks are invoked on the bridge's private GLib thread.

typedef struct SBSession SBSession;

typedef struct {
    void *context;
    // 1 when the display channel is open, 0 when closed or failed.
    void (*connection)(void *context, int connected);
    // Primary surface (re)created: new size. 0x0 means destroyed.
    void (*surface)(void *context, int width, int height);
    // New pixels were copied to the frame buffer.
    void (*damage)(void *context);
    // rgba == NULL hides the cursor.
    void (*cursor)(void *context, int width, int height, int hotX, int hotY, const uint8_t *rgba);
    // client != 0: absolute (tablet) pointer; 0: server mode (relative).
    void (*mouse_mode)(void *context, int client);
    // Guest announced UTF-8 text on its clipboard; the bridge fetches it and calls clipboard_text.
    void (*clipboard_text)(void *context, const char *utf8, int length);
    // Guest agent availability changed.
    void (*agent)(void *context, int connected);
    // Agent protocol capabilities and clipboard milestones; no clipboard contents.
    // 0 disconnected, 1 connected without clipboard capability, 2 clipboard ready,
    // 3 host text announced, 4 guest requested host text, 5 guest text received.
    void (*clipboard_status)(void *context, int status);
    // GL surface stays retained by the bridge until frame_token is completed.
    // Client must call sb_gl_surface_complete exactly once per token, after GPU
    // reads finish, including skipped/error frames and frames pending at close.
    // Callback dimensions/stride/format describe the actual IOSurface.
    void (*gl_surface)(void *context, void *surface, void *frame_token, int width, int height,
                       size_t bytes_per_row, uint32_t pixel_format, int y0top);
} SBCallbacks;

// Returns NULL if the frameworks cannot be loaded; error is a static or heap-free C string.
SBSession *sb_open(const char *frameworks_dir, const char *socket_path, SBCallbacks callbacks, char *error, int error_size);
// Call once; no other session operations may race with or follow sb_close.
// Outstanding GL tokens remain valid and must still be completed afterwards.
void sb_close(SBSession *session);
// Thread-safe ownership transfer; the token is invalid after this call.
void sb_gl_surface_complete(void *frame_token);

// Copies the current frame (BGRX, stride = width * 4) into a heap buffer. Caller frees with sb_free.
uint8_t *sb_copy_frame(SBSession *session, int *width, int *height);
uint8_t *sb_copy_changed_frame(SBSession *session, int *width, int *height);
void sb_free(void *pointer);

void sb_key(SBSession *session, uint32_t scancode, int down);
void sb_pointer_position(SBSession *session, int x, int y, int button_state);
void sb_pointer_motion(SBSession *session, int dx, int dy, int button_state);
void sb_button(SBSession *session, int button, int down, int button_state);
void sb_scroll(SBSession *session, int up, int button_state);
void sb_resize(SBSession *session, int width, int height);
// Announces host text on the guest clipboard (copied). NULL releases the grab.
void sb_clipboard_set(SBSession *session, const char *utf8, int length);

#endif

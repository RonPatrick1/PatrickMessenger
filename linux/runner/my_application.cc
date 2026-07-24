#include "my_application.h"

#include <flutter_linux/flutter_linux.h>
#ifdef GDK_WINDOWING_X11
#include <gdk/gdkx.h>
#endif

#include "flutter/generated_plugin_registrant.h"

struct WindowPlacement {
  gint x;
  gint y;
  gint width;
  gint height;
  gint monitor;
  gint tile_side;
  gboolean maximized;
  gboolean tiled;
  gboolean valid;
};

struct _MyApplication {
  GtkApplication parent_instance;
  char** dart_entrypoint_arguments;
  GtkWindow* window;
  WindowPlacement placement;
  guint save_timeout_id;
  guint restore_timeout_id;
  gboolean restoring_placement;
};

G_DEFINE_TYPE(MyApplication, my_application, GTK_TYPE_APPLICATION)

static gchar* window_state_path() {
  g_autofree gchar* directory =
      g_build_filename(g_get_user_config_dir(), "patrick-messenger", nullptr);
  if (g_mkdir_with_parents(directory, 0700) != 0) {
    g_warning("Failed to create window-state directory: %s", directory);
  }
  return g_build_filename(directory, "window-state.ini", nullptr);
}

static void load_window_placement(MyApplication* self) {
  g_autofree gchar* path = window_state_path();
  GKeyFile* key_file = g_key_file_new();
  g_autoptr(GError) error = nullptr;
  if (!g_key_file_load_from_file(key_file, path, G_KEY_FILE_NONE, &error)) {
    g_key_file_unref(key_file);
    return;
  }

  if (g_key_file_has_group(key_file, "window")) {
    self->placement.valid =
        g_key_file_get_boolean(key_file, "window", "valid", nullptr);
    self->placement.x =
        g_key_file_get_integer(key_file, "window", "x", nullptr);
    self->placement.y =
        g_key_file_get_integer(key_file, "window", "y", nullptr);
    self->placement.width =
        g_key_file_get_integer(key_file, "window", "width", nullptr);
    self->placement.height =
        g_key_file_get_integer(key_file, "window", "height", nullptr);
    self->placement.monitor =
        g_key_file_get_integer(key_file, "window", "monitor", nullptr);
    self->placement.tile_side =
        g_key_file_get_integer(key_file, "window", "tile-side", nullptr);
    self->placement.maximized =
        g_key_file_get_boolean(key_file, "window", "maximized", nullptr);
    self->placement.tiled =
        g_key_file_get_boolean(key_file, "window", "tiled", nullptr);
  }
  g_key_file_unref(key_file);

  if (self->placement.width < 480 || self->placement.height < 360) {
    self->placement.valid = FALSE;
  }
}

static gint monitor_index_at_point(GdkDisplay* display, gint x, gint y) {
  const gint monitor_count = gdk_display_get_n_monitors(display);
  for (gint index = 0; index < monitor_count; index++) {
    GdkRectangle geometry;
    gdk_monitor_get_geometry(gdk_display_get_monitor(display, index),
                             &geometry);
    if (x >= geometry.x && x < geometry.x + geometry.width &&
        y >= geometry.y && y < geometry.y + geometry.height) {
      return index;
    }
  }
  return -1;
}

static GdkMonitor* placement_monitor(GdkDisplay* display,
                                     const WindowPlacement* placement) {
  const gint center_x = placement->x + placement->width / 2;
  const gint center_y = placement->y + placement->height / 2;
  gint index = monitor_index_at_point(display, center_x, center_y);
  const gint monitor_count = gdk_display_get_n_monitors(display);
  if (index < 0 && placement->monitor >= 0 &&
      placement->monitor < monitor_count) {
    index = placement->monitor;
  }
  if (index >= 0) {
    return gdk_display_get_monitor(display, index);
  }
  GdkMonitor* primary = gdk_display_get_primary_monitor(display);
  if (primary != nullptr) {
    return primary;
  }
  return monitor_count > 0 ? gdk_display_get_monitor(display, 0) : nullptr;
}

static void move_window(GtkWindow* window, gint x, gint y) {
  GdkWindow* gdk_window = gtk_widget_get_window(GTK_WIDGET(window));
#ifdef GDK_WINDOWING_X11
  if (gdk_window != nullptr && GDK_IS_X11_WINDOW(gdk_window)) {
    const gint scale = gdk_window_get_scale_factor(gdk_window);
    XMoveWindow(gdk_x11_display_get_xdisplay(gdk_window_get_display(gdk_window)),
                gdk_x11_window_get_xid(gdk_window), x * scale, y * scale);
    XFlush(gdk_x11_display_get_xdisplay(gdk_window_get_display(gdk_window)));
    return;
  }
#endif
  gtk_window_move(window, x, y);
}

static void restore_window_placement(MyApplication* self, GtkWindow* window) {
  if (!self->placement.valid) {
    gtk_window_set_default_size(window, 1280, 720);
    return;
  }

  GdkDisplay* display = gtk_widget_get_display(GTK_WIDGET(window));
  GdkMonitor* monitor = placement_monitor(display, &self->placement);
  if (monitor == nullptr) {
    gtk_window_set_default_size(window, self->placement.width,
                                self->placement.height);
    move_window(window, self->placement.x, self->placement.y);
    return;
  }

  GdkRectangle workarea;
  gdk_monitor_get_workarea(monitor, &workarea);
  gint width = self->placement.width;
  gint height = self->placement.height;
  gint x = self->placement.x;
  gint y = self->placement.y;
  const gint saved_monitor = monitor_index_at_point(
      display, x + width / 2, y + height / 2);
  if (!self->placement.tiled || saved_monitor < 0) {
    width = MIN(width, workarea.width);
    height = MIN(height, workarea.height);
    x = CLAMP(x, workarea.x, workarea.x + workarea.width - width);
    y = CLAMP(y, workarea.y, workarea.y + workarea.height - height);
  }

  gtk_window_set_default_size(window, width, height);
  gtk_window_resize(window, width, height);
  move_window(window, x, y);
  if (self->placement.maximized) {
    gtk_window_maximize(window);
  }
}

static void save_window_placement(MyApplication* self) {
  if (!self->placement.valid) {
    return;
  }

  g_autofree gchar* path = window_state_path();
  GKeyFile* key_file = g_key_file_new();
  g_key_file_set_boolean(key_file, "window", "valid", TRUE);
  g_key_file_set_integer(key_file, "window", "x", self->placement.x);
  g_key_file_set_integer(key_file, "window", "y", self->placement.y);
  g_key_file_set_integer(key_file, "window", "width", self->placement.width);
  g_key_file_set_integer(key_file, "window", "height",
                         self->placement.height);
  g_key_file_set_integer(key_file, "window", "monitor",
                         self->placement.monitor);
  g_key_file_set_integer(key_file, "window", "tile-side",
                         self->placement.tile_side);
  g_key_file_set_boolean(key_file, "window", "maximized",
                         self->placement.maximized);
  g_key_file_set_boolean(key_file, "window", "tiled", self->placement.tiled);

  g_autoptr(GError) error = nullptr;
  if (!g_key_file_save_to_file(key_file, path, &error)) {
    g_warning("Failed to save window state: %s", error->message);
  }
  g_key_file_unref(key_file);
}

static gboolean save_window_timeout_cb(gpointer user_data) {
  MyApplication* self = MY_APPLICATION(user_data);
  self->save_timeout_id = 0;
  save_window_placement(self);
  return G_SOURCE_REMOVE;
}

static void schedule_window_state_save(MyApplication* self) {
  if (self->restoring_placement) {
    return;
  }
  if (self->save_timeout_id != 0) {
    g_source_remove(self->save_timeout_id);
  }
  self->save_timeout_id = g_timeout_add(350, save_window_timeout_cb, self);
}

static gboolean window_configure_event_cb(GtkWidget* widget,
                                          GdkEventConfigure*,
                                          gpointer user_data) {
  MyApplication* self = MY_APPLICATION(user_data);
  GdkWindow* gdk_window = gtk_widget_get_window(widget);
  const GdkWindowState state =
      gdk_window == nullptr ? static_cast<GdkWindowState>(0)
                            : gdk_window_get_state(gdk_window);
  if (self->restoring_placement) {
    return FALSE;
  }
  if ((state & (GDK_WINDOW_STATE_MAXIMIZED | GDK_WINDOW_STATE_FULLSCREEN)) ==
      0) {
    GdkRectangle frame;
    gdk_window_get_frame_extents(gdk_window, &frame);
    self->placement.x = frame.x;
    self->placement.y = frame.y;
    gtk_window_get_size(GTK_WINDOW(widget), &self->placement.width,
                        &self->placement.height);
    self->placement.valid = TRUE;

    GdkDisplay* display = gtk_widget_get_display(widget);
    self->placement.monitor = monitor_index_at_point(
        display, self->placement.x + self->placement.width / 2,
        self->placement.y + self->placement.height / 2);
    if (self->placement.tiled && self->placement.monitor >= 0) {
      GdkRectangle geometry;
      gdk_monitor_get_geometry(
          gdk_display_get_monitor(display, self->placement.monitor), &geometry);
      const gint center_x = self->placement.x + self->placement.width / 2;
      self->placement.tile_side =
          center_x < geometry.x + geometry.width / 2 ? -1 : 1;
    }
  }
  schedule_window_state_save(self);
  return FALSE;
}

static gboolean window_state_event_cb(GtkWidget* widget,
                                      GdkEventWindowState* event,
                                      gpointer user_data) {
  MyApplication* self = MY_APPLICATION(user_data);
  self->placement.maximized =
      (event->new_window_state & GDK_WINDOW_STATE_MAXIMIZED) != 0;
  const GdkWindowState tiled_states = static_cast<GdkWindowState>(
      GDK_WINDOW_STATE_TILED | GDK_WINDOW_STATE_TOP_TILED |
      GDK_WINDOW_STATE_RIGHT_TILED | GDK_WINDOW_STATE_BOTTOM_TILED |
      GDK_WINDOW_STATE_LEFT_TILED);
  self->placement.tiled =
      !self->placement.maximized &&
      (event->new_window_state & tiled_states) != 0;

  if (self->placement.tiled && !self->restoring_placement) {
    GdkDisplay* display = gtk_widget_get_display(widget);
    const gint center_x = self->placement.x + self->placement.width / 2;
    const gint center_y = self->placement.y + self->placement.height / 2;
    self->placement.monitor =
        monitor_index_at_point(display, center_x, center_y);
    if (self->placement.monitor >= 0) {
      GdkRectangle geometry;
      gdk_monitor_get_geometry(
          gdk_display_get_monitor(display, self->placement.monitor), &geometry);
      self->placement.tile_side =
          center_x < geometry.x + geometry.width / 2 ? -1 : 1;
    }
  }
  schedule_window_state_save(self);
  return FALSE;
}

static gboolean finish_window_restore_cb(gpointer user_data) {
  MyApplication* self = MY_APPLICATION(user_data);
  self->restore_timeout_id = 0;
  self->restoring_placement = FALSE;
  return G_SOURCE_REMOVE;
}

static gboolean window_delete_event_cb(GtkWidget*, GdkEvent*,
                                       gpointer user_data) {
  MyApplication* self = MY_APPLICATION(user_data);
  if (self->save_timeout_id != 0) {
    g_source_remove(self->save_timeout_id);
    self->save_timeout_id = 0;
  }
  save_window_placement(self);
  return FALSE;
}

// Called when first Flutter frame received.
static void first_frame_cb(MyApplication* self, FlView* view) {
  gtk_widget_show(gtk_widget_get_toplevel(GTK_WIDGET(view)));
  if (self->placement.valid && self->window != nullptr) {
    // GNOME may ignore the initial monitor position before the X11 window is
    // mapped. Repeat it immediately after the first frame is visible.
    restore_window_placement(self, self->window);
    self->restore_timeout_id =
        g_timeout_add(500, finish_window_restore_cb, self);
  }
}

// Implements GApplication::activate.
static void my_application_activate(GApplication* application) {
  MyApplication* self = MY_APPLICATION(application);
  GtkWindow* window =
      GTK_WINDOW(gtk_application_window_new(GTK_APPLICATION(application)));
  gtk_window_set_icon_name(window, APPLICATION_ID);
  self->window = window;
  g_object_add_weak_pointer(G_OBJECT(window),
                            reinterpret_cast<gpointer*>(&self->window));

  // Use a header bar when running in GNOME as this is the common style used
  // by applications and is the setup most users will be using (e.g. Ubuntu
  // desktop).
  // If running on X and not using GNOME then just use a traditional title bar
  // in case the window manager does more exotic layout, e.g. tiling.
  // If running on Wayland assume the header bar will work (may need changing
  // if future cases occur).
  gboolean use_header_bar = TRUE;
#ifdef GDK_WINDOWING_X11
  GdkScreen* screen = gtk_window_get_screen(window);
  if (GDK_IS_X11_SCREEN(screen)) {
    const gchar* wm_name = gdk_x11_screen_get_window_manager_name(screen);
    if (g_strcmp0(wm_name, "GNOME Shell") != 0) {
      use_header_bar = FALSE;
    }
  }
#endif
  if (use_header_bar) {
    GtkHeaderBar* header_bar = GTK_HEADER_BAR(gtk_header_bar_new());
    gtk_widget_show(GTK_WIDGET(header_bar));
    gtk_header_bar_set_title(header_bar, "Patrick Messenger");
    gtk_header_bar_set_show_close_button(header_bar, TRUE);
    gtk_window_set_titlebar(window, GTK_WIDGET(header_bar));
  } else {
    gtk_window_set_title(window, "Patrick Messenger");
  }

  restore_window_placement(self, window);
  g_signal_connect(window, "configure-event",
                   G_CALLBACK(window_configure_event_cb), self);
  g_signal_connect(window, "window-state-event",
                   G_CALLBACK(window_state_event_cb), self);
  g_signal_connect(window, "delete-event", G_CALLBACK(window_delete_event_cb),
                   self);

  g_autoptr(FlDartProject) project = fl_dart_project_new();
  fl_dart_project_set_dart_entrypoint_arguments(
      project, self->dart_entrypoint_arguments);

  FlView* view = fl_view_new(project);
  GdkRGBA background_color;
  // Background defaults to black, override it here if necessary, e.g. #00000000
  // for transparent.
  gdk_rgba_parse(&background_color, "#000000");
  fl_view_set_background_color(view, &background_color);
  gtk_widget_show(GTK_WIDGET(view));
  gtk_container_add(GTK_CONTAINER(window), GTK_WIDGET(view));

  // Show the window when Flutter renders.
  // Requires the view to be realized so we can start rendering.
  g_signal_connect_swapped(view, "first-frame", G_CALLBACK(first_frame_cb),
                           self);
  gtk_widget_realize(GTK_WIDGET(view));

  fl_register_plugins(FL_PLUGIN_REGISTRY(view));

  gtk_widget_grab_focus(GTK_WIDGET(view));
}

// Implements GApplication::local_command_line.
static gboolean my_application_local_command_line(GApplication* application,
                                                   gchar*** arguments,
                                                   int* exit_status) {
  MyApplication* self = MY_APPLICATION(application);
  // Strip out the first argument as it is the binary name.
  self->dart_entrypoint_arguments = g_strdupv(*arguments + 1);

  g_autoptr(GError) error = nullptr;
  if (!g_application_register(application, nullptr, &error)) {
    g_warning("Failed to register: %s", error->message);
    *exit_status = 1;
    return TRUE;
  }

  g_application_activate(application);
  *exit_status = 0;

  return TRUE;
}

// Implements GApplication::startup.
static void my_application_startup(GApplication* application) {
  G_APPLICATION_CLASS(my_application_parent_class)->startup(application);
}

// Implements GApplication::shutdown.
static void my_application_shutdown(GApplication* application) {
  MyApplication* self = MY_APPLICATION(application);
  if (self->save_timeout_id != 0) {
    g_source_remove(self->save_timeout_id);
    self->save_timeout_id = 0;
  }
  if (self->restore_timeout_id != 0) {
    g_source_remove(self->restore_timeout_id);
    self->restore_timeout_id = 0;
  }
  save_window_placement(self);

  G_APPLICATION_CLASS(my_application_parent_class)->shutdown(application);
}

// Implements GObject::dispose.
static void my_application_dispose(GObject* object) {
  MyApplication* self = MY_APPLICATION(object);
  if (self->save_timeout_id != 0) {
    g_source_remove(self->save_timeout_id);
    self->save_timeout_id = 0;
  }
  if (self->restore_timeout_id != 0) {
    g_source_remove(self->restore_timeout_id);
    self->restore_timeout_id = 0;
  }
  if (self->window != nullptr) {
    g_object_remove_weak_pointer(
        G_OBJECT(self->window),
        reinterpret_cast<gpointer*>(&self->window));
    self->window = nullptr;
  }
  g_clear_pointer(&self->dart_entrypoint_arguments, g_strfreev);
  G_OBJECT_CLASS(my_application_parent_class)->dispose(object);
}

static void my_application_class_init(MyApplicationClass* klass) {
  G_APPLICATION_CLASS(klass)->activate = my_application_activate;
  G_APPLICATION_CLASS(klass)->local_command_line =
      my_application_local_command_line;
  G_APPLICATION_CLASS(klass)->startup = my_application_startup;
  G_APPLICATION_CLASS(klass)->shutdown = my_application_shutdown;
  G_OBJECT_CLASS(klass)->dispose = my_application_dispose;
}

static void my_application_init(MyApplication* self) {
  self->window = nullptr;
  self->save_timeout_id = 0;
  self->restore_timeout_id = 0;
  self->placement.x = 0;
  self->placement.y = 0;
  self->placement.width = 1280;
  self->placement.height = 720;
  self->placement.monitor = -1;
  self->placement.tile_side = 0;
  self->placement.maximized = FALSE;
  self->placement.tiled = FALSE;
  self->placement.valid = FALSE;
  load_window_placement(self);
  self->restoring_placement = self->placement.valid;
}

MyApplication* my_application_new() {
  // Set the program name to the application ID, which helps various systems
  // like GTK and desktop environments map this running application to its
  // corresponding .desktop file. This ensures better integration by allowing
  // the application to be recognized beyond its binary name.
  g_set_prgname(APPLICATION_ID);

  return MY_APPLICATION(g_object_new(my_application_get_type(),
                                     "application-id", APPLICATION_ID, "flags",
                                     G_APPLICATION_NON_UNIQUE, nullptr));
}

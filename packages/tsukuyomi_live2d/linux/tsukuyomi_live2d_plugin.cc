#include "include/tsukuyomi_live2d/tsukuyomi_live2d_plugin.h"
#include "../src/gpu_api.h"
#include <epoxy/gl.h>
#include <algorithm>
#include <chrono>
#include <map>
#include <memory>
#include <mutex>
#include <stdexcept>
#include <vector>

namespace {
void require(bool value, const char* message) { if (!value) throw std::runtime_error(message); }
FlValue* at(FlValue* args, const char* key) {
  auto* value = fl_value_lookup_string(args, key);
  require(value != nullptr, "Missing GPU argument"); return value;
}
void put(FlValue* map, const char* key, FlValue* value) { fl_value_set_string_take(map, key, value); }
// Preserve Flutter's raster context; all Cubism state is in a private shared
// context, including FBOs/VAOs. No GL state leaks into Flutter.
struct Current {
  GdkGLContext* previous = gdk_gl_context_get_current();
  explicit Current(GdkGLContext* context) { gdk_gl_context_make_current(context); }
  ~Current() { if (previous) gdk_gl_context_make_current(previous); else gdk_gl_context_clear_current(); }
};
struct Reply { FlMethodCall* call; FlValue* value; std::string error; };
void respond(FlMethodCall* call, FlValue* value, const std::string& error = {}) {
  auto* reply = new Reply{FL_METHOD_CALL(g_object_ref(call)), value, error};
  g_idle_add_full(G_PRIORITY_DEFAULT, [](gpointer data) -> gboolean {
    auto* r = static_cast<Reply*>(data);
    if (r->error.empty()) fl_method_call_respond_success(r->call, r->value, nullptr);
    else fl_method_call_respond_error(r->call, "gpu", r->error.c_str(), nullptr, nullptr);
    return G_SOURCE_REMOVE;
  }, reply, [](gpointer data) {
    auto* r = static_cast<Reply*>(data);
    g_object_unref(r->call); if (r->value) fl_value_unref(r->value); delete r;
  });
}
struct State {
  std::mutex mutex;
  GdkGLContext* context = nullptr;
  const TsGpuApi* api = nullptr;
  void* model = nullptr;
  GLuint target = 0, color = 0;
  int width = 0, height = 0;
  std::vector<GLuint> atlases;
  FlMethodCall* pending = nullptr;
  bool closed = false;
  void finish(FlValue* value, const std::string& error = {}) {
    if (pending) { respond(pending, value, error); g_object_unref(pending); pending = nullptr; }
    else if (value) fl_value_unref(value);
  }
  ~State() {
    std::lock_guard<std::mutex> lock(mutex);
    closed = true; finish(nullptr, "Renderer disposed");
    if (context) {
      Current current(context);
      if (model) api->destroy(model);
      if (target) glDeleteFramebuffers(1, &target);
      if (color) glDeleteTextures(1, &color);
      if (!atlases.empty()) glDeleteTextures(static_cast<GLsizei>(atlases.size()), atlases.data());
    }
    if (context) g_object_unref(context);
  }
};
}
typedef struct _TsTexture { FlTextureGL parent; State* state; } TsTexture;
typedef struct _TsTextureClass { FlTextureGLClass parent; } TsTextureClass;
G_DEFINE_TYPE(TsTexture, ts_texture, fl_texture_gl_get_type())
static gboolean populate(FlTextureGL* texture, uint32_t* target, uint32_t* name,
                         uint32_t* width, uint32_t* height, GError** error) {
  auto* s = reinterpret_cast<TsTexture*>(texture)->state;
  std::lock_guard<std::mutex> lock(s->mutex);
  if (s->closed || !s->model) return FALSE;
  try {
    GLsync previous_use = s->pending ? glFenceSync(GL_SYNC_GPU_COMMANDS_COMPLETE, 0) : nullptr;
    if (previous_use) glFlush();
    Current current(s->context);
    if (previous_use) { glWaitSync(previous_use, 0, GL_TIMEOUT_IGNORED); glDeleteSync(previous_use); }
    if (s->pending) {
      FlValue* args = fl_method_call_get_args(s->pending);
      int w = static_cast<int>(fl_value_get_int(at(args, "width")));
      int h = static_cast<int>(fl_value_get_int(at(args, "height")));
      require(w > 0 && h > 0 && w <= 4096 && h <= 4096 && int64_t(w) * h <= 8000000, "Invalid output size");
      if (w != s->width || h != s->height) {
        if (!s->color) glGenTextures(1, &s->color);
        glBindTexture(GL_TEXTURE_2D, s->color);
        glTexParameteri(GL_TEXTURE_2D, GL_TEXTURE_MIN_FILTER, GL_LINEAR);
        glTexParameteri(GL_TEXTURE_2D, GL_TEXTURE_MAG_FILTER, GL_LINEAR);
        glTexParameteri(GL_TEXTURE_2D, GL_TEXTURE_WRAP_S, GL_CLAMP_TO_EDGE);
        glTexParameteri(GL_TEXTURE_2D, GL_TEXTURE_WRAP_T, GL_CLAMP_TO_EDGE);
        glTexImage2D(GL_TEXTURE_2D, 0, GL_RGBA8, w, h, 0, GL_RGBA, GL_UNSIGNED_BYTE, nullptr);
        if (!s->target) glGenFramebuffers(1, &s->target);
        glBindFramebuffer(GL_FRAMEBUFFER, s->target);
        glFramebufferTexture2D(GL_FRAMEBUFFER, GL_COLOR_ATTACHMENT0, GL_TEXTURE_2D, s->color, 0);
        require(glCheckFramebufferStatus(GL_FRAMEBUFFER) == GL_FRAMEBUFFER_COMPLETE, "Incomplete output framebuffer");
        s->width = w; s->height = h;
      }
      auto* ids = at(args, "ids"); auto* values = at(args, "values"); auto* blends = at(args, "blends");
      size_t count = fl_value_get_length(ids);
      require(count <= 1024 && count == fl_value_get_length(values) && count == fl_value_get_length(blends), "Invalid parameter batch");
      std::vector<const char*> names;
      for (size_t i = 0; i < count; ++i) names.push_back(fl_value_get_string(fl_value_get_list_value(ids, i)));
      TsGpuFrame frame{names.data(), fl_value_get_float_list(values), fl_value_get_int32_list(blends),
        static_cast<int32_t>(count), w, h, fl_value_get_float(at(args, "delta")),
        nullptr, reinterpret_cast<void*>(uintptr_t(s->target))};
      double timing[2]{};
      require(s->api->draw(s->model, &frame, timing), s->api->error());
      // The next Flutter sample occurs on this same raster thread. Complete
      // producer commands before returning a shared texture from our context.
      auto start = std::chrono::steady_clock::now();
      glFinish();
      double present = std::chrono::duration<double, std::micro>(std::chrono::steady_clock::now() - start).count();
      FlValue* result = fl_value_new_map();
      put(result, "width", fl_value_new_int(w)); put(result, "height", fl_value_new_int(h));
      put(result, "updateMicros", fl_value_new_float(timing[0]));
      put(result, "submitMicros", fl_value_new_float(timing[1]));
      put(result, "presentMicros", fl_value_new_float(present));
      s->finish(result);
    }
    if (!s->color) return FALSE;
    *target = GL_TEXTURE_2D; *name = s->color; *width = s->width; *height = s->height;
    return TRUE;
  } catch (const std::exception& e) {
    s->finish(nullptr, e.what());
    g_set_error_literal(error, g_quark_from_static_string("ts-live2d"), 1, e.what());
    return FALSE;
  }
}
static void ts_texture_finalize(GObject* object) {
  delete reinterpret_cast<TsTexture*>(object)->state;
  G_OBJECT_CLASS(ts_texture_parent_class)->finalize(object);
}
static void ts_texture_class_init(TsTextureClass* klass) {
  FL_TEXTURE_GL_CLASS(klass)->populate = populate;
  G_OBJECT_CLASS(klass)->finalize = ts_texture_finalize;
}
static void ts_texture_init(TsTexture* self) { self->state = new State; }

namespace {
struct Plugin {
  FlTextureRegistrar* registry;
  FlView* view;
  std::map<int64_t, TsTexture*> scenes;
  ~Plugin() {
    for (auto& entry : scenes) {
      { std::lock_guard<std::mutex> lock(entry.second->state->mutex);
        entry.second->state->closed = true;
        entry.second->state->finish(nullptr, "Renderer closed"); }
      fl_texture_registrar_unregister_texture(registry, FL_TEXTURE(entry.second));
      g_object_unref(entry.second);
    }
    g_object_unref(registry); g_object_unref(view);
  }
};
struct CreateWork {
  FlMethodCall* call;
  std::shared_ptr<Plugin> plugin;
  ~CreateWork() { g_object_unref(call); }
};
void handle(FlMethodChannel*, FlMethodCall* call, gpointer user_data) {
  auto plugin = *static_cast<std::shared_ptr<Plugin>*>(user_data);
  try {
    std::string method = fl_method_call_get_name(call);
    FlValue* args = fl_method_call_get_args(call);
    if (method == "create") {
      auto* texture = reinterpret_cast<TsTexture*>(g_object_new(ts_texture_get_type(), nullptr));
      auto* s = texture->state;
      try {
        s->api = reinterpret_cast<const TsGpuApi*>(fl_value_get_int(at(args, "nativeApi")));
        require(s->api && s->api->version == 1, "Native GPU ABI unavailable");
        GError* error = nullptr;
        s->context = gdk_window_create_gl_context(gtk_widget_get_window(GTK_WIDGET(plugin->view)), &error);
        if (error) { std::string message = error->message; g_error_free(error); throw std::runtime_error(message); }
        require(s->context != nullptr, "No OpenGL context");
        gdk_gl_context_set_required_version(s->context, 3, 2);
        gdk_gl_context_set_use_es(s->context, FALSE);
        if (!gdk_gl_context_realize(s->context, &error)) {
          std::string message = error ? error->message : "Cannot realize OpenGL context";
          g_clear_error(&error); throw std::runtime_error(message);
        }
        require(fl_texture_registrar_register_texture(plugin->registry, FL_TEXTURE(texture)), "Cannot register GL texture");
      } catch (...) { g_object_unref(texture); throw; }
      int64_t id = fl_texture_get_id(FL_TEXTURE(texture));
      plugin->scenes[id] = texture;
      // Decode and initialize on GLib's worker pool; platform/raster stay free.
      auto* task = g_task_new(texture, nullptr, nullptr, nullptr);
      g_task_set_task_data(task, new CreateWork{FL_METHOD_CALL(g_object_ref(call)), plugin},
          [](gpointer p) { delete static_cast<CreateWork*>(p); });
      g_task_run_in_thread(task, [](GTask* task, gpointer object, gpointer data, GCancellable*) {
        auto* t = reinterpret_cast<TsTexture*>(object);
        auto* work = static_cast<CreateWork*>(data);
        auto* state = t->state; auto* request = work->call;
        std::lock_guard<std::mutex> lock(state->mutex);
        try {
          require(!state->closed, "Renderer closed");
          Current current(state->context);
          auto* a = fl_method_call_get_args(request);
          auto* moc = at(a, "moc"); auto* physics = at(a, "physics");
          TsGpuInfo info{};
          state->model = state->api->create(fl_value_get_uint8_list(moc), static_cast<int32_t>(fl_value_get_length(moc)),
              fl_value_get_uint8_list(physics), static_cast<int32_t>(fl_value_get_length(physics)), nullptr, &info);
          require(state->model != nullptr, state->api->error());
          GLint max_size = 0; glGetIntegerv(GL_MAX_TEXTURE_SIZE, &max_size);
          int limit = static_cast<int>(std::clamp<int64_t>(fl_value_get_int(at(a, "maxTextureSize")), 1, std::min(max_size, 4096)));
          int64_t atlas_bytes = 0;
          auto* textures = at(a, "atlases");
          for (size_t i = 0; i < fl_value_get_length(textures); ++i) {
            auto* atlas_data = fl_value_get_list_value(textures, i);
            int w = static_cast<int>(fl_value_get_int(at(atlas_data, "width")));
            int h = static_cast<int>(fl_value_get_int(at(atlas_data, "height")));
            auto* rgba = at(atlas_data, "rgba");
            require(w > 0 && h > 0 && w <= limit && h <= limit &&
                fl_value_get_length(rgba) == size_t(w) * h * 4, "Invalid decoded atlas");
            const auto* pixels = fl_value_get_uint8_list(rgba);
            GLuint atlas = 0; glGenTextures(1, &atlas); state->atlases.push_back(atlas);
            glBindTexture(GL_TEXTURE_2D, atlas);
            glTexImage2D(GL_TEXTURE_2D, 0, GL_RGBA8, w, h, 0, GL_RGBA, GL_UNSIGNED_BYTE, pixels);
            glGenerateMipmap(GL_TEXTURE_2D);
            require(glGetError() == GL_NO_ERROR, "Cannot upload atlas");
            require(state->api->bind(state->model, static_cast<int32_t>(i), reinterpret_cast<void*>(uintptr_t(atlas))), state->api->error());
            for (;;) { atlas_bytes += int64_t(w) * h * 4; if (w == 1 && h == 1) break;
              w = std::max(1, w / 2); h = std::max(1, h / 2); }
          }
          glFinish();
          FlValue* value = fl_value_new_map();
          put(value, "textureId", fl_value_new_int(fl_texture_get_id(FL_TEXTURE(t))));
          put(value, "meshCount", fl_value_new_int(info.mesh_count));
          FlValue* bounds = fl_value_new_list();
          for (double bound : info.bounds) fl_value_append_take(bounds, fl_value_new_float(bound));
          put(value, "bounds", bounds); put(value, "maxSize", fl_value_new_int(std::min(max_size, 4096)));
          put(value, "atlasBytes", fl_value_new_int(atlas_bytes)); put(value, "backend", fl_value_new_string("OpenGL"));
          respond(request, value);
        } catch (const std::exception& e) {
          respond(request, nullptr, e.what());
          auto* cleanup = new std::pair<std::shared_ptr<Plugin>, int64_t>(
              work->plugin, fl_texture_get_id(FL_TEXTURE(t)));
          g_idle_add_full(G_PRIORITY_DEFAULT, [](gpointer p) -> gboolean {
            auto* job = static_cast<std::pair<std::shared_ptr<Plugin>, int64_t>*>(p);
            auto it = job->first->scenes.find(job->second);
            if (it != job->first->scenes.end()) {
              fl_texture_registrar_unregister_texture(job->first->registry, FL_TEXTURE(it->second));
              g_object_unref(it->second); job->first->scenes.erase(it);
            }
            return G_SOURCE_REMOVE;
          }, cleanup, [](gpointer p) { delete static_cast<std::pair<std::shared_ptr<Plugin>, int64_t>*>(p); });
        }
        g_task_return_boolean(task, TRUE);
      });
      g_object_unref(task);
      return;
    }
    auto found = plugin->scenes.find(fl_value_get_int(at(args, "id")));
    require(found != plugin->scenes.end(), "Unknown renderer");
    auto* texture = found->second; auto* s = texture->state;
    if (method == "dispose") {
      { std::lock_guard<std::mutex> lock(s->mutex); s->closed = true; s->finish(nullptr, "Renderer disposed"); }
      fl_texture_registrar_unregister_texture(plugin->registry, FL_TEXTURE(texture));
      plugin->scenes.erase(found); g_object_unref(texture); respond(call, nullptr); return;
    }
    std::lock_guard<std::mutex> lock(s->mutex);
    require(s->model && !s->closed, "Renderer unavailable");
    if (method == "frame") {
      require(s->pending == nullptr, "Frame already pending");
      s->pending = FL_METHOD_CALL(g_object_ref(call));
      fl_texture_registrar_mark_texture_frame_available(plugin->registry, FL_TEXTURE(texture));
      // A hidden window may never populate a texture. Release Dart backpressure
      // without rendering or advancing physics until the scene is visible.
      auto* pending = new std::pair<TsTexture*, FlMethodCall*>(
          reinterpret_cast<TsTexture*>(g_object_ref(texture)), FL_METHOD_CALL(g_object_ref(call)));
      g_timeout_add_full(G_PRIORITY_DEFAULT, 500, [](gpointer data) -> gboolean {
        auto* pending = static_cast<std::pair<TsTexture*, FlMethodCall*>*>(data);
        auto* state = pending->first->state; std::lock_guard<std::mutex> lock(state->mutex);
        if (state->pending == pending->second) {
          auto* value = fl_value_new_map(); put(value, "paused", fl_value_new_bool(true)); state->finish(value);
        }
        return G_SOURCE_REMOVE;
      }, pending, [](gpointer data) {
        auto* pending = static_cast<std::pair<TsTexture*, FlMethodCall*>*>(data);
        g_object_unref(pending->first); g_object_unref(pending->second); delete pending;
      });
    } else if (method == "snapshot") {
      require(s->color != 0, "No completed frame");
      Current current(s->context);
      glBindFramebuffer(GL_FRAMEBUFFER, s->target);
      std::vector<uint8_t> pixels(size_t(s->width) * s->height * 4), bottom_up(pixels.size());
      glReadPixels(0, 0, s->width, s->height, GL_RGBA, GL_UNSIGNED_BYTE, pixels);
      require(glGetError() == GL_NO_ERROR, "QA readback failed");
      for (int y = 0; y < s->height; ++y) std::copy_n(pixels.data() + size_t(y) * s->width * 4,
          s->width * 4, bottom_up.data() + size_t(s->height - 1 - y) * s->width * 4);
      respond(call, fl_value_new_uint8_list(bottom_up.data(), bottom_up.size()));
    } else { fl_method_call_respond_not_implemented(call, nullptr); }
  } catch (const std::exception& e) { respond(call, nullptr, e.what()); }
}
}
void tsukuyomi_live2d_plugin_register_with_registrar(FlPluginRegistrar* registrar) {
  auto plugin = std::shared_ptr<Plugin>(new Plugin{
    FL_TEXTURE_REGISTRAR(g_object_ref(fl_plugin_registrar_get_texture_registrar(registrar))),
    FL_VIEW(g_object_ref(fl_plugin_registrar_get_view(registrar))), {}});
  g_autoptr(FlStandardMethodCodec) codec = fl_standard_method_codec_new();
  g_autoptr(FlMethodChannel) channel = fl_method_channel_new(fl_plugin_registrar_get_messenger(registrar),
      "space.tsukuyomi/live2d_gpu", FL_METHOD_CODEC(codec));
  fl_method_channel_set_method_call_handler(channel, handle, new std::shared_ptr<Plugin>(plugin),
      [](gpointer p) { delete static_cast<std::shared_ptr<Plugin>*>(p); });
}

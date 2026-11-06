// SPDX-License-Identifier: GPL-3.0-or-later
#import <Foundation/Foundation.h>
#include <emacs-module.h>
#include "chromel_core.h"
#include <cstdio>
#include <cstring>
#include <exception>
#include <string>
#include <vector>

extern "C" { int plugin_is_GPL_compatible; }
namespace {
std::string stringArg(emacs_env* env, emacs_value arg) {
  ptrdiff_t length = 0;
  if (!env->copy_string_contents(env, arg, nullptr, &length)) return {};
  std::vector<char> data(length);
  if (!env->copy_string_contents(env, arg, data.data(), &length)) return {};
  return std::string(data.data(), length - 1);
}
emacs_value result(emacs_env* env, const std::string& value) {
  return env->make_string(env, value.data(), value.size());
}
// Report a native failure as a Lisp error so callers can recover.  Takes a
// plain C string: this runs inside a noexcept function while unwinding, where
// allocating a std::string could itself throw and terminate the process.
emacs_value signalText(emacs_env* env, const char* text) {
  const char* safe = text ? text : "";
  emacs_value message = env->make_string(env, safe, static_cast<ptrdiff_t>(strlen(safe)));
  emacs_value list = env->funcall(env, env->intern(env, "list"), 1, &message);
  env->non_local_exit_signal(env, env->intern(env, "error"), list);
  return env->intern(env, "nil");
}
enum Op { Init, Bind, Create, Layout, Hide, Command, Pump, Events, Info, Inspect, Shutdown, IsSettingsUrl };
emacs_value call(emacs_env* env, ptrdiff_t, emacs_value* args, void* data) noexcept {
 @autoreleasepool {
  emacs_value nilValue = env->intern(env, "nil");
  try {
    auto integer = [&](int i) { return env->extract_integer(env, args[i]); };
    auto string = [&](int i) { return stringArg(env, args[i]); };
    // Validate all arguments before any native operation.  Emacs non-local
    // exits must never leak through into CEF or Cocoa callbacks.
    Op op = static_cast<Op>(reinterpret_cast<intptr_t>(data));
    std::string first, second;
    int64_t numbers[6] = {};
    if (op == Init) { first = string(0); second = string(1); }
    if (op == Bind || op == IsSettingsUrl) first = string(0);
    if (op == Create) { numbers[0] = integer(0); first = string(1); }
    if (op == Layout) for (int i = 0; i < 6; ++i) numbers[i] = integer(i);
    if (op == Hide || op == Command || op == Inspect) numbers[0] = integer(0);
    if (op == Command) { first = string(1); second = string(2); }
    if (env->non_local_exit_check(env) != emacs_funcall_exit_return) return nilValue;
    switch (op) {
      case Init: chromel::initialize(first, second); break;
      case Bind: return env->make_integer(env, chromel::bind_window(first));
      case Create: return env->make_integer(env, chromel::create(numbers[0], first));
      case Layout: chromel::layout(numbers[0], numbers[1], numbers[2], numbers[3], numbers[4], numbers[5]); break;
      case Hide: chromel::hide(numbers[0]); break;
      case Command: chromel::command(numbers[0], first, second); break;
      case Pump: chromel::pump(); break;
      case Events: return result(env, chromel::events());
      case Info: return result(env, chromel::info());
      case Inspect: return result(env, chromel::inspect(numbers[0]));
      case Shutdown: chromel::shutdown(); break;
      case IsSettingsUrl: return chromel::is_settings_url(first) ? env->intern(env, "t") : nilValue;
    }
    return env->intern(env, "t");
  } catch (const std::exception& error) {
    return signalText(env, error.what());
  } catch (NSException* exception) {
    // Cocoa faults (nil subviews, abandoned windows) must not unwind through
    // Objective-C into Emacs' C frames, which aborts the whole editor.
    const char* name = exception.name.UTF8String;
    const char* reason = exception.reason.UTF8String;
    char text[512];
    snprintf(text, sizeof text, "Objective-C exception: %s %s",
             name ? name : "NSException", reason ? reason : "");
    return signalText(env, text);
  } catch (...) {
    return signalText(env, "Native module failure");
  }
 }
}
}
extern "C" int emacs_module_init(emacs_runtime* runtime) noexcept {
  emacs_env* env = runtime->get_environment(runtime);
  struct Entry { const char* name; int count; Op op; const char* doc; };
  const Entry entries[] = {
    {"init", 2, Init, "Initialize CEF using BUNDLE and PROFILE."},
    {"bind", 1, Bind, "Find and register the native window with TITLE."},
    {"create", 2, Create, "Create a browser in WINDOW loading URL."},
    {"layout", 6, Layout, "Position ID in WINDOW at X Y WIDTH HEIGHT (logical points)."},
    {"hide", 1, Hide, "Hide browser ID."},
    {"command", 3, Command, "Perform ACTION with ARGUMENT on browser ID."},
    {"pump", 0, Pump, "Perform nonblocking CEF event loop work."},
    {"events", 0, Events, "Drain browser events as a JSON array."},
    {"info", 0, Info, "Return native runtime diagnostics."},
    {"inspect", 1, Inspect, "Return actual Cocoa geometry and focus state of browser ID as JSON."},
    {"is-settings-url", 1, IsSettingsUrl, "Return non-nil when URL belongs in the shared Chrome-style window."},
    {"shutdown", 0, Shutdown, "Close browsers and shut down CEF before Emacs exits."}
  };
  for (const auto& entry : entries) {
    auto name = std::string("chromel--native-") + entry.name;
    emacs_value args[] = {
      env->intern(env, name.c_str()),
      env->make_function(env, entry.count, entry.count, call, entry.doc,
                         reinterpret_cast<void*>(static_cast<intptr_t>(entry.op)))};
    env->funcall(env, env->intern(env, "fset"), 2, args);
  }
  emacs_value feature = env->intern(env, "chromel-module");
  env->funcall(env, env->intern(env, "provide"), 1, &feature);
  return 0;
}

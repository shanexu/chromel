// SPDX-License-Identifier: GPL-3.0-or-later
#pragma once
#include <string>

namespace chromel {
// Bumped whenever a chromel--native-* signature or semantic changes; the elisp
// side refuses to run against a module that reports a different number.
constexpr int kChromelApiVersion = 7;
int api_version();
// How many CEF browsers (embedded pages or settings windows) are alive.
// Safe before CefInitialize.
int browser_count();
void initialize(const std::string& bundle, const std::string& profile);
long bind_window(const std::string& title);
bool is_settings_url(const std::string& url);

// PAC URL handed to Chromium as --proxy-pac-url.  Takes effect on the next
// CefInitialize: Chromium resolves proxies once, at process start, and CEF has
// no runtime equivalent of Chrome's chrome.proxy API.  Empty means direct.
void set_proxy_pac(const std::string& url);

// Bundle the running process is in.  Chromium authorizes MainBundlePath, so
// this is the only bundle CEF can load its framework from.
std::string bundle_path();

// JavaScript that paints the hint overlay.  Embedded at build time.
std::string hints_script();
int create(long window, const std::string& url);
void layout(int id, long window, double x, double y, double width, double height);
void hide(int id);
void command(int id, const std::string& action, const std::string& argument);
void pump();
// True when CEF has scheduled work for the message loop.
bool pump_pending();
std::string events();
std::string info();
std::string inspect(int id);
void shutdown();
}

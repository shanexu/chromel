// SPDX-License-Identifier: GPL-3.0-or-later
#pragma once
#include <string>

namespace chromel {
// Bumped whenever a chromel--native-* signature or semantic changes; the elisp
// side refuses to run against a module that reports a different number.
constexpr int kChromelApiVersion = 1;
int api_version();
void initialize(const std::string& bundle, const std::string& profile);
long bind_window(const std::string& title);
bool is_settings_url(const std::string& url);
int create(long window, const std::string& url);
void layout(int id, long window, double x, double y, double width, double height);
void hide(int id);
void command(int id, const std::string& action, const std::string& argument);
void pump();
std::string events();
std::string info();
std::string inspect(int id);
void shutdown();
}

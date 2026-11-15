// Permission prompts the page is waiting on.
//
// CEF hands us a request together with a callback that must be run exactly
// once. Emacs answers through the event loop, so the callback is parked here
// until the user picks yes or no.
#pragma once

#include <cstdint>
#include <string>
#include <vector>

#include "include/cef_permission_handler.h"

namespace chromel {

// Human names for a request, e.g. {"location"} or {"camera", "microphone"}.
std::vector<std::string> permission_names(uint32_t media, uint32_t prompt);

// Park the callback, report the request to Emacs, and return the id it will
// answer with. Called on the browser process UI thread.
uint64_t begin_prompt(int browserId,
                      const std::string& origin,
                      const std::vector<std::string>& names,
                      CefRefPtr<CefPermissionPromptCallback> prompt,
                      CefRefPtr<CefMediaAccessCallback> media,
                      uint32_t mediaBits);

// Answer a parked request. Unknown ids are ignored: Emacs may answer after a
// navigation already cancelled the prompt.
void permission_reply(uint64_t id, bool allow);

// Chromium withdrew the prompt (navigation, closed page); the callback is no
// longer ours to run.
void dismiss_prompt(uint64_t id);

// Answer every parked request with "no" before tearing CEF down.
void cancel_prompts();

}  // namespace chromel

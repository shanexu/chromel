#include "permissions.h"

#import <Foundation/Foundation.h>

#include <algorithm>
#include <unordered_map>

#include "events.h"

namespace chromel {
namespace {

struct Pending {
  std::string origin;
  std::vector<std::string> names;
  CefRefPtr<CefPermissionPromptCallback> prompt;
  CefRefPtr<CefMediaAccessCallback> media;
  uint32_t mediaBits = 0;
};

std::unordered_map<uint64_t, Pending>& pending() {
  static std::unordered_map<uint64_t, Pending> prompts;
  return prompts;
}

uint64_t lastId = 0;

NSString* toNS(const std::string& text) {
  NSString* result = [[NSString alloc] initWithBytes:text.data()
                                              length:text.size()
                                            encoding:NSUTF8StringEncoding];
  return result ? result : @"";
}

}  // namespace

std::vector<std::string> permission_names(uint32_t media, uint32_t prompt) {
  std::vector<std::string> names;
  if (media & CEF_MEDIA_PERMISSION_DEVICE_AUDIO_CAPTURE) names.push_back("microphone");
  if (media & CEF_MEDIA_PERMISSION_DEVICE_VIDEO_CAPTURE) names.push_back("camera");
  if (media & CEF_MEDIA_PERMISSION_DESKTOP_AUDIO_CAPTURE) names.push_back("desktop audio");
  if (media & CEF_MEDIA_PERMISSION_DESKTOP_VIDEO_CAPTURE) names.push_back("screen");

  struct Named {
    uint32_t bit;
    const char* name;
  };
  // Prompts are shown to a person, so the names say what the page gets, not
  // what Chromium calls it.
  static const Named table[] = {
      {CEF_PERMISSION_TYPE_CLIPBOARD, "clipboard"},
      {CEF_PERMISSION_TYPE_GEOLOCATION, "location"},
      {CEF_PERMISSION_TYPE_NOTIFICATIONS, "notifications"},
      {CEF_PERMISSION_TYPE_MIC_STREAM, "microphone"},
      {CEF_PERMISSION_TYPE_CAMERA_STREAM, "camera"},
      {CEF_PERMISSION_TYPE_POINTER_LOCK, "pointer lock"},
      {CEF_PERMISSION_TYPE_KEYBOARD_LOCK, "keyboard lock"},
      {CEF_PERMISSION_TYPE_MIDI_SYSEX, "MIDI devices"},
      {CEF_PERMISSION_TYPE_MULTIPLE_DOWNLOADS, "multiple downloads"},
      {CEF_PERMISSION_TYPE_FILE_SYSTEM_ACCESS, "files"},
      {CEF_PERMISSION_TYPE_LOCAL_FONTS, "local fonts"},
      {CEF_PERMISSION_TYPE_IDLE_DETECTION, "idle detection"},
      {CEF_PERMISSION_TYPE_PROTECTED_MEDIA_IDENTIFIER, "protected media"},
      {CEF_PERMISSION_TYPE_STORAGE_ACCESS, "storage"},
      {CEF_PERMISSION_TYPE_TOP_LEVEL_STORAGE_ACCESS, "storage"},
      {CEF_PERMISSION_TYPE_DISK_QUOTA, "disk space"},
      {CEF_PERMISSION_TYPE_VR_SESSION, "virtual reality"},
      {CEF_PERMISSION_TYPE_AR_SESSION, "augmented reality"},
      {CEF_PERMISSION_TYPE_WEB_APP_INSTALLATION, "app installation"},
      {CEF_PERMISSION_TYPE_WINDOW_MANAGEMENT, "window management"},
      {CEF_PERMISSION_TYPE_REGISTER_PROTOCOL_HANDLER, "protocol handler"},
      {CEF_PERMISSION_TYPE_SENSORS, "sensors"},
      {CEF_PERMISSION_TYPE_LOCAL_NETWORK, "local network"},
      {CEF_PERMISSION_TYPE_LOOPBACK_NETWORK, "local network"},
      {CEF_PERMISSION_TYPE_HAND_TRACKING, "hand tracking"},
      {CEF_PERMISSION_TYPE_CAMERA_PAN_TILT_ZOOM, "camera controls"},
      {CEF_PERMISSION_TYPE_CAPTURED_SURFACE_CONTROL, "captured surface"},
      {CEF_PERMISSION_TYPE_IDENTITY_PROVIDER, "identity"},
      {CEF_PERMISSION_TYPE_AMBIENT_LOGIN, "ambient login"},
  };
  for (const Named& entry : table) {
    if ((prompt & entry.bit) == 0) continue;
    const std::string name = entry.name;
    if (std::find(names.begin(), names.end(), name) == names.end()) names.push_back(name);
  }
  if (names.empty()) names.push_back("permission");
  return names;
}

uint64_t begin_prompt(int browserId,
                      const std::string& origin,
                      const std::vector<std::string>& names,
                      CefRefPtr<CefPermissionPromptCallback> prompt,
                      CefRefPtr<CefMediaAccessCallback> media,
                      uint32_t mediaBits) {
  const uint64_t id = ++lastId;
  Pending entry;
  entry.origin = origin;
  entry.names = names;
  entry.prompt = prompt;
  entry.media = media;
  entry.mediaBits = mediaBits;
  pending()[id] = entry;

  NSMutableArray* list = [NSMutableArray arrayWithCapacity:names.size()];
  for (const std::string& name : names) [list addObject:toNS(name)];
  NSDictionary* payload = @{@"id" : @(id), @"origin" : toNS(origin), @"permissions" : list};
  NSData* data = [NSJSONSerialization dataWithJSONObject:payload options:0 error:nil];
  if (data) emit(browserId, @"permission",
                 [[NSString alloc] initWithData:data encoding:NSUTF8StringEncoding]);
  return id;
}

void permission_reply(uint64_t id, bool allow) {
  const auto found = pending().find(id);
  if (found == pending().end()) return;
  const Pending entry = found->second;
  pending().erase(found);
  if (entry.media) {
    // getUserMedia requires the answer to repeat the bits it asked for.
    if (allow) {
      entry.media->Continue(entry.mediaBits);
    } else {
      entry.media->Cancel();
    }
    return;
  }
  if (entry.prompt)
    entry.prompt->Continue(allow ? CEF_PERMISSION_RESULT_ACCEPT : CEF_PERMISSION_RESULT_DENY);
}

void dismiss_prompt(uint64_t id) { pending().erase(id); }

void cancel_prompts() {
  auto parked = std::move(pending());
  pending().clear();
  for (auto& item : parked) {
    if (item.second.media) {
      item.second.media->Cancel();
    } else if (item.second.prompt) {
      item.second.prompt->Continue(CEF_PERMISSION_RESULT_IGNORE);
    }
  }
}

}  // namespace chromel

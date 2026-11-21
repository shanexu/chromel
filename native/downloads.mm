// Copyright 2026 the Chromel authors. SPDX-License-Identifier: GPL-3.0-or-later
#include "downloads.h"

#include <sys/stat.h>

#include <filesystem>
#include <mutex>
#include <string>
#include <unordered_map>

#include "events.h"

namespace chromel {
namespace {

std::mutex& stateMutex() {
  static std::mutex mutex;
  return mutex;
}

// Elisp owns the setting; native only obeys it and remembers the last percent so
// a slow download does not push an identical event on every pump.
std::string& directoryRef() {
  static std::string directory;
  return directory;
}

bool& configuredRef() {
  static bool configured = false;
  return configured;
}

std::unordered_map<int, int>& lastPercent() {
  static std::unordered_map<int, int> percents;
  return percents;
}

std::string suggestedFileName(const CefString& suggested) {
  // A page controls this string: never let it escape the download directory.
  std::filesystem::path name(suggested.ToString());
  std::string flat = name.filename().string();
  if (flat.empty() || flat == "." || flat == "..") flat = "download";
  return flat;
}

// "report.txt" -> "report (1).txt", like every other browser.  Returns an empty
// string when every candidate name is taken; the caller reports the failure
// instead of handing Chromium a path that already exists.
std::string uniquePath(const std::filesystem::path& directory, const std::string& name) {
  std::error_code error;
  const std::filesystem::path target = directory / name;
  if (!std::filesystem::exists(target, error)) return target.string();
  const std::string stem = target.stem().string();
  const std::string extension = target.extension().string();
  for (int index = 1; index < 10000; ++index) {
    const std::filesystem::path candidate =
        directory / (stem + " (" + std::to_string(index) + ")" + extension);
    if (!std::filesystem::exists(candidate, error)) return candidate.string();
  }
  return {};
}

void emitPayload(int browserId, NSDictionary* payload) {
  NSData* data = [NSJSONSerialization dataWithJSONObject:payload options:0 error:nil];
  if (!data) return;
  NSString* text = [[NSString alloc] initWithData:data encoding:NSUTF8StringEncoding];
  emit(browserId, @"download", text ?: @"");
}

NSString* value(const std::string& text) {
  return [NSString stringWithUTF8String:text.c_str()] ?: @"";
}

}  // namespace

void set_download_directory(const std::string& directory) {
  if (directory.empty()) return;
  // Recorded, not created: a download is the first thing that may need it, and
  // creating directories during startup would surprise anyone reading a stack.
  std::lock_guard<std::mutex> lock(stateMutex());
  configuredRef() = true;
  directoryRef() = directory;
  lastPercent().clear();
}

std::string download_directory() {
  std::lock_guard<std::mutex> lock(stateMutex());
  return configuredRef() ? directoryRef() : std::string();
}

bool start_download(int browserId,
                    CefRefPtr<CefDownloadItem> item,
                    const CefString& suggestedName,
                    CefRefPtr<CefBeforeDownloadCallback> callback) {
  if (!item || !callback) return false;
  const std::string name = suggestedFileName(suggestedName);
  std::string path;
  {
    std::lock_guard<std::mutex> lock(stateMutex());
    if (!configuredRef()) {
      emitPayload(browserId, @{
        @"state" : @"failed",
        @"name" : value(name),
        @"reason" : @"No download directory is configured; set `chromel-download-directory' and retry.",
      });
      return false;
    }
    std::error_code error;
    std::filesystem::create_directories(directoryRef(), error);
    if (error) {
      emitPayload(browserId, @{
        @"state" : @"failed",
        @"name" : value(name),
        @"reason" : value("Cannot create the download directory: " + error.message()),
      });
      return false;
    }
    path = uniquePath(directoryRef(), name);
    lastPercent().erase(browserId);
  }
  if (path.empty()) {
    emitPayload(browserId, @{
      @"state" : @"failed",
      @"name" : value(name),
      @"reason" : @"Every name derived from this download is already taken.",
    });
    return false;
  }
  // show_dialog=false: Emacs has no download shelf, so the path is decided here.
  callback->Continue(path, false);
  emitPayload(browserId, @{
    @"state" : @"started",
    @"name" : value(name),
    @"path" : value(path),
  });
  return true;
}

void download_progress(int browserId, CefRefPtr<CefDownloadItem> item) {
  if (!item) return;
  NSString* state = @"progress";
  if (item->IsComplete()) state = @"completed";
  else if (item->IsCanceled()) state = @"cancelled";
  else if (item->IsInterrupted()) state = @"interrupted";

  const int percent = item->GetPercentComplete();
  {
    std::lock_guard<std::mutex> lock(stateMutex());
    auto found = lastPercent().find(browserId);
    const bool unchanged = found != lastPercent().end() && found->second == percent;
    if (unchanged && [state isEqualToString:@"progress"]) return;
    if ([state isEqualToString:@"progress"]) lastPercent()[browserId] = percent;
    else lastPercent().erase(browserId);
  }

  emitPayload(browserId, @{
    @"state" : state,
    @"name" : value(item->GetSuggestedFileName().ToString()),
    @"path" : value(item->GetFullPath().ToString()),
    @"percent" : @(percent),
    @"received" : @((double)item->GetReceivedBytes()),
    @"total" : @((double)item->GetTotalBytes()),
  });
}

}  // namespace chromel

// Copyright 2026 the Chromel authors. SPDX-License-Identifier: GPL-3.0-or-later
#ifndef CHROMEL_DOWNLOADS_H_
#define CHROMEL_DOWNLOADS_H_

#include <string>

#include "include/cef_download_handler.h"
#include "include/cef_download_item.h"

namespace chromel {

// Where downloads land.  Elisp owns the setting; native only obeys it.
void set_download_directory(const std::string& directory);
std::string download_directory();

// Hand a download to CEF.  Returns false when there is no usable directory, in
// which case the callback is not continued and the download stays cancelled.
bool start_download(int browserId,
                    CefRefPtr<CefDownloadItem> item,
                    const CefString& suggestedName,
                    CefRefPtr<CefBeforeDownloadCallback> callback);

// Report progress/completion once per visible change.
void download_progress(int browserId, CefRefPtr<CefDownloadItem> item);

}  // namespace chromel

#endif  // CHROMEL_DOWNLOADS_H_

// SPDX-License-Identifier: GPL-3.0-or-later
#pragma once
#import <Cocoa/Cocoa.h>
#include <map>
#include <memory>
#include <string>
#include "include/cef_browser.h"

// One embedded page and the Cocoa view that hosts it.  This is the state the
// rest of the backend passes around by id, so it lives in its own header
// instead of inside a single 1300-line translation unit.
struct Page {
  int id;
  NSView* container;
  __weak NSWindow* lifetimeWindow;
  __weak NSView* host;
  CefRefPtr<CefBrowser> browser;
  bool closing = false;
  bool selected = false;
  std::string pendingEval;
  std::string pendingFind;
  int completedFind = -1;
  std::string inputFrame;
  bool inputControl = false;
  int scrollStep = 60, scrollDuration = 140, scrollSpeed = 900;
  unsigned short physicalCode = 0;
  char physicalKey = 0, scrollKey = 0;
  std::string scrollFrame;
  bool scrollHeld = false;
};

// Both maps are keyed by browser id.  `pages` holds the embedded pages the Lisp
// side talks to; `browsers` also holds browsers without a page (DevTools), which
// is why the two counts differ in `info()`.
extern std::map<int, std::shared_ptr<Page>> pages;
extern std::map<int, CefRefPtr<CefBrowser>> browsers;
extern int nextId;

std::shared_ptr<Page> pageFor(int id);
bool ownsFocus(const std::shared_ptr<Page>& page);
void stopScroll(const std::shared_ptr<Page>& page, bool cancel = true);
void scrollPage(const std::shared_ptr<Page>& page, CefRefPtr<CefFrame> frame,
                double amount, int duration, int speed, const std::string& mode, bool held);
void unfocus(const std::shared_ptr<Page>& page);

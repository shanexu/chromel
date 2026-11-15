// SPDX-License-Identifier: GPL-3.0-or-later
#include "page.h"
#include <stdexcept>

std::map<int, std::shared_ptr<Page>> pages;
std::map<int, CefRefPtr<CefBrowser>> browsers;
int nextId = 1;

std::shared_ptr<Page> pageFor(int id) {
  auto found = pages.find(id);
  if (found == pages.end() || found->second->closing)
    throw std::runtime_error("Browser is closed or unknown");
  return found->second;
}
bool ownsFocus(const std::shared_ptr<Page>& page) {
  NSResponder* responder = page->container.window.firstResponder;
  return [responder isKindOfClass:NSView.class] &&
    [(NSView*)responder isDescendantOf:page->container];
}
void stopScroll(const std::shared_ptr<Page>& page, bool cancel) {
  if (page->browser && !page->scrollFrame.empty()) {
    auto frame = page->browser->GetFrameByIdentifier(page->scrollFrame);
    if (frame && frame->IsValid()) frame->ExecuteJavaScript(
      cancel ? "window.__emacsChromelScroller?.cancel();" : "window.__emacsChromelScroller?.release();", "", 1);
  }
  page->scrollHeld = false;
  page->scrollKey = 0;
  if (cancel) { page->scrollFrame.clear(); page->physicalKey = 0; }
}
void scrollPage(const std::shared_ptr<Page>& page, CefRefPtr<CefFrame> frame,
                double amount, int duration, int speed, const std::string& mode, bool held) {
  if (!frame || !frame->IsValid() || !amount) return;
  held = held && mode == "pixels" && page->physicalKey == (amount > 0 ? 'j' : 'k');
  const auto frameId = frame->GetIdentifier().ToString();
  if (held && page->scrollHeld && page->scrollFrame == frameId && page->scrollKey == page->physicalKey) {
    frame->ExecuteJavaScript("window.__emacsChromelScroller?.repeat();", "", 1);
    return;
  }
  if (page->scrollHeld) {
    const auto key = page->physicalKey;
    stopScroll(page);
    page->physicalKey = key;
  }
  page->scrollFrame = frameId;
  page->scrollHeld = held;
  page->scrollKey = held ? page->physicalKey : 0;
  const auto prefix = held ? "window.__emacsChromelScroller?.hold(" : "window.__emacsChromelScroller?.scroll(";
  const auto args = std::to_string(amount) + "," + std::to_string(duration) + "," +
    (held ? std::to_string(speed) : "\"" + mode + "\"");
  frame->ExecuteJavaScript(prefix + args + ");", "", 1);
}
void unfocus(const std::shared_ptr<Page>& page) {
  stopScroll(page);
  if (ownsFocus(page)) {
    if (page->browser) page->browser->GetHost()->SetFocus(false);
    [page->container.window makeFirstResponder:page->host];
  }
}

// SPDX-License-Identifier: GPL-3.0-or-later
#include "page.h"
#include <algorithm>
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

NSMapTable<NSNumber*, NSWindow*>* windows = nil;

NSWindow* windowFor(long handle) {
  NSWindow* win = [windows objectForKey:@(handle)];
  if (!win || ![NSApp.windows containsObject:win])
    throw std::runtime_error("Emacs frame no longer exists");
  return win;
}

namespace chromel {

// Creating, placing and hiding a page is all "the page and its container", so
// it lives next to the rest of Page's behaviour.  Everything the browser
// callbacks do stays in chromel_core.mm.
int create(long handle, const std::string& url) {
  requireBackendReady();
  NSWindow* win = windowFor(handle);
  auto page = std::make_shared<Page>();
  page->id = nextId++;
  page->host = win.contentView;
  page->container = [[NSView alloc] initWithFrame:NSMakeRect(0, 0, 1, 1)];
  page->container.wantsLayer = YES;
  page->container.hidden = YES;
  [page->host addSubview:page->container];
  pages[page->id] = page;
  CefWindowInfo windowInfo;
  // Let CEF own a permanently hidden lifecycle window so its public close
  // path remains usable after embedding.  Only its child NSView is displayed
  // in Emacs; there is no external overlay or window-position tracking.
  windowInfo.hidden = true;
  windowInfo.bounds = CefRect(0, 0, 1, 1);
  windowInfo.runtime_style = CEF_RUNTIME_STYLE_ALLOY;
  CefBrowserSettings settings;
  CefRefPtr<CefClient> client = makePageClient(page->id);
  page->browser = CefBrowserHost::CreateBrowserSync(windowInfo, client, url, settings, nullptr, nullptr);
  if (!page->browser) {
    [page->container removeFromSuperview];
    pages.erase(page->id);
    throw std::runtime_error("CEF browser creation failed");
  }
  // CEF owns its view; the clipping container belongs to this plugin.
  NSView* view = (__bridge NSView*)page->browser->GetHost()->GetWindowHandle();
  if (!view) {
    // OnAfterCreated already registered this browser; without closing it the
    // renderer outlives the session and shutdown() can never reach CefShutdown.
    browsers.erase(page->browser->GetIdentifier());
    page->browser->GetHost()->CloseBrowser(true);
    [page->container removeFromSuperview];
    page->lifetimeWindow = nil;
    pages.erase(page->id);
    throw std::runtime_error("CEF created a browser without a Cocoa view");
  }
  page->lifetimeWindow = view.window;
  [view removeFromSuperview];
  [page->container addSubview:view];
  view.autoresizingMask = NSViewWidthSizable | NSViewHeightSizable;
  return page->id;
}

void layout(int id, long handle, double x, double y, double width, double height) {
  requireBackendReady();
  auto page = pageFor(id);
  NSView* host = windowFor(handle).contentView;
  if (page->host != host) {
    unfocus(page);
    [page->container removeFromSuperview];
    page->host = host;
    [host addSubview:page->container];
  }
  // Emacs pixel edges on NS are logical points; multiplying by Retina scale
  // would double the size.  Convert from top-left only for unflipped hosts.
  const double cy = host.isFlipped ? y : NSHeight(host.bounds) - y - height;
  NSRect rect = NSMakeRect(x, cy, std::max(0.0, width), std::max(0.0, height));
  if (!NSEqualRects(page->container.frame, rect)) {
    page->container.frame = rect;
    NSView* view = page->browser ? (__bridge NSView*)page->browser->GetHost()->GetWindowHandle() : nil;
    if (view) {
      view.frame = page->container.bounds;
      page->browser->GetHost()->NotifyMoveOrResizeStarted();
    }
  }
  page->container.hidden = width <= 0 || height <= 0;
}

void hide(int id) {
  requireBackendReady();
  auto page = pageFor(id);
  unfocus(page);
  page->container.hidden = YES;
  page->selected = false;
}

}  // namespace chromel

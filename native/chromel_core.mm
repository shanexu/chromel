// SPDX-License-Identifier: GPL-3.0-or-later
#import <Cocoa/Cocoa.h>
#import <objc/runtime.h>
#include "chromel_core.h"
#include "host_wakeup.h"
#include "include/cef_app.h"
#include "include/cef_application_mac.h"
#include "include/cef_browser.h"
#include "include/views/cef_browser_view.h"
#include "include/views/cef_box_layout.h"
#include "include/views/cef_window.h"
#include "include/cef_browser_process_handler.h"
#include "include/cef_client.h"
#include "include/cef_find_handler.h"
#include "include/cef_devtools_message_observer.h"
#include "include/cef_command_line.h"
#include "include/cef_process_message.h"
#include "include/cef_version.h"
#include "include/wrapper/cef_helpers.h"
#include "include/wrapper/cef_library_loader.h"
#include <map>
#include <vector>
#include <algorithm>
#include <cctype>
#include <filesystem>
#include <memory>
#include <cmath>
#include <stdexcept>
#include <signal.h>
#include <pthread.h>

namespace {
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
std::map<int, std::shared_ptr<Page>> pages;
std::map<int, CefRefPtr<CefBrowser>> browsers;
// Chrome-style settings windows share the global request context, but never
// enter the embedded Page map or its view/focus/lifecycle handling.
CefRefPtr<CefBrowser> settingsBrowser;
CefRefPtr<CefWindow> settingsWindow;
std::map<int, CefRefPtr<CefBrowser>> settingsBrowsers;
std::string settingsTitle;
bool settingsClosing = false;
CefRefPtr<CefRegistration> settingsTestObserver;
std::string settingsTestResult;
bool settingsTestSuccess = false;
NSMutableArray<NSDictionary*>* queue;
NSMapTable<NSNumber*, NSWindow*>* windows;
bool initialized = false;
bool stopped = false;
bool pumping = false;
std::unique_ptr<ChromelHostWakeup> hostWakeup;
int nextId = 1;
std::string profilePath;
bool testMode = false;
char handlingEventKey;
IMP originalSendEvent;
std::vector<id> observers;

// Releases a flag on every exit path, so one throwing native call cannot wedge
// a long-lived subsystem such as the message pump.
class FlagGuard {
 public:
  explicit FlagGuard(bool& flag) : flag_(flag) { flag_ = true; }
  ~FlagGuard() { flag_ = false; }
  FlagGuard(const FlagGuard&) = delete;
  FlagGuard& operator=(const FlagGuard&) = delete;
 private:
  bool& flag_;
};

// Chromium initializes as if it owned main(), resetting process signal
// dispositions.  Emacs relies on SIGALRM and friends for its own event loop.
class HostSignals {
 public:
  HostSignals() {
    sigset_t blocked;
    sigemptyset(&blocked);
    for (size_t i = 0; i < count; ++i) {
      sigaction(signals[i], nullptr, &actions[i]);
      sigaddset(&blocked, signals[i]);
    }
    pthread_sigmask(SIG_BLOCK, &blocked, &mask);
  }
  ~HostSignals() {
    for (size_t i = 0; i < count; ++i) sigaction(signals[i], &actions[i], nullptr);
    pthread_sigmask(SIG_SETMASK, &mask, nullptr);
  }
 private:
  static constexpr int signals[] = {SIGALRM, SIGVTALRM, SIGPROF, SIGIO, SIGCHLD,
                                    SIGUSR1, SIGUSR2, SIGWINCH, SIGINT, SIGHUP, SIGTERM, SIGQUIT};
  static constexpr size_t count = sizeof(signals) / sizeof(signals[0]);
  struct sigaction actions[count];
  sigset_t mask;
};

NSString* ns(const std::string& s) {
  return [[NSString alloc] initWithBytes:s.data() length:s.size()
                               encoding:NSUTF8StringEncoding] ?: @"";
}
std::string utf8(NSString* s) { return s ? std::string(s.UTF8String ?: "") : ""; }
void checkThread() {
  if (![NSThread isMainThread]) throw std::runtime_error("CEF must run on the Cocoa main thread");
}
void requireReady() {
  checkThread();
  if (!initialized || stopped) throw std::runtime_error("CEF is not running");
}
void emit(int id, NSString* type, NSString* value = @"") {
  if (!id) return;
  // Every callback used here is delivered on the CEF UI (Cocoa main) thread.
  [queue addObject:@{@"id": @(id), @"type": type, @"value": value ?: @""}];
}
std::shared_ptr<Page> pageFor(int id) {
  auto found = pages.find(id);
  if (found == pages.end() || found->second->closing)
    throw std::runtime_error("Browser is closed or unknown");
  return found->second;
}
NSWindow* windowFor(long handle) {
  NSWindow* win = [windows objectForKey:@(handle)];
  if (!win || ![NSApp.windows containsObject:win])
    throw std::runtime_error("Emacs frame no longer exists");
  return win;
}
// CEF may hand out a null or detached main frame while a page is tearing down.
// Every caller must tolerate that instead of dereferencing it.
CefRefPtr<CefFrame> mainFrame(const CefRefPtr<CefBrowser>& browser) {
  if (!browser) return nullptr;
  auto frame = browser->GetMainFrame();
  return frame && frame->IsValid() ? frame : nullptr;
}
bool ownsFocus(const std::shared_ptr<Page>& page) {
  NSResponder* responder = page->container.window.firstResponder;
  return [responder isKindOfClass:NSView.class] &&
    [(NSView*)responder isDescendantOf:page->container];
}
void stopScroll(const std::shared_ptr<Page>& page, bool cancel = true) {
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

BOOL isHandling(id self, SEL) {
  return [objc_getAssociatedObject(self, &handlingEventKey) boolValue];
}
void setHandling(id self, SEL, BOOL value) {
  objc_setAssociatedObject(self, &handlingEventKey, @(value), OBJC_ASSOCIATION_RETAIN_NONATOMIC);
}
NSEvent* routeKeyEvent(NSEvent* event);
void sendEvent(id self, SEL cmd, NSEvent* event) {
  event = routeKeyEvent(event);
  if (!event) return;
  const bool foreignInput = hostWakeup && ChromelHostWakeup::foreignInput(event);
  CefScopedSendingEvent scope;
  reinterpret_cast<void (*)(id, SEL, NSEvent*)>(originalSendEvent)(self, cmd, event);
  if (foreignInput && hostWakeup) hostWakeup->schedule();
}
void adaptApplication() {
  if ([NSApp conformsToProtocol:@protocol(CefAppProtocol)]) return;
  Class base = object_getClass(NSApp);
  Method method = class_getInstanceMethod(base, @selector(sendEvent:));
  originalSendEvent = method_getImplementation(method);
  // Preserve the application class identity: Foundation KVO can already have
  // registered observations before a module is loaded into a running Emacs.
  if (!class_addMethod(base, @selector(sendEvent:), (IMP)sendEvent, method_getTypeEncoding(method)))
    method_setImplementation(method, (IMP)sendEvent);
  const auto getterType = std::string(@encode(BOOL)) + "@:";
  const auto setterType = std::string("v@:") + @encode(BOOL);
  class_addMethod(base, @selector(isHandlingSendEvent), (IMP)isHandling, getterType.c_str());
  class_addMethod(base, @selector(setHandlingSendEvent:), (IMP)setHandling, setterType.c_str());
  class_addProtocol(base, @protocol(CefAppProtocol));
}

class App final : public CefApp, public CefBrowserProcessHandler {
 public:
  CefRefPtr<CefBrowserProcessHandler> GetBrowserProcessHandler() override { return this; }
  CefRefPtr<CefClient> GetDefaultClient() override;
  void OnScheduleMessagePumpWork(int64_t /*delayMs*/) override {
    // Emacs already schedules pump() on its main thread every 20 ms, including
    // while waiting in the minibuffer.  That recurring timer coalesces requests
    // and services delayed work too.  This callback can run on ANY thread:
    // never call Lisp, Cocoa, or CefDoMessageLoopWork synchronously here.
  }
  void OnBeforeCommandLineProcessing(const CefString& processType,
                                     CefRefPtr<CefCommandLine> commandLine) override {
    // Test-only Chromium facility: never ask the user's Keychain to authorize
    // disposable, repeatedly re-signed test apps.  Production uses Keychain.
    if (testMode && processType.empty()) {
      commandLine->AppendSwitch("use-mock-keychain");
      // The GUI harness stacks disposable windows behind the user's terminal.
      // Chromium throttles occluded windows, which made scripted navigation,
      // rendering and key delivery miss their deadlines at random.
      commandLine->AppendSwitch("disable-background-timer-throttling");
      commandLine->AppendSwitch("disable-renderer-backgrounding");
      commandLine->AppendSwitch("disable-backgrounding-occluded-windows");
    }
  }
 private:
  IMPLEMENT_REFCOUNTING(App);
};

bool isSettingsURL(const std::string& url);
bool isPrivilegedChromeURL(const std::string& url);

class Client final : public CefClient,
                     public CefLifeSpanHandler,
                     public CefDisplayHandler,
                     public CefLoadHandler,
                     public CefFocusHandler,
                     public CefRequestHandler,
                     public CefKeyboardHandler,
                     public CefFindHandler {
 public:
  explicit Client(int id) : id_(id) {}
  CefRefPtr<CefLifeSpanHandler> GetLifeSpanHandler() override { return this; }
  CefRefPtr<CefDisplayHandler> GetDisplayHandler() override { return this; }
  CefRefPtr<CefLoadHandler> GetLoadHandler() override { return this; }
  CefRefPtr<CefFocusHandler> GetFocusHandler() override { return this; }
  CefRefPtr<CefRequestHandler> GetRequestHandler() override { return this; }
  CefRefPtr<CefKeyboardHandler> GetKeyboardHandler() override { return this; }
  CefRefPtr<CefFindHandler> GetFindHandler() override { return this; }
  void OnFindResult(CefRefPtr<CefBrowser>, int identifier, int count, const CefRect&,
                    int ordinal, bool finalUpdate) override {
    const auto found = pages.find(id_);
    if (found == pages.end() || found->second->pendingFind.empty() ||
        identifier <= found->second->completedFind) return;
    const auto page = found->second;
    NSDictionary* result = @{@"token": ns(page->pendingFind), @"count": @(count),
                             @"ordinal": @(ordinal), @"final": @(finalUpdate)};
    NSData* data = [NSJSONSerialization dataWithJSONObject:result options:0 error:nil];
    emit(id_, @"find", [[NSString alloc] initWithData:data encoding:NSUTF8StringEncoding]);
    if (finalUpdate) {
      page->completedFind = identifier;
      page->pendingFind.clear();
    }
  }
  bool OnPreKeyEvent(CefRefPtr<CefBrowser> browser, const CefKeyEvent& event,
                     CefEventHandle, bool*) override {
    const auto found = pages.find(id_);
    if (found == pages.end() || found->second->closing || event.focus_on_editable_field ||
        (event.modifiers & (EVENTFLAG_SHIFT_DOWN | EVENTFLAG_CONTROL_DOWN |
                            EVENTFLAG_ALT_DOWN | EVENTFLAG_COMMAND_DOWN))) return false;
    auto frame = browser->GetFocusedFrame();
    if (!frame || !frame->IsValid()) return false;
    const auto page = found->second;
    if (page->inputControl && page->inputFrame == frame->GetIdentifier().ToString()) return false;
    const auto key = event.unmodified_character;
    if (key != 'j' && key != 'k') return false;
    if (event.type == KEYEVENT_RAWKEYDOWN || event.type == KEYEVENT_KEYDOWN) {
      scrollPage(page, frame, key == 'j' ? page->scrollStep : -page->scrollStep,
                 page->scrollDuration, page->scrollSpeed, "pixels", true);
    }
    return true;
  }
  bool OnProcessMessageReceived(CefRefPtr<CefBrowser>, CefRefPtr<CefFrame> frame,
                                CefProcessId source, CefRefPtr<CefProcessMessage> message) override {
    if (!message) return false;
    if (source == PID_RENDERER && message->GetName() == "chromel.input-focus") {
      auto found = pages.find(id_);
      auto args = message->GetArgumentList();
      if (found != pages.end() && !found->second->closing && frame && args && args->GetSize() >= 1) {
        found->second->inputFrame = frame->GetIdentifier().ToString();
        found->second->inputControl = args->GetBool(0);
      }
      return true;
    }
    if (source != PID_RENDERER || message->GetName() != "chromel.eval.result" ||
        !frame || !frame->IsMain())
      return false;
    auto args = message->GetArgumentList();
    if (!args || args->GetSize() < 3) return true;
    auto found = pages.find(id_);
    const auto token = args->GetString(0).ToString();
    if (found != pages.end() && !found->second->closing &&
        !token.empty() && found->second->pendingEval == token) {
      found->second->pendingEval.clear();
      NSDictionary* response = @{@"token": ns(token), @"ok": @(args->GetBool(1)),
                                 @"result": ns(args->GetString(2).ToString())};
      NSData* data = [NSJSONSerialization dataWithJSONObject:response options:0 error:nil];
      emit(id_, @"eval", [[NSString alloc] initWithData:data encoding:NSUTF8StringEncoding]);
    }
    return true;
  }
  void OnAfterCreated(CefRefPtr<CefBrowser> browser) override {
    CEF_REQUIRE_UI_THREAD();
    browsers[browser->GetIdentifier()] = browser;
  }
  bool DoClose(CefRefPtr<CefBrowser> browser) override {
    auto found = pages.find(id_);
    if (found != pages.end()) {
      auto page = found->second;
      unfocus(page);
      // Restore the view to its hidden lifetime window before allowing CEF's
      // normal close procedure.  CEF owns that window; retaining it here would
      // prevent the window/view teardown that completes OnBeforeClose.
      // This must never performClose: the visible Emacs host window.
      NSView* view = (__bridge NSView*)browser->GetHost()->GetWindowHandle();
      [view removeFromSuperview];
      [page->lifetimeWindow.contentView addSubview:view];
    }
    return false;
  }
  void OnBeforeClose(CefRefPtr<CefBrowser> browser) override {
    CEF_REQUIRE_UI_THREAD();
    browsers.erase(browser->GetIdentifier());
    auto found = pages.find(id_);
    if (found != pages.end()) {
      auto page = found->second;
      page->browser = nullptr;
      [page->container removeFromSuperview];
      pages.erase(found);
      emit(id_, @"closed");
    }
  }
  bool OnBeforePopup(CefRefPtr<CefBrowser>, CefRefPtr<CefFrame>, int,
                     const CefString& url, const CefString&, WindowOpenDisposition disposition,
                     bool userGesture, const CefPopupFeatures&, CefWindowInfo&,
                     CefRefPtr<CefClient>&, CefBrowserSettings&,
                     CefRefPtr<CefDictionaryValue>&, bool*) override {
    // Deliberate MVP behavior: user-requested links become new Emacs buffers.
    // This does not preserve window.opener / script-created popup sessions.
    if (userGesture && !url.empty())
      emit(id_, disposition == CEF_WOD_NEW_BACKGROUND_TAB ? @"popup-background" : @"popup", ns(url.ToString()));
    return true;
  }
  bool OnBeforeBrowse(CefRefPtr<CefBrowser>, CefRefPtr<CefFrame> frame,
                      CefRefPtr<CefRequest> request, bool userGesture, bool) override {
    // The Web Store installer and management WebUIs need a Chrome-style host.
    // Defer window creation to Emacs's event queue, outside the CEF callback.
    // Page-initiated handoff of the Web Store is a feature (test/gui-management
    // relies on it); privileged chrome:// pages additionally require a user
    // gesture, so a scripted redirect cannot raise a WebUI host by itself.
    const auto target = request ? request->GetURL().ToString() : std::string();
    if (id_ > 0 && frame && frame->IsMain() && isSettingsURL(target)) {
      if (userGesture || !isPrivilegedChromeURL(target)) emit(id_, @"chrome-ui", ns(target));
      // Cancel either way.  A denied handoff must not fall back to loading the
      // page in the Alloy browser, which has no chrome:// bindings.
      return true;
    }
    return false;
  }
  bool OnOpenURLFromTab(CefRefPtr<CefBrowser>, CefRefPtr<CefFrame>,
                        const CefString& url, WindowOpenDisposition disposition,
                        bool userGesture) override {
    // Modified clicks use this callback, not OnBeforePopup.  Letting CEF's
    // default handler proceed would navigate the source browser instead.
    if (disposition != CEF_WOD_NEW_FOREGROUND_TAB &&
        disposition != CEF_WOD_NEW_BACKGROUND_TAB &&
        disposition != CEF_WOD_NEW_WINDOW && disposition != CEF_WOD_NEW_POPUP)
      return false;
    if (userGesture && !url.empty())
      emit(id_, disposition == CEF_WOD_NEW_BACKGROUND_TAB ? @"popup-background" : @"popup", ns(url.ToString()));
    return true;
  }
  void OnTitleChange(CefRefPtr<CefBrowser>, const CefString& title) override {
    emit(id_, @"title", ns(title.ToString()));
  }
  void OnAddressChange(CefRefPtr<CefBrowser>, CefRefPtr<CefFrame> frame,
                       const CefString& url) override {
    if (frame->IsMain()) emit(id_, @"url", ns(url.ToString()));
  }
  void OnLoadingStateChange(CefRefPtr<CefBrowser>, bool loading, bool, bool) override {
    emit(id_, @"loading", loading ? @"1" : @"0");
  }
  void OnLoadEnd(CefRefPtr<CefBrowser>, CefRefPtr<CefFrame> frame, int status) override {
    if (frame->IsMain() && status < 400) emit(id_, @"loaded");
  }
  void OnLoadError(CefRefPtr<CefBrowser>, CefRefPtr<CefFrame> frame,
                   ErrorCode code, const CefString& message, const CefString&) override {
    if (frame->IsMain() && code != ERR_ABORTED) emit(id_, @"error", ns(message.ToString()));
  }
  bool OnSetFocus(CefRefPtr<CefBrowser>, FocusSource source) override {
    // Loading in a background buffer must not steal the minibuffer's focus.
    return source == FOCUS_SOURCE_NAVIGATION;
  }
  void OnGotFocus(CefRefPtr<CefBrowser>) override { emit(id_, @"focus"); }
 private:
  const int id_;
  IMPLEMENT_REFCOUNTING(Client);
};

class SettingsClient final : public CefClient,
                             public CefLifeSpanHandler,
                             public CefDisplayHandler,
                             public CefFocusHandler {
 public:
  CefRefPtr<CefLifeSpanHandler> GetLifeSpanHandler() override { return this; }
  CefRefPtr<CefDisplayHandler> GetDisplayHandler() override { return this; }
  CefRefPtr<CefFocusHandler> GetFocusHandler() override { return this; }
  void OnAfterCreated(CefRefPtr<CefBrowser> browser) override {
    browsers[browser->GetIdentifier()] = browser;
    settingsBrowsers[browser->GetIdentifier()] = browser;
  }
  void OnBeforeClose(CefRefPtr<CefBrowser> browser) override {
    if (settingsBrowser && settingsBrowser->IsSame(browser)) {
      settingsTestObserver = nullptr;
      settingsBrowser = nullptr;
      settingsTitle.clear();
      // The native window may still be completing its close sequence.
      settingsClosing = settingsWindow != nullptr;
    }
    settingsBrowsers.erase(browser->GetIdentifier());
    browsers.erase(browser->GetIdentifier());
  }
  void OnTitleChange(CefRefPtr<CefBrowser> browser, const CefString& title) override {
    if (settingsBrowser && settingsBrowser->IsSame(browser)) {
      settingsTitle = title.ToString();
      if (settingsWindow) settingsWindow->SetTitle(title);
    }
  }
  bool OnSetFocus(CefRefPtr<CefBrowser>, FocusSource) override {
    return testMode;  // Disposable GUI probes must not take the user's keyboard.
  }
 private:
  IMPLEMENT_REFCOUNTING(SettingsClient);
};

// Extensions and Chrome toolbar actions may create browsers without an opener.
// Track these too, so they are closed before CefShutdown releases the profile.
CefRefPtr<CefClient> App::GetDefaultClient() { return new SettingsClient; }

class SettingsViewDelegate final : public CefBrowserViewDelegate {
 public:
  cef_runtime_style_t GetBrowserRuntimeStyle() override { return CEF_RUNTIME_STYLE_CHROME; }
  ChromeToolbarType GetChromeToolbarType(CefRefPtr<CefBrowserView>) override { return CEF_CTT_NORMAL; }
  void OnWindowChanged(CefRefPtr<CefView> view, bool added) override {
    if (!added) return;
    auto browserView = view->AsBrowserView();
    auto window = view->GetWindow();
    auto toolbar = browserView ? browserView->GetChromeToolbar() : nullptr;
    if (window && toolbar && !toolbar->GetParentView()) {
      window->AddChildViewAt(toolbar, 0);
      window->Layout();
    }
  }
 private:
  IMPLEMENT_REFCOUNTING(SettingsViewDelegate);
};

class SettingsWindowDelegate final : public CefWindowDelegate {
 public:
  explicit SettingsWindowDelegate(CefRefPtr<CefBrowserView> view) : view_(view) {}
  void OnWindowCreated(CefRefPtr<CefWindow> window) override {
    settingsWindow = window;
    window->SetTitle("Settings");
    CefBoxLayoutSettings layoutSettings;
    layoutSettings.horizontal = false;
    auto layout = window->SetToBoxLayout(layoutSettings);
    window->AddChildView(view_);
    layout->SetFlexForView(view_, 1);
    if (!testMode) window->Show();
  }
  void OnWindowClosing(CefRefPtr<CefWindow>) override { settingsClosing = true; }
  void OnWindowDestroyed(CefRefPtr<CefWindow> window) override {
    if (settingsWindow && settingsWindow->IsSame(window)) settingsWindow = nullptr;
    view_ = nullptr;
    settingsClosing = false;
  }
  bool CanClose(CefRefPtr<CefWindow>) override {
    // CEF Views coordinates native window destruction with WebContents close.
    auto browser = view_ ? view_->GetBrowser() : nullptr;
    return !browser || browser->GetHost()->TryCloseBrowser();
  }
  CefSize GetPreferredSize(CefRefPtr<CefView>) override { return CefSize(1000, 760); }
  cef_runtime_style_t GetWindowRuntimeStyle() override { return CEF_RUNTIME_STYLE_CHROME; }
 private:
  CefRefPtr<CefBrowserView> view_;
  IMPLEMENT_REFCOUNTING(SettingsWindowDelegate);
};

// Schemes and hosts are case-insensitive; Chromium lowercases them before
// navigating, so the matcher must too or uppercase input bypasses it.
std::string loweredAuthority(const std::string& url) {
  if (url.find("://") == std::string::npos) return url;
  std::string copy = url;
  const auto start = url.find("://") + 3;
  const auto end = url.find_first_of("/?#", start);
  const auto limit = end == std::string::npos ? copy.size() : end;
  std::transform(copy.begin(), copy.begin() + static_cast<std::ptrdiff_t>(limit), copy.begin(),
                 [](unsigned char c) { return static_cast<char>(std::tolower(c)); });
  return copy;
}
bool isPrivilegedChromeURL(const std::string& rawUrl) {
  const auto url = loweredAuthority(rawUrl);
  return url == "chrome://extensions" || url.starts_with("chrome://extensions/") ||
    url.starts_with("chrome://extensions?") || url.starts_with("chrome://extensions#") ||
    url == "chrome://password-manager" || url.starts_with("chrome://password-manager/") ||
    url.starts_with("chrome://password-manager?") || url.starts_with("chrome://password-manager#") ||
    url == "chrome://settings" || url.starts_with("chrome://settings/") ||
    url.starts_with("chrome://settings?") || url.starts_with("chrome://settings#");
}
bool isSettingsURL(const std::string& rawUrl) {
  const auto url = loweredAuthority(rawUrl);
  return isPrivilegedChromeURL(url) ||
    url == "https://chromewebstore.google.com" || url.starts_with("https://chromewebstore.google.com/") ||
    url.starts_with("https://chromewebstore.google.com?") || url.starts_with("https://chromewebstore.google.com#");
}
void openSettings(const std::string& requested) {
  const auto url = requested.empty() ? std::string("chrome://settings/") : requested;
  if (!isSettingsURL(url)) throw std::runtime_error("Expected a Chromium management or Chrome Web Store URL");
  if (settingsClosing) throw std::runtime_error("Settings window is closing; try again shortly");
  if (!settingsBrowser) {
    CefBrowserSettings settings;
    auto view = CefBrowserView::CreateBrowserView(new SettingsClient, url, settings,
      nullptr, CefRequestContext::GetGlobalContext(), new SettingsViewDelegate);
    if (!view) throw std::runtime_error("Could not create the Chrome settings view");
    CefWindow::CreateTopLevelWindow(new SettingsWindowDelegate(view));
    settingsBrowser = view->GetBrowser();
    if (!settingsBrowser || !settingsWindow) {
      if (settingsWindow) settingsWindow->Close();
      throw std::runtime_error("Could not create the Chrome settings window");
    }
  } else if (!requested.empty()) {
    // An explicit subpage navigates.  M-x chromel-settings merely raises the
    // existing window, preserving a search, dialog or unfinished edit.
    auto frame = mainFrame(settingsBrowser);
    if (!frame) throw std::runtime_error("The management window has no main frame");
    frame->LoadURL(url);
  }
  if (!testMode) {
    settingsWindow->Restore();
    settingsWindow->Show();
    settingsWindow->Activate();
    settingsBrowser->GetHost()->SetFocus(true);
  }
}
void closeSettings() {
  settingsClosing = settingsBrowser != nullptr || settingsWindow != nullptr;
  auto closing = settingsBrowsers;
  for (const auto& item : closing) item.second->GetHost()->CloseBrowser(true);
}

// Read-only inspection and page-driven preference changes in disposable tests.
// This observer is never installed outside CHROMEL_CEF_TEST_MODE.
class SettingsTestObserver final : public CefDevToolsMessageObserver {
 public:
  void OnDevToolsMethodResult(CefRefPtr<CefBrowser>, int, bool success,
                              const void* result, size_t size) override {
    settingsTestSuccess = success;
    settingsTestResult.assign(static_cast<const char*>(result), size);
  }
 private:
  IMPLEMENT_REFCOUNTING(SettingsTestObserver);
};

NSEvent* routeKeyEvent(NSEvent* event) {
  // Observe release even when Emacs owns focus.  Only a scroll command chosen
  // by the Lisp keymap can arm continuous scrolling in Emacs command mode.
  if (event.type == NSEventTypeKeyUp) {
    for (const auto& item : pages) {
      const auto& page = item.second;
      if (page->physicalKey && page->physicalCode == event.keyCode) {
        page->physicalKey = 0;
        stopScroll(page, false);
      }
    }
    return event;
  }
  if (event.type == NSEventTypeLeftMouseDown || event.type == NSEventTypeRightMouseDown ||
      event.type == NSEventTypeScrollWheel || event.type == NSEventTypeFlagsChanged) {
    for (const auto& item : pages) stopScroll(item.second);
    return event;
  }
  if (event.type != NSEventTypeKeyDown) return event;
  const auto flags = event.modifierFlags & NSEventModifierFlagDeviceIndependentFlagsMask;
  NSString* key = event.charactersIgnoringModifiers.lowercaseString;
  const bool plainScroll = !(flags & (NSEventModifierFlagControl | NSEventModifierFlagOption |
                                      NSEventModifierFlagCommand | NSEventModifierFlagShift)) &&
    ([key isEqualToString:@"j"] || [key isEqualToString:@"k"]);
  for (const auto& item : pages) {
    const auto& page = item.second;
    if (page->closing) continue;
    const bool eligible = event.window == page->container.window && !page->container.hidden &&
      (page->selected || ownsFocus(page));
    if (!eligible || !plainScroll) {
      stopScroll(page);
      continue;
    }
    if (page->physicalKey && page->physicalKey != [key characterAtIndex:0]) stopScroll(page);
    page->physicalKey = [key characterAtIndex:0];
    page->physicalCode = event.keyCode;
    if (event.isARepeat && page->scrollHeld) {
      auto frame = page->browser->GetFrameByIdentifier(page->scrollFrame);
      if (frame && frame->IsValid()) frame->ExecuteJavaScript("window.__emacsChromelScroller?.repeat();", "", 1);
      return nil;
    }
  }
  // Route before Emacs/Cocoa handles Escape as a fullscreen key equivalent.
  const bool prefix = (flags & NSEventModifierFlagControl) &&
    [@[@"x", @"c", @"h", @"g"] containsObject:key];
  const bool metaX = (flags & NSEventModifierFlagOption) && [key isEqualToString:@"x"];
  const bool escape = event.keyCode == 53 &&
    !(flags & (NSEventModifierFlagControl | NSEventModifierFlagOption |
               NSEventModifierFlagCommand | NSEventModifierFlagShift));
  if (prefix || metaX || escape) {
    for (const auto& item : pages) {
      const auto& page = item.second;
      if (page->closing || event.window != page->container.window) continue;
      const bool commandFocus = page->selected && !page->container.hidden;
      if (!ownsFocus(page) && !(escape && commandFocus)) continue;
      unfocus(page);
      if (escape) {
        // Deliver the same Control-g event as the physical shortcut.  Do not
        // let Cocoa/Chromium interpret Escape as a fullscreen-exit command.
        return [NSEvent keyEventWithType:NSEventTypeKeyDown location:event.locationInWindow
          modifierFlags:NSEventModifierFlagControl timestamp:event.timestamp
          windowNumber:event.windowNumber context:nil characters:@"\x07"
          charactersIgnoringModifiers:@"g" isARepeat:event.isARepeat keyCode:5];
      }
      break;
    }
  }
  return event;
}
}  // namespace

namespace chromel {
void initialize(const std::string& bundle, const std::string& profile) {
  checkThread();
  std::filesystem::create_directories(profile + "/Default");
  const auto canonicalProfile = std::filesystem::canonical(profile).string();
  testMode = getenv("CHROMEL_CEF_TEST_MODE") && std::string(getenv("CHROMEL_CEF_TEST_MODE")) == "1";
  if (testMode) {
    auto temp = std::filesystem::canonical(utf8(NSTemporaryDirectory())).string() + "/";
    if (canonicalProfile.compare(0, temp.size(), temp) != 0)
      throw std::runtime_error("CEF test mode requires a temporary profile under NSTemporaryDirectory");
  }
  if (stopped) throw std::runtime_error("CEF cannot be restarted in this Emacs process");
  if (initialized) {
    if (canonicalProfile != profilePath) throw std::runtime_error("Restart Emacs to change CEF profiles");
    return;
  }
  if (!NSApp) throw std::runtime_error("A running Cocoa application is required");
  const auto framework = bundle + "/Contents/Frameworks/Chromium Embedded Framework.framework";
  const auto helper = bundle + "/Contents/Frameworks/Chromel Helper.app/Contents/MacOS/Chromel Helper";
  if (![[NSFileManager defaultManager] isExecutableFileAtPath:ns(helper)])
    throw std::runtime_error("CEF helper missing; run scripts/build.sh");
  std::error_code bundleError, frameworkError;
  const auto mainBundle = std::filesystem::canonical(utf8(NSBundle.mainBundle.bundlePath), bundleError).string() + "/";
  const auto frameworkReal = std::filesystem::canonical(framework, frameworkError).string();
  if (bundleError || frameworkError)
    throw std::runtime_error("Cannot resolve the CEF framework path: " + (bundleError ? bundleError : frameworkError).message());
  if (frameworkReal.compare(0, mainBundle.size(), mainBundle) != 0)
    throw std::runtime_error("CEF sandbox requires its framework inside the running app bundle. Start Emacs with this plugin's scripts/launch.sh (the original Emacs.app is unchanged).");
  if (!cef_load_library((framework + "/Chromium Embedded Framework").c_str()))
    throw std::runtime_error("Unable to load the CEF framework");
  adaptApplication();
  for (NSString* name in @[NSApplicationDidResignActiveNotification, NSWindowDidResignKeyNotification]) {
    id token = [NSNotificationCenter.defaultCenter addObserverForName:name object:nil queue:nil
      usingBlock:^(NSNotification*) { for (const auto& item : pages) stopScroll(item.second); }];
    observers.push_back(token);
  }
  queue = [NSMutableArray array];
  windows = [NSMapTable strongToWeakObjectsMapTable];
  CefSettings settings;
  settings.command_line_args_disabled = true;
  // With the default macOS pump, CefDoMessageLoopWork can call [NSApp run]
  // when Emacs has temporarily stopped AppKit's loop.  Reentering EmacsApp.run
  // from a Lisp timer corrupts AppKit autorelease-pool lifetime.  The external
  // pump executes CEF tasks only; Emacs remains responsible for Cocoa events.
  // A non-null BrowserProcessHandler is required, or CEF falls back to the
  // default native pump even when external_message_pump is enabled.
  settings.external_message_pump = true;
  settings.persist_session_cookies = true;
  CefString(&settings.framework_dir_path) = framework;
  CefString(&settings.main_bundle_path) = bundle;
  CefString(&settings.browser_subprocess_path) = helper;
  CefString(&settings.root_cache_path) = canonicalProfile;
  CefString(&settings.cache_path) = canonicalProfile + "/Default";
  CefString(&settings.log_file) = canonicalProfile + "/cef.log";
  settings.log_severity = LOGSEVERITY_WARNING;
  // Keep the Chromium subprocess sandbox enabled.  Helpers initialize it
  // before loading the framework.  No --no-sandbox or certificate bypasses.
  std::string executable = utf8(NSBundle.mainBundle.executablePath);
  char* argv[] = {executable.data(), nullptr};
  CefMainArgs args(1, argv);
  bool success;
  {
    HostSignals preserveEmacsSignals;
    success = CefInitialize(args, settings, new App, nullptr);
  }
  if (!success) {
    stopped = true;
    // Nothing runs shutdown() after a failed start, so drain the observers
    // here instead of leaving them attached to a dead runtime.
    for (id token : observers) [NSNotificationCenter.defaultCenter removeObserver:token];
    observers.clear();
    throw std::runtime_error("CEF initialization failed; inspect the profile cef.log and restart Emacs");
  }
  profilePath = canonicalProfile;
  initialized = true;
  hostWakeup = std::make_unique<ChromelHostWakeup>();
}

long bind_window(const std::string& title) {
  requireReady();
  for (NSWindow* window in NSApp.windows) {
    if ([window.title isEqualToString:ns(title)]) {
      [windows setObject:window forKey:@(window.windowNumber)];
      return window.windowNumber;
    }
  }
  throw std::runtime_error("Cannot identify the Emacs NSWindow by its temporary title");
}

int api_version() { return kChromelApiVersion; }

bool is_settings_url(const std::string& url) { return isSettingsURL(url); }

int create(long handle, const std::string& url) {
  requireReady();
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
  CefRefPtr<Client> client(new Client(page->id));
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
  requireReady();
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
  requireReady();
  auto page = pageFor(id);
  unfocus(page);
  page->container.hidden = YES;
  page->selected = false;
}

void command(int id, const std::string& action, const std::string& argument) {
  requireReady();
  if (id == 0 && action == "settings") { openSettings(argument); return; }
  if (id == 0 && action == "close-settings") { closeSettings(); return; }
  if (id == 0 && action == "test-settings-close-window" && testMode) {
    if (!settingsBrowser) throw std::runtime_error("No settings window");
    NSView* view = (__bridge NSView*)settingsBrowser->GetHost()->GetWindowHandle();
    [view.window performClose:nil];
    return;
  }
  if (id == 0 && action == "test-settings-show" && testMode) {
    if (!settingsWindow) throw std::runtime_error("No management window");
    settingsWindow->Show();
    return;
  }
  if (id == 0 && action == "test-settings-script" && testMode) {
    if (!settingsBrowser) throw std::runtime_error("No settings window");
    if (!settingsTestObserver) settingsTestObserver =
      settingsBrowser->GetHost()->AddDevToolsMessageObserver(new SettingsTestObserver);
    settingsTestResult.clear();
    settingsTestSuccess = false;
    auto params = CefDictionaryValue::Create();
    params->SetString("expression", argument);
    params->SetBool("returnByValue", true);
    params->SetBool("awaitPromise", true);
    params->SetBool("userGesture", true);  // Simulate WebUI actions in disposable tests.
    settingsBrowser->GetHost()->ExecuteDevToolsMethod(0, "Runtime.evaluate", params);
    return;
  }
  auto page = pageFor(id);
  auto browser = page->browser;
  if (action == "navigate" || action == "reload" || action == "back" || action == "forward") stopScroll(page);
  if (action == "scroll-settings") {
    NSData* data = [ns(argument) dataUsingEncoding:NSUTF8StringEncoding];
    NSArray* values = [NSJSONSerialization JSONObjectWithData:data options:0 error:nil];
    if (![values isKindOfClass:NSArray.class] || values.count != 3)
      throw std::runtime_error("Invalid scroll settings");
    for (NSNumber* value in values) if (![value isKindOfClass:NSNumber.class] || [value doubleValue] < 0 ||
                                  [value doubleValue] > 10000000)
      throw std::runtime_error("Invalid scroll settings");
    page->scrollStep = [values[0] intValue];
    page->scrollDuration = [values[1] intValue];
    page->scrollSpeed = [values[2] intValue];
  }
  else if (action == "scroll") {
    NSData* data = [ns(argument) dataUsingEncoding:NSUTF8StringEncoding];
    NSDictionary* request = [NSJSONSerialization JSONObjectWithData:data options:0 error:nil];
    if (![request isKindOfClass:NSDictionary.class] ||
        ![request[@"amount"] isKindOfClass:NSNumber.class] ||
        ![request[@"duration"] isKindOfClass:NSNumber.class] ||
        ![request[@"speed"] isKindOfClass:NSNumber.class] ||
        ![request[@"held"] isKindOfClass:NSNumber.class] ||
        ![request[@"frame"] isKindOfClass:NSString.class] ||
        ![@[@"pixels", @"half", @"top", @"bottom"] containsObject:request[@"mode"]])
      throw std::runtime_error("Invalid scroll request");
    const double amount = [request[@"amount"] doubleValue];
    const double duration = [request[@"duration"] doubleValue], speed = [request[@"speed"] doubleValue];
    if (!std::isfinite(amount) || !std::isfinite(duration) || !std::isfinite(speed) ||
        duration < 0 || duration > 10000000 || speed < 0 || speed > 10000000)
      throw std::runtime_error("Invalid scroll values");
    auto frame = [request[@"frame"] length] ? browser->GetFrameByIdentifier(utf8(request[@"frame"])) : browser->GetFocusedFrame();
    if (!frame || !frame->IsValid()) frame = browser->GetMainFrame();
    scrollPage(page, frame, amount, duration, speed, utf8(request[@"mode"]), [request[@"held"] boolValue]);
  }
  else if (action == "navigate") {
    auto frame = mainFrame(browser);
    if (!frame) throw std::runtime_error("The browser has no main frame");
    frame->LoadURL(argument);
  }
  else if (action == "reload") browser->Reload();
  else if (action == "back") browser->GoBack();
  else if (action == "forward") browser->GoForward();
  else if (action == "stop") browser->StopLoad();
  else if (action == "find") {
    NSData* data = [ns(argument) dataUsingEncoding:NSUTF8StringEncoding];
    NSDictionary* request = [NSJSONSerialization JSONObjectWithData:data options:0 error:nil];
    if (![request isKindOfClass:NSDictionary.class] ||
        ![request[@"text"] isKindOfClass:NSString.class] ||
        ![request[@"token"] isKindOfClass:NSString.class] ||
        ![request[@"forward"] isKindOfClass:NSNumber.class] ||
        ![request[@"next"] isKindOfClass:NSNumber.class] ||
        [request[@"text"] length] == 0 || [request[@"token"] length] == 0)
      throw std::runtime_error("Invalid find request");
    if (!page->pendingFind.empty()) throw std::runtime_error("A search is already pending");
    // In this Chromium version false only counts/highlights; true also
    // selects a match.  Explicitly reset a new search, then select its match.
    if (![request[@"next"] boolValue]) browser->GetHost()->StopFinding(true);
    page->pendingFind = utf8(request[@"token"]);
    browser->GetHost()->Find(utf8(request[@"text"]), [request[@"forward"] boolValue], false, true);
  }
  else if (action == "find-stop") {
    page->pendingFind.clear();
    browser->GetHost()->StopFinding(true);
  }
  else if (action == "selected") {
    const bool selected = argument == "1";
    if (page->selected && !selected) stopScroll(page);
    page->selected = selected;
  }
  else if (action == "focus") browser->GetHost()->SetFocus(true);
  else if (action == "unfocus") unfocus(page);
  else if (action == "focus-parent") {
    auto current = browser->GetFocusedFrame();
    auto target = argument == "root" || !current ? browser->GetMainFrame() : current->GetParent();
    if (!target || !target->IsValid()) target = browser->GetMainFrame();
    if (current && current->IsValid())
      current->ExecuteJavaScript("window.__emacsChromelScroller?.reset();", "", 1);
    if (target && target->IsValid()) {
      target->ExecuteJavaScript(
        "(()=>{window.__emacsChromelScroller?.reset();"
        "let e=document.activeElement;while(e?.shadowRoot?.activeElement)e=e.shadowRoot.activeElement;"
        "window.focus();if(e?.matches('iframe,frame'))e.blur();})();", "", 1);
    }
    unfocus(page);
  }
  else if (action == "click") {
    NSData* data = [ns(argument) dataUsingEncoding:NSUTF8StringEncoding];
    NSDictionary* point = [NSJSONSerialization JSONObjectWithData:data options:0 error:nil];
    if (![point isKindOfClass:NSDictionary.class] ||
        ![point[@"x"] isKindOfClass:NSNumber.class] ||
        ![point[@"y"] isKindOfClass:NSNumber.class] ||
        ![point[@"newBuffer"] isKindOfClass:NSNumber.class])
      throw std::runtime_error("Invalid click coordinates");
    // DOM rectangles are CSS pixels, CEF input coordinates are view DIPs.
    const double zoom = std::pow(1.2, browser->GetHost()->GetZoomLevel());
    const double x = [point[@"x"] doubleValue] * zoom;
    const double y = [point[@"y"] doubleValue] * zoom;
    if (page->container.hidden || !std::isfinite(x) || !std::isfinite(y) ||
        x < 0 || y < 0 || x >= NSWidth(page->container.bounds) || y >= NSHeight(page->container.bounds))
      throw std::runtime_error("Hint target is outside the visible browser view");
    CefMouseEvent event;
    event.x = static_cast<int>(x);
    event.y = static_cast<int>(y);
    event.modifiers = [point[@"newBuffer"] boolValue] ? EVENTFLAG_COMMAND_DOWN : 0;
    if (event.modifiers && ![point[@"background"] boolValue]) event.modifiers |= EVENTFLAG_SHIFT_DOWN;
    // Hint clicks start in Emacs command mode.  Dispatching a Chromium mouse
    // event does not require giving the native view keyboard focus.  Editable
    // hint targets use the separate "focus" command instead.
    browser->GetHost()->SendMouseMoveEvent(event, false);
    browser->GetHost()->SendMouseClickEvent(event, MBT_LEFT, false, 1);
    browser->GetHost()->SendMouseClickEvent(event, MBT_LEFT, true, 1);
  }
  else if (action == "eval") {
    NSData* data = [ns(argument) dataUsingEncoding:NSUTF8StringEncoding];
    NSDictionary* request = [NSJSONSerialization JSONObjectWithData:data options:0 error:nil];
    if (![request isKindOfClass:NSDictionary.class] ||
        ![request[@"token"] isKindOfClass:NSString.class] ||
        ![request[@"script"] isKindOfClass:NSString.class])
      throw std::runtime_error("Invalid JavaScript request");
    page->pendingEval = utf8(request[@"token"]);
    auto frame = mainFrame(browser);
    if (!frame) {
      page->pendingEval.clear();
      throw std::runtime_error("The browser has no main frame");
    }
    auto message = CefProcessMessage::Create("chromel.eval");
    message->GetArgumentList()->SetString(0, page->pendingEval);
    message->GetArgumentList()->SetString(1, utf8(request[@"script"]));
    frame->SendProcessMessage(PID_RENDERER, message);
  }
  else if (action == "javascript") {
    // Fire-and-forget channel for Lisp callers that need no reply; the reply
    // path above is the only one that can report success.  Elisp gates this
    // action behind `chromel-allow-raw-javascript'.
    auto frame = mainFrame(browser);
    if (!frame) throw std::runtime_error("The browser has no main frame");
    frame->ExecuteJavaScript(argument, "", 1);
  }
  else if (action == "javascript-focused") {
    // Route through CEF, not top.document: focused subframes may be cross-origin
    // and hosted in a different renderer.  Releasing Cocoa keyboard focus does
    // not change Chromium's focused frame.
    auto frame = browser->GetFocusedFrame();
    if (!frame || !frame->IsValid()) frame = browser->GetMainFrame();
    if (frame && frame->IsValid()) frame->ExecuteJavaScript(argument, "", 1);
  }
  else if (action == "javascript-frame") {
    NSData* data = [ns(argument) dataUsingEncoding:NSUTF8StringEncoding];
    NSDictionary* request = [NSJSONSerialization JSONObjectWithData:data options:0 error:nil];
    if (![request isKindOfClass:NSDictionary.class] ||
        ![request[@"frame"] isKindOfClass:NSString.class] ||
        ![request[@"script"] isKindOfClass:NSString.class])
      throw std::runtime_error("Invalid frame script request");
    auto frame = browser->GetFrameByIdentifier(utf8(request[@"frame"]));
    if (frame && frame->IsValid()) frame->ExecuteJavaScript(utf8(request[@"script"]), "", 1);
  }
  else if ((action == "test-key-down" || action == "test-key-repeat" || action == "test-key-up" ||
            action == "test-command-down" || action == "test-command-up") && testMode) {
    if (argument != "j" && argument != "k") throw std::runtime_error("Unsupported held test key");
    const bool up = action == "test-key-up" || action == "test-command-up";
    NSEvent* event = [NSEvent keyEventWithType:up ? NSEventTypeKeyUp : NSEventTypeKeyDown
      location:NSZeroPoint modifierFlags:0 timestamp:NSProcessInfo.processInfo.systemUptime
      windowNumber:page->container.window.windowNumber context:nil characters:ns(argument)
      charactersIgnoringModifiers:ns(argument) isARepeat:action == "test-key-repeat" keyCode:argument == "j" ? 38 : 40];
    if (action == "test-command-down" || action == "test-command-up") routeKeyEvent(event);
    else [NSApp sendEvent:event];
  }
  else if (action == "test-key" && testMode) {
    if (argument != "j" && argument != "k" && argument != "escape") throw std::runtime_error("Unsupported test key");
    // Exercise real Cocoa -> CEF keyboard dispatch, not the Lisp scroll command.
    NSString* characters = argument == "escape" ? @"\x1b" : ns(argument);
    for (auto type : {NSEventTypeKeyDown, NSEventTypeKeyUp}) {
      NSEvent* event = [NSEvent keyEventWithType:type location:NSZeroPoint modifierFlags:0
        timestamp:NSProcessInfo.processInfo.systemUptime windowNumber:page->container.window.windowNumber
        context:nil characters:characters charactersIgnoringModifiers:characters
        isARepeat:NO keyCode:argument == "escape" ? 53 : (argument == "j" ? 38 : 40)];
      if (argument == "escape") {
        // A real Escape arrives in an active app whose window is key.  Posted
        // events to a background app are dropped at random, so make the test
        // window key first instead of depending on the user's click order.
        NSWindow* target = page->container.window;
        if (!target) throw std::runtime_error("Test key needs a window");
        [NSApp activateIgnoringOtherApps:YES];
        [target makeKeyAndOrderFront:nil];
        [NSApp postEvent:event atStart:NO];
      }
      else [NSApp sendEvent:event];
    }
  }
  else if (action == "devtools") {
    CefWindowInfo wi;
    CefBrowserSettings settings;
    browser->GetHost()->ShowDevTools(wi, new Client(0), settings, CefPoint());
  } else if (action == "close") {
    unfocus(page);
    page->closing = true;
    page->container.hidden = YES;
    browser->GetHost()->CloseBrowser(true);
  } else throw std::runtime_error("Unknown browser action");
}

void pump() {
  requireReady();
  if (pumping) return;
  FlagGuard guard(pumping);
  CefDoMessageLoopWork();
}
std::string events() {
  requireReady();
  NSData* data = [NSJSONSerialization dataWithJSONObject:queue options:0 error:nil];
  [queue removeAllObjects];
  if (!data) return "[]";
  return std::string((const char*)data.bytes, data.length);
}
std::string info() {
  requireReady();
  return "CEF " CEF_VERSION "\nRuntime: Alloy (native child NSView)\nMessage pump: external (Emacs timer)\nSandbox: renderer helpers only (native/helper.cc initializes cef_sandbox; the Emacs host process is unsandboxed)\nPages: " +
    std::to_string(pages.size()) + "\nBrowsers including DevTools: " +
    std::to_string(browsers.size()) + "\nSettings browsers: " +
    std::to_string(settingsBrowsers.size()) + "\nSettings windows: " +
    std::to_string(settingsWindow ? 1 : 0) + "\nKeychain: " +
    (testMode ? "mock (disposable tests only)" : "system") + "\nProfile: " + profilePath;
}
std::string inspect(int id) {
  requireReady();
  if (id == 0) {
    NSView* view = settingsBrowser ? (__bridge NSView*)settingsBrowser->GetHost()->GetWindowHandle() : nil;
    auto frame = mainFrame(settingsBrowser);
    NSDictionary* state = @{@"count": @(settingsBrowsers.size()),
      @"closing": @(settingsClosing), @"windowAlive": @(settingsWindow != nullptr),
      @"id": @(settingsBrowser ? settingsBrowser->GetIdentifier() : 0),
      @"chrome": @(settingsBrowser && settingsBrowser->GetHost()->GetRuntimeStyle() == CEF_RUNTIME_STYLE_CHROME),
      @"sharedContext": @(settingsBrowser && settingsBrowser->GetHost()->GetRequestContext()->IsSame(CefRequestContext::GetGlobalContext())),
      @"url": frame ? ns(frame->GetURL().ToString()) : @"",
      @"title": ns(settingsTitle), @"window": @(view.window.windowNumber),
      @"testResult": testMode ? ns(settingsTestResult) : @"",
      @"testSuccess": @(testMode && settingsTestSuccess)};
    NSData* payload = [NSJSONSerialization dataWithJSONObject:state options:0 error:nil];
    if (!payload) return "{}";
    return std::string(static_cast<const char*>(payload.bytes), payload.length);
  }
  auto page = pageFor(id);
  NSRect rect = page->container.frame;
  NSView* host = page->host;
  double top = host.isFlipped ? rect.origin.y : NSHeight(host.bounds) - NSMaxY(rect);
  auto focusedFrame = page->browser->GetFocusedFrame();
  NSDictionary* state = @{@"x": @(rect.origin.x), @"y": @(top),
    @"width": @(rect.size.width), @"height": @(rect.size.height),
    @"window": @(page->container.window.windowNumber),
    @"hidden": @(page->container.hidden), @"focused": @(ownsFocus(page)),
    @"focusedFrameName": focusedFrame ? ns(focusedFrame->GetName().ToString()) : @"",
    @"hostClass": NSStringFromClass(host.class) ?: @"detached"};
  NSData* geometry = [NSJSONSerialization dataWithJSONObject:state options:0 error:nil];
  if (!geometry) return "{}";
  return std::string((const char*)geometry.bytes, geometry.length);
}
void shutdown() {
  checkThread();
  if (!initialized || stopped) return;
  hostWakeup.reset();
  for (id token : observers) [NSNotificationCenter.defaultCenter removeObserver:token];
  observers.clear();
  // Copy: CloseBrowser may synchronously modify the live map.
  auto closing = browsers;
  for (const auto& item : closing) item.second->GetHost()->CloseBrowser(true);
  closing.clear();
  // Pump CEF directly.  Running AppKit's loop here would re-enter EmacsApp.run
  // from inside kill-emacs and corrupt AppKit's autorelease-pool lifetime.
  const auto deadline = [NSDate dateWithTimeIntervalSinceNow:3.0];
  while ((!browsers.empty() || settingsWindow) && deadline.timeIntervalSinceNow > 0) {
    @autoreleasepool {
      CefDoMessageLoopWork();
    }
    [NSThread sleepForTimeInterval:0.005];
  }
  const bool clean = browsers.empty() && !settingsWindow;
  const size_t remaining = browsers.size();
  // Drop plugin state on both paths: a stuck renderer must not leave the maps
  // pointing at Emacs objects that are about to be freed.
  pages.clear();
  browsers.clear();
  settingsBrowsers.clear();
  settingsBrowser = nullptr;
  settingsWindow = nullptr;
  [windows removeAllObjects];
  // Calling CefShutdown with live browsers can crash.  On process exit the OS
  // will reclaim a stuck renderer; keep the framework loaded in that case.
  if (clean) {
    CefShutdown();
  } else {
    NSLog(@"Chromel: skipping CefShutdown because %zu browsers or a settings window did not close", remaining);
  }
  stopped = true;
}
}  // namespace chromel

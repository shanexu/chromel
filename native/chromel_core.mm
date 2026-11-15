// SPDX-License-Identifier: GPL-3.0-or-later
#import <Cocoa/Cocoa.h>
#import <objc/runtime.h>
#include "chromel_core.h"
#include "page.h"
#include "settings.h"
#include "chromel_scripts.h"
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
#include <functional>
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
// Chrome-style settings windows share the global request context, but never
// enter the embedded Page map or its view/focus/lifecycle handling.
NSMutableArray<NSDictionary*>* queue;
bool initialized = false;
bool stopped = false;
bool pumping = false;
// Set by CEF (from any thread) when it wants the message loop pumped, cleared
// before each pump.  It is the difference between "20 ms because a frame is
// due" and "250 ms because nothing is happening".
std::atomic<bool> pumpPending{false};
std::unique_ptr<ChromelHostWakeup> hostWakeup;
std::string profilePath;
// Three separate promises that used to share one flag.  Naming them keeps the
// production paths honest: "we are a test process" is not the same statement as
// "do not show or focus windows" or "do not touch the real Keychain".
struct TestSwitches {
  bool enabled = false;      // CHROMEL_CEF_TEST_MODE=1: test-only commands exist
  bool quietDesktop = false; // CHROMEL_CEF_TEST_QUIET: no Show/Activate/focus
  bool hermetic = false;     // CHROMEL_CEF_TEST_HERMETIC: mock keychain, temp profile
};
TestSwitches testSwitches;

bool envFlag(const char* name) {
  const char* value = getenv(name);
  return value && std::string(value) == "1";
}

// Test commands are not merely useless in production, they must be unreachable.
void requireTestSwitches(const char* action) {
  if (!testSwitches.enabled) throw std::runtime_error(std::string("Unknown browser action: ") + action);
}
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
// page.mm lives in another translation unit; it can still ask the same
// question without duplicating the message or the state it reads.
void requireReady() { requireBackendReady(); }
void emit(int id, NSString* type, NSString* value = @"") {
  if (!id) return;
  // Every callback used here is delivered on the CEF UI (Cocoa main) thread.
  [queue addObject:@{@"id": @(id), @"type": type, @"value": value ?: @""}];
}
// CEF may hand out a null or detached main frame while a page is tearing down.
// Every caller must tolerate that instead of dereferencing it.
CefRefPtr<CefFrame> mainFrame(const CefRefPtr<CefBrowser>& browser) {
  if (!browser) return nullptr;
  auto frame = browser->GetMainFrame();
  return frame && frame->IsValid() ? frame : nullptr;
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
  void OnScheduleMessagePumpWork(int64_t delayMs) override {
    // CEF telling us when it wants the loop pumped.  A negative delay means
    // "nothing scheduled", anything else means "work is due (or due soon)".
    // This callback can run on ANY thread: only touch the atomic and hand the
    // pump itself to the main queue, never call Lisp, Cocoa, or CEF here.
    pumpPending = delayMs >= 0;
    // The pump itself stays on the elisp timer: pumping from here as well made
    // frames arrive in pairs and `gui-hold' measured uneven velocity.
  }
  void OnBeforeCommandLineProcessing(const CefString& processType,
                                     CefRefPtr<CefCommandLine> commandLine) override {
    // Test-only Chromium facility: never ask the user's Keychain to authorize
    // disposable, repeatedly re-signed test apps.  Production uses Keychain.
    if (testSwitches.hermetic && processType.empty()) {
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


// Chromium's DevTools window is a browser of its own: it has no Emacs buffer and
// no entry in `pages`.  It still needs a client so the browser registry stays
// honest (shutdown and the "Browsers including DevTools" count) and so links the
// user clicks inside the inspector can leave the window instead of dying.
class DevToolsClient final : public CefClient,
                             public CefLifeSpanHandler,
                             public CefRequestHandler {
 public:
  explicit DevToolsClient(int owner) : owner_(owner) {}
  CefRefPtr<CefLifeSpanHandler> GetLifeSpanHandler() override { return this; }
  CefRefPtr<CefRequestHandler> GetRequestHandler() override { return this; }
  void OnAfterCreated(CefRefPtr<CefBrowser> browser) override {
    CEF_REQUIRE_UI_THREAD();
    browsers[browser->GetIdentifier()] = browser;
  }
  void OnBeforeClose(CefRefPtr<CefBrowser> browser) override {
    CEF_REQUIRE_UI_THREAD();
    // OnAfterCreated owns this entry; nothing in `pages` ever did.
    browsers.erase(browser->GetIdentifier());
  }
  bool OnBeforePopup(CefRefPtr<CefBrowser>, CefRefPtr<CefFrame>, int,
                     const CefString& url, const CefString&, WindowOpenDisposition disposition,
                     bool userGesture, const CefPopupFeatures&, CefWindowInfo&,
                     CefRefPtr<CefClient>&, CefBrowserSettings&,
                     CefRefPtr<CefDictionaryValue>&, bool*) override {
    // Attribute the popup to the inspected page so the new tab opens where that
    // page lives and keeps its session.  Everything else DevTools reports
    // (title, URL, focus) belongs to the inspector, not the page, and is dropped.
    if (userGesture && !url.empty() && owner_ > 0)
      emit(owner_, disposition == CEF_WOD_NEW_BACKGROUND_TAB ? @"popup-background" : @"popup",
           ns(url.ToString()));
    return true;
  }

 private:
  const int owner_;
  IMPLEMENT_REFCOUNTING(DevToolsClient);
};

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


// Read-only inspection and page-driven preference changes in disposable tests.
// This observer is never installed outside CHROMEL_CEF_TEST_MODE.

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

bool quietDesktopMode() { return testSwitches.quietDesktop; }
bool testSwitchesEnabled() { return testSwitches.enabled; }

void requireBackendReady() {
  checkThread();
  if (!initialized || stopped) throw std::runtime_error("CEF is not running");
}

// The elisp side only ever needs a CefClient, so page.mm asks for one by id
// instead of including this translation unit's private Client class.
CefRefPtr<CefClient> makePageClient(int id) { return new Client(id); }
CefRefPtr<CefClient> App::GetDefaultClient() { return makeSettingsClient(); }



namespace chromel {
void initialize(const std::string& bundle, const std::string& profile) {
  checkThread();
  std::filesystem::create_directories(profile + "/Default");
  const auto canonicalProfile = std::filesystem::canonical(profile).string();
  testSwitches.enabled = envFlag("CHROMEL_CEF_TEST_MODE");
  // Both promises default to whatever the mode says; the explicit variables let
  // a run watch its windows (QUIET=0) or keep the real Keychain (HERMETIC=0).
  testSwitches.quietDesktop = getenv("CHROMEL_CEF_TEST_QUIET") ? envFlag("CHROMEL_CEF_TEST_QUIET")
                                                              : testSwitches.enabled;
  testSwitches.hermetic = getenv("CHROMEL_CEF_TEST_HERMETIC") ? envFlag("CHROMEL_CEF_TEST_HERMETIC")
                                                             : testSwitches.enabled;
  if (testSwitches.hermetic) {
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
// Reads the bookkeeping maps only, so Elisp can ask "is anything still alive?"
// before CEF is up (and while it is shutting down) without tripping requireReady.
int browser_count() {
  return static_cast<int>(browsers.size() + settingsBrowserCount());
}

bool is_settings_url(const std::string& url) { return isSettingsURL(url); }

std::string hints_script() { return kChromelHintsSource; }

std::string bundle_path() {
  @autoreleasepool { return utf8(NSBundle.mainBundle.bundlePath); }
}


namespace {

// Every browser action lives in one table: the dispatcher stops being a chain
// of string comparisons, and the name of an action is the name of the code that
// implements it.  Bodies are the same code as before, moved not rewritten.
using BrowserAction = std::function<void(const std::shared_ptr<Page>&, const std::string&)>;
using SettingsAction = std::function<void(const std::string&)>;

// Settings windows belong to no page; Lisp addresses them as browser 0.
const std::map<std::string, SettingsAction>& settingsActions() {
  static const std::map<std::string, SettingsAction> table = {
    {"settings", [](const std::string& argument) { openSettings(argument); }},
    {"close-settings", [](const std::string&) { closeSettings(); }},
    {"test-settings-close-window", [](const std::string&) {
      requireTestSwitches("test-settings-close-window");
      closeSettingsWindow();
    }},
    {"test-settings-show", [](const std::string&) {
      requireTestSwitches("test-settings-show");
      showSettingsWindow();
    }},
    {"test-settings-script", [](const std::string& argument) {
      requireTestSwitches("test-settings-script");
      runSettingsScript(argument);
    }},
  };
  return table;
}

// The held-key family shares one body; the action name selects which edge of
// the key press is synthesized and whether Cocoa or Emacs sees it.
void sendHeldTestKey(const std::shared_ptr<Page>& page, const std::string& action, const std::string& argument) {
  requireTestSwitches("test key");
  if (argument != "j" && argument != "k") throw std::runtime_error("Unsupported held test key");
  const bool up = action == "test-key-up" || action == "test-command-up";
  NSEvent* event = [NSEvent keyEventWithType:up ? NSEventTypeKeyUp : NSEventTypeKeyDown
    location:NSZeroPoint modifierFlags:0 timestamp:NSProcessInfo.processInfo.systemUptime
    windowNumber:page->container.window.windowNumber context:nil characters:ns(argument)
    charactersIgnoringModifiers:ns(argument) isARepeat:action == "test-key-repeat"
    keyCode:argument == "j" ? 38 : 40];
  if (action == "test-command-down" || action == "test-command-up") routeKeyEvent(event);
  else [NSApp sendEvent:event];
}

const std::map<std::string, BrowserAction>& browserActions() {
  static const std::map<std::string, BrowserAction> table = {
    {"scroll-settings", [](const std::shared_ptr<Page>& page, const std::string& argument) {
      NSData* data = [ns(argument) dataUsingEncoding:NSUTF8StringEncoding];
      NSArray* values = [NSJSONSerialization JSONObjectWithData:data options:0 error:nil];
      if (![values isKindOfClass:NSArray.class] || values.count != 3)
        throw std::runtime_error("Invalid scroll settings");
      for (NSNumber* value in values)
        if (![value isKindOfClass:NSNumber.class] || [value doubleValue] < 0 ||
            [value doubleValue] > 10000000)
          throw std::runtime_error("Invalid scroll settings");
      page->scrollStep = [values[0] intValue];
      page->scrollDuration = [values[1] intValue];
      page->scrollSpeed = [values[2] intValue];
    }},
    {"scroll", [](const std::shared_ptr<Page>& page, const std::string& argument) {
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
      const double duration = [request[@"duration"] doubleValue];
      const double speed = [request[@"speed"] doubleValue];
      if (!std::isfinite(amount) || !std::isfinite(duration) || !std::isfinite(speed) ||
          duration < 0 || duration > 10000000 || speed < 0 || speed > 10000000)
        throw std::runtime_error("Invalid scroll values");
      auto browser = page->browser;
      auto frame = [request[@"frame"] length] ? browser->GetFrameByIdentifier(utf8(request[@"frame"]))
                                             : browser->GetFocusedFrame();
      if (!frame || !frame->IsValid()) frame = browser->GetMainFrame();
      scrollPage(page, frame, amount, duration, speed, utf8(request[@"mode"]), [request[@"held"] boolValue]);
    }},
    {"navigate", [](const std::shared_ptr<Page>& page, const std::string& argument) {
      auto frame = mainFrame(page->browser);
      if (!frame) throw std::runtime_error("The browser has no main frame");
      frame->LoadURL(argument);
    }},
    {"reload", [](const std::shared_ptr<Page>& page, const std::string&) { page->browser->Reload(); }},
    {"back", [](const std::shared_ptr<Page>& page, const std::string&) { page->browser->GoBack(); }},
    {"forward", [](const std::shared_ptr<Page>& page, const std::string&) { page->browser->GoForward(); }},
    {"stop", [](const std::shared_ptr<Page>& page, const std::string&) { page->browser->StopLoad(); }},
    {"find", [](const std::shared_ptr<Page>& page, const std::string& argument) {
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
      auto browser = page->browser;
      // In this Chromium version false only counts/highlights; true also
      // selects a match.  Explicitly reset a new search, then select its match.
      if (![request[@"next"] boolValue]) browser->GetHost()->StopFinding(true);
      page->pendingFind = utf8(request[@"token"]);
      browser->GetHost()->Find(utf8(request[@"text"]), [request[@"forward"] boolValue], false, true);
    }},
    {"find-stop", [](const std::shared_ptr<Page>& page, const std::string&) {
      page->pendingFind.clear();
      page->browser->GetHost()->StopFinding(true);
    }},
    {"selected", [](const std::shared_ptr<Page>& page, const std::string& argument) {
      const bool selected = argument == "1";
      if (page->selected && !selected) stopScroll(page);
      page->selected = selected;
    }},
    {"focus", [](const std::shared_ptr<Page>& page, const std::string&) { page->browser->GetHost()->SetFocus(true); }},
    {"unfocus", [](const std::shared_ptr<Page>& page, const std::string&) { unfocus(page); }},
    {"focus-parent", [](const std::shared_ptr<Page>& page, const std::string& argument) {
      auto browser = page->browser;
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
    }},
    {"click", [](const std::shared_ptr<Page>& page, const std::string& argument) {
      NSData* data = [ns(argument) dataUsingEncoding:NSUTF8StringEncoding];
      NSDictionary* point = [NSJSONSerialization JSONObjectWithData:data options:0 error:nil];
      if (![point isKindOfClass:NSDictionary.class] ||
          ![point[@"x"] isKindOfClass:NSNumber.class] ||
          ![point[@"y"] isKindOfClass:NSNumber.class] ||
          ![point[@"newBuffer"] isKindOfClass:NSNumber.class])
        throw std::runtime_error("Invalid click coordinates");
      auto browser = page->browser;
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
    }},
    {"eval", [](const std::shared_ptr<Page>& page, const std::string& argument) {
      NSData* data = [ns(argument) dataUsingEncoding:NSUTF8StringEncoding];
      NSDictionary* request = [NSJSONSerialization JSONObjectWithData:data options:0 error:nil];
      if (![request isKindOfClass:NSDictionary.class] ||
          ![request[@"token"] isKindOfClass:NSString.class] ||
          ![request[@"script"] isKindOfClass:NSString.class])
        throw std::runtime_error("Invalid JavaScript request");
      page->pendingEval = utf8(request[@"token"]);
      auto frame = mainFrame(page->browser);
      if (!frame) {
        page->pendingEval.clear();
        throw std::runtime_error("The browser has no main frame");
      }
      auto message = CefProcessMessage::Create("chromel.eval");
      message->GetArgumentList()->SetString(0, page->pendingEval);
      message->GetArgumentList()->SetString(1, utf8(request[@"script"]));
      frame->SendProcessMessage(PID_RENDERER, message);
    }},
    {"javascript", [](const std::shared_ptr<Page>& page, const std::string& argument) {
      // Fire-and-forget channel for Lisp callers that need no reply; the reply
      // path above is the only one that can report success.  Elisp gates this
      // action behind `chromel-allow-raw-javascript'.
      auto frame = mainFrame(page->browser);
      if (!frame) throw std::runtime_error("The browser has no main frame");
      frame->ExecuteJavaScript(argument, "", 1);
    }},
    {"javascript-focused", [](const std::shared_ptr<Page>& page, const std::string& argument) {
      // Route through CEF, not top.document: focused subframes may be
      // cross-origin and hosted in a different renderer.  Releasing Cocoa
      // keyboard focus does not change Chromium's focused frame.
      auto browser = page->browser;
      auto frame = browser->GetFocusedFrame();
      if (!frame || !frame->IsValid()) frame = browser->GetMainFrame();
      if (frame && frame->IsValid()) frame->ExecuteJavaScript(argument, "", 1);
    }},
    {"javascript-frame", [](const std::shared_ptr<Page>& page, const std::string& argument) {
      NSData* data = [ns(argument) dataUsingEncoding:NSUTF8StringEncoding];
      NSDictionary* request = [NSJSONSerialization JSONObjectWithData:data options:0 error:nil];
      if (![request isKindOfClass:NSDictionary.class] ||
          ![request[@"frame"] isKindOfClass:NSString.class] ||
          ![request[@"script"] isKindOfClass:NSString.class])
        throw std::runtime_error("Invalid frame script request");
      auto frame = page->browser->GetFrameByIdentifier(utf8(request[@"frame"]));
      if (frame && frame->IsValid()) frame->ExecuteJavaScript(utf8(request[@"script"]), "", 1);
    }},
    {"test-key-down", [](const std::shared_ptr<Page>& page, const std::string& argument) {
      sendHeldTestKey(page, "test-key-down", argument);
    }},
    {"test-key-repeat", [](const std::shared_ptr<Page>& page, const std::string& argument) {
      sendHeldTestKey(page, "test-key-repeat", argument);
    }},
    {"test-key-up", [](const std::shared_ptr<Page>& page, const std::string& argument) {
      sendHeldTestKey(page, "test-key-up", argument);
    }},
    {"test-command-down", [](const std::shared_ptr<Page>& page, const std::string& argument) {
      sendHeldTestKey(page, "test-command-down", argument);
    }},
    {"test-command-up", [](const std::shared_ptr<Page>& page, const std::string& argument) {
      sendHeldTestKey(page, "test-command-up", argument);
    }},
    {"test-key", [](const std::shared_ptr<Page>& page, const std::string& argument) {
      requireTestSwitches("test-key");
      if (argument != "j" && argument != "k" && argument != "escape")
        throw std::runtime_error("Unsupported test key");
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
    }},
    {"devtools", [](const std::shared_ptr<Page>& page, const std::string&) {
      CefWindowInfo wi;
      CefBrowserSettings settings;
      page->browser->GetHost()->ShowDevTools(wi, new DevToolsClient((int)page->id), settings, CefPoint());
    }},
    {"close", [](const std::shared_ptr<Page>& page, const std::string&) {
      unfocus(page);
      page->closing = true;
      page->container.hidden = YES;
      page->browser->GetHost()->CloseBrowser(true);
    }},
  };
  return table;
}

}  // namespace

void command(int id, const std::string& action, const std::string& argument) {
  requireReady();
  if (id == 0) {
    const auto& settings = settingsActions();
    const auto entry = settings.find(action);
    if (entry == settings.end()) throw std::runtime_error("Unknown browser action: " + action);
    entry->second(argument);
    return;
  }
  auto page = pageFor(id);
  // Navigation drops any in-flight scroll before the document changes.
  if (action == "navigate" || action == "reload" || action == "back" || action == "forward")
    stopScroll(page);
  const auto& table = browserActions();
  const auto entry = table.find(action);
  if (entry == table.end()) throw std::runtime_error("Unknown browser action: " + action);
  entry->second(page, argument);
}

void pump() {
  requireReady();
  if (pumping) return;
  FlagGuard guard(pumping);
  // Clear before pumping: CEF re-arms during the call when another frame is
  // due, and clearing afterwards would throw that request away.
  pumpPending = false;
  CefDoMessageLoopWork();
}
bool pump_pending() {
  if (pumpPending.load()) return true;
  // CEF does not schedule a pump for renderer-driven animation frames: a JS
  // scroll keeps its own clock inside the renderer.  While one of our scroll
  // animations is live we ask for the fast rate ourselves, or the page moves in
  // 250 ms bursts and keeps drifting after the key is released.
  for (const auto& item : pages)
    if (!item.second->scrollFrame.empty()) return true;
  // A settings window is a full Chrome UI with its own animations.
  if (settingsWindowOpen()) return true;
  return false;
}
std::string events() {
  requireReady();
  // An idle tick has nothing to report; skip the JSON round trip entirely.
  if (queue.count == 0) return "[]";
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
    std::to_string(settingsBrowserCount()) + "\nSettings windows: " +
    std::to_string(settingsWindowOpen() ? 1 : 0) + "\nKeychain: " +
    (testSwitches.hermetic ? "mock (disposable tests only)" : "system") + "\nProfile: " + profilePath +
    "\nTest switches: mode=" + (testSwitches.enabled ? "1" : "0") +
    " quiet=" + (testSwitches.quietDesktop ? "1" : "0") +
    " hermetic=" + (testSwitches.hermetic ? "1" : "0");
}
std::string inspect(int id) {
  requireReady();
  if (id == 0) return inspectSettings();
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
  while ((!browsers.empty() || settingsWindowOpen()) && deadline.timeIntervalSinceNow > 0) {
    @autoreleasepool {
      CefDoMessageLoopWork();
    }
    [NSThread sleepForTimeInterval:0.005];
  }
  const bool clean = browsers.empty() && !settingsWindowOpen();
  const size_t remaining = browsers.size();
  // Drop plugin state on both paths: a stuck renderer must not leave the maps
  // pointing at Emacs objects that are about to be freed.
  pages.clear();
  browsers.clear();
  resetSettingsState();
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

// SPDX-License-Identifier: GPL-3.0-or-later
#import <Cocoa/Cocoa.h>
#include "settings.h"
#include "page.h"
#include <algorithm>
#include <cctype>
#include <map>
#include <stdexcept>
#include <string>
#include "include/cef_browser.h"
#include "include/cef_client.h"
#include "include/cef_devtools_message_observer.h"
#include "include/views/cef_box_layout.h"
#include "include/views/cef_browser_view.h"
#include "include/views/cef_window.h"

// The management window is a small Chrome instance of its own: a Chrome-style
// browser view inside a Chrome-style top-level window, sharing the global
// request context so its cookies and settings match the embedded pages.
// Nothing here knows about Page; it only needs the shared browser registry so
// shutdown can see every live renderer.
namespace {

CefRefPtr<CefBrowser> settingsBrowser;
CefRefPtr<CefWindow> settingsWindow;
std::map<int, CefRefPtr<CefBrowser>> settingsBrowsers;
std::string settingsTitle;
bool settingsClosing = false;
CefRefPtr<CefRegistration> settingsTestObserver;
std::string settingsTestResult;
bool settingsTestSuccess = false;

// CEF may hand out a null or detached main frame while a page is tearing down.
CefRefPtr<CefFrame> mainFrameOf(const CefRefPtr<CefBrowser>& browser) {
  if (!browser) return nullptr;
  auto frame = browser->GetMainFrame();
  return frame && frame->IsValid() ? frame : nullptr;
}

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
    // Disposable GUI probes must not take the user's keyboard.
    return quietDesktopMode();
  }
 private:
  IMPLEMENT_REFCOUNTING(SettingsClient);
};

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
    if (!quietDesktopMode()) window->Show();
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

}  // namespace

// Kept public: the navigation gate in chromel_core.mm asks the same question.
bool isPrivilegedChromeURL(const std::string& rawUrl) {
  const auto url = loweredAuthority(rawUrl);
  return url == "chrome://extensions" || url.starts_with("chrome://extensions/") ||
    url.starts_with("chrome://extensions?") || url.starts_with("chrome://extensions#") ||
    url == "chrome://password-manager" || url.starts_with("chrome://password-manager/") ||
    url.starts_with("chrome://password-manager?") || url.starts_with("chrome://password-manager#") ||
    url == "chrome://settings" || url.starts_with("chrome://settings/") ||
    url.starts_with("chrome://settings?") || url.starts_with("chrome://settings#");
}

CefRefPtr<CefClient> makeSettingsClient() { return new SettingsClient; }

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
      // Close whatever was born, or the leftover browser keeps the whole
      // registry non-empty and the next call dereferences a null window.
      if (settingsWindow) settingsWindow->Close();
      if (settingsBrowser) settingsBrowser->GetHost()->CloseBrowser(true);
      settingsWindow = nullptr;
      settingsBrowser = nullptr;
      throw std::runtime_error("Could not create the Chrome settings window");
    }
  } else if (!requested.empty()) {
    // An explicit subpage navigates.  M-x chromel-settings merely raises the
    // existing window, preserving a search, dialog or unfinished edit.
    auto frame = mainFrameOf(settingsBrowser);
    if (!frame) throw std::runtime_error("The management window has no main frame");
    frame->LoadURL(url);
  }
  if (!quietDesktopMode()) {
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

bool settingsWindowOpen() { return static_cast<bool>(settingsWindow); }
int settingsBrowserCount() { return static_cast<int>(settingsBrowsers.size()); }

void showSettingsWindow() {
  if (!settingsWindow) throw std::runtime_error("No management window");
  settingsWindow->Show();
}

void closeSettingsWindow() {
  if (!settingsBrowser) throw std::runtime_error("No settings window");
  NSView* view = (__bridge NSView*)settingsBrowser->GetHost()->GetWindowHandle();
  [view.window performClose:nil];
}

void runSettingsScript(const std::string& source) {
  if (!settingsBrowser) throw std::runtime_error("No settings window");
  if (!settingsTestObserver) settingsTestObserver =
    settingsBrowser->GetHost()->AddDevToolsMessageObserver(new SettingsTestObserver);
  settingsTestResult.clear();
  settingsTestSuccess = false;
  auto params = CefDictionaryValue::Create();
  params->SetString("expression", source);
  params->SetBool("returnByValue", true);
  params->SetBool("awaitPromise", true);
  // Simulate WebUI actions in disposable tests.
  params->SetBool("userGesture", true);
  settingsBrowser->GetHost()->ExecuteDevToolsMethod(0, "Runtime.evaluate", params);
}

void resetSettingsState() {
  settingsBrowsers.clear();
  settingsBrowser = nullptr;
  settingsWindow = nullptr;
  settingsTitle.clear();
  settingsClosing = false;
  settingsTestObserver = nullptr;
  settingsTestResult.clear();
  settingsTestSuccess = false;
}

bool settingsTestPassed() { return settingsTestSuccess; }
std::string settingsTestPayload() { return settingsTestResult; }

std::string inspectSettings() {
  NSView* view = settingsBrowser ? (__bridge NSView*)settingsBrowser->GetHost()->GetWindowHandle() : nil;
  auto frame = mainFrameOf(settingsBrowser);
  NSDictionary* state = @{@"count": @(settingsBrowsers.size()),
    @"closing": @(settingsClosing), @"windowAlive": @(settingsWindow != nullptr),
    @"id": @(settingsBrowser ? settingsBrowser->GetIdentifier() : 0),
    @"chrome": @(settingsBrowser && settingsBrowser->GetHost()->GetRuntimeStyle() == CEF_RUNTIME_STYLE_CHROME),
    @"sharedContext": @(settingsBrowser && settingsBrowser->GetHost()->GetRequestContext()->IsSame(CefRequestContext::GetGlobalContext())),
    @"url": frame ? [NSString stringWithUTF8String:frame->GetURL().ToString().c_str()] : @"",
    @"title": [NSString stringWithUTF8String:settingsTitle.c_str()] ?: @"",
    @"window": @(view.window.windowNumber),
    @"testResult": testSwitchesEnabled() ? [NSString stringWithUTF8String:settingsTestResult.c_str()] ?: @"" : @"",
    @"testSuccess": @(testSwitchesEnabled() && settingsTestSuccess)};
  NSData* payload = [NSJSONSerialization dataWithJSONObject:state options:0 error:nil];
  if (!payload) return "{}";
  return std::string(static_cast<const char*>(payload.bytes), payload.length);
}

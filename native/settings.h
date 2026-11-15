// SPDX-License-Identifier: GPL-3.0-or-later
#pragma once
#include <string>
#include "include/cef_client.h"

// The Chrome management window (settings, password manager, extensions, Web
// Store).  It is a separate Chrome instance from the embedded pages, so it has
// its own state and its own file; the orchestrator only starts and stops it.
CefRefPtr<CefClient> makeSettingsClient();
bool isSettingsURL(const std::string& url);
// chrome://extensions | password-manager | settings only (not the Web Store).
bool isPrivilegedChromeURL(const std::string& url);
void openSettings(const std::string& requested);
void closeSettings();
// Called from shutdown() after the deadline loop, on both paths.
void resetSettingsState();

// Answered by the orchestrator: test switches and desktop-quieting policy live
// with the rest of the test plumbing in chromel_core.mm.
bool quietDesktopMode();
bool testSwitchesEnabled();

bool settingsWindowOpen();
int settingsBrowserCount();
std::string inspectSettings();
void showSettingsWindow();
void closeSettingsWindow();
void runSettingsScript(const std::string& source);
bool settingsTestPassed();
std::string settingsTestPayload();

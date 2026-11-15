// SPDX-License-Identifier: GPL-3.0-or-later
#import <Cocoa/Cocoa.h>
#include "blocklist.h"
#include "chromel_core.h"
#include <chrono>
#include <cstdio>
#include <stdexcept>
#include <string>

// Measures the matcher alone: no CEF, no browser, no network.  Kept next to the
// smoke test because both need the sandboxed bundle to run at all.
static int bench(const std::string& path, int samples) {
  if (samples <= 0) {
    fprintf(stderr, "need a positive sample count\n");
    return 2;
  }
  chromel::load_blocklist(path);
  const auto start = std::chrono::steady_clock::now();
  int blocked = 0;
  for (int i = 0; i < samples; ++i) {
    const std::string url = "http://ads.example.com/" + std::to_string(i) + "/x.js";
    if (chromel::blocklist_blocks(url, 3, "https://news.example.org/")) ++blocked;
  }
  const auto elapsed = std::chrono::duration<double, std::micro>(
                           std::chrono::steady_clock::now() - start)
                           .count();
  printf("mean=%.2f us samples=%d blocked=%d %s\n", elapsed / samples, samples, blocked,
         chromel::blocklist_summary().c_str());
  return 0;
}

static void step() {
 @autoreleasepool {
  chromel::pump();
  [[NSRunLoop currentRunLoop] runMode:NSDefaultRunLoopMode
                         beforeDate:[NSDate dateWithTimeIntervalSinceNow:0.01]];
  NSEvent* event;
  while ((event = [NSApp nextEventMatchingMask:NSEventMaskAny
                                   untilDate:[NSDate distantPast]
                                      inMode:NSDefaultRunLoopMode dequeue:YES])) {
    [NSApp sendEvent:event];
  }
 }
}

int main(int argc, char** argv) {
  setvbuf(stdout, nullptr, _IONBF, 0);
  if (argc == 4 && std::string(argv[1]) == "--blocklist-bench") {
    return bench(argv[2], atoi(argv[3]));
  }
  if (argc != 3 || std::string(argv[1]) != "--smoke-test") {
    fprintf(stderr,
            "This bundle hosts CEF for Emacs.\nUsage: %s --smoke-test TEMP_PROFILE"
            "\n       %s --blocklist-bench FILE SAMPLES\n",
            argv[0], argv[0]);
    return 2;
  }
  setenv("CHROMEL_CEF_TEST_MODE", "1", 1);
  @autoreleasepool {
    try {
      [NSApplication sharedApplication];
      [NSApp setActivationPolicy:NSApplicationActivationPolicyRegular];
      NSWindow* first = [[NSWindow alloc] initWithContentRect:NSMakeRect(100, 100, 800, 600)
          styleMask:NSWindowStyleMaskTitled | NSWindowStyleMaskResizable
          backing:NSBackingStoreBuffered defer:NO];
      first.title = @"Chromel native smoke";
      [first makeKeyAndOrderFront:nil];
      [NSApp finishLaunching];
      long handle;
      int id;
      @autoreleasepool {
      chromel::initialize(NSBundle.mainBundle.bundlePath.UTF8String, argv[2]);
      handle = chromel::bind_window("Chromel native smoke");
      id = chromel::create(handle,
          "data:text/html,<meta charset=utf-8><title>chromel-smoke-ready</title>"
          "<body style='background:%23273846;color:white;font:32px sans-serif'>"
          "CEF inside a native NSView<input placeholder='Keyboard test'></body>");
      chromel::layout(id, handle, 20, 40, 600, 400);
      }
      bool loaded = false, title = false;
      NSDate* deadline = [NSDate dateWithTimeIntervalSinceNow:30];
      while (deadline.timeIntervalSinceNow > 0 && !(loaded && title)) {
        step();
        auto events = chromel::events();
        if (events != "[]") printf("%s\n", events.c_str());
        loaded |= events.find("loaded") != std::string::npos;
        title |= events.find("chromel-smoke-ready") != std::string::npos;
      }
      if (!loaded || !title) throw std::runtime_error("Timed out waiting for renderer/title/load callbacks");
      @autoreleasepool { chromel::hide(id); }
      NSWindow* second;
      @autoreleasepool {
      second = [[NSWindow alloc] initWithContentRect:NSMakeRect(200, 200, 600, 450)
          styleMask:NSWindowStyleMaskTitled backing:NSBackingStoreBuffered defer:NO];
      second.title = @"Chromel second host";
      [second makeKeyAndOrderFront:nil];
        chromel::layout(id, chromel::bind_window("Chromel second host"), 10, 20, 500, 350);
      }
      for (int i = 0; i < 20; ++i) step();
      @autoreleasepool { chromel::command(id, "close", ""); }
      bool closed = false;
      deadline = [NSDate dateWithTimeIntervalSinceNow:10];
      while (deadline.timeIntervalSinceNow > 0 && !closed) {
        step();
        auto events = chromel::events();
        closed = events.find("closed") != std::string::npos;
      }
      if (!closed) throw std::runtime_error("Browser did not close cleanly");
      if (!first.visible || !second.visible) throw std::runtime_error("Closing browser closed a host window");
      printf("%s\n", chromel::info().c_str());
      chromel::shutdown();
      puts("PASS: renderer, navigation, layout, cross-window reparenting, hide, close, shutdown");
      return 0;
    } catch (const std::exception& error) {
      fprintf(stderr, "FAIL: %s\n", error.what());
      chromel::shutdown();
      return 1;
    }
  }
}

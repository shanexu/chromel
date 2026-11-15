// SPDX-License-Identifier: GPL-3.0-or-later
#include "events.h"

namespace {

// Events are dictionaries rather than a struct so the JSON shape stays in one
// place: {id, type, value}, drained and serialized as an array.
NSMutableArray<NSDictionary*>* eventQueue = nil;

}  // namespace

void resetEvents() { eventQueue = [NSMutableArray array]; }

void emit(int id, NSString* type, NSString* value) {
  if (!id) return;
  if (!eventQueue) resetEvents();
  // Every callback used here is delivered on the CEF UI (Cocoa main) thread.
  [eventQueue addObject:@{@"id": @(id), @"type": type, @"value": value ?: @""}];
}

std::string drainEvents() {
  // An idle tick has nothing to report; skip the JSON round trip entirely.
  if (eventQueue.count == 0) return "[]";
  NSData* data = [NSJSONSerialization dataWithJSONObject:eventQueue options:0 error:nil];
  [eventQueue removeAllObjects];
  if (!data) return "[]";
  return std::string((const char*)data.bytes, data.length);
}

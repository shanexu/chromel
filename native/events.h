// SPDX-License-Identifier: GPL-3.0-or-later
#pragma once
#import <Foundation/Foundation.h>
#include <string>

// Every CEF callback reports through here; the elisp timer drains it once per
// pump.  Both halves are main-thread only, so the queue needs no lock -- but it
// does need to live in one place, which is this file.
void emit(int id, NSString* type, NSString* value = @"");
std::string drainEvents();
void resetEvents();

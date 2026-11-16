#pragma once

#include <string>

namespace chromel {

// Reads the cosmetics snapshot at `path` and swaps it in.  Throws
// std::runtime_error when the file cannot be read.  UI thread.
void load_cosmetics(const std::string& path);

bool cosmetics_loaded();

// "hosts=<hosts with rules> injected=<frames styled since the load>"
std::string cosmetics_summary();

// Stylesheet for a frame that loaded `url`: the site-independent rules plus the
// ones for the page's host (and its parents).  Empty when nothing matches.
// Safe to call from the UI thread while another swap is in flight.
std::string cosmetics_css(const std::string& url);

// JavaScript that installs `css` as a single <style> element.  Doubles as the
// idempotent re-injection path for pages that load more content later.
std::string cosmetics_script(const std::string& css);

void cosmetics_count_injection();

}  // namespace chromel

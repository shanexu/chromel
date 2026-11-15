#pragma once

#include <string>

namespace chromel {

// Reads the blocklist snapshot at `path` and swaps it in.  Throws
// std::runtime_error when the file cannot be read, so the caller hears about a
// broken configuration instead of silently browsing unfiltered.  UI thread.
void load_blocklist(const std::string& path);

bool blocklist_loaded();

// "rules=<loaded rules> blocked=<requests cancelled since the load>"
std::string blocklist_summary();

// True when `url` matches a block rule and no allow rule or exception wins.
// Safe to call from the IO thread while another thread swaps the list.
bool blocklist_blocks(const std::string& url, int resource_type,
                      const std::string& initiator);

// Newline separated host suffixes that are never blocked (the user's "turn the
// blocker off on this site" list).  UI thread.
void set_blocklist_exceptions(const std::string& newline_separated);

}  // namespace chromel

#include "cosmetics.h"

#include "blocklist.h"

#import <Foundation/Foundation.h>

#include <atomic>
#include <fstream>
#include <memory>
#include <string>
#include <unordered_map>
#include <vector>

namespace chromel {
namespace {

struct Tables {
  std::string generic;
  std::unordered_map<std::string, std::string> host;
};

// Replaced whole, never mutated: the UI thread loads while any thread reads.
std::shared_ptr<const Tables> tables;
std::atomic<unsigned long> injectedTotal{0};

std::shared_ptr<const Tables> current() { return std::atomic_load(&tables); }

}  // namespace

void load_cosmetics(const std::string& path) {
  std::ifstream input(path);
  if (!input) throw std::runtime_error("Cannot open cosmetics: " + path);
  auto next = std::make_shared<Tables>();
  std::string line;
  while (std::getline(input, line)) {
    if (line.empty() || line[0] == '#') continue;
    std::vector<std::string> fields;
    size_t start = 0;
    while (true) {
      const size_t tab = line.find('\t', start);
      fields.push_back(line.substr(start, tab == std::string::npos ? std::string::npos : tab - start));
      if (tab == std::string::npos) break;
      start = tab + 1;
    }
    if (fields[0] == "g" && fields.size() >= 2) {
      next->generic = fields[1];
    } else if (fields[0] == "h" && fields.size() >= 3 && !fields[2].empty()) {
      next->host[fields[1]] = fields[2];
    }
  }
  std::atomic_store(&tables, std::shared_ptr<const Tables>(next));
}

bool cosmetics_loaded() { return current() != nullptr; }

std::string cosmetics_summary() {
  const auto loaded = current();
  if (!loaded) return "hosts=0 injected=0";
  return "hosts=" + std::to_string(loaded->host.size()) +
         " injected=" + std::to_string(injectedTotal.load());
}

std::string cosmetics_css(const std::string& url) {
  const auto loaded = current();
  if (!loaded) return {};
  std::string css = loaded->generic;
  std::string candidate = url_host(url);
  while (!candidate.empty()) {
    const auto found = loaded->host.find(candidate);
    if (found != loaded->host.end()) {
      if (!css.empty()) css += ";";
      css += found->second;
      break;
    }
    const size_t dot = candidate.find('.');
    if (dot == std::string::npos) break;
    candidate = candidate.substr(dot + 1);
  }
  return css;
}

std::string cosmetics_script(const std::string& css) {
  // One rule per selector: CSS drops the *whole* rule when any selector in a
  // comma list is unparsable, and uBOL's lists do contain selectors this
  // Chromium cannot parse.
  std::string sheet;
  size_t start = 0;
  while (start <= css.size()) {
    const size_t end = css.find(';', start);
    const std::string selector = css.substr(start, end == std::string::npos ? std::string::npos : end - start);
    if (!selector.empty()) sheet += selector + "{display:none!important}";
    if (end == std::string::npos) break;
    start = end + 1;
  }
  if (sheet.empty()) return {};
  NSArray* wrapper = @[ [NSString stringWithUTF8String:sheet.c_str()] ?: @"" ];
  NSData* json = [NSJSONSerialization dataWithJSONObject:wrapper options:0 error:nil];
  if (json == nil) return {};
  const std::string body(static_cast<const char*>(json.bytes), json.length);
  // body is `["css"]`; keep the literal including its quotes.
  const std::string literal = body.size() >= 2 ? body.substr(1, body.size() - 2) : "\"\"";
  return "(()=>{var s=document.getElementById('chromel-cosmetics');"
         "if(!s){s=document.createElement('style');s.id='chromel-cosmetics';"
         "(document.head||document.documentElement).appendChild(s);}"
         "s.textContent=" + literal + ";})()";
}

void cosmetics_count_injection() { injectedTotal.fetch_add(1); }

}  // namespace chromel

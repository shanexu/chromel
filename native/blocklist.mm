#include "blocklist.h"

#include <atomic>
#include <cstdlib>
#include <cctype>
#include <fstream>
#include <memory>
#include <mutex>
#include <sstream>
#include <stdexcept>
#include <unordered_map>
#include <unordered_set>
#include <vector>

namespace chromel {
namespace {

struct Rule {
  unsigned types = 0;
  bool allow = false;
  std::string initiator;
};

struct Tables {
  std::unordered_map<std::string, std::vector<Rule>> host;
  size_t rules = 0;
};

std::shared_ptr<const Tables> tables;
std::shared_ptr<const std::unordered_set<std::string>> exceptions;
std::atomic<unsigned long> blockedTotal{0};
std::mutex swapMutex;

std::string lower(std::string text) {
  for (char& ch : text) ch = static_cast<char>(std::tolower(static_cast<unsigned char>(ch)));
  return text;
}

std::string host_of(const std::string& url) {
  const size_t scheme = url.find("://");
  if (scheme == std::string::npos) return {};
  const size_t start = scheme + 3;
  size_t end = url.find_first_of("/?#", start);
  std::string authority = url.substr(start, end == std::string::npos ? std::string::npos : end - start);
  const size_t at = authority.rfind('@');
  if (at != std::string::npos) authority = authority.substr(at + 1);
  if (!authority.empty() && authority[0] == '[') {
    const size_t close = authority.find(']');
    if (close == std::string::npos) return {};
    authority = authority.substr(1, close - 1);
  } else {
    const size_t colon = authority.find(':');
    if (colon != std::string::npos) authority = authority.substr(0, colon);
  }
  while (!authority.empty() && authority.back() == '.') authority.pop_back();
  return lower(authority);
}

bool suffix_matches(const std::string& host, const std::string& suffix) {
  if (host == suffix) return true;
  if (host.size() <= suffix.size()) return false;
  return host.compare(host.size() - suffix.size(), suffix.size(), suffix) == 0 &&
         host[host.size() - suffix.size() - 1] == '.';
}

bool suffix_in(const std::unordered_set<std::string>& set, const std::string& host) {
  std::string candidate = host;
  while (!candidate.empty()) {
    if (set.count(candidate)) return true;
    const size_t dot = candidate.find('.');
    if (dot == std::string::npos) break;
    candidate = candidate.substr(dot + 1);
  }
  return false;
}

unsigned type_bit(int resource_type) {
  switch (resource_type) {
    case 0:
      return 1u << 0;  // RT_MAIN_FRAME
    case 1:
      return 1u << 1;  // RT_SUB_FRAME
    case 2:
      return 1u << 2;  // RT_STYLESHEET
    case 3:
      return 1u << 3;  // RT_SCRIPT
    case 4:
      return 1u << 4;  // RT_IMAGE
    case 5:
      return 1u << 5;  // RT_FONT_RESOURCE
    case 7:
      return 1u << 6;  // RT_OBJECT
    case 13:
      return 1u << 7;  // RT_XHR
    case 14:
      return 1u << 8;  // RT_PING
    case 8:
      return 1u << 9;  // RT_MEDIA
    default:
      return 1u << 11;  // "other": workers, websockets, prefetch, favicons
  }
}

bool rule_applies(const Rule& rule, unsigned bit, const std::string& initiatorHost) {
  if (rule.types && !(rule.types & bit)) return false;
  if (!rule.initiator.empty() && !suffix_matches(initiatorHost, rule.initiator)) return false;
  return true;
}

enum class Verdict { none, allow, block };

// Walks the host's suffixes twice: first for allow rules, then for block rules.
// A matching allow anywhere wins, which is the order the filter lists expect.
// The two passes must be distinguishable: collapsing them into one bool makes
// an allow rule look exactly like a block rule, which blocks allowed hosts.
Verdict verdict(const Tables& loaded, const std::string& host, const std::string& initiatorHost,
                unsigned bit) {
  for (int pass = 0; pass < 2; ++pass) {
    const bool wantAllow = pass == 0;
    std::string suffix = host;
    while (!suffix.empty()) {
      const auto found = loaded.host.find(suffix);
      if (found != loaded.host.end()) {
        for (const Rule& rule : found->second) {
          if (rule.allow != wantAllow) continue;
          if (!rule_applies(rule, bit, initiatorHost)) continue;
          return wantAllow ? Verdict::allow : Verdict::block;
        }
      }
      const size_t dot = suffix.find('.');
      if (dot == std::string::npos) break;
      suffix = suffix.substr(dot + 1);
    }
  }
  return Verdict::none;
}

std::shared_ptr<const Tables> current() { return std::atomic_load(&tables); }

std::shared_ptr<const std::unordered_set<std::string>> currentExceptions() {
  return std::atomic_load(&exceptions);
}

}  // namespace

void load_blocklist(const std::string& path) {
  std::ifstream input(path);
  if (!input) throw std::runtime_error("Cannot open blocklist: " + path);

  auto next = std::make_shared<Tables>();
  std::string line;
  while (std::getline(input, line)) {
    if (line.empty() || line[0] == '#') continue;
    std::vector<std::string> fields;
    std::string field;
    std::istringstream stream(line);
    while (std::getline(stream, field, '\t')) fields.push_back(field);
    if (fields.size() < 4) continue;

    Rule rule;
    if (fields[0] == "b") {
      rule.allow = false;
    } else if (fields[0] == "a") {
      rule.allow = true;
    } else {
      continue;
    }
    rule.types = static_cast<unsigned>(std::strtoul(fields[1].c_str(), nullptr, 16));

    std::istringstream spec(fields[3]);
    std::string token;
    std::string host;
    while (std::getline(spec, token, ';')) {
      if (token.rfind("h=", 0) == 0) {
        host = token.substr(2);
      } else if (token.rfind("i=", 0) == 0) {
        rule.initiator = token.substr(2);
      } else if (!token.empty()) {
        host.clear();  // an unknown marker: skip the whole rule
        break;
      }
    }
    if (host.empty()) continue;
    next->host[host].push_back(rule);
    ++next->rules;
  }

  {
    std::lock_guard<std::mutex> guard(swapMutex);
    std::atomic_store(&tables, std::shared_ptr<const Tables>(next));
    blockedTotal.store(0, std::memory_order_relaxed);
  }
}

bool blocklist_loaded() { return current() != nullptr; }

std::string blocklist_summary() {
  const auto loaded = current();
  std::ostringstream text;
  text << "rules=" << (loaded ? loaded->rules : 0) << " blocked="
       << blockedTotal.load(std::memory_order_relaxed);
  return text.str();
}

void set_blocklist_exceptions(const std::string& newline_separated) {
  auto next = std::make_shared<std::unordered_set<std::string>>();
  std::istringstream lines(newline_separated);
  std::string line;
  while (std::getline(lines, line)) {
    while (!line.empty() && (line.back() == '\r' || line.back() == ' ')) line.pop_back();
    if (!line.empty()) next->insert(lower(line));
  }
  std::lock_guard<std::mutex> guard(swapMutex);
  std::atomic_store(&exceptions, std::shared_ptr<const std::unordered_set<std::string>>(next));
}

bool blocklist_blocks(const std::string& url, int resource_type, const std::string& initiator) {
  const auto loaded = current();
  if (!loaded) return false;
  const std::string host = host_of(url);
  if (host.empty()) return false;
  const std::string initiatorHost = host_of(initiator);
  if (!initiatorHost.empty()) {
    const auto off = currentExceptions();
    if (off && suffix_in(*off, initiatorHost)) return false;
  }
  if (verdict(*loaded, host, initiatorHost, type_bit(resource_type)) != Verdict::block) {
    return false;
  }
  blockedTotal.fetch_add(1, std::memory_order_relaxed);
  return true;
}

std::string url_host(const std::string& url) { return host_of(url); }

}  // namespace chromel

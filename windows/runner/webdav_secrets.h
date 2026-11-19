#ifndef RUNNER_WEBDAV_SECRETS_H_
#define RUNNER_WEBDAV_SECRETS_H_

#include <cstddef>
#include <cstdint>
#include <optional>
#include <vector>

namespace webdav_secrets {

inline constexpr std::size_t kMaxInputBytes = 1024 * 1024;

// Current-user DPAPI, with no UI. Empty or oversized input and any DPAPI failure
// return nullopt. Output is also bounded so every protected blob can be passed
// back to Unprotect; DPAPI overhead reduces the maximum plaintext size slightly.
std::optional<std::vector<uint8_t>> Protect(
    const std::vector<uint8_t>& plaintext);
std::optional<std::vector<uint8_t>> Unprotect(
    const std::vector<uint8_t>& ciphertext);

}  // namespace webdav_secrets

#endif  // RUNNER_WEBDAV_SECRETS_H_

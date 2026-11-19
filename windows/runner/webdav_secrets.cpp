#include "webdav_secrets.h"

#include <windows.h>
#include <wincrypt.h>

namespace webdav_secrets {
namespace {

// DPAPI allocates with LocalAlloc. Erase the temporary buffer before releasing
// it, including when copying the decrypted bytes out fails.
struct DpapiBuffer {
  DATA_BLOB blob = {};

  DpapiBuffer() = default;
  DpapiBuffer(const DpapiBuffer&) = delete;
  DpapiBuffer& operator=(const DpapiBuffer&) = delete;

  ~DpapiBuffer() {
    if (blob.pbData != nullptr) {
      ::SecureZeroMemory(blob.pbData, blob.cbData);
      ::LocalFree(blob.pbData);
    }
  }
};

std::optional<std::vector<uint8_t>> Transform(
    const std::vector<uint8_t>& bytes, bool protect) {
  if (bytes.empty() || bytes.size() > kMaxInputBytes) {
    return std::nullopt;
  }

  // DPAPI takes a mutable pointer but does not modify the input blob.
  DATA_BLOB input = {static_cast<DWORD>(bytes.size()),
                     const_cast<BYTE*>(bytes.data())};
  DpapiBuffer output;
  // Deliberately omit CRYPTPROTECT_LOCAL_MACHINE: only the current Windows
  // user's DPAPI context may decrypt saved credentials. Never prompt for UI.
  const BOOL ok = protect
                      ? ::CryptProtectData(&input, nullptr, nullptr, nullptr,
                                           nullptr, CRYPTPROTECT_UI_FORBIDDEN,
                                           &output.blob)
                      : ::CryptUnprotectData(&input, nullptr, nullptr, nullptr,
                                             nullptr, CRYPTPROTECT_UI_FORBIDDEN,
                                             &output.blob);
  if (!ok || output.blob.pbData == nullptr || output.blob.cbData == 0 ||
      output.blob.cbData > kMaxInputBytes) {
    return std::nullopt;
  }
  return std::vector<uint8_t>(output.blob.pbData,
                              output.blob.pbData + output.blob.cbData);
}

}  // namespace

std::optional<std::vector<uint8_t>> Protect(
    const std::vector<uint8_t>& plaintext) {
  return Transform(plaintext, true);
}

std::optional<std::vector<uint8_t>> Unprotect(
    const std::vector<uint8_t>& ciphertext) {
  return Transform(ciphertext, false);
}

}  // namespace webdav_secrets

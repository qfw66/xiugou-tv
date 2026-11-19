#include "webdav_secrets_channel.h"

#include <flutter/standard_method_codec.h>

#include <utility>
#include <variant>

#include "webdav_secrets.h"

std::unique_ptr<flutter::MethodChannel<flutter::EncodableValue>>
RegisterWebDavSecretsChannel(flutter::BinaryMessenger* messenger) {
  auto channel = std::make_unique<flutter::MethodChannel<flutter::EncodableValue>>(
      messenger, "xiugou/webdav_secrets",
      &flutter::StandardMethodCodec::GetInstance());
  channel->SetMethodCallHandler(
      [](const flutter::MethodCall<flutter::EncodableValue>& call,
         std::unique_ptr<flutter::MethodResult<flutter::EncodableValue>> result) {
        const bool protect = call.method_name() == "protect";
        if (!protect && call.method_name() != "unprotect") {
          result->NotImplemented();
          return;
        }

        const auto* args = call.arguments();
        const auto* bytes =
            args ? std::get_if<std::vector<uint8_t>>(args) : nullptr;
        if (!bytes || bytes->empty() ||
            bytes->size() > webdav_secrets::kMaxInputBytes) {
          result->Error("bad_args", "Expected non-empty bytes of at most 1 MiB.");
          return;
        }

        auto output = protect ? webdav_secrets::Protect(*bytes)
                              : webdav_secrets::Unprotect(*bytes);
        if (!output) {
          result->Error(protect ? "protect_failed" : "unprotect_failed",
                        "Unable to process saved credentials.");
          return;
        }
        result->Success(flutter::EncodableValue(std::move(*output)));
      });
  return channel;
}

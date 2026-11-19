#ifndef RUNNER_WEBDAV_SECRETS_CHANNEL_H_
#define RUNNER_WEBDAV_SECRETS_CHANNEL_H_

#include <flutter/binary_messenger.h>
#include <flutter/encodable_value.h>
#include <flutter/method_channel.h>

#include <memory>

// "xiugou/webdav_secrets": protect/unprotect take and return Uint8List.
// Invalid arguments use bad_args; DPAPI failures use protect_failed or
// unprotect_failed with generic messages and no error details.
std::unique_ptr<flutter::MethodChannel<flutter::EncodableValue>>
RegisterWebDavSecretsChannel(flutter::BinaryMessenger* messenger);

#endif  // RUNNER_WEBDAV_SECRETS_CHANNEL_H_

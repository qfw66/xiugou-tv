#ifndef RUNNER_NATIVE_PLAYBACK_CHANNEL_H_
#define RUNNER_NATIVE_PLAYBACK_CHANNEL_H_

#include <flutter/method_channel.h>
#include <flutter_windows.h>

#include <memory>

namespace native_playback {

class PlaybackChannel {
 public:
  PlaybackChannel(flutter::BinaryMessenger* messenger, FlutterDesktopPluginRegistrarRef registrar,
                  HWND runner);
  ~PlaybackChannel();
  PlaybackChannel(const PlaybackChannel&) = delete;
  PlaybackChannel& operator=(const PlaybackChannel&) = delete;
  bool HandleTimer(WPARAM id);

 private:
  struct State;
  std::shared_ptr<State> state_;
  flutter::MethodChannel<flutter::EncodableValue> channel_;
};

}  // namespace native_playback
#endif  // RUNNER_NATIVE_PLAYBACK_CHANNEL_H_

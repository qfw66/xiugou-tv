#ifndef RUNNER_NATIVE_PLAYBACK_TEXTURE_H_
#define RUNNER_NATIVE_PLAYBACK_TEXTURE_H_

#include <flutter_texture_registrar.h>

#include <memory>

#include "native_playback_backend.h"

namespace native_playback {

// The platform thread owns the producer; Flutter only sees completed frames.
class PlaybackTexture final : public VideoOutput {
 public:
  static std::unique_ptr<PlaybackTexture> Register(FlutterDesktopTextureRegistrarRef registrar);
  ~PlaybackTexture() override;
  bool CreateDevice(IDXGIAdapter* adapter);
  ID3D11Device* Device() const override;
  ID3D11DeviceContext* Context() const override;
  ID3D11Texture2D* Target(int width, int height) override;
  bool Present() override;

  bool PublishReady();
  int64_t id() const { return id_; }
  int width() const { return width_; }
  int height() const { return height_; }
  bool pending() const;
  void Unregister();

 private:
  explicit PlaybackTexture(FlutterDesktopTextureRegistrarRef registrar);
  struct Impl;
  std::unique_ptr<Impl> impl_;
  FlutterDesktopTextureRegistrarRef registrar_;
  int64_t id_ = -1;
  int width_ = 0;
  int height_ = 0;
};

}  // namespace native_playback
#endif  // RUNNER_NATIVE_PLAYBACK_TEXTURE_H_

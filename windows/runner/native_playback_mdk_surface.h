#ifndef RUNNER_NATIVE_PLAYBACK_MDK_SURFACE_H_
#define RUNNER_NATIVE_PLAYBACK_MDK_SURFACE_H_

#include "native_playback_backend.h"
#include <mdk/RenderAPI.h>
#include <mdk/c/Player.h>
#include <wrl/client.h>

#include <atomic>
#include <cmath>

namespace native_playback {

// Only the platform-thread poller accesses the output. SDK notifications
// coalesce, including a decoded frame arriving after a paused seek.
class MdkSurface {
 public:
  void Attach(const mdkPlayerAPI* player) {
    player->setRenderCallback(player->object, {[](void*, void* opaque) {
      static_cast<MdkSurface*>(opaque)->RequestFrame();
    }, this});
    RequestFrame();
  }

  void RequestFrame() { dirty_ = true; }
  bool presented() const { return presented_; }

  bool Draw(const mdkPlayerAPI* player, VideoOutput& output, int w, int h) {
    auto* p = player->object;
    auto* ctx = output.Context();
    if (!ctx || !output.Device()) return false;
    if (!configured_) {
      const mdk::D3D11RenderAPI api(ctx);
      player->setRenderAPI(p, reinterpret_cast<const mdkRenderAPI*>(&api), nullptr);
      configured_ = true;
    }
    if (!w || !h) return true;
    const bool dirty = dirty_.exchange(false);
    if (!dirty && presented_ && width_ == w && height_ == h) return true;
    if (width_ != w || height_ != h) {
      width_ = w;
      height_ = h;
      player->setVideoSurfaceSize(p, w, h, nullptr);
    }
    auto* target = output.Target(w, h);
    if (!target) return false;
    if (target != target_) {
      view_.Reset();
      if (FAILED(output.Device()->CreateRenderTargetView(target, nullptr, view_.GetAddressOf()))) {
        return false;
      }
      target_ = target;  // The view holds the reference.
    }
    ctx->OMSetRenderTargets(1, view_.GetAddressOf(), nullptr);
    const double timestamp = player->renderVideo(p, nullptr);
    ctx->OMSetRenderTargets(0, nullptr, nullptr);
    if (!std::isfinite(timestamp) || timestamp < 0) return true;
    ctx->Flush();
    if (!output.Present()) return false;
    presented_ = true;
    return true;
  }

  void Detach(const mdkPlayerAPI* player) {
    player->setRenderCallback(player->object, {});
    if (configured_) player->setVideoSurfaceSize(player->object, -1, -1, nullptr);
    view_.Reset();
    target_ = nullptr;
    width_ = height_ = 0;
    configured_ = presented_ = false;
  }

 private:
  std::atomic<bool> dirty_{false};
  int width_ = 0, height_ = 0;
  bool configured_ = false, presented_ = false;
  ID3D11Texture2D* target_ = nullptr;
  Microsoft::WRL::ComPtr<ID3D11RenderTargetView> view_;
};

}  // namespace native_playback
#endif

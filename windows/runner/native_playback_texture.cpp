#include "native_playback_texture.h"

#include <d3d10.h>
#include <wrl/client.h>

#include <deque>
#include <utility>

namespace native_playback {
namespace {
using Microsoft::WRL::ComPtr;

D3D11_TEXTURE2D_DESC Description(int width, int height, bool shared) {
  D3D11_TEXTURE2D_DESC desc{};
  desc.Width = static_cast<UINT>(width);
  desc.Height = static_cast<UINT>(height);
  desc.MipLevels = desc.ArraySize = desc.SampleDesc.Count = 1;
  desc.Format = DXGI_FORMAT_B8G8R8A8_UNORM;
  desc.Usage = D3D11_USAGE_DEFAULT;
  desc.BindFlags = D3D11_BIND_RENDER_TARGET | D3D11_BIND_SHADER_RESOURCE;
  if (shared) desc.MiscFlags = D3D11_RESOURCE_MISC_SHARED;
  return desc;
}

struct Frame {
  ComPtr<ID3D11Texture2D> texture;
  HANDLE handle = nullptr;  // Legacy DXGI handle: owned by the resource, not CloseHandle.
  int width = 0;
  int height = 0;
};

struct Mailbox {
  std::shared_ptr<Frame> latest;  // Atomic shared_ptr operations across platform/raster.
  FlutterDesktopGpuSurfaceDescriptor descriptor{};  // Raster thread only.

  static const FlutterDesktopGpuSurfaceDescriptor* Obtain(size_t, size_t, void* opaque) {
    auto& box = *static_cast<Mailbox*>(opaque);
    const auto frame = std::atomic_load(&box.latest);
    if (!frame) return nullptr;
    const auto width = static_cast<size_t>(frame->width);
    const auto height = static_cast<size_t>(frame->height);
    frame->texture->AddRef();  // Pin the handle until the consumer has opened it.
    // Flutter also reads visible_width/height *after* invoking release_callback.
    // The descriptor itself therefore lives until the next raster call/unregister.
    box.descriptor = {sizeof(box.descriptor), frame->handle, width, height, width, height,
                      kFlutterDesktopPixelFormatBGRA8888,
                      [](void* p) { static_cast<ID3D11Texture2D*>(p)->Release(); },
                      frame->texture.Get()};
    return &box.descriptor;
  }
};

struct Transfer {
  std::shared_ptr<Frame> frame;
  ComPtr<ID3D11Query> ready;
};
}  // namespace

struct PlaybackTexture::Impl {
  std::unique_ptr<Mailbox> box = std::make_unique<Mailbox>();
  ComPtr<ID3D11Device> device;
  ComPtr<ID3D11DeviceContext> context;
  ComPtr<ID3D11Texture2D> target;
  int target_width = 0;
  int target_height = 0;
  std::deque<Transfer> queue;
};

PlaybackTexture::PlaybackTexture(FlutterDesktopTextureRegistrarRef registrar)
    : impl_(std::make_unique<Impl>()), registrar_(registrar) {}

std::unique_ptr<PlaybackTexture> PlaybackTexture::Register(FlutterDesktopTextureRegistrarRef registrar) {
  if (!registrar) return nullptr;
  auto output = std::unique_ptr<PlaybackTexture>(new PlaybackTexture(registrar));
  FlutterDesktopTextureInfo info{};
  info.type = kFlutterDesktopGpuSurfaceTexture;
  info.gpu_surface_config = {sizeof(info.gpu_surface_config), kFlutterDesktopGpuSurfaceTypeDxgiSharedHandle,
                             Mailbox::Obtain, output->impl_->box.get()};
  output->id_ = FlutterDesktopTextureRegistrarRegisterExternalTexture(registrar, &info);
  if (output->id_ < 0) return nullptr;
  return output;
}

PlaybackTexture::~PlaybackTexture() { Unregister(); }

void PlaybackTexture::Unregister() {
  if (id_ < 0) return;
  const auto id = std::exchange(id_, int64_t{-1});
  // May complete on the raster thread, even after the session/channel is gone.
  // The callback has no dependency on the platform thread or the registrar.
  FlutterDesktopTextureRegistrarUnregisterExternalTexture(registrar_, id,
      [](void* p) { delete static_cast<Mailbox*>(p); }, impl_->box.release());
}

bool PlaybackTexture::CreateDevice(IDXGIAdapter* adapter) {
  if (id_ < 0 || !adapter) return false;
  const UINT flags = D3D11_CREATE_DEVICE_VIDEO_SUPPORT | D3D11_CREATE_DEVICE_BGRA_SUPPORT;
  if (FAILED(D3D11CreateDevice(adapter, D3D_DRIVER_TYPE_UNKNOWN, nullptr, flags, nullptr, 0,
      D3D11_SDK_VERSION, &impl_->device, nullptr, &impl_->context))) return false;
  ComPtr<ID3D10Multithread> multithread;
  if (FAILED(impl_->context.As(&multithread))) return false;
  multithread->SetMultithreadProtected(TRUE);
  return multithread->GetMultithreadProtected() != FALSE;
}

ID3D11Device* PlaybackTexture::Device() const { return impl_->device.Get(); }
ID3D11DeviceContext* PlaybackTexture::Context() const { return impl_->context.Get(); }

ID3D11Texture2D* PlaybackTexture::Target(int width, int height) {
  auto& p = *impl_;
  if (id_ < 0 || !p.device || width <= 0 || height <= 0 ||
      width > D3D11_REQ_TEXTURE2D_U_OR_V_DIMENSION || height > D3D11_REQ_TEXTURE2D_U_OR_V_DIMENSION) return nullptr;
  if (width != p.target_width || height != p.target_height) {
    const auto desc = Description(width, height, false);
    ComPtr<ID3D11Texture2D> target;
    if (FAILED(p.device->CreateTexture2D(&desc, nullptr, &target))) return nullptr;
    p.target = std::move(target);
    p.target_width = width;
    p.target_height = height;
  }
  return p.target.Get();
}

bool PlaybackTexture::Present() {
  auto& p = *impl_;
  if (id_ < 0 || !p.target) return false;
  // Never write into a surface that has been handed to Flutter: opening the
  // handle is not a GPU read-completion fence. Under load, coalesce only the
  // newest *unpublished* copy, leaving the oldest one able to finish.
  auto& slot = p.queue.size() < 2 ? p.queue.emplace_back() : p.queue.back();
  if (!slot.frame || slot.frame->width != p.target_width || slot.frame->height != p.target_height) {
    auto frame = std::make_shared<Frame>();
    const auto desc = Description(p.target_width, p.target_height, true);
    ComPtr<IDXGIResource> resource;
    if (FAILED(p.device->CreateTexture2D(&desc, nullptr, &frame->texture)) ||
        FAILED(frame->texture.As(&resource)) || FAILED(resource->GetSharedHandle(&frame->handle)) ||
        !frame->handle) return false;
    frame->width = p.target_width;
    frame->height = p.target_height;
    slot.frame = std::move(frame);
  }
  if (!slot.ready) {
    const D3D11_QUERY_DESC desc{D3D11_QUERY_EVENT, 0};
    if (FAILED(p.device->CreateQuery(&desc, &slot.ready))) return false;
  }
  p.context->CopyResource(slot.frame->texture.Get(), p.target.Get());
  p.context->End(slot.ready.Get());
  p.context->Flush();  // Submit on the producer device before sharing across devices.
  return true;
}

bool PlaybackTexture::pending() const { return !impl_->queue.empty(); }

bool PlaybackTexture::PublishReady() {
  auto& p = *impl_;
  if (id_ < 0) return false;
  std::shared_ptr<Frame> newest;
  while (!p.queue.empty()) {
    auto& slot = p.queue.front();
    if (!slot.ready) return false;
    const auto hr = p.context->GetData(slot.ready.Get(), nullptr, 0, D3D11_ASYNC_GETDATA_DONOTFLUSH);
    if (FAILED(hr)) return false;
    if (hr != S_OK) break;  // Never wait for a fence on the UI or raster thread.
    newest = std::move(slot.frame);
    p.queue.pop_front();
  }
  if (newest) {
    if (id_ < 0) return false;  // A nested close may have detached the mailbox.
    const int w = newest->width, h = newest->height;
    std::atomic_store(&p.box->latest, std::move(newest));
    if (!FlutterDesktopTextureRegistrarMarkExternalTextureFrameAvailable(registrar_, id_)) return false;
    width_ = w;
    height_ = h;
  }
  return true;
}

}  // namespace native_playback

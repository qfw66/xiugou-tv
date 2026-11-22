#include "native_playback_backend.h"

#include <d3d10.h>  // ID3D10Multithread protection for MF's use of the D3D11 device.
#include <mfapi.h>
#include <mfmediaengine.h>
#include <wrl.h>

#include <algorithm>
#include <atomic>
#include <cmath>
#include <cstring>
#include <limits>
#include <optional>

namespace native_playback {
namespace {

using Microsoft::WRL::ComPtr;

template <typename T>
T Proc(HMODULE dll, const char* name) {
  const FARPROC address = dll ? GetProcAddress(dll, name) : nullptr;
  T function;
  static_assert(sizeof(function) == sizeof(address));
  std::memcpy(&function, &address, sizeof(function));
  return function;
}

struct MfApi {
  // Lazy, process-lifetime reference: an MF work item can outlive Shutdown.
  HMODULE dll = LoadLibraryExW(L"mfplat.dll", nullptr, LOAD_LIBRARY_SEARCH_SYSTEM32);
  decltype(&MFStartup) startup = Proc<decltype(startup)>(dll, "MFStartup");
  decltype(&MFShutdown) shutdown = Proc<decltype(shutdown)>(dll, "MFShutdown");
  decltype(&MFCreateAttributes) attributes = Proc<decltype(attributes)>(dll, "MFCreateAttributes");
  decltype(&MFCreateDXGIDeviceManager) device_manager =
      Proc<decltype(device_manager)>(dll, "MFCreateDXGIDeviceManager");
  decltype(&MFCreateFile) file = Proc<decltype(file)>(dll, "MFCreateFile");
  decltype(&MFCreateSourceResolver) resolver = Proc<decltype(resolver)>(dll, "MFCreateSourceResolver");
  decltype(&MFLockPlatform) lock = Proc<decltype(lock)>(dll, "MFLockPlatform");
  decltype(&MFUnlockPlatform) unlock = Proc<decltype(unlock)>(dll, "MFUnlockPlatform");
};

const MfApi& Api() {
  static const MfApi api;
  return api;
}

// Construct and destroy on the platform thread, never on an MF work queue.
class Runtime {
 public:
  Runtime() {
    const auto& api = Api();
    if ((SUCCEEDED(com_) || com_ == RPC_E_CHANGED_MODE) && api.startup &&
        api.shutdown && api.attributes && api.device_manager && api.file && api.resolver &&
        api.lock && api.unlock) {
      started_ = SUCCEEDED(api.startup(MF_VERSION, MFSTARTUP_FULL));
    }
  }
  ~Runtime() {
    if (started_) Api().shutdown();
    if (SUCCEEDED(com_)) CoUninitialize();
  }
  bool Factory(IMFMediaEngineClassFactory** result) const {
    return started_ && SUCCEEDED(CoCreateInstance(CLSID_MFMediaEngineClassFactory,
        nullptr, CLSCTX_INPROC_SERVER, IID_PPV_ARGS(result)));
  }
  Runtime(const Runtime&) = delete;
  Runtime& operator=(const Runtime&) = delete;

 private:
  HRESULT com_ = CoInitializeEx(nullptr, COINIT_APARTMENTTHREADED);
  bool started_ = false;
};

// The engine owns this free-threaded sink. It never calls the platform thread,
// the video output, or the engine itself (including during shutdown).
class Events final : public Microsoft::WRL::RuntimeClass<
    Microsoft::WRL::RuntimeClassFlags<Microsoft::WRL::ClassicCom>,
    IMFMediaEngineNotify, Microsoft::WRL::FtmBase> {
 public:
  STDMETHODIMP EventNotify(DWORD event, DWORD_PTR param1, DWORD) override {
    switch (event) {
      case MF_MEDIA_ENGINE_EVENT_NOTIFYSTABLESTATE:
        SetEvent(reinterpret_cast<HANDLE>(param1));
        break;
      case MF_MEDIA_ENGINE_EVENT_FIRSTFRAMEREADY:
        frame = true;
        break;
      case MF_MEDIA_ENGINE_EVENT_SEEKED:
        seeked = true;
        break;
      case MF_MEDIA_ENGINE_EVENT_ABORT:
      case MF_MEDIA_ENGINE_EVENT_ERROR:
      case MF_MEDIA_ENGINE_EVENT_STREAMRENDERINGERROR:
      case MF_MEDIA_ENGINE_EVENT_RESOURCELOST:
        failed = true;
        break;
    }
    return S_OK;
  }
  std::atomic<bool> frame{false};
  std::atomic<bool> seeked{true};
  std::atomic<bool> failed{false};
};

// Request a progressive HTTP byte stream, not a Windows Media streaming
// server. Resolving a slow URL must not block the platform thread.
class HttpOpen final : public Microsoft::WRL::RuntimeClass<
    Microsoft::WRL::RuntimeClassFlags<Microsoft::WRL::ClassicCom>,
    IMFAsyncCallback, Microsoft::WRL::FtmBase> {
 public:
  HRESULT Begin(BSTR url, IUnknown** cookie) {
    // Even a canceled operation may still Invoke after the session is gone.
    HRESULT hr = Api().lock();
    if (FAILED(hr)) return hr;
    locked_ = true;
    hr = Api().resolver(&resolver_);
    if (FAILED(hr)) return hr;
    return resolver_->BeginCreateObjectFromURL(url, MF_RESOLUTION_BYTESTREAM | MF_RESOLUTION_READ,
                                               nullptr, cookie, this, nullptr);
  }
  void Cancel(IUnknown* cookie) { resolver_->CancelObjectCreation(cookie); }
  STDMETHODIMP GetParameters(DWORD*, DWORD*) override { return E_NOTIMPL; }
  STDMETHODIMP Invoke(IMFAsyncResult* result) override {
    MF_OBJECT_TYPE type = MF_OBJECT_INVALID;
    ComPtr<IUnknown> object;
    HRESULT hr = resolver_->EndCreateObjectFromURL(result, &type, &object);
    if (SUCCEEDED(hr)) hr = type == MF_OBJECT_BYTESTREAM ? object.As(&stream_) : E_UNEXPECTED;
    status_.store(hr, std::memory_order_release);
    return S_OK;
  }
  HRESULT Apply(IMFMediaEngineEx* engine, BSTR url) const {
    const HRESULT hr = status_.load(std::memory_order_acquire);
    return SUCCEEDED(hr) ? engine->SetSourceFromByteStream(stream_.Get(), url) : hr;
  }
  ~HttpOpen() {
    stream_.Reset();
    resolver_.Reset();
    if (locked_) Api().unlock();  // Unlike MFShutdown, valid on a work queue.
  }

 private:
  ComPtr<IMFSourceResolver> resolver_;
  ComPtr<IMFByteStream> stream_;
  std::atomic<HRESULT> status_{E_PENDING};
  bool locked_ = false;
};

double Level(double volume) {
  return std::isfinite(volume) ? std::clamp(volume, 0.0, 1.0) : 0.0;
}

int64_t Milliseconds(double seconds) {
  const double ms = seconds * 1000.0;
  if (!std::isfinite(ms) || ms <= 0 ||
      ms >= static_cast<double>((std::numeric_limits<int64_t>::max)())) return 0;
  return std::llround(ms);
}

class Session {
 public:
  explicit Session(VideoOutput& video) : video_(video) {}
  ~Session() {
    if (cookie_) http_->Cancel(cookie_.Get());
    if (engine) engine->Shutdown();
    SysFreeString(url_);
  }

  bool Open(const std::wstring& source, double volume) {
    ComPtr<IMFMediaEngineClassFactory> factory;
    ComPtr<IMFAttributes> attributes;
    ComPtr<IMFMediaEngine> base;
    ComPtr<ID3D10Multithread> multithread;
    UINT token;
    if (!runtime.Factory(&factory) || !video_.Device() || !video_.Context() ||
        FAILED(video_.Context()->QueryInterface(IID_PPV_ARGS(&multithread))) ||
        FAILED(Api().device_manager(&token, &manager))) return false;
    multithread->SetMultithreadProtected(TRUE);
    if (FAILED(manager->ResetDevice(video_.Device(), token))) return false;
    events = Microsoft::WRL::Make<Events>();
    if (!events || FAILED(Api().attributes(&attributes, 4)) ||
        FAILED(attributes->SetUnknown(MF_MEDIA_ENGINE_CALLBACK,
                                      static_cast<IMFMediaEngineNotify*>(events.Get()))) ||
        FAILED(attributes->SetUnknown(MF_MEDIA_ENGINE_DXGI_MANAGER, manager.Get())) ||
        FAILED(attributes->SetUINT32(MF_MEDIA_ENGINE_VIDEO_OUTPUT_FORMAT, DXGI_FORMAT_B8G8R8A8_UNORM)) ||
        FAILED(attributes->SetUINT32(MF_MEDIA_ENGINE_SYNCHRONOUS_CLOSE, TRUE)) ||
        FAILED(factory->CreateInstance(0, attributes.Get(), &base))) return false;
    if (FAILED(base.As(&engine))) {
      base->Shutdown();
      return false;
    }
    if (FAILED(engine->SetAutoPlay(FALSE)) || FAILED(engine->SetVolume(Level(volume))) ||
        FAILED(engine->SetPreload(MF_MEDIA_ENGINE_PRELOAD_AUTOMATIC))) return false;

    url_ = SysAllocString(source.c_str());
    if (!url_) return false;
    if (_wcsnicmp(url_, L"http://", 7) == 0 || _wcsnicmp(url_, L"https://", 8) == 0) {
      http_ = Microsoft::WRL::Make<HttpOpen>();
      return http_ && SUCCEEDED(http_->Begin(url_, &cookie_));
    }
    // The literal wide path is not a URL; '#' and '%' are ordinary characters.
    ComPtr<IMFByteStream> stream;
    return SUCCEEDED(Api().file(MF_ACCESSMODE_READ, MF_OPENMODE_FAIL_IF_NOT_EXIST,
                                MF_FILEFLAGS_NONE, url_, &stream)) &&
           SUCCEEDED(engine->SetSourceFromByteStream(stream.Get(), url_));
  }

  HRESULT PollSource() {
    if (!http_) return S_OK;
    const HRESULT hr = http_->Apply(engine.Get(), url_);
    if (hr != E_PENDING) {
      cookie_.Reset();
      http_.Reset();
    }
    return hr;
  }

  HRESULT PresentFrame() {
    // The caller holds a newly ticked sample that has not been presented.
    DWORD width, height;
    HRESULT hr = engine->GetNativeVideoSize(&width, &height);
    if (FAILED(hr)) return hr;
    if (!width || !height || width > INT_MAX || height > INT_MAX) return E_UNEXPECTED;
    auto* target = video_.Target(static_cast<int>(width), static_cast<int>(height));
    if (!target) return E_FAIL;
    const RECT dst{0, 0, static_cast<LONG>(width), static_cast<LONG>(height)};
    const MFARGB black{0, 0, 0, 255};
    hr = engine->TransferVideoFrame(target, nullptr, &dst, &black);
    if (hr != S_OK) return hr;
    return video_.Present() ? S_OK : E_FAIL;
  }

  // Keep COM and MF initialized until all interfaces have been released.
  Runtime runtime;
  ComPtr<IMFDXGIDeviceManager> manager;
  ComPtr<Events> events;
  ComPtr<IMFMediaEngineEx> engine;

 private:
  VideoOutput& video_;
  BSTR url_ = nullptr;
  ComPtr<HttpOpen> http_;
  ComPtr<IUnknown> cookie_;
};

class MfBackend final : public Backend {
 public:
  bool Open(VideoOutput& video, const std::wstring& source, int64_t start_ms,
            double volume, bool paused) override {
    session_.reset();
    snapshot_ = {};
    snapshot_.phase = Phase::failed;
    if (source.empty() || source.find(L'\0') != std::wstring::npos) return false;
    auto session = std::make_unique<Session>(video);
    if (!session->Open(source, volume)) return false;
    session_ = std::move(session);
    want_paused_ = paused;
    presented_pts_.reset();
    intent_dirty_ = true;
    pending_pts_.reset();
    step_on_empty_seek_ = false;
    pending_seek_.reset();
    if (start_ms > 0) pending_seek_ = start_ms;
    wait_since_ = GetTickCount64();
    snapshot_.phase = Phase::loading;
    return true;
  }

  Snapshot Read() override {
    if (!session_) return snapshot_;
    auto& s = *session_;
    auto* e = s.engine.Get();
    if (s.events->failed || (!presented_pts_ && GetTickCount64() - wait_since_ > 30000)) return Fail();
    const HRESULT source = s.PollSource();
    if (source == E_PENDING) return snapshot_;
    if (FAILED(source)) return Fail();
    if (e->GetReadyState() < MF_MEDIA_ENGINE_READY_HAVE_METADATA) return snapshot_;
    if (!e->HasVideo()) return Fail();
    snapshot_.duration_ms = Milliseconds(e->GetDuration());
    if (!s.events->frame) return snapshot_;
    // A paused seek cannot complete until the frame server is ticked. Latch
    // new samples, but never expose a pre-seek frame while SEEKED is pending.
    LONGLONG pts;
    const HRESULT tick = e->OnVideoStreamTick(&pts);
    if (FAILED(tick)) return Fail();
    if (tick == S_OK) pending_pts_ = pts;  // S_FALSE means no new sample.
    if (!s.events->seeked) return snapshot_;
    if (pending_seek_) {
      const int64_t target = snapshot_.duration_ms > 0 ?
          (std::min)(*pending_seek_, snapshot_.duration_ms) : *pending_seek_;
      pending_seek_.reset();
      if (target != Milliseconds(e->GetCurrentTime())) {
        s.events->seeked = false;
        if (FAILED(e->SetCurrentTime(static_cast<double>(target) / 1000.0))) return Fail();
        pending_pts_.reset();
        presented_pts_.reset();
        step_on_empty_seek_ = true;
        snapshot_.phase = Phase::loading;
        wait_since_ = GetTickCount64();
        return snapshot_;
      }
    }
    if (pending_pts_ && pending_pts_ != presented_pts_) {
      const HRESULT frame = s.PresentFrame();
      if (FAILED(frame)) return Fail();
      if (frame == S_OK) presented_pts_ = pending_pts_;
    }
    pending_pts_.reset();
    if (!presented_pts_) {
      // A paused seek can finish without queuing a sample (S_FALSE forever).
      // Request one frame without starting the clock/audio. Readiness still
      // requires a subsequent successful tick, transfer and presentation.
      if (step_on_empty_seek_ && e->IsPaused() && GetTickCount64() - wait_since_ >= 200) {
        step_on_empty_seek_ = false;
        if (FAILED(e->FrameStep(TRUE))) return Fail();
      }
      return snapshot_;
    }
    // Do not race Play with a pending scrub, especially on an HTTP source.
    if (intent_dirty_) {
      if (FAILED(want_paused_ ? (e->IsPaused() ? S_OK : e->Pause()) : e->Play())) return Fail();
      intent_dirty_ = false;
    }
    snapshot_.position_ms = Milliseconds(e->GetCurrentTime());
    if (snapshot_.duration_ms > 0) snapshot_.position_ms = (std::min)(snapshot_.duration_ms, snapshot_.position_ms);
    snapshot_.phase = e->IsEnded() ? Phase::ended : (e->IsPaused() ? Phase::paused : Phase::playing);
    return snapshot_;
  }

  void SetPaused(bool paused) override {
    want_paused_ = paused;
    intent_dirty_ = true;
    Read();
  }

  void Seek(int64_t ms) override {
    pending_seek_ = (std::max)(ms, int64_t{0});
    Read();
  }

  void SetVolume(double volume) override {
    if (session_ && FAILED(session_->engine->SetVolume(Level(volume)))) Fail();
  }

 private:
  Snapshot Fail() {
    snapshot_.phase = Phase::failed;
    session_.reset();  // Stop audio and release the source before reporting failure.
    return snapshot_;
  }

  std::unique_ptr<Session> session_;
  Snapshot snapshot_;
  std::optional<int64_t> pending_seek_;
  std::optional<LONGLONG> pending_pts_, presented_pts_;
  ULONGLONG wait_since_ = 0;
  bool intent_dirty_ = false;
  bool step_on_empty_seek_ = false;
  bool want_paused_ = false;
};

}  // namespace

bool MfAvailable() {
  Runtime runtime;
  ComPtr<IMFMediaEngineClassFactory> factory;
  return runtime.Factory(&factory);
}

std::unique_ptr<Backend> MakeMf() {
  return std::make_unique<MfBackend>();
}

}  // namespace native_playback

#include "native_playback_backend.h"

#ifdef XIUGOU_MDK_PREVIEW
#include "native_playback_mdk_surface.h"
#include <mdk/c/MediaInfo.h>
#include <mdk/c/Player.h>

#include <algorithm>
#include <atomic>
#include <cmath>
#include <cstring>
#include <limits>

namespace native_playback {
namespace {

static_assert(MDK_VERSION == MDK_VERSION_INT(0, 40, 1),
              "The MDK preview requires the matching 0.40.1 SDK and DLLs");

std::string Utf8(const std::wstring& text) {
  if (text.empty() || text.find(L'\0') != text.npos ||
      text.size() > static_cast<size_t>((std::numeric_limits<int>::max)())) return {};
  const int n = static_cast<int>(text.size());
  const int size = WideCharToMultiByte(CP_UTF8, WC_ERR_INVALID_CHARS,
                                       text.data(), n, nullptr, 0, nullptr, nullptr);
  std::string result(size, '\0');
  if (!size || !WideCharToMultiByte(CP_UTF8, WC_ERR_INVALID_CHARS, text.data(),
                                    n, result.data(), size, nullptr, nullptr)) return {};
  return result;
}

std::wstring RuntimeDirectory() {
  std::wstring exe(32768, L'\0');
  const DWORD n = GetModuleFileNameW(nullptr, exe.data(), static_cast<DWORD>(exe.size()));
  if (!n || n >= exe.size()) return {};
  exe.resize(n);
  const auto slash = exe.find_last_of(L"\\/");
  if (slash == exe.npos) return {};
  return exe.substr(0, slash + 1) + L"mdk\\";
}

template <class Fn>
Fn Symbol(HMODULE module, const char* name) {
  const auto address = GetProcAddress(module, name);
  Fn result;
  static_assert(sizeof(result) == sizeof(address));
  std::memcpy(&result, &address, sizeof(result));
  return result;
}

struct Runtime {
  decltype(&mdkPlayerAPI_new) create = nullptr;
  decltype(&mdkPlayerAPI_reset) reset = nullptr;
  decltype(&MDK_VideoStreamCodecParameters) video_parameters = nullptr;
};

Runtime LoadRuntime() {
  const auto dir = RuntimeDirectory();
  if (dir.empty()) return {};
  // Never change the DLL search policy of Flutter/mpv or let MDK discover
  // FFmpeg on its own. Only the app-owned preview directory and OS are trusted.
  constexpr DWORD flags = LOAD_LIBRARY_SEARCH_DLL_LOAD_DIR | LOAD_LIBRARY_SEARCH_SYSTEM32;
  HMODULE ffmpeg = LoadLibraryExW((dir + L"ffmpeg-9.dll").c_str(), nullptr, flags);
  if (!ffmpeg) return {};
  HMODULE mdk = LoadLibraryExW((dir + L"mdk.dll").c_str(), nullptr, flags);
  if (mdk) {
    const auto version = Symbol<decltype(&MDK_version)>(mdk, "MDK_version");
    const auto set_string = Symbol<decltype(&MDK_setGlobalOptionString)>(mdk, "MDK_setGlobalOptionString");
    const auto set_ptr = Symbol<decltype(&MDK_setGlobalOptionPtr)>(mdk, "MDK_setGlobalOptionPtr");
    const auto set_log = Symbol<decltype(&MDK_setLogHandler)>(mdk, "MDK_setLogHandler");
    const Runtime api{Symbol<decltype(&mdkPlayerAPI_new)>(mdk, "mdkPlayerAPI_new"),
                      Symbol<decltype(&mdkPlayerAPI_reset)>(mdk, "mdkPlayerAPI_reset"),
                      Symbol<decltype(&MDK_VideoStreamCodecParameters)>(mdk, "MDK_VideoStreamCodecParameters")};
    if (api.create && api.reset && api.video_parameters && version && set_string && set_ptr && set_log &&
        version() == MDK_VERSION && GetProcAddress(ffmpeg, "avformat_open_input")) {
      // In MDK's C ABI, null opaque means "no handler", even for a non-null cb.
      static int log_cookie;
      set_log({[](MDK_LogLevel, const char*, void*) {}, &log_cookie});
      set_string("log", "Off");
      set_ptr("ffmpeg", ffmpeg);
      set_string("ffmpeg.log", "quiet");
      set_string("plugins_dir", Utf8(dir).c_str());
      set_string("plugins", "");
      // Library references outlive SDK workers; players and views are per session.
      return api;
    }
    FreeLibrary(mdk);
  }
  FreeLibrary(ffmpeg);
  return {};
}

const Runtime& Api() {
  static const Runtime api = LoadRuntime();
  return api;
}

class MdkBackend final : public Backend {
 public:
  ~MdkBackend() override { Close(); }

  bool Open(VideoOutput& video, const std::wstring& source, int64_t start_ms,
            double volume, bool paused) override {
    Close();
    video_ = &video;
    source_ = Utf8(source);
    volume_ = Level(volume);
    return Start(start_ms, paused);
  }

  Snapshot Read() override {
    if (!player_ || snapshot_.phase == Phase::failed || snapshot_.phase == Phase::ended) {
      return snapshot_;
    }
    auto* p = player_->object;
    if ((metadata_dirty_.exchange(false) || !width_) &&
        (player_->mediaStatus(p) & MDK_MediaStatus_Loaded)) ReadMediaInfo();
    const auto state = player_->state(p);
    const bool loading_timeout = snapshot_.phase == Phase::loading &&
                                 GetTickCount64() - opened_at_ > 20000;
    if (failed_ || loading_timeout || !surface_.Draw(player_, *video_, width_, height_)) {
      snapshot_.phase = Phase::failed;
    } else if (state == MDK_State_Stopped && eof_) {
      snapshot_.phase = surface_.presented() ? Phase::ended : Phase::failed;
      if (surface_.presented() && snapshot_.duration_ms > 0) snapshot_.position_ms = snapshot_.duration_ms;
    } else if (surface_.presented() && prepared_ && state != MDK_State_Stopped) {
      // prepare() first parks on the requested frame. Do not race playback
      // against its pending pause (especially on EOF -> seek(0) -> resume).
      if (starting_ && state == MDK_State_Paused) {
        starting_ = false;
        if (!want_paused_) player_->setState(p, MDK_State_Playing);
      }
      if (starting_ || (!want_paused_ && state == MDK_State_Paused &&
                        snapshot_.phase == Phase::loading)) return snapshot_;
      const int64_t pos = player_->position(player_->object);
      if (pos >= 0) snapshot_.position_ms = pos;
      snapshot_.phase = state == MDK_State_Playing ? Phase::playing : Phase::paused;
    } else if (snapshot_.phase != Phase::loading) {
      // Previously presented, then stopped without an end-of-stream event.
      snapshot_.phase = Phase::failed;
    }
    if (snapshot_.phase == Phase::failed) Close();
    return snapshot_;
  }

  void SetPaused(bool paused) override {
    if (!player_ || snapshot_.phase == Phase::failed) return;
    if (snapshot_.phase == Phase::ended) {
      if (!paused) Start(0, false);
      return;
    }
    want_paused_ = paused;
    if (starting_) return;
    player_->setState(player_->object, paused ? MDK_State_Paused : MDK_State_Playing);
  }

  void Seek(int64_t ms) override {
    if (!player_ || snapshot_.phase == Phase::failed) return;
    ms = (std::max)(int64_t{0}, ms);
    if (snapshot_.duration_ms > 0) ms = (std::min)(ms, snapshot_.duration_ms - 1);
    if (snapshot_.phase == Phase::ended || want_paused_ || starting_) {
      // Paused seek notifications can precede delivery of the parked frame.
      // A new accurate prepare guarantees a decoded frame at the new position.
      Start(ms, snapshot_.phase == Phase::ended || want_paused_);
    } else {
      player_->seekWithFlags(player_->object, ms, MDK_SeekFlag_FromStart,
          {[](int64_t pos, void* opaque) {
             if (pos >= 0) static_cast<MdkSurface*>(opaque)->RequestFrame();
           }, &surface_});
    }
  }

  void SetVolume(double volume) override {
    volume_ = Level(volume);
    if (player_) player_->setVolume(player_->object, volume_);
  }

 private:
  static float Level(double value) {
    return std::isfinite(value) ? static_cast<float>(std::clamp(value, 0.0, 1.0)) : 0.0f;
  }

  void ReadMediaInfo() {
    const auto* info = player_->mediaInfo(player_->object);
    if (!info) return;
    snapshot_.duration_ms = (std::max)(int64_t{0}, info->duration);
    if (!info->video || info->nb_video <= 0) {
      failed_ = true;
      return;
    }
    const auto& stream = info->video[0];  // MDK's default active video track.
    mdkVideoCodecParameters codec{};
    Api().video_parameters(&stream, &codec);
    if (codec.width <= 0 || codec.height <= 0) return;  // Decoder size event follows.
    const double par = std::isfinite(codec.par) && codec.par > 0 ? codec.par : 1.0;
    const double w = (std::max)(1.0, std::round(codec.width * par));
    const double h = codec.height;
    const int angle = (stream.rotation % 360 + 360) % 360;
    const double rad = angle * (3.14159265358979323846 / 180.0);
    const double dw = std::round(std::abs(w * std::cos(rad)) + std::abs(h * std::sin(rad)));
    const double dh = std::round(std::abs(w * std::sin(rad)) + std::abs(h * std::cos(rad)));
    if (dw > D3D11_REQ_TEXTURE2D_U_OR_V_DIMENSION || dh > D3D11_REQ_TEXTURE2D_U_OR_V_DIMENSION) {
      failed_ = true;
      return;
    }
    width_ = static_cast<int>(dw);
    height_ = static_cast<int>(dh);
    surface_.RequestFrame();
  }

  bool Start(int64_t ms, bool paused) {
    Close();
    snapshot_ = {Phase::failed, (std::max)(int64_t{0}, ms), 0};
    if (!video_ || source_.empty() || !Api().create) return false;
    if (!(player_ = Api().create())) return false;
    eof_ = false;
    failed_ = false;
    metadata_dirty_ = true;
    prepared_ = false;
    starting_ = true;
    want_paused_ = paused;
    width_ = height_ = 0;
    opened_at_ = GetTickCount64();
    snapshot_.phase = Phase::loading;
    auto* p = player_->object;
    player_->onMediaStatus(p, {OnStatus, this}, nullptr);
    player_->onEvent(p, {OnEvent, this}, nullptr);
    player_->setTimeout(p, 10000, {OnTimeout, this});
    const char* decoders[] = {"D3D11", "FFmpeg", nullptr};
    player_->setDecoders(p, MDK_MediaType_Video, decoders);
    player_->setVolume(p, volume_);
    surface_.Attach(player_);
    player_->setProperty(p, "subtitle", "0");
    player_->setProperty(p, "cc", "0");
    player_->setMedia(p, source_.c_str());
    player_->setActiveTracks(p, MDK_MediaType_Subtitle, nullptr, 0);
    player_->prepare(p, snapshot_.position_ms, {OnPrepare, this}, MDK_SeekFlag_FromStart);
    return true;
  }

  // Workers only signal the poller. No callback touches D3D, the output or UI.
  static bool OnStatus(MDK_MediaStatus old, MDK_MediaStatus now, void* opaque) {
    auto& self = *static_cast<MdkBackend*>(opaque);
    if (now & MDK_MediaStatus_Invalid) self.failed_ = true;
    if (now & MDK_MediaStatus_End) self.eof_ = true;
    if ((now & MDK_MediaStatus_Loaded) && !(old & MDK_MediaStatus_Loaded)) {
      self.metadata_dirty_ = true;
    }
    return true;
  }

  static bool OnEvent(const mdkMediaEvent* e, void* opaque) {
    if (e && e->category && e->detail && !std::strcmp(e->detail, "size") &&
        (!std::strcmp(e->category, "video") || !std::strcmp(e->category, "decoder.video"))) {
      static_cast<MdkBackend*>(opaque)->metadata_dirty_ = true;
    }
    if (e && e->error < 0 && e->category && e->detail &&
        !std::strcmp(e->category, "decoder.video") && !std::strcmp(e->detail, "open")) {
      static_cast<MdkBackend*>(opaque)->failed_ = true;
    }
    return false;
  }

  static bool OnPrepare(int64_t position, bool* boost, void* opaque) {
    auto& self = *static_cast<MdkBackend*>(opaque);
    if (position < 0) self.failed_ = true;
    else self.prepared_ = true;
    if (boost) *boost = true;
    return position >= 0;
  }

  static bool OnTimeout(int64_t, void* opaque) {
    static_cast<MdkBackend*>(opaque)->failed_ = true;
    return true;
  }

  void Close() {
    if (player_) {
      auto* p = player_->object;
      player_->setMute(p, true);
      surface_.Detach(player_);
      player_->setState(p, MDK_State_Stopped);
      // Reset unregisters and joins workers before this callback context is reused.
      auto* owned = player_;
      Api().reset(&owned, true);
      player_ = nullptr;
    }
  }

  const mdkPlayerAPI* player_ = nullptr;
  VideoOutput* video_ = nullptr;
  MdkSurface surface_;
  std::string source_;
  float volume_ = 1.0f;
  ULONGLONG opened_at_ = 0;
  Snapshot snapshot_;
  std::atomic<bool> eof_{false}, failed_{false};
  std::atomic<bool> metadata_dirty_{true};
  std::atomic<bool> prepared_{false};
  bool starting_ = false, want_paused_ = true;
  int width_ = 0, height_ = 0;
};

}  // namespace

bool MdkAvailable() { return Api().create != nullptr; }
std::unique_ptr<Backend> MakeMdk() {
  return MdkAvailable() ? std::make_unique<MdkBackend>() : nullptr;
}

}  // namespace native_playback
#else
namespace native_playback {
bool MdkAvailable() { return false; }
std::unique_ptr<Backend> MakeMdk() { return nullptr; }
}  // namespace native_playback
#endif

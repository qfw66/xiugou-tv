#include "native_playback_channel.h"

#include <flutter/standard_method_codec.h>
#include <shlwapi.h>
#include <urlmon.h>
#include <wrl/client.h>

#include <algorithm>
#include <cmath>
#include <cwchar>
#include <cwctype>
#include <limits>
#include <optional>
#include <string_view>
#include <utility>

#include "native_playback_texture.h"

namespace native_playback {
namespace {
using Value = flutter::EncodableValue;
using Map = flutter::EncodableMap;
using Result = std::unique_ptr<flutter::MethodResult<Value>>;

constexpr UINT kFrameIntervalMs = 16;
constexpr ULONGLONG kLoadTimeoutMs = 30000;

struct Request {
  bool mf;
  std::wstring source;
  int64_t position;
  double volume;
  bool paused;
};

template <typename T>
const T* Field(const Map& map, const char* key) {
  const auto it = map.find(Value(key));
  return it == map.end() ? nullptr : std::get_if<T>(&it->second);
}

bool IsLocalPath(const std::wstring& s) {
  if (s.size() < 4 || !((s[0] >= L'A' && s[0] <= L'Z') ||
                        (s[0] >= L'a' && s[0] <= L'z')) ||
      s[1] != L':' || (s[2] != L'\\' && s[2] != L'/') ||
      s.find_first_of(L"<>:\"|?*", 2) != s.npos) return false;
  const wchar_t root[] = {s[0], L':', L'\\', 0};
  const auto drive = GetDriveTypeW(root);
  if (drive != DRIVE_FIXED && drive != DRIVE_REMOVABLE && drive != DRIVE_CDROM &&
      drive != DRIVE_RAMDISK) return false;
  size_t start = 3;
  for (;;) {
    const auto end = s.find_first_of(L"/\\", start);
    const auto part = std::wstring_view(s).substr(start, end - start);
    if (part.empty() || part.back() == L'.' || part.back() == L' ') return false;
    // A drive prefix and even a file extension do not disarm DOS device names.
    auto stem = part.substr(0, part.find(L'.'));
    while (!stem.empty() && stem.back() == L' ') stem.remove_suffix(1);
    if (stem.size() <= 7) {
      std::wstring name(stem);
      CharUpperBuffW(name.data(), static_cast<DWORD>(name.size()));
      if (name == L"CON" || name == L"AUX" || name == L"PRN" ||
          name == L"NUL" || name == L"CONIN$" || name == L"CONOUT$" ||
          (name.size() == 4 && (name.compare(0, 3, L"COM") == 0 ||
                                name.compare(0, 3, L"LPT") == 0) &&
           std::wcschr(L"0123456789\u00b9\u00b2\u00b3", name[3]))) return false;
    }
    if (end == s.npos) return true;
    start = end + 1;
  }
}

bool HasCredentialParameter(std::wstring_view query) {
  while (!query.empty()) {
    const auto end = query.find_first_of(L"&;");
    const auto pair = query.substr(0, end);
    std::wstring key(pair.substr(0, pair.find(L'=')));
    if (!key.empty()) {
      if (FAILED(UrlUnescapeW(key.data(), nullptr, nullptr, URL_UNESCAPE_INPLACE)))
        return true;
      key.resize(std::wcslen(key.c_str()));
      CharLowerBuffW(key.data(), static_cast<DWORD>(key.size()));
      key.erase(std::remove_if(key.begin(), key.end(), [](wchar_t c) {
        return c == L'-' || c == L'_' || c == L'.';
      }), key.end());
      for (const auto* word : {L"token", L"authorization", L"credential", L"passwd",
                               L"password", L"cookie", L"signature", L"secret",
                               L"apikey", L"accesskey"}) {
        if (key.find(word) != key.npos) return true;
      }
      if (key == L"auth" || key == L"authkey" || key == L"pwd" || key == L"jwt" ||
          key == L"sessionid" || key == L"sig" || key == L"sign" || key == L"key" ||
          key == L"policy" || key == L"keypairid" || key == L"hdnea" ||
          key.compare(0, 4, L"xamz") == 0 || key.compare(0, 5, L"xgoog") == 0) return true;
    }
    if (end == query.npos) break;
    query.remove_prefix(end + 1);
  }
  return false;
}

bool IsHttpUri(const std::wstring& s) {
  size_t start = 0;
  if (_wcsnicmp(s.c_str(), L"https://", 8) == 0) start = 8;
  else if (_wcsnicmp(s.c_str(), L"http://", 7) == 0) start = 7;
  else return false;
  // Check the raw authority before Windows has a chance to canonicalize it.
  const auto end = s.find_first_of(L"/?#", start);
  const auto authority = std::wstring_view(s).substr(start, end - start);
  if (authority.empty() || authority.find_first_of(L"@%") != authority.npos ||
      s.find_first_of(L"\\<>\"{}|^` ") != s.npos) return false;
  for (size_t i = 0; i < s.size(); ++i) {
    if (std::iswspace(s[i])) return false;
    if (s[i] == L'%') {
      if (i + 2 >= s.size() || !std::iswxdigit(s[i + 1]) || !std::iswxdigit(s[i + 2]) ||
          s[i + 1] == L'0' || s[i + 1] == L'1' ||
          (s[i + 1] == L'7' && std::towupper(s[i + 2]) == L'F')) return false;
      i += 2;
    }
  }
  Microsoft::WRL::ComPtr<IUri> uri;
  DWORD host_length = 0;
  BOOL user_info = FALSE;
  if (FAILED(CreateUri(s.c_str(), Uri_CREATE_NO_IE_SETTINGS, 0, &uri)) ||
      FAILED(uri->GetPropertyLength(Uri_PROPERTY_HOST, &host_length, 0)) ||
      host_length == 0 || FAILED(uri->HasProperty(Uri_PROPERTY_USER_INFO, &user_info)) ||
      user_info) return false;
  const auto query = s.find(L'?');
  const auto fragment = s.find(L'#');
  // Fragments are not media request data and may contain authorization flows.
  return fragment == s.npos && (query == s.npos ||
      !HasCredentialParameter(std::wstring_view(s).substr(query + 1)));
}

std::optional<Request> Parse(const Value* args) {
  const auto* map = args ? std::get_if<Map>(args) : nullptr;
  if (!map || map->size() != 5) return {};
  const auto* backend = Field<std::string>(*map, "backend");
  const auto* source = Field<std::string>(*map, "source");
  const auto* volume = Field<double>(*map, "volume");
  const auto* paused = Field<bool>(*map, "paused");
  const auto pos = map->find(Value("positionMs"));
  const auto ms = pos != map->end() ? pos->second.TryGetLongValue() : std::nullopt;
  if (!backend || (*backend != "mf" && *backend != "mdk") || !source ||
      source->empty() || source->size() > 4 * 32767 || !ms || *ms < 0 ||
      !volume || !std::isfinite(*volume) || *volume < 0 || *volume > 1 ||
      !paused) return {};
  const int bytes = static_cast<int>(source->size());
  const int n = MultiByteToWideChar(CP_UTF8, MB_ERR_INVALID_CHARS, source->data(),
                                    bytes, nullptr, 0);
  if (n <= 0 || n > 32767) return {};
  std::wstring wide(n, 0);
  if (!MultiByteToWideChar(CP_UTF8, MB_ERR_INVALID_CHARS, source->data(), bytes,
                           wide.data(), n)) return {};
  for (const auto c : wide) {
    if (c < 32 || (c >= 0x7f && c <= 0x9f) || c == 0x2028 || c == 0x2029) return {};
  }
  if (!IsLocalPath(wide) && !IsHttpUri(wide)) return {};
  return Request{*backend == "mf", std::move(wide), *ms, *volume, *paused};
}

std::optional<int64_t> Integer(const Map& map, const char* key) {
  const auto it = map.find(Value(key));
  return it != map.end() ? it->second.TryGetLongValue() : std::nullopt;
}

const char* PhaseName(Phase phase) {
  switch (phase) {
    case Phase::loading: return "loading";
    case Phase::playing: return "playing";
    case Phase::paused: return "paused";
    case Phase::ended: return "ended";
    case Phase::failed: return "failed";
  }
  return "failed";
}

struct Session {
  Session(int64_t session_id, Request request, std::unique_ptr<PlaybackTexture> texture)
      : id(session_id), opening(std::move(request)), video(std::move(texture)) {}

  void Detach() {
    closed = true;
    if (video) video->Unregister();  // While the engine/registrar still exists.
  }

  void Fail() {
    snapshot.phase = Phase::failed;
    backend.reset();  // Stop audio even if Dart hasn't observed the failure yet.
    video.reset();
  }

  void Tick(IDXGIAdapter* adapter) {
    if (closed || snapshot.phase == Phase::failed) return;
    if (opening) {
      auto request = std::move(*opening);
      opening.reset();
      if (!video->CreateDevice(adapter)) return Fail();
      if (closed) return;
      backend = request.mf ? MakeMf() : MakeMdk();
      if (closed) return;
      if (!backend || !backend->Open(*video, request.source, request.position, request.volume,
                                     request.paused)) return Fail();
    }
    // Open/Read/controls/destructors may pump Win32 messages. Only this tick
    // calls the backend; channel handlers just replace pending control values.
    if (closed) return;
    if (const auto volume = std::exchange(pending_volume, {})) backend->SetVolume(*volume);
    if (closed) return;
    if (const auto seek = std::exchange(pending_seek, {})) backend->Seek(*seek);
    if (closed) return;
    if (const auto paused = std::exchange(pending_pause, {})) backend->SetPaused(*paused);
    if (closed) return;
    const auto next = backend->Read();
    if (closed) return;
    if (next.phase == Phase::failed || !video->PublishReady()) return Fail();
    if (closed) return;
    snapshot.duration_ms = std::max<int64_t>(next.duration_ms, 0);
    if (!video->width() || next.phase == Phase::loading) {
      // Metadata/an audio clock isn't a playable video or a resume position.
      snapshot.phase = Phase::loading;
      const auto now = GetTickCount64();
      if (!loading_since) loading_since = now;
      if ((next.phase != Phase::loading && !video->pending()) || now - *loading_since >= kLoadTimeoutMs) {
        Fail();
      }
      return;
    }
    loading_since.reset();
    snapshot.phase = next.phase;
    snapshot.position_ms = std::max<int64_t>(next.position_ms, 0);
  }

  Value StateValue() const {
    return Value(Map{{Value("phase"), Value(PhaseName(snapshot.phase))},
                     {Value("positionMs"), Value(snapshot.position_ms)},
                     {Value("durationMs"), Value(snapshot.duration_ms)},
                     {Value("width"), Value(video ? video->width() : 0)},
                     {Value("height"), Value(video ? video->height() : 0)}});
  }

  const int64_t id;
  std::optional<Request> opening;
  std::optional<double> pending_volume;
  std::optional<int64_t> pending_seek;
  std::optional<bool> pending_pause;
  Snapshot snapshot;
  std::optional<ULONGLONG> loading_since = GetTickCount64();
  bool closed = false;
  std::unique_ptr<PlaybackTexture> video;
  std::unique_ptr<Backend> backend;  // Destroy before the VideoOutput it borrows.
};
}  // namespace

struct PlaybackChannel::State {
  State(FlutterDesktopPluginRegistrarRef registrar, HWND runner_window) : runner(runner_window) {
    if (registrar) {
      textures = FlutterDesktopRegistrarGetTextureRegistrar(registrar);
      FlutterDesktopPluginRegistrarGetGraphicsAdapter(registrar, adapter.GetAddressOf());
    }
  }

  UINT_PTR TimerId() const { return reinterpret_cast<UINT_PTR>(this); }

  void Tick() {
    if (pumping || !active || stopping) return;
    pumping = true;
    {
      const auto session = active;  // A nested close detaches but cannot free the backend mid-call.
      session->Tick(adapter.Get());
      if (active == session && session->snapshot.phase == Phase::failed) KillTimer(runner, TimerId());
    }
    pumping = false;
  }

  void Close() {
    KillTimer(runner, TimerId());
    const bool was_pumping = std::exchange(pumping, true);
    if (auto session = std::move(active)) session->Detach();
    pumping = was_pumping;
  }

  void Open(const Value* args, Result result) {
    auto request = Parse(args);
    // Windows URI validation may enter COM. Recheck ownership before registering.
    if (stopping) { result->Error("cancelled"); return; }
    if (active) { result->Error("busy"); return; }
    if (!request) { result->Error("bad_args"); return; }
    if (!textures || !adapter) { result->Error("unavailable"); return; }
    auto video = PlaybackTexture::Register(textures);
    if (!video || next_id == std::numeric_limits<int64_t>::max() ||
        !SetTimer(runner, TimerId(), kFrameIntervalMs, nullptr)) {
      result->Error("open_failed");
      return;
    }
    const auto texture_id = video->id();
    const auto id = ++next_id;  // Independent of possibly recycled Flutter texture IDs.
    active = std::make_shared<Session>(id, std::move(*request), std::move(video));
    result->Success(Value(Map{{Value("id"), Value(id)}, {Value("textureId"), Value(texture_id)}}));
  }

  void Handle(const flutter::MethodCall<Value>& call, Result result) {
    if (stopping) { result->Error("cancelled"); return; }
    const auto& method = call.method_name();
    if (method == "availability") {
      const bool gpu = textures && adapter;
      result->Success(Value(Map{{Value("mf"), Value(gpu && MfAvailable())},
                                {Value("mdk"), Value(gpu && MdkAvailable())}}));
      return;
    }
    if (method == "open") { Open(call.arguments(), std::move(result)); return; }
    const bool query = method == "state" || method == "close";
    if (!query && method != "pause" && method != "seek" && method != "volume") {
      result->NotImplemented();
      return;
    }
    const auto* args = call.arguments();
    const auto* map = args ? std::get_if<Map>(args) : nullptr;
    const auto id = map ? Integer(*map, "id") : std::nullopt;
    if (!id || *id <= 0 || map->size() != (query ? 1u : 2u)) { result->Error("bad_args"); return; }
    if (!active || active->id != *id) { result->Error("stale_session"); return; }
    if (method == "state") { result->Success(active->StateValue()); return; }
    if (method == "close") {
      const auto& s = active->snapshot;
      const Value pos = s.phase == Phase::loading || s.phase == Phase::failed ? Value() : Value(s.position_ms);
      Close();
      result->Success(Value(Map{{Value("positionMs"), pos}}));
      return;
    }
    if (active->snapshot.phase == Phase::failed) { result->Error("playback_failed"); return; }
    if (method == "pause") {
      const auto* paused = Field<bool>(*map, "paused");
      if (!paused) { result->Error("bad_args"); return; }
      if (active->opening) active->opening->paused = *paused;
      else active->pending_pause = *paused;
    } else if (method == "seek") {
      const auto ms = Integer(*map, "positionMs");
      if (!ms || *ms < 0) { result->Error("bad_args"); return; }
      if (active->opening) active->opening->position = *ms;
      else active->pending_seek = *ms;
    } else {
      const auto* volume = Field<double>(*map, "volume");
      if (!volume || !std::isfinite(*volume) || *volume < 0 || *volume > 1) {
        result->Error("bad_args"); return;
      }
      if (active->opening) active->opening->volume = *volume;
      else active->pending_volume = *volume;
    }
    result->Success();
  }

  HWND runner;
  FlutterDesktopTextureRegistrarRef textures = nullptr;
  Microsoft::WRL::ComPtr<IDXGIAdapter> adapter;
  int64_t next_id = 0;
  bool pumping = false;
  bool stopping = false;
  std::shared_ptr<Session> active;
};

PlaybackChannel::PlaybackChannel(flutter::BinaryMessenger* messenger, FlutterDesktopPluginRegistrarRef registrar,
                                 HWND runner)
    : state_(std::make_shared<State>(registrar, runner)),
      channel_(messenger, "xiugou/native_playback", &flutter::StandardMethodCodec::GetInstance()) {
  channel_.SetMethodCallHandler([weak = std::weak_ptr<State>(state_)](const auto& call, Result result) {
    if (const auto state = weak.lock()) state->Handle(call, std::move(result));
    else result->Error("cancelled");
  });
}

PlaybackChannel::~PlaybackChannel() {
  state_->stopping = true;
  channel_.SetMethodCallHandler(nullptr);
  state_->Close();
}

bool PlaybackChannel::HandleTimer(WPARAM id) {
  const auto state = state_;
  if (id != state->TimerId()) return false;
  state->Tick();
  return true;
}

}  // namespace native_playback

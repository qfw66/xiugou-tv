#ifndef RUNNER_NATIVE_PLAYBACK_BACKEND_H_
#define RUNNER_NATIVE_PLAYBACK_BACKEND_H_

#include <d3d11.h>

#include <cstdint>
#include <memory>
#include <string>

namespace native_playback {

enum class Phase { loading, playing, paused, ended, failed };
struct Snapshot {
  Phase phase = Phase::loading;
  int64_t position_ms = 0;
  int64_t duration_ms = 0;
};

// All methods run on the platform thread. Codecs write a frame into Target()
// and call Present() only after the GPU work has been submitted successfully.
class VideoOutput {
 public:
  virtual ~VideoOutput() = default;
  virtual ID3D11Device* Device() const = 0;
  virtual ID3D11DeviceContext* Context() const = 0;
  virtual ID3D11Texture2D* Target(int width, int height) = 0;
  virtual bool Present() = 0;
};

class Backend {
 public:
  virtual ~Backend() = default;
  virtual bool Open(VideoOutput& video, const std::wstring& source, int64_t start_ms,
                    double volume, bool paused) = 0;
  virtual Snapshot Read() = 0;
  virtual void SetPaused(bool paused) = 0;
  virtual void Seek(int64_t ms) = 0;
  virtual void SetVolume(double volume) = 0;  // 0..1
};

bool MfAvailable();
std::unique_ptr<Backend> MakeMf();
bool MdkAvailable();
std::unique_ptr<Backend> MakeMdk();

}  // namespace native_playback
#endif  // RUNNER_NATIVE_PLAYBACK_BACKEND_H_

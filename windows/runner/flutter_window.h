#ifndef RUNNER_FLUTTER_WINDOW_H_
#define RUNNER_FLUTTER_WINDOW_H_

#include <flutter/dart_project.h>
#include <flutter/flutter_view_controller.h>

#include <memory>

#include "process_job.h"

#include "win32_window.h"
#include "window_fullscreen.h"

// A window that does nothing but host a Flutter view.
class FlutterWindow : public Win32Window {
 public:
  // Creates a new FlutterWindow hosting a Flutter view running |project|.
  explicit FlutterWindow(const flutter::DartProject& project);
  virtual ~FlutterWindow();

 protected:
  // Win32Window:
  bool OnCreate() override;
  void OnDestroy() override;
  LRESULT MessageHandler(HWND window, UINT const message, WPARAM const wparam,
                         LPARAM const lparam) noexcept override;

 private:
  // The project to run.
  flutter::DartProject project_;

  // The Flutter instance hosted by this window.
  std::unique_ptr<flutter::FlutterViewController> flutter_controller_;

  // Keeps the process-job channel alive for the lifetime of the engine.
  std::unique_ptr<flutter::MethodChannel<flutter::EncodableValue>>
      process_job_channel_;

  // §52 一步式全屏；通道析构早于本对象（OnDestroy 里先清通道）。
  std::unique_ptr<WindowFullscreen> fullscreen_;
  std::unique_ptr<flutter::MethodChannel<flutter::EncodableValue>>
      fullscreen_channel_;
};

#endif  // RUNNER_FLUTTER_WINDOW_H_

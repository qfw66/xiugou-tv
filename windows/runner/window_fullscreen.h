#ifndef RUNNER_WINDOW_FULLSCREEN_H_
#define RUNNER_WINDOW_FULLSCREEN_H_

#include <flutter/binary_messenger.h>
#include <flutter/encodable_value.h>
#include <flutter/method_channel.h>
#include <windows.h>

#include <memory>
#include <optional>

// 方法通道 "xiugou/window_fullscreen"（§52 全屏切换抽动）。
//
// 取代 window_manager 0.3.9 的 setFullScreen：插件进入全屏前先发
// SC_MAXIMIZE（窗口先动画到「最大化 + 任务栏可见」的中间尺寸，再跳到整屏），
// 退出时先 Restore() 再挪回原位，一次切换 Flutter 要按 2~3 个不同尺寸布局，
// 表现为闪屏 / 画面跳动。这里改成一次 SetWindowPos 直接到目标矩形。
//
// 方法：
//   setFullScreen({isFullScreen: bool}) -> bool  实际生效后的状态
//   isFullScreen() -> bool
class WindowFullscreen {
 public:
  explicit WindowFullscreen(HWND window) : window_(window) {}

  bool IsFullScreen() const { return fullscreen_; }
  void SetFullScreen(bool value);

  // 必须在插件 HandleTopLevelWindowProc 之前调用：全屏期间接管
  // WM_NCCALCSIZE，让客户区等于整个窗口矩形（插件对「隐藏标题栏」样式
  // 会扣掉 8px 边框，直接用会在屏幕三边留缝）。
  std::optional<LRESULT> HandleMessage(UINT message, WPARAM wparam,
                                       LPARAM lparam);

 private:
  HWND window_;
  bool fullscreen_ = false;
  LONG_PTR saved_style_ = 0;
  RECT saved_rect_{};
};

std::unique_ptr<flutter::MethodChannel<flutter::EncodableValue>>
RegisterWindowFullscreenChannel(flutter::BinaryMessenger* messenger,
                                WindowFullscreen* fullscreen);

#endif  // RUNNER_WINDOW_FULLSCREEN_H_

#include "process_job.h"

#include <flutter/standard_method_codec.h>
#include <windows.h>

#include <variant>

namespace {

// Lazily created, process-wide job. Not inheritable, never closed explicitly.
HANDLE KillOnCloseJob() {
  static HANDLE job = [] {
    HANDLE handle = ::CreateJobObjectW(nullptr, nullptr);
    if (handle == nullptr) {
      return static_cast<HANDLE>(nullptr);
    }
    JOBOBJECT_EXTENDED_LIMIT_INFORMATION info = {};
    info.BasicLimitInformation.LimitFlags = JOB_OBJECT_LIMIT_KILL_ON_JOB_CLOSE;
    if (!::SetInformationJobObject(handle, JobObjectExtendedLimitInformation,
                                   &info, sizeof(info))) {
      ::CloseHandle(handle);
      return static_cast<HANDLE>(nullptr);
    }
    return handle;
  }();
  return job;
}

bool Adopt(DWORD pid) {
  HANDLE job = KillOnCloseJob();
  if (job == nullptr) {
    return false;
  }
  HANDLE process =
      ::OpenProcess(PROCESS_SET_QUOTA | PROCESS_TERMINATE, FALSE, pid);
  if (process == nullptr) {
    return false;
  }
  const BOOL ok = ::AssignProcessToJobObject(job, process);
  ::CloseHandle(process);
  return ok != FALSE;
}

}  // namespace

std::unique_ptr<flutter::MethodChannel<flutter::EncodableValue>>
RegisterProcessJobChannel(flutter::BinaryMessenger* messenger) {
  auto channel = std::make_unique<flutter::MethodChannel<flutter::EncodableValue>>(
      messenger, "xiugou/process_job",
      &flutter::StandardMethodCodec::GetInstance());
  channel->SetMethodCallHandler(
      [](const flutter::MethodCall<flutter::EncodableValue>& call,
         std::unique_ptr<flutter::MethodResult<flutter::EncodableValue>>
             result) {
        if (call.method_name() != "adopt") {
          result->NotImplemented();
          return;
        }
        const auto* args = call.arguments();
        DWORD pid = 0;
        if (const auto* pid32 = std::get_if<int32_t>(args)) {
          pid = static_cast<DWORD>(*pid32);
        } else if (const auto* pid64 = std::get_if<int64_t>(args)) {
          pid = static_cast<DWORD>(*pid64);
        } else {
          result->Error("bad_args", "pid must be an integer");
          return;
        }
        result->Success(flutter::EncodableValue(Adopt(pid)));
      });
  return channel;
}

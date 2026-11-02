#ifndef RUNNER_PROCESS_JOB_H_
#define RUNNER_PROCESS_JOB_H_

#include <flutter/binary_messenger.h>
#include <flutter/encodable_value.h>
#include <flutter/method_channel.h>

#include <memory>

// Method channel "xiugou/process_job".
//
// adopt(pid) puts a child process (and every process it spawns afterwards)
// into a Job Object created with JOB_OBJECT_LIMIT_KILL_ON_JOB_CLOSE. The job
// handle is owned by this process and is never closed explicitly, so when the
// app exits for any reason - normal close, crash, or being killed - the OS
// closes the handle and terminates the whole adopted tree.
//
// Only processes that are explicitly adopted join the job: the app's own
// detached launches (restart after reset, update installer, opening URLs)
// must survive the app and therefore are never adopted.
std::unique_ptr<flutter::MethodChannel<flutter::EncodableValue>>
RegisterProcessJobChannel(flutter::BinaryMessenger* messenger);

#endif  // RUNNER_PROCESS_JOB_H_

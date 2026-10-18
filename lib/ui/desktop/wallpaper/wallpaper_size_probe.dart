import 'dart:io';
import 'dart:ui' as ui;

/// 只读文件头解析图片像素尺寸（SET-08）。
///
/// 用 [ui.ImageDescriptor.encoded] 而不是整图解码：9000×9000 的图整图解码
/// 约 324 MB，在「选择壁纸」阶段就可能把内存打满。返回 null 表示无法识别。
Future<({int width, int height})?> probeWallpaperImageSize(File file) async {
  ui.ImmutableBuffer? buffer;
  ui.ImageDescriptor? descriptor;
  try {
    buffer = await ui.ImmutableBuffer.fromUint8List(await file.readAsBytes());
    descriptor = await ui.ImageDescriptor.encoded(buffer);
    return (width: descriptor.width, height: descriptor.height);
  } catch (_) {
    return null;
  } finally {
    descriptor?.dispose();
    buffer?.dispose();
  }
}

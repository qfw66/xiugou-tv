import 'package:file_selector/file_selector.dart';

import '../../../core/player/local_subtitle_files.dart';

typedef SubtitleFilePicker =
    Future<XFile?> Function({required List<XTypeGroup> acceptedTypeGroups});

Future<String?> pickLocalSubtitleFile(SubtitleFilePicker? picker) async {
  final file = await (picker ?? openFile)(
    acceptedTypeGroups: const [
      XTypeGroup(label: '字幕文件', extensions: LocalSubtitleFiles.extensions),
    ],
  );
  return file?.path;
}

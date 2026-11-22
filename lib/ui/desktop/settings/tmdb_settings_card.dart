import 'package:flutter/material.dart';

import '../../../core/settings/models/tmdb_preferences.dart';
import '../../theme/app_palette.dart';
import '../../theme/app_tokens.dart';

class TmdbSettingsCard extends StatefulWidget {
  const TmdbSettingsCard({
    super.key,
    required this.preferences,
    required this.onSave,
  });
  final TmdbPreferences preferences;
  final Future<void> Function(TmdbPreferences) onSave;

  @override
  State<TmdbSettingsCard> createState() => _TmdbSettingsCardState();
}

class _TmdbSettingsCardState extends State<TmdbSettingsCard> {
  late final _key = TextEditingController(text: widget.preferences.apiKey);
  bool _saving = false;
  String? _error, _feedback;

  @override
  void dispose() {
    _key.dispose();
    super.dispose();
  }

  Future<void> _save({
    bool? cinematic,
    TmdbEndpoint? endpoint,
    TmdbImageEndpoint? imageEndpoint,
    bool applyKey = false,
  }) async {
    if (_saving) return;
    final old = widget.preferences;
    final key = applyKey ? _key.text.trim() : old.apiKey;
    if (!TmdbPreferences.acceptsKey(key)) {
      setState(() {
        _error = '请输入 32 位 TMDB v3 API Key，或留空使用内置密钥';
        _feedback = null;
      });
      return;
    }
    setState(() {
      _saving = true;
      _error = null;
      _feedback = null;
    });
    try {
      await widget.onSave(
        TmdbPreferences(
          cinematic: cinematic ?? old.cinematic,
          endpoint: endpoint ?? old.endpoint,
          imageEndpoint: imageEndpoint ?? old.imageEndpoint,
          apiKey: key,
        ),
      );
      if (mounted && applyKey) {
        setState(() => _feedback = key.isEmpty ? '已恢复内置密钥' : '个人密钥已保存');
      }
    } catch (_) {
      if (mounted) setState(() => _feedback = '影片详情设置未保存');
    } finally {
      if (mounted) setState(() => _saving = false);
    }
  }

  Widget _endpointField<T extends Enum>({
    required String label,
    required T value,
    required List<T> options,
    required String Function(T) describe,
    required ValueChanged<T> onChanged,
  }) => InputDecorator(
    decoration: InputDecoration(
      labelText: label,
      border: const OutlineInputBorder(),
    ),
    child: DropdownButtonHideUnderline(
      child: DropdownButton<T>(
        value: value,
        isExpanded: true,
        isDense: true,
        items: [
          for (final option in options)
            DropdownMenuItem(
              value: option,
              child: Text(describe(option), overflow: TextOverflow.ellipsis),
            ),
        ],
        onChanged: _saving
            ? null
            : (v) {
                if (v != null) onChanged(v);
              },
      ),
    ),
  );

  @override
  Widget build(BuildContext context) {
    final prefs = widget.preferences;
    return Column(
      crossAxisAlignment: CrossAxisAlignment.start,
      children: [
        Text(
          '影片详情',
          style: TextStyle(
            fontSize: AppType.label,
            fontWeight: FontWeight.bold,
            color: context.palette.textTitle,
          ),
        ),
        const SizedBox(height: 8),
        SegmentedButton<bool>(
          segments: const [
            ButtonSegment(
              value: false,
              icon: Icon(Icons.view_compact_outlined),
              label: Text('经典弹窗'),
            ),
            ButtonSegment(
              value: true,
              icon: Icon(Icons.panorama_outlined),
              label: Text('TMDB 详情页'),
            ),
          ],
          selected: {prefs.cinematic},
          onSelectionChanged: _saving
              ? null
              : (v) => _save(cinematic: v.single),
        ),
        const SizedBox(height: 16),
        _endpointField<TmdbEndpoint>(
          label: 'TMDB 资料接口',
          value: prefs.endpoint,
          options: TmdbEndpoint.values,
          describe: (e) =>
              '${e == TmdbEndpoint.official ? '官方 API' : '资料镜像'} · ${e.host}',
          onChanged: (v) => _save(endpoint: v),
        ),
        const SizedBox(height: 12),
        _endpointField<TmdbImageEndpoint>(
          label: 'TMDB 图片线路',
          value: prefs.imageEndpoint,
          options: TmdbImageEndpoint.values,
          describe: (e) =>
              '${e == TmdbImageEndpoint.official ? '图片直连' : '图片反代'} · ${Uri.parse(e.baseUrl).host}',
          onChanged: (v) => _save(imageEndpoint: v),
        ),
        const SizedBox(height: AppSpacing.sm),
        const SelectableText('TMDB 官网：https://www.themoviedb.org/'),
        const SizedBox(height: 12),
        TextField(
          controller: _key,
          obscureText: true,
          autocorrect: false,
          enableSuggestions: false,
          onSubmitted: (_) => _save(applyKey: true),
          onChanged: (_) {
            if (_feedback != null || _error != null) {
              setState(() {
                _feedback = null;
                _error = null;
              });
            }
          },
          decoration: InputDecoration(
            labelText: '个人 TMDB API Key',
            hintText: '留空使用内置密钥',
            errorText: _error,
            border: const OutlineInputBorder(),
            suffixIcon: IconButton(
              tooltip: '保存密钥',
              icon: const Icon(Icons.save_outlined),
              onPressed: _saving ? null : () => _save(applyKey: true),
            ),
          ),
        ),
        if (_feedback != null)
          Padding(
            padding: const EdgeInsets.only(top: 6),
            child: Text(_feedback!),
          ),
      ],
    );
  }
}

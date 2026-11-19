import '../config/models/vod_config.dart';

class BrowserVerificationRequest {
  const BrowserVerificationRequest({
    required this.site,
    required this.id,
    required this.origin,
    required this.method,
  });

  final Site site;
  final String id;
  final Uri origin;
  final String method;

  static BrowserVerificationRequest? fromResponse(
      Site site, String method, Object? value) {
    if (site.api != 'csp_GM' && site.api != 'GM') return null;
    if (value is! Map) return null;
    final id = value['id'];
    final rawUrl = value['url'];
    final rawOrigin = value['origin'];
    if (id is! String ||
        !RegExp(r'^[a-f0-9]{32}$').hasMatch(id) ||
        rawUrl is! String ||
        rawOrigin is! String) {
      return null;
    }
    final url = Uri.tryParse(rawUrl);
    final origin = Uri.tryParse(rawOrigin);
    if (url == null ||
        origin == null ||
        !const {'http', 'https'}.contains(url.scheme) ||
        !const {'http', 'https'}.contains(origin.scheme) ||
        origin.host.isEmpty ||
        url.host.isEmpty ||
        url.userInfo.isNotEmpty ||
        origin.userInfo.isNotEmpty ||
        origin.hasQuery ||
        origin.hasFragment ||
        (origin.path.isNotEmpty && origin.path != '/') ||
        url.origin != origin.origin) {
      return null;
    }
    return BrowserVerificationRequest(
        site: site, id: id, origin: Uri.parse(origin.origin), method: method);
  }
}

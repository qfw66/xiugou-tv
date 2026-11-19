<?php
// Xiugou's stdin bridge for the public BaseSpider method contract.
// Source code and its libraries remain source-owned; no HTTP server is started.
define('DRPY_BRIDGE', true);
ini_set('display_errors', '0');
ini_set('log_errors', '0');
date_default_timezone_set('Asia/Shanghai');
$level = ob_get_level();
// Discard incidental source output (including init/method warnings), keeping bounded memory.
ob_start(static function ($text) { return ''; }, 8192);
try {
    if (PHP_VERSION_ID < 80300) throw new RuntimeException('PHP 8.3 required');
    $request = json_decode(stream_get_contents(STDIN, 4 * 1024 * 1024 + 1), true, 512, JSON_THROW_ON_ERROR);
    $method = $request['method'] ?? '';
    $allowed = ['init', 'homeContent', 'homeVideoContent', 'categoryContent', 'detailContent',
        'searchContent', 'playerContent', 'localProxy', 'action', 'liveContent'];
    if (!in_array($method, $allowed, true)) throw new InvalidArgumentException('Invalid method');
    require $request['file'];
    // The upstream base class changes display_errors during require.
    ini_set('display_errors', '0');
    ini_set('log_errors', '0');
    $spider = new Spider();
    $env = $request['env'] ?? [];
    if (method_exists($spider, 'setEnv')) $spider->setEnv($env);
    if ($method !== 'init' && method_exists($spider, 'init')) $spider->init($env['ext'] ?? '');
    $optional = ['init', 'homeVideoContent', 'action', 'liveContent'];
    if (!method_exists($spider, $method)) {
        if (!in_array($method, $optional, true)) throw new BadMethodCallException('Missing method');
        $value = null;
    } else {
        $value = $spider->$method(...($request['args'] ?? []));
    }
    // Preserve arbitrary binary localProxy bodies across the JSON transport.
    if ($method === 'localProxy' && is_array($value) && count($value) >= 3
            && (int)($value[4] ?? 0) === 0 && is_string($value[2])) {
        $value[2] = base64_encode($value[2]);
        $value[4] = 1;
    }
    $response = ['ok' => true, 'value' => $value];
} catch (Throwable $error) {
    // Source exceptions can embed cookies or signed URLs. Return location, never their raw text.
    $response = ['ok' => false, 'kind' => get_class($error),
        'file' => basename($error->getFile()), 'line' => $error->getLine()];
}
while (ob_get_level() > $level) ob_end_clean();
echo json_encode($response, JSON_UNESCAPED_UNICODE | JSON_INVALID_UTF8_SUBSTITUTE | JSON_THROW_ON_ERROR);
exit($response['ok'] ? 0 : 1);

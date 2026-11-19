package com.fongmi.companion;

import java.io.IOException;
import java.util.Map;

/** Bounded HTTP diagnostics from a Cat source, without copying response payloads. */
final class CatNodeHttpException extends IOException {
    final int status;
    final boolean missingRoute;

    CatNodeHttpException(int status, String route, Map<String,Object> body) {
        super("猫源接口 HTTP " + status + machineCode(body) + "：" + route);
        this.status = status;
        String message = CatNodeRuntime.text(body.get("message"));
        String error = CatNodeRuntime.text(body.get("error"));
        String method = route.substring(route.lastIndexOf('/') + 1);
        String endpoint = route.replaceFirst("^/spider/", "").replaceFirst("/[0-9]+/", "/");
        this.missingRoute = status == 404 && (
                message.equals("站点或接口不存在: " + endpoint) || message.equals("站点或接口不存在：" + endpoint)
                || error.equals("站点或接口不存在: " + endpoint) || error.equals("站点或接口不存在：" + endpoint)
                || message.equals("Route POST:" + route + " not found")
                || error.equals("Dynamic spider handler not found: post /" + method)
                || "ROUTE_NOT_FOUND".equals(body.get("code")));
    }

    private static String machineCode(Map<String,Object> body) {
        Object code = body.get("code");
        return code instanceof String value && value.matches("[A-Z][A-Z0-9_]{0,63}") ? " (" + value + ")" : "";
    }
}

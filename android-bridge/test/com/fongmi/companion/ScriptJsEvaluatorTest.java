package com.fongmi.companion;

import com.google.gson.JsonElement;
import com.google.gson.JsonObject;
import com.google.gson.JsonParser;

/** Real Graal contexts, including cancellation; no upstream requests. */
public final class ScriptJsEvaluatorTest {
    private static int assertions;

    public static void main(String[] args) throws Exception {
        equal("md5X('abc')", "\"900150983cd24fb0d6963f7d28e17f72\"");
        equal("[null,true,false,4.5,'中文😀',{a:[1,2]}]", "[null,true,false,4.5,\"中文😀\",{\"a\":[1,2]}]");
        equal("[md5X(''),md5X('message digest'),md5X(123),md5X(null),md5X()]",
                "[\"d41d8cd98f00b204e9800998ecf8427e\",\"f96b697d7cb7938d525a2f31aaf161d0\","
                        + "\"202cb962ac59075b964b07152d234b70\",\"37a6259cc0c1dae299a7866489dff0bd\","
                        + "\"5e543256c480ac577d30f76f9120eb74\"]");
        equal("var CryptoJS={MD5:md5X}; CryptoJS.MD5('abc').toString()",
                "\"900150983cd24fb0d6963f7d28e17f72\"");
        equal("md5X=()=> 'bad'; delete globalThis.md5X; md5X('abc')",
                "\"900150983cd24fb0d6963f7d28e17f72\"");
        failure("Object.defineProperty(globalThis,'md5X',{value:1})", "js-error");
        equal("var leaked=7; Object.prototype.polluted=8; 'ok'", "\"ok\"");
        equal("[typeof leaked,typeof ({}).polluted]", "[\"undefined\",\"undefined\"]");
        equal("Object.prototype.toJSON=()=> 'bad'; Array.prototype.toJSON=()=> 'bad'; ({a:[1,2]})",
                "{\"a\":[1,2]}");
        equal("JSON.stringify=()=> 'bad'; Object.keys=()=> []; Set.prototype.has=()=>true; ({a:[1]})", "{\"a\":[1]}");
        equal("print('TEST_SECRET'); console.log('TEST_SECRET'); 7", "7");
        equal("Object.freeze({a:1,b:[2]})", "{\"a\":1,\"b\":[2]}");
        equal("Object.freeze([1,Object.freeze({a:2})])", "[1,{\"a\":2}]");
        equal("Object.freeze(Object.assign(Object.create(null),{a:1}))", "{\"a\":1}");
        equal("Object.prototype.value='polluted'; Object.prototype.get=()=>1; ({a:1})", "{\"a\":1}");

        String[] unsupported = {
                "undefined", "NaN", "Infinity", "1n", "Symbol('secret')", "(()=>1)",
                "({x:undefined})", "[undefined]", "[1,,3]", "({f:()=>1})", "new Date()", "new Map()",
                "new Uint8Array([1,2])", "({get a(){throw new Error('TEST_SECRET')}})",
                "var cycle={}; cycle.self=cycle; cycle", "({[Symbol('x')]:1})",
                "Promise.resolve(1)", "new Promise(()=>{})", "(async()=>1)()", "({nested:Promise.resolve(1)})",
                "var p=Promise.resolve(1); Object.setPrototypeOf(p,null); p",
                "var p=Promise.resolve(1); Object.setPrototypeOf(p,null); Object.defineProperty(p,'constructor',{value:null}); p",
                "var p=Promise.resolve(1); Object.setPrototypeOf(p,null); Object.freeze(p)",
                "var p=Promise.resolve(1); Object.setPrototypeOf(p,Object.prototype); Object.freeze(p)",
                "var p=Promise.resolve(1); Object.setPrototypeOf(p,null); Object.defineProperty(p,'constructor',"
                        + "{value:new Proxy({}, {get(){throw 1}})}); Object.freeze(p)",
                "Object.prototype.value=1; ({get secret(){return 'TEST_SECRET'}})",
                "'x'.repeat(1048577)", "new Array(10001).fill(1)",
                "var deep=0; for(var i=0;i<70;i++) deep=[deep]; deep"
        };
        for (String source : unsupported) failure(source, "unsupported-result");
        failure("throw new Error('TEST_SECRET')", "js-error");
        failure("function {", "js-error");
        failure("Java.type('java.lang.System').getenv()", "js-error");
        failure("Java.type('java.io.File').new('secret')", "js-error");
        failure("Packages.java.lang.Runtime.getRuntime().exec('whoami')", "js-error");
        failure("load('file:///secret')", "js-error");
        failure("read('secret')", "js-error");
        failure("Polyglot.eval('python','1')", "js-error");
        failure("process.env", "js-error");
        equal("[typeof JavaImporter,typeof Worker,typeof fetch,typeof quit,typeof readbuffer]",
                "[\"undefined\",\"undefined\",\"undefined\",\"undefined\",\"undefined\"]");
        equal("[typeof md5X.getClass,typeof md5X.class,typeof md5X.execute]",
                "[\"undefined\",\"undefined\",\"undefined\"]");
        failure("md5X.constructor(\"return Java.type('java.lang.Runtime')\")()", "js-error");

        invalid("{}", "invalid-request");
        invalid("{\"source\":\"1\",\"source\":\"2\"}", "invalid-request");
        invalid("{source:'1'}", "invalid-request");
        invalid("{\"source\":\"1\"} {}", "invalid-request");
        invalid("{\"source\":\"1\",\"timeout\":0}", "invalid-request");
        invalid("{\"source\":\"1\",\"timeout\":1.5}", "invalid-request");
        invalid("{\"source\":\"1\",\"timeout\":true}", "invalid-request");
        invalid("{\"source\":\"1\",\"globals\":{\"md5X\":2}}", "invalid-request");
        invalid("{\"source\":\"1\",\"globals\":{\"__proto__\":{}}}", "invalid-request");
        invalid("{\"source\":\"1\",\"globals\":{\"Object\":{}}}", "invalid-request");
        invalid("{\"source\":\"1\",\"globals\":{\"a\":NaN}}", "invalid-request");
        invalid("{\"source\":\"1\",\"globals\":{\"a\":9007199254740992}}", "invalid-request");
        invalid(" ".repeat(1048577), "input-limit");
        JsonObject request = request("[data.__proto__.polluted, typeof ({}).polluted, data.constructor.prototype.x]", 5000);
        request.add("globals", JsonParser.parseString("{\"data\":{\"__proto__\":{\"polluted\":true},\"constructor\":{\"prototype\":{\"x\":7}}}}"));
        check(result(request).equals(JsonParser.parseString("[true,\"undefined\",7]")), "nested prototype keys remain data");

        for (String source : new String[]{"while(true){}", "({get x(){while(true){} }})",
                "Promise.resolve().then(function spin(){Promise.resolve().then(spin)}); 1"}) {
            long started = System.nanoTime();
            JsonObject reply = response(request(source, 200));
            check(!reply.get("ok").getAsBoolean(), "loop must fail");
            String code = reply.get("error").getAsString();
            check(code.equals("timeout") || (source.contains("get x") && code.equals("unsupported-result")), "loop error is bounded");
            check((System.nanoTime() - started) / 1_000_000 < 5000, "context cancellation must terminate execution");
            equal("6*7", "42");
        }
        // A cancelled context cannot leave a non-daemon executor holding the JVM open.
        check(Thread.getAllStackTraces().keySet().stream()
                .noneMatch(thread -> thread.isAlive() && thread.getName().equals("script-js-deadline") && !thread.isDaemon()),
                "watchdog must not retain the process");
        System.out.println("ScriptJsEvaluatorTest OK (" + assertions + " assertions)");
    }

    private static JsonObject request(String source, int timeout) {
        JsonObject request = new JsonObject();
        request.addProperty("source", source);
        request.addProperty("timeout", timeout);
        return request;
    }

    private static JsonObject response(JsonObject request) {
        return JsonParser.parseString(ScriptJsEvaluator.evaluate(request.toString())).getAsJsonObject();
    }

    private static JsonElement result(JsonObject request) {
        JsonObject response = response(request);
        check(response.get("ok").getAsBoolean(), "request must succeed: " + response);
        return response.get("result");
    }

    private static void equal(String source, String expected) {
        check(result(request(source, 5000)).equals(JsonParser.parseString(expected)), "result: " + source);
    }

    private static void failure(String source, String code) {
        JsonObject response = response(request(source, 5000));
        check(!response.get("ok").getAsBoolean(), "request must fail: " + source);
        check(code.equals(response.get("error").getAsString()), "error code: " + source + " -> " + response);
        check(!response.toString().contains("TEST_SECRET"), "errors must not leak guest messages");
    }

    private static void invalid(String input, String code) {
        JsonObject response = JsonParser.parseString(ScriptJsEvaluator.evaluate(input)).getAsJsonObject();
        check(!response.get("ok").getAsBoolean() && code.equals(response.get("error").getAsString()), "invalid request");
    }

    private static void check(boolean condition, String message) {
        assertions++;
        if (!condition) throw new AssertionError(message);
    }
}

package com.fongmi.companion;

import com.google.gson.JsonArray;
import com.google.gson.JsonElement;
import com.google.gson.JsonNull;
import com.google.gson.JsonObject;
import com.google.gson.JsonPrimitive;
import com.google.gson.stream.JsonReader;
import com.google.gson.stream.JsonToken;
import org.graalvm.polyglot.Context;
import org.graalvm.polyglot.EnvironmentAccess;
import org.graalvm.polyglot.HostAccess;
import org.graalvm.polyglot.PolyglotAccess;
import org.graalvm.polyglot.Value;
import org.graalvm.polyglot.io.IOAccess;
import org.graalvm.polyglot.proxy.ProxyExecutable;

import java.io.ByteArrayInputStream;
import java.io.OutputStream;
import java.io.StringReader;
import java.math.BigDecimal;
import java.nio.ByteBuffer;
import java.nio.charset.CodingErrorAction;
import java.nio.charset.StandardCharsets;
import java.security.MessageDigest;
import java.util.HexFormat;
import java.util.Set;
import java.util.concurrent.Executors;
import java.util.concurrent.ScheduledExecutorService;
import java.util.concurrent.TimeUnit;
import java.util.concurrent.atomic.AtomicBoolean;
import java.util.concurrent.atomic.AtomicReference;

/** One request, one restricted context. This does not use JavaScriptSpider. */
public final class ScriptJsEvaluator {
    private static final int MAX_BYTES = 1024 * 1024;
    private static final int MAX_DEPTH = 64;
    private static final int MAX_NODES = 10000;
    private static final Set<String> REQUEST_KEYS = Set.of("source", "globals", "timeout");
    private static final Set<String> PROTECTED = Set.of("md5X", "__proto__", "constructor", "prototype");

    // Capture the intrinsics before guest code can mutate them. JSON data is parsed
    // inside the guest realm; no caller-provided object becomes a host object.
    private static final String BOOTSTRAP = """
            (digest) => {
                const str = String, parse = JSON.parse, stringify = JSON.stringify;
                const keys = Object.keys, define = Object.defineProperty;
                const descriptor = Object.getOwnPropertyDescriptor, proto = Object.getPrototypeOf;
                const symbols = Object.getOwnPropertySymbols, create = Object.create;
                const isArray = Array.isArray, finite = Number.isFinite;
                const safeInteger = Number.isSafeInteger, integer = Number.isInteger;
                const ObjectCtor = Object, objectProto = Object.prototype, functionProto = Function.prototype;
                const apply = Reflect.apply;
                const promiseThen = Promise.prototype.then, noop = () => {};
                const freeze = Object.freeze, setProto = Object.setPrototypeOf;
                const extensible = Object.isExtensible, own = Object.hasOwn;
                const species = Symbol.species;
                function dataProperty(value, name) {
                    for (let at = value, depth = 0; at !== null; at = proto(at)) {
                        if (++depth > 64) throw new Error('unsupported');
                        const property = descriptor(at, name);
                        if (property) {
                            if (!own(property, 'value')) throw new Error('unsupported');
                            return property.value;
                        }
                    }
                }
                const SetCtor = Set, setHas = Set.prototype.has;
                const setAdd = Set.prototype.add, setRemove = Set.prototype.delete;
                define(globalThis, 'md5X', {
                    value: freeze(function md5X(value) { return digest(str(value)); }),
                    writable: false, configurable: false, enumerable: false
                });
                return {
                    install(json) {
                        const values = parse(json);
                        for (const name of keys(values)) {
                            if (name in globalThis) throw new Error('protected-global');
                            define(globalThis, name, {
                                value: values[name], writable: true, configurable: true, enumerable: true
                            });
                        }
                    },
                    encode(value) {
                        let nodes = 0, size = 0;
                        const seen = new SetCtor(), has = setHas;
                        const add = setAdd, remove = setRemove;
                        function walk(v, depth) {
                            if (++nodes > 10000 || depth > 64) throw new Error('result-limit');
                            if (v === null || typeof v === 'boolean') { size += 5; return v; }
                            if (typeof v === 'string') {
                                if (v.length > 1048448) throw new Error('result-limit');
                                size += stringify(v).length;
                                if (size > 1048448) throw new Error('result-limit');
                                return v;
                            }
                            if (typeof v === 'number') {
                                if (!finite(v) || (integer(v) && !safeInteger(v))) throw new Error('unsupported');
                                size += 24;
                                return v;
                            }
                            if (typeof v !== 'object') throw new Error('unsupported');
                            if (symbols(v).length) throw new Error('unsupported');
                            const array = isArray(v), p = proto(v);
                            if (!array && p !== objectProto && p !== null) throw new Error('unsupported');
                            // Promise.then checks its internal brand before reading
                            // constructor. A private sentinel getter prevents species,
                            // prototype or constructor tampering from hiding a Promise.
                            const previous = descriptor(v, 'constructor');
                            let promise = false;
                            // Array.isArray uses an internal brand; arrays cannot be Promises.
                            if (!array && (previous ? previous.configurable : extensible(v))) {
                                const sentinel = create(null), trap = create(null);
                                trap.get = () => { throw sentinel; };
                                trap.configurable = true;
                                try {
                                    define(v, 'constructor', trap);
                                    try { apply(promiseThen, v, [noop, noop]); promise = true; }
                                    catch (error) { promise = error === sentinel; }
                                } finally {
                                    if (previous) define(v, 'constructor', setProto(previous, null));
                                    else delete v.constructor;
                                }
                            } else if (!array) {
                                // Frozen data cannot receive the sentinel. Only the
                                // captured Object constructor and its ordinary prototype
                                // chain are safe for this fallback: a Proxy can disagree
                                // between descriptor lookup and Promise's species lookup.
                                const ctor = dataProperty(v, 'constructor');
                                if (ctor !== undefined) {
                                    if (ctor !== ObjectCtor || proto(ctor) !== functionProto
                                            || proto(functionProto) !== objectProto || proto(objectProto) !== null)
                                        throw new Error('unsupported');
                                    const chosen = dataProperty(ctor, species);
                                    if (chosen !== undefined && chosen !== null) throw new Error('unsupported');
                                }
                                try { apply(promiseThen, v, [noop, noop]); promise = true; } catch (_) {}
                            }
                            if (promise) throw new Error('unsupported');
                            if (apply(has, seen, [v])) throw new Error('cycle');
                            apply(add, seen, [v]);
                            const output = array ? [] : create(null);
                            // Prevent a guest-written Array.prototype.toJSON from running.
                            if (array) setProto(output, null);
                            const names = keys(v);
                            if (array && names.length !== v.length) throw new Error('unsupported');
                            size += 2;
                            for (let i = 0; i < names.length; i++) {
                                const name = array ? str(i) : names[i];
                                const property = descriptor(v, name);
                                if (!property || !own(property, 'value')) throw new Error('unsupported');
                                size += stringify(name).length + 2;
                                if (size > 1048448) throw new Error('result-limit');
                                const copied = create(null);
                                copied.value = walk(property.value, depth + 1);
                                copied.enumerable = true;
                                define(output, name, copied);
                            }
                            apply(remove, seen, [v]);
                            return output;
                        }
                        return stringify(walk(value, 0));
                    }
                };
            }
            """;

    private ScriptJsEvaluator() {}

    /** Public for the main-style contract test; returns only the wire envelope. */
    public static String evaluate(String input) {
        long started = System.nanoTime();
        final JsonObject request;
        final int timeout;
        final JsonObject globals;
        try {
            if (input.length() > MAX_BYTES || input.getBytes(StandardCharsets.UTF_8).length > MAX_BYTES) {
                return error("input-limit");
            }
            JsonElement parsed = parseJson(input);
            if (!parsed.isJsonObject()) return error("invalid-request");
            request = parsed.getAsJsonObject();
            if (!REQUEST_KEYS.containsAll(request.keySet()) || !isString(request.get("source"))) {
                return error("invalid-request");
            }
            JsonElement requestedGlobals = request.get("globals");
            if (requestedGlobals != null && !requestedGlobals.isJsonObject()) return error("invalid-request");
            globals = requestedGlobals == null ? new JsonObject() : requestedGlobals.getAsJsonObject();
            if (globals.keySet().stream().anyMatch(PROTECTED::contains)) return error("invalid-request");
            JsonElement requestedTimeout = request.get("timeout");
            if (requestedTimeout == null) {
                timeout = 5000;
            } else {
                if (!requestedTimeout.isJsonPrimitive() || !requestedTimeout.getAsJsonPrimitive().isNumber()) {
                    return error("invalid-request");
                }
                timeout = requestedTimeout.getAsBigDecimal().intValueExact();
                if (timeout <= 0) return error("invalid-request");
            }
        } catch (Exception | StackOverflowError ignored) {
            return error("invalid-request");
        }

        AtomicReference<Context> active = new AtomicReference<>();
        AtomicBoolean expired = new AtomicBoolean();
        ScheduledExecutorService watchdog = Executors.newSingleThreadScheduledExecutor(task -> {
            Thread thread = new Thread(task, "script-js-deadline");
            thread.setDaemon(true);
            return thread;
        });
        long remaining = TimeUnit.MILLISECONDS.toNanos(timeout) - (System.nanoTime() - started);
        watchdog.schedule(() -> {
            expired.set(true);
            Context running = active.get();
            if (running != null) {
                try { running.close(true); } catch (RuntimeException ignored) { /* already closing */ }
            }
        }, Math.max(0, remaining), TimeUnit.NANOSECONDS);
        try {
            Context context = Context.newBuilder("js")
                    .allowAllAccess(false)
                    .allowHostAccess(HostAccess.NONE)
                    .allowHostClassLookup(name -> false)
                    .allowHostClassLoading(false)
                    .allowNativeAccess(false)
                    .allowCreateThread(false)
                    .allowCreateProcess(false)
                    .allowEnvironmentAccess(EnvironmentAccess.NONE)
                    .allowPolyglotAccess(PolyglotAccess.NONE)
                    .allowIO(IOAccess.NONE)
                    .allowValueSharing(false)
                    .allowInnerContextOptions(false)
                    .useSystemExit(false)
                    .in(new ByteArrayInputStream(new byte[0]))
                    .out(OutputStream.nullOutputStream())
                    .err(OutputStream.nullOutputStream())
                    .logHandler(OutputStream.nullOutputStream())
                    .option("engine.WarnInterpreterOnly", "false")
                    .build();
            active.set(context);
            if (expired.get()) return error("timeout");
            ProxyExecutable digest = values -> {
                try {
                    byte[] bytes = values[0].asString().getBytes(StandardCharsets.UTF_8);
                    return HexFormat.of().formatHex(MessageDigest.getInstance("MD5").digest(bytes));
                } catch (Exception ignored) {
                    throw new IllegalStateException("digest-failed");
                }
            };
            Value helpers = context.eval("js", BOOTSTRAP).execute(digest);
            Value encode = helpers.getMember("encode");
            try {
                helpers.getMember("install").execute(globals.toString());
            } catch (RuntimeException ignored) {
                return error(expired.get() ? "timeout" : "invalid-request");
            }
            final Value result;
            try {
                result = context.eval("js", request.get("source").getAsString());
            } catch (RuntimeException ignored) {
                return error(expired.get() ? "timeout" : "js-error");
            }
            final String json;
            try {
                json = encode.execute(result).asString();
            } catch (RuntimeException ignored) {
                return error(expired.get() ? "timeout" : "unsupported-result");
            }
            String response = "{\"ok\":true,\"result\":" + json + "}";
            if (expired.get()) return error("timeout");
            if (response.getBytes(StandardCharsets.UTF_8).length > MAX_BYTES) return error("output-limit");
            return response;
        } catch (RuntimeException | LinkageError | StackOverflowError ignored) {
            return error(expired.get() ? "timeout" : "engine-error");
        } finally {
            Context context = active.get();
            if (context != null) {
                try { context.close(true); } catch (RuntimeException ignored) { /* watchdog closed it */ }
            }
            watchdog.shutdownNow();
        }
    }

    private static boolean isString(JsonElement element) {
        return element != null && element.isJsonPrimitive() && element.getAsJsonPrimitive().isString();
    }

    private static JsonElement parseJson(String input) throws Exception {
        try (JsonReader reader = new JsonReader(new StringReader(input))) {
            reader.setLenient(false);
            JsonElement value = readJson(reader, 0, new int[]{MAX_NODES});
            if (reader.peek() != JsonToken.END_DOCUMENT) throw new IllegalArgumentException();
            return value;
        }
    }

    private static JsonElement readJson(JsonReader reader, int depth, int[] budget) throws Exception {
        if (depth > MAX_DEPTH || --budget[0] < 0) throw new IllegalArgumentException();
        switch (reader.peek()) {
            case NULL:
                reader.nextNull();
                return JsonNull.INSTANCE;
            case BOOLEAN:
                return new JsonPrimitive(reader.nextBoolean());
            case STRING:
                return new JsonPrimitive(reader.nextString());
            case NUMBER:
                BigDecimal number = new BigDecimal(reader.nextString());
                double value = number.doubleValue();
                if (!Double.isFinite(value) || (number.scale() <= 0 && number.abs().compareTo(
                        BigDecimal.valueOf(9007199254740991L)) > 0)) throw new IllegalArgumentException();
                return new JsonPrimitive(number);
            case BEGIN_ARRAY:
                JsonArray array = new JsonArray();
                reader.beginArray();
                while (reader.hasNext()) array.add(readJson(reader, depth + 1, budget));
                reader.endArray();
                return array;
            case BEGIN_OBJECT:
                JsonObject object = new JsonObject();
                reader.beginObject();
                while (reader.hasNext()) {
                    String key = reader.nextName();
                    if (--budget[0] < 0 || object.has(key)) throw new IllegalArgumentException();
                    object.add(key, readJson(reader, depth + 1, budget));
                }
                reader.endObject();
                return object;
            default:
                throw new IllegalArgumentException();
        }
    }

    private static String error(String code) {
        return "{\"ok\":false,\"error\":\"" + code + "\"}";
    }

    public static void main(String[] args) {
        String response;
        try {
            byte[] input = System.in.readNBytes(MAX_BYTES + 1);
            if (input.length > MAX_BYTES) {
                response = error("input-limit");
            } else {
                String request = StandardCharsets.UTF_8.newDecoder()
                        .onMalformedInput(CodingErrorAction.REPORT)
                        .onUnmappableCharacter(CodingErrorAction.REPORT)
                        .decode(ByteBuffer.wrap(input)).toString();
                response = evaluate(request);
            }
        } catch (Exception | LinkageError | OutOfMemoryError | StackOverflowError ignored) {
            response = error("engine-error");
        }
        // System.out uses the Windows native charset even with file.encoding=UTF-8.
        byte[] encoded = response.getBytes(StandardCharsets.UTF_8);
        System.out.write(encoded, 0, encoded.length);
        System.out.flush();
    }
}

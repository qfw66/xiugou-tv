package com.fongmi.companion;

import com.fongmi.companion.py.PyRuntime;
import com.fongmi.companion.py.PySpider;
import java.util.ArrayDeque;
import java.util.ArrayList;
import java.util.IdentityHashMap;
import java.util.LinkedHashMap;
import java.util.List;
import java.util.Map;
import java.util.UUID;
import java.util.concurrent.Executors;
import java.util.concurrent.ScheduledExecutorService;
import java.util.concurrent.TimeUnit;

/** HTTP leases own bounded event rings; each producer retains its original Python child. */
final class ScriptDanmakuRegistry implements AutoCloseable {
    private static final int CAPACITY = 256;
    private static final int MAX_SUBSCRIPTIONS = 64;
    private final Map<String, Entry> entries = new LinkedHashMap<>();
    private final Map<PySpider, Entry> current = new IdentityHashMap<>();
    private final long leaseNanos = TimeUnit.MILLISECONDS.toNanos(Math.max(100L,
            Math.min(60_000L, Long.getLong("xiugou.py.danmakuLeaseMs", 60_000L))));
    private final ScheduledExecutorService expiry = Executors.newSingleThreadScheduledExecutor(r -> {
        Thread thread = new Thread(r, "script-danmaku-lease");
        thread.setDaemon(true);
        return thread;
    });
    private boolean closed;
    private int resets;

    ScriptDanmakuRegistry() {
        expiry.scheduleWithFixedDelay(this::expire, 100L, 100L, TimeUnit.MILLISECONDS);
    }

    Entry start(PySpider spider, String room) throws Exception {
        Entry entry = new Entry(spider);
        Entry previous;
        synchronized (this) {
            if (closed || resets > 0 || entries.size() >= MAX_SUBSCRIPTIONS)
                throw new IllegalStateException("subscription unavailable");
            entries.put(entry.id, entry);
            previous = current.put(spider, entry);
        }
        if (previous != null) previous.stop();
        try {
            PyRuntime.DanmakuSession session = spider.openDanmaku(entry.id, entry);
            entry.attach(session);
            session.start(room);
            synchronized (entry) {
                if (entry.revoked || entry.closed) throw new IllegalStateException("subscription cancelled");
                entry.leaseUntil = System.nanoTime() + leaseNanos;
                entry.starting = false;
            }
            return entry;
        } catch (Exception error) {
            remove(entry);
            entry.revoke();
            entry.stop();
            throw error;
        }
    }

    synchronized Entry find(String id, String generation) {
        Entry entry = entries.get(id);
        return entry != null && generation.equals(entry.generation) ? entry : null;
    }

    void stop(String id, String generation) {
        Entry entry = find(id, generation);
        if (entry == null) return;
        remove(entry);
        entry.revoke();
        entry.stop();
    }

    private synchronized void remove(Entry entry) {
        entries.remove(entry.id, entry);
        current.remove(entry.spider, entry);
    }

    /** Admission stays closed until the loader has retired every original child. */
    int reset(java.util.function.IntSupplier release) {
        List<Entry> retiring;
        synchronized (this) {
            resets++;
            retiring = new ArrayList<>(entries.values());
            entries.clear();
            current.clear();
        }
        try {
            for (Entry entry : retiring) entry.revoke();
            return release.getAsInt();
        } finally {
            synchronized (this) { resets--; }
        }
    }

    private void expire() {
        List<Entry> retiring = new ArrayList<>();
        synchronized (this) {
            long now = System.nanoTime();
            for (Entry entry : entries.values()) {
                synchronized (entry) {
                    if (!entry.starting && entry.polls == 0 && now >= entry.leaseUntil) retiring.add(entry);
                }
            }
            for (Entry entry : retiring) remove(entry);
        }
        for (Entry entry : retiring) {
            entry.revoke();
            entry.stop();
        }
    }

    @Override public void close() {
        synchronized (this) { closed = true; }
        reset(() -> 0);
        expiry.shutdownNow();
    }

    final class Entry implements PyRuntime.DanmakuListener {
        final String id = UUID.randomUUID().toString().replace("-", "");
        final PySpider spider;
        private final ArrayDeque<Map<String, Object>> events = new ArrayDeque<>();
        private volatile String generation = "";
        private PyRuntime.DanmakuSession session;
        private Map<String, Object> state = Map.of("state", "connecting");
        private long sequence;
        private long leaseUntil = System.nanoTime() + leaseNanos;
        private int polls;
        private boolean starting = true;
        private boolean closed;
        private boolean revoked;

        Entry(PySpider spider) { this.spider = spider; }

        String generation() { return generation; }

        void attach(PyRuntime.DanmakuSession owner) {
            boolean cancelled;
            synchronized (this) {
                session = owner;
                generation = owner.generation;
                cancelled = revoked || closed;
            }
            if (cancelled) owner.close();
        }

        @Override public synchronized void event(long seq, Map<String, Object> item) {
            if (revoked || closed || seq <= sequence) return;
            sequence = seq;
            if (item.containsKey("state")) state = item;
            events.addLast(Map.of("seq", seq, "item", item));
            if (events.size() > CAPACITY) events.removeFirst();
            notifyAll();
        }

        @Override public synchronized void closed() {
            if (closed) return;
            closed = true;
            state = Map.of("state", "error", "msg", "script danmaku ended");
            notifyAll();
        }

        synchronized void revoke() {
            revoked = true;
            closed = true;
            events.clear();
            notifyAll();
        }

        void stop() {
            PyRuntime.DanmakuSession owner;
            synchronized (this) {
                closed = true;
                events.clear();
                notifyAll();
                owner = session;
            }
            if (owner != null) owner.close();
        }

        synchronized Map<String, Object> started(String base) {
            if (revoked || closed) throw new IllegalStateException("subscription cancelled");
            String query = "?subscriptionId=" + id + "&generation=" + generation;
            Map<String, Object> result = new LinkedHashMap<>();
            result.put("subscriptionId", id);
            result.put("generation", generation);
            result.put("eventsUrl", base + "/events" + query);
            result.put("stopUrl", base + "/stop" + query);
            result.put("cursor", 0);
            result.put("state", Map.of("state", "connecting"));
            return result;
        }

        synchronized Map<String, Object> poll(long after, long waitMs) throws InterruptedException {
            if (revoked) return null;
            if (after < 0 || after > sequence) throw new IllegalArgumentException("invalid cursor");
            polls++;
            try {
                long until = System.nanoTime() + TimeUnit.MILLISECONDS.toNanos(waitMs);
                while (!revoked && !closed && sequence <= after) {
                    long remaining = until - System.nanoTime();
                    if (remaining <= 0) break;
                    TimeUnit.NANOSECONDS.timedWait(this, remaining);
                }
                if (revoked) return null;
                List<Map<String, Object>> batch = new ArrayList<>();
                for (Map<String, Object> event : events) if ((Long) event.get("seq") > after) batch.add(event);
                Map<String, Object> result = new LinkedHashMap<>();
                result.put("subscriptionId", id);
                result.put("generation", generation);
                result.put("cursor", sequence);
                result.put("events", batch);
                result.put("dropped", Math.max(0L, sequence - after - batch.size()));
                result.put("state", state);
                result.put("closed", closed);
                return result;
            } finally {
                polls--;
                leaseUntil = System.nanoTime() + leaseNanos;
            }
        }
    }
}

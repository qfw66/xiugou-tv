package com.fongmi.companion.ui;

import android.app.AlertDialog;
import android.app.Dialog;
import android.app.DialogHost;
import android.view.View;
import android.widget.AdapterView;
import android.widget.CompoundButton;
import android.widget.EditText;
import android.widget.TextView;

import com.fongmi.companion.JsonCodec;

import java.util.ArrayDeque;
import java.util.ArrayList;
import java.util.Deque;
import java.util.LinkedHashMap;
import java.util.LinkedHashSet;
import java.util.List;
import java.util.Map;
import java.util.Set;
import java.util.concurrent.ConcurrentHashMap;
import java.util.concurrent.Executors;
import java.util.concurrent.ScheduledExecutorService;
import java.util.concurrent.TimeUnit;

/**
 * 载荷界面的宿主：把弹窗 / Toast / 剪贴板 / 外部跳转转成事件，供 Flutter 长轮询；
 * 再把用户在 Flutter 里的操作回放给载荷（输入框回填、按钮 / 列表 / 开关 / 下拉点击、取消）。
 *
 * <p>线程模型：
 * <ul>
 *   <li>载荷线程调用 {@link DialogHost} 回调，只登记「脏」弹窗，{@value #FLUSH_DELAY_MS}ms 后合并成一次快照，
 *       避免载荷逐个 addView 时刷出几十个中间态；</li>
 *   <li>用户操作在独立的 {@code android-ui} 单线程上执行，对应 Android 的主线程：
 *       HTTP 请求立即返回，载荷回调里的网络请求不会卡住 RPC。</li>
 * </ul>
 */
public final class UiBridge extends DialogHost {

    static final long FLUSH_DELAY_MS = 60;
    private static final int MAX_EVENTS = 256;
    private static final long MAX_WAIT_MS = 30_000;

    private static final UiBridge INSTANCE = new UiBridge();

    private final Object lock = new Object();
    private final Deque<Event> events = new ArrayDeque<>();
    private long seq;

    /** 正在显示的弹窗：宿主标识 → 弹窗。 */
    private final Map<Integer, Dialog> showing = new ConcurrentHashMap<>();
    /** 已经向宿主发出过 show 的弹窗。 */
    private final Set<Integer> announced = ConcurrentHashMap.newKeySet();
    private final Set<Integer> dirty = ConcurrentHashMap.newKeySet();
    private final ScheduledExecutorService ui = Executors.newSingleThreadScheduledExecutor(r -> {
        Thread t = new Thread(r, "android-ui");
        t.setDaemon(true);
        return t;
    });
    private volatile boolean flushScheduled;

    private static final class Event {
        final long seq;
        final Map<String, Object> body;

        Event(long seq, Map<String, Object> body) {
            this.seq = seq;
            this.body = body;
        }
    }

    private UiBridge() {
    }

    public static UiBridge get() {
        return INSTANCE;
    }

    /** 注册为载荷界面的宿主；可重复调用。 */
    public static void install() {
        DialogHost.install(INSTANCE);
    }

    // ==================================================================
    // DialogHost：载荷 → 宿主
    // ==================================================================

    @Override
    public void onShow(Dialog dialog) {
        showing.put(dialog.getHostId(), dialog);
        markDirty(dialog);
    }

    @Override
    public void onDismiss(Dialog dialog) {
        int id = dialog.getHostId();
        showing.remove(id);
        dirty.remove(id);
        if (announced.remove(id)) {
            Map<String, Object> body = new LinkedHashMap<>();
            body.put("type", "dismiss");
            body.put("id", id);
            emit(body);
            log("dismiss #" + id);
        }
    }

    @Override
    public void onChanged(View view) {
        if (view == null || showing.isEmpty()) return;
        View root = view.getRootView();
        for (Dialog dialog : showing.values()) {
            if (dialog.getHostContentView() == root
                    || (dialog instanceof AlertDialog && ((AlertDialog) dialog).isHostButton(view))) {
                markDirty(dialog);
                return;
            }
        }
    }

    @Override
    public void onDialogChanged(Dialog dialog) {
        if (showing.containsKey(dialog.getHostId())) markDirty(dialog);
    }

    @Override
    public void onToast(CharSequence text) {
        Map<String, Object> body = new LinkedHashMap<>();
        body.put("type", "toast");
        body.put("text", text.toString());
        emit(body);
    }

    @Override
    public void onOpenUri(String uri, String mimeType) {
        Map<String, Object> body = new LinkedHashMap<>();
        body.put("type", "openUri");
        body.put("uri", uri);
        body.put("mime", mimeType == null ? "" : mimeType);
        emit(body);
        log("openUri " + uri);
    }

    @Override
    public void onClipboard(CharSequence text) {
        Map<String, Object> body = new LinkedHashMap<>();
        body.put("type", "clipboard");
        body.put("text", text.toString());
        emit(body);
    }

    @Override
    public void post(Runnable runnable) {
        if (runnable != null) ui.execute(guard(runnable));
    }

    private void markDirty(Dialog dialog) {
        dirty.add(dialog.getHostId());
        synchronized (this) {
            if (flushScheduled) return;
            flushScheduled = true;
        }
        ui.schedule(this::flush, FLUSH_DELAY_MS, TimeUnit.MILLISECONDS);
    }

    private void flush() {
        synchronized (this) {
            flushScheduled = false;
        }
        List<Integer> ids = new ArrayList<>(dirty);
        dirty.removeAll(ids);
        for (int id : ids) {
            Dialog dialog = showing.get(id);
            if (dialog == null) continue;
            Map<String, Object> snapshot;
            try {
                snapshot = UiSnapshot.dialog(dialog);
            } catch (RuntimeException e) {
                // 不重试：持续失败会形成空转；下一次控件变更会再次触发快照
                System.err.println("[UiBridge] snapshot #" + id + " failed: " + e);
                continue;
            }
            boolean first = announced.add(id);
            Map<String, Object> body = new LinkedHashMap<>();
            body.put("type", first ? "show" : "update");
            body.put("dialog", snapshot);
            emit(body);
            if (first) log("show #" + id + " " + snapshot.get("title"));
        }
    }

    private void emit(Map<String, Object> body) {
        synchronized (lock) {
            seq++;
            body.put("seq", seq);
            events.addLast(new Event(seq, body));
            while (events.size() > MAX_EVENTS) events.removeFirst();
            lock.notifyAll();
        }
    }

    // ==================================================================
    // 宿主 → 载荷
    // ==================================================================

    /**
     * 长轮询：返回序号大于 {@code after} 的事件；没有新事件时最多等 {@code waitMs}。
     *
     * <p>{@code after < 0}（宿主刚连上）或事件已被挤出缓冲时，返回 {@code reset=true} 与所有正在显示的弹窗，
     * 宿主据此重建界面，不补发历史 Toast。
     */
    public String poll(long after, long waitMs) throws InterruptedException {
        long deadline = System.currentTimeMillis() + Math.max(0, Math.min(waitMs, MAX_WAIT_MS));
        List<Object> out = new ArrayList<>();
        boolean reset;
        long cursor;
        synchronized (lock) {
            while (after >= 0 && seq <= after) {
                long left = deadline - System.currentTimeMillis();
                if (left <= 0) break;
                lock.wait(left);
            }
            long oldest = events.isEmpty() ? seq + 1 : events.peekFirst().seq;
            reset = after < 0 || (after < oldest - 1 && seq > after);
            cursor = seq;
            if (!reset) {
                for (Event e : events) if (e.seq > after) out.add(e.body);
            }
        }
        if (reset) {
            for (Dialog dialog : showing.values()) {
                if (!announced.contains(dialog.getHostId())) continue;
                Map<String, Object> body = new LinkedHashMap<>();
                body.put("type", "show");
                body.put("dialog", UiSnapshot.dialog(dialog));
                out.add(body);
            }
        }
        Map<String, Object> resp = new LinkedHashMap<>();
        resp.put("cursor", cursor);
        resp.put("reset", reset);
        resp.put("events", out);
        return JsonCodec.stringify(resp);
    }

    /**
     * 回放一次用户操作。请求体字段：{@code dialog}（弹窗标识）、{@code type}、
     * 以及按类型需要的 {@code which} / {@code index} / {@code view} / {@code checked}；
     * {@code inputs}（控件标识 → 文本）先于操作回填到输入框，载荷在按钮回调里读取。
     *
     * @return 弹窗仍在显示时为 true（操作已排队执行）
     */
    public boolean input(Map<String, Object> request) {
        int dialogId = intOf(request.get("dialog"), -1);
        Dialog dialog = showing.get(dialogId);
        if (dialog == null) return false;
        String type = String.valueOf(request.getOrDefault("type", ""));
        Object inputs = request.get("inputs");
        ui.execute(guard(() -> {
            if (inputs instanceof Map) applyInputs(dialog, (Map<?, ?>) inputs);
            perform(dialog, type, request);
        }));
        return true;
    }

    private void applyInputs(Dialog dialog, Map<?, ?> inputs) {
        for (Map.Entry<?, ?> entry : inputs.entrySet()) {
            View view = UiSnapshot.find(dialog, intOf(entry.getKey(), -1));
            if (view instanceof EditText) {
                ((EditText) view).applyUserInput(entry.getValue() == null ? "" : entry.getValue().toString());
            }
        }
    }

    private void perform(Dialog dialog, String type, Map<String, Object> request) {
        View view = UiSnapshot.find(dialog, intOf(request.get("view"), -1));
        switch (type) {
            case "button":
                if (dialog instanceof AlertDialog) ((AlertDialog) dialog).hostPerformButton(intOf(request.get("which"), 0));
                break;
            case "item":
                if (dialog instanceof AlertDialog) ((AlertDialog) dialog).hostPerformItem(intOf(request.get("index"), -1));
                break;
            case "click":
                if (view != null && view.isEnabled()) view.performClick();
                break;
            case "check":
                if (view instanceof CompoundButton && view.isEnabled()
                        && ((CompoundButton) view).isChecked() != Boolean.TRUE.equals(request.get("checked"))) {
                    view.performClick();
                }
                break;
            case "select":
                if (view instanceof AdapterView) ((AdapterView<?>) view).setSelection(intOf(request.get("index"), -1));
                break;
            case "submit":
                if (view instanceof TextView) ((TextView) view).dispatchEditorAction(6 /* IME_ACTION_DONE */);
                break;
            case "cancel":
                dialog.hostRequestCancel();
                break;
            default:
                // 只回填输入
                break;
        }
        // 操作可能改了不触发通知的状态（如列表选中），统一再刷一次
        if (dialog.isShowing()) onDialogChanged(dialog);
    }

    /** 载荷回调抛出的异常只记日志并提示，不能打死 android-ui 线程。 */
    private Runnable guard(Runnable task) {
        return () -> {
            try {
                task.run();
            } catch (Throwable t) {
                System.err.println("[UiBridge] callback failed: " + t);
                t.printStackTrace();
                String msg = t.getMessage();
                onToast("操作出错：" + (msg == null || msg.isEmpty() ? t.getClass().getSimpleName() : msg));
            }
        };
    }

    /** 关闭所有弹窗记录（服务停止时调用），不回调载荷。 */
    public void reset() {
        showing.clear();
        announced.clear();
        dirty.clear();
    }

    /** 当前正在显示的弹窗标识（诊断 / 测试用）。 */
    public Set<Integer> showingIds() {
        return new LinkedHashSet<>(showing.keySet());
    }

    private static int intOf(Object value, int fallback) {
        if (value instanceof Number) return ((Number) value).intValue();
        if (value == null) return fallback;
        try {
            return Integer.parseInt(value.toString().trim());
        } catch (NumberFormatException e) {
            return fallback;
        }
    }

    private static void log(String msg) {
        System.out.println("[UiBridge] " + msg);
    }
}

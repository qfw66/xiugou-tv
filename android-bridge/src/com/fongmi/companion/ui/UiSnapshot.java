package com.fongmi.companion.ui;

import android.app.AlertDialog;
import android.app.Dialog;
import android.graphics.Bitmap;
import android.view.View;
import android.view.ViewGroup;
import android.widget.AdapterView;
import android.widget.Button;
import android.widget.CheckBox;
import android.widget.CompoundButton;
import android.widget.EditText;
import android.widget.GridLayout;
import android.widget.HorizontalScrollView;
import android.widget.ImageView;
import android.widget.LinearLayout;
import android.widget.ProgressBar;
import android.widget.RadioButton;
import android.widget.ScrollView;
import android.widget.Spinner;
import android.widget.TextView;

import java.util.ArrayList;
import java.util.Base64;
import java.util.LinkedHashMap;
import java.util.List;
import java.util.Map;

/**
 * 把载荷弹窗序列化成宿主可渲染的结构（纯函数，便于单测）。
 *
 * <p>节点协议（与 Flutter 侧 {@code SpiderDialog} 对应，改动需两端同步）：
 * <ul>
 *   <li>公共字段：{@code id}（控件宿主标识）、{@code kind}、{@code enabled}、{@code clickable}；</li>
 *   <li>{@code group}：{@code axis} = v / h，{@code scroll}，{@code children}；{@code grid} 另带 {@code columns}；</li>
 *   <li>{@code text}（{@code bold}）、{@code button}、{@code input}（{@code hint} / {@code password} / {@code multiline}）、
 *       {@code image}（{@code png} 为 Base64、{@code width} / {@code height}）、{@code switch} / {@code check} / {@code radio}
 *       （{@code checked}）、{@code select}（{@code options} / {@code selected}）、{@code progress}。</li>
 * </ul>
 * {@code GONE} 的控件不输出；不认识的纯 View 视为装饰，不输出。
 */
public final class UiSnapshot {

    private UiSnapshot() {
    }

    public static Map<String, Object> dialog(Dialog dialog) {
        Map<String, Object> out = new LinkedHashMap<>();
        out.put("id", dialog.getHostId());
        out.put("title", text(dialog.getHostTitle()));
        out.put("cancelable", dialog.isHostCancelable());
        View content = dialog.getHostContentView();
        out.put("content", content == null ? null : node(content));
        if (dialog instanceof AlertDialog) {
            AlertDialog alert = (AlertDialog) dialog;
            out.put("message", text(alert.getHostMessage()));
            List<Object> buttons = new ArrayList<>();
            for (int which : alert.getHostButtons()) {
                Map<String, Object> b = new LinkedHashMap<>();
                b.put("which", which);
                b.put("text", text(alert.getHostButtonText(which)));
                b.put("enabled", alert.isHostButtonEnabled(which));
                buttons.add(b);
            }
            out.put("buttons", buttons);
            CharSequence[] items = alert.getHostItems();
            if (items != null && alert.getHostItemMode() != AlertDialog.ITEMS_NONE) {
                Map<String, Object> list = new LinkedHashMap<>();
                int mode = alert.getHostItemMode();
                list.put("mode", mode == AlertDialog.ITEMS_SINGLE ? "single"
                        : mode == AlertDialog.ITEMS_MULTI ? "multi" : "list");
                List<Object> labels = new ArrayList<>();
                for (CharSequence item : items) labels.add(text(item));
                list.put("items", labels);
                if (mode == AlertDialog.ITEMS_SINGLE) list.put("checked", alert.getHostCheckedItem());
                if (mode == AlertDialog.ITEMS_MULTI) list.put("checked", alert.getHostCheckedItems());
                out.put("list", list);
            }
        } else {
            out.put("message", "");
            out.put("buttons", new ArrayList<>());
        }
        return out;
    }

    static Map<String, Object> node(View v) {
        if (v.getVisibility() == View.GONE) return null;
        Map<String, Object> n = new LinkedHashMap<>();
        n.put("id", v.getHostId());
        n.put("enabled", v.isEnabled());
        n.put("clickable", v.getOnClickListener() != null);
        if (v instanceof Spinner) {
            Spinner s = (Spinner) v;
            n.put("kind", "select");
            List<Object> options = new ArrayList<>();
            for (int i = 0; i < s.getCount(); i++) options.add(text(String.valueOf(s.getItemAtPosition(i))));
            n.put("options", options);
            n.put("selected", s.getSelectedItemPosition());
            return n;
        }
        if (v instanceof ProgressBar) {
            ProgressBar p = (ProgressBar) v;
            n.put("kind", "progress");
            n.put("indeterminate", p.isIndeterminate());
            n.put("max", p.getMax());
            n.put("value", p.getProgress());
            return n;
        }
        if (v instanceof ImageView) {
            Bitmap bitmap = ((ImageView) v).getImageBitmap();
            if (bitmap == null || bitmap.isRecycled()) return null;
            n.put("kind", "image");
            n.put("png", Base64.getEncoder().encodeToString(bitmap.toPng()));
            n.put("width", bitmap.getWidth());
            n.put("height", bitmap.getHeight());
            return n;
        }
        if (v instanceof CompoundButton) {
            CompoundButton c = (CompoundButton) v;
            n.put("kind", v instanceof RadioButton ? "radio" : v instanceof CheckBox ? "check" : "switch");
            n.put("text", text(c.getText()));
            n.put("checked", c.isChecked());
            return n;
        }
        if (v instanceof EditText) {
            EditText e = (EditText) v;
            n.put("kind", "input");
            n.put("text", text(e.getText()));
            n.put("hint", text(e.getHint()));
            n.put("password", e.isPasswordInput());
            n.put("multiline", e.getMaxLines() > 1 && (e.getInputType() & 0x00020000) != 0);
            return n;
        }
        if (v instanceof Button) {
            n.put("kind", "button");
            n.put("text", text(((Button) v).getText()));
            return n;
        }
        if (v instanceof TextView) {
            TextView t = (TextView) v;
            String value = text(t.getText());
            if (value.isEmpty() && n.get("clickable") == Boolean.FALSE) return null;
            n.put("kind", "text");
            n.put("text", value);
            n.put("bold", t.isBold());
            return n;
        }
        if (v instanceof AdapterView || !(v instanceof ViewGroup)) return null;
        ViewGroup g = (ViewGroup) v;
        if (g instanceof GridLayout) {
            n.put("kind", "grid");
            int columns = ((GridLayout) g).getColumnCount();
            n.put("columns", columns > 0 ? columns : 1);
        } else {
            n.put("kind", "group");
            boolean horizontal = g instanceof HorizontalScrollView
                    || (g instanceof LinearLayout && ((LinearLayout) g).getOrientation() == LinearLayout.HORIZONTAL);
            n.put("axis", horizontal ? "h" : "v");
            n.put("scroll", g instanceof ScrollView || g instanceof HorizontalScrollView);
        }
        List<Object> children = new ArrayList<>();
        for (int i = 0; i < g.getChildCount(); i++) {
            View child = g.getChildAt(i);
            Map<String, Object> c = child == null ? null : node(child);
            if (c != null) children.add(c);
        }
        if (children.isEmpty() && n.get("clickable") == Boolean.FALSE) return null;
        n.put("children", children);
        return n;
    }

    /** 在弹窗里按宿主标识找控件（内容树 + AlertDialog 的按钮）。 */
    static View find(Dialog dialog, int hostId) {
        View content = dialog.getHostContentView();
        return content == null ? null : find(content, hostId);
    }

    private static View find(View v, int hostId) {
        if (v.getHostId() == hostId) return v;
        if (v instanceof ViewGroup) {
            ViewGroup g = (ViewGroup) v;
            for (int i = 0; i < g.getChildCount(); i++) {
                View child = g.getChildAt(i);
                View found = child == null ? null : find(child, hostId);
                if (found != null) return found;
            }
        }
        return null;
    }

    private static String text(CharSequence value) {
        return value == null ? "" : value.toString();
    }
}

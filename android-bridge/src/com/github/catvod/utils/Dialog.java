package com.github.catvod.utils;

import android.app.AlertDialog;
import android.content.Context;
import android.graphics.Bitmap;
import android.widget.*;
import com.fongmi.companion.ui.UiBridge;
import org.json.JSONArray;
import org.json.JSONObject;
import java.util.*;
import java.util.concurrent.*;

/** JSON forms translated to the existing Android-view/UI bridge protocol. */
public final class Dialog implements AutoCloseable {
    @FunctionalInterface public interface Callback { JSONObject onAction(JSONObject action) throws Exception; }
    private static final Set<Dialog> OPEN = ConcurrentHashMap.newKeySet();
    private static final ExecutorService CALLBACKS = new ThreadPoolExecutor(0, 16, 30, TimeUnit.SECONDS,
            new SynchronousQueue<>(), r -> { Thread t=new Thread(r,"java-sdk-dialog"); t.setDaemon(true); return t; });
    private final CompletableFuture<JSONObject> result = new CompletableFuture<>();
    private final Map<String,EditText> inputs=new LinkedHashMap<>();
    private final Map<String,TextView> errors=new LinkedHashMap<>();
    private final List<Integer> validatingButtons=new ArrayList<>();
    private volatile AlertDialog window;
    private ImageView picture;
    private volatile Future<?> callbackTask;
    private JSONObject spec;
    private Callback callback;
    private boolean started, busy;
    public Dialog() {}
    public JSONObject show(JSONObject spec) { return show(spec,null); }
    public JSONObject show(JSONObject spec,Callback callback) {
        if(UiBridge.isUiThread()) throw new IllegalStateException("Synchronous JSON dialog requires a worker thread");
        synchronized(this) {
            if(started) throw new IllegalStateException("Dialog already used"); started=true;
            this.spec=copy(spec); this.callback=callback;
            if(result.isDone()) return null; OPEN.add(this);
        }
        UiBridge.get().post(() -> {
            try { synchronized(this) { if(!result.isDone()) render(); } }
            catch(Throwable ignored) {
                result.completeExceptionally(new IllegalArgumentException("Unsupported or invalid dialog"));
                OPEN.remove(this);
                if(window!=null) window.dismiss();
            }
        });
        try { return result.get(); }
        catch(InterruptedException e) { close(); Thread.currentThread().interrupt(); return null; }
        catch(ExecutionException e) { close(); throw new IllegalStateException("Dialog failed"); }
    }
    private void render() throws Exception {
        Context context=Context.get(); AlertDialog view=new AlertDialog(context); window=view;
        view.setTitle(spec.optString("title","")); view.setMessage(spec.optString("message",""));
        view.setCancelable(spec.optBoolean("cancelable",true));
        view.setOnCancelListener(d -> finish(null)); view.setOnDismissListener(d -> finish(null));
        LinearLayout content=new LinearLayout(context); content.setOrientation(LinearLayout.VERTICAL);
        JSONArray fields=spec.optJSONArray("inputs");
        if(fields!=null) for(int i=0;i<fields.length();i++) {
            JSONObject f=fields.getJSONObject(i); String name=f.getString("name");
            TextView label=new TextView(context); label.setText(f.optString("label",name)); content.addView(label);
            EditText edit=new EditText(context); edit.setText(f.optString("value","")); edit.setHint(f.optString("hint",""));
            if(f.optString("type").equals("password")) edit.setInputType(0x81);
            if(f.optBoolean("multiline",false)) { edit.setInputType(0x20001); edit.setMaxLines(6); }
            inputs.put(name,edit); content.addView(edit);
            String helper=f.optString("helperText","");
            if(!helper.isEmpty()) { TextView hint=new TextView(context); hint.setText(helper); content.addView(hint); }
            TextView error=new TextView(context); errors.put(name,error); content.addView(error);
        }
        String qr=spec.optString("qrcode","");
        if(isLocalQr(qr)) {
            TextView notice=new TextView(context); notice.setText("此设置地址仅限当前设备，请在配置中心打开。当前不支持手机扫码设置。"); content.addView(notice);
        }
        picture=new ImageView(context);
        picture.setImageBitmap(image(spec)); content.addView(picture);
        ScrollView scroll=new ScrollView(context); scroll.addView(content); view.setView(scroll);
        JSONArray buttons=spec.optJSONArray("buttons");
        if(buttons==null || buttons.length()==0) buttons=new JSONArray().put(new JSONObject().put("id","close").put("label","关闭"));
        if(buttons.length()>3) throw new UnsupportedOperationException("JSON forms support at most three buttons");
        for(int i=0;i<buttons.length();i++) {
            JSONObject button=buttons.getJSONObject(i); int which=-1-i;
            view.setButton(which,button.optString("label",button.optString("id")),null);
            view.getButton(which).setOnClickListener(v -> {
                try { submit(button); } catch (Exception ignored) { view.setMessage("表单数据无效"); }
            });
            if(validates(button)) validatingButtons.add(which);
        }
        view.show();
    }
    private boolean validates(JSONObject button) { JSONArray v=button.optJSONArray("validate"); return v==null || v.length()>0; }
    private void submit(JSONObject button) throws org.json.JSONException {
        if(result.isDone() || (busy && validates(button))) return;
        JSONObject values=new JSONObject(), invalid=new JSONObject();
        inputs.forEach((key,input) -> put(values,key,input.getText().toString()));
        JSONArray selected=button.optJSONArray("validate"), fields=spec.optJSONArray("inputs");
        if(fields!=null) for(int i=0;i<fields.length();i++) {
            JSONObject f=fields.getJSONObject(i); String name=f.getString("name");
            boolean validate=selected==null;
            if(selected!=null) for(int j=0;j<selected.length();j++) if(name.equals(selected.optString(j))) validate=true;
            if(!validate) continue;
            String value=values.optString(name);
            if(f.optBoolean("required",false) && value.trim().isEmpty()) invalid.put(name,"请填写此项");
            else if(value.length()>f.optInt("maxLength",Integer.MAX_VALUE)) invalid.put(name,"输入内容过长");
        }
        showErrors(invalid);
        if(invalid.length()>0) return;
        JSONObject action=new JSONObject().put("button",button.getString("id")).put("values",values);
        // Explicit validate:[] buttons are cancellation/navigation and must remain responsive during validation.
        if(!validates(button) || callback==null) { if(button.optBoolean("close",true)) finish(action); return; }
        busy=true; setBusy(true);
        try {
            callbackTask=CALLBACKS.submit(() -> {
                JSONObject reply;
                try { reply=callback.onAction(action); }
                catch(Throwable ignored) { reply=new JSONObject(Map.of("message","验证失败，请检查输入后重试","close",false)); }
                JSONObject response=reply;
                UiBridge.get().post(() -> {
                    if(result.isDone()) return;
                    busy=false; setBusy(false);
                    if(response!=null) {
                        showErrors(response.optJSONObject("errors"));
                        if(response.has("message")) window.setMessage(response.optString("message"));
                        if(response.has("title")) window.setTitle(response.optString("title"));
                    }
                    JSONObject fieldErrors=response==null?null:response.optJSONObject("errors");
                    if((fieldErrors==null || fieldErrors.length()==0) && (response==null?button.optBoolean("close",true):response.optBoolean("close",button.optBoolean("close",true)))) finish(action);
                });
            });
        } catch(RejectedExecutionException e) { busy=false; setBusy(false); window.setMessage("当前操作较多，请稍后重试"); }
    }
    private void setBusy(boolean value) { for(int which:validatingButtons) window.getButton(which).setEnabled(!value); }
    private void showErrors(JSONObject values) { errors.forEach((key,text) -> text.setText(values==null?"":values.optString(key,""))); }
    private void finish(JSONObject value) {
        if(!result.complete(value)) return; OPEN.remove(this);
        Future<?> pending=callbackTask; if(pending!=null) pending.cancel(true);
        UiBridge.get().post(() -> { AlertDialog view=window; if(view!=null) view.dismiss(); });
    }
    /** Update a live QR/message form; ignored after close. */
    public void update(JSONObject patch) {
        UiBridge.get().post(() -> {
            if(result.isDone() || window==null) return;
            if(patch.has("message")) window.setMessage(patch.optString("message"));
            if(patch.has("title")) window.setTitle(patch.optString("title"));
            if(patch.has("image") || patch.has("qrcode")) {
                try { picture.setImageBitmap(image(patch)); }
                catch(Exception ignored) { window.setMessage("图片无法显示，请重试"); }
            }
            showErrors(patch.optJSONObject("errors"));
        });
    }
    public void close() { finish(null); }
    private static JSONObject copy(JSONObject value) {
        try { return new JSONObject(value.toString()); }
        catch (org.json.JSONException e) { throw new IllegalArgumentException("Invalid dialog"); }
    }
    private static void put(JSONObject object,String name,Object value) {
        try { object.put(name,value); }
        catch (org.json.JSONException e) { throw new IllegalArgumentException("Invalid dialog value"); }
    }
    private static boolean isLocalQr(String qr) {
        try { return Set.of("127.0.0.1","localhost","::1","[::1]").contains(Objects.toString(java.net.URI.create(qr).getHost(),"")); }
        catch(Exception ignored) { return false; }
    }
    private static Bitmap image(JSONObject spec) throws Exception {
        String qr=spec.optString("qrcode","");
        if(!qr.isEmpty() && !isLocalQr(qr)) {
            var matrix=new com.google.zxing.qrcode.QRCodeWriter().encode(qr,com.google.zxing.BarcodeFormat.QR_CODE,280,280);
            int[] pixels=new int[280*280];
            for(int y=0;y<280;y++) for(int x=0;x<280;x++) pixels[y*280+x]=matrix.get(x,y)?0xff000000:0xffffffff;
            return Bitmap.createBitmap(pixels,280,280,Bitmap.Config.ARGB_8888);
        }
        String image=spec.optString("image","");
        if(image.isEmpty()) return null;
        if(image.length()>1024*1024 || !image.matches("(?s)data:image/(png|jpeg);base64,.*"))
            throw new IllegalArgumentException("Expected bounded embedded form image");
        byte[] bytes=Base64.getDecoder().decode(image.substring(image.indexOf(',')+1));
        android.graphics.BitmapFactory.Options bounds=new android.graphics.BitmapFactory.Options(); bounds.inJustDecodeBounds=true;
        android.graphics.BitmapFactory.decodeByteArray(bytes,0,bytes.length,bounds);
        if(bounds.outWidth<1 || bounds.outHeight<1 || bounds.outWidth>2048 || bounds.outHeight>2048)
            throw new IllegalArgumentException("Invalid form image dimensions");
        return android.graphics.BitmapFactory.decodeByteArray(bytes,0,bytes.length);
    }
    public static void closeAll() { new ArrayList<>(OPEN).forEach(Dialog::close); }
}

package android.content;

import android.app.ActivityManager;
import android.app.UiModeManager;
import android.content.res.AssetManager;
import android.content.res.Configuration;
import android.net.Uri;
import android.os.HandlerThread;
import android.os.StatFs;

import java.io.File;
import java.io.FileNotFoundException;

/**
 * pg.jar（alist-tvbox PG 订阅，issue #15）的 Init.init 在桌面上依次卡在这些 Android 类上：
 * UiModeManager（判断是不是电视）、getPackageResourcePath，以及 Init 里建 Picasso 实例时用到的
 * StatFs / ActivityManager / HandlerThread / registerReceiver / UriMatcher / AssetManager。
 * 任何一个缺失或返回 null，Init 就抛 NoClassDefFoundError / NPE，整个 jar 的站点全部变成「站点暂不可用」。
 * 运行：java -ea -cp &lt;classes&gt; android.content.PicassoInitShimsTest
 */
public final class PicassoInitShimsTest {

    public static void main(String[] args) throws Exception {
        uiModeReportsTelevision();
        activityManagerGivesSaneMemoryClass();
        statFsReportsRealDiskSize();
        handlerThreadLooperIsReadyImmediately();
        receiversAndAssetsDoNotThrow();
        packageResourcePathIsAbsolute();
        System.out.println("PicassoInitShimsTest OK");
    }

    private static void uiModeReportsTelevision() {
        Object service = Context.get().getSystemService("uimode");
        assert service instanceof UiModeManager : "uimode service must be a UiModeManager, got " + service;
        int type = ((UiModeManager) service).getCurrentModeType();
        assert type == Configuration.UI_MODE_TYPE_TELEVISION : "must agree with Configuration (TV), got " + type;
        assert Context.get().getSystemService("uimode") == service : "same instance every time";
    }

    private static void activityManagerGivesSaneMemoryClass() {
        Object service = Context.get().getSystemService("activity");
        assert service instanceof ActivityManager : "activity service must be an ActivityManager, got " + service;
        ActivityManager am = (ActivityManager) service;
        int mb = am.getMemoryClass();
        assert mb >= 64 && mb <= 512 : "memory class MB clamped to 64..512, got " + mb;
        assert am.getLargeMemoryClass() >= mb;
        assert !am.isLowRamDevice();
    }

    private static void statFsReportsRealDiskSize() {
        File dir = new File(System.getProperty("java.io.tmpdir"));
        StatFs fs = new StatFs(dir.getAbsolutePath());
        long total = fs.getBlockCountLong() * fs.getBlockSizeLong();
        assert total > 0 : "total disk bytes must be positive (Picasso sizes its disk cache from it)";
        assert Math.abs(total - dir.getTotalSpace()) < fs.getBlockSizeLong() : "block math matches File.getTotalSpace";
        assert fs.getAvailableBytes() <= fs.getTotalBytes();
        fs.restat(new File("does-not-exist-" + System.nanoTime()).getAbsolutePath());
        assert fs.getBlockCountLong() == 0 : "restat must switch to the new path";
    }

    private static void handlerThreadLooperIsReadyImmediately() {
        HandlerThread thread = new HandlerThread("picasso-test", 10);
        assert thread.isDaemon() : "must not keep the companion alive";
        thread.start();
        assert thread.getLooper() != null : "Picasso calls getLooper() right after start()";
        assert thread.quit();
    }

    private static void receiversAndAssetsDoNotThrow() throws Exception {
        BroadcastReceiver receiver = new BroadcastReceiver() {
            @Override
            public void onReceive(Context context, Intent intent) {
            }
        };
        IntentFilter filter = new IntentFilter();
        filter.addAction("android.intent.action.AIRPLANE_MODE");
        assert Context.get().registerReceiver(receiver, filter) == null : "desktop sends no sticky broadcasts";
        Context.get().unregisterReceiver(receiver);

        UriMatcher matcher = new UriMatcher(UriMatcher.NO_MATCH);
        matcher.addURI("com.android.contacts", "contacts/lookup/*/#", 1);
        assert matcher.match(Uri.parse("content://com.android.contacts/contacts/lookup/a/1")) == UriMatcher.NO_MATCH;

        AssetManager assets = Context.get().getAssets();
        assert assets != null : "getAssets must not be null";
        try {
            assets.open("anything.png").close();
            assert false : "desktop has no APK assets";
        } catch (FileNotFoundException expected) {
            // 载荷按「没有这个资源」处理
        }
    }

    private static void packageResourcePathIsAbsolute() {
        String path = Context.get().getPackageResourcePath();
        assert path != null && new File(path).isAbsolute() : "getPackageResourcePath must be an absolute path, got " + path;
    }
}

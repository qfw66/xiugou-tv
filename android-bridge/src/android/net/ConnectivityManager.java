package android.net;

/**
 * android.net.ConnectivityManager 的最小替身。
 *
 * <p>载荷（配置中心「当前 DNS」、picasso 网络状态）在方法体里引用了它与 Network / NetworkCapabilities /
 * LinkProperties；类本身不存在时，JVM 在链接期就抛 {@code NoClassDefFoundError}，整个 categoryContent 失败。
 * 桌面端 {@code Context.getSystemService("connectivity")} 仍返回 null，载荷走它自己写好的「拿不到」分支；
 * 这里的方法只为让类可解析，即便被调到也返回「无网络信息」。
 */
public class ConnectivityManager {

    public static final int TYPE_MOBILE = 0;
    public static final int TYPE_WIFI = 1;
    public static final int TYPE_ETHERNET = 9;

    public Network[] getAllNetworks() {
        return new Network[0];
    }

    public Network getActiveNetwork() {
        return null;
    }

    public NetworkCapabilities getNetworkCapabilities(Network network) {
        return null;
    }

    public LinkProperties getLinkProperties(Network network) {
        return null;
    }

    public NetworkInfo getActiveNetworkInfo() {
        return null;
    }
}

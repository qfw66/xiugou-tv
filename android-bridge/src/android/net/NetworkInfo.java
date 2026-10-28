package android.net;

/** android.net.NetworkInfo 的最小替身（载荷内嵌的 picasso 引用它）。 */
public class NetworkInfo {

    public boolean isConnected() {
        return true;
    }

    public boolean isConnectedOrConnecting() {
        return true;
    }

    public int getType() {
        return ConnectivityManager.TYPE_ETHERNET;
    }

    public int getSubtype() {
        return 0;
    }
}

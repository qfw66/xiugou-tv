package android.net;

/** android.net.NetworkCapabilities 的最小替身（见 {@link ConnectivityManager}）。 */
public class NetworkCapabilities {

    public static final int NET_CAPABILITY_INTERNET = 12;
    public static final int NET_CAPABILITY_VALIDATED = 16;
    public static final int TRANSPORT_CELLULAR = 0;
    public static final int TRANSPORT_WIFI = 1;
    public static final int TRANSPORT_ETHERNET = 3;

    public boolean hasCapability(int capability) {
        return false;
    }

    public boolean hasTransport(int transportType) {
        return false;
    }
}

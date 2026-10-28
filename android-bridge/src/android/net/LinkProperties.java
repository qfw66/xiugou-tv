package android.net;

import java.net.InetAddress;
import java.util.Collections;
import java.util.List;

/** android.net.LinkProperties 的最小替身（见 {@link ConnectivityManager}）。 */
public class LinkProperties {

    public List<InetAddress> getDnsServers() {
        return Collections.emptyList();
    }
}

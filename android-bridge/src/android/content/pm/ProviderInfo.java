package android.content.pm;

/** android.content.pm.ProviderInfo 桩（继承 PackageItemInfo，多一个 authority）。 */
public class ProviderInfo extends PackageItemInfo {

    public String authority = "";
    public boolean exported;

    public ProviderInfo() {
    }
}

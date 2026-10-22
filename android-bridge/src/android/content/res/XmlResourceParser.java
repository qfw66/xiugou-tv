package android.content.res;

/**
 * android.content.res.XmlResourceParser 桩：桌面端没有打包资源。
 *
 * <p>只作为 {@code PackageItemInfo.loadXmlMetaData(...)} 的返回类型存在，
 * 载荷拿到 null 即视为「无元数据」。故意不继承 {@code org.xmlpull.v1.XmlPullParser}
 * （该包同样缺失），避免为一个恒为 null 的返回值引入整条 XML 解析依赖。
 */
public interface XmlResourceParser {

    int START_TAG = 2;
    int END_TAG = 3;
    int TEXT = 4;

    void close();

    int getEventType();

    String getName();

    String getAttributeName(int index);

    String getAttributeValue(int index);

    String getAttributeValue(String namespace, String name);

    int getAttributeCount();

    int next();

    int nextToken();
}

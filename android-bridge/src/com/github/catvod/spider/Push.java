package com.github.catvod.spider;

import android.content.Context;
import com.github.catvod.bean.Result;
import com.github.catvod.bean.Vod;
import com.github.catvod.crawler.Spider;
import com.github.catvod.utils.Util;

import java.io.File;
import java.util.Collections;
import java.util.List;

public class Push extends Spider {

    @Override
    public void init(Context context, String extend) {}

    @Override
    public String detailContent(List<String> ids) {
        if (ids == null || ids.isEmpty()) return Result.string(Collections.emptyList());
        return Result.string(vod(ids.get(0)));
    }

    @Override
    public String playerContent(String flag, String id, List<String> vipFlags) {
        if (id == null) return "{}";
        if (id.contains("://") && id.contains("***")) id = id.replace("***", "#");
        if ("解析".equals(flag)) {
            return Result.get().parse().jx().url(id).string();
        } else if ("嗅探".equals(flag)) {
            return Result.get().parse().url(id).string();
        }
        return Result.get().url(id).string();
    }

    private Vod vod(String url) {
        Vod vod = new Vod();
        vod.setVodId(url);
        vod.setTypeName("Push");
        vod.setVodName(url.startsWith("file://") ? new File(url.substring(7)).getName() : url);
        if (url.contains("://") && url.contains("#")) url = url.replace("#", "***");

        if (Util.isThunder(url)) {
            vod.setVodPlayUrl(url);
            vod.setVodPlayFrom("迅雷");
        } else if (url.contains("$")) {
            vod.setVodPlayFrom("直连");
            vod.setVodPlayUrl(url.replace("\n", "#"));
        } else {
            vod.setVodPlayUrl(url + "$$$" + url + "$$$" + url);
            vod.setVodPlayFrom("直连$$$嗅探$$$解析");
        }
        return vod;
    }
}

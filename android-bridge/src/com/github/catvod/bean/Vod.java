package com.github.catvod.bean;

public class Vod {
    private String vod_id = "";
    private String vod_name = "";
    private String vod_pic = "";
    private String vod_remarks = "";
    private String vod_year = "";
    private String vod_area = "";
    private String vod_actor = "";
    private String vod_director = "";
    private String vod_content = "";
    private String vod_play_from = "";
    private String vod_play_url = "";
    private String type_name = "";

    public Vod() {}

    public Vod(String vodId, String vodName, String vodPic) {
        this.vod_id = vodId != null ? vodId : "";
        this.vod_name = vodName != null ? vodName : "";
        this.vod_pic = vodPic != null ? vodPic : "";
    }

    public Vod(String vodId, String vodName, String vodPic, String vodRemarks) {
        this(vodId, vodName, vodPic);
        this.vod_remarks = vodRemarks != null ? vodRemarks : "";
    }

    public String getVodId() { return vod_id; }
    public void setVodId(String vodId) { this.vod_id = vodId != null ? vodId : ""; }

    public String getVodName() { return vod_name; }
    public void setVodName(String vodName) { this.vod_name = vodName != null ? vodName : ""; }

    public String getVodPic() { return vod_pic; }
    public void setVodPic(String vodPic) { this.vod_pic = vodPic != null ? vodPic : ""; }

    public String getVodRemarks() { return vod_remarks; }
    public void setVodRemarks(String vodRemarks) { this.vod_remarks = vodRemarks != null ? vodRemarks : ""; }

    public String getVodYear() { return vod_year; }
    public void setVodYear(String vodYear) { this.vod_year = vodYear != null ? vodYear : ""; }

    public String getVodArea() { return vod_area; }
    public void setVodArea(String vodArea) { this.vod_area = vodArea != null ? vodArea : ""; }

    public String getVodActor() { return vod_actor; }
    public void setVodActor(String vodActor) { this.vod_actor = vodActor != null ? vodActor : ""; }

    public String getVodDirector() { return vod_director; }
    public void setVodDirector(String vodDirector) { this.vod_director = vodDirector != null ? vodDirector : ""; }

    public String getVodContent() { return vod_content; }
    public void setVodContent(String vodContent) { this.vod_content = vodContent != null ? vodContent : ""; }

    public String getVodPlayFrom() { return vod_play_from; }
    public void setVodPlayFrom(String vodPlayFrom) { this.vod_play_from = vodPlayFrom != null ? vodPlayFrom : ""; }

    public String getVodPlayUrl() { return vod_play_url; }
    public void setVodPlayUrl(String vodPlayUrl) { this.vod_play_url = vodPlayUrl != null ? vodPlayUrl : ""; }

    public String getTypeName() { return type_name; }
    public void setTypeName(String typeName) { this.type_name = typeName != null ? typeName : ""; }

    public String toJson() {
        StringBuilder sb = new StringBuilder("{");
        sb.append("\"vod_id\":\"").append(escape(vod_id)).append("\",");
        sb.append("\"vod_name\":\"").append(escape(vod_name)).append("\",");
        sb.append("\"vod_pic\":\"").append(escape(vod_pic)).append("\",");
        sb.append("\"vod_remarks\":\"").append(escape(vod_remarks)).append("\",");
        sb.append("\"vod_year\":\"").append(escape(vod_year)).append("\",");
        sb.append("\"vod_area\":\"").append(escape(vod_area)).append("\",");
        sb.append("\"vod_actor\":\"").append(escape(vod_actor)).append("\",");
        sb.append("\"vod_director\":\"").append(escape(vod_director)).append("\",");
        sb.append("\"vod_content\":\"").append(escape(vod_content)).append("\",");
        sb.append("\"vod_play_from\":\"").append(escape(vod_play_from)).append("\",");
        sb.append("\"vod_play_url\":\"").append(escape(vod_play_url)).append("\",");
        sb.append("\"type_name\":\"").append(escape(type_name)).append("\"");
        sb.append("}");
        return sb.toString();
    }

    private static String escape(String s) {
        if (s == null) return "";
        return s.replace("\\", "\\\\").replace("\"", "\\\"").replace("\n", "\\n").replace("\r", "\\r");
    }
}

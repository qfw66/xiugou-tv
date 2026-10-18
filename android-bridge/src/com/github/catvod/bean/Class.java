package com.github.catvod.bean;

public class Class {
    private String type_id;
    private String type_name;
    private String type_flag;

    public Class(String typeId) {
        this(typeId, typeId);
    }

    public Class(String typeId, String typeName) {
        this(typeId, typeName, null);
    }

    public Class(String typeId, String typeName, String typeFlag) {
        this.type_id = typeId;
        this.type_name = typeName;
        this.type_flag = typeFlag;
    }

    public String getTypeId() {
        return type_id != null ? type_id : "";
    }

    public String getTypeName() {
        return type_name != null ? type_name : "";
    }

    public String getTypeFlag() {
        return type_flag;
    }

    public String toJson() {
        StringBuilder sb = new StringBuilder("{");
        sb.append("\"type_id\":\"").append(escape(type_id)).append("\",");
        sb.append("\"type_name\":\"").append(escape(type_name)).append("\"");
        if (type_flag != null) {
            sb.append(",\"type_flag\":\"").append(escape(type_flag)).append("\"");
        }
        sb.append("}");
        return sb.toString();
    }

    private static String escape(String s) {
        if (s == null) return "";
        return s.replace("\\", "\\\\").replace("\"", "\\\"").replace("\n", "\\n").replace("\r", "\\r");
    }
}

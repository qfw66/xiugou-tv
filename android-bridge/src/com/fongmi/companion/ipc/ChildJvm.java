package com.fongmi.companion.ipc;

import java.io.File;
import java.util.ArrayList;
import java.util.Collections;
import java.util.List;

/** 子 JVM 不会继承父 JVM 的 -D 参数，只传递站源运行所需的两个目录。 */
public final class ChildJvm {
    private ChildJvm() {}

    public static List<String> command(String... args) {
        File bin = new File(System.getProperty("java.home"), "bin");
        List<String> command = new ArrayList<>();
        command.add(new File(bin, File.separatorChar == '\\' ? "java.exe" : "java").getAbsolutePath());
        for (String key : List.of("user.home", "java.io.tmpdir")) {
            String value = System.getProperty(key);
            if (value != null && !value.isEmpty()) command.add("-D" + key + "=" + value);
        }
        Collections.addAll(command, args);
        return command;
    }
}

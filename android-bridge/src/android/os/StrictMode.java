package android.os;

/**
 * 桌面端的 {@code StrictMode} 空实现。
 *
 * <p>加固载荷（wexguard 的 {@code InitOrigin.init}、ftyguard 的部分 Config 类）
 * 会在初始化时立刻执行
 * {@code StrictMode.setThreadPolicy(new StrictMode.ThreadPolicy.Builder().permitAll().build())}。
 * JVM 上缺这个类会抛 {@code NoClassDefFoundError}，导致整个 InitOrigin 初始化中断、
 * 其静态配置字段（JSONObject）保持 null，最终表现为该站 0 数据。
 *
 * <p>桌面端没有主线程磁盘违例的概念，所有方法都是无操作；Builder 保留链式调用形态。
 */
public final class StrictMode {

    private StrictMode() {
    }

    public static void setThreadPolicy(ThreadPolicy policy) {
    }

    public static ThreadPolicy getThreadPolicy() {
        return new ThreadPolicy();
    }

    public static ThreadPolicy.Builder allowThreadDiskReads() {
        return new ThreadPolicy.Builder();
    }

    public static ThreadPolicy.Builder allowThreadDiskWrites() {
        return new ThreadPolicy.Builder();
    }

    public static void setVmPolicy(VmPolicy policy) {
    }

    public static VmPolicy getVmPolicy() {
        return new VmPolicy();
    }

    /** 线程策略：桌面端无实际语义。 */
    public static class ThreadPolicy {

        public static class Builder {
            public Builder() {
            }

            public Builder detectAll() {
                return this;
            }

            public Builder detectDiskReads() {
                return this;
            }

            public Builder detectDiskWrites() {
                return this;
            }

            public Builder detectNetwork() {
                return this;
            }

            public Builder detectCustomSlowCalls() {
                return this;
            }

            public Builder detectResourceMismatches() {
                return this;
            }

            public Builder detectUnbufferedIo() {
                return this;
            }

            public Builder permitAll() {
                return this;
            }

            public Builder permitDiskReads() {
                return this;
            }

            public Builder permitDiskWrites() {
                return this;
            }

            public Builder permitCustomSlowCalls() {
                return this;
            }

            public Builder permitNetwork() {
                return this;
            }

            public Builder permitUnbufferedIo() {
                return this;
            }

            public Builder penaltyLog() {
                return this;
            }

            public Builder penaltyDialog() {
                return this;
            }

            public Builder penaltyDeath() {
                return this;
            }

            public Builder penaltyDeathOnNetwork() {
                return this;
            }

            public Builder penaltyFlashScreen() {
                return this;
            }

            public Builder penaltyDropBox() {
                return this;
            }

            public Builder threadPolicyMask(int mask) {
                return this;
            }

            public ThreadPolicy build() {
                return new ThreadPolicy();
            }
        }
    }

    /** VM 策略：桌面端无实际语义。 */
    public static class VmPolicy {

        public static class Builder {
            public Builder() {
            }

            public Builder detectAll() {
                return this;
            }

            public Builder detectLeakedSqlLiteObjects() {
                return this;
            }

            public Builder detectLeakedClosableObjects() {
                return this;
            }

            public Builder detectLeakedRegistrationObjects() {
                return this;
            }

            public Builder detectActivityLeaks() {
                return this;
            }

            public Builder detectFileUriExposure() {
                return this;
            }

            public Builder permitAll() {
                return this;
            }

            public Builder penaltyLog() {
                return this;
            }

            public Builder penaltyDeath() {
                return this;
            }

            public Builder penaltyDropBox() {
                return this;
            }

            public Builder setClassInstanceLimit(Class<?> klass, int instanceLimit) {
                return this;
            }

            public VmPolicy build() {
                return new VmPolicy();
            }
        }
    }
}

package android.text;

/**
 * 输入过滤器：EditText 在接收用户输入时依次套用，LengthFilter 截断超长内容，AllCaps 转大写。
 * 实现与 AOSP 语义一致。
 */
public interface InputFilter {

    /**
     * @return 替换 source[start,end) 的内容；返回 null 表示原样接受
     */
    CharSequence filter(CharSequence source, int start, int end, Spanned dest, int dstart, int dend);

    class LengthFilter implements InputFilter {

        private final int max;

        public LengthFilter(int max) {
            this.max = max;
        }

        @Override
        public CharSequence filter(CharSequence source, int start, int end, Spanned dest, int dstart, int dend) {
            int keep = max - (dest.length() - (dend - dstart));
            if (keep <= 0) return "";
            if (keep >= end - start) return null;
            keep += start;
            // 不把代理对拆成两半
            if (Character.isHighSurrogate(source.charAt(keep - 1))) {
                --keep;
                if (keep == start) return "";
            }
            return source.subSequence(start, keep);
        }

        public int getMax() {
            return max;
        }
    }

    class AllCaps implements InputFilter {

        @Override
        public CharSequence filter(CharSequence source, int start, int end, Spanned dest, int dstart, int dend) {
            String part = source.subSequence(start, end).toString();
            String upper = part.toUpperCase(java.util.Locale.ROOT);
            return upper.equals(part) ? null : upper;
        }
    }
}

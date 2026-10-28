package android.content;

/**
 * android.content.ClipData：剪贴板内容（只支持纯文本）。
 */
public class ClipData {

    public static class Item {
        private final CharSequence text;

        public Item(CharSequence text) {
            this.text = text;
        }

        public CharSequence getText() {
            return text;
        }

        public CharSequence coerceToText(Context context) {
            return text == null ? "" : text;
        }
    }

    private final CharSequence label;
    private final Item item;

    private ClipData(CharSequence label, Item item) {
        this.label = label;
        this.item = item;
    }

    public static ClipData newPlainText(CharSequence label, CharSequence text) {
        return new ClipData(label, new Item(text));
    }

    public int getItemCount() {
        return 1;
    }

    public Item getItemAt(int index) {
        return item;
    }

    public CharSequence getLabel() {
        return label;
    }
}

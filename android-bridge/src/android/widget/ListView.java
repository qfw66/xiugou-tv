package android.widget;

import android.content.Context;
import android.graphics.drawable.Drawable;
import android.util.AttributeSet;
import java.util.BitSet;

/** 桌面列表的数据和勾选状态；焦点位置与勾选位置是两件事。 */
public class ListView extends AbsListView {
    public static final int CHOICE_MODE_NONE = 0, CHOICE_MODE_SINGLE = 1, CHOICE_MODE_MULTIPLE = 2;
    private final BitSet checked = new BitSet();
    private int choiceMode;
    private boolean itemsCanFocus;
    private Drawable divider;
    private int dividerHeight;

    public ListView(Context context) { super(context); }
    public ListView(Context context, AttributeSet attrs) { super(context, attrs); }

    @Override public void setAdapter(ListAdapter adapter) {
        checked.clear();
        super.setAdapter(adapter);
    }

    public void setChoiceMode(int mode) {
        if (mode == choiceMode) return;
        choiceMode = mode;
        checked.clear();
        notifyChanged();
    }

    public int getChoiceMode() { return choiceMode; }
    public int getCheckedItemPosition() {
        return choiceMode == CHOICE_MODE_SINGLE ? checked.nextSetBit(0) : INVALID_POSITION;
    }
    public boolean isItemChecked(int position) { return position >= 0 && checked.get(position); }

    public void setItemChecked(int position, boolean value) {
        if (choiceMode == CHOICE_MODE_NONE || position < 0 || position >= getCount()
                || checked.get(position) == value) return;
        if (choiceMode == CHOICE_MODE_SINGLE && value) checked.clear();
        checked.set(position, value);
        notifyChanged();
    }

    public void setItemsCanFocus(boolean enabled) { itemsCanFocus = enabled; }
    public boolean getItemsCanFocus() { return itemsCanFocus; }
    public void setDivider(Drawable value) { divider = value; }
    public Drawable getDivider() { return divider; }
    public void setDividerHeight(int height) { dividerHeight = height; }
    public int getDividerHeight() { return dividerHeight; }
    public int getFirstVisiblePosition() { return 0; }
}

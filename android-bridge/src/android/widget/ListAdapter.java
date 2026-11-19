package android.widget;

/** List-backed choice controls share Adapter positions and per-item enabled state. */
public interface ListAdapter extends Adapter {
    default boolean areAllItemsEnabled() { return true; }
    default boolean isEnabled(int position) { return true; }
}

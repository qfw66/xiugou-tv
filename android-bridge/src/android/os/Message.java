package android.os;

public class Message {

    public int what;
    public int arg1;
    public int arg2;
    public Object obj;
    public Handler target;
    public Runnable callback;

    public static Message obtain() {
        return new Message();
    }

    public static Message obtain(Handler h) {
        Message m = new Message();
        m.target = h;
        return m;
    }

    public void sendToTarget() {
        if (target != null) target.sendMessage(this);
    }

    public void recycle() {
    }
}

package android.graphics;

/**
 * 整数坐标点。
 */
public class Point {

    public int x;
    public int y;

    public Point() {
    }

    public Point(int x, int y) {
        this.x = x;
        this.y = y;
    }

    public Point(Point src) {
        this(src.x, src.y);
    }

    public void set(int x, int y) {
        this.x = x;
        this.y = y;
    }

    public void offset(int dx, int dy) {
        x += dx;
        y += dy;
    }

    public void negate() {
        x = -x;
        y = -y;
    }

    public final boolean equals(int x, int y) {
        return this.x == x && this.y == y;
    }

    @Override
    public boolean equals(Object o) {
        if (!(o instanceof Point)) return false;
        Point p = (Point) o;
        return x == p.x && y == p.y;
    }

    @Override
    public int hashCode() {
        return 31 * x + y;
    }

    @Override
    public String toString() {
        return "Point(" + x + ", " + y + ")";
    }
}

package com.fongmi.companion.d2j;

import com.googlecode.dex2jar.ir.ET;
import com.googlecode.dex2jar.ir.IrMethod;
import com.googlecode.dex2jar.ir.StmtTraveler;
import com.googlecode.dex2jar.ir.expr.Exprs;
import com.googlecode.dex2jar.ir.expr.InvokeExpr;
import com.googlecode.dex2jar.ir.expr.Local;
import com.googlecode.dex2jar.ir.expr.NewExpr;
import com.googlecode.dex2jar.ir.expr.Value;
import com.googlecode.dex2jar.ir.stmt.AssignStmt;
import com.googlecode.dex2jar.ir.stmt.LabelStmt;
import com.googlecode.dex2jar.ir.stmt.Stmt;
import com.googlecode.dex2jar.ir.stmt.Stmts;
import com.googlecode.dex2jar.ir.ts.Cfg;
import com.googlecode.dex2jar.ir.ts.Transformer;

import java.util.Arrays;
import java.util.HashMap;
import java.util.HashSet;
import java.util.Iterator;
import java.util.Map;
import java.util.Set;
import java.util.concurrent.atomic.AtomicInteger;

/**
 * dex2jar 2.4.31 {@code com.googlecode.dex2jar.ir.ts.NewTransformer} 的修正版（原实现 Apache-2.0）。
 *
 * <p>原实现把 {@code new-instance T} 与随后的 {@code invoke-direct S.<init>} 合并成
 * {@code new S(...)}：合并表达式只记得构造器所属类 S，真实分配类型 T 被丢弃。
 * 加固载荷大量使用「把子类构造器内联到调用点、直接调父类构造器」的写法（T 往往连
 * {@code <init>} 都没有），ART 接受这种写法；经原实现转换后，对象的运行期类型变成父类
 * （常见是 {@code Object} / {@code TypeToken}），随后表现为 AbstractMethodError、
 * 「Object 不能转 Runnable」、gson 的 "Must only create direct subclasses of TypeToken"。
 *
 * <p>修正：仅当分配类型与构造器所属类一致时才合并；不一致时保留未合并的
 * {@code a = new T; a.<init>()} 形态（原实现处理 use-before-init 时同样走这条路径），
 * 由 IR2JConverter 输出 {@code NEW T ... INVOKESPECIAL S.<init>}，与 dex 语义逐条一致。
 * 这种字节码不满足 JVM 类型校验，依赖 companion 以 {@code -noverify} 启动。
 */
public final class PreciseNewTransformer implements Transformer {

    private static final Vx IGNORED = new Vx(null, true);

    /** 本实例累计保留的「分配类型 ≠ 构造器所属类」点位数，供转换日志使用。 */
    public final AtomicInteger keptMismatched = new AtomicInteger();

    @Override
    public void transform(IrMethod method) {
        replaceX(method);
        replaceAST(method);
    }

    private void replaceX(IrMethod method) {
        Map<Local, TObject> init = new HashMap<>();
        for (Stmt p : method.stmts) {
            if (p.st == Stmt.ST.ASSIGN && p.getOp1().vt == Value.VT.LOCAL && p.getOp2().vt == Value.VT.NEW) {
                Local local = (Local) p.getOp1();
                init.put(local, new TObject(local, (AssignStmt) p));
            }
        }
        if (init.isEmpty()) {
            return;
        }
        int size = Cfg.reIndexLocal(method);
        makeSureUsedBeforeConstructor(method, init, size);
        dropMismatched(init);
        if (!init.isEmpty()) {
            replace0(method, init, size);
        }
        for (Stmt stmt : method.stmts) {
            stmt.frame = null;
        }
    }

    private void dropMismatched(Map<Local, TObject> init) {
        Iterator<TObject> it = init.values().iterator();
        while (it.hasNext()) {
            TObject obj = it.next();
            String allocated = ((NewExpr) obj.init.getOp2()).type;
            InvokeExpr ie = findInvokeExpr(obj.invokeStmt);
            if (ie != null && !allocated.equals(ie.getOwner())) {
                it.remove();
                keptMismatched.incrementAndGet();
            }
        }
    }

    private void replaceAST(IrMethod method) {
        Iterator<Stmt> it = method.stmts.iterator();
        while (it.hasNext()) {
            Stmt p = it.next();
            InvokeExpr ie = findInvokeExpr(p);
            if (ie == null || !"<init>".equals(ie.getName()) || !"V".equals(ie.getRet())) {
                continue;
            }
            Value[] orgOps = ie.getOps();
            if (orgOps[0].vt != Value.VT.NEW) {
                continue;
            }
            NewExpr newExpr = (NewExpr) orgOps[0];
            if (!newExpr.type.equals(ie.getOwner())) {
                keptMismatched.incrementAndGet();
                continue;
            }
            Value[] nOps = Arrays.copyOfRange(orgOps, 1, orgOps.length);
            InvokeExpr invokeNew = Exprs.nInvokeNew(nOps, ie.getArgs(), ie.getOwner());
            method.stmts.insertBefore(p, Stmts.nVoidInvoke(invokeNew));
            it.remove();
        }
    }

    private void replace0(IrMethod method, Map<Local, TObject> init, int size) {
        Set<Local> toDelete = new HashSet<>();
        Local[] locals = new Local[size];
        for (Local local : method.locals) {
            locals[local.lsIndex] = local;
        }
        for (TObject obj : init.values()) {
            Vx[] frame = (Vx[]) obj.invokeStmt.frame;
            for (int i = 0; i < frame.length; i++) {
                Vx s = frame[i];
                if (s != null && s.obj == obj) {
                    toDelete.add(locals[i]);
                }
            }
        }
        Iterator<Stmt> it = method.stmts.iterator();
        while (it.hasNext()) {
            Stmt p = it.next();
            if (p.st == Stmt.ST.ASSIGN && p.getOp1().vt == Value.VT.LOCAL && toDelete.contains((Local) p.getOp1())) {
                it.remove();
            }
        }
        for (TObject obj : init.values()) {
            Vx[] frame = (Vx[]) obj.invokeStmt.frame;
            for (int i = 0; i < frame.length; i++) {
                Vx s = frame[i];
                if (s == null || s.obj != obj) {
                    continue;
                }
                Local b = locals[i];
                if (b != obj.local) {
                    method.stmts.insertAfter(obj.invokeStmt, Stmts.nAssign(b, obj.local));
                }
            }
            InvokeExpr ie = findInvokeExpr(obj.invokeStmt);
            Value[] orgOps = ie.getOps();
            Value[] nOps = Arrays.copyOfRange(orgOps, 1, orgOps.length);
            InvokeExpr invokeNew = Exprs.nInvokeNew(nOps, ie.getArgs(), ie.getOwner());
            method.stmts.replace(obj.invokeStmt, Stmts.nAssign(obj.local, invokeNew));
        }
    }

    private void makeSureUsedBeforeConstructor(IrMethod method, final Map<Local, TObject> init, final int size) {
        Cfg.createCFG(method);
        Cfg.dfs(method.stmts, new Cfg.FrameVisitor<Vx[]>() {
            boolean keepFrame = false;
            final Vx[] tmp = new Vx[size];
            final StmtTraveler stmtTraveler = new StmtTraveler() {
                Stmt current;

                @Override
                public Stmt travel(Stmt stmt) {
                    this.current = stmt;
                    if (stmt.et == ET.E2 && stmt.getOp1().vt == Value.VT.LOCAL) {
                        Local op1 = (Local) stmt.getOp1();
                        if (stmt.getOp2().vt == Value.VT.LOCAL) {
                            Local op2 = (Local) stmt.getOp2();
                            tmp[op1.lsIndex] = tmp[op2.lsIndex];
                            return stmt;
                        } else if (stmt.getOp2().vt == Value.VT.NEW) {
                            tmp[op1.lsIndex] = new Vx(init.get(op1), false);
                            return stmt;
                        } else {
                            travel(stmt.getOp2());
                            tmp[op1.lsIndex] = IGNORED;
                            return stmt;
                        }
                    }
                    if (stmt.st == Stmt.ST.LABEL) {
                        LabelStmt labelStmt = (LabelStmt) stmt;
                        if (labelStmt.phis != null) {
                            for (AssignStmt phi : labelStmt.phis) {
                                Local local = (Local) phi.getOp1();
                                tmp[local.lsIndex] = IGNORED;
                            }
                        }
                        return stmt;
                    }
                    return super.travel(stmt);
                }

                @Override
                public Value travel(Value op) {
                    if (op.vt == Value.VT.INVOKE_SPECIAL && op.getOps().length >= 1
                            && "<init>".equals(((InvokeExpr) op).getName())) {
                        Value thiz = op.getOps()[0];
                        if (thiz.vt == Value.VT.LOCAL) {
                            Local local = (Local) thiz;
                            Vx vx = tmp[local.lsIndex];
                            TObject object = vx.obj;
                            if (object != null) {
                                if (object.invokeStmt != null) {
                                    object.useBeforeInit = true;
                                } else {
                                    vx.init = true;
                                    object.invokeStmt = current;
                                    for (int i = 0; i < tmp.length; i++) {
                                        Vx s = tmp[i];
                                        if (s != null && s.obj == object) {
                                            tmp[i] = IGNORED;
                                        }
                                    }
                                    keepFrame = true;
                                }
                            }
                        }
                    }
                    op = super.travel(op);
                    if (op.vt == Value.VT.LOCAL) {
                        use((Local) op);
                    }
                    return op;
                }
            };

            @Override
            public Vx[] merge(Vx[] srcFrame, Vx[] distFrame, Stmt src, Stmt dist) {
                if (distFrame == null) {
                    distFrame = new Vx[size];
                    System.arraycopy(srcFrame, 0, distFrame, 0, size);
                } else {
                    for (int i = 0; i < size; i++) {
                        Vx s = srcFrame[i];
                        Vx d = distFrame[i];
                        if (s == null) {
                            continue;
                        }
                        if (d == null) {
                            distFrame[i] = s;
                        } else if (s != d) {
                            if (s.obj != null) {
                                s.obj.useBeforeInit = true;
                            }
                            if (d.obj != null) {
                                d.obj.useBeforeInit = true;
                            }
                        }
                    }
                }
                if (dist.st == Stmt.ST.LABEL) {
                    java.util.List<AssignStmt> phis = ((LabelStmt) dist).phis;
                    if (phis != null && !phis.isEmpty()) {
                        for (AssignStmt phi : phis) {
                            for (Value value : phi.getOp2().getOps()) {
                                Local local = (Local) value;
                                int i = local.lsIndex;
                                Vx s = srcFrame[i];
                                Vx d = distFrame[i];
                                if (d != null) {
                                    if (!d.init && d.obj != null) {
                                        d.obj.useBeforeInit = true;
                                    }
                                } else if (s != null && !s.init && s.obj != null) {
                                    s.obj.useBeforeInit = true;
                                }
                            }
                        }
                    }
                }
                return distFrame;
            }

            @Override
            public Vx[] initFirstFrame(Stmt first) {
                return new Vx[size];
            }

            @Override
            public Vx[] exec(Vx[] frame, Stmt stmt) {
                keepFrame = false;
                System.arraycopy(frame, 0, tmp, 0, size);
                stmtTraveler.travel(stmt);
                if (stmt.cfgFroms.size() > 1) {
                    keepFrame = true;
                }
                if (!keepFrame) {
                    stmt.frame = null;
                }
                return tmp;
            }

            void use(Local local) {
                Vx vx = tmp[local.lsIndex];
                if (!vx.init) {
                    TObject object = vx.obj;
                    if (object != null) {
                        object.useBeforeInit = true;
                    }
                    tmp[local.lsIndex] = IGNORED;
                }
            }
        });
        init.values().removeIf(obj -> obj.useBeforeInit || obj.invokeStmt == null);
    }

    private static InvokeExpr findInvokeExpr(Stmt p) {
        if (p.st == Stmt.ST.ASSIGN) {
            if (p.getOp2().vt == Value.VT.INVOKE_SPECIAL) {
                return (InvokeExpr) p.getOp2();
            }
        } else if (p.st == Stmt.ST.VOID_INVOKE) {
            Value op = p.getOp();
            if (op instanceof InvokeExpr) {
                return (InvokeExpr) op;
            }
        }
        return null;
    }

    private static final class TObject {
        Stmt invokeStmt;
        final Local local;
        boolean useBeforeInit;
        final AssignStmt init;

        TObject(Local local, AssignStmt init) {
            this.local = local;
            this.init = init;
        }
    }

    private static final class Vx {
        boolean init;
        final TObject obj;

        Vx(TObject obj, boolean init) {
            this.obj = obj;
            this.init = init;
        }
    }
}

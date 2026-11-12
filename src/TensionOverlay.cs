using System;
using System.Collections.Generic;
using System.Drawing;
using System.Drawing.Drawing2D;
using System.Drawing.Text;
using System.IO;
using System.Runtime.InteropServices;
using System.Text;
using System.Threading;
using System.Windows.Forms;

[assembly: System.Reflection.AssemblyVersion("1.0.0.0")]
[assembly: System.Reflection.AssemblyFileVersion("1.0.0.0")]
[assembly: System.Reflection.AssemblyProduct("PBZTensionHUD")]
[assembly: System.Reflection.AssemblyTitle("PBZTensionHUD overlay")]

public class TensionOverlay : Form
{
    // ---------------- Win32 ----------------
    const int WS_EX_LAYERED = 0x00080000;
    const int WS_EX_TRANSPARENT = 0x00000020;
    const int WS_EX_TOOLWINDOW = 0x00000080;
    const int WS_EX_NOACTIVATE = 0x08000000;
    const int WS_EX_TOPMOST = 0x00000008;
    const int ULW_ALPHA = 2;
    const byte AC_SRC_OVER = 0x00;
    const byte AC_SRC_ALPHA = 0x01;

    [StructLayout(LayoutKind.Sequential, Pack = 1)]
    struct BLENDFUNCTION { public byte BlendOp, BlendFlags, SourceConstantAlpha, AlphaFormat; }
    [StructLayout(LayoutKind.Sequential)] struct POINT { public int X, Y; }
    [StructLayout(LayoutKind.Sequential)] struct SIZE { public int cx, cy; }
    [StructLayout(LayoutKind.Sequential)] struct RECT { public int Left, Top, Right, Bottom; }

    [DllImport("user32.dll")] static extern IntPtr GetDC(IntPtr hWnd);
    [DllImport("user32.dll")] static extern int ReleaseDC(IntPtr hWnd, IntPtr hDC);
    [DllImport("gdi32.dll")] static extern IntPtr CreateCompatibleDC(IntPtr hdc);
    [DllImport("gdi32.dll")] static extern bool DeleteDC(IntPtr hdc);
    [DllImport("gdi32.dll")] static extern IntPtr SelectObject(IntPtr hdc, IntPtr h);
    [DllImport("gdi32.dll")] static extern bool DeleteObject(IntPtr h);
    [DllImport("user32.dll")] static extern bool UpdateLayeredWindow(IntPtr hwnd, IntPtr hdcDst, ref POINT pptDst,
        ref SIZE psize, IntPtr hdcSrc, ref POINT pptSrc, int crKey, ref BLENDFUNCTION pblend, int dwFlags);
    [DllImport("user32.dll")] static extern bool SetWindowPos(IntPtr hWnd, IntPtr after, int X, int Y, int cx, int cy, uint flags);
    [DllImport("user32.dll")] static extern bool IsWindowVisible(IntPtr hWnd);
    [DllImport("user32.dll")] static extern bool EnumWindows(EnumWindowsProc cb, IntPtr p);
    delegate bool EnumWindowsProc(IntPtr hWnd, IntPtr lParam);
    [DllImport("user32.dll")] static extern uint GetWindowThreadProcessId(IntPtr hWnd, out uint pid);
    [DllImport("user32.dll")] static extern bool GetWindowRect(IntPtr hWnd, out RECT r);
    [DllImport("shcore.dll")] static extern int SetProcessDpiAwareness(int value);
    [DllImport("user32.dll")] static extern bool SetProcessDPIAware();
    static readonly IntPtr HWND_TOPMOST = new IntPtr(-1);
    const uint SWP_NOSIZE = 0x0001, SWP_NOMOVE = 0x0002, SWP_NOACTIVATE = 0x0010;

    // ---------------- compact layout (design px @1080p) ----------------
    const int PAD = 4;
    const int PANEL_W = 344;
    const int PANEL_H_STD = 424;
    const int PANEL_H_FULL = 516;

    const float X0 = 12, X1 = 332;          // content bounds
    const float TITLE_Y = 8;
    const float BOSS_Y = 30;
    const float HP_Y = 49;
    const float DIV_A = 56;
    const float SEAL_Y = 62, SEAL_SZ = 58;
    const float SCORE_Y = 64;
    const float CHART_Y = 108, CHART_H = 42;   // realtime 30 s score curve
    const float TREND_Y = 156;
    const float DIV_B = 176;
    const float DIM_Y = 182, DIM_ROW = 17;
    const float DIV_C = 254;
    const float LOG_HDR_Y = 258;
    const float LOG_TOP = 272, LOG_ROW = 21;
    const int LOG_ROWS = 6;
    const double CHART_SECONDS = 30.0;
    const double ROW_LIFE = 8.0;

    // ---------------- state ----------------
    class EvRow { public string Name = ""; public double Value; public double BaseW; public int Count = 1; public double Born; public long Rc; }

    class State
    {
        public long Ts;
        public long Fight;
        public bool Visible;
        public string Boss = "";
        public int Tier = 2;
        public double Raw, Delta, Peak;
        public double PlayerHp = -1, BossHp = -1;
        public double Shachi = -1, ShachiDps = 0;
        public long EvSeq;
        public List<KeyValuePair<string, double>> Dims = new List<KeyValuePair<string, double>>();
        public List<string[]> Events = new List<string[]>();
        public List<string[]> Weights = new List<string[]>();
        public string Preset = "full";
        public int Page = 1, Pages = 1;
    }

    State st = new State();
    string statePath;
    IntPtr gameWnd = IntPtr.Zero;
    System.Windows.Forms.Timer timer;
    string lastSignature = "";
    int lastX = int.MinValue, lastY = int.MinValue;
    float S = 1f;

    // scrolling log
    readonly List<EvRow> rows = new List<EvRow>();
    long seenSeq = -1;
    long lastFlashSeq = -1;
    double scrollRc = 0, scrollTarget = 0; long nextRc = 0;
    const double TICKER_ROWS_PER_SEC = 3.2;
    double nowClock = 0;

    // ---------------- palette ----------------
    static Color A(int a, int r, int g, int b) { return Color.FromArgb(a, r, g, b); }
    static readonly Color C_PANEL = A(230, 0x0B, 0x0C, 0x0E);
    static readonly Color C_WELL = A(125, 0x05, 0x06, 0x0A);
    static readonly Color C_BAND = A(80, 0, 0, 0);
    static readonly Color C_GOLD = A(170, 0xC8, 0xB4, 0x78);
    static readonly Color C_GOLD_SOFT = A(60, 0xC8, 0xB4, 0x78);
    static readonly Color C_GOLD_BRIGHT = A(255, 0xE3, 0xC7, 0x7E);
    static readonly Color C_TXT1 = A(255, 0xF2, 0xEA, 0xD8);
    static readonly Color C_TXT2 = A(235, 0xC9, 0xBE, 0xA5);
    static readonly Color C_TXT3 = A(225, 0xA8, 0x9C, 0x84);
    static readonly Color C_TXT4 = A(215, 0x8C, 0x82, 0x70);
    static readonly Color C_BAD = A(255, 0xF4, 0x86, 0x6B);
    static readonly Color C_BAD_BIG = A(255, 0xE8, 0x70, 0x5A);
    static readonly Color C_GOOD = A(255, 0x8F, 0xC7, 0xB4);
    static readonly Color C_INK = A(250, 0x0A, 0x0B, 0x0D);

    static Color TierColor(int t)
    {
        switch (t)
        {
            case 0: return Color.FromArgb(255, 0x8C, 0xBB, 0xD0);
            case 1: return Color.FromArgb(255, 0x9C, 0xCA, 0xA6);
            case 2: return Color.FromArgb(255, 0xD6, 0xBE, 0x84);
            case 3: return Color.FromArgb(255, 0xE9, 0xB2, 0x68);
            case 4: return Color.FromArgb(255, 0xED, 0x7E, 0x52);
            default: return Color.FromArgb(255, 0xE2, 0x55, 0x44);
        }
    }
    static string TierName(int t)
    {
        switch (t)
        {
            case 0: return "CALM";
            case 1: return "STEADY";
            case 2: return "NEUTRAL";
            case 3: return "PRESSURED";
            case 4: return "PANIC";
            default: return "OVERWHELMED";
        }
    }
    // two-character state, wuxia flavoured
    static string TierAdj(int t)
    {
        switch (t)
        {
            case 0: return "从容";
            case 1: return "沉稳";
            case 2: return "相持";
            case 3: return "吃紧";
            case 4: return "失措";
            default: return "难支";
        }
    }

    // four-character line that reads like a line from a wuxia novel
    static string TierPoem(int t)
    {
        switch (t)
        {
            case 0: return "游刃有余";
            case 1: return "章法有度";
            case 2: return "势均力敌";
            case 3: return "渐落下风";
            case 4: return "阵脚已乱";
            default: return "命悬一线";
        }
    }

    public TensionOverlay(string path)
    {
        statePath = path;
        FormBorderStyle = FormBorderStyle.None;
        ShowInTaskbar = false;
        TopMost = true;
        StartPosition = FormStartPosition.Manual;
        SetStyle(ControlStyles.AllPaintingInWmPaint | ControlStyles.Opaque | ControlStyles.UserPaint, true);
        Size = new Size(360, 400);
        Location = new Point(-10000, -10000);

        timer = new System.Windows.Forms.Timer();
        timer.Interval = 100;
        timer.Tick += delegate { Pump(); };
        timer.Start();
    }

    protected override bool ShowWithoutActivation { get { return true; } }
    protected override CreateParams CreateParams
    {
        get
        {
            CreateParams cp = base.CreateParams;
            cp.ExStyle |= WS_EX_LAYERED | WS_EX_TRANSPARENT | WS_EX_TOOLWINDOW | WS_EX_NOACTIVATE | WS_EX_TOPMOST;
            return cp;
        }
    }

    public static void Log(string msg)
    {
        string line = DateTime.Now.ToString("HH:mm:ss") + " " + msg + Environment.NewLine;
        foreach (var dir in new string[]
        {
            Path.Combine(Path.GetTempPath(), "PBZTensionHUD"),
            Path.GetDirectoryName(System.Reflection.Assembly.GetExecutingAssembly().Location)
        })
        {
            try
            {
                if (dir == null) continue;
                Directory.CreateDirectory(dir);
                File.AppendAllText(Path.Combine(dir, "overlay.log"), line);
                return;
            }
            catch { }
        }
    }

    // ---------------- lifecycle ----------------
    int noGameTicks = 0;
    double panelAlpha = 162, lastBgSample = -10;
    string flashName = ""; double flashValue = 0, flashAt = -10;
    double emptySince = -1; long lastFightSeen = -1;
    readonly List<double> evStamps = new List<double>(); double mashUntil = -10;
    readonly List<KeyValuePair<double, double>> hist = new List<KeyValuePair<double, double>>();
    double chartSmooth = 0; bool chartInit = false; double lastBeat = -10; double lastChartLog = -10; double lastAcceptedAt = 0;
    readonly DateTime startTime = DateTime.Now;

    void Pump()
    {
        try
        {
            double prevNow = nowClock;
            nowClock = (DateTime.Now - startTime).TotalSeconds;
            double dt = Math.Max(0.0, Math.Min(0.3, nowClock - prevNow));
            Watchdog();
            LoadState();
            if (nowClock - lastBeat > 2)
            {
                lastBeat = nowClock;
                try
                {
                    string hb = Path.Combine(Path.GetDirectoryName(statePath), "overlay.alive");
                    File.WriteAllText(hb, DateTimeOffset.UtcNow.ToUnixTimeSeconds().ToString());
                }
                catch { }
            }            if (!st.Visible) { MoveOffscreen(); return; }
            ComputeScale();
            LocateGame();

            // instant and dense: the feed jumps to the newest state the moment an action lands,
            // exactly like the in-game reference overlay (no drifting scroll)
            scrollRc = scrollTarget;
            if (rows.Count > 0) rows.RemoveAll(r => r.Rc < scrollRc - 1.6);

            bool animating = nowClock < mashUntil;
            bool live = st.Boss.Length > 0 || rows.Count > 0;
            int want = (animating || live) ? 50 : 100;
            if (timer.Interval != want) timer.Interval = want;

            string sig = Signature();
            if (sig != lastSignature || animating || live)
            {
                lastSignature = sig;
                Render();
            }
        }
        catch (Exception ex) { Log("pump error: " + ex.Message); }
    }

    void Watchdog()
    {
        bool gameAlive = false;
        try { gameAlive = System.Diagnostics.Process.GetProcessesByName("PBZ").Length > 0; }
        catch { gameAlive = true; }
        if (gameAlive) { noGameTicks = 0; return; }
        noGameTicks++;
        if (noGameTicks > 200) { Log("game exited, shutting down"); Application.Exit(); }
    }

    // sample the scene just left of the panel (the overlay is on top, so we must sample outside it)
    // bright scene -> more opaque so text stays readable; dark scene -> much more transparent
    void UpdateBackdrop()
    {
        if (nowClock - lastBgSample < 1.2) return;
        lastBgSample = nowClock;
        if (lastX == int.MinValue || lastY == int.MinValue) return;
        int sw = 48, sh = 220;
        int sx = lastX - sw - 10;
        int sy = lastY + 40;
        if (sx < 0 || sy < 0) return;
        try
        {
            using (var bmp = new Bitmap(sw, sh))
            using (var g = Graphics.FromImage(bmp))
            {
                g.CopyFromScreen(sx, sy, 0, 0, new Size(sw, sh));
                double sum = 0; int n = 0;
                for (int y = 0; y < sh; y += 8)
                    for (int x = 0; x < sw; x += 8)
                    {
                        Color c = bmp.GetPixel(x, y);
                        sum += 0.299 * c.R + 0.587 * c.G + 0.114 * c.B;
                        n++;
                    }
                double luma = n > 0 ? sum / n : 128;
                double target = 126 + (luma / 255.0) * 88;   // 126 .. 214
                panelAlpha = panelAlpha * 0.55 + target * 0.45;
            }
        }
        catch { }
    }

    void MoveOffscreen()
    {
        lastX = int.MinValue;
        lastY = int.MinValue;
        if (Width > 0) SetWindowPos(Handle, HWND_TOPMOST, -10000, -10000, 0, 0, SWP_NOSIZE | SWP_NOACTIVATE);
    }

    void ComputeScale()
    {
        Screen scr = Screen.PrimaryScreen;
        float h = scr != null ? scr.Bounds.Height : 1080f;
        S = h / 1080f;
        if (S < 0.80f) S = 0.80f;
        if (S > 1.40f) S = 1.40f;
    }

    IntPtr FindGameWindow()
    {
        var pids = new HashSet<uint>();
        foreach (var p in System.Diagnostics.Process.GetProcessesByName("PBZ"))
        {
            try { pids.Add((uint)p.Id); } catch { }
        }
        if (pids.Count == 0) return IntPtr.Zero;
        IntPtr best = IntPtr.Zero;
        int bestArea = 0;
        EnumWindows(delegate (IntPtr h, IntPtr l)
        {
            uint pid;
            GetWindowThreadProcessId(h, out pid);
            if (!pids.Contains(pid)) return true;
            if (!IsWindowVisible(h)) return true;
            RECT r;
            if (!GetWindowRect(h, out r)) return true;
            int w = r.Right - r.Left, hh = r.Bottom - r.Top;
            if (w < 400 || hh < 300) return true;
            int area = w * hh;
            if (area > bestArea) { bestArea = area; best = h; }
            return true;
        }, IntPtr.Zero);
        return best;
    }

    void LocateGame()
    {
        if (gameWnd == IntPtr.Zero || !IsWindowVisible(gameWnd))
            gameWnd = FindGameWindow();

        int panelW = (int)(PANEL_W * S);
        int x, y;
        RECT r;
        if (gameWnd != IntPtr.Zero && GetWindowRect(gameWnd, out r))
        {
            int w = r.Right - r.Left, h = r.Bottom - r.Top;
            if (w < 200 || h < 200) return;
            x = r.Right - (int)(20 * S) - panelW - (int)(PAD * S);
            y = r.Top + (int)(20 * S) - (int)(PAD * S);
        }
        else
        {
            var scr = Screen.PrimaryScreen.Bounds;
            x = scr.Right - (int)(20 * S) - panelW - (int)(PAD * S);
            y = (int)(20 * S) - (int)(PAD * S);
        }
        if (x != lastX || y != lastY)
        {
            lastX = x; lastY = y;
            SetWindowPos(Handle, HWND_TOPMOST, x, y, 0, 0, SWP_NOSIZE | SWP_NOACTIVATE);
        }
    }

    // ---------------- state ----------------
    void LoadState()
    {
        if (!File.Exists(statePath)) { st.Visible = false; return; }
        string[] lines;
        try
        {
            using (var fs = new FileStream(statePath, FileMode.Open, FileAccess.Read, FileShare.ReadWrite))
            using (var sr = new StreamReader(fs, Encoding.UTF8))
            {
                var list = new List<string>();
                string line;
                while ((line = sr.ReadLine()) != null) list.Add(line);
                lines = list.ToArray();
            }
        }
        catch (IOException) { return; }
        catch (UnauthorizedAccessException) { return; }

        var s = new State();
        bool sawEof = false;
        foreach (string line in lines)
        {
            int eq = line.IndexOf('=');
            if (eq <= 0) continue;
            string k = line.Substring(0, eq).Trim();
            string v = line.Substring(eq + 1).Trim();
            try
            {
                switch (k)
                {
                    case "eof": sawEof = true; break;
                    case "fight": s.Fight = long.Parse(v); break;
                    case "ts": s.Ts = long.Parse(v); break;
                    case "visible": s.Visible = v == "1"; break;
                    case "boss": s.Boss = v; break;
                    case "tier": s.Tier = Math.Max(0, Math.Min(5, int.Parse(v))); break;
                    case "raw": s.Raw = D(v); break;
                    case "delta": s.Delta = D(v); break;
                    case "peak": s.Peak = D(v); break;
                    case "php": s.PlayerHp = D(v); break;
                    case "bhp": s.BossHp = D(v); break;
                    case "shachi": s.Shachi = D(v); break;
                    case "shachidps": s.ShachiDps = D(v); break;
                    case "evseq": s.EvSeq = long.Parse(v); break;
                    case "preset": s.Preset = v; break;
                    case "page": s.Page = int.Parse(v); break;
                    case "pages": s.Pages = int.Parse(v); break;
                    case "dim":
                        foreach (string part in v.Split(';'))
                        {
                            string[] f = part.Split('|');
                            if (f.Length < 2) continue;
                            s.Dims.Add(new KeyValuePair<string, double>(f[0], D(f[1])));
                        }
                        break;
                    case "ev":
                        foreach (string part in v.Split(';'))
                        {
                            string[] f = part.Split('|');
                            if (f.Length >= 3) s.Events.Add(new string[] { f[0], f[1], f[2], f.Length > 3 ? f[3] : "0" });
                        }
                        break;
                    case "w":
                        foreach (string part in v.Split(';'))
                        {
                            string[] f = part.Split('|');
                            if (f.Length >= 2) s.Weights.Add(new string[] { f[0], f[1] });
                        }
                        break;
                }
            }
            catch { }
        }
        if (!sawEof)
        {
            // torn write (or a stale mod that does not emit eof): keep the last good frame,
            // but do not freeze the HUD forever if the file never becomes valid again
            if (nowClock - lastAcceptedAt > 1.5) st.Visible = false;
            return;
        }
        lastAcceptedAt = nowClock;
        long now = DateTimeOffset.UtcNow.ToUnixTimeSeconds();
        if (s.Ts > 0 && now - s.Ts > 3) s.Visible = false;

        // feed the scrolling ticker
        if (seenSeq < 0) seenSeq = s.EvSeq;
        if (s.EvSeq > seenSeq)
        {
            seenSeq = s.EvSeq;
        }

        // a new fight must start with an empty ticker and an empty chart.
        // driven by the fight id (boss names can change mid-fight, so they are display-only)
        if (s.Fight != lastFightSeen)
        {
            lastFightSeen = s.Fight;
            rows.Clear();
            evStamps.Clear();
            hist.Clear();
            chartInit = false;
            mashUntil = -10;
            scrollRc = scrollTarget = 0;
            nextRc = 0;
            lastFlashSeq = s.EvSeq;
            seenSeq = s.EvSeq;
            // attaching mid-fight: seed the feed with the events that already happened
            for (int i = s.Events.Count - 1; i >= 0; i--)
            {
                rows.Add(new EvRow
                {
                    Name = s.Events[i][0],
                    Value = D(s.Events[i][1]),
                    BaseW = D(s.Events[i][3]),
                    Count = 1,
                    Born = nowClock - 1.0,
                    Rc = nextRc++
                });
            }
            scrollRc = scrollTarget = Math.Max(0, nextRc - LOG_ROWS);
        }
        if (s.Boss.Length == 0 && (rows.Count > 0 || hist.Count > 0))
        {
            // fight over: the feed and the curve belong to that fight, not to the menu
            rows.Clear(); evStamps.Clear(); scrollRc = scrollTarget = 0; nextRc = 0;
            hist.Clear(); chartInit = false; mashUntil = -10;
        }

        // empty-event fallback (a fight that ended without a boss change)
        if (s.Events.Count == 0)
        {
            if (emptySince < 0) emptySince = nowClock;
            else if (nowClock - emptySince > 0.5 && rows.Count > 0)
            {
                rows.Clear(); evStamps.Clear(); scrollRc = scrollTarget = 0; nextRc = 0;
            }
        }
        else emptySince = -1;

        // per-action feedback: newest event flashes, and the arrival rate feeds mash detection
        if (s.EvSeq != lastFlashSeq && s.Events.Count > 0)
        {
            lastFlashSeq = s.EvSeq;
            flashName = s.Events[0][0];
            flashValue = D(s.Events[0][1]);
            flashAt = nowClock;
            evStamps.Add(nowClock);
            double t = nowClock - 3.0;
            while (evStamps.Count > 0 && evStamps[0] < t) evStamps.RemoveAt(0);
            if (evStamps.Count >= 13) mashUntil = nowClock + 1.2;   // ~4.3 events/s over 3 s

            // one line per real event so the feed reacts immediately; only an immediate repeat
            // of the very same action is folded into the previous line as xN
            rows.Add(new EvRow
            {
                Name = s.Events[0][0],
                Value = D(s.Events[0][1]),
                BaseW = D(s.Events[0][3]),
                Count = 1,
                Born = nowClock,
                Rc = nextRc++
            });
            scrollTarget = Math.Max(0, nextRc - LOG_ROWS);
            while (rows.Count > LOG_ROWS + 2) rows.RemoveAt(0);
        }

        st = s;

        // chart history: smoothed score samples, ~10 Hz, 32 s sliding window
        if (hist.Count == 0 || nowClock - hist[hist.Count - 1].Key > 0.08)
        {
            chartSmooth = chartInit ? (chartSmooth * 0.62 + st.Raw * 0.38) : st.Raw;
            chartInit = true;
            hist.Add(new KeyValuePair<double, double>(nowClock, chartSmooth));
            while (hist.Count > 0 && hist[0].Key < nowClock - (CHART_SECONDS + 2)) hist.RemoveAt(0);
            if (nowClock - lastChartLog > 5)
            {
                lastChartLog = nowClock;
                Log(string.Format("chart n={0} span={1:F1} now={2:F1}", hist.Count,
                    hist.Count > 0 ? hist[hist.Count - 1].Key - hist[0].Key : 0, nowClock));
            }
        }
    }

    static double D(string v)
    {
        double d;
        if (double.TryParse(v, System.Globalization.NumberStyles.Any,
                System.Globalization.CultureInfo.InvariantCulture, out d)) return d;
        return 0;
    }

    string Signature()
    {
        var sb = new StringBuilder();
        sb.Append(st.Boss).Append('|').Append(st.Tier).Append('|').Append(st.Raw.ToString("F1")).Append('|')
          .Append(st.Delta.ToString("F1")).Append('|').Append(st.Peak.ToString("F1")).Append('|')
          .Append(st.PlayerHp.ToString("F1")).Append('|').Append(st.BossHp.ToString("F1")).Append('|').Append(st.Shachi.ToString("F3")).Append('|').Append(st.ShachiDps.ToString("F1")).Append('|')
          .Append(st.Preset).Append('|').Append(st.Page).Append('|').Append(st.Pages).Append('|');
        foreach (var d in st.Dims) sb.Append(d.Key).Append(':').Append(d.Value.ToString("F1")).Append(';');
        sb.Append('#').Append(rows.Count).Append('@').Append(scrollRc.ToString("F2")).Append('^').Append(st.EvSeq); if (st.Events.Count > 0) sb.Append(':').Append(st.Events[0][2]);
        foreach (var w in st.Weights) sb.Append(w[0]).Append(',').Append(w[1]).Append(';');
        return sb.ToString();
    }

    // ---------------- rendering ----------------
    void Render()
    {
        bool full = st.Preset == "full" && st.Weights.Count > 0;
        int panelH = full ? PANEL_H_FULL : PANEL_H_STD;
        int cw = (int)((PANEL_W + PAD * 2) * S);
        int ch = (int)((panelH + PAD * 2) * S);

        using (var bmp = new Bitmap(cw, ch, System.Drawing.Imaging.PixelFormat.Format32bppPArgb))
        {
            using (var g = Graphics.FromImage(bmp))
            {
                g.Clear(Color.Transparent);
                g.SmoothingMode = SmoothingMode.AntiAlias;
                g.TextRenderingHint = TextRenderingHint.AntiAliasGridFit;
                g.PixelOffsetMode = PixelOffsetMode.Half;
                g.CompositingQuality = CompositingQuality.HighQuality;
                g.PageUnit = GraphicsUnit.Pixel;
                g.ScaleTransform(S, S);
                g.TranslateTransform(PAD, PAD);
                PaintPanel(g, full, panelH);
            }
            PushLayered(bmp);
        }
    }

    void PushLayered(Bitmap bmp)
    {
        IntPtr screenDc = GetDC(IntPtr.Zero);
        IntPtr memDc = CreateCompatibleDC(screenDc);
        IntPtr hBitmap = bmp.GetHbitmap(Color.FromArgb(0));
        IntPtr old = SelectObject(memDc, hBitmap);
        try
        {
            SIZE size = new SIZE { cx = bmp.Width, cy = bmp.Height };
            POINT src = new POINT { X = 0, Y = 0 };
            POINT dst = new POINT { X = lastX == int.MinValue ? 100 : lastX, Y = lastY == int.MinValue ? 100 : lastY };
            BLENDFUNCTION blend = new BLENDFUNCTION
            { BlendOp = AC_SRC_OVER, BlendFlags = 0, SourceConstantAlpha = 255, AlphaFormat = AC_SRC_ALPHA };
            UpdateLayeredWindow(Handle, screenDc, ref dst, ref size, memDc, ref src, 0, ref blend, ULW_ALPHA);
        }
        finally
        {
            SelectObject(memDc, old);
            DeleteObject(hBitmap);
            DeleteDC(memDc);
            ReleaseDC(IntPtr.Zero, screenDc);
        }
    }

    // NOTE: fonts are created in DEVICE pixels (already multiplied by S) and text is drawn with
    // an identity transform. Drawing text under a scaled transform rasterises small glyphs first
    // and then upscales them, which is exactly what made small labels look blurry.
    // hero calligraphy face: shipped in bin/Fonts, loaded privately (no system install needed)
    static readonly PrivateFontCollection pfc = new PrivateFontCollection();
    static bool fontLoaded = false;
    static FontFamily heroFamily = null;

    static void LoadBundledFonts()
    {
        if (fontLoaded) return;
        fontLoaded = true;
        try
        {
            string dir = Path.Combine(Path.GetDirectoryName(System.Reflection.Assembly.GetExecutingAssembly().Location), "Fonts");
            if (!Directory.Exists(dir)) return;
            foreach (var file in Directory.GetFiles(dir, "*.ttf"))
            {
                var before = pfc.Families.Length;
                try { pfc.AddFontFile(file); } catch { }
                if (pfc.Families.Length > before && heroFamily == null)
                    heroFamily = pfc.Families[pfc.Families.Length - 1];
            }
            if (heroFamily != null) Log("hero font loaded: " + heroFamily.Name);
        }
        catch (Exception ex) { Log("font load failed: " + ex.Message); }
    }
    Font F(string family, float px, bool bold)
    {
        FontStyle stl = bold ? FontStyle.Bold : FontStyle.Regular;
        float size = px * S;
        if (family == "Hero")
        {
            if (heroFamily != null)
            {
                try { return new Font(heroFamily, size, FontStyle.Regular, GraphicsUnit.Pixel); }
                catch { }
            }
            family = "KaiTi";   // graceful fallback
        }
        foreach (var cand in new string[] { family, "Microsoft YaHei", "SimSun", "Arial" })
        {
            try { return new Font(cand, size, stl, GraphicsUnit.Pixel); }
            catch { }
        }
        return new Font(FontFamily.GenericSansSerif, size, stl, GraphicsUnit.Pixel);
    }

    void Txt(Graphics g, string s, Font f, Color c, float x, float y, float w, StringAlignment align)
    {
        var saved = g.Transform;
        g.ResetTransform();
        try
        {
            using (var sf = new StringFormat(StringFormat.GenericTypographic))
            {
                sf.Alignment = align;
                sf.LineAlignment = StringAlignment.Near;
                sf.FormatFlags = StringFormatFlags.NoWrap;
                sf.Trimming = StringTrimming.EllipsisCharacter;

                var rect = new RectangleF((x + PAD) * S, (y + PAD) * S, w * S, f.Height + 4);
                using (var br = new SolidBrush(Color.FromArgb(Math.Min(170, (int)c.A), 0, 0, 0)))
                {
                    g.DrawString(s, f, br, new RectangleF(rect.X + 0.8f, rect.Y + 0.8f, rect.Width, rect.Height), sf);
                    g.DrawString(s, f, br, new RectangleF(rect.X - 0.8f, rect.Y + 0.8f, rect.Width, rect.Height), sf);
                }
                using (var br = new SolidBrush(c))
                    g.DrawString(s, f, br, rect, sf);
            }
        }
        finally { g.Transform = saved; }
    }
    static GraphicsPath RoundRect(RectangleF r, float rad)
    {
        var p = new GraphicsPath();
        float d = Math.Max(0.5f, rad) * 2f;
        if (d > r.Width) d = r.Width;
        if (d > r.Height) d = r.Height;
        p.AddArc(r.X, r.Y, d, d, 180, 90);
        p.AddArc(r.Right - d, r.Y, d, d, 270, 90);
        p.AddArc(r.Right - d, r.Bottom - d, d, d, 0, 90);
        p.AddArc(r.X, r.Bottom - d, d, d, 90, 90);
        p.CloseFigure();
        return p;
    }

    void Divider(Graphics g, float y)
    {
        using (var pen = new Pen(C_GOLD_SOFT, 1f))
            g.DrawLine(pen, X0, y, X1, y);
    }

    void HpBar(Graphics g, float x, float y, float w, double pct, Color c)
    {
        using (var br = new SolidBrush(A(150, 0x20, 0x22, 0x26)))
            g.FillRectangle(br, x, y, w, 3);
        if (pct < 0) return;
        float f = (float)Math.Max(0.0, Math.Min(1.0, pct / 100.0));
        if (f <= 0.001f) return;
        using (var br = new SolidBrush(c))
            g.FillRectangle(br, x, y, w * f, 3);
    }

    void DrawChart(Graphics g, float x, float y, float w, float h)
    {
        using (var br = new SolidBrush(Color.FromArgb(170, 5, 6, 10)))
            g.FillRectangle(br, x, y, w, h);

        float mid = y + h / 2f;
        // tier bands (coarse): upper half warm, lower half cool
        using (var br = new SolidBrush(Color.FromArgb(9, 0xE8, 0x70, 0x5A)))
            g.FillRectangle(br, x, y, w, h / 2f);
        using (var br = new SolidBrush(Color.FromArgb(9, 0x8F, 0xC7, 0xB4)))
            g.FillRectangle(br, x, mid, w, h / 2f);

        using (var pen = new Pen(A(80, 0xC8, 0xB4, 0x78), 1f))
            g.DrawLine(pen, x, mid, x + w, mid);

        if (hist.Count >= 2)
        {
            double tEnd = nowClock, tStart = tEnd - CHART_SECONDS;
            var pts = new List<PointF>();
            foreach (var s in hist)
            {
                if (s.Key < tStart) continue;
                float px = x + (float)((s.Key - tStart) / CHART_SECONDS) * w;
                double v = Math.Max(-100, Math.Min(100, s.Value));
                float py = mid - (float)(v / 100.0) * (h / 2f - 3f);
                pts.Add(new PointF(px, py));
            }
            if (pts.Count >= 2)
            {
                var arr = pts.ToArray();
                // area fill
                var poly = new List<PointF>(arr);
                poly.Add(new PointF(arr[arr.Length - 1].X, mid));
                poly.Add(new PointF(arr[0].X, mid));
                using (var br = new SolidBrush(Color.FromArgb(26, TierColor(st.Tier))))
                    g.FillPolygon(br, poly.ToArray());
                using (var pen = new Pen(Color.FromArgb(240, 0xF2, 0xEA, 0xD8), 1.8f))
                {
                    pen.LineJoin = LineJoin.Round;
                    g.DrawLines(pen, arr);
                }
                var last = arr[arr.Length - 1];
                using (var br = new SolidBrush(C_TXT1))
                    g.FillEllipse(br, last.X - 2.5f, last.Y - 2.5f, 5f, 5f);
                using (var br = new SolidBrush(Color.FromArgb(150, TierColor(st.Tier))))
                    g.FillEllipse(br, last.X - 5f, last.Y - 5f, 10f, 10f);
            }
        }

        using (var pen = new Pen(A(45, 0xC8, 0xB4, 0x78), 1f))
            g.DrawRectangle(pen, x, y, w, h);

        var fLab = F("Consolas", 8, false);
        Txt(g, "+100", fLab, C_TXT4, x + w - 26, y + 1, 26, StringAlignment.Far);
        Txt(g, "−100", fLab, C_TXT4, x + w - 26, y + h - 10, 26, StringAlignment.Far);
        Txt(g, "30s", fLab, C_TXT4, x + 2, y + h - 10, 30, StringAlignment.Near);
        fLab.Dispose();
    }

    void PaintPanel(Graphics g, bool full, int panelH)
    {
        // ---- soft glow + gradient panel ----
        for (int i = 3; i >= 1; i--)
        {
            int a = i == 3 ? 5 : (i == 2 ? 10 : 18);
            using (var gp = RoundRect(new RectangleF(-i * 2, -i * 2, PANEL_W + i * 4, panelH + i * 4), 5 + i * 2))
            using (var pen = new Pen(Color.FromArgb(a, 0xC8, 0xB4, 0x78), 1f))
                g.DrawPath(pen, gp);
        }
        int aTop = Math.Min(235, (int)(panelAlpha * 1.18));
        int aBot = Math.Max(70, (int)(panelAlpha * 0.72));
        using (var p = RoundRect(new RectangleF(0, 0, PANEL_W, panelH), 5))
        {
            using (var br = new LinearGradientBrush(
                new RectangleF(0, 0, PANEL_W, panelH),
                Color.FromArgb(aTop, 0x0B, 0x0C, 0x0E),
                Color.FromArgb(aBot, 0x0B, 0x0C, 0x0E),
                LinearGradientMode.Vertical))
                g.FillPath(br, p);
            using (var pen = new Pen(Color.FromArgb(120, 0xC8, 0xB4, 0x78), 1f)) g.DrawPath(pen, p);
        }
        using (var p2 = RoundRect(new RectangleF(3, 3, PANEL_W - 6, panelH - 6), 4))
        using (var pen2 = new Pen(Color.FromArgb(48, 0xC8, 0xB4, 0x78), 1f))
            g.DrawPath(pen2, p2);
        using (var well = RoundRect(new RectangleF(8, 58, PANEL_W - 16, panelH - 78), 4))
        using (var br = new SolidBrush(Color.FromArgb((int)(panelAlpha * 0.52), 0x05, 0x06, 0x0A)))
            g.FillPath(br, well);

        // ---- title ----
        var fTitle = F("Hero", 17, false);
        Txt(g, "影之刃零", fTitle, C_TXT1, X0, TITLE_Y - 2, 90, StringAlignment.Near);
        fTitle.Dispose();
        var fTag = F("DengXian", 8, false);
        Txt(g, "· TENSION", fTag, C_GOLD_BRIGHT, X0 + 72, TITLE_Y + 3, 90, StringAlignment.Near);
        fTag.Dispose();
        using (var br = new SolidBrush(A(225, 0xC9, 0x45, 0x2F)))
            g.FillRectangle(br, X1 - 16, TITLE_Y - 1, 16, 16);
        var fStamp = F("KaiTi", 9, true);
        Txt(g, "调", fStamp, A(240, 0xF2, 0xEA, 0xD8), X1 - 16, TITLE_Y - 1, 16, StringAlignment.Center);
        fStamp.Dispose();

        // ---- boss + hp ----
        using (var br = new SolidBrush(A(235, 0xC9, 0x45, 0x2F)))
            g.FillRectangle(br, X0, BOSS_Y + 1, 13, 13);
        var fBS = F("KaiTi", 8, true);
        Txt(g, "敌", fBS, C_TXT1, X0, BOSS_Y + 1, 13, StringAlignment.Center);
        fBS.Dispose();
        string boss = st.Boss.Length > 0 ? st.Boss : "未检测到 Boss";
        var fBoss = HasCJK(boss) ? F("KaiTi", 13, false) : F("Consolas", 11, false);
        Txt(g, boss, fBoss, C_TXT2, X0 + 18, BOSS_Y, X1 - X0 - 18, StringAlignment.Near);
        fBoss.Dispose();

        if (st.PlayerHp >= 0 || st.BossHp > 0)
        {
            var fHp = F("Consolas", 7, false);
            if (st.PlayerHp >= 0)
            {
                HpBar(g, X0, HP_Y, 104, st.PlayerHp, A(235, 0x8F, 0xC7, 0xB4));
                Txt(g, st.PlayerHp.ToString("0.0") + "%", fHp, C_TXT3, X0 + 108, HP_Y - 3, 44, StringAlignment.Near);
            }
            if (st.BossHp > 0)
            {
                HpBar(g, X1 - 104, HP_Y, 104, st.BossHp, A(235, 0xE8, 0x70, 0x5A));
                Txt(g, st.BossHp.ToString("0.0") + "%", fHp, C_TXT3, X1 - 148, HP_Y - 3, 40, StringAlignment.Far);
            }
            fHp.Dispose();
        }

        Divider(g, DIV_A);

        // ---- tier block: narrow ink seal, big vertical state word, slim comment column ----
        Color accent = TierColor(st.Tier);
        float tbW = 78, tbH = 70;
        using (var p = RoundRect(new RectangleF(X0, SEAL_Y, tbW, tbH), 3))
        {
            using (var br = new SolidBrush(A(112, 0x08, 0x09, 0x0B))) g.FillPath(br, p);
            using (var pen = new Pen(Color.FromArgb(155, accent), 1f)) g.DrawPath(pen, p);
        }
        using (var pen = new Pen(A(42, 0xC8, 0xB4, 0x78), 1f))
            g.DrawLine(pen, X0 + 40, SEAL_Y + 9, X0 + 40, SEAL_Y + 55);

        string adj = TierAdj(st.Tier);
        var fBig = F("Hero", 26, false);
        Txt(g, adj.Substring(0, 1), fBig, Color.FromArgb(255, accent), X0 + 7, SEAL_Y + 4, 30, StringAlignment.Near);
        Txt(g, adj.Substring(1, 1), fBig, Color.FromArgb(255, accent), X0 + 7, SEAL_Y + 32, 30, StringAlignment.Near);
        fBig.Dispose();

        string poem = TierPoem(st.Tier);
        var fPoem = F("KaiTi", 11, false);
        for (int i = 0; i < 4 && i < poem.Length; i++)
        {
            Txt(g, poem.Substring(i, 1), fPoem, C_TXT4,
                X0 + 46, SEAL_Y + 6 + i * 11, 14, StringAlignment.Near);
        }
        fPoem.Dispose();

        for (int i = 0; i < 6; i++)
        {
            bool on = i <= st.Tier;
            using (var br = new SolidBrush(on ? Color.FromArgb(225, accent) : A(50, 0xC8, 0xB4, 0x78)))
                g.FillRectangle(br, X0 + 8 + i * 8, SEAL_Y + 60, 4, 3);
        }
        // ---- score ----
        float sx = X0 + tbW + 12;
        var fScore = F("Consolas", 34, true);
        string scoreTxt = (st.Raw >= 0 ? "+" : "−") + Math.Abs(st.Raw).ToString("0.0");
        Color scoreColor = st.Raw > 0 ? C_BAD_BIG : (st.Raw < 0 ? C_GOOD : C_TXT2);
        Txt(g, scoreTxt, fScore, scoreColor, sx, SCORE_Y, X1 - sx, StringAlignment.Far);
        fScore.Dispose();

        // ---- realtime curve ----
        DrawChart(g, sx, CHART_Y, X1 - sx, CHART_H);

        // ---- trend / peak (made prominent) ----
        var fTL = F("KaiTi", 13.5f, false);
        var fTN = F("Consolas", 13, true);
        Txt(g, "趋势", fTL, C_TXT2, X0, TREND_Y, 30, StringAlignment.Near);
        bool up = st.Delta > 0.05, down = st.Delta < -0.05;
        var fArrow = F("DengXian", 10, true);
        Txt(g, up ? "▲" : (down ? "▼" : "—"), fArrow, st.Delta > 0 ? C_BAD : (st.Delta < 0 ? C_GOOD : C_TXT3),
            X0 + 32, TREND_Y + 2, 12, StringAlignment.Near);
        fArrow.Dispose();
        string dTxt = (st.Delta >= 0 ? "+" : "−") + Math.Abs(st.Delta).ToString("0.0");
        Txt(g, dTxt, fTN, st.Delta > 0 ? C_BAD : (st.Delta < 0 ? C_GOOD : C_TXT3), X0 + 44, TREND_Y, 62, StringAlignment.Near);
        var fUnit = F("Consolas", 8, false);
        Txt(g, "/s", fUnit, C_TXT4, X0 + 106, TREND_Y + 2, 20, StringAlignment.Near);
        fUnit.Dispose();

        Txt(g, "峰值", fTL, C_GOLD, X1 - 84, TREND_Y, 30, StringAlignment.Near);
        string pTxt = (st.Peak >= 0 ? "+" : "−") + Math.Abs(st.Peak).ToString("0");
        Txt(g, pTxt, fTN, C_GOLD_BRIGHT, X1 - 48, TREND_Y, 48, StringAlignment.Far);
        fTN.Dispose(); fTL.Dispose();

        Divider(g, DIV_B);

        // ---- dimensions ----
        var fDim = F("KaiTi", 13, false);
        var fDimNum = F("Consolas", 10, false);
        float dy = DIM_Y;
        foreach (var d in st.Dims)
        {
            Txt(g, d.Key, fDim, C_TXT2, X0, dy, 40, StringAlignment.Near);
            float bx = X0 + 40, bw = X1 - X0 - 40 - 58;
            using (var path = RoundRect(new RectangleF(bx, dy + 5, bw, 4), 2))
            using (var br = new SolidBrush(A(200, 5, 6, 10)))
                g.FillPath(br, path);
            float frac = (float)Math.Min(1.0, Math.Abs(d.Value) / 200.0);
            if (frac > 0.01f)
            {
                Color dc = d.Value < 0 ? C_GOOD : C_BAD;
                float fw = bw * frac;
                float fx = bx + (bw - fw) / 2f;
                using (var br = new SolidBrush(Color.FromArgb(230, dc)))
                    g.FillRectangle(br, fx, dy + 5, fw, 4);
            }
            string val = (d.Value > 0 ? "+" : (d.Value < 0 ? "−" : "")) + Math.Abs(d.Value).ToString("0.0");
            Txt(g, val, fDimNum, C_TXT1, X1 - 54, dy + 1, 54, StringAlignment.Far);
            dy += DIM_ROW;
        }
        if (st.Dims.Count == 0)
        {
            var fWait = F("KaiTi", 11, false);
            Txt(g, "等待战斗数据…", fWait, C_TXT4, X0, DIM_Y + 2, 260, StringAlignment.Near);
            fWait.Dispose();
        }
        fDim.Dispose(); fDimNum.Dispose();

        Divider(g, DIV_C);

        // ---- event ticker header ----
        var fLog = F("DengXian", 8.5f, false);
        Txt(g, "战况 · EVENT LOG", fLog, A(200, 0xC8, 0xB4, 0x78), X0, LOG_HDR_Y, 160, StringAlignment.Near);
        Txt(g, Math.Min(rows.Count, LOG_ROWS) + " / " + LOG_ROWS, fLog, C_TXT4, X1 - 40, LOG_HDR_Y, 40, StringAlignment.Far);
        fLog.Dispose();

        if (nowClock < mashUntil)
        {
            double pulse = 0.55 + 0.45 * Math.Sin(nowClock * 9.0);
            var rect = new RectangleF(150, LOG_HDR_Y - 2, 46, 13);
            using (var path = RoundRect(rect, 3))
            using (var br = new SolidBrush(Color.FromArgb((int)(180 + 60 * pulse), 0xC9, 0x45, 0x2F)))
                g.FillPath(br, path);
            var fMash = F("KaiTi", 9, true);
            Txt(g, "乱按", fMash, Color.FromArgb(255, 0xF2, 0xEA, 0xD8), rect.X, rect.Y + 1, rect.Width, StringAlignment.Center);
            fMash.Dispose();
            var fPen = F("Consolas", 7, false);
            Txt(g, "+10", fPen, Color.FromArgb((int)(200 + 55 * pulse), 0xF4, 0x86, 0x6B), 200, LOG_HDR_Y, 30, StringAlignment.Near);
            fPen.Dispose();
        }

        // ---- scrolling ticker ----
        var area = new RectangleF(X0 - 4, LOG_TOP - 2, (X1 - X0) + 8, LOG_ROWS * LOG_ROW + 4);
        var oldClip = g.Clip;
        g.SetClip(area);

        var fName = F("KaiTi", 14, false);
        var fNameB = F("KaiTi", 14, true);
        var fVal = F("Consolas", 11, false);
        var fValB = F("Consolas", 11, true);
        var fCnt = F("Consolas", 9, false);

        for (int i = 0; i < rows.Count; i++)
        {
            float y = area.Y + 2 + (float)((rows[i].Rc - scrollRc) * LOG_ROW);
            if (y < area.Y - LOG_ROW || y > area.Bottom) continue;

            float a = Math.Min(1f, Math.Max(0f, (y - area.Y + LOG_ROW) / (LOG_ROW * 1.2f)));
            double age = nowClock - rows[i].Born;
            float slide = 0f;
            if (age < 0.16) { a *= (float)(age / 0.16); slide = (float)((1.0 - age / 0.16) * 3.0); }
            int alpha = (int)(255 * a);
            if (alpha < 8) continue;

            var row = rows[i];
            bool newest = (i == rows.Count - 1);
            Color sc = row.Value < 0 ? C_GOOD : (row.Value > 0 ? C_BAD : C_TXT3);
            y += slide;

            if (newest)
            {
                using (var br = new SolidBrush(A((int)(alpha * 0.28), 0, 0, 0)))
                    g.FillRectangle(br, area.X, y - 2, area.Width, LOG_ROW - 3);
                using (var br = new SolidBrush(Color.FromArgb(alpha, sc)))
                    g.FillRectangle(br, area.X, y + 1, 2.5f, LOG_ROW - 7);
            }

            string vt = (row.Value > 0 ? "+" : (row.Value < 0 ? "-" : "")) + Math.Abs(row.Value).ToString("0");
            Txt(g, vt, newest ? fValB : fVal, Color.FromArgb(alpha, sc), area.X + 8, y + 2, 42, StringAlignment.Near);

            Txt(g, row.Name, newest ? fNameB : fName,
                Color.FromArgb((int)(alpha * (newest ? 1.0 : 0.88)), 0xF2, 0xEA, 0xD8),
                area.X + 56, y, 150, StringAlignment.Near);

            if (row.BaseW != 0)
            {
                string bt = (row.BaseW > 0 ? "+" : "-") + Math.Abs(row.BaseW).ToString("0");
                Txt(g, "基础" + bt, fCnt, Color.FromArgb((int)(alpha * 0.62), 0xC8, 0xB4, 0x78),
                    area.Right - 78, y + 4, 74, StringAlignment.Far);
            }
        }
        g.Clip = oldClip;
        fName.Dispose(); fNameB.Dispose(); fVal.Dispose(); fValB.Dispose(); fCnt.Dispose();

        if (rows.Count == 0)
        {
            var fNone = F("KaiTi", 11, false);
            Txt(g, "等待战斗事件…", fNone, C_TXT4, X0, LOG_TOP + 2, 260, StringAlignment.Near);
            fNone.Dispose();
        }

        // ---- weights (full preset) ----
        if (full)
        {
            Divider(g, PANEL_H_STD - 2);
            var fW = F("DengXian", 7.5f, false);
            Txt(g, "基础权重 · WEIGHTS", fW, A(190, 0xC8, 0xB4, 0x78), X0, PANEL_H_STD + 6, 200, StringAlignment.Near);
            Txt(g, st.Page + " / " + Math.Max(1, st.Pages), fW, C_TXT4, X1 - 40, PANEL_H_STD + 6, 40, StringAlignment.Far);
            fW.Dispose();

            var fWn = F("KaiTi", 12, false);
            var fWv = F("Consolas", 10, false);
            float colW = (X1 - X0) / 2f;
            for (int i = 0; i < st.Weights.Count; i++)
            {
                int col = i / 3, row = i % 3;
                float x = X0 + col * colW;
                float y = PANEL_H_STD + 22 + row * 15;
                double wv = D(st.Weights[i][1]);
                Txt(g, st.Weights[i][0], fWn, C_TXT2, x, y, colW - 34, StringAlignment.Near);
                string vt = (wv > 0 ? "+" : (wv < 0 ? "−" : "")) + Math.Abs(wv).ToString("0");
                Txt(g, vt, fWv, wv < 0 ? C_GOOD : C_BAD, x + colW - 40, y, 36, StringAlignment.Far);
            }
            fWn.Dispose(); fWv.Dispose();
        }

        // ---- footer ----
        var fFoot = F("DengXian", 8.5f, false);
        Txt(g, "F7 显隐 · F8 预设 · F9 翻页", fFoot, C_TXT4, X0, panelH - 16, 220, StringAlignment.Near);
        Txt(g, st.Preset + "  " + st.Page + "/" + st.Pages, fFoot, C_TXT4, X1 - 100, panelH - 16, 100, StringAlignment.Far);
        fFoot.Dispose();
    }
    static bool HasCJK(string s)
    {
        foreach (char c in s) if (c >= 0x4E00 && c <= 0x9FFF) return true;
        return false;
    }

    [STAThread]
    static void Main(string[] args)
    {
        bool created = false;
        Mutex mutex = null;
        try
        {
            mutex = new Mutex(true, "Global\\PBZTensionHUD_overlay_v1", out created);
            if (!created)
            {
                Log("another overlay instance is already running; exiting");
                return;
            }
            AppDomain.CurrentDomain.UnhandledException += delegate (object s, UnhandledExceptionEventArgs e)
            { Log("UNHANDLED: " + e.ExceptionObject); };
            Application.ThreadException += delegate (object s, System.Threading.ThreadExceptionEventArgs e)
            { Log("THREAD EX: " + e.Exception); };
            Application.SetUnhandledExceptionMode(UnhandledExceptionMode.CatchException);

            try { SetProcessDpiAwareness(2); } catch { try { SetProcessDPIAware(); } catch { } }
            LoadBundledFonts();
            string path = args.Length > 0 ? args[0] : Path.Combine(Path.GetTempPath(), "PBZTensionHUD", "state.txt");
            Directory.CreateDirectory(Path.GetDirectoryName(path));
            Log("start v1.0.0, state=" + path);
            Application.EnableVisualStyles();
            var f = new TensionOverlay(path);
            Application.Run(f);
            Log("exited");
        }
        catch (Exception ex) { Log("FATAL: " + ex); }
        finally
        {
            if (mutex != null)
            {
                try { if (created) mutex.ReleaseMutex(); } catch { }
                mutex.Dispose();
            }
        }
    }
}

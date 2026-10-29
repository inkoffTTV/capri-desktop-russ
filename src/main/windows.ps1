# Watches the top-level windows so Capri can sit on them.
# Prints one JSON line whenever something changes: the foreground window and the visible
# windows in z-order (front first), as physical-pixel frame bounds. No contents, and no titles:
# the title of the window in front is only checked against a short list of AI names (ChatGPT,
# Gemini...) for her jealousy, and all that goes out is which of them matched ("ai").
#
#   powershell -File windows.ps1 <capri hwnd> <capri pid>

param([long]$Self = 0, [int]$ParentPid = 0)
$ErrorActionPreference = 'Stop'

Add-Type -ReferencedAssemblies System.Management -TypeDefinition @"
using System;
using System.Collections.Generic;
using System.Management;
using System.Runtime.InteropServices;
using System.Text;
using System.Text.RegularExpressions;

public static class CapriWindows {
  delegate bool EnumProc(IntPtr hwnd, IntPtr lParam);

  [StructLayout(LayoutKind.Sequential)]
  public struct RECT { public int Left, Top, Right, Bottom; }

  [DllImport("user32.dll")] static extern bool EnumWindows(EnumProc cb, IntPtr lParam);
  [DllImport("user32.dll")] static extern bool IsWindowVisible(IntPtr hwnd);
  [DllImport("user32.dll")] static extern bool IsIconic(IntPtr hwnd);
  [DllImport("user32.dll")] static extern bool IsZoomed(IntPtr hwnd);
  [DllImport("user32.dll")] static extern IntPtr GetForegroundWindow();
  [DllImport("user32.dll")] static extern int GetWindowLong(IntPtr hwnd, int index);
  [DllImport("user32.dll")] static extern int GetClassName(IntPtr hwnd, StringBuilder name, int max);
  [DllImport("user32.dll", CharSet = CharSet.Unicode)] static extern int GetWindowText(IntPtr hwnd, StringBuilder text, int max);
  [DllImport("user32.dll")] static extern uint GetWindowThreadProcessId(IntPtr hwnd, out uint pid);
  [DllImport("kernel32.dll")] static extern IntPtr OpenProcess(uint access, bool inherit, uint pid);
  [DllImport("kernel32.dll", CharSet = CharSet.Unicode)] static extern bool QueryFullProcessImageName(IntPtr process, int flags, StringBuilder name, ref int size);
  [DllImport("kernel32.dll")] static extern bool CloseHandle(IntPtr handle);
  [DllImport("user32.dll")] static extern bool SetProcessDpiAwarenessContext(IntPtr value);
  [DllImport("dwmapi.dll")] static extern int DwmGetWindowAttribute(IntPtr hwnd, int attr, out RECT value, int size);
  [DllImport("dwmapi.dll")] static extern int DwmGetWindowAttribute(IntPtr hwnd, int attr, out int value, int size);

  const int GWL_EXSTYLE = -20;
  const int WS_EX_TOOLWINDOW = 0x80;
  const int WS_EX_NOACTIVATE = 0x08000000;
  const int DWMWA_EXTENDED_FRAME_BOUNDS = 9;
  const int DWMWA_CLOAKED = 14;

  // Other AIs: a key, what gives them away in the title of the window in front, and the name of
  // their own app's program, if they have one.
  static readonly string[][] AIS = {
    new[] { "chatgpt", @"\bChatGPT\b", "chatgpt" },
    new[] { "claude", @"\bClaude\b", "claude" },
    new[] { "codex", @"\bCodex\b", "codex" },
    new[] { "gemini", @"\bGemini\b", "" },
    new[] { "copilot", @"\bCopilot\b", "copilot" },
    new[] { "perplexity", @"\bPerplexity\b", "perplexity" },
    new[] { "deepseek", @"\bDeepSeek\b", "" },
    new[] { "grok", @"\bGrok\b", "" },
    new[] { "lechat", @"\bLe Chat\b|\bMistral AI\b", "" },
    new[] { "characterai", @"character\.ai", "" },
    new[] { "metaai", @"\bMeta AI\b", "" },
  };
  static IntPtr procOf = IntPtr.Zero;
  static string proc = "";
  static string game = "";

  // A game: its program sits in a launcher's library (Steam, Epic, Riot, Xbox, GOG). The game is the
  // name of its folder there (the launchers themselves aren't games).
  static readonly Regex GAME = new Regex(@"\\(?:steamapps\\common|Epic Games|Riot Games|XboxGames|GOG Galaxy\\Games)\\([^\\]+)\\", RegexOptions.IgnoreCase);
  static readonly Regex NOT_GAME = new Regex(@"launcher|client|redistributable|steamworks", RegexOptions.IgnoreCase);

  // The program behind the window in front, when it changes: its name, and the game it is, if one.
  static void Program(IntPtr fg) {
    if (fg == procOf) return;
    procOf = fg;
    proc = "";
    game = "";
    uint pid;
    GetWindowThreadProcessId(fg, out pid);
    try { proc = System.Diagnostics.Process.GetProcessById((int)pid).ProcessName.ToLowerInvariant(); } catch {}
    IntPtr h = OpenProcess(0x1000, false, pid); // PROCESS_QUERY_LIMITED_INFORMATION
    if (h == IntPtr.Zero) return;
    var path = new StringBuilder(1024);
    int size = path.Capacity;
    if (QueryFullProcessImageName(h, 0, path, ref size)) {
      var m = GAME.Match(path.ToString());
      if (m.Success && !NOT_GAME.IsMatch(m.Groups[1].Value)) game = m.Groups[1].Value;
    }
    CloseHandle(h);
  }

  static string Json(string s) {
    return "\"" + s.Replace("\\", "\\\\").Replace("\"", "\\\"") + "\"";
  }

  // USB sticks (and SD cards) plugged in, by drive letter, looked at every couple of seconds.
  static string usb = "[]";
  static DateTime usbAt = DateTime.MinValue;
  static string Usb() {
    if ((DateTime.Now - usbAt).TotalMilliseconds < 2000) return usb;
    usbAt = DateTime.Now;
    var letters = new StringBuilder();
    try {
      foreach (var d in System.IO.DriveInfo.GetDrives()) {
        if (d.DriveType != System.IO.DriveType.Removable || !d.IsReady) continue;
        if (letters.Length > 0) letters.Append(',');
        letters.Append(Json(d.Name.Substring(0, 1)));
      }
    } catch {}
    usb = "[" + letters.ToString() + "]";
    return usb;
  }

  // Which of them the window in front is, as a JSON list of keys.
  static string Ai(IntPtr fg) {
    var title = new StringBuilder(512);
    GetWindowText(fg, title, 512);
    Program(fg);
    string t = title.ToString();
    var keys = new StringBuilder();
    foreach (var ai in AIS) {
      if (!Regex.IsMatch(t, ai[1], RegexOptions.IgnoreCase) && (ai[2] == "" || proc != ai[2])) continue;
      if (keys.Length > 0) keys.Append(',');
      keys.Append('"').Append(ai[0]).Append('"');
    }
    return "[" + keys.ToString() + "]";
  }

  public static void Init() {
    SetProcessDpiAwarenessContext(new IntPtr(-4)); // per-monitor v2: real pixels everywhere
    try { WatchDevices(); } catch {}
  }

  // Devices plugged in or out (a phone, a controller, a headset...). Windows says something
  // changed; we list the devices again and see what's new or gone.
  static Dictionary<string, string[]> devices;
  static int plugs = 0;
  static string plug = "null";
  static readonly object gate = new object();

  static Dictionary<string, string[]> Devices() {
    var all = new Dictionary<string, string[]>();
    using (var q = new ManagementObjectSearcher("SELECT DeviceID, Name, PNPClass FROM Win32_PnPEntity")) {
      foreach (ManagementBaseObject d in q.Get()) {
        var id = d["DeviceID"] as string;
        if (id != null) all[id] = new[] { (d["Name"] as string) ?? "", (d["PNPClass"] as string) ?? "" };
      }
    }
    return all;
  }

  static void WatchDevices() {
    devices = Devices();
    var watcher = new ManagementEventWatcher(new WqlEventQuery("SELECT * FROM Win32_DeviceChangeEvent WHERE EventType = 2 OR EventType = 3"));
    watcher.EventArrived += (s, e) => {
      try { Changed(); } catch {} // never take the whole helper down over a device
    };
    watcher.Start();
  }

  static void Changed() {
    System.Threading.Thread.Sleep(1200); // a phone shows up as several devices, one after the other
    lock (gate) {
      var now = Devices();
      var added = new List<string[]>();
      var removed = new List<string[]>();
      foreach (var d in now) if (!devices.ContainsKey(d.Key)) added.Add(d.Value);
      foreach (var d in devices) if (!now.ContainsKey(d.Key)) removed.Add(d.Value);
      devices = now;
      bool plugged = added.Count > 0;
      var best = Best(plugged ? added : removed);
      if (best == null) return;
      plugs++;
      plug = "{\"n\":" + plugs + ",\"in\":" + (plugged ? "true" : "false") + ",\"name\":" + Json(best[0]) + ",\"class\":" + Json(best[1]) + "}";
    }
  }

  // The device that says the most about what was plugged: "Galaxy S21" rather than "USB Composite Device".
  static readonly Regex VAGUE = new Regex(@"composite|hub|concentrateur|input device|hid|mass storage|stockage|g.n.ri|virtu|num.rat|interface|host|h.te|bus|port|endpoint|service|profil|protocol|p.riph.rique|dispositivo", RegexOptions.IgnoreCase); // ASCII only: PowerShell reads this file as ANSI
  public static string[] Best(List<string[]> list) {
    string[] best = null;
    int top = int.MinValue;
    foreach (var d in list) {
      if (d[0] == "") continue;
      int score = d[1] == "WPD" ? 6 : d[1] == "AudioEndpoint" ? 5 : d[1] == "Camera" || d[1] == "Image" ? 4 : d[1] == "HIDClass" || d[1] == "Keyboard" || d[1] == "Mouse" ? 3 : d[1] == "Bluetooth" ? 2 : 1;
      if (VAGUE.IsMatch(d[0])) score -= 4;
      if (score > top) { top = score; best = d; }
    }
    return best;
  }

  public static string Snapshot(long self) {
    var sb = new StringBuilder();
    IntPtr fg = GetForegroundWindow();
    var fgClass = new StringBuilder(64);
    GetClassName(fg, fgClass, 64);
    // the taskbar clicked: it comes up over her (Windows has no levels among windows on top)
    bool taskbar = fgClass.ToString() == "Shell_TrayWnd" || fgClass.ToString() == "Shell_SecondaryTrayWnd";
    sb.Append("{\"fg\":").Append(fg.ToInt64()).Append(",\"taskbar\":").Append(taskbar ? "true" : "false")
      .Append(",\"ai\":").Append(Ai(fg))
      .Append(",\"game\":").Append(game == "" ? "null" : Json(game))
      .Append(",\"usb\":").Append(Usb());
    lock (gate) sb.Append(",\"plug\":").Append(plug);
    sb.Append(",\"wins\":[");
    int count = 0;
    EnumWindows((h, l) => {
      if (count >= 40) return false;
      if (h.ToInt64() == self || !IsWindowVisible(h) || IsIconic(h)) return true;
      int ex = GetWindowLong(h, GWL_EXSTYLE);
      if ((ex & WS_EX_TOOLWINDOW) != 0 || (ex & WS_EX_NOACTIVATE) != 0) return true;
      int cloaked;
      if (DwmGetWindowAttribute(h, DWMWA_CLOAKED, out cloaked, 4) == 0 && cloaked != 0) return true;
      var cls = new StringBuilder(64);
      GetClassName(h, cls, 64);
      string c = cls.ToString();
      if (c == "Progman" || c == "WorkerW" || c == "Shell_TrayWnd" || c == "Shell_SecondaryTrayWnd") return true;
      RECT r;
      if (DwmGetWindowAttribute(h, DWMWA_EXTENDED_FRAME_BOUNDS, out r, 16) != 0) return true;
      if (r.Right - r.Left < 200 || r.Bottom - r.Top < 120) return true;
      if (count > 0) sb.Append(',');
      count++;
      sb.Append("{\"id\":").Append(h.ToInt64())
        .Append(",\"x\":").Append(r.Left).Append(",\"y\":").Append(r.Top)
        .Append(",\"w\":").Append(r.Right - r.Left).Append(",\"h\":").Append(r.Bottom - r.Top)
        .Append(",\"max\":").Append(IsZoomed(h) ? "true" : "false").Append('}');
      return true;
    }, IntPtr.Zero);
    sb.Append("]}");
    return sb.ToString();
  }
}
"@

[CapriWindows]::Init()
$last = ''
$tick = 0
while ($true) {
  $snap = [CapriWindows]::Snapshot($Self)
  if ($snap -ne $last) {
    [Console]::Out.WriteLine($snap)
    [Console]::Out.Flush()
    $last = $snap
  }
  # stop with Capri, even if she crashed without telling us
  $tick++
  if ($ParentPid -and ($tick % 20 -eq 0) -and -not (Get-Process -Id $ParentPid -ErrorAction SilentlyContinue)) { break }
  Start-Sleep -Milliseconds 150
}

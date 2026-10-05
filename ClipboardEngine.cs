using System;
using System.IO;
using System.Linq;
using System.Text;
using System.Text.RegularExpressions;
using System.Runtime.InteropServices;
using System.Drawing;
using System.Drawing.Imaging;
using System.Windows.Forms;

namespace CodexClipboard
{
    public static class Native
    {
        [DllImport("user32.dll")] private static extern uint GetClipboardSequenceNumber();
        [DllImport("user32.dll", SetLastError = true)] private static extern bool OpenClipboard(IntPtr hwnd);
        [DllImport("user32.dll")] private static extern bool CloseClipboard();
        [DllImport("user32.dll", SetLastError = true)] private static extern bool EmptyClipboard();
        [DllImport("user32.dll", SetLastError = true)] private static extern IntPtr SetClipboardData(uint format, IntPtr memory);
        [DllImport("kernel32.dll", SetLastError = true)] private static extern IntPtr GlobalAlloc(uint flags, UIntPtr bytes);
        [DllImport("kernel32.dll")] private static extern IntPtr GlobalLock(IntPtr memory);
        [DllImport("kernel32.dll")] private static extern bool GlobalUnlock(IntPtr memory);
        [DllImport("kernel32.dll")] private static extern IntPtr GlobalFree(IntPtr memory);
        public static uint Sequence { get { return GetClipboardSequenceNumber(); } }

        private sealed class OwnerWindow : NativeWindow, IDisposable
        {
            public OwnerWindow() { CreateHandle(new CreateParams()); }
            public void Dispose() { DestroyHandle(); }
        }

        // Verify the image's version while holding the clipboard lock: newer copies win.
        public static bool ReplaceText(uint expected, string text)
        {
            byte[] bytes = Encoding.Unicode.GetBytes(text + "\0");
            IntPtr memory = GlobalAlloc(2, new UIntPtr((uint)bytes.Length));
            if (memory == IntPtr.Zero) throw new OutOfMemoryException("Clipboard text allocation failed.");
            bool opened = false;
            try
            {
                IntPtr pointer = GlobalLock(memory);
                if (pointer == IntPtr.Zero) throw new System.ComponentModel.Win32Exception(Marshal.GetLastWin32Error());
                try { Marshal.Copy(bytes, 0, pointer, bytes.Length); }
                finally { GlobalUnlock(memory); }
                using (OwnerWindow owner = new OwnerWindow())
                {
                    if (!OpenClipboard(owner.Handle)) throw new System.Runtime.InteropServices.ExternalException("Clipboard is busy.");
                    opened = true;
                    if (Sequence != expected) return false;
                    if (!EmptyClipboard()) throw new System.ComponentModel.Win32Exception(Marshal.GetLastWin32Error());
                    if (SetClipboardData(13, memory) == IntPtr.Zero)
                        throw new System.ComponentModel.Win32Exception(Marshal.GetLastWin32Error());
                    memory = IntPtr.Zero; // Clipboard owns the allocation after success.
                    CloseClipboard();
                    opened = false;
                    return true;
                }
            }
            finally
            {
                if (opened) CloseClipboard();
                if (memory != IntPtr.Zero) GlobalFree(memory);
            }
        }
    }


    public sealed class HotkeyTrigger : NativeWindow, IDisposable
    {
        private const int HotkeyId = 19537;
        private readonly System.Collections.Generic.Queue<uint> requests =
            new System.Collections.Generic.Queue<uint>();
        private bool registered;

        [DllImport("user32.dll", SetLastError = true)]
        private static extern bool RegisterHotKey(IntPtr hwnd, int id, uint modifiers, uint key);
        [DllImport("user32.dll")]
        private static extern bool UnregisterHotKey(IntPtr hwnd, int id);

        public HotkeyTrigger() : this("Ctrl+Q") { }

        public HotkeyTrigger(string chord)
        {
            string[] parts = chord.Split('+');
            uint modifiers = 0x4000;
            for (int i = 0; i < parts.Length - 1; i++)
            {
                switch (parts[i].Trim().ToUpperInvariant())
                {
                    case "CTRL": modifiers |= 0x0002; break;
                    case "ALT": modifiers |= 0x0001; break;
                    case "SHIFT": modifiers |= 0x0004; break;
                    case "WIN": modifiers |= 0x0008; break;
                    default: throw new ArgumentException("Unknown hotkey modifier.", "chord");
                }
            }
            string key = parts[parts.Length - 1].Trim().ToUpperInvariant();
            if ((modifiers & 0x0002) == 0 || key.Length != 1 ||
                !((key[0] >= 'A' && key[0] <= 'Z') || (key[0] >= '0' && key[0] <= '9')))
                throw new ArgumentException("Use Ctrl plus a letter/digit, optionally Alt, Shift or Win.", "chord");
            CreateHandle(new CreateParams { Caption = "CodexClipboardHotkey", Parent = new IntPtr(-3) });
            if (!RegisterHotKey(Handle, HotkeyId, modifiers, key[0]))
            {
                int error = Marshal.GetLastWin32Error();
                DestroyHandle();
                throw new System.ComponentModel.Win32Exception(error,
                    "Cannot register hotkey. Another application may already be using this hotkey.");
            }
            registered = true;
        }

        protected override void WndProc(ref Message message)
        {
            if (message.Msg == 0x0312 && message.WParam.ToInt32() == HotkeyId)
            {
                if (requests.Count < 16) requests.Enqueue(Native.Sequence);
                return;
            }
            base.WndProc(ref message);
        }

        // The STA watcher pumps the message queue so real Windows hotkeys are delivered.
        public long TakeRequest()
        {
            Application.DoEvents();
            return requests.Count == 0 ? -1L : (long)requests.Dequeue();
        }

        public void Dispose()
        {
            if (registered) { UnregisterHotKey(Handle, HotkeyId); registered = false; }
            if (Handle != IntPtr.Zero) DestroyHandle();
        }
    }

    public sealed class CaptureResult
    {
        public string SavedPath { get; set; }
        public bool ClipboardReplaced { get; set; }
        public int RemainingFiles { get; set; }
        public string PublicationError { get; set; }
    }

    public static class Engine
    {
        private static readonly Regex GeneratedName = new Regex(
            @"^codex-shot-[0-9]{19}-[0-9a-f]{32}\.png$", RegexOptions.CultureInvariant);
        public static string LastCleanupError { get; private set; }

        public static CaptureResult Capture(string directory, int retainCount, uint expectedSequence)
        {
            if (retainCount < 1) throw new ArgumentOutOfRangeException("retainCount");
            if (Native.Sequence != expectedSequence || !Clipboard.ContainsImage()) return null;
            using (Image image = Clipboard.GetImage())
            {
                if (image == null || Native.Sequence != expectedSequence) return null;
                string fullDirectory = Path.GetFullPath(directory);
                Directory.CreateDirectory(fullDirectory);
                long order = DateTime.UtcNow.Ticks;
                foreach (FileInfo existing in GeneratedFiles(fullDirectory))
                {
                    long previous;
                    if (long.TryParse(existing.Name.Substring(11, 19), out previous) && previous >= order)
                    {
                        if (previous == long.MaxValue) throw new IOException("Screenshot ordering counter exhausted.");
                        order = previous + 1;
                    }
                }
                string name = "codex-shot-" + order.ToString("D19",
                    System.Globalization.CultureInfo.InvariantCulture) + "-" + Guid.NewGuid().ToString("N") + ".png";
                string path = Path.Combine(fullDirectory, name);
                string temporary = path + ".partial";
                try
                {
                    image.Save(temporary, ImageFormat.Png);
                    File.Move(temporary, path);
                }
                finally
                {
                    if (File.Exists(temporary)) File.Delete(temporary);
                }
                // Cleanup still runs if the user copied new content during file saving.
                bool replaced = false;
                string publicationError = null;
                try { replaced = Native.ReplaceText(expectedSequence, path); }
                catch (Exception e) { publicationError = e.Message; }
                finally { Cleanup(fullDirectory, retainCount); }
                return new CaptureResult { SavedPath = path, ClipboardReplaced = replaced,
                    PublicationError = publicationError, RemainingFiles = GeneratedFiles(fullDirectory).Length };
            }
        }

        private static FileInfo[] GeneratedFiles(string directory)
        {
            string fullDirectory = Path.GetFullPath(directory);
            if (!Directory.Exists(fullDirectory)) return new FileInfo[0];
            return new DirectoryInfo(fullDirectory).GetFiles("codex-shot-*.png", SearchOption.TopDirectoryOnly)
                .Where(f => GeneratedName.IsMatch(f.Name) && (f.Attributes & FileAttributes.ReparsePoint) == 0)
                .OrderBy(f => f.Name, StringComparer.Ordinal).ToArray();
        }

        public static int Cleanup(string directory, int retainCount)
        {
            if (retainCount < 1) throw new ArgumentOutOfRangeException("retainCount");
            LastCleanupError = null;
            string fullDirectory = Path.GetFullPath(directory).TrimEnd(Path.DirectorySeparatorChar, Path.AltDirectorySeparatorChar);
            FileInfo[] files = GeneratedFiles(fullDirectory);
            int excess = Math.Max(0, files.Length - retainCount);
            // Delete only the stale range; a locked oldest file never sacrifices a newer one.
            foreach (FileInfo file in files.Take(excess))
            {
                if (!String.Equals(file.DirectoryName.TrimEnd(Path.DirectorySeparatorChar, Path.AltDirectorySeparatorChar),
                    fullDirectory, StringComparison.OrdinalIgnoreCase))
                    throw new InvalidOperationException("Retention target escaped the screenshot directory.");
                try { file.Delete(); }
                catch (IOException e) { LastCleanupError = e.Message; }
                catch (UnauthorizedAccessException e) { LastCleanupError = e.Message; }
            }
            return GeneratedFiles(fullDirectory).Length;
        }
    }
}

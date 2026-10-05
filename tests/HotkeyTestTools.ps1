if (-not ('CodexClipboardTest.Keyboard' -as [type])) {
    Add-Type -TypeDefinition 'using System; using System.Runtime.InteropServices; namespace CodexClipboardTest { public static class Keyboard {
    [DllImport("user32.dll")] private static extern void keybd_event(byte key,byte scan,uint flags,UIntPtr extra);
    [DllImport("user32.dll",SetLastError=true)] public static extern bool RegisterHotKey(IntPtr window,int id,uint modifiers,uint key);
    [DllImport("user32.dll")] public static extern bool UnregisterHotKey(IntPtr window,int id);

    public static void PressCtrlAltQ() {
        keybd_event(17,0,0,UIntPtr.Zero); keybd_event(18,0,0,UIntPtr.Zero);
        keybd_event(81,0,0,UIntPtr.Zero); keybd_event(81,0,2,UIntPtr.Zero);
        keybd_event(18,0,2,UIntPtr.Zero); keybd_event(17,0,2,UIntPtr.Zero);
    }
    public static void PressCtrlQ() {
        keybd_event(17,0,0,UIntPtr.Zero); keybd_event(81,0,0,UIntPtr.Zero);
        keybd_event(81,0,2,UIntPtr.Zero); keybd_event(17,0,2,UIntPtr.Zero);
    } } }'
}
function Send-TestCtrlQ { [CodexClipboardTest.Keyboard]::PressCtrlQ() }

function Send-TestConversionHotkey {
    [CodexClipboardTest.Keyboard]::PressCtrlAltQ()
}

using System;
using System.Runtime.InteropServices;
using System.Text;

public static class TrayLumaBenchmarkNative
{
    private delegate bool EnumProc(IntPtr window, IntPtr data);
    [DllImport("user32.dll")] private static extern bool EnumWindows(EnumProc callback, IntPtr data);
    [DllImport("user32.dll")] private static extern uint GetWindowThreadProcessId(IntPtr window, out uint processId);
    [DllImport("user32.dll", CharSet = CharSet.Unicode)] private static extern int GetClassName(IntPtr window, StringBuilder text, int count);
    [DllImport("user32.dll", SetLastError = true)] private static extern IntPtr SendMessageTimeout(IntPtr window, uint message, UIntPtr wParam, IntPtr lParam, uint flags, uint timeout, out UIntPtr result);
    [DllImport("user32.dll")] public static extern uint GetGuiResources(IntPtr process, uint flags);

    public static IntPtr Find(int processId)
    {
        IntPtr found = IntPtr.Zero;
        EnumWindows(delegate(IntPtr window, IntPtr unused) {
            uint id;
            GetWindowThreadProcessId(window, out id);
            if (id != processId) return true;
            var name = new StringBuilder(128);
            GetClassName(window, name, name.Capacity);
            if (name.ToString() != "TrayLuma.Benchmark") return true;
            found = window;
            return false;
        }, IntPtr.Zero);
        return found;
    }

    public static uint Command(IntPtr window, uint command)
    {
        UIntPtr result;
        if (SendMessageTimeout(window, 0x8006, new UIntPtr(command), IntPtr.Zero, 2, 2000, out result) == IntPtr.Zero)
            throw new InvalidOperationException("Benchmark window stopped responding.");
        return (uint)result.ToUInt64();
    }
}

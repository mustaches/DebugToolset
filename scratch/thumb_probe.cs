using System;
using System.Runtime.InteropServices;

class ThumbProbe {
    [ComImport, Guid("bcc18b79-ba16-442f-80c4-8a59c30c463b"), InterfaceType(ComInterfaceType.InterfaceIsIUnknown)]
    interface IShellItemImageFactory {
        void GetImage(SIZE size, uint flags, out IntPtr phbm);
    }
    [StructLayout(LayoutKind.Sequential)] struct SIZE { public int cx; public int cy; public SIZE(int x, int y){cx=x;cy=y;} }
    [DllImport("shell32.dll", CharSet=CharSet.Unicode, PreserveSig=true)]
    static extern int SHCreateItemFromParsingName(string path, IntPtr pbc, [MarshalAs(UnmanagedType.LPStruct)] Guid riid, out IShellItemImageFactory ppv);

    static void Main(string[] args) {
        Console.WriteLine("PID " + System.Diagnostics.Process.GetCurrentProcess().Id);
        foreach (var path in args) {
            Console.WriteLine("thumb: " + path);
            var iid = new Guid("bcc18b79-ba16-442f-80c4-8a59c30c463b");
            IShellItemImageFactory factory;
            int hr = SHCreateItemFromParsingName(path, IntPtr.Zero, iid, out factory);
            Console.WriteLine("SHCreateItem hr=0x" + hr.ToString("X8"));
            if (hr != 0) continue;
            IntPtr hbm;
            factory.GetImage(new SIZE(256, 256), 0, out hbm);
            Console.WriteLine("GetImage hbm=" + hbm);
        }
        Console.WriteLine("done");
    }
}

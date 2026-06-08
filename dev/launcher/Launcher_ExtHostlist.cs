// ========================================
// Fabriq Extended Hostlist Editor Launcher (v0.68.0)
// Tiny C# wrapper that launches fabriq_exthostlist.ps1 via conhost +
// powershell.exe. Like Handoff Viewer this launcher does NOT self-elevate
// (the manifest requests asInvoker): the editor only reads/writes the
// per-satellite extended hostlist under backuper\data\ and prompts for the
// master passphrase; no admin is required.
//
// The entry .ps1 lives at the repo root next to this .exe:
//     E:\fabriq_backuper\fabriq_exthostlist.ps1
//
// Adapted 2026-06-08 from Launcher_HandoffViewer.cs. The only differences are
// the entry .ps1 file name, the AssemblyTitle/Product strings, and the
// MessageBox caption.
// ========================================

using System;
using System.Diagnostics;
using System.IO;
using System.Reflection;
using System.Runtime.InteropServices;

[assembly: AssemblyTitle("Fabriq Extended Hostlist Editor")]
[assembly: AssemblyProduct("Fabriq Extended Hostlist Editor")]
[assembly: AssemblyDescription("Per-satellite extended hostlist editor (UNC creds + visual info)")]
[assembly: AssemblyCompany("Fabriq Project")]
[assembly: AssemblyVersion("0.68.0.0")]
[assembly: AssemblyFileVersion("0.68.0.0")]

namespace FabriqExtHostlist
{
    internal static class Launcher
    {
        [DllImport("user32.dll", CharSet = CharSet.Unicode)]
        private static extern int MessageBoxW(IntPtr hWnd, string text, string caption, uint type);

        private const uint MB_ICONERROR = 0x00000010;
        private const uint MB_OK        = 0x00000000;

        [STAThread]
        private static int Main()
        {
            try
            {
                string exePath = Assembly.GetExecutingAssembly().Location;
                string baseDir = Path.GetDirectoryName(exePath);

                if (string.IsNullOrEmpty(baseDir))
                {
                    ShowError("Failed to resolve launcher directory.");
                    return 1;
                }

                // Pin cwd to the repo root so the entry .ps1's relative path
                // math resolves consistently regardless of how the .exe is
                // invoked (double-click, shortcut, Run dialog, ...).
                Directory.SetCurrentDirectory(baseDir);

                string entryPs1 = Path.Combine(baseDir, "fabriq_exthostlist.ps1");
                if (!File.Exists(entryPs1))
                {
                    ShowError("fabriq_exthostlist.ps1 was not found at the repo root:\n" + baseDir);
                    return 2;
                }

                // Launch via conhost so we get a fresh console window
                // independent of any parent.
                var psi = new ProcessStartInfo
                {
                    FileName  = "conhost.exe",
                    Arguments = "powershell.exe -NoProfile -ExecutionPolicy Bypass -File \".\\fabriq_exthostlist.ps1\"",
                    WorkingDirectory = baseDir,
                    UseShellExecute  = true,
                };

                Process.Start(psi);
                return 0;
            }
            catch (Exception ex)
            {
                ShowError("Unexpected launcher error:\n" + ex.Message);
                return 99;
            }
        }

        private static void ShowError(string message)
        {
            MessageBoxW(IntPtr.Zero, message, "Fabriq Extended Hostlist Editor Launcher", MB_ICONERROR | MB_OK);
        }
    }
}

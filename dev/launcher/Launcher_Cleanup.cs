// ========================================
// Fabriq Cleanup Launcher (v0.54.0)
// Tiny C# wrapper that launches fabriq_cleanup.ps1 via conhost +
// powershell.exe. Unlike LAN-Prep this launcher does NOT self-elevate
// (the manifest requests asInvoker): cleanup only deletes user-owned
// backup data, so administrator rights are not required.
//
// The entry .ps1 lives at the repo root next to this .exe:
//     E:\fabriq_backuper\fabriq_cleanup.ps1
//
// Adapted 2026-06-05 from Launcher_LanPrep.cs. The only differences
// are the entry .ps1 file name, the AssemblyTitle/Product strings,
// the MessageBox caption, and the asInvoker manifest.
// ========================================

using System;
using System.Diagnostics;
using System.IO;
using System.Reflection;
using System.Runtime.InteropServices;

[assembly: AssemblyTitle("Fabriq Cleanup")]
[assembly: AssemblyProduct("Fabriq Cleanup")]
[assembly: AssemblyDescription("Post-migration backup-data cleanup tool (per hostlist host)")]
[assembly: AssemblyCompany("Fabriq Project")]
[assembly: AssemblyVersion("0.54.0.0")]
[assembly: AssemblyFileVersion("0.54.0.0")]

namespace FabriqCleanup
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

                string entryPs1 = Path.Combine(baseDir, "fabriq_cleanup.ps1");
                if (!File.Exists(entryPs1))
                {
                    ShowError("fabriq_cleanup.ps1 was not found at the repo root:\n" + baseDir);
                    return 2;
                }

                // Launch via conhost so we get a fresh console window
                // independent of any parent.
                var psi = new ProcessStartInfo
                {
                    FileName  = "conhost.exe",
                    Arguments = "powershell.exe -NoProfile -ExecutionPolicy Bypass -WindowStyle Minimized -File \".\\fabriq_cleanup.ps1\"",
                    WorkingDirectory = baseDir,
                    UseShellExecute  = true,
                    // t-0017: open the diagnostic console MINIMIZED (taskbar only) so it
                    // does not sit on screen beside the GUI. The console still exists, so
                    // Read-Host / startup errors stay reachable by restoring the window.
                    WindowStyle = ProcessWindowStyle.Minimized,
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
            MessageBoxW(IntPtr.Zero, message, "Fabriq Cleanup Launcher", MB_ICONERROR | MB_OK);
        }
    }
}

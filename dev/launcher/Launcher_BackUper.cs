// ========================================
// Fabriq BackUper Launcher (detached satellite repo)
// Tiny C# wrapper that launches fabriq_backuper.ps1 via
// conhost + powershell.exe. The entry .ps1 lives at the
// repo root (E:\fabriq_backuper\fabriq_backuper.ps1).
//
// Adapted 2026-05-20 from e:\fabriq\dev\launcher\Launcher_BackUper.cs
// (apps\fabriq_backuper layout) for the detached satellite repo.
// Single change: the entry .ps1 path no longer has the apps\fabriq_backuper
// prefix — it lives next to this .exe at the repo root.
// ========================================

using System;
using System.Diagnostics;
using System.IO;
using System.Reflection;
using System.Runtime.InteropServices;

[assembly: AssemblyTitle("Fabriq BackUper")]
[assembly: AssemblyProduct("Fabriq BackUper")]
[assembly: AssemblyDescription("Standalone backup/restore satellite for the Fabriq kitting framework")]
[assembly: AssemblyCompany("Fabriq Project")]
[assembly: AssemblyVersion("0.13.0.0")]
[assembly: AssemblyFileVersion("0.13.0.0")]

namespace FabriqBackUper
{
    internal static class Launcher
    {
        // Win32 MessageBox for error reporting (avoids pulling in WinForms).
        [DllImport("user32.dll", CharSet = CharSet.Unicode)]
        private static extern int MessageBoxW(IntPtr hWnd, string text, string caption, uint type);

        private const uint MB_ICONERROR = 0x00000010;
        private const uint MB_OK = 0x00000000;

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
                // math (Find-FabriqRoot scans the sibling-directory parent)
                // resolves correctly regardless of how the user invoked the
                // .exe (Explorer double-click, shortcut, Run dialog, ...).
                Directory.SetCurrentDirectory(baseDir);

                string entryPs1 = Path.Combine(baseDir, "fabriq_backuper.ps1");
                if (!File.Exists(entryPs1))
                {
                    ShowError("fabriq_backuper.ps1 was not found at the repo root:\n" + baseDir);
                    return 2;
                }

                // Launch via conhost.exe so we get a fresh console window
                // independent of any parent. fabriq_backuper.ps1 will then
                // self-spawn into an isolated subprocess (FABRIQ_BACKUPER_SUBPROCESS
                // sentinel) so PSReadLine handlers / env vars / global
                // state never leak back into the launcher process.
                var psi = new ProcessStartInfo
                {
                    FileName = "conhost.exe",
                    Arguments = "powershell.exe -NoProfile -ExecutionPolicy Bypass -File \".\\fabriq_backuper.ps1\"",
                    WorkingDirectory = baseDir,
                    UseShellExecute = true,
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
            MessageBoxW(IntPtr.Zero, message, "Fabriq BackUper Launcher", MB_ICONERROR | MB_OK);
        }
    }
}

using System;
using System.Collections.Generic;
using System.ComponentModel;
using System.Diagnostics;
using System.IO;
using System.Runtime.InteropServices;
using System.Text;

// Use process creation events to stop only positively identified disposable
// children before their first user-mode instruction. No target code is patched.
public static class EbrRecoveryDebugger
{
    private const uint DebugProcess = 1;
    private const uint DebugContinue = 0x00010002;
    private const uint DebugExceptionNotHandled = 0x80010001;
    private const uint Breakpoint = 0x80000003;
    private const uint FaultExitCode = 197;
    private const uint WaitTimeout = 258;
    private const int SemaphoreTimeout = 121;

    [StructLayout(LayoutKind.Sequential)]
    private struct StartupInfo
    {
        public int Size;
        public IntPtr Reserved, Desktop, Title;
        public uint X, Y, XSize, YSize, XChars, YChars, Fill, Flags;
        public ushort ShowWindow, ReservedSize;
        public IntPtr Reserved2, StandardIn, StandardOut, StandardError;
    }

    [StructLayout(LayoutKind.Sequential)]
    private struct ProcessInfo
    {
        public IntPtr Process, Thread;
        public uint Pid, Tid;
    }

    // DEBUG_EVENT and its largest union member have this layout on native x64.
    [StructLayout(LayoutKind.Explicit, Size = 176)]
    private struct DebugEvent
    {
        [FieldOffset(0)] public uint Kind;
        [FieldOffset(4)] public uint Pid;
        [FieldOffset(8)] public uint Tid;
        [FieldOffset(16)] public IntPtr File;
        [FieldOffset(24)] public IntPtr Process;
        [FieldOffset(16)] public uint Status;
    }

    public sealed class Observation
    {
        public uint CoordinatorPid { get; set; }
        public uint InstallerPid { get; set; }
        public uint InstallerExitCode { get; set; }
        public uint InterruptedChildPid { get; set; }
        public uint InterruptedChildExitCode { get; set; }
        public uint CoordinatorExitCode { get; set; }
        public string InterruptedChildPath { get; set; }
        public string Boundary { get; set; }
    }

    [DllImport("kernel32.dll", CharSet = CharSet.Unicode, SetLastError = true)]
    private static extern bool CreateProcess(string image, StringBuilder command, IntPtr processAttributes,
        IntPtr threadAttributes, bool inheritHandles, uint flags, IntPtr environment, string directory,
        ref StartupInfo startup, out ProcessInfo process);
    [DllImport("kernel32.dll", SetLastError = true)]
    private static extern bool WaitForDebugEvent(out DebugEvent debugEvent, uint milliseconds);
    [DllImport("kernel32.dll", SetLastError = true)]
    private static extern bool ContinueDebugEvent(uint pid, uint tid, uint status);
    [DllImport("kernel32.dll", SetLastError = true)]
    private static extern bool DebugActiveProcessStop(uint pid);
    [DllImport("kernel32.dll", SetLastError = true)]
    private static extern bool TerminateProcess(IntPtr process, uint code);
    [DllImport("kernel32.dll", SetLastError = true)]
    private static extern uint WaitForSingleObject(IntPtr handle, uint milliseconds);
    [DllImport("kernel32.dll")]
    private static extern bool CloseHandle(IntPtr handle);
    [DllImport("kernel32.dll", CharSet = CharSet.Unicode, SetLastError = true)]
    private static extern bool QueryFullProcessImageName(IntPtr process, uint flags, StringBuilder name, ref uint length);

    private static void Check(bool condition, string operation)
    {
        if (!condition)
            throw new Win32Exception(Marshal.GetLastWin32Error(), operation);
    }

    private static bool Same(string left, string right) =>
        String.Equals(left, right, StringComparison.OrdinalIgnoreCase);

    private static string ProcessImage(IntPtr process)
    {
        var buffer = new StringBuilder(32768);
        uint length = (uint)buffer.Capacity;
        Check(QueryFullProcessImageName(process, 0, buffer, ref length), "Query owned process image");
        return buffer.ToString();
    }

    public static Observation Interrupt(string coordinator, string transaction, string installer, string application,
        string boundary, Action<uint, uint> onBoundary)
    {
        if (IntPtr.Size != 8 || (boundary != "InstallerStart" && boundary != "BeforeRelaunch"))
            throw new ArgumentException("Expected native x64 and a known interruption boundary.");
        var startup = new StartupInfo { Size = Marshal.SizeOf<StartupInfo>() };
        var command = new StringBuilder("\"" + coordinator + "\" --update-coordinator \"" + transaction + "\"");
        Check(CreateProcess(coordinator, command, IntPtr.Zero, IntPtr.Zero, false, DebugProcess, IntPtr.Zero,
            Path.GetDirectoryName(coordinator), ref startup, out ProcessInfo root), "Launch disposable coordinator");
        CloseHandle(root.Thread);
        var result = new Observation { CoordinatorPid = root.Pid, Boundary = boundary };
        var live = new HashSet<uint> { root.Pid };
        var initialBreak = new HashSet<uint>();
        bool installerExited = false;
        try
        {
            var elapsed = Stopwatch.StartNew();
            while (live.Count != 0 && elapsed.Elapsed < TimeSpan.FromSeconds(100))
            {
                if (!WaitForDebugEvent(out DebugEvent current, 500))
                {
                    int error = Marshal.GetLastWin32Error();
                    if (error == SemaphoreTimeout || error == WaitTimeout)
                        continue;
                    throw new Win32Exception(error, "Wait for owned process debug event");
                }
                uint status = DebugContinue;
                try
                {
                    switch (current.Kind)
                    {
                        case 1: // EXCEPTION_DEBUG_EVENT
                            if (current.Status != Breakpoint || !initialBreak.Add(current.Pid))
                                status = DebugExceptionNotHandled;
                            break;
                        case 3: // CREATE_PROCESS_DEBUG_EVENT
                            if (current.File != IntPtr.Zero)
                                CloseHandle(current.File);
                            live.Add(current.Pid);
                            string image = ProcessImage(current.Process);
                            if (current.Pid == root.Pid)
                            {
                                if (!Same(image, coordinator))
                                    throw new InvalidOperationException("Coordinator image mismatch.");
                                break;
                            }
                            bool isInstaller = Same(image, installer);
                            bool isApplication = Same(image, application);
                            if ((!isInstaller && !isApplication) ||
                                (isInstaller && result.InstallerPid != 0) ||
                                (isApplication && (!installerExited || result.InstallerExitCode != 0)))
                                throw new InvalidOperationException("Unexpected disposable process at interruption boundary: " + image);
                            if (isInstaller)
                                result.InstallerPid = current.Pid;
                            if ((isInstaller && boundary == "InstallerStart") || (isApplication && boundary == "BeforeRelaunch"))
                            {
                                onBoundary(root.Pid, current.Pid);
                                Check(TerminateProcess(root.Process, FaultExitCode), "Terminate the owned coordinator");
                                Check(TerminateProcess(current.Process, FaultExitCode), "Terminate the owned child before execution");
                                result.InterruptedChildPid = current.Pid;
                                result.InterruptedChildPath = image;
                            }
                            break;
                        case 5: // EXIT_PROCESS_DEBUG_EVENT
                            live.Remove(current.Pid);
                            if (current.Pid == root.Pid)
                                result.CoordinatorExitCode = current.Status;
                            if (current.Pid == result.InstallerPid)
                            {
                                result.InstallerExitCode = current.Status;
                                installerExited = true;
                            }
                            if (current.Pid == result.InterruptedChildPid)
                                result.InterruptedChildExitCode = current.Status;
                            break;
                        case 6: // LOAD_DLL_DEBUG_EVENT
                            if (current.File != IntPtr.Zero)
                                CloseHandle(current.File);
                            break;
                    }
                }
                finally
                {
                    Check(ContinueDebugEvent(current.Pid, current.Tid, status), "Continue owned process debug event");
                }
            }
            if (live.Count != 0 || result.InterruptedChildPid == 0 ||
                result.InterruptedChildExitCode != FaultExitCode || result.CoordinatorExitCode != FaultExitCode)
                throw new InvalidOperationException("Expected fault exits were not observed at " + boundary);
            return result;
        }
        finally
        {
            if (WaitForSingleObject(root.Process, 0) == WaitTimeout)
                TerminateProcess(root.Process, FaultExitCode);
            foreach (uint pid in live)
                DebugActiveProcessStop(pid);
            CloseHandle(root.Process);
        }
    }
}

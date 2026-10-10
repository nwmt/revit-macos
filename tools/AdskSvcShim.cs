// SPDX-License-Identifier: MIT
// Service shim for AdskLicensingService under Wine.
//
// Why: AdskLicensingService is written in Go (kardianos/service). It decides whether it runs as a
// service via svc.IsAnInteractiveSession(). Under Wine the token carries the Interactive SID, so it
// thinks it was started from a console and never calls StartServiceCtrlDispatcher. SCM waits until
// the timeout and kills the process (process_send_start_message ... failed to start), even though
// the HTTP server is already up.
//
// What it does: registers with SCM as a regular .NET service, reports RUNNING and keeps the real
// AdskLicensingService.exe as a child process in console mode. If the child dies, the service
// stops (SCM then restarts it per the sc failure policy).
using System;
using System.Diagnostics;
using System.IO;
using System.ServiceProcess;

class AdskSvcShim : ServiceBase {
  const string DefaultTarget = @"C:\Program Files (x86)\Common Files\Autodesk Shared\AdskLicensing\Current\AdskLicensingService\AdskLicensingService.exe";
  const string LogPath = @"C:\ProgramData\Autodesk\AdskLicensingService\Log\AdskSvcShim.log";
  readonly string target;
  Process child;

  AdskSvcShim(string target) { ServiceName = "AdskLicensingService"; this.target = target; CanStop = true; }

  static void Log(string m) {
    try { File.AppendAllText(LogPath, DateTime.Now.ToString("yyyy/MM/dd HH:mm:ss.fff") + " " + m + Environment.NewLine); } catch { }
  }

  protected override void OnStart(string[] args) {
    var psi = new ProcessStartInfo(target) {
      WorkingDirectory = Path.GetDirectoryName(target), UseShellExecute = false, CreateNoWindow = true
    };
    child = Process.Start(psi);
    child.EnableRaisingEvents = true;
    child.Exited += (s, e) => { Log("child exited code=" + child.ExitCode + ", stopping service"); Stop(); };
    Log("started child pid=" + child.Id + " " + target);
  }

  protected override void OnStop() {
    try { if (child != null && !child.HasExited) { child.Kill(); child.WaitForExit(5000); } } catch (Exception ex) { Log("stop: " + ex.Message); }
    Log("stopped");
  }

  static void Main(string[] args) {
    Run(new AdskSvcShim(args.Length > 0 ? args[0] : DefaultTarget));
  }
}

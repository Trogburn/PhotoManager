using System.Diagnostics;
using System.Text;

namespace PhotoManager.Services;

public sealed record ScriptResult(int ExitCode, string StandardOutput, string StandardError);

public sealed class PowerShellScriptRunner
{
    public async Task<ScriptResult> RunAsync(
        string scriptPath,
        IEnumerable<string> arguments,
        string workingDirectory,
        CancellationToken cancellationToken = default)
    {
        if (!File.Exists(scriptPath))
        {
            throw new FileNotFoundException("Workflow script was not found.", scriptPath);
        }

        var info = new ProcessStartInfo
        {
            FileName = "powershell.exe",
            WorkingDirectory = workingDirectory,
            UseShellExecute = false,
            CreateNoWindow = true,
            RedirectStandardOutput = true,
            RedirectStandardError = true,
            StandardOutputEncoding = Encoding.UTF8,
            StandardErrorEncoding = Encoding.UTF8
        };
        info.ArgumentList.Add("-NoLogo");
        info.ArgumentList.Add("-NoProfile");
        info.ArgumentList.Add("-NonInteractive");
        info.ArgumentList.Add("-ExecutionPolicy");
        info.ArgumentList.Add("Bypass");
        info.ArgumentList.Add("-File");
        info.ArgumentList.Add(scriptPath);
        foreach (var argument in arguments)
        {
            info.ArgumentList.Add(argument);
        }

        using var process = new Process { StartInfo = info, EnableRaisingEvents = true };
        if (!process.Start())
        {
            throw new InvalidOperationException($"Unable to start PowerShell script: {scriptPath}");
        }

        var stdoutTask = process.StandardOutput.ReadToEndAsync(cancellationToken);
        var stderrTask = process.StandardError.ReadToEndAsync(cancellationToken);
        await process.WaitForExitAsync(cancellationToken);
        return new ScriptResult(
            process.ExitCode,
            await stdoutTask,
            await stderrTask);
    }
}

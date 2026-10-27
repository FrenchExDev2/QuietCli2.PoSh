using System;
using System.Collections.Concurrent;
using System.Diagnostics;
using System.IO;
using System.Text;
using System.Threading;
using System.Threading.Tasks;

namespace QuietCliStack.V1 {
    public sealed class Record {
        public string Stream { get; set; }
        public string Text { get; set; }
        public bool Truncated { get; set; }
    }
    public sealed class Capture {
        public string Stdout = "", Stderr = "", StartError = "";
        public int? ExitCode;
        public bool TimedOut, CaptureTruncated;
        public long StdoutCharacters, StderrCharacters, LostRecords, ElapsedMs;
    }
    // Only native readers run in background tasks. PowerShell callbacks run on the caller's thread.
    public sealed class NativeSession : IDisposable {
        readonly BlockingCollection<Record> queue = new(16);
        readonly CancellationTokenSource cancel = new();
        readonly Process process = new();
        readonly Stopwatch watch = Stopwatch.StartNew();
        readonly Task completion;
        readonly bool streaming;
        readonly int captureLimit, recordLimit;
        readonly char delimiter;
        public Capture Result { get; } = new();

        public NativeSession(string executable, string[] arguments, string directory,
                             int seconds, bool streamRecords, int maxCaptureCharacters,
                             int maxRecordCharacters, char recordDelimiter) {
            streaming = streamRecords; captureLimit = maxCaptureCharacters;
            recordLimit = maxRecordCharacters; delimiter = recordDelimiter;
            process.StartInfo = new ProcessStartInfo(executable) {
                WorkingDirectory = directory, UseShellExecute = false, CreateNoWindow = true,
                RedirectStandardInput = true, RedirectStandardOutput = true, RedirectStandardError = true,
                StandardOutputEncoding = Encoding.UTF8, StandardErrorEncoding = Encoding.UTF8
            };
            foreach (string arg in arguments) process.StartInfo.ArgumentList.Add(arg);
            try { process.Start(); process.StandardInput.Close(); }
            catch (Exception e) {
                Result.StartError = e.GetType().Name;
                Result.ElapsedMs = watch.ElapsedMilliseconds;
                queue.CompleteAdding(); completion = Task.CompletedTask; return;
            }
            completion = Task.Run(() => RunAsync(seconds));
        }
        async Task PublishAsync(string stream, StringBuilder text, long length) {
            bool lost = length > recordLimit;
            if (lost) Interlocked.Increment(ref Result.LostRecords);
            var record = new Record { Stream = stream, Truncated = lost, Text = lost ? "" : text.ToString() };
            while (!queue.TryAdd(record)) await Task.Delay(1, cancel.Token).ConfigureAwait(false);
        }
        async Task DrainAsync(StreamReader reader, string stream) {
            var buffer = new char[4096]; var text = new StringBuilder();
            long length = 0; int count;
            while ((count = await reader.ReadAsync(buffer.AsMemory(), cancel.Token).ConfigureAwait(false)) > 0) {
                if (stream == "stdout") Result.StdoutCharacters += count;
                else Result.StderrCharacters += count;
                if (!streaming) {
                    int limit = stream == "stdout" ? captureLimit : Math.Min(captureLimit, 32768);
                    int keep = Math.Min(count, Math.Max(0, limit - text.Length));
                    if (keep > 0) text.Append(buffer, 0, keep);
                    continue;
                }
                for (int i = 0; i < count; i++) {
                    if (buffer[i] == (stream == "stderr" ? '\n' : delimiter)) {
                        await PublishAsync(stream, text, length).ConfigureAwait(false);
                        text.Clear(); length = 0;
                    } else {
                        length++; if (text.Length < recordLimit) text.Append(buffer[i]);
                    }
                }
            }
            if (streaming && length > 0) await PublishAsync(stream, text, length).ConfigureAwait(false);
            if (!streaming) {
                if (stream == "stdout") Result.Stdout = text.ToString();
                else Result.Stderr = text.ToString();
            }
        }
        void Kill() {
            try { process.Kill(entireProcessTree: true); }
            catch (InvalidOperationException) { }
            catch (System.ComponentModel.Win32Exception) { }
        }
        async Task RunAsync(int seconds) {
            using var timerCancel = new CancellationTokenSource();
            try {
                var finished = Task.WhenAll(process.WaitForExitAsync(cancel.Token),
                    DrainAsync(process.StandardOutput, "stdout"), DrainAsync(process.StandardError, "stderr"));
                var deadline = Task.Delay(TimeSpan.FromSeconds(seconds), timerCancel.Token);
                if (await Task.WhenAny(finished, deadline).ConfigureAwait(false) != finished) {
                    Result.TimedOut = true; Kill();
                    if (await Task.WhenAny(finished, Task.Delay(2000)).ConfigureAwait(false) != finished) cancel.Cancel();
                }
                await finished.ConfigureAwait(false);
            } catch (OperationCanceledException) { }
              catch (Exception e) { Result.StartError = e.GetType().Name; Kill(); }
            finally {
                timerCancel.Cancel();
                try { if (process.HasExited) Result.ExitCode = process.ExitCode; }
                catch (InvalidOperationException) { }
                if (!streaming) Result.CaptureTruncated = Result.StdoutCharacters > Result.Stdout.Length ||
                                                         Result.StderrCharacters > Result.Stderr.Length;
                Result.ElapsedMs = watch.ElapsedMilliseconds;
                queue.CompleteAdding();
            }
        }
        public Record Next() {
            while (!queue.IsCompleted) if (queue.TryTake(out var record, 100)) return record;
            completion.GetAwaiter().GetResult(); return null;
        }
        public void Dispose() {
            if (!completion.IsCompleted) { cancel.Cancel(); Kill(); }
            completion.GetAwaiter().GetResult();
            process.Dispose(); cancel.Dispose(); queue.Dispose(); watch.Stop();
        }
    }
}

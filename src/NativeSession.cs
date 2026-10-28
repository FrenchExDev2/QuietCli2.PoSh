#nullable enable
using System;
using System.Collections;
using System.Collections.Concurrent;
using System.Collections.Generic;
using System.Diagnostics;
using System.IO;
using System.Text;
using System.Threading;
using System.Threading.Tasks;

namespace QuietCliStack.V2 {
    public sealed class Record {
        public string Stream { get; init; } = "";
        public string Text { get; init; } = "";
        public long Sequence { get; set; }
        public bool Truncated { get; init; }
    }
    // Captures own their temporary directory. Read text only when requested; serialization never traverses this object.
    public sealed class Capture : IDisposable {
        public string DirectoryPath { get; }
        public string EncodingName { get; }
        public char StdoutDelimiter { get; }
        public char StderrDelimiter { get; }
        public long StdoutBytes, StderrBytes, LostRecords, ElapsedMs, CallbackMs, BackpressureMs;
        public int? ExitCode;
        public double? ProcessMs; public double SetupMs;
        public bool TimedOut, Cancelled, SourceComplete, CaptureComplete = true, Lossy, JournalComplete = true;
        public Record[] ReadRecords() {
            string path = Path.Combine(DirectoryPath, "records.bin");
            var records = new List<Record>();
            if (!File.Exists(path)) return records.ToArray();
            using var input = new BinaryReader(File.OpenRead(path), Encoding.UTF8);
            while (input.BaseStream.Position < input.BaseStream.Length) {
                records.Add(new Record { Sequence=input.ReadInt64(), Stream=input.ReadString(), Truncated=input.ReadBoolean(), Text=input.ReadString() });
            }
            return records.ToArray();
        }
                readonly Queue<string> stdoutTail = new(), stderrTail = new();
        public string[] ReadTail(string stream) { ValidateStream(stream); return (stream=="stdout" ? stdoutTail : stderrTail).ToArray(); }
        internal void RememberTail(string stream, string value) {
            var tail=stream=="stdout" ? stdoutTail : stderrTail;
            if (value.Length>1000) value=value.Substring(0,1000)+"…";
            tail.Enqueue(value);if(tail.Count>20)tail.Dequeue();
        }
        public string StartError = "";
        public string Stdout => ReadText("stdout");
        public string Stderr => ReadText("stderr");
        public Capture(string path, string encoding, char stdout, char stderr) {
            DirectoryPath = path; EncodingName = encoding; StdoutDelimiter = stdout; StderrDelimiter = stderr;
        }
        public string ReadText(string stream) {
            ValidateStream(stream);
            string path = Path.Combine(DirectoryPath, stream);
            return File.Exists(path) ? Encoding.GetEncoding(EncodingName).GetString(File.ReadAllBytes(path)) : "";
        }
        public string[] ReadLines(string stream, int from, int count) {
            ValidateStream(stream);
            if (from < 1 || count < 0) throw new ArgumentOutOfRangeException();
            var result = new List<string>();
            string path = Path.Combine(DirectoryPath, stream);
            if (!File.Exists(path)) return result.ToArray();
            using var reader = new StreamReader(path, Encoding.GetEncoding(EncodingName));
            int line = 0; string? value;
            while ((value = reader.ReadLine()) is not null && result.Count < count) {
                if (++line >= from) result.Add(value);
            }
            return result.ToArray();
        }
        static void ValidateStream(string stream) {
            if (stream != "stdout" && stream != "stderr") throw new ArgumentException("Unknown capture stream.");
        }
        public void Dispose() {
            try { if (Directory.Exists(DirectoryPath)) Directory.Delete(DirectoryPath, true); } catch (IOException) { } catch (UnauthorizedAccessException) { }
            GC.SuppressFinalize(this);
        }
        ~Capture() { Dispose(); }
    }
    // Adapted from QuietCli V1's concurrent readers. Domain callbacks always run on PowerShell's caller thread.
    public sealed class NativeSession : IDisposable {
        readonly BlockingCollection<Record> queue = new(16);
        readonly CancellationTokenSource readersCancel = new();
        readonly Process process = new();
        readonly Stopwatch watch = Stopwatch.StartNew();
        readonly Task completion;
        readonly Encoding encoding;
        readonly CancellationToken cancellation;
        readonly string? cancellationFile;
        readonly int recordLimit;
        readonly long captureLimit;
        readonly char stdoutDelimiter, stderrDelimiter;
        long sequence, delivered;
        BinaryWriter? journal;
        int incompleteCaptures;
        bool stdoutComplete, stderrComplete;
        public Capture Result { get; }
        public NativeSession(string executable, string[] arguments, string directory, IDictionary environment,
            string? input, string encodingName, int seconds, int maxRecord, long maxCapture,
            char stdoutSeparator, char stderrSeparator, CancellationToken token, string? signalFile) {
            encoding = Encoding.GetEncoding(encodingName);
            cancellation = token; cancellationFile = signalFile;
            recordLimit = maxRecord; captureLimit = maxCapture; stdoutDelimiter = stdoutSeparator; stderrDelimiter = stderrSeparator;
            string path = Path.Combine(Path.GetTempPath(), "quietcli-" + Guid.NewGuid().ToString("N"));
            Directory.CreateDirectory(path);
            Result = new Capture(path, encodingName, stdoutSeparator, stderrSeparator);
            try { journal = new BinaryWriter(File.Create(Path.Combine(path, "records.bin")), Encoding.UTF8); } catch (IOException) { Result.JournalComplete=false; }
            process.StartInfo = new ProcessStartInfo(executable) {
                WorkingDirectory = directory, UseShellExecute = false, CreateNoWindow = true,
                RedirectStandardInput = input is not null, RedirectStandardOutput = true, RedirectStandardError = true
            };
            process.StartInfo.Environment["QUIETCLI_TRACKING"] = "0";
            process.StartInfo.Environment["QUIETCLI_RECALL"] = "0";
            foreach (DictionaryEntry entry in environment) {
                string key = (string)entry.Key;
                if (entry.Value is null) process.StartInfo.Environment.Remove(key);
                else process.StartInfo.Environment[key] = Convert.ToString(entry.Value);
            }
            foreach (string argument in arguments) process.StartInfo.ArgumentList.Add(argument);
            if (Cancelled()) {
                Result.Cancelled = true; queue.CompleteAdding(); completion = Task.CompletedTask; return;
            }
                        try {
                process.EnableRaisingEvents=true;
                double started=watch.Elapsed.TotalMilliseconds;
                process.Exited += (_, _) => Result.ProcessMs=watch.Elapsed.TotalMilliseconds-started;
                process.Start();Result.SetupMs=watch.Elapsed.TotalMilliseconds;
            }
            catch (Exception e) {
                Result.StartError = e.Message; Result.ElapsedMs = watch.ElapsedMilliseconds;
                queue.CompleteAdding(); completion = Task.CompletedTask; return;
            }
            completion = Task.Run(() => RunAsync(seconds, input));
        }
        bool Cancelled() => cancellation.IsCancellationRequested ||
            (!string.IsNullOrEmpty(cancellationFile) && File.Exists(cancellationFile));
        async Task Publish(string stream, StringBuilder text, long length) {
            Result.RememberTail(stream,text.ToString());
            bool oversized = length > recordLimit;
            if (oversized) Interlocked.Increment(ref Result.LostRecords);
            var record = new Record { Stream = stream, Text = oversized ? "" : text.ToString(),
                Sequence = Interlocked.Increment(ref sequence), Truncated = oversized };
            long started = Stopwatch.GetTimestamp();
            while (!queue.TryAdd(record)) await Task.Delay(1, readersCancel.Token).ConfigureAwait(false);
            Interlocked.Add(ref Result.BackpressureMs, (long)Stopwatch.GetElapsedTime(started).TotalMilliseconds);
        }
        async Task DrainAsync(Stream stream, string name, char delimiter) {
            var bytes = new byte[8192]; var chars = new char[encoding.GetMaxCharCount(bytes.Length)];
            var decoder = encoding.GetDecoder(); var strict = (Encoding)encoding.Clone();
            strict.DecoderFallback = DecoderFallback.ExceptionFallback;
            var verifier = strict.GetDecoder();
            var text = new StringBuilder(); long length = 0, stored = 0;
            FileStream? spool = null;
            try { spool = new FileStream(Path.Combine(Result.DirectoryPath, name), FileMode.CreateNew, FileAccess.Write, FileShare.Read); }
            catch (IOException) { Interlocked.Increment(ref incompleteCaptures); }
            try {
                int count;
                while ((count = await stream.ReadAsync(bytes.AsMemory(), readersCancel.Token).ConfigureAwait(false)) > 0) {
                    if (name == "stdout") Result.StdoutBytes += count; else Result.StderrBytes += count;
                    int keep = (int)Math.Min(count, Math.Max(0, captureLimit - stored));
                    if (keep < count) Interlocked.Increment(ref incompleteCaptures);
                    if (spool is not null && keep > 0) {
                        try { await spool.WriteAsync(bytes.AsMemory(0, keep), readersCancel.Token).ConfigureAwait(false); stored += keep; }
                        catch (IOException) { spool.Dispose(); spool = null; Interlocked.Increment(ref incompleteCaptures); }
                    }
                    try { verifier.GetCharCount(bytes, 0, count, false); }
                    catch (DecoderFallbackException) { Result.Lossy = true; verifier.Reset(); }
                    int produced = decoder.GetChars(bytes, 0, count, chars, 0, false);
                    for (int i = 0; i < produced; i++) {
                        if (chars[i] == delimiter) { await Publish(name, text, length).ConfigureAwait(false); text.Clear(); length = 0; }
                        else { length++; if (text.Length < recordLimit) text.Append(chars[i]); }
                    }
                }
                try { verifier.GetCharCount(Array.Empty<byte>(), 0, 0, true); }
                catch (DecoderFallbackException) { Result.Lossy = true; }
                int remaining = decoder.GetChars(Array.Empty<byte>(), 0, 0, chars, 0, true);
                for (int i = 0; i < remaining; i++) { length++; if (text.Length < recordLimit) text.Append(chars[i]); }
                if (length > 0) await Publish(name, text, length).ConfigureAwait(false);
                if (name == "stdout") stdoutComplete = true; else stderrComplete = true;
            } finally { spool?.Dispose(); }
        }
        async Task WriteInput(string? input) {
            if (input is null) return;
            byte[] bytes = encoding.GetBytes(input);
            try { await process.StandardInput.BaseStream.WriteAsync(bytes.AsMemory(), readersCancel.Token).ConfigureAwait(false); }
            finally { process.StandardInput.Close(); }
        }
        void Kill() {
            try { process.Kill(true); }
            catch (InvalidOperationException) { }
            catch (System.ComponentModel.Win32Exception) { }
        }
        async Task RunAsync(int seconds, string? input) {
            try {
                var finished = Task.WhenAll(process.WaitForExitAsync(readersCancel.Token),
                    DrainAsync(process.StandardOutput.BaseStream, "stdout", stdoutDelimiter),
                    DrainAsync(process.StandardError.BaseStream, "stderr", stderrDelimiter), WriteInput(input));
                while (!finished.IsCompleted) {
                    if (Cancelled() || watch.Elapsed.TotalSeconds >= seconds) {
                        Result.Cancelled = Cancelled(); Result.TimedOut = !Result.Cancelled; Kill();
                        if (await Task.WhenAny(finished, Task.Delay(2000)).ConfigureAwait(false) != finished) readersCancel.Cancel();
                        break;
                    }
                    await Task.WhenAny(finished, Task.Delay(25)).ConfigureAwait(false);
                }
                await finished.ConfigureAwait(false);
            } catch (OperationCanceledException) { }
              catch (Exception e) { Result.StartError = e.Message; Kill(); }
            finally {
                try { if (process.HasExited) Result.ExitCode = process.ExitCode; } catch (InvalidOperationException) { }
                Result.SourceComplete = stdoutComplete && stderrComplete && !Result.TimedOut && !Result.Cancelled && Result.StartError.Length == 0;
                Result.CaptureComplete = Result.SourceComplete && incompleteCaptures == 0;
                Result.ElapsedMs = watch.ElapsedMilliseconds;
                queue.CompleteAdding();
            }
        }
        public Record? Next() {
                        while (!queue.IsCompleted) if (queue.TryTake(out var record, 50)) {
                record.Sequence=++delivered;
                if (journal is not null && Result.JournalComplete) {
                    if (journal.BaseStream.Length + Encoding.UTF8.GetByteCount(record.Text) + 32 > captureLimit) Result.JournalComplete=false;
                    else try { journal.Write(record.Sequence);journal.Write(record.Stream);journal.Write(record.Truncated);journal.Write(record.Text); }
                    catch (IOException) { Result.JournalComplete=false; }
                }
                return record;
            }
            completion.GetAwaiter().GetResult(); return null;
        }
        public void Dispose() {
            if (!completion.IsCompleted) { readersCancel.Cancel(); Kill(); }
            completion.GetAwaiter().GetResult();
            journal?.Dispose(); process.Dispose(); readersCancel.Dispose(); queue.Dispose(); watch.Stop();
        }
    }
}

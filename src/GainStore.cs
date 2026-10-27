using System;
using System.Collections.Generic;
using System.Globalization;
using System.IO;
using System.Reflection;
using System.Runtime.InteropServices;
using System.Text;

namespace QuietCliStack.GainV1 {
    // SQLite's stable C API. No CLI, NuGet download, or dependency on another module.
    // https://www.sqlite.org/c3ref/open.html
    // https://www.sqlite.org/c3ref/bind_blob.html
    internal static class Sqlite {
        const string Library = "quietcli_sqlite";
        static Sqlite() { NativeLibrary.SetDllImportResolver(typeof(Sqlite).Assembly, Resolve); }
        static IntPtr Resolve(string name, Assembly assembly, DllImportSearchPath? path) {
            if (name != Library) return IntPtr.Zero;
            string[] candidates = OperatingSystem.IsWindows() ? new[] { "winsqlite3.dll", "sqlite3.dll" } :
                OperatingSystem.IsMacOS() ? new[] { "/usr/lib/libsqlite3.dylib", "libsqlite3.dylib" } :
                new[] { "libsqlite3.so.0", "libsqlite3.so" };
            foreach (string candidate in candidates)
                if (NativeLibrary.TryLoad(candidate, out IntPtr handle)) return handle;
            throw new DllNotFoundException("QuietCli requires the system SQLite library (winsqlite3 or libsqlite3).");
        }
        [DllImport(Library, CallingConvention = CallingConvention.Cdecl)]
        internal static extern int sqlite3_open_v2([MarshalAs(UnmanagedType.LPUTF8Str)] string path, out IntPtr db, int flags, IntPtr vfs);
        [DllImport(Library, CallingConvention = CallingConvention.Cdecl)] internal static extern int sqlite3_close_v2(IntPtr db);
        [DllImport(Library, CallingConvention = CallingConvention.Cdecl)] internal static extern IntPtr sqlite3_errmsg(IntPtr db);
        [DllImport(Library, CallingConvention = CallingConvention.Cdecl)] internal static extern int sqlite3_busy_timeout(IntPtr db, int ms);
        [DllImport(Library, CallingConvention = CallingConvention.Cdecl)]
        internal static extern int sqlite3_prepare_v2(IntPtr db, [MarshalAs(UnmanagedType.LPUTF8Str)] string sql, int length, out IntPtr statement, IntPtr tail);
        [DllImport(Library, CallingConvention = CallingConvention.Cdecl)] internal static extern int sqlite3_finalize(IntPtr statement);
        [DllImport(Library, CallingConvention = CallingConvention.Cdecl)] internal static extern int sqlite3_step(IntPtr statement);
        [DllImport(Library, CallingConvention = CallingConvention.Cdecl)] internal static extern int sqlite3_bind_null(IntPtr statement, int index);
        [DllImport(Library, CallingConvention = CallingConvention.Cdecl)] internal static extern int sqlite3_bind_int64(IntPtr statement, int index, long value);
        [DllImport(Library, CallingConvention = CallingConvention.Cdecl)] internal static extern int sqlite3_bind_double(IntPtr statement, int index, double value);
        [DllImport(Library, CallingConvention = CallingConvention.Cdecl)] internal static extern int sqlite3_bind_text(IntPtr statement, int index, byte[] value, int length, IntPtr destructor);
        [DllImport(Library, CallingConvention = CallingConvention.Cdecl)] internal static extern int sqlite3_column_count(IntPtr statement);
        [DllImport(Library, CallingConvention = CallingConvention.Cdecl)] internal static extern IntPtr sqlite3_column_name(IntPtr statement, int column);
        [DllImport(Library, CallingConvention = CallingConvention.Cdecl)] internal static extern int sqlite3_column_type(IntPtr statement, int column);
        [DllImport(Library, CallingConvention = CallingConvention.Cdecl)] internal static extern long sqlite3_column_int64(IntPtr statement, int column);
        [DllImport(Library, CallingConvention = CallingConvention.Cdecl)] internal static extern double sqlite3_column_double(IntPtr statement, int column);
        [DllImport(Library, CallingConvention = CallingConvention.Cdecl)] internal static extern IntPtr sqlite3_column_text(IntPtr statement, int column);
    }

    public sealed class Database : IDisposable {
        IntPtr db;
        public Database(string path, bool create) {
            try {
                if (create) Directory.CreateDirectory(Path.GetDirectoryName(Path.GetFullPath(path)));
                // FULLMUTEX, with read/write/create for recording or read-only for reports.
                Check(Sqlite.sqlite3_open_v2(path, out db, (create ? 6 : 1) | 0x10000, IntPtr.Zero));
                Check(Sqlite.sqlite3_busy_timeout(db, 2000));
                long version = (long)Query("PRAGMA user_version", Array.Empty<object>())[0]["user_version"];
                if (version > 1) throw new InvalidOperationException("Unsupported QuietCli gain database schema.");
                if (create && version == 0) {
                    Execute("BEGIN IMMEDIATE", Array.Empty<object>());
                    try {
                        long foreignTables = (long)Query("SELECT COUNT(*) AS n FROM sqlite_master WHERE type='table' AND name NOT LIKE 'sqlite_%' AND name <> 'quietcli_deliveries'", Array.Empty<object>())[0]["n"];
                        if (foreignTables != 0)
                            throw new InvalidOperationException("Refusing to initialize QuietCli history in an existing unrelated database.");
                        Execute(@"CREATE TABLE IF NOT EXISTS quietcli_deliveries (
                            id TEXT PRIMARY KEY, timestamp_ms INTEGER NOT NULL,
                            command TEXT NOT NULL, outcome TEXT NOT NULL,
                            native_calls INTEGER NOT NULL, measured INTEGER NOT NULL,
                            analysis_complete INTEGER NOT NULL, truncated INTEGER NOT NULL,
                            input_bytes INTEGER NOT NULL, output_bytes INTEGER NOT NULL,
                            input_tokens INTEGER, output_tokens INTEGER, saved_tokens INTEGER,
                            elapsed_ms INTEGER NOT NULL)", Array.Empty<object>());
                        Execute("CREATE INDEX IF NOT EXISTS quietcli_gain_time ON quietcli_deliveries(timestamp_ms)", Array.Empty<object>());
                        Execute("PRAGMA user_version = 1", Array.Empty<object>());
                        Execute("COMMIT", Array.Empty<object>());
                    } catch { Execute("ROLLBACK", Array.Empty<object>()); throw; }
                } else if (!create && version != 1) {
                    throw new InvalidOperationException("Not a supported QuietCli gain database.");
                }
            } catch { Dispose(); throw; }
        }
        void Check(int code) {
            if (code != 0) throw new InvalidOperationException("SQLite " + code + ": " +
                (db == IntPtr.Zero ? "cannot open database" : Marshal.PtrToStringUTF8(Sqlite.sqlite3_errmsg(db))));
        }
        IntPtr Prepare(string sql, object[] values) {
            IntPtr statement = IntPtr.Zero;
            try {
                Check(Sqlite.sqlite3_prepare_v2(db, sql, -1, out statement, IntPtr.Zero));
                for (int i = 0; i < values.Length; i++) {
                    object value = values[i]; int code;
                    if (value == null) code = Sqlite.sqlite3_bind_null(statement, i + 1);
                    else if (value is string text) {
                        byte[] bytes = Encoding.UTF8.GetBytes(text + "\0");
                        code = Sqlite.sqlite3_bind_text(statement, i + 1, bytes, bytes.Length - 1, new IntPtr(-1));
                    } else if (value is double || value is float || value is decimal)
                        code = Sqlite.sqlite3_bind_double(statement, i + 1, Convert.ToDouble(value, CultureInfo.InvariantCulture));
                    else code = Sqlite.sqlite3_bind_int64(statement, i + 1, Convert.ToInt64(value, CultureInfo.InvariantCulture));
                    Check(code);
                }
                return statement;
            } catch { if (statement != IntPtr.Zero) Sqlite.sqlite3_finalize(statement); throw; }
        }
        public void Execute(string sql, object[] values) {
            IntPtr statement = Prepare(sql, values);
            try { int code; do { code = Sqlite.sqlite3_step(statement); } while (code == 100); if (code != 101) Check(code); }
            finally { Sqlite.sqlite3_finalize(statement); }
        }
        public List<Dictionary<string, object>> Query(string sql, object[] values) {
            var rows = new List<Dictionary<string, object>>(); IntPtr statement = Prepare(sql, values);
            try {
                int code;
                while ((code = Sqlite.sqlite3_step(statement)) == 100) {
                    var row = new Dictionary<string, object>();
                    for (int column = 0; column < Sqlite.sqlite3_column_count(statement); column++) {
                        string name = Marshal.PtrToStringUTF8(Sqlite.sqlite3_column_name(statement, column));
                        int type = Sqlite.sqlite3_column_type(statement, column);
                        row[name] = type == 1 ? (object)Sqlite.sqlite3_column_int64(statement, column) :
                            type == 2 ? (object)Sqlite.sqlite3_column_double(statement, column) :
                            type == 5 ? null : Marshal.PtrToStringUTF8(Sqlite.sqlite3_column_text(statement, column));
                    }
                    rows.Add(row);
                }
                if (code != 101) Check(code);
            } finally { Sqlite.sqlite3_finalize(statement); }
            return rows;
        }
        public void Dispose() { if (db != IntPtr.Zero) { Sqlite.sqlite3_close_v2(db); db = IntPtr.Zero; } }
    }
}

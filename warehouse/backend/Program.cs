using Microsoft.Data.SqlClient;
using System.Data;

// Load .env file manually.
// Saat dotnet run, .env biasanya ada di folder backend/current directory.
// Saat publish/Windows Service, .env biasanya ada di AppContext.BaseDirectory.
var envCandidates = new[]
{
    Path.Combine(AppContext.BaseDirectory, ".env"),
    Path.Combine(Directory.GetCurrentDirectory(), ".env")
};
var envPath = envCandidates.FirstOrDefault(File.Exists);
if (envPath != null)
{
    Console.WriteLine($"[ENV] Loading .env from: {envPath}");
    foreach (var line in File.ReadAllLines(envPath))
    {
        if (string.IsNullOrWhiteSpace(line) || line.TrimStart().StartsWith("#"))
            continue;
        var parts = line.Split('=', 2);
        if (parts.Length == 2)
            Environment.SetEnvironmentVariable(parts[0].Trim(), parts[1].Trim());
    }
}
else
{
    Console.WriteLine("[ENV] .env not found. Using environment variables/defaults.");
}

var builder = WebApplication.CreateBuilder(args);

builder.Host.UseWindowsService(options =>
{
    options.ServiceName = "WarehouseApiService";
});

builder.Services.AddCors(options =>
{
    options.AddDefaultPolicy(policy =>
        policy.AllowAnyOrigin().AllowAnyMethod().AllowAnyHeader());
});

var app = builder.Build();
app.UseCors();

// ── API Key middleware ────────────────────────────────────────────
app.Use(async (context, next) =>
{
    // /api/health dikecualikan — digunakan SyncService untuk cek koneksi
    if (context.Request.Path.StartsWithSegments("/api") &&
        !context.Request.Path.StartsWithSegments("/api/health"))
    {
        var apiKey      = context.Request.Headers["x-api-key"].ToString();
        var expectedKey = Environment.GetEnvironmentVariable("API_KEY") ?? "change-me";
        var remote      = context.Connection.RemoteIpAddress?.ToString() ?? "unknown";
        Console.WriteLine($"[AUTH] {remote} → {context.Request.Path} key='{MaskSecret(apiKey)}'");
        if (apiKey != expectedKey)
        {
            Console.WriteLine($"[AUTH] Unauthorized from {remote}");
            context.Response.StatusCode = 401;
            await context.Response.WriteAsJsonAsync(new { error = "Unauthorized" });
            return;
        }
    }
    await next();
});

// ── Health ────────────────────────────────────────────────────────
app.MapGet("/", () => new { status = "ok", message = "Warehouse backend is running" });
// Endpoint health khusus untuk cek koneksi dari Flutter (SyncService)
// Tidak butuh API key agar bisa dicek sebelum auth
app.MapGet("/api/health", () => Results.Ok(new { status = "ok", timestamp = DateTime.UtcNow }))
   .WithName("HealthCheck");
app.MapGet("/api/models",    GetModels).WithName("GetModels");
app.MapGet("/public/models", GetModels).WithName("PublicGetModels");

// ── Entries ───────────────────────────────────────────────────────
app.MapPost("/api/entries", async (HttpRequest req) =>
{
    try
    {
        var payload = await req.ReadFromJsonAsync<EntryDto>();
        if (payload == null || payload.Items == null || payload.Items.Count == 0)
            return Results.BadRequest(new { error = "Invalid payload" });

        var cs = GetWarehouseCs();
        using var conn = new SqlConnection(cs);
        await conn.OpenAsync();
        using var tran = conn.BeginTransaction();

        try
        {
            var insertMaster = new SqlCommand(@"
                INSERT INTO dbo.Entries (EntryDate, ContainerNumber, BookingConfirmation)
                OUTPUT INSERTED.EntryId
                VALUES (@date, @cn, @bc)", conn, tran);

            if (!DateTime.TryParse(payload.Date, out var parsedDate))
                parsedDate = DateTime.Now;

            insertMaster.Parameters.AddWithValue("@date", parsedDate.Date);
            insertMaster.Parameters.AddWithValue("@cn", (object?)payload.ContainerNumber ?? DBNull.Value);
            insertMaster.Parameters.AddWithValue("@bc", (object?)payload.BookingConfirmation ?? DBNull.Value);

            var entryId = Convert.ToInt32(await insertMaster.ExecuteScalarAsync());

            // PENTING:
            // Offline Flutter punya id detail lokal. SQL Server punya DetailId sendiri.
            // Kita balikin mapping clientDetailId -> detailId agar sync scan bisa
            // langsung memakai DetailId SQL yang benar, bukan menebak dari prefix/DO.
            var detailMappings = new List<object>();

            foreach (var it in payload.Items)
            {
                using var insertDetail = new SqlCommand(@"
                    INSERT INTO dbo.EntryDetails
                        (EntryId, Model, ContNo, Destination, DrlNumber, DoText, SerialNumber, Quantity)
                    OUTPUT INSERTED.DetailId
                    VALUES
                        (@entryId, @model, @cont, @dest, @drl, @doText, @serial, @qty)", conn, tran);

                insertDetail.Parameters.AddWithValue("@entryId", entryId);
                insertDetail.Parameters.AddWithValue("@model",  (object?)it.Model        ?? DBNull.Value);
                insertDetail.Parameters.AddWithValue("@cont",   (object?)it.ContNo       ?? DBNull.Value);
                insertDetail.Parameters.AddWithValue("@dest",   (object?)it.Destination  ?? DBNull.Value);
                insertDetail.Parameters.AddWithValue("@drl",    (object?)it.DrlNumber    ?? DBNull.Value);
                insertDetail.Parameters.AddWithValue("@doText", (object?)it.DoText       ?? DBNull.Value);
                insertDetail.Parameters.AddWithValue("@serial", (object?)it.SerialNumber ?? DBNull.Value);
                insertDetail.Parameters.AddWithValue("@qty",    it.Quantity);

                var detailId = Convert.ToInt32(await insertDetail.ExecuteScalarAsync());

                detailMappings.Add(new
                {
                    clientDetailId = it.ClientDetailId,
                    detailId       = detailId,
                    model          = it.Model,
                    doText         = it.DoText,
                    serialNumber   = it.SerialNumber
                });
            }

            await tran.CommitAsync();

            Console.WriteLine($"[ENTRY] ✓ EntryId={entryId} details={detailMappings.Count}");

            return Results.Ok(new
            {
                entryId = entryId,
                details = detailMappings
            });
        }
        catch (Exception ex)
        {
            try { await tran.RollbackAsync(); } catch { }
            Console.WriteLine($"[ENTRY] ✗ Error: {ex.Message}");
            return Results.BadRequest(new { error = ex.Message });
        }
    }
    catch (Exception ex)
    {
        Console.WriteLine($"[ENTRY] ✗ Error outer: {ex.Message}");
        return Results.BadRequest(new { error = ex.Message });
    }
}).WithName("CreateEntry");

app.MapGet("/api/entries", async () =>
{
    var cs = GetWarehouseCs();
    var list = new List<object>();
    try
    {
        using var conn = new SqlConnection(cs);
        await conn.OpenAsync();
        using var cmd = new SqlCommand(
            "SELECT EntryId, EntryDate, ContainerNumber FROM dbo.Entries ORDER BY EntryId DESC", conn);
        using var reader = await cmd.ExecuteReaderAsync();
        while (await reader.ReadAsync())
            list.Add(new
            {
                entryId         = reader.GetInt32(0),
                entryDate       = reader.GetDateTime(1).ToString("yyyy-MM-dd"),
                containerNumber = reader.IsDBNull(2) ? null : reader.GetString(2)
            });
    }
    catch (Exception ex) { return Results.BadRequest(new { error = ex.Message }); }
    return Results.Ok(list);
}).WithName("ListEntries");

app.MapGet("/api/entries/{id}/details", async (int id) =>
{
    var cs = GetWarehouseCs();
    var details = new List<object>();
    try
    {
        using var conn = new SqlConnection(cs);
        await conn.OpenAsync();
        using var cmd = new SqlCommand(@"
            SELECT DetailId, Model, ContNo, Destination, DrlNumber, DoText, SerialNumber, Quantity
            FROM dbo.EntryDetails WHERE EntryId = @id", conn);
        cmd.Parameters.AddWithValue("@id", id);
        using var reader = await cmd.ExecuteReaderAsync();
        while (await reader.ReadAsync())
            details.Add(new
            {
                detailId     = reader.GetInt32(0),
                model        = reader.IsDBNull(1) ? null : reader.GetString(1),
                contNo       = reader.IsDBNull(2) ? null : reader.GetString(2),
                destination  = reader.IsDBNull(3) ? null : reader.GetString(3),
                drlNumber    = reader.IsDBNull(4) ? null : reader.GetString(4),
                doText       = reader.IsDBNull(5) ? null : reader.GetString(5),
                serialNumber = reader.IsDBNull(6) ? null : reader.GetString(6),
                quantity     = reader.IsDBNull(7) ? 0    : reader.GetInt32(7)
            });
    }
    catch (Exception ex) { return Results.BadRequest(new { error = ex.Message }); }
    return Results.Ok(details);
}).WithName("GetEntryDetails");

app.MapPut("/api/details/{id}", async (int id, HttpRequest req) =>
{
    try
    {
        var payload = await req.ReadFromJsonAsync<EntryItemDto>();
        if (payload == null) return Results.BadRequest(new { error = "Invalid payload" });

        var cs = GetWarehouseCs();
        using var conn = new SqlConnection(cs);
        await conn.OpenAsync();
        using var cmd = new SqlCommand(@"
            UPDATE dbo.EntryDetails
            SET Model=@model, ContNo=@cont, Destination=@dest,
                DrlNumber=@drl, DoText=@doText, SerialNumber=@serial, Quantity=@qty
            WHERE DetailId=@id", conn);
        cmd.Parameters.AddWithValue("@model",  (object?)payload.Model        ?? DBNull.Value);
        cmd.Parameters.AddWithValue("@cont",   (object?)payload.ContNo       ?? DBNull.Value);
        cmd.Parameters.AddWithValue("@dest",   (object?)payload.Destination  ?? DBNull.Value);
        cmd.Parameters.AddWithValue("@drl",    (object?)payload.DrlNumber    ?? DBNull.Value);
        cmd.Parameters.AddWithValue("@doText", (object?)payload.DoText       ?? DBNull.Value);
        cmd.Parameters.AddWithValue("@serial", (object?)payload.SerialNumber ?? DBNull.Value);
        cmd.Parameters.AddWithValue("@qty",    payload.Quantity);
        cmd.Parameters.AddWithValue("@id",     id);
        var rows = await cmd.ExecuteNonQueryAsync();
        return Results.Ok(new { updated = rows });
    }
    catch (Exception ex) { return Results.BadRequest(new { error = ex.Message }); }
}).WithName("UpdateDetail");

app.MapGet("/api/details/byModel/{model}", async (string model) =>
{
    var cs = GetWarehouseCs();
    var results = new List<object>();
    try
    {
        using var conn = new SqlConnection(cs);
        await conn.OpenAsync();
        using var cmd = new SqlCommand(@"
            SELECT DetailId, EntryId, Model, ContNo, Destination, DrlNumber, DoText, SerialNumber, Quantity
            FROM dbo.EntryDetails WHERE Model LIKE @m", conn);
        cmd.Parameters.AddWithValue("@m", "%" + model + "%");
        using var reader = await cmd.ExecuteReaderAsync();
        while (await reader.ReadAsync())
            results.Add(new
            {
                detailId     = reader.GetInt32(0),
                entryId      = reader.GetInt32(1),
                model        = reader.IsDBNull(2) ? null : reader.GetString(2),
                contNo       = reader.IsDBNull(3) ? null : reader.GetString(3),
                destination  = reader.IsDBNull(4) ? null : reader.GetString(4),
                drlNumber    = reader.IsDBNull(5) ? null : reader.GetString(5),
                doText       = reader.IsDBNull(6) ? null : reader.GetString(6),
                serialNumber = reader.IsDBNull(7) ? null : reader.GetString(7),
                quantity     = reader.IsDBNull(8) ? 0    : reader.GetInt32(8)
            });
    }
    catch (Exception ex) { return Results.BadRequest(new { error = ex.Message }); }
    return Results.Ok(results);
}).WithName("FindDetailsByModel");

// ── Bookings ──────────────────────────────────────────────────────
app.MapGet("/api/bookings/today", async () =>
{
    var cs = GetWarehouseCs();
    var list = new List<object>();
    try
    {
        using var conn = new SqlConnection(cs);
        await conn.OpenAsync();
        using var cmd = new SqlCommand(@"
            SELECT DISTINCT BookingConfirmation
            FROM dbo.Entries
            WHERE CAST(EntryDate AS DATE) = CAST(GETDATE() AS DATE)
              AND BookingConfirmation IS NOT NULL
              AND BookingConfirmation <> ''
            ORDER BY BookingConfirmation", conn);
        using var r = await cmd.ExecuteReaderAsync();
        while (await r.ReadAsync())
            list.Add(new
            {
                bookingConfirmation = r.IsDBNull(0) ? null : r.GetString(0)
            });
    }
    catch (Exception ex) { return Results.BadRequest(new { error = ex.Message }); }
    return Results.Ok(list);
}).WithName("GetBookingsToday");

// ── Containers ────────────────────────────────────────────────────
app.MapGet("/api/containers/today", async () =>
{
    var cs = GetWarehouseCs();
    var list = new List<object>();
    try
    {
        using var conn = new SqlConnection(cs);
        await conn.OpenAsync();
        using var cmd = new SqlCommand(@"
            SELECT DISTINCT EntryId, ContainerNumber
            FROM dbo.Entries
            WHERE CAST(EntryDate AS DATE) = CAST(GETDATE() AS DATE)
              AND ContainerNumber IS NOT NULL
              AND ContainerNumber <> ''
            ORDER BY ContainerNumber", conn);
        using var r = await cmd.ExecuteReaderAsync();
        while (await r.ReadAsync())
            list.Add(new
            {
                entryId         = r.GetInt32(0),
                containerNumber = r.IsDBNull(1) ? null : r.GetString(1)
            });
    }
    catch (Exception ex) { return Results.BadRequest(new { error = ex.Message }); }
    return Results.Ok(list);
}).WithName("GetContainersToday");

app.MapGet("/api/containers/{containerNumber}/details", async (string containerNumber) =>
{
    var cs = GetWarehouseCs();
    var list = new List<object>();
    try
    {
        using var conn = new SqlConnection(cs);
        await conn.OpenAsync();
        using var cmd = new SqlCommand(@"
            SELECT
                d.DetailId, d.Model, d.SerialNumber, d.Quantity,
                d.ContNo, d.Destination, d.DrlNumber, d.DoText,
                e.EntryId, e.ContainerNumber,
                ISNULL((
                    SELECT COUNT(1) FROM dbo.ScannedItems s
                    WHERE s.EntryDetailId = d.DetailId
                      AND CAST(s.ScannedAt AS DATE) = CAST(GETDATE() AS DATE)
                ), 0) AS ScannedToday
            FROM dbo.EntryDetails d
            JOIN dbo.Entries e ON d.EntryId = e.EntryId
            WHERE e.ContainerNumber = @cn
              AND CAST(e.EntryDate AS DATE) = CAST(GETDATE() AS DATE)
            ORDER BY d.Model", conn);
        cmd.Parameters.AddWithValue("@cn", containerNumber);
        using var r = await cmd.ExecuteReaderAsync();
        while (await r.ReadAsync())
            list.Add(new
            {
                detailId        = r.GetInt32(0),
                model           = r.IsDBNull(1) ? null : r.GetString(1),
                serialNumber    = r.IsDBNull(2) ? null : r.GetString(2),
                quantity        = r.IsDBNull(3) ? 0    : r.GetInt32(3),
                contNo          = r.IsDBNull(4) ? null : r.GetString(4),
                destination     = r.IsDBNull(5) ? null : r.GetString(5),
                drlNumber       = r.IsDBNull(6) ? null : r.GetString(6),
                doText          = r.IsDBNull(7) ? null : r.GetString(7),
                entryId         = r.GetInt32(8),
                containerNumber = r.IsDBNull(9) ? null : r.GetString(9),
                scannedToday    = r.GetInt32(10)
            });
    }
    catch (Exception ex) { return Results.BadRequest(new { error = ex.Message }); }
    return Results.Ok(list);
}).WithName("GetDetailsByContainer");

// ── Batches ───────────────────────────────────────────────────────
app.MapPost("/api/batches", async (HttpRequest req) =>
{
    try
    {
        var body = await new StreamReader(req.Body).ReadToEndAsync();
        var payload = System.Text.Json.JsonSerializer.Deserialize<CreateBatchRequest>(
            body,
            new System.Text.Json.JsonSerializerOptions { PropertyNameCaseInsensitive = true });
        if (payload == null || payload.Items == null || payload.Items.Count == 0)
            return Results.BadRequest(new { error = "Invalid payload" });

        var cs = GetBatchCs();
        using var conn = new SqlConnection(cs);
        await conn.OpenAsync();
        using var tran = conn.BeginTransaction();
        try
        {
            var insertBatchCmd = new SqlCommand(
                "INSERT INTO Batches([Date]) OUTPUT INSERTED.Id VALUES(@date)", conn, tran);
            insertBatchCmd.Parameters.AddWithValue("@date", payload.Date);
            var batchId = Convert.ToInt32(await insertBatchCmd.ExecuteScalarAsync());

            var insertItemCmd = new SqlCommand(@"
                INSERT INTO BatchItems
                    (BatchId, Model, Destination, DRLNumber, DOText, ContNo, Serial, DateRecorded)
                VALUES (@batchId,@model,@destination,@drl,@do,@cont,@serial,@date)",
                conn, tran);
            insertItemCmd.Parameters.Add(new SqlParameter("@batchId",     SqlDbType.Int));
            insertItemCmd.Parameters.Add(new SqlParameter("@model",       SqlDbType.NVarChar, 200));
            insertItemCmd.Parameters.Add(new SqlParameter("@destination", SqlDbType.NVarChar, 200));
            insertItemCmd.Parameters.Add(new SqlParameter("@drl",         SqlDbType.NVarChar, 100));
            insertItemCmd.Parameters.Add(new SqlParameter("@do",          SqlDbType.NVarChar, 100));
            insertItemCmd.Parameters.Add(new SqlParameter("@cont",        SqlDbType.NVarChar, 100));
            insertItemCmd.Parameters.Add(new SqlParameter("@serial",      SqlDbType.NVarChar, 200));
            insertItemCmd.Parameters.Add(new SqlParameter("@date",        SqlDbType.DateTime));

            foreach (var it in payload.Items)
            {
                insertItemCmd.Parameters["@batchId"].Value     = batchId;
                insertItemCmd.Parameters["@model"].Value       = (object?)it.Model        ?? DBNull.Value;
                insertItemCmd.Parameters["@destination"].Value = (object?)it.Destination  ?? DBNull.Value;
                insertItemCmd.Parameters["@drl"].Value         = (object?)it.DRLNumber    ?? DBNull.Value;
                insertItemCmd.Parameters["@do"].Value          = (object?)it.DOText       ?? DBNull.Value;
                insertItemCmd.Parameters["@cont"].Value        = (object?)it.ContNo       ?? DBNull.Value;
                insertItemCmd.Parameters["@serial"].Value      = (object?)it.SerialNumber ?? DBNull.Value;
                insertItemCmd.Parameters["@date"].Value        = payload.Date;
                await insertItemCmd.ExecuteNonQueryAsync();
            }
            await tran.CommitAsync();
            return Results.Ok(new { batchId });
        }
        catch (Exception ex)
        {
            try { await tran.RollbackAsync(); } catch { }
            return Results.BadRequest(new { error = ex.Message });
        }
    }
    catch (Exception ex) { return Results.BadRequest(new { error = ex.Message }); }
});

app.MapGet("/api/batches/{id}/items", async (int id) =>
{
    try
    {
        var cs = GetBatchCs();
        var results = new List<object>();
        using var conn = new SqlConnection(cs);
        await conn.OpenAsync();
        using var cmd = new SqlCommand(@"
            SELECT Id,BatchId,Model,Destination,DRLNumber,DOText,ContNo,Serial,DateRecorded
            FROM BatchItems WHERE BatchId=@batchId ORDER BY Id", conn);
        cmd.Parameters.AddWithValue("@batchId", id);
        using var reader = await cmd.ExecuteReaderAsync();
        while (await reader.ReadAsync())
            results.Add(new
            {
                Id           = reader["Id"],
                BatchId      = reader["BatchId"],
                Model        = reader["Model"],
                Destination  = reader["Destination"],
                DRLNumber    = reader["DRLNumber"],
                DOText       = reader["DOText"],
                ContNo       = reader["ContNo"],
                Serial       = reader["Serial"],
                DateRecorded = reader["DateRecorded"],
            });
        return Results.Ok(results);
    }
    catch (Exception ex) { return Results.BadRequest(new { error = ex.Message }); }
});

// ── SCAN (FIXED - detail-safe) ─────────────────────────────────────────────
// Prinsip fix:
// 1) Flutter boleh kirim ServerDetailId, tapi backend TIDAK langsung percaya begitu saja.
//    ServerDetailId tetap divalidasi terhadap container, DO, dan prefix serial.
// 2) Kalau ServerDetailId salah / stale / milik DO lain, backend fallback ke matching
//    berdasarkan container + doText + prefix.
// 3) Duplicate dan quantity dihitung berdasarkan EntryDetailId, bukan model/container umum.
//    Ini penting untuk kasus 1 container punya beberapa DO dengan model/prefix yang sama.
app.MapPost("/api/scan", async (HttpRequest req) =>
{
    try
    {
        var payload = await req.ReadFromJsonAsync<ScanRequest>();
        if (payload == null || string.IsNullOrWhiteSpace(payload.SerialNumber))
            return Results.BadRequest(new { error = "SerialNumber wajib diisi" });

        var rawSerial = payload.SerialNumber.Trim();
        var cleanedSerial = new string(rawSerial.SkipWhile(c => !char.IsLetterOrDigit(c)).ToArray());
        if (string.IsNullOrWhiteSpace(cleanedSerial))
            cleanedSerial = rawSerial;

        var targetContainer = payload.ContainerNumber?.Trim();
        var targetDoText = payload.DoText?.Trim();

        Console.WriteLine(
            $"[SCAN] Raw='{rawSerial}' Cleaned='{cleanedSerial}' " +
            $"Container='{targetContainer}' DoText='{targetDoText}' ServerDetailId={payload.ServerDetailId?.ToString() ?? "null"}");

        if (string.IsNullOrWhiteSpace(targetContainer))
            return Results.BadRequest(new { error = "Container wajib dipilih sebelum scan" });

        if (string.IsNullOrWhiteSpace(targetDoText))
        {
            Console.WriteLine("[SCAN] ✗ Ditolak: doText kosong");
            return Results.BadRequest(new { error = "DO wajib dipilih sebelum scan. Pastikan aplikasi mengirim doText." });
        }

        var cs = GetWarehouseCs();
        using var conn = new SqlConnection(cs);
        await conn.OpenAsync();

        int matchedDetailId = 0;
        string? matchedModel = null;
        string? matchedPrefix = null;
        int allowedQty = 0;
        string? contNo = null;
        string? destination = null;
        string? drlNumber = null;
        string? doText = null;
        string? matchedContainer = null;

       
        if (payload.ServerDetailId.HasValue && payload.ServerDetailId.Value > 0)
        {
            Console.WriteLine($"[SCAN] FastPath: validasi ServerDetailId={payload.ServerDetailId.Value}");

            using var directCmd = new SqlCommand(@"
                SELECT TOP 1
                    d.DetailId,
                    d.Model,
                    d.SerialNumber,
                    ISNULL(d.Quantity, 0) AS Quantity,
                    d.ContNo,
                    d.Destination,
                    d.DrlNumber,
                    d.DoText,
                    e.ContainerNumber
                FROM dbo.EntryDetails d
                JOIN dbo.Entries e ON d.EntryId = e.EntryId
                WHERE d.DetailId = @detailId
                  AND e.ContainerNumber = @container
                  AND ISNULL(d.DoText, '') = @doText
                  AND d.SerialNumber IS NOT NULL
                  AND d.SerialNumber <> ''
                  AND @input LIKE d.SerialNumber + '%'", conn);

            directCmd.Parameters.AddWithValue("@detailId", payload.ServerDetailId.Value);
            directCmd.Parameters.AddWithValue("@container", targetContainer);
            directCmd.Parameters.AddWithValue("@doText", targetDoText);
            directCmd.Parameters.AddWithValue("@input", cleanedSerial);

            using var r = await directCmd.ExecuteReaderAsync();
            if (await r.ReadAsync())
            {
                matchedDetailId = r.GetInt32(0);
                matchedModel = r.IsDBNull(1) ? "" : r.GetString(1);
                matchedPrefix = r.IsDBNull(2) ? "" : r.GetString(2);
                allowedQty = r.IsDBNull(3) ? 0 : r.GetInt32(3);
                contNo = r.IsDBNull(4) ? null : r.GetString(4);
                destination = r.IsDBNull(5) ? null : r.GetString(5);
                drlNumber = r.IsDBNull(6) ? null : r.GetString(6);
                doText = r.IsDBNull(7) ? null : r.GetString(7);
                matchedContainer = r.IsDBNull(8) ? null : r.GetString(8);
            }

            if (matchedDetailId > 0)
            {
                Console.WriteLine(
                    $"[SCAN] FastPath OK → DetailId={matchedDetailId} Model='{matchedModel}' " +
                    $"Prefix='{matchedPrefix}' DoText='{doText}'");
            }
            else
            {
                Console.WriteLine(
                    $"[SCAN] FastPath INVALID → ServerDetailId={payload.ServerDetailId.Value} " +
                    $"tidak cocok dengan container='{targetContainer}', doText='{targetDoText}', atau prefix serial. Fallback SlowPath.");
            }
        }

        // ── SLOW PATH: matching berdasarkan container + DO + prefix ───────────────
        // Dipakai kalau:
        // - ServerDetailId kosong
        // - ServerDetailId dari SQLite stale / salah mapping
        // - ServerDetailId tidak cocok dengan doText/container/prefix
        if (matchedDetailId == 0)
        {
            Console.WriteLine($"[SCAN] SlowPath: prefix matching serial='{cleanedSerial}' container='{targetContainer}' doText='{targetDoText}'");

            using var checkPrefixCmd = new SqlCommand(@"
                SELECT TOP 1
                    d.DetailId,
                    d.Model,
                    d.SerialNumber,
                    ISNULL(d.Quantity, 0) AS Quantity,
                    d.ContNo,
                    d.Destination,
                    d.DrlNumber,
                    d.DoText,
                    e.ContainerNumber
                FROM dbo.EntryDetails d
                JOIN dbo.Entries e ON d.EntryId = e.EntryId
                WHERE @input LIKE d.SerialNumber + '%'
                  AND d.SerialNumber IS NOT NULL
                  AND d.SerialNumber <> ''
                  AND e.ContainerNumber = @container
                  AND ISNULL(d.DoText, '') = @doText
                  AND CAST(e.EntryDate AS DATE) = CAST(GETDATE() AS DATE)
                ORDER BY
                  CASE
                    WHEN ISNULL(d.Quantity, 0) > (
                        SELECT COUNT(1)
                        FROM dbo.ScannedItems sx
                        WHERE sx.EntryDetailId = d.DetailId
                          AND CAST(sx.ScannedAt AS DATE) = CAST(GETDATE() AS DATE)
                    ) THEN 0 ELSE 1
                  END ASC,
                  LEN(d.SerialNumber) DESC,
                  d.DetailId ASC", conn);

            checkPrefixCmd.Parameters.AddWithValue("@input", cleanedSerial);
            checkPrefixCmd.Parameters.AddWithValue("@container", targetContainer);
            checkPrefixCmd.Parameters.AddWithValue("@doText", targetDoText);

            using var r = await checkPrefixCmd.ExecuteReaderAsync();
            if (await r.ReadAsync())
            {
                matchedDetailId = r.GetInt32(0);
                matchedModel = r.IsDBNull(1) ? "" : r.GetString(1);
                matchedPrefix = r.IsDBNull(2) ? "" : r.GetString(2);
                allowedQty = r.IsDBNull(3) ? 0 : r.GetInt32(3);
                contNo = r.IsDBNull(4) ? null : r.GetString(4);
                destination = r.IsDBNull(5) ? null : r.GetString(5);
                drlNumber = r.IsDBNull(6) ? null : r.GetString(6);
                doText = r.IsDBNull(7) ? null : r.GetString(7);
                matchedContainer = r.IsDBNull(8) ? null : r.GetString(8);

                Console.WriteLine(
                    $"[SCAN] SlowPath OK → DetailId={matchedDetailId} Model='{matchedModel}' " +
                    $"Prefix='{matchedPrefix}' DoText='{doText}'");
            }
        }

        if (matchedDetailId == 0)
        {
            // Diagnostic: cari serial ini cocok di container lain atau DO lain hari ini
            using var diagCmd = new SqlCommand(@"
                SELECT TOP 1
                    e.ContainerNumber,
                    d.DoText,
                    d.Model,
                    d.SerialNumber
                FROM dbo.EntryDetails d
                JOIN dbo.Entries e ON d.EntryId = e.EntryId
                WHERE @input LIKE d.SerialNumber + '%'
                  AND d.SerialNumber IS NOT NULL
                  AND d.SerialNumber <> ''
                  AND CAST(e.EntryDate AS DATE) = CAST(GETDATE() AS DATE)
                ORDER BY LEN(d.SerialNumber) DESC", conn);

            diagCmd.Parameters.AddWithValue("@input", cleanedSerial);

            string? otherContainer = null;
            string? otherDoText = null;
            string? otherModel = null;
            string? otherPrefix = null;

            using (var dr = await diagCmd.ExecuteReaderAsync())
            {
                if (await dr.ReadAsync())
                {
                    otherContainer = dr.IsDBNull(0) ? null : dr.GetString(0);
                    otherDoText = dr.IsDBNull(1) ? null : dr.GetString(1);
                    otherModel = dr.IsDBNull(2) ? null : dr.GetString(2);
                    otherPrefix = dr.IsDBNull(3) ? null : dr.GetString(3);
                }
            }

            Console.WriteLine(
                $"[SCAN] ✗ Tidak match. serial='{cleanedSerial}', container='{targetContainer}', doText='{targetDoText}', " +
                $"otherContainer='{otherContainer}', otherDo='{otherDoText}', otherModel='{otherModel}', otherPrefix='{otherPrefix}'");

            return Results.BadRequest(new
            {
                error = otherContainer != null
                    ? $"Serial ini terdaftar di container '{otherContainer}' DO '{otherDoText}', bukan container '{targetContainer}' DO '{targetDoText}'."
                    : "Serial number tidak dikenali untuk hari ini.",
                serialNumber = cleanedSerial,
                containerNumber = targetContainer,
                doText = targetDoText,
                serverDetailId = payload.ServerDetailId
            });
        }

        // ── Duplicate check: container-wide (lintas DO) ─────────────────────────
        using (var dupCmd = new SqlCommand(@"
            SELECT TOP 1 d.DoText
            FROM dbo.ScannedItems s
            JOIN dbo.EntryDetails d ON s.EntryDetailId = d.DetailId
            JOIN dbo.Entries e ON d.EntryId = e.EntryId
            WHERE s.SerialNumber = @serial
              AND e.ContainerNumber = @container
              AND CAST(s.ScannedAt AS DATE) = CAST(GETDATE() AS DATE)", conn))
        {
            dupCmd.Parameters.AddWithValue("@serial", cleanedSerial);
            dupCmd.Parameters.AddWithValue("@container", targetContainer);
            
            var existingDo = await dupCmd.ExecuteScalarAsync() as string;

            if (existingDo != null)
            {
                var currentDo = doText ?? targetDoText;
                var errMsg = existingDo == currentDo 
                    ? $"Serial number '{cleanedSerial}' sudah pernah discan untuk DO/detail ini hari ini."
                    : $"Serial number '{cleanedSerial}' sudah discan di DO yang berbeda ({existingDo}) dalam kontainer ini.";

                Console.WriteLine($"[SCAN] 409 duplicate → Serial='{cleanedSerial}' ExistingDo='{existingDo}'");
                return Results.Conflict(new
                {
                    error = errMsg,
                    detailId = matchedDetailId,
                    doText = currentDo,
                    containerNumber = targetContainer
                });
            }
        }

        // ── Quantity check: detail-specific ───────────────────────────────────────
        int scannedToday;
        using (var countCmd = new SqlCommand(@"
            SELECT COUNT(1)
            FROM dbo.ScannedItems
            WHERE EntryDetailId = @detailId
              AND CAST(ScannedAt AS DATE) = CAST(GETDATE() AS DATE)", conn))
        {
            countCmd.Parameters.AddWithValue("@detailId", matchedDetailId);
            scannedToday = Convert.ToInt32(await countCmd.ExecuteScalarAsync() ?? 0);
        }

        // allowedQty 0/null dianggap tidak dibatasi, supaya data lama yang qty-nya kosong
        // tidak otomatis menolak semua scan.
        if (allowedQty > 0 && scannedToday >= allowedQty)
        {
            Console.WriteLine(
                $"[SCAN] 422 qty full → DetailId={matchedDetailId}, Model='{matchedModel}', " +
                $"DoText='{doText}', Serial='{cleanedSerial}', scanned={scannedToday}, allowed={allowedQty}");

            return Results.UnprocessableEntity(new
            {
                error = $"Quantity untuk DO '{doText ?? targetDoText}' model '{matchedModel}' sudah terpenuhi. " +
                        $"Sudah discan {scannedToday} dari {allowedQty}.",
                detailId = matchedDetailId,
                model = matchedModel,
                doText = doText ?? targetDoText,
                scannedToday,
                allowedQty
            });
        }

        // ── Insert ────────────────────────────────────────────────────────────────
        using var insertCmd = new SqlCommand(@"
            INSERT INTO dbo.ScannedItems
                (EntryDetailId, Model, SerialNumber, Quantity, ScannedAt,
                 ContNo, Destination, DrlNumber, DoText)
            OUTPUT INSERTED.Id
            VALUES
                (@detailId, @model, @serial, 1, GETDATE(),
                 @contNo, @dest, @drl, @doText)", conn);

        insertCmd.Parameters.AddWithValue("@detailId", matchedDetailId);
        insertCmd.Parameters.AddWithValue("@model", (object?)matchedModel ?? DBNull.Value);
        insertCmd.Parameters.AddWithValue("@serial", cleanedSerial);
        insertCmd.Parameters.AddWithValue("@contNo", (object?)contNo ?? DBNull.Value);
        insertCmd.Parameters.AddWithValue("@dest", (object?)destination ?? DBNull.Value);
        insertCmd.Parameters.AddWithValue("@drl", (object?)drlNumber ?? DBNull.Value);
        insertCmd.Parameters.AddWithValue("@doText", (object?)doText ?? targetDoText ?? (object)DBNull.Value);

        var insertedId = Convert.ToInt32(await insertCmd.ExecuteScalarAsync());

        Console.WriteLine(
            $"[SCAN] ✓ '{cleanedSerial}' → Id={insertedId} DetailId={matchedDetailId} " +
            $"Model='{matchedModel}' DoText='{doText}' Qty={scannedToday + 1}/{allowedQty}");

        return Results.Ok(new
        {
            id = insertedId,
            message = "Scan berhasil",
            model = matchedModel,
            serialNumber = cleanedSerial,
            doText = doText ?? targetDoText,
            detailId = matchedDetailId,
            scannedToday = scannedToday + 1,
            allowedQty
        });
    }
    catch (Exception ex)
    {
        Console.WriteLine($"[SCAN] ✗ Exception: {ex}");
        return Results.BadRequest(new { error = ex.Message });
    }
}).WithName("Scan");

// ── GET scan today ────────────────────────────────────────────────
app.MapGet("/api/scan/today", async () =>
{
    var cs = GetWarehouseCs();
    var list = new List<object>();
    try
    {
        using var conn = new SqlConnection(cs);
        await conn.OpenAsync();
        using var cmd = new SqlCommand(@"
            SELECT
                s.Id, s.Model, s.SerialNumber, s.Quantity, s.ScannedAt,
                d.Quantity AS AllowedQty,
                (
                    SELECT COUNT(1) FROM dbo.ScannedItems sx
                    WHERE sx.EntryDetailId = s.EntryDetailId
                      AND CAST(sx.ScannedAt AS DATE) = CAST(GETDATE() AS DATE)
                ) AS ScannedCount
            FROM dbo.ScannedItems s
            JOIN dbo.EntryDetails d ON s.EntryDetailId = d.DetailId
            WHERE CAST(s.ScannedAt AS DATE) = CAST(GETDATE() AS DATE)
            ORDER BY s.ScannedAt DESC", conn);
        using var r = await cmd.ExecuteReaderAsync();
        while (await r.ReadAsync())
            list.Add(new
            {
                id           = r.GetInt32(0),
                model        = r.IsDBNull(1) ? null : r.GetString(1),
                serialNumber = r.IsDBNull(2) ? null : r.GetString(2),
                quantity     = r.GetInt32(6),   // ScannedCount
                scannedAt    = r.GetDateTime(4).ToString("yyyy-MM-dd HH:mm:ss"),
                allowedQty   = r.GetInt32(5)
            });
    }
    catch (Exception ex) { return Results.BadRequest(new { error = ex.Message }); }
    return Results.Ok(list);
}).WithName("GetScannedToday");

// ── Report ────────────────────────────────────────────────────────
app.MapGet("/api/report", async (string? date, string? containerNumber) =>
{
    var cs = GetWarehouseCs();
    var list = new List<object>();
    try
    {
        using var conn = new SqlConnection(cs);
        await conn.OpenAsync();

        var where = new System.Text.StringBuilder("WHERE 1=1 ");
        if (!string.IsNullOrEmpty(date))
            where.Append("AND CAST(s.ScannedAt AS DATE) = @date ");
        if (!string.IsNullOrEmpty(containerNumber))
            where.Append("AND e.ContainerNumber = @cn ");

        using var cmd = new SqlCommand($@"
            SELECT
                s.Id, s.Model, s.SerialNumber, s.ScannedAt,
                s.ContNo, s.Destination, s.DrlNumber, s.DoText,
                e.ContainerNumber,
                d.Quantity AS AllowedQty,
                (SELECT COUNT(1) FROM dbo.ScannedItems sx
                 WHERE sx.EntryDetailId = s.EntryDetailId
                   AND CAST(sx.ScannedAt AS DATE) = CAST(s.ScannedAt AS DATE)
                ) AS ScannedOnDay
            FROM dbo.ScannedItems s
            JOIN dbo.EntryDetails d ON s.EntryDetailId = d.DetailId
            JOIN dbo.Entries e ON d.EntryId = e.EntryId
            {where}
            ORDER BY s.ScannedAt DESC", conn);

        if (!string.IsNullOrEmpty(date))
            cmd.Parameters.AddWithValue("@date", date);
        if (!string.IsNullOrEmpty(containerNumber))
            cmd.Parameters.AddWithValue("@cn", containerNumber);

        using var r = await cmd.ExecuteReaderAsync();
        while (await r.ReadAsync())
            list.Add(new
            {
                id              = r.GetInt32(0),
                model           = r.IsDBNull(1) ? null : r.GetString(1),
                serialNumber    = r.IsDBNull(2) ? null : r.GetString(2),
                scannedAt       = r.GetDateTime(3).ToString("yyyy-MM-dd HH:mm:ss"),
                contNo          = r.IsDBNull(4) ? null : r.GetString(4),
                destination     = r.IsDBNull(5) ? null : r.GetString(5),
                drlNumber       = r.IsDBNull(6) ? null : r.GetString(6),
                doText          = r.IsDBNull(7) ? null : r.GetString(7),
                containerNumber = r.IsDBNull(8) ? null : r.GetString(8),
                allowedQty      = r.GetInt32(9),
                scannedOnDay    = r.GetInt32(10)
            });
    }
    catch (Exception ex) { return Results.BadRequest(new { error = ex.Message }); }
    return Results.Ok(list);
}).WithName("Report");

// ── PUT / DELETE scan ─────────────────────────────────────────────
app.MapPut("/api/scan/{id}", async (int id, HttpRequest req) =>
{
    try
    {
        var payload = await req.ReadFromJsonAsync<UpdateScanRequest>();
        if (payload == null) return Results.BadRequest(new { error = "Payload tidak valid" });
        var cs = GetWarehouseCs();
        using var conn = new SqlConnection(cs);
        await conn.OpenAsync();
        using var cmd = new SqlCommand(
            "UPDATE dbo.ScannedItems SET SerialNumber=@serial,Quantity=@qty WHERE Id=@id", conn);
        cmd.Parameters.AddWithValue("@serial", payload.SerialNumber ?? (object)DBNull.Value);
        cmd.Parameters.AddWithValue("@qty",    payload.Quantity);
        cmd.Parameters.AddWithValue("@id",     id);
        var rows = await cmd.ExecuteNonQueryAsync();
        return Results.Ok(new { updated = rows });
    }
    catch (Exception ex) { return Results.BadRequest(new { error = ex.Message }); }
}).WithName("UpdateScan");

app.MapDelete("/api/scan/{id}", async (int id) =>
{
    try
    {
        var cs = GetWarehouseCs();
        using var conn = new SqlConnection(cs);
        await conn.OpenAsync();
        using var cmd = new SqlCommand("DELETE FROM dbo.ScannedItems WHERE Id=@id", conn);
        cmd.Parameters.AddWithValue("@id", id);
        var rows = await cmd.ExecuteNonQueryAsync();
        return Results.Ok(new { deleted = rows });
    }
    catch (Exception ex) { return Results.BadRequest(new { error = ex.Message }); }
}).WithName("DeleteScan");

// ── Export by date ────────────────────────────────────────────────
app.MapGet("/api/export", async (string? date, string? containerNumber, string? bookingConfirmation) =>
{
    var cs = GetWarehouseCs();
    var list = new List<object>();
    try
    {
        using var conn = new SqlConnection(cs);
        await conn.OpenAsync();

        var filterDate = string.IsNullOrEmpty(date)
            ? DateTime.Today.ToString("yyyy-MM-dd")
            : date;

        var sql = @"
            SELECT
                s.ScannedAt,
                s.Destination,
                s.DrlNumber,
                s.SerialNumber,
                s.Model,
                s.DoText,
                s.ContNo,
                e.ContainerNumber,
                (SELECT TOP 1 sx.ScannedAt 
                 FROM dbo.ScannedItems sx 
                 WHERE sx.SerialNumber = s.SerialNumber 
                   AND sx.Id < s.Id
                 ORDER BY sx.Id DESC) as PreviousScanDate,
                e.BookingConfirmation,
                CONVERT(VARCHAR(10), o.ProdDate, 120) as ProdDate
            FROM dbo.ScannedItems s
            JOIN dbo.EntryDetails d ON s.EntryDetailId = d.DetailId
            JOIN dbo.Entries      e ON d.EntryId       = e.EntryId
            OUTER APPLY (
                SELECT TOP 1 oo.[Date] as ProdDate
                FROM [PROMOSYS].[dbo].[OEESN] oo
                WHERE LTRIM(RTRIM(s.SerialNumber)) = LTRIM(RTRIM(oo.SN_GOOD)) COLLATE DATABASE_DEFAULT
                ORDER BY oo.[Date] DESC
            ) o
            WHERE CAST(s.ScannedAt AS DATE) = @date";

        if (!string.IsNullOrEmpty(containerNumber))
            sql += " AND e.ContainerNumber = @cn";
            
        if (!string.IsNullOrEmpty(bookingConfirmation))
            sql += " AND e.BookingConfirmation = @bc";

        sql += " ORDER BY s.DoText ASC, s.ScannedAt ASC";

        using var cmd = new SqlCommand(sql, conn);
        cmd.Parameters.AddWithValue("@date", filterDate);
        if (!string.IsNullOrEmpty(containerNumber))
            cmd.Parameters.AddWithValue("@cn", containerNumber);
        if (!string.IsNullOrEmpty(bookingConfirmation))
            cmd.Parameters.AddWithValue("@bc", bookingConfirmation);

        using var r = await cmd.ExecuteReaderAsync();
        while (await r.ReadAsync())
        {
            var prevDateObj = r.IsDBNull(8) ? null : (DateTime?)r.GetDateTime(8);
            string? warningText = prevDateObj != null 
                ? $"WARNING: Pernah discan tgl {prevDateObj.Value:dd-MM-yyyy HH:mm}" 
                : null;

            list.Add(new
            {
                date            = r.GetDateTime(0).ToString("yyyy-MM-dd HH:mm:ss"),
                city            = r.IsDBNull(1) ? null : r.GetString(1),
                drlNumber       = r.IsDBNull(2) ? null : r.GetString(2),
                serialNumber    = r.IsDBNull(3) ? null : r.GetString(3),
                model           = r.IsDBNull(4) ? null : r.GetString(4),
                doText          = r.IsDBNull(5) ? null : r.GetString(5),
                containerNo     = r.IsDBNull(6) ? null : r.GetString(6),
                containerNumber = r.IsDBNull(7) ? null : r.GetString(7),
                warningText     = warningText,
                bookingConfirmation = r.IsDBNull(9) ? null : r.GetString(9),
                prodDate        = r.IsDBNull(10) ? null : r.GetString(10)
            });
        }
    }
    catch (Exception ex) { return Results.BadRequest(new { error = ex.Message }); }
    return Results.Ok(list);
}).WithName("ExportByDate");

// ── Upload file ke network share ──────────────────────────────────
app.MapPost("/api/upload", async (HttpRequest req) =>
{
    try
    {
        var form = await req.ReadFormAsync();
        var file = form.Files.GetFile("file");
        if (file == null) return Results.BadRequest(new { error = "File tidak ada" });

        var sharePath = @"\\137.40.93.11\ac\Internal_Use\MC File\Finished Goods";

        if (!Directory.Exists(sharePath))
        {
            Console.WriteLine($"[UPLOAD] ❌ Folder tidak accessible: {sharePath}");
            return Results.BadRequest(new { error = $"Folder tujuan tidak dapat diakses: {sharePath}" });
        }

        var ext       = Path.GetExtension(file.FileName);
        var baseName  = Path.GetFileNameWithoutExtension(file.FileName);
        var timestamp = DateTime.Now.ToString("yyyyMMdd_HHmmss");
        var fileName  = $"{baseName}_{timestamp}{ext}";
        var destPath  = Path.Combine(sharePath, fileName);

        using var stream = new FileStream(destPath, FileMode.Create);
        await file.CopyToAsync(stream);

        Console.WriteLine($"[UPLOAD] ✅ File saved to {destPath}");
        return Results.Ok(new { message = "Upload berhasil", path = destPath, fileName });
    }
    catch (UnauthorizedAccessException ex)
    {
        Console.WriteLine($"[UPLOAD] ❌ Permission denied: {ex.Message}");
        return Results.BadRequest(new {
            error = "Tidak punya akses ke folder tujuan. Pastikan Windows Service berjalan dengan akun yang punya akses ke network share."
        });
    }
    catch (Exception ex)
    {
        Console.WriteLine($"[UPLOAD] ❌ Error: {ex.Message}");
        return Results.BadRequest(new { error = ex.Message });
    }
}).WithName("UploadToShare");

// ── Startup ───────────────────────────────────────────────────────
_ = EnsureWarehouseTables();
app.Urls.Add($"http://0.0.0.0:{Environment.GetEnvironmentVariable("PORT") ?? "7006"}");
app.Run();

// ═════════════════════════════════════════════════════════════════
string GetConnectionString(string dbEnvKey, string defaultDbName) =>
    $"Server={Env("DB_SERVER", "10.83.33.103")};" +
    $"Database={Env(dbEnvKey, defaultDbName)};" +
    $"User Id={Env("DB_USER", "sa")};" +
    $"Password={Env("DB_PASSWORD", "sa")};" +
    "Encrypt=false;TrustServerCertificate=true;";

string GetWarehouseCs() => GetConnectionString("WAREHOUSE_DB", "WarehouseDB");
string GetBatchCs()     => GetConnectionString("BATCH_DB", "WarehouseDB");
string Env(string key, string fallback) =>
    Environment.GetEnvironmentVariable(key) ?? fallback;

string MaskSecret(string? value)
{
    if (string.IsNullOrEmpty(value)) return "<empty>";
    if (value.Length <= 4) return "****";
    return $"{value[..2]}***{value[^2..]}";
}

// ═════════════════════════════════════════════════════════════════
async Task EnsureWarehouseTables()
{
    try
    {
        using var conn = new SqlConnection(GetWarehouseCs());
        await conn.OpenAsync();
        var sqls = new[]
        {
            @"IF NOT EXISTS (SELECT * FROM sys.objects
                WHERE object_id=OBJECT_ID(N'[dbo].[Entries]') AND type=N'U')
              CREATE TABLE [dbo].[Entries] (
                [EntryId]         INT IDENTITY(1,1) NOT NULL PRIMARY KEY,
                [EntryDate]       DATE NOT NULL,
                [ContainerNumber] NVARCHAR(256) NULL
              )",
            @"IF COL_LENGTH('dbo.Entries', 'BookingConfirmation') IS NULL
              ALTER TABLE dbo.Entries ADD BookingConfirmation NVARCHAR(256) NULL",
            @"IF NOT EXISTS (SELECT * FROM sys.columns
                WHERE object_id=OBJECT_ID(N'dbo.Entries') AND name='ContainerNumber')
              ALTER TABLE dbo.Entries ADD ContainerNumber NVARCHAR(256) NULL",
            @"IF NOT EXISTS (SELECT * FROM sys.objects
                WHERE object_id=OBJECT_ID(N'[dbo].[EntryDetails]') AND type=N'U')
              CREATE TABLE [dbo].[EntryDetails] (
                [DetailId]     INT IDENTITY(1,1) NOT NULL PRIMARY KEY,
                [EntryId]      INT NOT NULL,
                [Model]        NVARCHAR(256) NULL,
                [ContNo]       NVARCHAR(256) NULL,
                [Destination]  NVARCHAR(256) NULL,
                [DrlNumber]    NVARCHAR(128) NULL,
                [DoText]       NVARCHAR(256) NULL,
                [SerialNumber] NVARCHAR(256) NULL,
                [Quantity]     INT NULL,
                CONSTRAINT FK_EntryDetails_Entries
                    FOREIGN KEY (EntryId) REFERENCES dbo.Entries(EntryId) ON DELETE CASCADE
              )",
            @"IF NOT EXISTS (SELECT * FROM sys.objects
                WHERE object_id=OBJECT_ID(N'[dbo].[ScannedItems]') AND type=N'U')
              CREATE TABLE [dbo].[ScannedItems] (
                [Id]            INT IDENTITY(1,1) NOT NULL PRIMARY KEY,
                [EntryDetailId] INT NOT NULL,
                [Model]         NVARCHAR(256) NULL,
                [SerialNumber]  NVARCHAR(256) NOT NULL,
                [Quantity]      INT NOT NULL DEFAULT 1,
                [ScannedAt]     DATETIME NOT NULL DEFAULT GETDATE(),
                [ContNo]        NVARCHAR(256) NULL,
                [Destination]   NVARCHAR(256) NULL,
                [DrlNumber]     NVARCHAR(128) NULL,
                [DoText]        NVARCHAR(256) NULL,
                CONSTRAINT FK_ScannedItems_EntryDetails
                    FOREIGN KEY (EntryDetailId)
                    REFERENCES dbo.EntryDetails(DetailId) ON DELETE CASCADE
              )",
            @"IF NOT EXISTS (SELECT * FROM sys.columns
                WHERE object_id=OBJECT_ID(N'dbo.ScannedItems') AND name='ContNo')
              ALTER TABLE dbo.ScannedItems ADD
                ContNo      NVARCHAR(256) NULL,
                Destination NVARCHAR(256) NULL,
                DrlNumber   NVARCHAR(128) NULL,
                DoText      NVARCHAR(256) NULL",
        };

        foreach (var sql in sqls)
        {
            using var cmd = new SqlCommand(sql, conn);
            await cmd.ExecuteNonQueryAsync();
        }
        Console.WriteLine("[DB] Tables ensured OK.");
    }
    catch (Exception ex)
    {
        Console.WriteLine($"[DB] Error: {ex.Message}");
    }
}

// ═════════════════════════════════════════════════════════════════
async Task<IResult> GetModels()
{
    try
    {
        var cs = GetConnectionString("DB_DATABASE", "promosys");
        var models = new List<dynamic>();
        using var conn = new SqlConnection(cs);
        await conn.OpenAsync();
        using var cmd = new SqlCommand(@"
            SELECT TOP 1000
                [Product_Id],[Marking],[ProductName],[MachineCode],
                [Description],[ProdPlan],[SUT],[NoOfOperator],
                [QtyHour],[ProdHeadHour],[CycleTimeVacum],[WorkHour]
            FROM [PROMOSYS].[dbo].[MasterData]", conn);
        using var r = await cmd.ExecuteReaderAsync();
        while (await r.ReadAsync())
            models.Add(new
            {
                Product_Id     = r["Product_Id"],
                Marking        = r["Marking"],
                ProductName    = r["ProductName"],
                MachineCode    = r["MachineCode"],
                Description    = r["Description"],
                ProdPlan       = r["ProdPlan"],
                SUT            = r["SUT"],
                NoOfOperator   = r["NoOfOperator"],
                QtyHour        = r["QtyHour"],
                ProdHeadHour   = r["ProdHeadHour"],
                CycleTimeVacum = r["CycleTimeVacum"],
                WorkHour       = r["WorkHour"]
            });
        return Results.Ok(models);
    }
    catch (Exception ex) { return Results.BadRequest(new { error = ex.Message }); }
}

// ═════════════════════════════════════════════════════════════════
// DTOs
// ═════════════════════════════════════════════════════════════════
public class EntryItemDto
{
    public int?    ClientDetailId { get; set; }
    public string? Model        { get; set; }
    public string? ContNo       { get; set; }
    public string? Destination  { get; set; }
    public string? DrlNumber    { get; set; }
    public string? DoText       { get; set; }
    public string? SerialNumber { get; set; }
    public int     Quantity     { get; set; }
}

public class EntryDto
{
    public string?             Date                { get; set; }
    public string?             ContainerNumber     { get; set; }
    public string?             BookingConfirmation { get; set; }
    public List<EntryItemDto>? Items               { get; set; }
}

public class BatchItemDto
{
    public string? Model        { get; set; }
    public string? Destination  { get; set; }
    public string? DRLNumber    { get; set; }
    public string? DOText       { get; set; }
    public string? ContNo       { get; set; }
    public string? SerialNumber { get; set; }
}

public class CreateBatchRequest
{
    public DateTime            Date  { get; set; }
    public List<BatchItemDto>? Items { get; set; }
}

// FIX: Tambah ServerDetailId agar sync dari Flutter bisa bypass prefix matching
public class ScanRequest
{
    public string? SerialNumber    { get; set; }
    public string? ContainerNumber { get; set; }
    public string? DoText          { get; set; }
    public int?    ServerDetailId  { get; set; } // ← TAMBAH: skip prefix matching saat sync
}

public class UpdateScanRequest
{
    public string? SerialNumber { get; set; }
    public int     Quantity     { get; set; }
}

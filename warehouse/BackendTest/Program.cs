using System;
using Microsoft.Data.Sqlite;
using System.IO;

class Program
{
    static void Main()
    {
        string dbFile = "test.db";
        if (File.Exists(dbFile)) File.Delete(dbFile);

        using var conn = new SqliteConnection($"Data Source={dbFile}");
        conn.Open();

        var initCmd = conn.CreateCommand();
        initCmd.CommandText = @"
            CREATE TABLE Entries (
                EntryId INTEGER PRIMARY KEY AUTOINCREMENT,
                EntryDate TEXT,
                ContainerNumber TEXT
            );
            CREATE TABLE EntryDetails (
                DetailId INTEGER PRIMARY KEY AUTOINCREMENT,
                EntryId INTEGER,
                DoText TEXT,
                SerialNumber TEXT,
                Quantity INTEGER
            );
            CREATE TABLE ScannedItems (
                ScannedItemId INTEGER PRIMARY KEY AUTOINCREMENT,
                EntryDetailId INTEGER,
                SerialNumber TEXT,
                ScannedAt TEXT DEFAULT CURRENT_TIMESTAMP
            );

            INSERT INTO Entries (EntryId, EntryDate, ContainerNumber) VALUES (1, date('now', 'localtime'), 'C1');
            INSERT INTO EntryDetails (DetailId, EntryId, DoText, SerialNumber, Quantity) VALUES (1, 1, 'D1', '123', 30);
            INSERT INTO EntryDetails (DetailId, EntryId, DoText, SerialNumber, Quantity) VALUES (2, 1, 'D2', '123', 30);
            INSERT INTO EntryDetails (DetailId, EntryId, DoText, SerialNumber, Quantity) VALUES (3, 1, 'D3', '123', 30);
        ";
        initCmd.ExecuteNonQuery();

        string input = "123%123";
        string targetContainer = "C1";
        string targetDoText = "D3";

        Console.WriteLine($"\n--- SCENARIO: SCAN '{input}' in DO '{targetDoText}' ---");

        // 1. SlowPath
        using var matchCmd = conn.CreateCommand();
        matchCmd.CommandText = @"
            SELECT d.DetailId, d.Quantity
            FROM EntryDetails d
            JOIN Entries e ON d.EntryId = e.EntryId
            WHERE @input LIKE d.SerialNumber || '%'
              AND d.SerialNumber IS NOT NULL
              AND d.SerialNumber <> ''
              AND e.ContainerNumber = @container
              AND IFNULL(d.DoText, '') = @doText
              AND date(e.EntryDate) = date('now','localtime')
            ORDER BY
              CASE
                WHEN IFNULL(d.Quantity, 0) > (
                    SELECT COUNT(1)
                    FROM ScannedItems sx
                    WHERE sx.EntryDetailId = d.DetailId
                      AND date(sx.ScannedAt) = date('now','localtime')
                ) THEN 0 ELSE 1
              END ASC,
              LENGTH(d.SerialNumber) DESC,
              d.DetailId ASC
            LIMIT 1
        ";
        matchCmd.Parameters.AddWithValue("@input", input);
        matchCmd.Parameters.AddWithValue("@container", targetContainer);
        matchCmd.Parameters.AddWithValue("@doText", targetDoText);

        int matchedDetailId = 0;
        using (var reader = matchCmd.ExecuteReader())
        {
            if (reader.Read())
            {
                matchedDetailId = reader.GetInt32(0);
                Console.WriteLine($"[SLOWPATH] Match DetailId = {matchedDetailId}");
            }
        }

        if (matchedDetailId == 0)
        {
            Console.WriteLine("[SLOWPATH] Failed to find match. Going to DiagCmd.");
            
            using var diagCmd = conn.CreateCommand();
            diagCmd.CommandText = @"
                SELECT 
                    e.ContainerNumber,
                    d.DoText,
                    d.SerialNumber
                FROM EntryDetails d
                JOIN Entries e ON d.EntryId = e.EntryId
                WHERE @input LIKE d.SerialNumber || '%'
                  AND d.SerialNumber IS NOT NULL
                  AND d.SerialNumber <> ''
                  AND date(e.EntryDate) = date('now','localtime')
                ORDER BY LENGTH(d.SerialNumber) DESC
                LIMIT 1
            ";
            diagCmd.Parameters.AddWithValue("@input", input);
            using var reader = diagCmd.ExecuteReader();
            if (reader.Read())
            {
                var otherContainer = reader.GetString(0);
                var otherDoText = reader.GetString(1);
                Console.WriteLine($"[DIAG] Serial ini terdaftar di container '{otherContainer}' DO '{otherDoText}', bukan container '{targetContainer}' DO '{targetDoText}'.");
            }
        }
        else
        {
            Console.WriteLine($"[SUCCESS] Proceeding to duplicate check for DetailId {matchedDetailId}...");
        }

    }
}

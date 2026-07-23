-- init_tables.sql
-- Creates WarehouseDB and required tables for Entries/EntryDetails and Batches/BatchItems
-- Run this on your SQL Server (e.g., in SSMS) as a user with sufficient privileges.

IF NOT EXISTS(SELECT 1 FROM sys.databases WHERE name = 'WarehouseDB')
BEGIN
    PRINT 'Creating database WarehouseDB';
    CREATE DATABASE WarehouseDB;
END
GO

USE WarehouseDB;
GO

-- Entries (header table)
IF NOT EXISTS (SELECT * FROM sys.objects WHERE object_id = OBJECT_ID(N'[dbo].[Entries]') AND type in (N'U'))
BEGIN
    CREATE TABLE [dbo].[Entries](
        [EntryId] INT IDENTITY(1,1) NOT NULL PRIMARY KEY,
        [EntryDate] DATE NOT NULL
    );
    PRINT 'Created table dbo.Entries';
END
GO

-- EntryDetails (child records linked to Entries.EntryId)
IF NOT EXISTS (SELECT * FROM sys.objects WHERE object_id = OBJECT_ID(N'[dbo].[EntryDetails]') AND type in (N'U'))
BEGIN
    CREATE TABLE [dbo].[EntryDetails](
        [DetailId] INT IDENTITY(1,1) NOT NULL PRIMARY KEY,
        [EntryId] INT NOT NULL,
        [Model] NVARCHAR(256) NULL,
        [ContNo] NVARCHAR(256) NULL,
        [Destination] NVARCHAR(256) NULL,
        [DrlNumber] NVARCHAR(128) NULL,
        [DoText] NVARCHAR(256) NULL,
        [SerialNumber] NVARCHAR(256) NULL,
        [Quantity] INT NULL,
        CONSTRAINT FK_EntryDetails_Entries FOREIGN KEY (EntryId) REFERENCES dbo.Entries(EntryId) ON DELETE CASCADE
    );
    CREATE INDEX IX_EntryDetails_Model ON dbo.EntryDetails(Model);
    PRINT 'Created table dbo.EntryDetails and index IX_EntryDetails_Model';
END
GO

-- Batches (alternate header table)
IF NOT EXISTS (SELECT * FROM sys.objects WHERE object_id = OBJECT_ID(N'[dbo].[Batches]') AND type in (N'U'))
BEGIN
    CREATE TABLE [dbo].[Batches](
        [Id] INT IDENTITY(1,1) NOT NULL PRIMARY KEY,
        [Date] DATETIME NOT NULL DEFAULT(GETDATE())
    );
    PRINT 'Created table dbo.Batches';
END
GO

-- BatchItems (child records linked to Batches.Id)
IF NOT EXISTS (SELECT * FROM sys.objects WHERE object_id = OBJECT_ID(N'[dbo].[BatchItems]') AND type in (N'U'))
BEGIN
    CREATE TABLE [dbo].[BatchItems](
        [Id] INT IDENTITY(1,1) NOT NULL PRIMARY KEY,
        [BatchId] INT NOT NULL,
        [Model] NVARCHAR(200) NULL,
        [Destination] NVARCHAR(200) NULL,
        [DRLNumber] NVARCHAR(100) NULL,
        [DOText] NVARCHAR(100) NULL,
        [ContNo] NVARCHAR(100) NULL,
        [Serial] NVARCHAR(200) NULL,
        [DateRecorded] DATETIME NOT NULL DEFAULT(GETDATE()),
        CONSTRAINT FK_BatchItems_Batches FOREIGN KEY (BatchId) REFERENCES dbo.Batches(Id) ON DELETE CASCADE
    );
    CREATE INDEX IX_BatchItems_Model ON dbo.BatchItems(Model);
    PRINT 'Created table dbo.BatchItems and index IX_BatchItems_Model';
END
GO

-- Example: how to insert a header + multiple details in one transaction (T-SQL sample)
--
-- BEGIN TRANSACTION;
-- DECLARE @entryId INT;
-- INSERT INTO dbo.Entries (EntryDate) VALUES (CONVERT(date, GETDATE()));
-- SET @entryId = SCOPE_IDENTITY();
-- INSERT INTO dbo.EntryDetails (EntryId, Model, ContNo, Destination, DrlNumber, DoText, SerialNumber, Quantity)
-- VALUES (@entryId, 'MODEL-1', 'CONT-123', 'DEST', '12345', 'DO123', 'SERIAL-001', 1),
--        (@entryId, 'MODEL-2', 'CONT-124', 'DEST', '12346', 'DO124', 'SERIAL-002', 1);
-- COMMIT TRANSACTION;
--
-- Example: simple SELECTs
-- SELECT TOP 100 * FROM dbo.Entries ORDER BY EntryId DESC;
-- SELECT * FROM dbo.EntryDetails WHERE EntryId = @entryId;

PRINT 'init_tables.sql completed.';

/*
05. A fact table exhausts the int IDENTITY key range.
Assumption: "More than two billion identifiers is so many that this table will
never reach the int limit."

BUSINESS SCENARIO
A data warehouse records one fact for every sales line. Volume is initially
low, but stores, an online channel, and more granular events are added over
time. After many years, FactSaleID reaches 2,147,483,647.

AdventureWorks has no table with over two billion rows. The synthetic
dbo.DemoFactSale represents a typical fact table, and seed 2,147,483,645 merely
compresses its multi-year growth into three INSERTs.

PROBLEM AND CAUSE
The largest int value is 2,147,483,647. Once the IDENTITY counter reaches that
limit, the next INSERT fails with error 8115. Changing a column to bigint in a
large table may require a long lock, additional space, and transaction-log growth.
Consider foreign keys, indexes, procedures, and types used by applications as well.

SOLUTION
Create an empty table with the same schema but a bigint key and an IDENTITY seed
of 2,147,483,648. Rename the old table and create a view using its former name
that joins both sets with UNION ALL. The identifier ranges do not overlap, so
duplicate removal is unnecessary.

A view containing UNION ALL is not directly writable. An INSTEAD OF INSERT trigger
sends new facts to the bigint table, so the loading process still uses the name
dbo.DemoFactSale. Separately check applications expecting SCOPE_IDENTITY(): the
INSERT runs in the trigger, which is a different scope.

A separate process moves history in small batches. IDENTITY_INSERT preserves the
old fact numbers, and one transaction covers copying and deleting the same batch.
After emptying the archive, remove the view and trigger, then give the bigint table
the original name.

In production, recreate and verify foreign keys, indexes, constraints, triggers,
permissions, statistics, replication, and parameter types before cutover. The demo
focuses on continuity of identifiers and reads.

CHECKLIST
- What is last_value, and when will the present write rate reach the limit?
- Can every dependency and client store bigint?
- Where do new INSERTs go while history is being moved?
- Do consumers use SCOPE_IDENTITY(), OUTPUT, or expect a base table?
- Is every batch copied and deleted atomically, without gaps or duplicates?
- How will row counts, checksums, and ID ranges be verified before cutover?
- How long should the compatibility layer exist, and what is the final cutover plan?

RUN: SQL Server 2016+, any demo database.
Sources:
https://thevikingdba.blogspot.com/2026/08/running-out-of-int-v.html Brian McMeans
https://learn.microsoft.com/sql/t-sql/statements/create-table-transact-sql-identity-property
https://learn.microsoft.com/sql/t-sql/statements/create-view-transact-sql#updatable-views
https://learn.microsoft.com/sql/t-sql/statements/set-identity-insert-transact-sql
*/

SET NOCOUNT ON;
SET XACT_ABORT ON;
GO

/*
clean up
*/
DROP TRIGGER IF EXISTS dbo.DemoFactSale_Insert;
DROP PROCEDURE IF EXISTS dbo.DemoMigrateFactSaleBatch;

IF OBJECT_ID(N'dbo.DemoFactSale', N'V') IS NOT NULL
    DROP VIEW dbo.DemoFactSale;

IF OBJECT_ID(N'dbo.DemoFactSale', N'U') IS NOT NULL
    DROP TABLE dbo.DemoFactSale;

DROP TABLE IF EXISTS dbo.DemoFactSale_IntArchive;
DROP TABLE IF EXISTS dbo.DemoFactSale_Bigint;
GO

/*
Initial state: the fact table still uses int. A seed near the limit simulates
years of identifier consumption without creating billions of rows.
*/
CREATE TABLE dbo.DemoFactSale
(
    FactSaleID int IDENTITY(2147483645, 1) NOT NULL
        CONSTRAINT PK_DemoFactSale_Int PRIMARY KEY,
    OrderDateKey int NOT NULL,
    StoreKey int NOT NULL,
    ProductKey int NOT NULL,
    Quantity smallint NOT NULL,
    SalesAmount decimal(12, 2) NOT NULL
);
GO

INSERT INTO dbo.DemoFactSale
    (OrderDateKey, StoreKey, ProductKey, Quantity, SalesAmount)
VALUES
    (20260913, 11, 706, 1, 1399.00),
    (20260914, 24, 870, 2, 109.98),
    (20260915, 11, 782, 1, 2294.99);
GO

SELECT
    COUNT_BIG(*) AS FactRows,
    MAX(FactSaleID) AS MaximumFactSaleID,
    CONVERT(bigint, i.last_value) AS LastGeneratedIdentity,
    CONVERT(bigint, 2147483647) - CONVERT(bigint, i.last_value)
        AS RemainingIdentityValues
FROM dbo.DemoFactSale AS f
CROSS JOIN sys.identity_columns AS i
WHERE i.object_id = OBJECT_ID(N'dbo.DemoFactSale')
GROUP BY i.last_value;
GO

/*
FAILURE
The table reached the largest int value. Another fact cannot be stored.
*/
BEGIN TRY
    INSERT INTO dbo.DemoFactSale
        (OrderDateKey, StoreKey, ProductKey, Quantity, SalesAmount)
    VALUES
        (20260915, 18, 897, 1, 699.00);

    SELECT N'UNEXPECTED SUCCESS' AS Result;
END TRY
BEGIN CATCH
    SELECT
        N'EXPECTED ERROR' AS Result,
        ERROR_NUMBER() AS ErrorNumber,
        ERROR_MESSAGE() AS ErrorMessage;
END CATCH;
GO

/*
FIX — STEP 1
The new table starts its IDENTITY values at the first number beyond the maximum
int value. Old and new identifiers cannot collide.
*/
CREATE TABLE dbo.DemoFactSale_Bigint
(
    FactSaleID bigint IDENTITY(2147483648, 1) NOT NULL
        CONSTRAINT PK_DemoFactSale_Bigint PRIMARY KEY,
    OrderDateKey int NOT NULL,
    StoreKey int NOT NULL,
    ProductKey int NOT NULL,
    Quantity smallint NOT NULL,
    SalesAmount decimal(12, 2) NOT NULL
);
GO

/*
FIX — STEP 2
The old table receives a technical name. The view takes its old name, so queries
reading history do not need to join two objects themselves.
*/
EXEC sys.sp_rename
    @objname = N'dbo.DemoFactSale',
    @newname = N'DemoFactSale_IntArchive',
    @objtype = N'OBJECT';
GO

CREATE VIEW dbo.DemoFactSale
AS
    SELECT
        CONVERT(bigint, FactSaleID) AS FactSaleID,
        OrderDateKey,
        StoreKey,
        ProductKey,
        Quantity,
        SalesAmount
    FROM dbo.DemoFactSale_IntArchive

    UNION ALL

    SELECT
        FactSaleID,
        OrderDateKey,
        StoreKey,
        ProductKey,
        Quantity,
        SalesAmount
    FROM dbo.DemoFactSale_Bigint;
GO

/*
FIX — STEP 3
UNION ALL prevents a normal INSERT into the view. The trigger retains the target
name used by the loading process and sends every new fact to the bigint table.
Providing FactSaleID explicitly remains forbidden in the regular load process.
*/
CREATE TRIGGER dbo.DemoFactSale_Insert
ON dbo.DemoFactSale
INSTEAD OF INSERT
AS
BEGIN
    SET NOCOUNT ON;

    IF EXISTS
    (
        SELECT 1
        FROM inserted
        WHERE FactSaleID IS NOT NULL
    )
        THROW 51005, N'FactSaleID is generated automatically and cannot be supplied in INSERT.', 1;

    INSERT INTO dbo.DemoFactSale_Bigint
        (OrderDateKey, StoreKey, ProductKey, Quantity, SalesAmount)
    SELECT
        OrderDateKey,
        StoreKey,
        ProductKey,
        Quantity,
        SalesAmount
    FROM inserted;
END;
GO

/*
The loading process still writes through the original name. The new fact receives
identifier 2,147,483,648, which the old int column could not store.
*/
INSERT INTO dbo.DemoFactSale
    (OrderDateKey, StoreKey, ProductKey, Quantity, SalesAmount)
VALUES
    (20260915, 18, 897, 1, 699.00);
GO

SELECT
    FactSaleID,
    OrderDateKey,
    StoreKey,
    ProductKey,
    Quantity,
    SalesAmount
FROM dbo.DemoFactSale
ORDER BY FactSaleID;
GO

/*
FIX — STEP 4
A separate procedure moves one batch and returns its size. In production, a
recurring job can call it. Update locks protect the selected batch from a concurrent
migration process, and the transaction covers copying and deletion.
*/
CREATE PROCEDURE dbo.DemoMigrateFactSaleBatch
    @BatchSize int,
    @RowsMigrated int OUTPUT
AS
BEGIN
    SET NOCOUNT ON;
    SET XACT_ABORT ON;

    IF @BatchSize <= 0
        THROW 51008, N'Batch size must be greater than zero.', 1;

    CREATE TABLE #MigrationBatch
    (
        FactSaleID int NOT NULL PRIMARY KEY
    );

    SET @RowsMigrated = 0;

    BEGIN TRY
        BEGIN TRANSACTION;

        INSERT INTO #MigrationBatch (FactSaleID)
        SELECT TOP (@BatchSize) FactSaleID
        FROM dbo.DemoFactSale_IntArchive WITH (UPDLOCK, READPAST, ROWLOCK)
        ORDER BY FactSaleID;

        SET @RowsMigrated = @@ROWCOUNT;

        IF @RowsMigrated > 0
        BEGIN
            SET IDENTITY_INSERT dbo.DemoFactSale_Bigint ON;

            INSERT INTO dbo.DemoFactSale_Bigint
                (FactSaleID, OrderDateKey, StoreKey, ProductKey, Quantity, SalesAmount)
            SELECT
                old.FactSaleID,
                old.OrderDateKey,
                old.StoreKey,
                old.ProductKey,
                old.Quantity,
                old.SalesAmount
            FROM dbo.DemoFactSale_IntArchive AS old
            JOIN #MigrationBatch AS batch
                ON batch.FactSaleID = old.FactSaleID;

            SET IDENTITY_INSERT dbo.DemoFactSale_Bigint OFF;

            DELETE old
            FROM dbo.DemoFactSale_IntArchive AS old
            JOIN #MigrationBatch AS batch
                ON batch.FactSaleID = old.FactSaleID;
        END;

        COMMIT TRANSACTION;
    END TRY
    BEGIN CATCH
        IF XACT_STATE() <> 0
            ROLLBACK TRANSACTION;

        BEGIN TRY
            SET IDENTITY_INSERT dbo.DemoFactSale_Bigint OFF;
        END TRY
        BEGIN CATCH
        END CATCH;

        THROW;
    END CATCH;
END;
GO

/*
The job calls the procedure until the old table is empty. A two-row batch is
used only to show several runs in the demo. Choose a production size based on
lock duration, load, and transaction-log capacity.
*/
DECLARE @RowsMigrated int = 1;

WHILE @RowsMigrated > 0
BEGIN
    EXEC dbo.DemoMigrateFactSaleBatch
        @BatchSize = 2,
        @RowsMigrated = @RowsMigrated OUTPUT;

    IF @RowsMigrated > 0
        SELECT
            @RowsMigrated AS MigratedInBatch,
            (SELECT COUNT_BIG(*) FROM dbo.DemoFactSale_IntArchive) AS RowsLeftInArchive,
            (SELECT COUNT_BIG(*) FROM dbo.DemoFactSale_Bigint) AS RowsInBigintTable;
END;
GO

/*
New writes can continue during migration. The bigint generator retains its own
last value; copying lower explicit IDs does not cause a collision.
*/
INSERT INTO dbo.DemoFactSale
    (OrderDateKey, StoreKey, ProductKey, Quantity, SalesAmount)
VALUES
    (20260915, 24, 870, 3, 164.97);
GO

SELECT
    (SELECT COUNT_BIG(*) FROM dbo.DemoFactSale_IntArchive) AS RowsLeftInArchive,
    (SELECT COUNT_BIG(*) FROM dbo.DemoFactSale) AS RowsVisibleUnderOriginalName,
    MIN(FactSaleID) AS MinimumPreservedID,
    MAX(FactSaleID) AS MaximumGeneratedID
FROM dbo.DemoFactSale;

IF EXISTS (SELECT 1 FROM dbo.DemoFactSale_IntArchive)
    THROW 51006, N'The migration process did not empty the old table.', 1;

IF NOT EXISTS
(
    SELECT 1
    FROM dbo.DemoFactSale_Bigint
    WHERE FactSaleID = CONVERT(bigint, 2147483645)
)
    THROW 51007, N'The migrated fact identifier was not preserved.', 1;
GO

/*
FIX — STEP 5
After migration completes and is reconciled, remove the compatibility layer.
The bigint table takes the original name, and the next INSERT works without a trigger.
*/
DROP TRIGGER dbo.DemoFactSale_Insert;
DROP PROCEDURE dbo.DemoMigrateFactSaleBatch;
DROP VIEW dbo.DemoFactSale;
DROP TABLE dbo.DemoFactSale_IntArchive;

EXEC sys.sp_rename
    @objname = N'dbo.DemoFactSale_Bigint',
    @newname = N'DemoFactSale',
    @objtype = N'OBJECT';
GO

INSERT INTO dbo.DemoFactSale
    (OrderDateKey, StoreKey, ProductKey, Quantity, SalesAmount)
VALUES
    (20260915, 11, 706, 2, 2798.00);
GO

SELECT
    TYPE_NAME(c.system_type_id) AS FactSaleIDType,
    i.seed_value AS IdentitySeed,
    i.last_value AS LastGeneratedIdentity
FROM sys.columns AS c
JOIN sys.identity_columns AS i
    ON i.object_id = c.object_id
   AND i.column_id = c.column_id
WHERE c.object_id = OBJECT_ID(N'dbo.DemoFactSale')
  AND c.name = N'FactSaleID';

SELECT
    FactSaleID,
    OrderDateKey,
    StoreKey,
    ProductKey,
    Quantity,
    SalesAmount
FROM dbo.DemoFactSale
ORDER BY FactSaleID;
GO

/*
clean up
*/
DROP TABLE IF EXISTS dbo.DemoFactSale;
GO

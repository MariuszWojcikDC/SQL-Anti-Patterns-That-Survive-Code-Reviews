/*
01. SELECT INTO carries over IDENTITY even when the table looks like an ordinary copy.
Assumption: "SELECT INTO copies columns and data, but not additional column
properties from the source."

BUSINESS SCENARIO
An integration loads a procedure's result into a staging table created by an
empty SELECT. dbo.DemoOrderData returns three columns from Sales.SalesOrderHeader
in AdventureWorks, and INSERT ... EXEC writes them to the staging table.

PROBLEM AND CAUSE
Selecting SalesOrderID directly carries its IDENTITY property through SELECT INTO.
INSERT ... EXEC without a column list receives three values, but the target has
only two ordinary writable columns. The visible column count is not the insert contract.

SOLUTION
Create the table explicitly without IDENTITY, using agreed types, and specify an
INSERT column list. SalesOrderID + 0 also prevents IDENTITY inheritance but hides
the intent. It does not replace NULL with zero; that is a separate SELECT INTO property.

CHECKLIST
- Does SELECT INTO inherit IDENTITY? Was sys.columns checked?
- Do the count, order, types, and nullability match the procedure's contract?
- Would changing a projection, JOIN, or expression alter staging table metadata?

Source: https://learn.microsoft.com/sql/t-sql/queries/select-into-clause-transact-sql
*/

SET NOCOUNT ON;
SET XACT_ABORT OFF;
GO

/*
clean up
*/

DROP PROCEDURE IF EXISTS dbo.DemoOrderData;
DROP TABLE IF EXISTS dbo.Table_Broken;
DROP TABLE IF EXISTS dbo.Table_Fixed;
DROP TABLE IF EXISTS dbo.Table_LessElegantFixed;
GO

SELECT
    @@SERVERNAME AS ServerName,
    DB_NAME() AS CurrentDatabase,
    CAST(SERVERPROPERTY('ProductVersion') AS varchar(50)) AS ProductVersion;
GO

/*
Procedure used by both versions of the example

The procedure returns three columns:
Column1, Column2, Column3.
*/

CREATE OR ALTER PROCEDURE dbo.DemoOrderData
AS
BEGIN
    SET NOCOUNT ON;

    SELECT TOP (100)
        SalesOrderID        AS Column1,
        SalesPersonID       AS Column2,
        PurchaseOrderNumber AS Column3
    FROM Sales.SalesOrderHeader
    ORDER BY SalesOrderID;
END;
GO


/*
PART A — BROKEN VERSION
Reproduce error 213
*/

/*
SalesOrderID has the IDENTITY property.

Because SELECT INTO refers directly to SalesOrderID,
Column1 inherits the IDENTITY property.
*/
SELECT TOP (0)
    SalesOrderID        AS Column1,
    SalesPersonID       AS Column2,
    PurchaseOrderNumber AS Column3
INTO dbo.Table_Broken
FROM Sales.SalesOrderHeader;
GO


/*
Check the hidden cause before running the failing INSERT.
Expected result:
Column1 -> is_identity = 1
*/
SELECT
    N'BROKEN TABLE' AS DemoPart,
    column_id,
    name,
    TYPE_NAME(user_type_id) AS DataType,
    max_length,
    is_nullable,
    is_identity
FROM sys.columns
WHERE object_id = OBJECT_ID(N'dbo.Table_Broken')
ORDER BY column_id;
GO

/*
Expected result:
Error 213 — the column name or number of supplied values does not match
the table definition.

The procedure returns three values:
Column1, Column2, Column3

But Column1 has IDENTITY and is not treated as an ordinary writable column
when the target column list is omitted.
*/
BEGIN TRY
    INSERT INTO dbo.Table_Broken
    EXEC dbo.DemoOrderData;

    SELECT
        N'BROKEN DEMO' AS DemoPart,
        N'UNEXPECTED PASS' AS Result;
END TRY
BEGIN CATCH
    SELECT
        N'BROKEN DEMO' AS DemoPart,
        N'EXPECTED FAILURE' AS Result,
        ERROR_NUMBER() AS ErrorNumber,
        ERROR_SEVERITY() AS ErrorSeverity,
        ERROR_STATE() AS ErrorState,
        ERROR_LINE() AS ErrorLine,
        ERROR_MESSAGE() AS ErrorMessage;
END CATCH;
GO

/*
The table should remain empty after the failed insert.
*/
SELECT
    N'BROKEN TABLE ROW COUNT' AS CheckName,
    COUNT(*) AS TotalRows
FROM dbo.Table_Broken;
GO

/*
PART B — CORRECT VERSION
Recommended solution: define the staging table explicitly
*/

/*
When specific metadata is required, do not rely on SELECT INTO inheritance.

Define the table and insert contract explicitly:
- no IDENTITY;
- agreed data types;
- specified nullability;
- target column list in INSERT.
*/
CREATE TABLE dbo.Table_Fixed
(
    Column1     int           NOT NULL,
    Column2     int           NULL,
    Column3     nvarchar(25)  NULL

);
GO

/*
Check that no column has the IDENTITY property.
*/
SELECT
    N'FIXED TABLE' AS DemoPart,
    column_id,
    name,
    TYPE_NAME(user_type_id) AS DataType,
    max_length,
    is_nullable,
    is_identity
FROM sys.columns
WHERE object_id = OBJECT_ID(N'dbo.Table_Fixed')
ORDER BY column_id;
GO

/*
Write the procedure's result.
The explicit target column list shows the expected insert contract.
*/
BEGIN TRY
    INSERT INTO dbo.Table_Fixed
    (
        Column1,
        Column2,
        Column3
    )
    EXEC dbo.DemoOrderData;
    
END TRY
BEGIN CATCH
    SELECT
        N'FIXED INSERT EXEC' AS DemoPart,
        N'FAIL' AS Result,
        ERROR_NUMBER() AS ErrorNumber,
        ERROR_SEVERITY() AS ErrorSeverity,
        ERROR_STATE() AS ErrorState,
        ERROR_LINE() AS ErrorLine,
        ERROR_MESSAGE() AS ErrorMessage;

    THROW;
END CATCH;
GO

SELECT TOP (10)
    Column1,
    Column2,
    Column3
FROM dbo.Table_Fixed
ORDER BY Column1;
GO



/*
PART B — SalesOrderID + 0 prevents IDENTITY inheritance
*/

SELECT TOP (0)
    SalesOrderID + 0       AS Column1,
    SalesPersonID       AS Column2,
    PurchaseOrderNumber AS Column3
INTO dbo.Table_LessElegantFixed
FROM Sales.SalesOrderHeader;
GO



SELECT
    N'FIXED TABLE' AS DemoPart,
    column_id,
    name,
    TYPE_NAME(user_type_id) AS DataType,
    max_length,
    is_nullable,
    is_identity
FROM sys.columns
WHERE object_id = OBJECT_ID(N'dbo.Table_LessElegantFixed')
ORDER BY column_id;
GO

BEGIN TRY
    INSERT INTO dbo.Table_LessElegantFixed
    EXEC dbo.DemoOrderData;

END TRY
BEGIN CATCH
    SELECT
        N'EXPRESSION FIX' AS DemoPart,
        N'FAIL' AS Result,
        ERROR_NUMBER() AS ErrorNumber,
        ERROR_SEVERITY() AS ErrorSeverity,
        ERROR_STATE() AS ErrorState,
        ERROR_LINE() AS ErrorLine,
        ERROR_MESSAGE() AS ErrorMessage;
END CATCH;
GO


SELECT
    COUNT(*) AS TotalRows
FROM dbo.Table_LessElegantFixed;
GO


/*
clean up
*/
DROP PROCEDURE IF EXISTS dbo.DemoOrderData;
DROP TABLE IF EXISTS dbo.Table_Fixed;
DROP TABLE IF EXISTS dbo.Table_Broken;
DROP TABLE IF EXISTS dbo.Table_LessElegantFixed;
GO

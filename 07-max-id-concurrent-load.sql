/*
07. A PRIMARY KEY does not replace a generator for sequential identifiers.
Assumption: "A PRIMARY KEY ensures uniqueness, and MAX(ID) plus ROW_NUMBER()
will safely continue numbering while loading further batches."

BUSINESS SCENARIO
Two ETL processes load sales order lines into a reporting table without an
IDENTITY column. Process A takes order 43660 and process B takes the first two
lines of order 43661. These are real rows from Sales.SalesOrderDetail.

The target table exists for the demonstration because AdventureWorks does not
include such a parallel ETL process. Two real lines from order 43659 form its initial state.

PROBLEM AND CAUSE
A PRIMARY KEY checks whether the value being stored is unique. It does not
generate the next ID or reserve numbers for a loading process. The process
therefore tries to continue numbering using MAX(LoadRowID).

Both processes can read the same MAX(LoadRowID) before either runs an INSERT.
They then number their batches from the same value. MAX describes the state
visible during SELECT, but reserves no range for the process that read it.

The primary key correctly rejects the second batch and protects stored-data
uniqueness, but it does not ensure a continuous load process. Without a UNIQUE
or PRIMARY KEY constraint, the table would accept duplicate identifiers and
the problem would only surface in reports.

SOLUTION
If the table has IDENTITY, the loading process omits that column and lets the
engine assign values. If there is a valid reason not to use IDENTITY, a SEQUENCE
object can handle numbering through NEXT VALUE FOR. Parallel processes then get
values from one generator rather than independently guessing the next one via MAX.

A PRIMARY KEY remains necessary as the final uniqueness guarantee. IDENTITY and
SEQUENCE continue assigning values but do not guarantee gapless numbering: a
number can be consumed by a failed INSERT, ROLLBACK, or outage.

CHECKLIST
- Can several processes assign identifiers at the same time?
- Is the MAX value read reserved until INSERT finishes?
- Who assigns the next ID: the ETL process, IDENTITY, or SEQUENCE?
- Is the PRIMARY KEY mistaken for a number-generation mechanism?
- Are gaps after an error, ROLLBACK, or server restart acceptable?
- Is the number a technical key or a document number requiring its own rules?

RUN: AdventureWorks OLTP, SQL Server 2016+. The script creates and removes
demo dbo objects and uses real order lines.
Sources:
https://learn.microsoft.com/sql/t-sql/statements/create-table-transact-sql-identity-property
https://learn.microsoft.com/sql/relational-databases/sequence-numbers/sequence-numbers
https://learn.microsoft.com/sql/t-sql/functions/next-value-for-transact-sql
*/

SET NOCOUNT ON;
SET XACT_ABORT ON;
GO

/*
clean up
*/
DROP TABLE IF EXISTS dbo.DemoParallelSalesLineLoad;
DROP SEQUENCE IF EXISTS dbo.DemoParallelSalesLineID;
DROP TABLE IF EXISTS #PreparedLoadA;
DROP TABLE IF EXISTS #PreparedLoadB;
GO

/*
The target table has no IDENTITY. The first two ID values represent data
previously loaded from order 43659.
*/
CREATE TABLE dbo.DemoParallelSalesLineLoad
(
    LoadRowID bigint NOT NULL
        CONSTRAINT PK_DemoParallelSalesLineLoad PRIMARY KEY,
    SalesOrderID int NOT NULL,
    SalesOrderDetailID int NOT NULL,
    ProductID int NOT NULL,
    OrderQty smallint NOT NULL,
    LineTotal numeric(38, 6) NOT NULL
);

INSERT INTO dbo.DemoParallelSalesLineLoad
    (LoadRowID, SalesOrderID, SalesOrderDetailID, ProductID, OrderQty, LineTotal)
SELECT TOP (2)
    ROW_NUMBER() OVER (ORDER BY SalesOrderDetailID),
    SalesOrderID,
    SalesOrderDetailID,
    ProductID,
    OrderQty,
    LineTotal
FROM Sales.SalesOrderDetail
WHERE SalesOrderID = 43659
ORDER BY SalesOrderDetailID;
GO

/*
The table state before the two new loading processes start.
*/
SELECT
    LoadRowID,
    SalesOrderID,
    SalesOrderDetailID,
    ProductID,
    OrderQty,
    LineTotal
FROM dbo.DemoParallelSalesLineLoad
ORDER BY LoadRowID;
GO

/*
FAILURE
Processes A and B prepare their batches before writing. Both see MAX = 2, so
they independently assign IDs 3 and 4 to their rows.
*/
SELECT
    MAX(LoadRowID) AS MaximumLoadRowIDSeenByBothProcesses
FROM dbo.DemoParallelSalesLineLoad;
GO

SELECT
    (SELECT MAX(LoadRowID) FROM dbo.DemoParallelSalesLineLoad)
        + ROW_NUMBER() OVER (ORDER BY SalesOrderDetailID) AS ProposedLoadRowID,
    SalesOrderID,
    SalesOrderDetailID,
    ProductID,
    OrderQty,
    LineTotal
INTO #PreparedLoadA
FROM Sales.SalesOrderDetail
WHERE SalesOrderID = 43660;

SELECT TOP (2)
    (SELECT MAX(LoadRowID) FROM dbo.DemoParallelSalesLineLoad)
        + ROW_NUMBER() OVER (ORDER BY SalesOrderDetailID) AS ProposedLoadRowID,
    SalesOrderID,
    SalesOrderDetailID,
    ProductID,
    OrderQty,
    LineTotal
INTO #PreparedLoadB
FROM Sales.SalesOrderDetail
WHERE SalesOrderID = 43661
ORDER BY SalesOrderDetailID;

SELECT
    ProcessName,
    ProposedLoadRowID,
    SalesOrderID,
    SalesOrderDetailID
FROM
(
    SELECT N'Process A' AS ProcessName, ProposedLoadRowID,
           SalesOrderID, SalesOrderDetailID
    FROM #PreparedLoadA

    UNION ALL

    SELECT N'Process B', ProposedLoadRowID,
           SalesOrderID, SalesOrderDetailID
    FROM #PreparedLoadB
) AS PreparedLoads
ORDER BY ProposedLoadRowID, ProcessName;
GO

/*
Process A writes IDs 3 and 4. Shortly afterward, process B tries to write the
same range and receives a primary-key violation.
*/
INSERT INTO dbo.DemoParallelSalesLineLoad
    (LoadRowID, SalesOrderID, SalesOrderDetailID, ProductID, OrderQty, LineTotal)
SELECT ProposedLoadRowID, SalesOrderID, SalesOrderDetailID,
       ProductID, OrderQty, LineTotal
FROM #PreparedLoadA;

BEGIN TRY
    INSERT INTO dbo.DemoParallelSalesLineLoad
        (LoadRowID, SalesOrderID, SalesOrderDetailID, ProductID, OrderQty, LineTotal)
    SELECT ProposedLoadRowID, SalesOrderID, SalesOrderDetailID,
           ProductID, OrderQty, LineTotal
    FROM #PreparedLoadB;

    SELECT N'SUCCESS' AS Result;
END TRY
BEGIN CATCH
    SELECT
        N'ERROR' AS Result,
        ERROR_NUMBER() AS ErrorNumber,
        ERROR_MESSAGE() AS ErrorMessage;
END CATCH;
GO

/*
The PRIMARY KEY preserved uniqueness: the table has identifiers 1 through 4.
It did not solve numbering, because process B's lines were not loaded.
*/
SELECT
    LoadRowID,
    SalesOrderID,
    SalesOrderDetailID,
    ProductID,
    OrderQty,
    LineTotal
FROM dbo.DemoParallelSalesLineLoad
ORDER BY LoadRowID;
GO

/*
FIX
The table still has no IDENTITY. Its default value comes from an independent
SEQUENCE object, and loading processes do not provide LoadRowID.
*/
DROP TABLE dbo.DemoParallelSalesLineLoad;

CREATE SEQUENCE dbo.DemoParallelSalesLineID
    AS bigint
    START WITH 1
    INCREMENT BY 1
    NO CYCLE;
GO

CREATE TABLE dbo.DemoParallelSalesLineLoad
(
    LoadRowID bigint NOT NULL
        CONSTRAINT DF_DemoParallelSalesLineLoad_LoadRowID
        DEFAULT (NEXT VALUE FOR dbo.DemoParallelSalesLineID)
        CONSTRAINT PK_DemoParallelSalesLineLoad PRIMARY KEY,
    SalesOrderID int NOT NULL,
    SalesOrderDetailID int NOT NULL,
    ProductID int NOT NULL,
    OrderQty smallint NOT NULL,
    LineTotal numeric(38, 6) NOT NULL
);

INSERT INTO dbo.DemoParallelSalesLineLoad
    (SalesOrderID, SalesOrderDetailID, ProductID, OrderQty, LineTotal)
SELECT TOP (2)
    SalesOrderID, SalesOrderDetailID, ProductID, OrderQty, LineTotal
FROM Sales.SalesOrderDetail
WHERE SalesOrderID = 43659
ORDER BY SalesOrderDetailID;


/*
These two INSERTs represent independent processes. Both omit LoadRowID.
*/
INSERT INTO dbo.DemoParallelSalesLineLoad
    (SalesOrderID, SalesOrderDetailID, ProductID, OrderQty, LineTotal)
SELECT SalesOrderID, SalesOrderDetailID, ProductID, OrderQty, LineTotal
FROM #PreparedLoadA;

INSERT INTO dbo.DemoParallelSalesLineLoad
    (SalesOrderID, SalesOrderDetailID, ProductID, OrderQty, LineTotal)
SELECT SalesOrderID, SalesOrderDetailID, ProductID, OrderQty, LineTotal
FROM #PreparedLoadB;

SELECT
    LoadRowID,
    SalesOrderID,
    SalesOrderDetailID,
    ProductID,
    OrderQty,
    LineTotal
FROM dbo.DemoParallelSalesLineLoad
ORDER BY LoadRowID;
GO

/*
clean up
*/
DROP TABLE IF EXISTS dbo.DemoParallelSalesLineLoad;
DROP SEQUENCE IF EXISTS dbo.DemoParallelSalesLineID;
DROP TABLE IF EXISTS #PreparedLoadA;
DROP TABLE IF EXISTS #PreparedLoadB;
GO

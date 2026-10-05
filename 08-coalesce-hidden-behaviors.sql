/*
08. COALESCE is more than "the first non-NULL value."

ASSUMPTION
"COALESCE checks arguments in order, returns the first non-NULL one, and how
the remaining arguments were evaluated or typed no longer matters."

BUSINESS SCENARIO
In a sales system, COALESCE may fill missing data:
- a subquery selects an order for audit and a constant identifies a technical account;
- an export replaces a missing identifier with a text label;
- a computed column replaces a missing salesperson with technical value 0.

Each case looks like a simple "if NULL, use a fallback." SQL Server must also
determine evaluation behavior, result type, and its metadata.

PROBLEM AND CAUSE
1. COALESCE is expanded to a CASE expression. An argument containing a subquery
   may execute twice. A nondeterministic subquery may return another row, and at
   READ COMMITTED the second read may see a different committed value than the first.
2. The result type is selected by data type precedence, rather than by the argument
   that ultimately supplies the value. The first non-NULL value may therefore need
   an unexpected conversion to the type of a later argument.
3. COALESCE(col, 0) may never return NULL, yet computed-column metadata can still
   allow NULL. This matters for keys and indexes.

CORRECT APPROACH
- Evaluate an expensive or variable subquery once, then pass its stored result to
  COALESCE. ISNULL or SNAPSHOT isolation are alternatives when they fit the whole
  operation's contract.
- Explicitly convert arguments to the agreed target type before COALESCE.
- Check computed-column metadata. ISNULL may provide NOT NULL metadata, but has
  its own type and length rules, shown in example 2.

CHECKLIST
- Is any argument a subquery or expensive expression?
- Is the subquery deterministic, and can its result change between two evaluations
  at the isolation level in use?
- What is the expression's type, and which arguments will SQL Server convert?
- Does nullability metadata meet the key or index requirements?
- Would replacing COALESCE with ISNULL change the result type or length?
- Is the fallback, such as 0, outside the valid data domain?

RUN: AdventureWorks OLTP, SQL Server 2016+. The script creates and removes a
demo dbo table and local temporary tables.
Sources:
https://learn.microsoft.com/sql/t-sql/language-elements/coalesce-transact-sql
https://learn.microsoft.com/sql/t-sql/data-types/data-type-precedence-transact-sql
*/

SET NOCOUNT ON;
SET XACT_ABORT ON;
SET QUOTED_IDENTIFIER ON;
GO

/*
clean up
*/
DROP TABLE IF EXISTS #CoalesceResults;
DROP TABLE IF EXISTS #SelectedSalesPersons;
DROP TABLE IF EXISTS dbo.DemoCoalesceMetadata;
GO

/*
PITFALL 1: COALESCE CAN RETURN NULL DESPITE A FALLBACK OF 1

A quality-assurance process randomly selects an order for audit and retrieves
the assigned salesperson identifier. Order 43659 has SalesPersonID = 279, while
online order 43697 has no salesperson. If the selected order lacks a salesperson,
fallback 1 should identify the technical audit user.

Both orders and their SalesPersonID values come from Sales.SalesOrderHeader.
*/
SELECT
    SalesOrderID,
    SalesPersonID,
    OrderDate,
    Status
FROM Sales.SalesOrderHeader
WHERE SalesOrderID IN (43659, 43697)
ORDER BY SalesOrderID;

CREATE TABLE #CoalesceResults
(
    EffectiveSalesPersonID int NULL
);

CREATE TABLE #SelectedSalesPersons
(
    SelectedSalesPersonID int NULL
);
GO

/*
The following subquery selects one of the two rows shown above:
- order 43659, where SalesPersonID = 279;
- order 43697, where SalesPersonID = NULL.

COALESCE may execute the argument containing the subquery twice because the
optimizer expands it into logic equivalent to this CASE:

CASE
    WHEN (selection) IS NOT NULL THEN (selection)
    ELSE 1
END

NULL occurs in this sequence:
1. The first subquery execution selects order 43659 and returns 279.
2. The condition 279 IS NOT NULL is true, so SQL Server chooses THEN.
3. The subquery executes again in the THEN branch.
4. The second execution may select order 43697 and return NULL.
5. The entire CASE, and therefore COALESCE, then returns NULL. The ELSE branch
   with fallback 1 is not revisited because the THEN branch was already chosen.

Possible results of one trial are:
- the first selection returns NULL: ELSE runs and returns 1;
- both selections return 279: the result is 279;
- the first selection returns 279 and the second NULL: the result is NULL.

GO 100 does not create NULL and is not a T-SQL statement. It is a client-side
separator understood by SSMS or sqlcmd with a repeat count: it sends the prior
batch, the single INSERT below, one hundred times in the same session. Each run
adds one result to #CoalesceResults. One hundred trials merely increase the chance
of seeing 279 followed by NULL. EffectiveSalesPersonID allows NULL, so that result
can be stored in the temporary table.
*/
INSERT INTO #CoalesceResults (EffectiveSalesPersonID)
SELECT COALESCE
    (
        (
            SELECT TOP (1) SalesPersonID
            FROM Sales.SalesOrderHeader
            WHERE SalesOrderID IN (43659, 43697)
            ORDER BY NEWID()
        ),
        1
    );
GO 100

/*
The result can be 279, 1, or NULL. Rows counted in NullZCoalesce show the pitfall:
COALESCE returned NULL despite the explicit fallback of 1.
*/

SELECT 
    EffectiveSalesPersonID 
FROM #CoalesceResults
GO


SELECT
    COUNT(*) AS TrialCount,
    SUM(CASE WHEN EffectiveSalesPersonID IS NULL THEN 1 ELSE 0 END)
        AS NullFromCoalesce,
    SUM(CASE WHEN EffectiveSalesPersonID = 1 THEN 1 ELSE 0 END)
        AS FallbackUsed,
    SUM(CASE WHEN EffectiveSalesPersonID = 279 THEN 1 ELSE 0 END)
        AS SalespersonUsed
FROM #CoalesceResults;
GO

/*
FIX
First, perform the selection itself and store its result. Each trial now contains
one observed value: 279 or NULL.
*/
INSERT INTO #SelectedSalesPersons (SelectedSalesPersonID)
SELECT
    (
        SELECT TOP (1) SalesPersonID
        FROM Sales.SalesOrderHeader
        WHERE SalesOrderID IN (43659, 43697)
        ORDER BY NEWID()
    );
GO 100

/*
COALESCE operates on the stored column and cannot select again. Therefore every
stored NULL is replaced by 1, and the result is never NULL.
*/
SELECT
    COUNT(*) AS TrialCount,
    SUM(CASE WHEN COALESCE(SelectedSalesPersonID, 1) IS NULL THEN 1 ELSE 0 END)
        AS NullAfterMaterialization
FROM #SelectedSalesPersons;
GO

/*
PITFALL 2: RESULT TYPE DOES NOT DEPEND ON THE FIRST VALUE RETURNED

An export should use the business ProductNumber, falling back to the internal
ProductID only when it is absent. We assume the result type follows the first
non-NULL value. ProductID is int, however, which has higher precedence than
nvarchar. SQL Server therefore tries to convert the selected ProductNumber, such
as N'AR-5381', to int, and the query ends with error 245.

COALESCE(NULL, 1, 'abc') itself returns 1 in SQL Server 2025: determining int
as the type does not automatically convert an unselected branch. The error occurs
when the value actually selected does not fit the type of the entire expression.
*/
BEGIN TRY
    SELECT TOP (1)
        COALESCE(ProductNumber, ProductID) AS ProductLabel
    FROM Production.Product
    ORDER BY ProductID;

    SELECT N'SUCCESS' AS Result;
END TRY
BEGIN CATCH
    SELECT
        N'ERROR' AS Result,
        ERROR_NUMBER() AS ErrorNumber,
        ERROR_MESSAGE() AS ErrorMessage;
END CATCH;

/*
FIX
The export must return text, so explicitly convert the internal identifier to
the target type and length. Both arguments now belong to the agreed domain.
*/
SELECT TOP (5)
    COALESCE(ProductNumber, CONVERT(nvarchar(25), ProductID)) AS ProductLabel,
    Name AS ProductName
FROM Production.Product
ORDER BY ProductID;
GO

/*
PITFALL 3: SAME RESULT, DIFFERENT NULLABILITY METADATA

Copy orders 43659 and 43697 to the demo table without changing their SalesOrderID
or SalesPersonID. Two computed columns replace a missing salesperson with 0.
COALESCE and ISNULL return exactly the same values: 279 and 0. SQL Server
describes the COALESCE result as nullable and the ISNULL result as NOT NULL.
*/
SELECT
    SalesOrderID,
    SalesPersonID
INTO dbo.DemoCoalesceMetadata
FROM Sales.SalesOrderHeader
WHERE SalesOrderID IN (43659, 43697);

SELECT
    SalesOrderID,
    SalesPersonID
FROM dbo.DemoCoalesceMetadata
ORDER BY SalesOrderID;

ALTER TABLE dbo.DemoCoalesceMetadata
ADD SalesPersonFromCoalesce AS COALESCE(SalesPersonID, 0),
    SalesPersonFromIsNull AS ISNULL(SalesPersonID, 0);

SELECT
    SalesOrderID,
    SalesPersonID,
    SalesPersonFromCoalesce,
    SalesPersonFromIsNull
FROM dbo.DemoCoalesceMetadata
ORDER BY SalesOrderID;

SELECT
    c.name,
    c.is_nullable,
    cc.definition 
FROM sys.columns AS c
JOIN sys.computed_columns AS cc
    ON cc.object_id = c.object_id
   AND cc.column_id = c.column_id
WHERE c.object_id = OBJECT_ID(N'dbo.DemoCoalesceMetadata')
  AND c.name IN (N'SalesPersonFromCoalesce', N'SalesPersonFromIsNull')
ORDER BY c.column_id;
GO

/*
A PRIMARY KEY on the COALESCE result fails even though visible values contain no
NULL. Dynamic execution lets the definition error be caught and the demonstration continue.
*/
ALTER TABLE dbo.DemoCoalesceMetadata
ADD CONSTRAINT PK_DemoCoalesceMetadata
PRIMARY KEY (SalesOrderID, SalesPersonFromCoalesce);


/*
FIX
In this model, ISNULL has the expected int type and NOT NULL metadata, so it can
form part of the key. This is not a universal replacement: check ISNULL's type
and length rules and ensure that 0 is not a valid SalesPersonID before using it.
*/
ALTER TABLE dbo.DemoCoalesceMetadata
ADD CONSTRAINT PK_DemoCoalesceMetadata
PRIMARY KEY (SalesOrderID, SalesPersonFromIsNull);
GO

SELECT
    c.name,
    c.is_nullable,
    i.name,
    i.is_primary_key
FROM sys.columns AS c
LEFT JOIN sys.index_columns AS ic
    ON ic.object_id = c.object_id
   AND ic.column_id = c.column_id
LEFT JOIN sys.indexes AS i
    ON i.object_id = ic.object_id
   AND i.index_id = ic.index_id
WHERE c.object_id = OBJECT_ID(N'dbo.DemoCoalesceMetadata')
  AND c.name IN (N'SalesPersonFromCoalesce', N'SalesPersonFromIsNull')
ORDER BY c.column_id;
GO

/*
clean up
*/
DROP TABLE IF EXISTS #CoalesceResults;
DROP TABLE IF EXISTS #SelectedSalesPersons;
DROP TABLE IF EXISTS dbo.DemoCoalesceMetadata;
GO

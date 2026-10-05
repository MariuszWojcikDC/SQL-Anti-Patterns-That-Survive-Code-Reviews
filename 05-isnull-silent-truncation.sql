/*
02. ISNULL silently truncates the replacement value.
Assumption: "If the first argument is NULL, ISNULL returns the second argument
with its type and length."

BUSINESS SCENARIO
A person-label export uses Person.Person in AdventureWorks. It takes Title, or
FirstName when Title is missing. Title is nvarchar(8), while FirstName is
nvarchar(50). We show actual people without a title whose first names exceed
eight characters; the demo does not pad their names.

PROBLEM AND CAUSE
ISNULL takes the type and length from its first argument. The first name is
truncated to eight characters, and SELECT INTO preserves that short type.
The absence of an error does not mean no data was lost.

SOLUTION
Widen the first ISNULL argument before evaluating the expression. Casting the
finished result cannot recover truncated text. The target length must follow
the export contract.

CHECKLIST
- Was the expression's type checked, as well as the types of both columns?
- Does the test cover a NULL first argument and a longer replacement value?
- Do the table and recipient field limits accommodate the full data length?

RUN: AdventureWorks OLTP, SQL Server 2016+. Writes only to #temp.
Source: https://learn.microsoft.com/sql/t-sql/functions/isnull-transact-sql
*/

SET NOCOUNT ON;
GO

/*
clean up
*/
DROP TABLE IF EXISTS #PersonExport;
GO

/*
FAILURE
ISNULL takes the result type and length from Title: nvarchar(8).
The WHERE clause selects rows that need a replacement and whose first names
exceed eight characters, making the truncation visible.
*/
SELECT TOP (10)
    p.BusinessEntityID,
    p.Title,
    p.FirstName,
    ISNULL(p.Title, p.FirstName) AS DisplayValue
INTO #PersonExport
FROM Person.Person AS p
WHERE p.Title IS NULL
  AND LEN(p.FirstName) > 8
ORDER BY p.BusinessEntityID;
GO

/*
Although DisplayValue comes from FirstName, it is truncated to eight characters.
*/
SELECT
    BusinessEntityID,
    Title,
    FirstName,
    DisplayValue,
    LEN(FirstName) AS FirstNameLength,
    LEN(DisplayValue) AS DisplayValueLength
FROM #PersonExport;
GO

/*
SELECT INTO also preserves the hidden assumption: DisplayValue is nvarchar(8).
*/
SELECT
    c.name AS ColumnName,
    TYPE_NAME(c.user_type_id) AS DataType,
    c.max_length / 2 AS MaxCharacters
FROM tempdb.sys.columns AS c
WHERE c.object_id = OBJECT_ID(N'tempdb..#PersonExport')
GO

/*
FIX
Set the intended result length by widening the first ISNULL argument.
*/
SELECT TOP (10)
    p.BusinessEntityID,
    ISNULL(CAST(p.Title AS nvarchar(50)), p.FirstName) AS DisplayValue
FROM Person.Person AS p
WHERE p.Title IS NULL
  AND LEN(p.FirstName) > 8
ORDER BY p.BusinessEntityID;
GO

/*
Microsoft Learn: ISNULL returns the first argument's type, and a longer
replacement value may be truncated:
https://learn.microsoft.com/sql/t-sql/functions/isnull-transact-sql
*/

/*
clean up
*/
DROP TABLE IF EXISTS #PersonExport;
GO

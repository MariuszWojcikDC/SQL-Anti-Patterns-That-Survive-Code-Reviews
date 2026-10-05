/*
04. A temporary table may compare text using a different collation.
Assumption: "Because I am working in this database, #temp uses its text rules."

BUSINESS SCENARIO
An import of postal codes is joined to Person.Address in AdventureWorks.
After moving the database to another instance, the same JOIN may stop working
even though neither the nvarchar(15) type nor the query changed.

PROBLEM AND CAUSE
In a regular non-contained database, an explicitly created #temp column without
COLLATE inherits tempdb's default collation. Comparing columns with incompatible
text comparison rules may cause a conflict. If the settings match, the conflict
demo will not fail. A different database name alone does not imply incompatibility.
The REPRODUCE THE PROBLEM section chooses an example collation: compare it with
the column's actual collation, since no constant guarantees a conflict everywhere.

SOLUTION
COLLATE database_default in the #temp definition uses the current database's
default collation. This works for source columns that use that same setting.
A source column with its own collation needs a deliberate match.
The choice also affects letter and accent equality, not just the error.

CHECKLIST
- What collations do the instance, tempdb, database, and source column use?
- Was the query tested after restoring the database on the target instance?
- Should case and accents distinguish codes in this domain?

RUN: AdventureWorks OLTP, SQL Server 2016+. Only #temp tables are used.
The conflict demonstrations may intentionally raise an error; run them separately in SSMS.
Source:
https://learn.microsoft.com/sql/relational-databases/collations/set-or-change-the-column-collation#collations-and-tempdb
*/

SET NOCOUNT ON;
GO


/*
Check the environment settings that determine whether the problem occurs.
*/
SELECT
    CAST(DATABASEPROPERTYEX(DB_NAME(), N'Collation') AS sysname)
        AS UserDatabaseCollation,
    CAST(DATABASEPROPERTYEX(N'tempdb', N'Collation') AS sysname)
        AS TempdbCollation;
GO

/*
clean up
*/
DROP TABLE IF EXISTS #Codes;
GO


/*
TYPICAL CODE: without COLLATE, PostalCode inherits tempdb's collation.
Whether a conflict occurs depends on the comparison rules of both columns.
In a standard AdventureWorks database with matching defaults, the JOIN works
and the risk that may surface after deployment stays hidden.
Check any collations explicitly assigned to columns as well.
*/
CREATE TABLE #Codes
(
    PostalCode nvarchar(15) NOT NULL
);

INSERT INTO #Codes (PostalCode)
SELECT TOP (3) PostalCode
FROM Person.Address
ORDER BY AddressID;

SELECT
    a.AddressID,
    a.PostalCode
FROM Person.Address AS a
JOIN #Codes AS c
    ON c.PostalCode = a.PostalCode;
GO

/*
clean up
*/
DROP TABLE IF EXISTS #Codes;
GO

/*
REPRODUCE THE PROBLEM
For this demonstration, assign #Codes a specific collation. This causes a
conflict if it differs from Person.Address.PostalCode's collation. A compilation
error at this level may bypass TRY/CATCH; run the next batch after the error.
*/
CREATE TABLE #Codes
(
    PostalCode nvarchar(15) COLLATE Latin1_General_100_CI_AS_SC NOT NULL
);

INSERT INTO #Codes (PostalCode)
SELECT TOP (3) PostalCode
FROM Person.Address
ORDER BY AddressID;

BEGIN TRY
    SELECT
        a.AddressID,
        a.PostalCode
    FROM Person.Address AS a
    JOIN #Codes AS c
        ON c.PostalCode = a.PostalCode;
END TRY
BEGIN CATCH
    SELECT
        N'Expected collation conflict' AS Result,
        ERROR_NUMBER() AS ErrorNumber,
        ERROR_MESSAGE() AS ErrorMessage;
END CATCH;
GO

/*
clean up
*/
DROP TABLE IF EXISTS #Codes;
GO

/*
FIX
database_default uses the current user database's default collation instead of
tempdb's setting. It matches the source if its column also uses the current
database default. An explicitly collated source column needs a matching choice.
*/
CREATE TABLE #Codes
(
    PostalCode nvarchar(15) COLLATE database_default NOT NULL
);

INSERT INTO #Codes (PostalCode)
SELECT TOP (3) PostalCode
FROM Person.Address
ORDER BY AddressID;

SELECT
    a.AddressID,
    a.PostalCode
FROM Person.Address AS a
JOIN #Codes AS c
    ON c.PostalCode = a.PostalCode;
GO

/*
Microsoft Learn:
https://learn.microsoft.com/sql/relational-databases/collations/set-or-change-the-column-collation#collations-and-tempdb
*/

/*
clean up
*/
DROP TABLE IF EXISTS #Codes;
GO

/*
06. The schema allows an employee to belong to two departments at once.
Assumption: "An employee can belong to only one department, so the history
table surely prevents two active assignments."

BUSINESS SCENARIO
An HR report reads the current department from HumanResources.EmployeeDepartmentHistory.
Employee 1 has one active assignment: department 16, shift 1, StartDate
2009-01-14, and EndDate NULL.

PROBLEM AND CAUSE
The primary key includes BusinessEntityID, StartDate, DepartmentID, and ShiftID,
so a different department creates a different key. The database accepts another
active row for the same employee, period, and shift. The business must decide
whether this is an error, a valid split assignment, or support for another department.

SOLUTION
If multiple assignments are valid, the model and report must handle a one-to-many
relationship. If only one open assignment is allowed, a unique filtered index on
BusinessEntityID where EndDate IS NULL can enforce that rule. Preventing all
overlapping periods requires stronger write validation.

CHECKLIST
- Can an employee belong to several departments at once?
- Which assignment is primary, and how are working time and costs split?
- If this state is forbidden, which schema constraint actually prevents it?

RUN: AdventureWorks OLTP, SQL Server 2016+. The INSERT runs inside a transaction
and is undone by ROLLBACK.
Sources:
https://learn.microsoft.com/sql/relational-databases/tables/primary-and-foreign-key-constraints
https://learn.microsoft.com/sql/t-sql/statements/create-index-transact-sql
*/

SET NOCOUNT ON;
SET XACT_ABORT ON;
GO
/*
Current data has no employee with more than one active department.
An empty result describes the data, not a schema guarantee.
*/
SELECT
    BusinessEntityID,
    COUNT(*) AS ActiveAssignments
FROM HumanResources.EmployeeDepartmentHistory
WHERE EndDate IS NULL
GROUP BY BusinessEntityID
HAVING COUNT(*) > 1;
GO


/*
Check what the schema actually guarantees: primary key columns, uniqueness,
index filters, CHECK constraints, and table triggers.
*/
SELECT
    kc.name AS KeyName,
    ic.key_ordinal AS KeyOrdinal,
    c.name AS KeyColumn
FROM sys.key_constraints AS kc
JOIN sys.index_columns AS ic
    ON ic.object_id = kc.parent_object_id
   AND ic.index_id = kc.unique_index_id
JOIN sys.columns AS c
    ON c.object_id = ic.object_id
   AND c.column_id = ic.column_id
WHERE kc.parent_object_id =
      OBJECT_ID(N'HumanResources.EmployeeDepartmentHistory')
ORDER BY kc.name, ic.key_ordinal;

SELECT
    i.name AS IndexName,
    i.is_unique AS IsUnique,
    i.is_primary_key AS IsPrimaryKey,
    i.has_filter AS HasFilter,
    i.filter_definition AS FilterDefinition
FROM sys.indexes AS i
WHERE i.object_id = OBJECT_ID(N'HumanResources.EmployeeDepartmentHistory')
  AND i.index_id > 0
ORDER BY i.name;

SELECT
    cc.name AS CheckName,
    cc.definition AS CheckDefinition
FROM sys.check_constraints AS cc
WHERE cc.parent_object_id =
      OBJECT_ID(N'HumanResources.EmployeeDepartmentHistory');

SELECT
    tr.name AS TriggerName,
    tr.is_disabled AS IsDisabled
FROM sys.triggers AS tr
WHERE tr.parent_id = OBJECT_ID(N'HumanResources.EmployeeDepartmentHistory');
GO



BEGIN TRANSACTION;

/*
Copy the assignment and change only the department from 16 to 1.
The INSERT succeeds because DepartmentID is part of the primary key.
*/
INSERT INTO HumanResources.EmployeeDepartmentHistory
    (BusinessEntityID, DepartmentID, ShiftID, StartDate, EndDate, ModifiedDate)
SELECT
    BusinessEntityID, 1, ShiftID, StartDate, EndDate, GETDATE()
FROM HumanResources.EmployeeDepartmentHistory
WHERE BusinessEntityID = 1 AND DepartmentID = 16 AND EndDate IS NULL;

/*
The employee now has two active assignments covering the same period.
*/
SELECT
    edh.BusinessEntityID,
    p.FirstName,
    p.LastName,
    d.Name AS DepartmentName,
    edh.StartDate,
    edh.EndDate
FROM HumanResources.EmployeeDepartmentHistory AS edh
JOIN Person.Person AS p
    ON p.BusinessEntityID = edh.BusinessEntityID
JOIN HumanResources.Department AS d
    ON d.DepartmentID = edh.DepartmentID
WHERE edh.BusinessEntityID = 1
  AND edh.EndDate IS NULL
ORDER BY d.Name;

ROLLBACK TRANSACTION;
GO

/*
POSSIBLE RULE FOR ONE OPEN ASSIGNMENT

CREATE UNIQUE INDEX UX_EmployeeDepartmentHistory_Current
ON HumanResources.EmployeeDepartmentHistory (BusinessEntityID)
WHERE EndDate IS NULL;
*/

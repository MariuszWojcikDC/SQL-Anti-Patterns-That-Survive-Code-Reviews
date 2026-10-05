/*
09. An unqualified column in a subquery may come from the outer query.
Assumption: "a nonexistent column will always cause an error."

If the column is absent from the subquery's tables, SQL Server also looks one level
up. A typo can therefore create unintended correlation and return an empty set,
the full set, or a plausible but incorrect value.

Qualify every column in a subquery with an alias, including outer references.

AdventureWorks OLTP, SQL Server 2016+. Read only.
Source: https://learn.microsoft.com/sql/relational-databases/performance/subqueries#qualify-column-names-in-subqueries
*/
SET NOCOUNT ON;

/*
1. Sales.SalesOrderDetail has no CustomerID column.
The standalone query raises error 207. Dynamic SQL can catch it and continue
the demonstration.
*/
SELECT CustomerID FROM Sales.SalesOrderDetail;

/*
2. The same CustomerID inside the subquery does not raise an error.
It binds to c.CustomerID, so IN returns all customers and NOT IN returns none.
No SalesOrderDetail data is compared.
*/
SELECT COUNT(*) AS AllCustomers
FROM Sales.Customer;

SELECT COUNT(*) AS CustomersReturnedByIN
FROM Sales.Customer AS c
WHERE c.CustomerID IN
(
    SELECT CustomerID
    FROM Sales.SalesOrderDetail AS sod
);

SELECT COUNT(*) AS CustomersReturnedByNOTIN
FROM Sales.Customer AS c
WHERE c.CustomerID NOT IN
(
    SELECT CustomerID
    FROM Sales.SalesOrderDetail AS sod
);

/*
This supporting query shows how SQL Server actually bound CustomerID.
The result matches the incorrect IN query above.
*/
SELECT COUNT(*) AS CustomersReturnedByExplicitOuterReference
FROM Sales.Customer AS c
WHERE c.CustomerID IN
(
    SELECT c.CustomerID
    FROM Sales.SalesOrderDetail AS sod
);

/*
Explicit sod.CustomerID cannot bind to the outer table and exposes the mistake
as error 207.
*/
SELECT COUNT(*)
FROM Sales.Customer AS c
WHERE c.CustomerID IN
(
    SELECT sod.CustomerID
    FROM Sales.SalesOrderDetail AS sod
);
/*
Intended query: customers without orders. An explicit alias identifies the right table.
*/
SELECT c.CustomerID, c.AccountNumber
FROM Sales.Customer AS c
WHERE c.CustomerID NOT IN
(
    SELECT soh.CustomerID
    FROM Sales.SalesOrderHeader AS soh
)
ORDER BY c.CustomerID;


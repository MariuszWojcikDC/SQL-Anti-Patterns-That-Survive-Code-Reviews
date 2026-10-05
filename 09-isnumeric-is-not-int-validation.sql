/*
03. ISNUMERIC accepts more than conventional numeric notation.
Assumption: "As its name suggests, ISNUMERIC checks whether the supplied text is a number."

BUSINESS SCENARIO
A CSV importer receives quantities, dates, postal codes, and times as text.
Fields may be mixed up after a mapping change; a spreadsheet may use scientific
notation, and a postal code with a leading zero is valid text. VALUES supplies
explicit import-contract samples; AdventureWorks does not store raw invalid CSV fields.

PROBLEM AND CAUSE
ISNUMERIC returns 1 if an expression can be converted to any numeric type
supported by SQL Server. This includes scientific notation, currency symbols,
and even a lone + or -, beyond ordinary numeric notation. A result of 1 does not
guarantee conversion to the intended type, such as int. A digit string may also
represent a date, time, or postal code; convertibility does not establish its
business meaning. Conversion can also change its representation, for example
by removing a postal code's leading zero.

SOLUTION
Use TRY_CONVERT for the exact target type, then validate the field's format and
rules: for example, allowed characters and range for a quantity, and preservation
of zeros for a postal code. A NULL from TRY_CONVERT signals an error to handle,
not a value to silently discard. Even a valid int cannot detect a date mistakenly
placed in the Quantity column.

CHECKLIST
- What are the field's domain and range, beyond its technical type?
- Are signs, whitespace, exponents, and zero or negative values allowed?
- Must the original text and rejection reason be retained?
- Is column mapping checked before conversion begins?

RUN: SQL Server 2016+, any database. Only #temp is used.
Sources:
https://learn.microsoft.com/sql/t-sql/functions/isnumeric-transact-sql
https://learn.microsoft.com/sql/t-sql/functions/try-convert-transact-sql
*/

SET NOCOUNT ON;
GO

/*
clean up
*/
DROP TABLE IF EXISTS #ImportValues;
GO

SELECT
    Source.FieldName,
    CAST(Source.RawValue AS nvarchar(50)) AS RawValue,
    Source.IntendedMeaning,
    TRY_CONVERT(int, Source.RawValue) AS ParsedInt
INTO #ImportValues
FROM
(
    VALUES
        (N'Quantity',   N'12345',      N'Integer'),
        (N'OrderDate',  N'20240229',   N'Date in YYYYMMDD format'),
        (N'OrderDate',  N'2024-02-29', N'Date in ISO format'),
        (N'PostalCode', N'50-120',     N'Polish postal code with a hyphen'),
        (N'PostalCode', N'50120',      N'Polish postal code without a hyphen'),
        (N'PostalCode', N'02138',      N'US postal code; leading zero matters'),
        (N'PickupTime', N'235959',     N'Time in HHMMSS format'),
        (N'Quantity',   N'1e4',        N'Scientific notation'),
        (N'Quantity',   N'+',          N'Plus sign only'),
        (N'Quantity',   N'-',          N'Minus sign only'),
        /*
Unusual characters: the query result shows ISNUMERIC's actual response.
        */
        (N'SpecialChar', N'.',         N'Decimal separator'),
        (N'SpecialChar', N',',         N'Group separator'),
        (N'SpecialChar', N'/',         N'Forward slash'),
        (N'SpecialChar', N'\',         N'Backslash'),
        (N'SpecialChar', NCHAR(9),     N'Horizontal tab'),
        (N'SpecialChar', NCHAR(10),    N'Line feed'),
        (N'SpecialChar', NCHAR(13),    N'Carriage return'),
        (N'SpecialChar', N' ',         N'Space'),
        (N'Quantity',   N'12A45',      N'Not numeric')
) AS Source(FieldName, RawValue, IntendedMeaning);
GO

/*
An unseparated date, postal codes without a hyphen, and a time consist only
of digits, so ISNUMERIC returns 1. That does not show whether a value belongs
in Quantity. Conversely, the valid Polish postal code 50-120 contains a hyphen
and fails the ISNUMERIC check.

Converting a postal code also removes its leading zero. Values such as 1e4,
+, -, decimal and group separators, backslash, and whitespace show another issue:
ISNUMERIC does not check whether text contains only digits. SQL Server even
converts a lone + or - to int 0. A forward slash is a counterexample: it
does not pass ISNUMERIC.
*/
SELECT
    FieldName,
    RawValue,
    IntendedMeaning,
    ISNUMERIC(RawValue) AS IsNumeric,
    ParsedInt AS AsInt,
    TRY_CONVERT(date, RawValue, 112) AS AsDateYyyyMmDd,
    TRY_CONVERT(time(0),
        STUFF(STUFF(RawValue, 3, 0, N':'), 6, 0, N':')) AS AsTimeHhMmSs
FROM #ImportValues
ORDER BY FieldName, RawValue;
GO

/*
Microsoft Learn:
- ISNUMERIC returns 1 for +, -, and valid currency symbols. The example also
  tests other separators and control characters to show how they are interpreted.
- TRY_CONVERT returns NULL when conversion to the specified type fails.
https://learn.microsoft.com/sql/t-sql/functions/isnumeric-transact-sql
https://learn.microsoft.com/sql/t-sql/functions/try-convert-transact-sql
*/

/*
clean up
*/
DROP TABLE IF EXISTS #ImportValues;
GO

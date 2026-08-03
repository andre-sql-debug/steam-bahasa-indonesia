# Data profiling checklist

Run this on every new file, before writing any SQL. It never changes, so you
never need to remember it — just open this page.

The whole point: **a file's format is a property of whoever created it, not of
the data inside it.** "It's a CSV" tells you almost nothing.

---

## Before loading — profile the FILE

### 1. What separates the columns?

Open the file in Notepad (or Notepad++) and look at the first line.

- See `a,b,c` → comma
- See `a;b;c` → semicolon (usual for European/Indonesian Excel exports, because
  the comma is their decimal separator)
- See wide gaps → tab

Or in Git Bash:

```bash
head -1 yourfile.csv | tr -cd ',' | wc -c     # commas
head -1 yourfile.csv | tr -cd ';' | wc -c     # semicolons
```

Whichever count is high is your delimiter. If the header has 38 commas and 0
semicolons, that's your answer.

### 2. How do lines end?

```bash
grep -c $'\r' yourfile.csv
```

Matches the line count → `\r\n` (Windows). Zero → `\n`.

### 3. Is there a BOM?

```bash
head -c 3 yourfile.csv | od -An -tx1
```

`ef bb bf` → UTF-8 BOM. Harmless if you skip the header row, but it corrupts
your first column name if you don't.

### 4. Does the header match the data?

**The check that saved this project.** Count the header fields and compare to a
data row. The Steam dataset had 39 header names for 40 data columns — a missing
comma had merged `Discount` and `DLC count`, so every column after `Price` was
off by one.

If they don't match, every downstream number is wrong.

### 5. Are there newlines inside fields?

If the file has long free-text columns (descriptions, reviews, comments), the
raw newline count will exceed the real row count. `LOAD DATA` will split those
rows and corrupt the load. Strip or drop those columns first.

---

## After loading — profile the TABLE

```sql
-- 1. Did every row arrive?
SELECT COUNT(*) FROM stg_table;

-- 2. Duplicates in what you think is the key?
SELECT id_col FROM stg_table GROUP BY id_col HAVING COUNT(*) > 1;

-- 3. Blanks?
SELECT COUNT(*) FROM stg_table WHERE id_col IS NULL OR id_col = '';

-- 4. How long does the text actually get?
SELECT MAX(LENGTH(some_text_col)) FROM stg_table;

-- 5. What values does a category column actually hold?
SELECT some_col, COUNT(*) FROM stg_table GROUP BY some_col ORDER BY 2 DESC;
```

Check 5 is the one people skip. It's how you find that "Status" has 11 values
rather than the 2 you assumed.

---

## The check that matters most

**Verify one number you already know the answer to.**

Steam: English came out at 2.15%. Nearly every Steam game is in English, so the
parse had to be wrong — and it was. If the first result had been plausible but
wrong, it would have gone straight into the analysis unnoticed.

Pick something you can predict — a total, a well-known share, a row count from
the source system — and check that first. A result that's obviously absurd is a
gift. A result that's quietly wrong is the thing that ends up in a slide deck.

---

## Constraints: only claim what you've tested

A constraint is a claim about the data.

| Want | Test | Add it if |
|---|---|---|
| `PRIMARY KEY` | `GROUP BY col HAVING COUNT(*) > 1` | zero rows returned |
| `NOT NULL` | `WHERE col IS NULL OR col = ''` | count is 0 |
| `FOREIGN KEY` | left-join the parent, count unmatched | count is 0 |
| `VARCHAR(n)` | `MAX(LENGTH(col))` | n is comfortably above it — or use `TEXT` |

Staging tables get **no** constraints and all-text columns. Constraints reject
rows, and a rejected row during import is invisible data loss. Load everything,
inspect, then tighten in the clean table.

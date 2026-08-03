/* ============================================================================
   03_analysis.sql
   Steam — Bahasa Indonesia localisation analysis
   Target: MySQL 8.0

   Question: how well served are Indonesian players on Steam, and is it
   improving?

   Headline: only 3.36% of 125,855 Steam games support Bahasa Indonesia. But
   that number is dragged down by history — on current releases the share is
   6%, up from 0.28% in 2015.

   Runs against `games`, the typed layer — not `stg_games`, which is all text.

     stg_games   loaded straight from CSV, every column VARCHAR/TEXT so no
                 value can fail the import
     games       proper types: appid INT PK, price DECIMAL(10,2),
                 release_year SMALLINT, has_indonesian TINYINT

   Converting once at that boundary means nothing downstream needs CAST, and
   nothing downstream can get the conversion wrong.

   Queries written by Dre.
   ========================================================================= */

USE steam;


/* ---------------------------------------------------------------------------
   1. Overall — what share of the whole catalogue supports Indonesian?

   ANSWER: 4,235 of 125,855 = 3.36%
   ------------------------------------------------------------------------ */

SELECT ROUND(100.0 * SUM(has_indonesian) / COUNT(*), 2) AS pct_indonesian
FROM   games;


/* ---------------------------------------------------------------------------
   2. Is it improving? Support by release year.

   ANSWER: yes, sharply. 0.28% in 2015 -> 6.05% in 2025. A 22x increase in
   the share, on a catalogue that itself grew 10x over the same period — so
   this is real localisation growth, not just more games existing.

   CAVEAT: 2026 is a partial year, so its 3,316 games are not comparable to a
   full year. Do not read the last bar as a collapse in releases.
   ------------------------------------------------------------------------ */

SELECT release_year,
       COUNT(*)                AS games,
       SUM(has_indonesian)     AS with_indonesian,
       ROUND(100.0 * SUM(has_indonesian) / COUNT(*), 2) AS pct_indonesian
FROM   games
WHERE  release_year >= 2015
GROUP  BY release_year
ORDER  BY release_year;


/* ---------------------------------------------------------------------------
   3. Compared to whom? Indonesian vs Thai vs Vietnamese, per year.

   ANSWER: the overall gap is historical, not current. Across the whole
   catalogue Indonesian trails Thai (3.36% vs 4.99%), but per-year the two
   have converged:

       2015    Indonesian     7    Thai    38    (Thai 5x ahead)
       2025    Indonesian 1,510    Thai 1,590    (near parity)

   Worth stating plainly: Indonesia has roughly four times Thailand's
   population, so parity in absolute game counts still means far less
   coverage per player.

   Three separate CASE expressions, not one with three branches — a game can
   support several of these languages at once, so a single CASE would assign
   each game to whichever language it tested first and undercount the rest.
   ------------------------------------------------------------------------ */

SELECT release_year,
       COUNT(*) AS games,
       ROUND(100.0 * SUM(has_indonesian) / COUNT(*), 2) AS pct_indonesian,
       SUM(CASE WHEN supported_languages LIKE '%Indonesian%' THEN 1 ELSE 0 END) AS indonesian,
       SUM(CASE WHEN supported_languages LIKE '%Thai%'       THEN 1 ELSE 0 END) AS thai,
       SUM(CASE WHEN supported_languages LIKE '%Vietnamese%' THEN 1 ELSE 0 END) AS vietnamese
FROM   games
WHERE  release_year >= 2015
GROUP  BY release_year
ORDER  BY release_year ASC;


/* ---------------------------------------------------------------------------
   4. Who localises? Support by price band.

   ANSWER: expensive games localise far more — 14.77% of games over $30
   support Indonesian, against 1.88% of free games. Localisation costs money,
   so bigger budgets do it.

   BUT the pattern is not monotonic: Under $10 (3.89%) beats $10-30 (1.67%).
   Unexplained. Worth investigating — possibly cheap Asian-published titles
   localising broadly as standard.

   Prices are USD. Steam sets separate regional prices for Indonesia, so
   these are NOT what an Indonesian player pays — do not convert to rupiah.

   Band boundaries verified with MIN/MAX per band: 0.49-9.99, 10.00-30.00,
   30.09-999.98. No gaps, no overlaps.

   That check originally ran against stg_games and needed an explicit CAST:
   price was stored as text there, and text sorts '109.99' before '30.99', so
   MIN reported the cheapest game over $30 as $109.99. Against `games` no CAST
   is needed — price is DECIMAL(10,2) and compares numerically. That is the
   entire reason the clean layer exists.
   ------------------------------------------------------------------------ */

WITH bands AS (
    SELECT CASE WHEN price = 0 THEN 'Free'
                WHEN price < 10 THEN 'Under 10'
                WHEN price BETWEEN 10 AND 30 THEN '10 to 30'
                ELSE 'Over 30'
           END AS band,
           COUNT(*) AS games,
           SUM(CASE WHEN supported_languages LIKE '%Indonesian%' THEN 1 ELSE 0 END) AS indonesian
    FROM   games
    GROUP  BY band
)
SELECT band,
       games,
       indonesian,
       ROUND(100.0 * indonesian / games, 2) AS percent
FROM   bands;


/* ---------------------------------------------------------------------------
   DATA NOTES

   * The source CSV ships with a BROKEN HEADER: 39 column names describe 40
     data columns, because a missing comma merged "Discount" and "DLC count".
     Every column after "Price" is shifted by one. Caught because English came
     out at 2.15% when it should be ~89% — a result absurd enough to notice.
     A plausible-but-wrong result would have gone straight into the analysis.

   * Steam is PC gaming. Indonesia is a mobile-first games market, so this
     says nothing about Indonesian gaming overall — only about the PC
     catalogue available to Indonesian players.

   * "Supports Indonesian" means the language is listed on the store page. It
     does not distinguish full localisation from subtitles only.
   ------------------------------------------------------------------------ */

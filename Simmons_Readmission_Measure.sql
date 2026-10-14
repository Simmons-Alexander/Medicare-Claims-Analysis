/*
-- HEDIS inspired readmission rate

Data: Synthetic Medicare inpatient claims (2007 - 2010)

Definition
- Initial stay: any inpatient stay with a discharge date on or before 12/01/2010
- Denominator: eligible initial stays
- Numerator: eligible initial stays that have a readmission within 30 days after discharge 
- Rate: numerator / denominator

Exclusions 
- Duplicate claims (same member, admission date, discharge date) (19 duplicates)
- Discharges after 2010-12-01, because the 30 day window extends past the end of the data (313 stays)
- Stays whose next admission begins on or before the discharge date (2,143 stays, 3.2%) 

RESULTS
- 66,754 stays -> 64,298 eligible stays, 6,423 readmissions, 10.0% overall
- Rate rises with condition burden, from 4.0% (no tracked conditions) to 15.6% (all three conditions)

Limitations 
- No way to account for planned readmissions 
- No way to identify transfers directly
- Members missing from 2008 beneficiary file are dropped by the join
- Claim volume drops sharply in Q4 2010 (see Simmons_Data_Exploration.sql), likely a quirk of the synthetic data.
*/

-- Step 1: DATA CLEANING

-- Query 1: Check for duplicate stays (same member, same admission, & same discharge dates)

SELECT
    COUNT(*) AS duplicate_stay_groups,
    SUM(row_count - 1) AS extra_rows
FROM (
    SELECT
        member_id,
        admission_date,
        discharge_date,
        COUNT(*) AS row_count
    FROM `medicare_claims.fact_claims`
    GROUP BY member_id, admission_date, discharge_date
    HAVING COUNT(*) > 1
);

-- Query 2: 

WITH stays AS (
    SELECT DISTINCT
        fact.member_id,
        PARSE_DATE('%Y%m%d', CAST(fact.admission_date AS STRING)) AS admission_date,
        PARSE_DATE('%Y%m%d', CAST(fact.discharge_date AS STRING)) AS discharge_date
    FROM `medicare_claims.fact_claims` AS fact
    INNER JOIN `medicare_claims.dim_members` AS dim
        ON fact.member_id = dim.member_id
    WHERE fact.admission_date IS NOT NULL
      AND fact.discharge_date IS NOT NULL
)
SELECT
    COUNT(*) AS total_stays,
    COUNT(DISTINCT member_id) AS unique_members,
    MIN(admission_date) AS earliest_admission,
    MAX(discharge_date) AS latest_discharge,
    COUNTIF(discharge_date < admission_date) AS discharge_before_admission
FROM stays;

-- Removed duplicate rows, dropped claims missing a date, & verified there are no entries where
-- the discharge date procedes the admission date. 

-- Step 2: CALCULATE 30 DAY READMISSION RATE

-- Query 3: Classify each stay & count by category 

WITH stays AS (
    SELECT DISTINCT
        fact.member_id,
        PARSE_DATE('%Y%m%d', CAST(fact.admission_date AS STRING)) AS admission_date,
        PARSE_DATE('%Y%m%d', CAST(fact.discharge_date AS STRING)) AS discharge_date
    FROM `medicare_claims.fact_claims` AS fact
    INNER JOIN `medicare_claims.dim_members` AS dim
        ON fact.member_id = dim.member_id
    WHERE fact.admission_date IS NOT NULL
      AND fact.discharge_date IS NOT NULL
),
sequenced AS (
    SELECT
        member_id,
        admission_date,
        discharge_date,
        LEAD(admission_date) OVER (
            PARTITION BY member_id
            ORDER BY admission_date, discharge_date
        ) AS next_admission_date
    FROM stays
),
classified AS (
    SELECT
        *,
        DATE_DIFF(next_admission_date, discharge_date, DAY) AS days_to_next
    FROM sequenced
)
SELECT
    CASE
        WHEN discharge_date > DATE '2010-12-01'
            THEN '1 - Excluded: discharge in final 30 days of data'
        WHEN days_to_next <= 0
            THEN '2 - Excluded: same day or overlapping next admission'
        WHEN days_to_next BETWEEN 1 AND 30
            THEN '3 - Readmitted within 30 days'
        ELSE '4 - Not readmitted within 30 days'
    END AS category,
    COUNT(*) AS stays
FROM classified
GROUP BY category
ORDER BY category;

-- Calculated time between discharge date and next admission. 
-- Created buckets to isolate readmissions within 30 days. 
-- A member's last stay has no next admission, so it is labelled as "Not readmitted". 


-- Query 4: Calculate 30 day readmission rate for total group & for each health profile 

WITH stays AS (
    SELECT DISTINCT
        fact.member_id,
        dim.member_health_profile,
        PARSE_DATE('%Y%m%d', CAST(fact.admission_date AS STRING)) AS admission_date,
        PARSE_DATE('%Y%m%d', CAST(fact.discharge_date AS STRING)) AS discharge_date
    FROM `medicare_claims.fact_claims` AS fact
    INNER JOIN `medicare_claims.dim_members` AS dim
        ON fact.member_id = dim.member_id
    WHERE fact.admission_date IS NOT NULL
      AND fact.discharge_date IS NOT NULL
),
sequenced AS (
    SELECT
        member_id,
        member_health_profile,
        admission_date,
        discharge_date,
        LEAD(admission_date) OVER (
            PARTITION BY member_id
            ORDER BY admission_date, discharge_date
        ) AS next_admission_date
    FROM stays
),
classified AS (
    SELECT
        *,
        DATE_DIFF(next_admission_date, discharge_date, DAY) AS days_to_next
    FROM sequenced
),
eligible AS (
    SELECT *
    FROM classified
    WHERE discharge_date <= DATE '2010-12-01'
      AND (days_to_next IS NULL OR days_to_next >= 1)
)
SELECT
    COALESCE(member_health_profile, 'ALL MEMBERS') AS member_health_profile,
    COUNT(*) AS eligible_stays,
    COUNTIF(days_to_next BETWEEN 1 AND 30) AS readmissions,
    ROUND(SAFE_DIVIDE(COUNTIF(days_to_next BETWEEN 1 AND 30), COUNT(*)) * 100, 1) AS readmission_rate_pct
FROM eligible
GROUP BY ROLLUP(member_health_profile)
ORDER BY readmission_rate_pct DESC;

-- Learned ROLLUP to add an extra row to get overall total. 
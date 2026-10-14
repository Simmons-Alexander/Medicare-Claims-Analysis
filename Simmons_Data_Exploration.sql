-- STEP 1: DATA EXPLORATION

-- Query 1: Verifying data imported correctly 

SELECT 
'beneficiary_summary_2008' AS table_name, COUNT(*) AS total_rows
FROM `medicare_claims.beneficiary_summary_2008`
UNION ALL
SELECT 
'inpatient_claims_2008_2010' AS table_name, COUNT(*) AS total_rows
FROM `medicare_claims.inpatient_claims_2008_2010`;

-- Beneficiary data is available for 2008, but inpatient claims span late 2007 - 2010. 
-- 226 claims (.3% of total claims) have late 2007 admission dates, included since processed/discharged date 
-- is in 2008.  
-- INNER JOINs will drop claims from members not in the 2008 beneficiary file.  
-- Results reflect a fixed 2008 population, not each year's actual population, creating bias.

-- Query 2: Previewing the first 10 members to find ID and demographic columns

SELECT * FROM `medicare_claims.beneficiary_summary_2008` 
LIMIT 10;

-- Query 3: Previewing the first 10 claims to look for admission dates and costs columns

SELECT * FROM `medicare_claims.inpatient_claims_2008_2010` 
LIMIT 10;

-- Query 4: Checking total claim records and highest single primary payer payment 

SELECT 
    COUNT(desynpuf_id) AS total_claims_count, 
    MAX(nch_prmry_pyr_clm_pd_amt) AS max_primary_payer_payment
FROM `medicare_claims.inpatient_claims_2008_2010`;

-- Discovered desynpuf_id is present in both tables and will be used as the join key. 

-- STEP 2: BUILDING STAR SCHEMA 

-- Query 1: Creating a dimension table from the raw beneficiary_summary_2008 data

CREATE OR REPLACE TABLE `medicare_claims.dim_members` AS 
SELECT 
    desynpuf_id AS member_id, 
    bene_birth_dt AS member_birth_date, 
    CASE
        WHEN bene_sex_ident_cd = 1 THEN 'Male'
        WHEN bene_sex_ident_cd = 2 THEN 'Female'
        ELSE 'Unknown'
    END AS gender, 
    CASE
        WHEN sp_diabetes = 1 THEN 1
        ELSE 0
    END AS has_diabetes, 
    CASE
        WHEN sp_chrnkidn = 1 THEN 1
        ELSE 0
    END AS has_kidney_disease,
    CASE
        WHEN sp_chf = 1 THEN 1
        ELSE 0
    END AS has_heart_failure,
    CASE 
        WHEN sp_diabetes = 1 AND sp_chrnkidn = 1 AND sp_chf = 1 THEN 'All 3 Conditions'
        WHEN sp_chrnkidn = 1 AND sp_chf = 1 THEN 'Kidney & Heart Failure'
        WHEN sp_diabetes = 1 AND sp_chrnkidn = 1 THEN 'Diabetes & Kidney Disease'
        WHEN sp_diabetes = 1 AND sp_chf = 1 THEN 'Diabetes & Heart Failure'
        WHEN sp_chrnkidn = 1 THEN 'Kidney Disease Only'
        WHEN sp_chf = 1 THEN 'Heart Failure Only'
        WHEN sp_diabetes = 1 THEN 'Diabetes Only'
        ELSE 'No Tracked Chronic Conditions'
    END AS member_health_profile
FROM `medicare_claims.beneficiary_summary_2008`;

-- Discovered beneficiary table contains one record per member, making it suitable as a dimension table. 
-- Confirmed via GROUP BY that each condition in dataset is flagged as either 'Yes' or 'No', no unknowns or NULLs.  

-- Query 2: Creating a fact table from the raw inpatient_claims_2008_2010 data 

CREATE OR REPLACE TABLE `medicare_claims.fact_claims` AS
SELECT 
desynpuf_id AS member_id, 
clm_admsn_dt AS admission_date, 
nch_bene_dschrg_dt AS discharge_date, 
clm_pmt_amt as plan_paid_amount, 
COALESCE(nch_prmry_pyr_clm_pd_amt, 0) AS primary_payer_paid_amount 
FROM `medicare_claims.inpatient_claims_2008_2010`;

-- Discovered primary payer payment contains NULL values, so used COALESCE.

-- Query 3: Validating the Star Schema by Summarizing Claims by Gender

SELECT 
    dim.gender,
    COUNT(fact.member_id) AS total_claims,
    SUM(fact.plan_paid_amount) AS total_plan_spend,
    SUM(fact.primary_payer_paid_amount) AS total_primary_payer_spend
FROM `medicare_claims.fact_claims` AS fact
INNER JOIN `medicare_claims.dim_members` AS dim
    ON fact.member_id = dim.member_id
GROUP BY dim.gender;

-- STEP 3: POPULATION HEALTH AND UTILIZATION COHORTS

-- Query 1: Grouping members by how many chronic illnesses they have to see its impact on cost. 

SELECT 
    (dim.has_diabetes + dim.has_kidney_disease + dim.has_heart_failure) AS condition_count,
    COUNT(DISTINCT fact.member_id) AS unique_members,
    COUNT(fact.member_id) AS total_claims,
    ROUND(SUM(fact.plan_paid_amount), 2) AS total_plan_spend,
    ROUND(AVG(fact.plan_paid_amount), 2) AS avg_spend_per_claim
FROM `medicare_claims.fact_claims` AS fact
INNER JOIN `medicare_claims.dim_members` AS dim
    ON fact.member_id = dim.member_id
GROUP BY condition_count
ORDER BY condition_count DESC;

-- Query 2: Summarizes claims and spend by member health profile 

CREATE OR REPLACE VIEW `medicare_claims.v_health_profile_spend_summary` AS
SELECT 
    dim.member_health_profile,
    COUNT(fact.member_id) AS total_claims,
    ROUND(SUM(fact.plan_paid_amount), 2) AS total_plan_spend,
    ROUND(AVG(fact.plan_paid_amount), 2) AS avg_spend_per_claim
FROM `medicare_claims.fact_claims` AS fact
INNER JOIN `medicare_claims.dim_members` AS dim
    ON fact.member_id = dim.member_id
GROUP BY dim.member_health_profile;

-- Query 3: Utilization by Age Groups

WITH member_ages AS (
    SELECT 
        fact.plan_paid_amount,
        dim.member_birth_date,
        DATE_DIFF(
            PARSE_DATE('%Y%m%d', CAST(fact.admission_date AS STRING)),
            PARSE_DATE('%Y%m%d', CAST(dim.member_birth_date AS STRING)),
            YEAR
        ) AS calculated_age
    FROM `medicare_claims.fact_claims` AS fact
    INNER JOIN `medicare_claims.dim_members` AS dim
        ON fact.member_id = dim.member_id
)
SELECT 
    CASE 
        WHEN member_birth_date = 19090101 THEN 'Unknown DOB'
        WHEN calculated_age < 65 THEN 'Under 65'
        WHEN calculated_age BETWEEN 65 AND 74 THEN '65 to 74'
        WHEN calculated_age BETWEEN 75 AND 84 THEN '75 to 84'
        ELSE '85 and Older'
    END AS age_group,
    COUNT(*) AS total_claims,
    ROUND(SUM(plan_paid_amount), 2) AS total_plan_spend,
    ROUND(AVG(plan_paid_amount), 2) AS avg_spend_per_claim
FROM member_ages
GROUP BY age_group
ORDER BY age_group;

-- Ages is calculated relative to each claim's admission year, not a fixed year. 
-- Using 2008 as a fixed year would cause ages to be incorrect for claims in other years. 
-- Learned PARSE_DATE to convert integer to DATE. 
-- Discovered that many birth dates appear as 19090101. Ran a query isolating for that date that returned 52 rows. 
-- Ran a new query separating them into their own bucket. 
-- Isolating them prevents them from artificially inflating 85+ bucket, as it is not likely so many were
-- born on that date. 

-- Query 4: Utilization by Gender

SELECT 
    dim.gender AS member_gender,
    COUNT(fact.member_id) AS total_claims,
    ROUND(SUM(fact.plan_paid_amount), 2) AS total_plan_spend,
    ROUND(AVG(fact.plan_paid_amount), 2) AS avg_spend_per_claim
FROM `medicare_claims.fact_claims` AS fact
INNER JOIN `medicare_claims.dim_members` AS dim
    ON fact.member_id = dim.member_id
GROUP BY member_gender;

-- Query 5: Ranks Total Spend by Member Health Profile 

SELECT 
    member_health_profile,
    total_claims,
    total_plan_spend,
    DENSE_RANK() OVER (ORDER BY total_plan_spend DESC) AS spend_rank
FROM `medicare_claims.v_health_profile_spend_summary`
ORDER BY spend_rank;

-- Query 6: Identifying High-Utilization Members

WITH threshold AS (
    SELECT APPROX_QUANTILES(total_member_claims, 100)[OFFSET(95)] AS p95_claim_count
    FROM (
        SELECT member_id, COUNT(*) AS total_member_claims
        FROM `medicare_claims.fact_claims`
        GROUP BY member_id
    )
),
claim_counts AS (
    SELECT 
        member_id,
        COUNT(*) AS total_member_claims
    FROM `medicare_claims.fact_claims`
    GROUP BY member_id
    HAVING COUNT(*) > (SELECT p95_claim_count FROM threshold)
)
SELECT 
    member_id,
    total_member_claims
FROM claim_counts
ORDER BY total_member_claims DESC;

-- Needed a way to calculated percentiles, so I Learned APPROX_QUANTILES in BigQuery to find
-- the 95th percentile threshold (4 claims). 

-- Query 7: Average Length of Stay by Member Health Profile

SELECT 
    dim.member_health_profile,
    COUNT(fact.member_id) AS total_claims,
    ROUND(AVG(DATE_DIFF(
        PARSE_DATE('%Y%m%d', CAST(fact.discharge_date AS STRING)), 
        PARSE_DATE('%Y%m%d', CAST(fact.admission_date AS STRING)), 
        DAY
    )), 1) AS avg_length_of_stay_days
FROM `medicare_claims.fact_claims` AS fact
INNER JOIN `medicare_claims.dim_members` AS dim
    ON fact.member_id = dim.member_id
GROUP BY dim.member_health_profile
ORDER BY avg_length_of_stay_days DESC;

-- Discovered admission & discharge dates are stored as integers, so they are converted to DATE
-- before calculating length of stay. 

-- Query 8: Yearly Spend Trend

WITH yearly_spend AS (
    SELECT 
        DIV(admission_date, 10000) AS admission_year,
        COUNT(*) AS total_claims,
        ROUND(SUM(plan_paid_amount), 2) AS total_plan_spend
    FROM `medicare_claims.fact_claims`
    GROUP BY admission_year
),
with_prior_year AS (
    SELECT 
        admission_year,
        total_claims,
        total_plan_spend,
        LAG(total_plan_spend) OVER (ORDER BY admission_year) AS prior_year_spend
    FROM yearly_spend
)
SELECT 
    admission_year,
    total_claims,
    total_plan_spend,
    prior_year_spend,
    ROUND(total_plan_spend - prior_year_spend, 2) AS yoy_dollar_change,
    CASE 
        WHEN prior_year_spend IS NULL OR prior_year_spend = 0 THEN NULL
        ELSE ROUND((total_plan_spend - prior_year_spend) / prior_year_spend * 100, 1)
    END AS yoy_percent_change
FROM with_prior_year
ORDER BY admission_year;

-- Query 9 & 10: Checking if claim volume decline in 2010 is valid

SELECT
  DATE_TRUNC(PARSE_DATE('%Y%m%d', CAST(admission_date AS STRING)), MONTH)
    AS year_month,
  COUNT(*) AS claims,
  COUNT(DISTINCT member_id) AS members
FROM `medicare_claims.fact_claims`
WHERE admission_date BETWEEN 20090101 AND 20101231
GROUP BY year_month
ORDER BY year_month;

SELECT
  DATE_TRUNC(PARSE_DATE('%Y%m%d', CAST(discharge_date AS STRING)), MONTH)
    AS year_month,
  COUNT(*) AS claims,
  COUNT(DISTINCT member_id) AS members
FROM `medicare_claims.fact_claims`
WHERE discharge_date BETWEEN 20070101 AND 20111231
GROUP BY year_month
ORDER BY year_month;

-- Discovered claim volume steadily declines across 2010 with a sharp drop-off in Q4. 
-- Monthly claim counts by admission date and discharge date show same pattern. 
-- This is a characteristic of the dataset, perhaps because it is synthetic. 


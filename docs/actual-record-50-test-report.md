# Actual Record Test Report: 50 Account Heuristic Dedupe Run

Date: June 30, 2026  
Org: `Agentforce@dreaminforce.com`  
Object tested: `Account`  
Test type: actual Salesforce records, not only Apex test data

## Summary

We tested the deployed enterprise heuristic duplicate scanner with 50 real Account records inserted into the org.

The dataset contained:

| Record Type | Count |
| --- | ---: |
| Intentional duplicate records | 25 |
| Intentional unique records | 25 |
| Total actual records inserted | 50 |

Final result after tuning and redeploy:

| Result | Count |
| --- | ---: |
| Expected duplicate records | 25 |
| Duplicate records correctly flagged | 25 |
| Expected unique records | 25 |
| Unique records incorrectly flagged | 0 |
| Duplicate groups from the 50-record dataset | 5 |
| Temporary candidate rows remaining | 0 |
| Temporary pair rows remaining | 0 |

## Deployment Used For Final Test

The larger actual-record test exposed one heuristic gap, so the scorer was tuned and redeployed before the final rerun.

Final deploy:

| Item | Value |
| --- | --- |
| Deploy job id | `0AfdL00000ciTTRSA2` |
| Apex test class | `HeuristicDuplicateScanServiceTest` |
| Tests completed | 18 |
| Component errors | 0 |
| Test failures | 0 |
| Deploy status | Succeeded |

## Test Data Created

The 50 records were created with this marker:

```text
Codex 50 Record Dedupe Test 1782822964158
```

The dataset had 5 duplicate clusters, each with 5 related Account names, plus 25 unique Accounts.

Duplicate clusters:

| Group | Example Names |
| --- | --- |
| Group 1 | Blue Sky Consulting, Blue Sky Ltd., BlueSky Consulting, Blue Sky Consultancy, Blue Sky Co |
| Group 2 | Northwind Traders, North Wind Traders LLC, Northwind Trading, Northwind Traders Ltd., North Wind Trade Co |
| Group 3 | Acme Logistics, Acme Logistic Services, ACME Logistics Inc, Acme Logistics Ltd., Acme Freight Logistics |
| Group 4 | Green Farm Supply, GreenFarm Supplies, Green Farm LLC, Green Farm Supply Co, Green Farm Suppliers |
| Group 5 | Ocean Harbor Services, OceanHarbor Services, Ocean Harbor Ltd, Ocean Harbor Service Co, Ocean Harbor Support |

## Functionality Tested

This was not only a deployment or Apex unit-test check. The test exercised the actual runtime flow against real Account records in the org.

| Step | Functionality | What Happened In This Test |
| ---: | --- | --- |
| 1 | Insert actual Account records | 50 real Account records were inserted into `Agentforce@dreaminforce.com`. |
| 2 | Allow intentional duplicates | Salesforce duplicate rules initially blocked duplicate-looking records, so the insert was rerun with duplicate-rule allow-save for this test dataset. |
| 3 | Start scan from deployed Apex | `HeuristicDuplicateScanController.startScan('Account', 6000, 75, true)` started a real scan. |
| 4 | Use enterprise scan path | `Max Records = 6000`, so the scanner used the staged enterprise path rather than the small inline path. |
| 5 | Stage candidate rows | The scanner created temporary candidate rows using bucket keys from normalized name, phone, email, and website domain clues. |
| 6 | Analyze buckets | The analyzer grouped temporary rows by full `Bucket_Key__c` and compared only records inside the same bucket. |
| 7 | Write matched pairs | Pairs scoring at or above threshold `75` were written to `Heuristic_Duplicate_Pair__c`. |
| 8 | Consolidate overlapping pairs | The pair consolidator merged connected pairs into final groups, so `{A, B}` plus `{B, C}` becomes `{A, B, C}`. |
| 9 | Persist final output | Final `Heuristic_Duplicate_Group__c` and `Heuristic_Duplicate_Member__c` records were written. |
| 10 | Cleanup temporary rows | Temporary candidate and pair rows were deleted after completion. |
| 11 | Verify actual output | The final groups were checked against the 50 actual Account ids. |

## Actual Records Inserted

These are the actual Account records used for the 50-record test.

| # | Expected Result | Salesforce Id | Account Name | Phone | Website | City |
| ---: | --- | --- | --- | --- | --- | --- |
| 1 | Duplicate Group 1 | `001dL00002Hn0AZQAZ` | Blue Sky Consulting | `2125550144` | `codex50-g1-1782822964158.example` | New York |
| 2 | Duplicate Group 1 | `001dL00002Hn0AaQAJ` | Blue Sky Ltd. | `2125550144` | `https://codex50-g1-1782822964158.example` | New York |
| 3 | Duplicate Group 1 | `001dL00002Hn0AbQAJ` | BlueSky Consulting | `7000000002` | `codex50-g1-1782822964158.example` | New York |
| 4 | Duplicate Group 1 | `001dL00002Hn0AcQAJ` | Blue Sky Consultancy | `7000000003` | `https://codex50-g1-1782822964158.example` | New York |
| 5 | Duplicate Group 1 | `001dL00002Hn0AdQAJ` | Blue Sky Co | `7000000004` | `codex50-g1-1782822964158.example` | New York |
| 6 | Duplicate Group 2 | `001dL00002Hn0AeQAJ` | Northwind Traders | `2065550199` | `codex50-g2-1782822964158.example` | Seattle |
| 7 | Duplicate Group 2 | `001dL00002Hn0AfQAJ` | North Wind Traders LLC | `2065550199` | `https://codex50-g2-1782822964158.example` | Seattle |
| 8 | Duplicate Group 2 | `001dL00002Hn0AgQAJ` | Northwind Trading | `7000000102` | `codex50-g2-1782822964158.example` | Seattle |
| 9 | Duplicate Group 2 | `001dL00002Hn0AhQAJ` | Northwind Traders Ltd. | `7000000103` | `https://codex50-g2-1782822964158.example` | Seattle |
| 10 | Duplicate Group 2 | `001dL00002Hn0AiQAJ` | North Wind Trade Co | `7000000104` | `codex50-g2-1782822964158.example` | Seattle |
| 11 | Duplicate Group 3 | `001dL00002Hn0AjQAJ` | Acme Logistics | `3035550111` | `codex50-g3-1782822964158.example` | Denver |
| 12 | Duplicate Group 3 | `001dL00002Hn0AkQAJ` | Acme Logistic Services | `3035550111` | `https://codex50-g3-1782822964158.example` | Denver |
| 13 | Duplicate Group 3 | `001dL00002Hn0AlQAJ` | ACME Logistics Inc | `7000000202` | `codex50-g3-1782822964158.example` | Denver |
| 14 | Duplicate Group 3 | `001dL00002Hn0AmQAJ` | Acme Logistics Ltd. | `7000000203` | `https://codex50-g3-1782822964158.example` | Denver |
| 15 | Duplicate Group 3 | `001dL00002Hn0AnQAJ` | Acme Freight Logistics | `7000000204` | `codex50-g3-1782822964158.example` | Denver |
| 16 | Duplicate Group 4 | `001dL00002Hn0AoQAJ` | Green Farm Supply | `5125550188` | `codex50-g4-1782822964158.example` | Austin |
| 17 | Duplicate Group 4 | `001dL00002Hn0ApQAJ` | GreenFarm Supplies | `5125550188` | `https://codex50-g4-1782822964158.example` | Austin |
| 18 | Duplicate Group 4 | `001dL00002Hn0AqQAJ` | Green Farm LLC | `7000000302` | `codex50-g4-1782822964158.example` | Austin |
| 19 | Duplicate Group 4 | `001dL00002Hn0ArQAJ` | Green Farm Supply Co | `7000000303` | `https://codex50-g4-1782822964158.example` | Austin |
| 20 | Duplicate Group 4 | `001dL00002Hn0AsQAJ` | Green Farm Suppliers | `7000000304` | `codex50-g4-1782822964158.example` | Austin |
| 21 | Duplicate Group 5 | `001dL00002Hn0AtQAJ` | Ocean Harbor Services | `3055550166` | `codex50-g5-1782822964158.example` | Miami |
| 22 | Duplicate Group 5 | `001dL00002Hn0AuQAJ` | OceanHarbor Services | `3055550166` | `https://codex50-g5-1782822964158.example` | Miami |
| 23 | Duplicate Group 5 | `001dL00002Hn0AvQAJ` | Ocean Harbor Ltd | `7000000402` | `codex50-g5-1782822964158.example` | Miami |
| 24 | Duplicate Group 5 | `001dL00002Hn0AwQAJ` | Ocean Harbor Service Co | `7000000403` | `https://codex50-g5-1782822964158.example` | Miami |
| 25 | Duplicate Group 5 | `001dL00002Hn0AxQAJ` | Ocean Harbor Support | `7000000404` | `codex50-g5-1782822964158.example` | Miami |
| 26 | Unique | `001dL00002Hn0AyQAJ` | Codex Unique Company 1 1782822964158 | `8000000000` | `codex50-unique-1-1782822964158.example` | City 1 |
| 27 | Unique | `001dL00002Hn0AzQAJ` | Codex Unique Company 2 1782822964158 | `8000000001` | `codex50-unique-2-1782822964158.example` | City 2 |
| 28 | Unique | `001dL00002Hn0B0QAJ` | Codex Unique Company 3 1782822964158 | `8000000002` | `codex50-unique-3-1782822964158.example` | City 3 |
| 29 | Unique | `001dL00002Hn0B1QAJ` | Codex Unique Company 4 1782822964158 | `8000000003` | `codex50-unique-4-1782822964158.example` | City 4 |
| 30 | Unique | `001dL00002Hn0B2QAJ` | Codex Unique Company 5 1782822964158 | `8000000004` | `codex50-unique-5-1782822964158.example` | City 5 |
| 31 | Unique | `001dL00002Hn0B3QAJ` | Codex Unique Company 6 1782822964158 | `8000000005` | `codex50-unique-6-1782822964158.example` | City 6 |
| 32 | Unique | `001dL00002Hn0B4QAJ` | Codex Unique Company 7 1782822964158 | `8000000006` | `codex50-unique-7-1782822964158.example` | City 7 |
| 33 | Unique | `001dL00002Hn0B5QAJ` | Codex Unique Company 8 1782822964158 | `8000000007` | `codex50-unique-8-1782822964158.example` | City 8 |
| 34 | Unique | `001dL00002Hn0B6QAJ` | Codex Unique Company 9 1782822964158 | `8000000008` | `codex50-unique-9-1782822964158.example` | City 9 |
| 35 | Unique | `001dL00002Hn0B7QAJ` | Codex Unique Company 10 1782822964158 | `8000000009` | `codex50-unique-10-1782822964158.example` | City 10 |
| 36 | Unique | `001dL00002Hn0B8QAJ` | Codex Unique Company 11 1782822964158 | `8000000010` | `codex50-unique-11-1782822964158.example` | City 11 |
| 37 | Unique | `001dL00002Hn0B9QAJ` | Codex Unique Company 12 1782822964158 | `8000000011` | `codex50-unique-12-1782822964158.example` | City 12 |
| 38 | Unique | `001dL00002Hn0BAQAZ` | Codex Unique Company 13 1782822964158 | `8000000012` | `codex50-unique-13-1782822964158.example` | City 13 |
| 39 | Unique | `001dL00002Hn0BBQAZ` | Codex Unique Company 14 1782822964158 | `8000000013` | `codex50-unique-14-1782822964158.example` | City 14 |
| 40 | Unique | `001dL00002Hn0BCQAZ` | Codex Unique Company 15 1782822964158 | `8000000014` | `codex50-unique-15-1782822964158.example` | City 15 |
| 41 | Unique | `001dL00002Hn0BDQAZ` | Codex Unique Company 16 1782822964158 | `8000000015` | `codex50-unique-16-1782822964158.example` | City 16 |
| 42 | Unique | `001dL00002Hn0BEQAZ` | Codex Unique Company 17 1782822964158 | `8000000016` | `codex50-unique-17-1782822964158.example` | City 17 |
| 43 | Unique | `001dL00002Hn0BFQAZ` | Codex Unique Company 18 1782822964158 | `8000000017` | `codex50-unique-18-1782822964158.example` | City 18 |
| 44 | Unique | `001dL00002Hn0BGQAZ` | Codex Unique Company 19 1782822964158 | `8000000018` | `codex50-unique-19-1782822964158.example` | City 19 |
| 45 | Unique | `001dL00002Hn0BHQAZ` | Codex Unique Company 20 1782822964158 | `8000000019` | `codex50-unique-20-1782822964158.example` | City 20 |
| 46 | Unique | `001dL00002Hn0BIQAZ` | Codex Unique Company 21 1782822964158 | `8000000020` | `codex50-unique-21-1782822964158.example` | City 21 |
| 47 | Unique | `001dL00002Hn0BJQAZ` | Codex Unique Company 22 1782822964158 | `8000000021` | `codex50-unique-22-1782822964158.example` | City 22 |
| 48 | Unique | `001dL00002Hn0BKQAZ` | Codex Unique Company 23 1782822964158 | `8000000022` | `codex50-unique-23-1782822964158.example` | City 23 |
| 49 | Unique | `001dL00002Hn0BLQAZ` | Codex Unique Company 24 1782822964158 | `8000000023` | `codex50-unique-24-1782822964158.example` | City 24 |
| 50 | Unique | `001dL00002Hn0BMQAZ` | Codex Unique Company 25 1782822964158 | `8000000024` | `codex50-unique-25-1782822964158.example` | City 25 |

The 25 unique records used names like:

```text
Codex Unique Company 1 1782822964158
Codex Unique Company 2 1782822964158
...
Codex Unique Company 25 1782822964158
```

## First Run Finding

Initial scan id:

```text
a08dL00000dSHCLQA4
```

The first 50-record run found:

| Metric | Value |
| --- | ---: |
| Expected duplicate records | 25 |
| Duplicate records flagged | 24 |
| Unique records incorrectly flagged | 0 |

The missed record was:

```text
Acme Freight Logistics
```

Why it was missed:

`Acme Logistics` and `Acme Freight Logistics` shared domain and city, but the name scorer was too strict when a meaningful token was inserted in the middle of the company name.

This was a useful real-data finding. The heuristic was updated so token-subset names can score correctly when the other evidence is strong.

Example:

| Record A | Record B | Why It Should Match |
| --- | --- | --- |
| Acme Logistics | Acme Freight Logistics | The shorter meaningful name tokens are contained inside the longer name, and the domain/city also match |

## Final Rerun

Final scan id:

```text
a08dL00000dS39QQAS
```

Overall scan metrics:

| Metric | Value |
| --- | ---: |
| Scan status | Completed |
| Total org Accounts scanned | 74 |
| Processed Accounts | 74 |
| Candidate comparisons | 149 |
| Overall flagged records | 33 |
| Overall flagged groups | 7 |
| Error message | None |

The scan processed 74 Accounts because the org already contained earlier test Accounts. The report below isolates only the 50 records from this test dataset.

## Step-By-Step Execution

### Step 1: Insert Actual Records

| Input | Value |
| --- | --- |
| Records inserted | 50 actual `Account` records |
| Duplicate groups inserted | 5 groups |
| Records per duplicate group | 5 |
| Unique records inserted | 25 |
| Test marker | `Codex 50 Record Dedupe Test 1782822964158` |

The records were intentionally realistic:

| Pattern | Example |
| --- | --- |
| Exact-ish names with legal suffix | `Blue Sky Consulting` vs `Blue Sky Ltd.` |
| Spacing difference | `Northwind Traders` vs `North Wind Traders LLC` |
| Inserted token | `Acme Logistics` vs `Acme Freight Logistics` |
| Singular/plural difference | `Green Farm Supply` vs `Green Farm Suppliers` |
| Joined words | `Ocean Harbor Services` vs `OceanHarbor Services` |

### Step 2: Start The Scan

| Scan Input | Value |
| --- | --- |
| Object | `Account` |
| Max records | 6000 |
| Threshold | 75 |
| Clear previous results | `true` |
| Final scan id | `a08dL00000dS39QQAS` |

Because `Max records` was greater than 5000, the scanner used the enterprise staged path.

### Step 3: Candidate Staging

For each scanned Account, the scanner created temporary candidate rows from matching clues.

| Bucket Type | Example Source Field | Example Bucket Key |
| --- | --- | --- |
| Name + city | `Blue Sky Consulting`, `New York` | `N|bluesk|newyork` |
| Phone | `2125550144` | `P|2125550144` |
| Website domain | `https://codex50-g1-1782822964158.example` | `D|codex50-g1-1782822964158.example` |
| Email | Blank for these Accounts | No email bucket created |

The scanner does not compare every record with every other record. It only compares records that share a full bucket key.

### Step 4: Bucket Analysis

The analyzer read the temporary candidate rows ordered by full `Bucket_Key__c`.

| Bucket Key Example | Records In That Bucket | Analyzer Behavior |
| --- | --- | --- |
| `P|2125550144` | Blue Sky Consulting, Blue Sky Ltd. | Compare these records because they share a phone bucket. |
| `D|codex50-g1-1782822964158.example` | All 5 Blue Sky test records | Compare records in this domain bucket. |
| `D|codex50-unique-1-1782822964158.example` | Codex Unique Company 1 | Ignore for matching because only one record is in the bucket. |

### Step 5: Pair Scoring

Pairs inside a bucket were scored.

| Evidence | Example | Effect |
| --- | --- | --- |
| Same normalized phone | `2125550144` and `2125550144` | Strong positive signal |
| Same website domain | `codex50-g1-...example` and `https://codex50-g1-...example` | Strong positive signal |
| Same city | `New York` and `New York` | Small positive signal |
| Similar name | `Blue Sky Consulting` and `BlueSky Consulting` | Positive signal |
| Inserted token name | `Acme Logistics` and `Acme Freight Logistics` | Positive signal after tuning |

If the final score was at least `75`, the pair was considered a duplicate pair.

### Step 6: Pair Consolidation

The scanner then consolidated overlapping matched pairs.

| Matched Pair Evidence | Consolidation Effect |
| --- | --- |
| Blue Sky Consulting matched Blue Sky Ltd. | Creates one connection. |
| Blue Sky Ltd. matched BlueSky Consulting | Extends the same connected set. |
| BlueSky Consulting matched Blue Sky Consultancy | Extends the same connected set again. |
| Blue Sky Consultancy matched Blue Sky Co | Adds the fifth Blue Sky record. |
| All connected Blue Sky records | Persisted as one final duplicate group. |

This phase is what protects the system from treating connected duplicates as separate small groups.

### Step 7: Persist Final Groups

The final groups were written to:

| Object | Purpose |
| --- | --- |
| `Heuristic_Duplicate_Group__c` | One row per final duplicate group |
| `Heuristic_Duplicate_Member__c` | One row per record inside a final duplicate group |

### Step 8: Cleanup

After the final groups were saved, temporary rows were deleted.

| Temporary Object | Final Remaining Rows |
| --- | ---: |
| `Heuristic_Duplicate_Candidate__c` | 0 |
| `Heuristic_Duplicate_Pair__c` | 0 |

## Final 50-Record Dataset Result

| Metric | Value |
| --- | ---: |
| Test Accounts found by id | 50 |
| Expected duplicate records | 25 |
| Expected unique records | 25 |
| Test records flagged as duplicate members | 25 |
| Duplicate groups from test records | 5 |
| Unique test records incorrectly flagged | 0 |
| Groups mixed with older org test records | 1 |

One Blue Sky group also included older Blue Sky test records already present in the org. That is expected because the scanner compares real org records, not only the 50 inserted records.

## Final Duplicate Groups

### Group 1: Blue Sky

| Metric | Value |
| --- | ---: |
| Group id | `a05dL00001nrUODQA2` |
| Full group count | 8 |
| Test records in group | 5 |
| Top score | 100 |
| Minimum test score | 88 |
| Maximum test score | 100 |

Test records included:

| Account | Score |
| --- | ---: |
| Blue Sky Consulting | 100 |
| Blue Sky Ltd. | 100 |
| BlueSky Consulting | 88 |
| Blue Sky Consultancy | 88 |
| Blue Sky Co | 88 |

### Group 2: Northwind

| Metric | Value |
| --- | ---: |
| Group id | `a05dL00001nrUKzQAM` |
| Full group count | 5 |
| Test records in group | 5 |
| Top score | 100 |
| Minimum test score | 81 |
| Maximum test score | 100 |

Test records included:

| Account | Score |
| --- | ---: |
| Northwind Traders | 100 |
| North Wind Traders LLC | 100 |
| Northwind Traders Ltd. | 88 |
| North Wind Trade Co | 88 |
| Northwind Trading | 81 |

### Group 3: Acme

| Metric | Value |
| --- | ---: |
| Group id | `a05dL00001nrUHlQAM` |
| Full group count | 5 |
| Test records in group | 5 |
| Top score | 89 |
| Minimum test score | 83 |
| Maximum test score | 89 |

Test records included:

| Account | Score |
| --- | ---: |
| Acme Logistics | 89 |
| Acme Logistic Services | 89 |
| ACME Logistics Inc | 88 |
| Acme Logistics Ltd. | 88 |
| Acme Freight Logistics | 83 |

### Group 4: Green Farm

| Metric | Value |
| --- | ---: |
| Group id | `a05dL00001nrUG9QAM` |
| Full group count | 5 |
| Test records in group | 5 |
| Top score | 88 |
| Minimum test score | 78 |
| Maximum test score | 88 |

Test records included:

| Account | Score |
| --- | ---: |
| Green Farm Supply | 88 |
| Green Farm Supply Co | 88 |
| GreenFarm Supplies | 84 |
| Green Farm LLC | 79 |
| Green Farm Suppliers | 78 |

### Group 5: Ocean Harbor

| Metric | Value |
| --- | ---: |
| Group id | `a05dL00001nrUMbQAM` |
| Full group count | 5 |
| Test records in group | 5 |
| Top score | 100 |
| Minimum test score | 79 |
| Maximum test score | 100 |

Test records included:

| Account | Score |
| --- | ---: |
| Ocean Harbor Services | 100 |
| OceanHarbor Services | 100 |
| Ocean Harbor Service Co | 88 |
| Ocean Harbor Ltd | 79 |
| Ocean Harbor Support | 79 |

## Temporary Row Cleanup

The enterprise scan uses temporary staging objects during large scans:

- `Heuristic_Duplicate_Candidate__c`
- `Heuristic_Duplicate_Pair__c`

Final cleanup verification for scan `a08dL00000dS39QQAS`:

| Temporary Object | Remaining Rows |
| --- | ---: |
| `Heuristic_Duplicate_Candidate__c` | 0 |
| `Heuristic_Duplicate_Pair__c` | 0 |

## Async Job Verification

The final rerun completed with zero async errors.

Recent enterprise scan jobs included:

| Apex Job | Status | Errors |
| --- | --- | ---: |
| `HeuristicDuplicateScanBatch` | Completed | 0 |
| `HeuristicDuplicateBucketAnalysisBatch` | Completed | 0 |
| `HeuristicDuplicatePairConsolidationBatch` | Completed | 0 |
| `HeuristicDuplicateGroupPersistBatch` | Completed | 0 |
| `HeuristicDuplicatePairCleanupBatch` | Completed | 0 |

## Conclusion

The 50-record actual-org test passed after one heuristic improvement.

Final result:

- All 25 intended duplicate records were detected.
- All 25 intended unique records stayed unflagged.
- The final duplicate groups were persisted correctly.
- Temporary staging rows were cleaned up.
- The async batch chain completed with zero errors.

This test validates the deployed enterprise architecture against real Account records, not only Apex test data.

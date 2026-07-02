# Enterprise Heuristic Duplicate Scan

This note explains the large-volume heuristic duplicate scanner in plain English. The scanner can run against supported same-object data, and the examples below use `Account` records because they are easy to recognize.

## The Simple Idea

The scanner does not compare every Account with every other Account.

That would be impossible at enterprise scale.

Example:

- 400,000 Accounts
- Comparing every Account to every other Account would create about 80 billion comparisons
- Salesforce governor limits would not allow that

Instead, the scanner does something smarter:

1. Read Accounts in batches.
2. Put each Account into small "buckets" based on useful matching clues.
3. Compare only records inside the same bucket.
4. Save likely duplicate groups.
5. Delete the temporary bucket records after analysis.

## Easy Example

Imagine these Accounts:

| Account Name | Phone | City | Website |
| --- | --- | --- | --- |
| Blue Sky Consulting | +1 (212) 555-0144 | New York | https://www.bluesky.example |
| BlueSky Consulting | 2125550144 | New York | bluesky.example |
| Red Valley Manufacturing | 4159991111 | San Francisco | redvalley.example |

The scanner normalizes the data.

For the first two records:

- `Blue Sky Consulting` and `BlueSky Consulting` become similar compact names
- `+1 (212) 555-0144` and `2125550144` both become `2125550144`
- both websites become `bluesky.example`
- both cities become `newyork`

So they land in the same buckets and get compared.

`Red Valley Manufacturing` lands in different buckets, so it is not compared with Blue Sky unless some matching clue overlaps.

## What Is A Bucket?

A bucket is a temporary group of records that share a matching clue.

The scanner creates buckets from:

- name prefix plus city
- normalized phone
- normalized email
- normalized website domain

Example buckets:

| Full `Bucket_Key__c` Value | What It Means | Records That May Go There |
| --- | --- | --- |
| <code>P&#124;2125550144</code> | Phone bucket for phone `2125550144` | Records with phone `2125550144` |
| <code>D&#124;bluesky.example</code> | Domain bucket for domain `bluesky.example` | Records with website domain `bluesky.example` |
| <code>N&#124;bluesk&#124;newyork</code> | Name bucket for names starting like `bluesk` in New York | Records with similar name prefix in New York |

If two records share a bucket, they are candidates for comparison.

Important: the first letter is only a prefix.

| Prefix | Meaning |
| --- | --- |
| `N` | name-based bucket |
| `P` | phone-based bucket |
| `E` | email-based bucket |
| `D` | website/domain-based bucket |

The full bucket is the whole value, not just the prefix.

So this is one phone bucket:

```text
P|2125550144
```

And this is a different phone bucket:

```text
P|4159991111
```

They both start with `P`, but they are not the same bucket.

Here is the same idea with actual source records.

| Source Record | Field Used | Prefix Only | Full `Bucket_Key__c` Value |
| --- | --- | --- | --- |
| Blue Sky Consulting | Phone `2125550144` | `P` | <code>P&#124;2125550144</code> |
| BlueSky Consulting | Phone `2125550144` | `P` | <code>P&#124;2125550144</code> |
| Red Valley Manufacturing | Phone `4159991111` | `P` | <code>P&#124;4159991111</code> |
| Green Farm LLC | Phone `3035558888` | `P` | <code>P&#124;3035558888</code> |
| Acme Inc | Phone `9991112222` | `P` | <code>P&#124;9991112222</code> |
| Ocean Logistics | Phone `8887776666` | `P` | <code>P&#124;8887776666</code> |

The analyzer compares rows with the same full `Bucket_Key__c` value:

| Full `Bucket_Key__c` Value | Records In That Bucket | What Analyzer Does |
| --- | --- | --- |
| <code>P&#124;2125550144</code> | Blue Sky Consulting, BlueSky Consulting | compares these 2 records |
| <code>P&#124;4159991111</code> | Red Valley Manufacturing | ignores it because there is only 1 record |
| <code>P&#124;3035558888</code> | Green Farm LLC | ignores it because there is only 1 record |
| <code>P&#124;9991112222</code> | Acme Inc | ignores it because there is only 1 record |
| <code>P&#124;8887776666</code> | Ocean Logistics | ignores it because there is only 1 record |

## What Happens With 400,000 Accounts?

If you run the scan on `Account` with `Max Records = 400000`:

1. Salesforce starts `HeuristicDuplicateScanBatch`.
2. The batch queries up to 400,000 non-soft-merged Accounts.
3. For each Account, it creates temporary `Heuristic_Duplicate_Candidate__c` rows.
4. Those rows contain compact matching data, not a full copy of the Account.
5. After collection finishes, Salesforce starts `HeuristicDuplicateBucketAnalysisBatch`.
6. The analyzer reads candidate rows ordered by bucket key.
7. It compares records inside each bucket.
8. If a pair scores above the threshold, it writes a temporary `Heuristic_Duplicate_Pair__c` row.
9. It deletes candidate rows as it processes them.
10. Salesforce starts `HeuristicDuplicatePairConsolidationBatch`.
11. The consolidator merges overlapping pairs into final groups.
12. Salesforce starts `HeuristicDuplicateGroupPersistBatch`.
13. The persist batch writes final group/member rows.
14. The scan is marked `Completed`.

So the scanner can cover a large number of Accounts without holding all 400,000 records in Apex memory.

## Small Scan Vs Large Scan

There are two paths.

| Requested Max Records | Behavior |
| --- | --- |
| 5,000 or less | Collector analyzes inline after collecting records, without creating temporary candidate rows |
| More than 5,000 | Collector writes candidate rows, then starts analyzer batch |

This keeps smaller scans fast while making larger scans safe.

## How Scoring Works

When two records are compared, the scanner gives points for matching clues.

Examples:

| Match | Effect |
| --- | --- |
| Same normalized name | strong positive score |
| Very similar name | medium positive score |
| Same phone | positive score |
| Same email | strong positive score |
| Same website domain | positive score |
| Same city | small positive score |
| Different phone when both are present | small penalty |
| Different email when both are present | penalty |
| Different website domain when both are present | small penalty |

If the final score is at or above the selected threshold, the records are grouped as likely duplicates.

Default threshold: `78`.

Higher threshold means fewer, stricter matches.
Lower threshold means more matches, but more false positives.

## Example Score Story

These are likely duplicates:

| Field | Record A | Record B |
| --- | --- | --- |
| Name | North Wind Traders | Northwind Traders |
| Phone | 2065550199 | +1 206-555-0199 |
| City | Seattle | Seattle |
| Website | northwind.example | https://northwind.example |

Why they score high:

- names are very similar
- phones normalize to the same value
- city matches
- website domain matches

These are probably not duplicates:

| Field | Record A | Record B |
| --- | --- | --- |
| Name | North Wind Traders | South Harbor Logistics |
| Phone | 2065550199 | 3035550101 |
| City | Seattle | Denver |
| Website | northwind.example | southharbor.example |

Why they score low:

- different name
- different phone
- different city
- different website domain

## Important Safety Rule

The scanner skips buckets with more than 70 records.

Example:

If 500 Accounts all have:

```text
Website = gmail.com
```

or

```text
Phone = 0000000000
```

that bucket is too broad to be useful. Comparing every record inside it would create too much noise and too much work.

So the scanner ignores that bucket.

This is intentional. It protects the org from runaway comparisons.

## What Gets Stored Permanently?

These records remain after the scan:

- `Heuristic_Duplicate_Scan__c`: one row for the scan status and metrics
- `Heuristic_Duplicate_Group__c`: one row per detected duplicate group
- `Heuristic_Duplicate_Member__c`: one row per record inside each duplicate group

These records are temporary:

- `Heuristic_Duplicate_Candidate__c`
- `Heuristic_Duplicate_Pair__c`

Candidate rows are deleted after bucket analysis. Pair rows are deleted after final group persistence.
Final group/member rows are written by a separate persist batch so large result sets do not all depend on one batch `finish` transaction.

If a scan is cancelled or fails during the large-scan path, cleanup batches remove leftover candidate and pair rows for that scan.

## Why Pair Consolidation Matters

Sometimes duplicates connect through different clues.

Example:

| Pair Found | Bucket That Found It |
| --- | --- |
| `A` matches `B` | phone bucket |
| `B` matches `C` | website bucket |

Without consolidation, the scanner might create two groups:

```text
Group 1: A, B
Group 2: B, C
```

With pair consolidation, the scanner sees that both pairs share `B`, so it creates one final group:

```text
Final Group: A, B, C
```

## What The Admin Sees

In the UI, the admin chooses:

- object, such as `Account`
- max records, up to `400000`
- score threshold
- whether to clear previous results

During the run, the admin sees:

- status
- processing path
- current pipeline stage
- active Apex job and job progress
- scanned records
- candidate comparisons
- duplicate records
- duplicate groups
- last heartbeat

After the run, the admin reviews duplicate groups and can start the soft merge workflow.

## What This Utility Is Good At

This utility is good for:

- finding likely same-object duplicates
- scanning large record sets safely
- producing explainable duplicate groups
- giving admins review control before merge
- avoiding Salesforce Duplicate Rules and Matching Rules dependency

## What This Utility Does Not Do Yet

It does not yet:

- compare every record to every other record
- automatically merge records without admin review
- detect cross-object duplicates, such as Lead versus Contact
- use machine learning
- split oversized buckets into smarter sub-buckets
- resume a partially processed analysis bucket after an unexpected platform failure

## Enterprise Mental Model

Think of the scanner like sorting mail.

Bad approach:

> Compare every envelope with every other envelope.

Better approach:

> First sort envelopes by ZIP code, street, and recipient clues. Then compare only envelopes that landed in the same small pile.

That is what the heuristic scanner does.

For 400,000 Accounts, it creates many small piles, compares records inside those piles, saves strong matches, and throws away the temporary sorting piles when done.

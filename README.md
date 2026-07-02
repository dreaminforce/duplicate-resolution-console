# Duplicate Resolution Console

Salesforce DX project for duplicate detection and resolution across two workflows:

- `Matching & Duplicate Rule Workbench` for reviewing Salesforce `DuplicateRecordSet` and `DuplicateRecordItem` data
- `Heuristic Duplicate Admin` for running same-object duplicate scans without relying on Salesforce Matching Rules or Duplicate Rules

The merge flow is implemented as a survivor-plus-field-resolution soft merge. It updates the survivor, reparents related data where possible, and writes audit history to custom objects instead of using `Database.merge`.

## Current repo status

This README was aligned to the current codebase on 2026-03-28.

Notable current-state details:

- the project name in [`sfdx-project.json`](./sfdx-project.json) is `Duplicate Resolution Console`
- the repo includes a unified Lightning app/tab and separate exposed LWCs for the matching-rule and heuristic flows
- the repo now includes an MIT `LICENSE` file for public/open-source use
- the OpenAI Apex client is currently configured to use Custom Labels by default, not a Named Credential

## What the package does

### Matching-rule workflow

1. Salesforce duplicate jobs or duplicate rules create `DuplicateRecordSet` and `DuplicateRecordItem` records.
2. [`DuplicateAiController.cls`](./force-app/main/default/classes/DuplicateAiController.cls) and [`DuplicateAiService.cls`](./force-app/main/default/classes/DuplicateAiService.cls) load those sets.
3. [`aiDuplicateWorkbench`](./force-app/main/default/lwc/aiDuplicateWorkbench/aiDuplicateWorkbench.js) lets the user inspect duplicate sets, optionally run AI analysis, and review merge recommendations.
4. [`DuplicateMergeService.cls`](./force-app/main/default/classes/DuplicateMergeService.cls) builds a field-level proposal and executes the soft merge.

### Heuristic workflow

1. [`HeuristicDuplicateScanController.cls`](./force-app/main/default/classes/HeuristicDuplicateScanController.cls) starts an async scan for one selected object at a time.
2. [`HeuristicDuplicateScanBatch.cls`](./force-app/main/default/classes/HeuristicDuplicateScanBatch.cls) streams records into lightweight candidate buckets.
3. [`HeuristicDuplicateBucketAnalysisBatch.cls`](./force-app/main/default/classes/HeuristicDuplicateBucketAnalysisBatch.cls) analyzes those buckets and writes matched-pair evidence for larger scans.
4. [`HeuristicDuplicatePairConsolidationBatch.cls`](./force-app/main/default/classes/HeuristicDuplicatePairConsolidationBatch.cls) merges overlapping pairs into final duplicate groups.
5. [`HeuristicDuplicateGroupPersistBatch.cls`](./force-app/main/default/classes/HeuristicDuplicateGroupPersistBatch.cls) writes final groups and members in a separate batch phase.
6. Results are stored in:
   - `Heuristic_Duplicate_Scan__c`
   - `Heuristic_Duplicate_Group__c`
   - `Heuristic_Duplicate_Member__c`
7. Temporary candidate rows are stored in `Heuristic_Duplicate_Candidate__c`, and temporary matched pairs are stored in `Heuristic_Duplicate_Pair__c`.
8. [`heuristicDuplicateAdmin`](./force-app/main/default/lwc/heuristicDuplicateAdmin/heuristicDuplicateAdmin.js) shows scan history, flagged groups, and merged-group history.
9. The same merge service is reused for survivor selection and field-level merge execution.

## Main metadata in this repo

### Apex

- [`DuplicateAiController.cls`](./force-app/main/default/classes/DuplicateAiController.cls)
- [`DuplicateAiService.cls`](./force-app/main/default/classes/DuplicateAiService.cls)
- [`DuplicateMergeService.cls`](./force-app/main/default/classes/DuplicateMergeService.cls)
- [`HeuristicDuplicateScanController.cls`](./force-app/main/default/classes/HeuristicDuplicateScanController.cls)
- [`HeuristicDuplicateScanService.cls`](./force-app/main/default/classes/HeuristicDuplicateScanService.cls)
- [`HeuristicDuplicateScanBatch.cls`](./force-app/main/default/classes/HeuristicDuplicateScanBatch.cls)
- [`HeuristicDuplicateBucketAnalysisBatch.cls`](./force-app/main/default/classes/HeuristicDuplicateBucketAnalysisBatch.cls)
- [`HeuristicDuplicateCandidateCleanupBatch.cls`](./force-app/main/default/classes/HeuristicDuplicateCandidateCleanupBatch.cls)
- [`HeuristicDuplicatePairCleanupBatch.cls`](./force-app/main/default/classes/HeuristicDuplicatePairCleanupBatch.cls)
- [`HeuristicDuplicatePairConsolidationBatch.cls`](./force-app/main/default/classes/HeuristicDuplicatePairConsolidationBatch.cls)
- [`HeuristicDuplicateGroupPersistBatch.cls`](./force-app/main/default/classes/HeuristicDuplicateGroupPersistBatch.cls)
- [`OpenAiResponsesClient.cls`](./force-app/main/default/classes/OpenAiResponsesClient.cls)

### Lightning Web Components

- [`dedupeConsole`](./force-app/main/default/lwc/dedupeConsole/dedupeConsole.js): unified tabbed container
- [`aiDuplicateWorkbench`](./force-app/main/default/lwc/aiDuplicateWorkbench/aiDuplicateWorkbench.js): duplicate-rule review and AI analysis
- [`heuristicDuplicateAdmin`](./force-app/main/default/lwc/heuristicDuplicateAdmin/heuristicDuplicateAdmin.js): manual heuristic scans and resolution
- [`mergeResolutionWorkspace`](./force-app/main/default/lwc/mergeResolutionWorkspace/mergeResolutionWorkspace.js): field-level merge review UI used by both workflows

### Access and app metadata

- [`Duplicate_Resolution.app-meta.xml`](./force-app/main/default/applications/Duplicate_Resolution.app-meta.xml)
- [`AI_Duplicate_Workbench.permissionset-meta.xml`](./force-app/main/default/permissionsets/AI_Duplicate_Workbench.permissionset-meta.xml)
- [`Heuristic_Duplicate_Admin.permissionset-meta.xml`](./force-app/main/default/permissionsets/Heuristic_Duplicate_Admin.permissionset-meta.xml)
- [`AI_Duplicate_Workbench.tab-meta.xml`](./force-app/main/default/tabs/AI_Duplicate_Workbench.tab-meta.xml)
- [`Heuristic_Duplicate_Admin.tab-meta.xml`](./force-app/main/default/tabs/Heuristic_Duplicate_Admin.tab-meta.xml)
- [`Duplicate_Resolution_Console.tab-meta.xml`](./force-app/main/default/tabs/Duplicate_Resolution_Console.tab-meta.xml)

### Audit and scan objects

- [`Duplicate_Merge_Run__c`](./force-app/main/default/objects/Duplicate_Merge_Run__c/Duplicate_Merge_Run__c.object-meta.xml)
- [`Duplicate_Merge_Record__c`](./force-app/main/default/objects/Duplicate_Merge_Record__c/Duplicate_Merge_Record__c.object-meta.xml)
- [`Heuristic_Duplicate_Scan__c`](./force-app/main/default/objects/Heuristic_Duplicate_Scan__c/Heuristic_Duplicate_Scan__c.object-meta.xml)
- [`Heuristic_Duplicate_Group__c`](./force-app/main/default/objects/Heuristic_Duplicate_Group__c/Heuristic_Duplicate_Group__c.object-meta.xml)
- [`Heuristic_Duplicate_Member__c`](./force-app/main/default/objects/Heuristic_Duplicate_Member__c/Heuristic_Duplicate_Member__c.object-meta.xml)
- [`Heuristic_Duplicate_Candidate__c`](./force-app/main/default/objects/Heuristic_Duplicate_Candidate__c/Heuristic_Duplicate_Candidate__c.object-meta.xml)
- [`Heuristic_Duplicate_Pair__c`](./force-app/main/default/objects/Heuristic_Duplicate_Pair__c/Heuristic_Duplicate_Pair__c.object-meta.xml)

## OpenAI configuration

The repo currently ships with [`OpenAiResponsesClient.cls`](./force-app/main/default/classes/OpenAiResponsesClient.cls) set to:

- `USE_NAMED_CREDENTIAL = false`
- model `gpt-4.1-mini`
- endpoint and API key loaded from Custom Labels

The required labels are defined in [`CustomLabels.labels-meta.xml`](./force-app/main/default/labels/CustomLabels.labels-meta.xml):

- `OpenAI_Hardcoded_Endpoint`
- `OpenAI_Hardcoded_API_Key`

Important:

- the committed default API key value is `REPLACE_ME`, so AI analysis will fail until you set a real key
- keeping API keys in Custom Labels is convenient for testing but weaker than using a Named Credential or External Credential

If you want to use a Named Credential instead:

1. Create a Named Credential named `OpenAI`.
2. Point it at `https://api.openai.com`.
3. Provide bearer-token authentication through your preferred Salesforce credential flow.
4. Change `USE_NAMED_CREDENTIAL` in [`OpenAiResponsesClient.cls`](./force-app/main/default/classes/OpenAiResponsesClient.cls) from `false` to `true`.

The callout target is `POST /v1/responses`.

## Deploy

Deploy the metadata:

```bash
sf project deploy start --source-dir force-app/main/default --target-org <alias>
```

Assign both permission sets if you want access to both flows:

```bash
sf org assign permset --name AI_Duplicate_Workbench --target-org <alias>
sf org assign permset --name Heuristic_Duplicate_Admin --target-org <alias>
```

After deployment, open the `Duplicate Resolution` Lightning app or the `Duplicate Resolution Console` tab.

## Local tooling

Node tooling is defined in [`package.json`](./package.json).

Useful commands:

```bash
npm install
npm run lint
npm run test:unit
npm run prettier:verify
```

Notes:

- Jest tooling for LWC is configured, but this repo currently does not include committed LWC Jest test files
- Apex coverage is split across [`DuplicateAiServiceTest.cls`](./force-app/main/default/classes/DuplicateAiServiceTest.cls) and [`HeuristicDuplicateScanServiceTest.cls`](./force-app/main/default/classes/HeuristicDuplicateScanServiceTest.cls)

## Known documentation notes

This README intentionally avoids a few stale claims from the previous version:

- it no longer lists `force-app/main/default/objects/Account/fields/Heuristic_Duplicate_*`, because that path is not present in the repo
- it now documents both permission sets instead of only one
- it now reflects the actual current OpenAI transport mode in code
- it now mentions the shared merge review workspace component

## Licensing

This repository now includes an MIT license in [`LICENSE`](./LICENSE).

That means the code is ready to be published publicly with a clear permissive reuse license.

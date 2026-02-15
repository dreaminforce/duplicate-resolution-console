# Salesforce AI Dedupe Package (Starter)

This project now includes a first implementation of an AI-assisted duplicate resolution workbench for Salesforce.
It also includes a separate deterministic duplicate scanner that does not depend on Salesforce Matching Rules/Duplicate Rules and supports scanning any selected object.

## What it does

1. User runs standard Salesforce duplicate jobs manually.
2. `DuplicateRecordItem` and `DuplicateRecordSet` data is read by Apex.
3. User opens **AI Duplicate Workbench** and selects an object.
4. The app analyzes duplicate sets for that object.
5. For each set, AI proposes:
   - canonical parent record
   - ranked closeness/match score for all records
   - recommended action (`KEEP`, `MERGE`, `DELETE`, `REVIEW`)
6. User reviews detailed set data and executes actions.

## Included components

- `force-app/main/default/classes/DuplicateAiController.cls`
- `force-app/main/default/classes/DuplicateAiService.cls`
- `force-app/main/default/classes/OpenAiResponsesClient.cls`
- `force-app/main/default/lwc/aiDuplicateWorkbench/*`
- `force-app/main/default/tabs/AI_Duplicate_Workbench.tab-meta.xml`
- `force-app/main/default/permissionsets/AI_Duplicate_Workbench.permissionset-meta.xml`
- `force-app/main/default/classes/HeuristicDuplicateScanController.cls`
- `force-app/main/default/classes/HeuristicDuplicateScanService.cls`
- `force-app/main/default/classes/HeuristicDuplicateScanBatch.cls`
- `force-app/main/default/classes/HeuristicDuplicateScanServiceTest.cls`
- `force-app/main/default/lwc/heuristicDuplicateAdmin/*`
- `force-app/main/default/tabs/Heuristic_Duplicate_Admin.tab-meta.xml`
- `force-app/main/default/permissionsets/Heuristic_Duplicate_Admin.permissionset-meta.xml`
- `force-app/main/default/objects/Heuristic_Duplicate_Scan__c/*`
- `force-app/main/default/objects/Heuristic_Duplicate_Group__c/*`
- `force-app/main/default/objects/Heuristic_Duplicate_Member__c/*`
- `force-app/main/default/objects/Account/fields/Heuristic_Duplicate_*`

## OpenAI setup

The Apex callout expects a **Named Credential** named `OpenAI`.

Configure it in Salesforce Setup:

1. Create Named Credential: `OpenAI`
2. URL: `https://api.openai.com`
3. Add Authorization header for Bearer API key (or use External Credential flow)
4. Ensure callouts from Apex to this credential are allowed

The service calls: `POST /v1/responses`

## Deploy

```bash
sf project deploy start --source-dir force-app/main/default --target-org <alias>
```

Assign permission set:

```bash
sf org assign permset --name AI_Duplicate_Workbench --target-org <alias>
```

## Notes

- Merge action is only enabled for merge-capable standard objects (`Account`, `Contact`, `Lead`, `Case`).
- If AI analysis fails for a set, deterministic fallback ranking is used so users can still proceed.
- The LWC field matrix is intentionally compact and scrollable to handle wide record comparisons.
- The **Heuristic Duplicate Admin** tab runs on button-click and scans one selected object at a time (for example Account-to-Account, Contact-to-Contact, Lead-to-Lead).
- Results are stored in dedicated custom objects:
  - `Heuristic_Duplicate_Scan__c`
  - `Heuristic_Duplicate_Group__c`
  - `Heuristic_Duplicate_Member__c`
- This scanner is fully separate from `DuplicateRecordSet`/`DuplicateRecordItem` and from Salesforce MR/DR behavior.

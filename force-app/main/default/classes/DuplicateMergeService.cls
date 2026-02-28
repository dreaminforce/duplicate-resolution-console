public with sharing class DuplicateMergeService {
  private static final Integer MAX_RELATIONSHIP_SCANS = 45;
  private static final Integer MAX_QUERYABLE_FIELDS = 180;
  private static final Integer MAX_SNAPSHOT_LENGTH = 32000;

  public class MergeProposal {
    @AuraEnabled public String objectApiName;
    @AuraEnabled public String objectLabel;
    @AuraEnabled public String summary;
    @AuraEnabled public String survivorRecordId;
    @AuraEnabled public String survivorDisplayValue;
    @AuraEnabled public Boolean softMergeOnly;
    @AuraEnabled public Integer reviewRequiredCount;
    @AuraEnabled public Integer lowRiskFieldCount;
    @AuraEnabled public Integer relatedRecordCount;
    @AuraEnabled public List<String> warnings;
    @AuraEnabled public List<RecordCandidate> records;
    @AuraEnabled public List<FieldProposal> fields;
    @AuraEnabled public List<RelatedSummary> relatedSummaries;
  }

  public class RecordCandidate {
    @AuraEnabled public String recordId;
    @AuraEnabled public String displayValue;
    @AuraEnabled public Boolean isSurvivor;
    @AuraEnabled public Integer completenessScore;
    @AuraEnabled public Integer relationshipScore;
    @AuraEnabled public Integer externalIdScore;
    @AuraEnabled public Integer activityScore;
    @AuraEnabled public Integer survivorScore;
    @AuraEnabled public Integer relatedRecordCount;
    @AuraEnabled public String survivorReason;
    @AuraEnabled public Map<String, String> fields;
  }

  public class FieldProposal {
    @AuraEnabled public String fieldApiName;
    @AuraEnabled public String fieldLabel;
    @AuraEnabled public String dataType;
    @AuraEnabled public String riskLevel;
    @AuraEnabled public Boolean requiresReview;
    @AuraEnabled public String recommendationReason;
    @AuraEnabled public String recommendedSourceRecordId;
    @AuraEnabled public String selectedSourceRecordId;
    @AuraEnabled public String recommendedValue;
    @AuraEnabled public String selectedValue;
    @AuraEnabled public List<FieldCandidate> candidates;
  }

  public class FieldCandidate {
    @AuraEnabled public String recordId;
    @AuraEnabled public String displayValue;
    @AuraEnabled public String value;
    @AuraEnabled public Boolean isSurvivor;
    @AuraEnabled public Boolean isRecommended;
  }

  public class RelatedSummary {
    @AuraEnabled public String relationshipLabel;
    @AuraEnabled public String childObjectApiName;
    @AuraEnabled public String fieldApiName;
    @AuraEnabled public Integer recordCount;
  }

  public class MergeExecutionRequest {
    @AuraEnabled public String objectApiName;
    @AuraEnabled public String survivorRecordId;
    @AuraEnabled public List<String> loserRecordIds;
    @AuraEnabled public List<FieldSelectionInput> fieldSelections;
  }

  public class FieldSelectionInput {
    @AuraEnabled public String fieldApiName;
    @AuraEnabled public String sourceRecordId;
  }

  public class MergeExecutionResult {
    @AuraEnabled public Boolean success;
    @AuraEnabled public String message;
    @AuraEnabled public String mergeRunId;
    @AuraEnabled public String survivorRecordId;
    @AuraEnabled public Integer updatedFieldCount;
    @AuraEnabled public Integer reparentedRecordCount;
    @AuraEnabled public Integer softMergedCount;
    @AuraEnabled public List<String> warnings;
    @AuraEnabled public List<String> errors;
  }

  private class QueryResultContext {
    public Map<Id, SObject> recordsById = new Map<Id, SObject>();
    public List<String> queriedFieldNames = new List<String>();
  }

  private class MergeContext {
    public Schema.DescribeSObjectResult describeResult;
    public Map<String, Schema.SObjectField> fieldMap = new Map<String, Schema.SObjectField>();
    public QueryResultContext queryContext = new QueryResultContext();
    public Map<Id, RecordContext> recordsById = new Map<Id, RecordContext>();
    public List<RecordContext> orderedRecords = new List<RecordContext>();
    public List<RelationshipPlan> relationshipPlans = new List<RelationshipPlan>();
    public List<RelatedSummary> relatedSummaries = new List<RelatedSummary>();
    public List<String> warnings = new List<String>();
    public Id survivorId;
    public String objectApiName;
  }

  private class RecordContext {
    public Id recordId;
    public SObject row;
    public Map<String, String> flatFields = new Map<String, String>();
    public String displayValue;
    public Integer completenessScore;
    public Integer relationshipScore;
    public Integer externalIdScore;
    public Integer activityScore;
    public Integer survivorScore;
    public Integer relatedRecordCount;
    public String survivorReason;
  }

  private class RelationshipPlan {
    public String childObjectApiName;
    public String fieldApiName;
    public String relationshipLabel;
    public Integer priority;
  }

  private class RelationshipCountContext {
    public Map<Id, Integer> countsByRecordId = new Map<Id, Integer>();
    public List<RelatedSummary> summaries = new List<RelatedSummary>();
    public List<String> warnings = new List<String>();
  }

  public static MergeProposal getMergeProposal(String objectApiName, List<String> recordIds, String preferredSurvivorId) {
    Set<Id> ids = coerceIds(recordIds);
    Id preferredId = parseId(preferredSurvivorId);
    MergeContext context = buildMergeContext(objectApiName, ids, preferredId);
    return toProposal(context);
  }

  public static MergeProposal getMergeProposal(String objectApiName, List<Id> recordIds, Id preferredSurvivorId) {
    return getMergeProposal(objectApiName, stringifyIds(recordIds), String.valueOf(preferredSurvivorId));
  }

  public static MergeExecutionResult executeMerge(MergeExecutionRequest request) {
    if (request == null) {
      throw new AuraHandledException('Merge request is required.');
    }

    Set<Id> recordIds = coerceIds(request.loserRecordIds);
    Id survivorId = parseId(request.survivorRecordId);
    if (survivorId == null) {
      throw new AuraHandledException('survivorRecordId is required.');
    }
    recordIds.add(survivorId);

    MergeContext context = buildMergeContext(request.objectApiName, recordIds, survivorId);
    Map<String, String> selectionByField = buildSelectionMap(request.fieldSelections);

    MergeExecutionResult result = new MergeExecutionResult();
    result.success = true;
    result.errors = new List<String>();
    result.warnings = new List<String>();
    result.survivorRecordId = String.valueOf(context.survivorId);
    result.updatedFieldCount = 0;
    result.reparentedRecordCount = 0;
    result.softMergedCount = 0;

    List<RecordContext> loserRecords = new List<RecordContext>();
    for (RecordContext recordCtx : context.orderedRecords) {
      if (recordCtx.recordId != context.survivorId) {
        loserRecords.add(recordCtx);
      }
    }

    if (loserRecords.isEmpty()) {
      throw new AuraHandledException('At least one loser record is required to execute a merge.');
    }

    Duplicate_Merge_Run__c run = new Duplicate_Merge_Run__c(
      Object_Api_Name__c = context.objectApiName,
      Survivor_Record_Id__c = String.valueOf(context.survivorId),
      Survivor_Display__c = context.recordsById.get(context.survivorId).displayValue,
      Status__c = 'In Progress',
      Summary__c = 'Executing survivor-plus-field-resolution merge.'
    );
    insert run;
    result.mergeRunId = String.valueOf(run.Id);

    try {
      MergeProposal proposal = toProposal(context);
      SObject survivorUpdate = applySelectedFieldValues(context, proposal, selectionByField, result);
      if (!isEmptyUpdate(survivorUpdate)) {
        update survivorUpdate;
      }

      result.reparentedRecordCount = reparentRelatedRecords(context, loserRecords, result.errors, result.warnings);
      result.softMergedCount = upsertSoftMergeRegistry(context, loserRecords, run.Id, result.warnings);
      applyNativeSoftMergeMarkers(context, loserRecords, result.warnings);

      run.Status__c = result.errors.isEmpty() ? 'Completed' : 'Completed With Errors';
      run.Updated_Field_Count__c = result.updatedFieldCount;
      run.Reparented_Record_Count__c = result.reparentedRecordCount;
      run.Merged_Record_Count__c = result.softMergedCount;
      run.Warnings__c = truncateLongText(String.join(result.warnings, '\n'));
      run.Execution_Detail__c = truncateLongText(JSON.serialize(buildAuditPayload(proposal, selectionByField, result)));
      run.Summary__c =
        'Updated ' +
        String.valueOf(result.updatedFieldCount) +
        ' field(s), moved ' +
        String.valueOf(result.reparentedRecordCount) +
        ' related record(s), and soft-merged ' +
        String.valueOf(result.softMergedCount) +
        ' loser record(s).';
      update run;

      result.success = result.errors.isEmpty();
      result.message =
        result.success
          ? 'Soft merge completed. Survivor updated and losers marked in the merge registry.'
          : 'Soft merge completed with errors. Review the merge audit record for details.';
      return result;
    } catch (Exception ex) {
      run.Status__c = 'Failed';
      run.Warnings__c = truncateLongText(describeException(ex));
      run.Summary__c = 'Merge failed before completion.';
      update run;
      throw new AuraHandledException(describeException(ex));
    }
  }

  public static Set<Id> getSoftMergedRecordIds(String objectApiName) {
    if (String.isBlank(objectApiName)) {
      return new Set<Id>();
    }

    Set<Id> out = new Set<Id>();
    for (Duplicate_Merge_Record__c row : [
      SELECT Source_Record_Id__c
      FROM Duplicate_Merge_Record__c
      WHERE Object_Api_Name__c = :objectApiName AND Soft_Merge_Status__c = 'Merged'
      LIMIT 50000
    ]) {
      Id parsed = parseId(row.Source_Record_Id__c);
      if (parsed != null) {
        out.add(parsed);
      }
    }
    return out;
  }

  public static Set<Id> getSoftMergedRecordIds(String objectApiName, Set<Id> candidateIds) {
    Set<Id> out = new Set<Id>();
    if (String.isBlank(objectApiName) || candidateIds == null || candidateIds.isEmpty()) {
      return out;
    }

    Set<String> candidateStrings = new Set<String>();
    for (Id idValue : candidateIds) {
      candidateStrings.add(String.valueOf(idValue));
    }

    for (Duplicate_Merge_Record__c row : [
      SELECT Source_Record_Id__c
      FROM Duplicate_Merge_Record__c
      WHERE
        Object_Api_Name__c = :objectApiName
        AND Soft_Merge_Status__c = 'Merged'
        AND Source_Record_Id__c IN :candidateStrings
    ]) {
      Id parsed = parseId(row.Source_Record_Id__c);
      if (parsed != null) {
        out.add(parsed);
      }
    }
    return out;
  }

  private static MergeContext buildMergeContext(String objectApiName, Set<Id> inputIds, Id preferredSurvivorId) {
    validateObjectApiName(objectApiName);
    if (inputIds == null || inputIds.size() < 2) {
      throw new AuraHandledException('Select at least two records to build a merge proposal.');
    }

    Set<Id> activeIds = new Set<Id>();
    activeIds.addAll(inputIds);
    activeIds.removeAll(getSoftMergedRecordIds(objectApiName, inputIds));
    if (activeIds.size() < 2) {
      throw new AuraHandledException('Only one active record remains after excluding already merged records.');
    }

    MergeContext context = new MergeContext();
    context.objectApiName = objectApiName;
    context.describeResult = Schema.getGlobalDescribe().get(objectApiName).getDescribe();
    context.fieldMap = context.describeResult.fields.getMap();
    context.queryContext = queryAllFieldsForRecords(objectApiName, activeIds);

    Set<String> queriedFieldSet = new Set<String>();
    for (String fieldName : context.queryContext.queriedFieldNames) {
      queriedFieldSet.add(fieldName.toLowerCase());
    }

    for (Id recordId : activeIds) {
      if (!context.queryContext.recordsById.containsKey(recordId)) {
        continue;
      }

      RecordContext recordCtx = new RecordContext();
      recordCtx.recordId = recordId;
      recordCtx.row = context.queryContext.recordsById.get(recordId);
      recordCtx.flatFields = flattenFields(recordCtx.row, context.queryContext.queriedFieldNames);
      recordCtx.displayValue = deriveDisplayValue(recordCtx.row, queriedFieldSet, String.valueOf(recordId));
      recordCtx.completenessScore = scoreRecordQuality(recordCtx.flatFields);
      recordCtx.externalIdScore = scoreExternalIds(recordCtx.row, context.fieldMap);
      recordCtx.activityScore = scoreRecentActivity(recordCtx.row, context.fieldMap);
      context.recordsById.put(recordId, recordCtx);
      context.orderedRecords.add(recordCtx);
    }

    if (context.orderedRecords.size() < 2) {
      throw new AuraHandledException('The selected records could not be queried for merge review.');
    }

    RelationshipCountContext relationshipCounts = countRelatedRecords(context.describeResult, activeIds);
    context.relatedSummaries = relationshipCounts.summaries;
    context.warnings.addAll(relationshipCounts.warnings);

    for (RecordContext recordCtx : context.orderedRecords) {
      recordCtx.relatedRecordCount = relationshipCounts.countsByRecordId.containsKey(recordCtx.recordId)
        ? relationshipCounts.countsByRecordId.get(recordCtx.recordId)
        : 0;
      recordCtx.relationshipScore = Math.min(recordCtx.relatedRecordCount, 30);
      recordCtx.survivorScore =
        recordCtx.completenessScore + recordCtx.externalIdScore + recordCtx.activityScore + recordCtx.relationshipScore;
    }

    context.orderedRecords.sort(new SurvivorSorter());

    if (preferredSurvivorId != null && context.recordsById.containsKey(preferredSurvivorId)) {
      context.survivorId = preferredSurvivorId;
    } else {
      context.survivorId = context.orderedRecords[0].recordId;
    }

    for (RecordContext recordCtx : context.orderedRecords) {
      recordCtx.survivorReason = buildSurvivorReason(recordCtx);
    }

    context.relationshipPlans = discoverRelationshipPlans(context.describeResult, context.warnings);
    return context;
  }

  private static MergeProposal toProposal(MergeContext context) {
    MergeProposal proposal = new MergeProposal();
    proposal.objectApiName = context.objectApiName;
    proposal.objectLabel = context.describeResult.getLabel();
    proposal.survivorRecordId = String.valueOf(context.survivorId);
    proposal.survivorDisplayValue = context.recordsById.get(context.survivorId).displayValue;
    proposal.softMergeOnly = true;
    proposal.warnings = new List<String>();
    proposal.warnings.addAll(context.warnings);
    proposal.relatedSummaries = context.relatedSummaries;
    proposal.relatedRecordCount = 0;
    for (RelatedSummary summary : proposal.relatedSummaries) {
      proposal.relatedRecordCount += summary.recordCount;
    }

    proposal.records = new List<RecordCandidate>();
    for (RecordContext recordCtx : context.orderedRecords) {
      RecordCandidate row = new RecordCandidate();
      row.recordId = String.valueOf(recordCtx.recordId);
      row.displayValue = recordCtx.displayValue;
      row.isSurvivor = recordCtx.recordId == context.survivorId;
      row.completenessScore = recordCtx.completenessScore;
      row.relationshipScore = recordCtx.relationshipScore;
      row.externalIdScore = recordCtx.externalIdScore;
      row.activityScore = recordCtx.activityScore;
      row.survivorScore = recordCtx.survivorScore;
      row.relatedRecordCount = recordCtx.relatedRecordCount;
      row.survivorReason = recordCtx.survivorReason;
      row.fields = recordCtx.flatFields;
      proposal.records.add(row);
    }

    proposal.fields = buildFieldProposals(context);
    proposal.reviewRequiredCount = 0;
    proposal.lowRiskFieldCount = 0;
    for (FieldProposal fieldProposal : proposal.fields) {
      if (fieldProposal.requiresReview) {
        proposal.reviewRequiredCount++;
      } else {
        proposal.lowRiskFieldCount++;
      }
    }

    proposal.summary =
      'Survivor ' +
      proposal.survivorDisplayValue +
      ' will be kept. Review ' +
      String.valueOf(proposal.reviewRequiredCount) +
      ' high-risk field(s), auto-fill ' +
      String.valueOf(proposal.lowRiskFieldCount) +
      ' lower-risk field(s), and move ' +
      String.valueOf(proposal.relatedRecordCount) +
      ' related record(s).';
    return proposal;
  }

  private static List<FieldProposal> buildFieldProposals(MergeContext context) {
    List<FieldProposal> proposals = new List<FieldProposal>();
    List<String> fieldNames = new List<String>(context.fieldMap.keySet());
    fieldNames.sort();

    for (String fieldName : fieldNames) {
      if (!shouldIncludeInMergeProposal(fieldName, context.fieldMap.get(fieldName).getDescribe())) {
        continue;
      }

      FieldProposal proposal = buildSingleFieldProposal(context, fieldName, context.fieldMap.get(fieldName).getDescribe());
      if (proposal != null) {
        proposals.add(proposal);
      }
    }

    proposals.sort(new FieldProposalSorter());
    return proposals;
  }

  private static FieldProposal buildSingleFieldProposal(
    MergeContext context,
    String fieldName,
    Schema.DescribeFieldResult fieldDescribe
  ) {
    RecordContext survivor = context.recordsById.get(context.survivorId);
    List<FieldCandidate> candidates = new List<FieldCandidate>();
    Set<String> distinctValues = new Set<String>();
    Boolean anyNonBlank = false;
    Boolean hasConflict = false;
    Integer longestValueLength = -1;
    Id longestValueRecordId;
    Id firstNonBlankRecordId;

    for (RecordContext recordCtx : context.orderedRecords) {
      String value = recordCtx.flatFields.containsKey(fieldName) ? recordCtx.flatFields.get(fieldName) : '';
      String normalized = normalizeValueForConflict(value, fieldDescribe);
      if (!String.isBlank(normalized)) {
        anyNonBlank = true;
        if (firstNonBlankRecordId == null) {
          firstNonBlankRecordId = recordCtx.recordId;
        }
        if (value.length() > longestValueLength) {
          longestValueLength = value.length();
          longestValueRecordId = recordCtx.recordId;
        }
        if (!distinctValues.isEmpty() && !distinctValues.contains(normalized)) {
          hasConflict = true;
        }
        distinctValues.add(normalized);
      }
    }

    if (!anyNonBlank) {
      return null;
    }

    String riskLevel = classifyRisk(fieldName, fieldDescribe);
    Id recommendedSourceId = null;
    String recommendationReason;

    String survivorValue = survivor.flatFields.get(fieldName);
    if (String.isBlank(survivorValue) && distinctValues.size() == 1 && firstNonBlankRecordId != null) {
      recommendedSourceId = firstNonBlankRecordId;
      recommendationReason = 'Survivor is blank and one shared value can safely fill the field.';
    } else if (!hasConflict) {
      recommendedSourceId = !String.isBlank(survivorValue) ? survivor.recordId : firstNonBlankRecordId;
      recommendationReason = 'All active records agree on the same non-blank value.';
    } else if (riskLevel == 'HIGH') {
      recommendedSourceId = !String.isBlank(survivorValue) ? survivor.recordId : selectBestConflictingRecord(context, fieldName);
      recommendationReason = 'Meaningful conflict detected on a high-risk field. Survivor is the conservative default.';
    } else {
      recommendedSourceId = selectBestConflictingRecord(context, fieldName);
      if (recommendedSourceId == null) {
        recommendedSourceId = longestValueRecordId == null ? survivor.recordId : longestValueRecordId;
      }
      recommendationReason = 'Lower-risk conflict resolved by non-blank completeness and record quality.';
    }

    if (recommendedSourceId == null) {
      return null;
    }

    for (RecordContext recordCtx : context.orderedRecords) {
      String value = recordCtx.flatFields.containsKey(fieldName) ? recordCtx.flatFields.get(fieldName) : '';
      FieldCandidate candidate = new FieldCandidate();
      candidate.recordId = String.valueOf(recordCtx.recordId);
      candidate.displayValue = recordCtx.displayValue;
      candidate.value = value;
      candidate.isSurvivor = recordCtx.recordId == context.survivorId;
      candidate.isRecommended = recordCtx.recordId == recommendedSourceId;
      candidates.add(candidate);
    }

    FieldProposal proposal = new FieldProposal();
    proposal.fieldApiName = fieldName;
    proposal.fieldLabel = fieldDescribe.getLabel();
    proposal.dataType = String.valueOf(fieldDescribe.getType());
    proposal.riskLevel = riskLevel;
    proposal.requiresReview = hasConflict && riskLevel == 'HIGH';
    proposal.recommendationReason = recommendationReason;
    proposal.recommendedSourceRecordId = String.valueOf(recommendedSourceId);
    proposal.selectedSourceRecordId = proposal.recommendedSourceRecordId;
    proposal.recommendedValue = context.recordsById.get(recommendedSourceId).flatFields.get(fieldName);
    proposal.selectedValue = proposal.recommendedValue;
    proposal.candidates = candidates;
    return proposal;
  }

  private static SObject applySelectedFieldValues(
    MergeContext context,
    MergeProposal proposal,
    Map<String, String> selectionByField,
    MergeExecutionResult result
  ) {
    SObject survivorUpdate = Schema.getGlobalDescribe().get(context.objectApiName).newSObject(context.survivorId);
    RecordContext survivor = context.recordsById.get(context.survivorId);

    for (FieldProposal fieldProposal : proposal.fields) {
      String selectedSourceId = selectionByField.containsKey(fieldProposal.fieldApiName)
        ? selectionByField.get(fieldProposal.fieldApiName)
        : fieldProposal.selectedSourceRecordId;
      Id sourceId = parseId(selectedSourceId);
      if (sourceId == null || !context.recordsById.containsKey(sourceId)) {
        sourceId = parseId(fieldProposal.recommendedSourceRecordId);
      }
      if (sourceId == null || !context.recordsById.containsKey(sourceId)) {
        continue;
      }

      SObject sourceRow = context.recordsById.get(sourceId).row;
      Object selectedValue = safeGetField(sourceRow, fieldProposal.fieldApiName);
      Object currentValue = safeGetField(survivor.row, fieldProposal.fieldApiName);
      if (areValuesEqual(currentValue, selectedValue)) {
        continue;
      }

      survivorUpdate.put(fieldProposal.fieldApiName, selectedValue);
      result.updatedFieldCount++;
    }

    return survivorUpdate;
  }

  private static Integer reparentRelatedRecords(
    MergeContext context,
    List<RecordContext> loserRecords,
    List<String> errors,
    List<String> warnings
  ) {
    Integer moved = 0;
    Set<Id> loserIds = new Set<Id>();
    for (RecordContext loser : loserRecords) {
      loserIds.add(loser.recordId);
    }

    for (RelationshipPlan plan : context.relationshipPlans) {
      try {
        String soql =
          'SELECT Id,' +
          plan.fieldApiName +
          ' FROM ' +
          plan.childObjectApiName +
          ' WHERE ' +
          plan.fieldApiName +
          ' IN :loserIds LIMIT 5000';
        List<SObject> children = Database.query(soql);
        if (children.isEmpty()) {
          continue;
        }

        for (SObject child : children) {
          child.put(plan.fieldApiName, context.survivorId);
        }

        Database.SaveResult[] saveResults = Database.update(children, false);
        for (Integer i = 0; i < saveResults.size(); i++) {
          if (saveResults[i].isSuccess()) {
            moved++;
          } else {
            for (Database.Error err : saveResults[i].getErrors()) {
              warnings.add(
                plan.childObjectApiName +
                '.' +
                plan.fieldApiName +
                ' reparent failed for ' +
                String.valueOf(children[i].get('Id')) +
                ': ' +
                err.getMessage()
              );
            }
          }
        }
      } catch (Exception ex) {
        errors.add(
          'Failed to reparent related records for ' +
          plan.childObjectApiName +
          '.' +
          plan.fieldApiName +
          ': ' +
          describeException(ex)
        );
      }
    }

    return moved;
  }

  private static Integer upsertSoftMergeRegistry(
    MergeContext context,
    List<RecordContext> loserRecords,
    Id mergeRunId,
    List<String> warnings
  ) {
    List<Duplicate_Merge_Record__c> rows = new List<Duplicate_Merge_Record__c>();
    for (RecordContext loser : loserRecords) {
      Duplicate_Merge_Record__c registryRow = new Duplicate_Merge_Record__c();
      registryRow.Merge_Run__c = mergeRunId;
      registryRow.Object_Api_Name__c = context.objectApiName;
      registryRow.Source_Record_Id__c = String.valueOf(loser.recordId);
      registryRow.Merged_Into_Record_Id__c = String.valueOf(context.survivorId);
      registryRow.Source_Display__c = loser.displayValue;
      registryRow.Soft_Merge_Status__c = 'Merged';
      registryRow.Snapshot_JSON__c = truncateLongText(JSON.serialize(buildSnapshotPayload(loser)));
      rows.add(registryRow);
    }

    if (rows.isEmpty()) {
      return 0;
    }

    Database.UpsertResult[] upsertResults = Database.upsert(rows, Duplicate_Merge_Record__c.Fields.Source_Record_Id__c, false);
    Integer mergedCount = 0;
    for (Integer i = 0; i < upsertResults.size(); i++) {
      if (upsertResults[i].isSuccess()) {
        mergedCount++;
      } else {
        for (Database.Error err : upsertResults[i].getErrors()) {
          warnings.add('Failed to store soft-merge registry row for ' + rows[i].Source_Record_Id__c + ': ' + err.getMessage());
        }
      }
    }
    return mergedCount;
  }

  private static void applyNativeSoftMergeMarkers(MergeContext context, List<RecordContext> loserRecords, List<String> warnings) {
    Map<String, Schema.SObjectField> fieldMap = context.fieldMap;
    if (!fieldMap.containsKey('Merged_Into__c') && !fieldMap.containsKey('Merged__c') && !fieldMap.containsKey('Merge_Status__c')) {
      return;
    }

    List<SObject> updates = new List<SObject>();
    for (RecordContext loser : loserRecords) {
      SObject updateRow = Schema.getGlobalDescribe().get(context.objectApiName).newSObject(loser.recordId);
      Boolean hasChanges = false;

      if (fieldMap.containsKey('Merged_Into__c')) {
        Schema.DescribeFieldResult mergedIntoDescribe = fieldMap.get('Merged_Into__c').getDescribe();
        if (mergedIntoDescribe.isUpdateable()) {
          if (mergedIntoDescribe.getType() == Schema.DisplayType.Reference) {
            updateRow.put('Merged_Into__c', context.survivorId);
            hasChanges = true;
          } else {
            updateRow.put('Merged_Into__c', String.valueOf(context.survivorId));
            hasChanges = true;
          }
        }
      }

      if (fieldMap.containsKey('Merged__c') && fieldMap.get('Merged__c').getDescribe().isUpdateable()) {
        updateRow.put('Merged__c', true);
        hasChanges = true;
      }

      if (fieldMap.containsKey('Merge_Status__c')) {
        Schema.DescribeFieldResult statusDescribe = fieldMap.get('Merge_Status__c').getDescribe();
        if (statusDescribe.isUpdateable() && canAssignMergedStatus(statusDescribe)) {
          updateRow.put('Merge_Status__c', 'Merged');
          hasChanges = true;
        }
      }

      if (hasChanges) {
        updates.add(updateRow);
      }
    }

    if (updates.isEmpty()) {
      return;
    }

    Database.SaveResult[] saveResults = Database.update(updates, false);
    for (Integer i = 0; i < saveResults.size(); i++) {
      if (saveResults[i].isSuccess()) {
        continue;
      }
      for (Database.Error err : saveResults[i].getErrors()) {
        warnings.add('Native soft-merge marker update failed for ' + String.valueOf(updates[i].get('Id')) + ': ' + err.getMessage());
      }
    }
  }

  private static RelationshipCountContext countRelatedRecords(Schema.DescribeSObjectResult describeResult, Set<Id> recordIds) {
    RelationshipCountContext output = new RelationshipCountContext();
    List<RelationshipPlan> plans = discoverRelationshipPlans(describeResult, output.warnings);

    for (RelationshipPlan plan : plans) {
      try {
        String soql =
          'SELECT ' +
          plan.fieldApiName +
          ' relationId, COUNT(Id) totalRows FROM ' +
          plan.childObjectApiName +
          ' WHERE ' +
          plan.fieldApiName +
          ' IN :recordIds GROUP BY ' +
          plan.fieldApiName;
        Integer relationshipTotal = 0;
        for (AggregateResult aggregateRow : Database.query(soql)) {
          Id relationId = (Id) aggregateRow.get('relationId');
          Integer countValue = Integer.valueOf(String.valueOf(aggregateRow.get('totalRows')));
          relationshipTotal += countValue;
          Integer existing = output.countsByRecordId.containsKey(relationId) ? output.countsByRecordId.get(relationId) : 0;
          output.countsByRecordId.put(relationId, existing + countValue);
        }

        if (relationshipTotal > 0) {
          RelatedSummary summary = new RelatedSummary();
          summary.relationshipLabel = plan.relationshipLabel;
          summary.childObjectApiName = plan.childObjectApiName;
          summary.fieldApiName = plan.fieldApiName;
          summary.recordCount = relationshipTotal;
          output.summaries.add(summary);
        }
      } catch (Exception ex) {
        output.warnings.add(
          'Skipped relationship count for ' +
          plan.childObjectApiName +
          '.' +
          plan.fieldApiName +
          ': ' +
          describeException(ex)
        );
      }
    }

    output.summaries.sort(new RelatedSummarySorter());
    return output;
  }

  private static List<RelationshipPlan> discoverRelationshipPlans(
    Schema.DescribeSObjectResult describeResult,
    List<String> warnings
  ) {
    List<RelationshipPlan> plans = new List<RelationshipPlan>();
    Set<String> seenKeys = new Set<String>();

    for (Schema.ChildRelationship relationship : describeResult.getChildRelationships()) {
      if (relationship == null || relationship.getField() == null || relationship.getChildSObject() == null) {
        continue;
      }

      Schema.DescribeFieldResult fieldDescribe = relationship.getField().getDescribe();
      Schema.DescribeSObjectResult childDescribe = relationship.getChildSObject().getDescribe();
      if (!fieldDescribe.isUpdateable() || !childDescribe.isQueryable() || childDescribe.isDeprecatedAndHidden()) {
        continue;
      }

      String childObjectApiName = childDescribe.getName();
      String fieldApiName = fieldDescribe.getName();
      String dedupeKey = childObjectApiName + '.' + fieldApiName;
      if (seenKeys.contains(dedupeKey)) {
        continue;
      }

      RelationshipPlan plan = new RelationshipPlan();
      plan.childObjectApiName = childObjectApiName;
      plan.fieldApiName = fieldApiName;
      plan.relationshipLabel = String.isBlank(relationship.getRelationshipName())
        ? childDescribe.getLabel()
        : relationship.getRelationshipName();
      plan.priority = relationshipPriority(childObjectApiName);
      plans.add(plan);
      seenKeys.add(dedupeKey);
    }

    plans.sort(new RelationshipPlanSorter());
    if (plans.size() > MAX_RELATIONSHIP_SCANS) {
      warnings.add(
        'Relationship scanning capped at ' +
        String.valueOf(MAX_RELATIONSHIP_SCANS) +
        ' child relationships to stay within Apex limits.'
      );
      List<RelationshipPlan> trimmedPlans = new List<RelationshipPlan>();
      for (Integer i = 0; i < MAX_RELATIONSHIP_SCANS; i++) {
        trimmedPlans.add(plans[i]);
      }
      return trimmedPlans;
    }
    return plans;
  }

  private static Boolean shouldIncludeInMergeProposal(String fieldName, Schema.DescribeFieldResult describeResult) {
    if (String.isBlank(fieldName) || describeResult == null) {
      return false;
    }
    if (fieldName == 'Id' || fieldName == 'IsDeleted' || fieldName == 'MasterRecordId') {
      return false;
    }
    if (!describeResult.isAccessible() || !describeResult.isUpdateable() || describeResult.isCalculated() || describeResult.isAutoNumber()) {
      return false;
    }
    if (describeResult.getType() == Schema.DisplayType.Base64 || describeResult.getType() == Schema.DisplayType.Address) {
      return false;
    }
    return true;
  }

  private static Integer relationshipPriority(String childObjectApiName) {
    if (String.isBlank(childObjectApiName)) {
      return 100;
    }
    Map<String, Integer> priorities = new Map<String, Integer>{
      'Task' => 1,
      'Event' => 2,
      'Contact' => 3,
      'Opportunity' => 4,
      'Case' => 5,
      'ContentDocumentLink' => 6,
      'Note' => 7,
      'Attachment' => 8
    };
    return priorities.containsKey(childObjectApiName) ? priorities.get(childObjectApiName) : 50;
  }

  private static String classifyRisk(String fieldApiName, Schema.DescribeFieldResult describeResult) {
    String normalized = fieldApiName == null ? '' : fieldApiName.toLowerCase();
    if (
      normalized.contains('owner') ||
      normalized.contains('status') ||
      normalized.contains('stage') ||
      normalized.contains('amount') ||
      normalized.contains('parent') ||
      normalized.contains('external') ||
      normalized.contains('consent') ||
      normalized.contains('compliance') ||
      normalized.contains('tax') ||
      normalized.contains('vat') ||
      normalized.contains('ssn')
    ) {
      return 'HIGH';
    }
    if (describeResult.isExternalId() || describeResult.isUnique()) {
      return 'HIGH';
    }

    Schema.DisplayType fieldType = describeResult.getType();
    if (
      fieldType == Schema.DisplayType.Reference ||
      fieldType == Schema.DisplayType.Picklist ||
      fieldType == Schema.DisplayType.MultiPicklist ||
      fieldType == Schema.DisplayType.Currency ||
      fieldType == Schema.DisplayType.Percent ||
      fieldType == Schema.DisplayType.Date ||
      fieldType == Schema.DisplayType.DateTime ||
      fieldType == Schema.DisplayType.Boolean
    ) {
      return 'HIGH';
    }
    return 'LOW';
  }

  private static Id selectBestConflictingRecord(MergeContext context, String fieldName) {
    RecordContext best;
    for (RecordContext recordCtx : context.orderedRecords) {
      String value = recordCtx.flatFields.get(fieldName);
      if (String.isBlank(value)) {
        continue;
      }

      if (
        best == null ||
        recordCtx.survivorScore > best.survivorScore ||
        (recordCtx.survivorScore == best.survivorScore && value.length() > best.flatFields.get(fieldName).length())
      ) {
        best = recordCtx;
      }
    }
    return best == null ? null : best.recordId;
  }

  private static Integer scoreRecordQuality(Map<String, String> fields) {
    Integer score = 0;
    Integer nonBlank = 0;
    for (String fieldName : fields.keySet()) {
      if (!String.isBlank(fields.get(fieldName))) {
        nonBlank++;
      }
    }

    score += Math.min(nonBlank, 60);
    for (String prioritized : new List<String>{
      'Name',
      'FirstName',
      'LastName',
      'Email',
      'Phone',
      'MobilePhone',
      'Company',
      'Website',
      'BillingStreet',
      'ShippingStreet',
      'Description'
    }) {
      if (!String.isBlank(fields.get(prioritized))) {
        score += 4;
      }
    }
    return clampScore(score);
  }

  private static Integer scoreExternalIds(SObject row, Map<String, Schema.SObjectField> fieldMap) {
    Integer score = 0;
    for (String fieldName : fieldMap.keySet()) {
      Schema.DescribeFieldResult describeResult = fieldMap.get(fieldName).getDescribe();
      if (!describeResult.isExternalId()) {
        continue;
      }

      Object value = safeGetField(row, fieldName);
      if (value != null && !String.isBlank(String.valueOf(value))) {
        score += 10;
      }
    }
    return score;
  }

  private static Integer scoreRecentActivity(SObject row, Map<String, Schema.SObjectField> fieldMap) {
    Datetime lastModified = fieldMap.containsKey('LastModifiedDate') ? (Datetime) safeGetField(row, 'LastModifiedDate') : null;
    Date lastActivity = fieldMap.containsKey('LastActivityDate') ? (Date) safeGetField(row, 'LastActivityDate') : null;

    Integer score = 0;
    if (lastModified != null) {
      Integer days = lastModified.date().daysBetween(Date.today());
      if (days <= 30) {
        score += 15;
      } else if (days <= 180) {
        score += 10;
      } else {
        score += 4;
      }
    }

    if (lastActivity != null) {
      Integer activityAge = lastActivity.daysBetween(Date.today());
      if (activityAge <= 30) {
        score += 12;
      } else if (activityAge <= 180) {
        score += 7;
      } else {
        score += 2;
      }
    }
    return score;
  }

  private static QueryResultContext queryAllFieldsForRecords(String objectApiName, Set<Id> ids) {
    QueryResultContext result = new QueryResultContext();
    if (ids == null || ids.isEmpty()) {
      return result;
    }

    Map<String, Schema.SObjectField> fieldMap = Schema.getGlobalDescribe().get(objectApiName).getDescribe().fields.getMap();
    List<String> allQueryableFields = buildQueryableFieldList(fieldMap);

    try {
      result.recordsById =
        new Map<Id, SObject>(Database.query('SELECT FIELDS(ALL) FROM ' + objectApiName + ' WHERE Id IN :ids'));
      result.queriedFieldNames = allQueryableFields;
      return result;
    } catch (Exception ignored) {
      try {
        String soql = 'SELECT ' + String.join(allQueryableFields, ',') + ' FROM ' + objectApiName + ' WHERE Id IN :ids';
        result.recordsById = new Map<Id, SObject>(Database.query(soql));
        result.queriedFieldNames = allQueryableFields;
        return result;
      } catch (Exception secondFailure) {
        result.recordsById = new Map<Id, SObject>(Database.query('SELECT Id FROM ' + objectApiName + ' WHERE Id IN :ids'));
        result.queriedFieldNames = new List<String>{ 'Id' };
        return result;
      }
    }
  }

  private static List<String> buildQueryableFieldList(Map<String, Schema.SObjectField> fieldMap) {
    List<String> fields = new List<String>();
    Set<String> added = new Set<String>();

    List<String> sortedFieldNames = new List<String>(fieldMap.keySet());
    sortedFieldNames.sort();
    for (String fieldName : sortedFieldNames) {
      if (fields.size() >= MAX_QUERYABLE_FIELDS) {
        break;
      }

      Schema.DescribeFieldResult describeResult = fieldMap.get(fieldName).getDescribe();
      if (
        added.contains(fieldName.toLowerCase()) ||
        !describeResult.isAccessible() ||
        describeResult.getType() == Schema.DisplayType.Base64
      ) {
        continue;
      }

      added.add(fieldName.toLowerCase());
      fields.add(fieldName);
    }

    if (!added.contains('id') && fieldMap.containsKey('Id')) {
      fields.add(0, 'Id');
    }
    return fields;
  }

  private static Map<String, String> flattenFields(SObject row, List<String> fieldNames) {
    Map<String, String> out = new Map<String, String>();
    for (String fieldName : fieldNames) {
      out.put(fieldName, formatValue(safeGetField(row, fieldName)));
    }
    return out;
  }

  private static String deriveDisplayValue(SObject row, Set<String> queriedFieldSet, String fallbackId) {
    if (row == null) {
      return fallbackId;
    }

    Object nameValue = queriedFieldSet.contains('name') ? safeGetField(row, 'Name') : null;
    if (nameValue != null) {
      return String.valueOf(nameValue);
    }

    Object subjectValue = queriedFieldSet.contains('subject') ? safeGetField(row, 'Subject') : null;
    if (subjectValue != null) {
      return String.valueOf(subjectValue);
    }
    return fallbackId;
  }

  private static Map<String, Object> buildSnapshotPayload(RecordContext recordCtx) {
    Map<String, Object> payload = new Map<String, Object>();
    payload.put('recordId', String.valueOf(recordCtx.recordId));
    payload.put('displayValue', recordCtx.displayValue);
    payload.put('fields', recordCtx.row.getPopulatedFieldsAsMap());
    return payload;
  }

  private static Map<String, Object> buildAuditPayload(
    MergeProposal proposal,
    Map<String, String> selectionByField,
    MergeExecutionResult result
  ) {
    List<Map<String, Object>> fieldPayload = new List<Map<String, Object>>();
    for (FieldProposal fieldProposal : proposal.fields) {
      Map<String, Object> row = new Map<String, Object>();
      row.put('fieldApiName', fieldProposal.fieldApiName);
      row.put('recommendedSourceRecordId', fieldProposal.recommendedSourceRecordId);
      row.put(
        'selectedSourceRecordId',
        selectionByField.containsKey(fieldProposal.fieldApiName)
          ? selectionByField.get(fieldProposal.fieldApiName)
          : fieldProposal.selectedSourceRecordId
      );
      row.put('riskLevel', fieldProposal.riskLevel);
      row.put('requiresReview', fieldProposal.requiresReview);
      row.put('recommendedValue', fieldProposal.recommendedValue);
      fieldPayload.add(row);
    }

    Map<String, Object> payload = new Map<String, Object>();
    payload.put('proposalSummary', proposal.summary);
    payload.put('survivorRecordId', proposal.survivorRecordId);
    payload.put('relatedSummaries', proposal.relatedSummaries);
    payload.put('warnings', result.warnings);
    payload.put('errors', result.errors);
    payload.put('fields', fieldPayload);
    return payload;
  }

  private static Map<String, String> buildSelectionMap(List<FieldSelectionInput> fieldSelections) {
    Map<String, String> out = new Map<String, String>();
    if (fieldSelections == null) {
      return out;
    }

    for (FieldSelectionInput input : fieldSelections) {
      if (input == null || String.isBlank(input.fieldApiName)) {
        continue;
      }
      out.put(input.fieldApiName, input.sourceRecordId);
    }
    return out;
  }

  private static Boolean canAssignMergedStatus(Schema.DescribeFieldResult describeResult) {
    if (describeResult == null) {
      return false;
    }
    if (describeResult.getType() == Schema.DisplayType.String || describeResult.getType() == Schema.DisplayType.TextArea) {
      return true;
    }
    if (describeResult.getType() != Schema.DisplayType.Picklist) {
      return false;
    }
    for (Schema.PicklistEntry entry : describeResult.getPicklistValues()) {
      if (entry.getValue() == 'Merged') {
        return true;
      }
    }
    return false;
  }

  private static String normalizeValueForConflict(String value, Schema.DescribeFieldResult describeResult) {
    if (String.isBlank(value)) {
      return '';
    }

    Schema.DisplayType fieldType = describeResult.getType();
    if (
      fieldType == Schema.DisplayType.Phone ||
      fieldType == Schema.DisplayType.Email ||
      fieldType == Schema.DisplayType.Url
    ) {
      return value.replaceAll('[^a-zA-Z0-9]', '').toLowerCase();
    }
    return value.trim().toLowerCase();
  }

  private static String buildSurvivorReason(RecordContext recordCtx) {
    return
      'Completeness ' +
      String.valueOf(recordCtx.completenessScore) +
      ', related records ' +
      String.valueOf(recordCtx.relatedRecordCount) +
      ', external ID score ' +
      String.valueOf(recordCtx.externalIdScore) +
      ', recent activity score ' +
      String.valueOf(recordCtx.activityScore) +
      '.';
  }

  private static Boolean isEmptyUpdate(SObject row) {
    return row == null || row.getPopulatedFieldsAsMap().size() <= 1;
  }

  private static Set<Id> coerceIds(List<String> rawIds) {
    Set<Id> out = new Set<Id>();
    if (rawIds == null) {
      return out;
    }

    for (String rawId : rawIds) {
      Id parsed = parseId(rawId);
      if (parsed != null) {
        out.add(parsed);
      }
    }
    return out;
  }

  private static List<String> stringifyIds(List<Id> ids) {
    List<String> out = new List<String>();
    if (ids == null) {
      return out;
    }
    for (Id idValue : ids) {
      if (idValue != null) {
        out.add(String.valueOf(idValue));
      }
    }
    return out;
  }

  private static Id parseId(String rawId) {
    if (String.isBlank(rawId)) {
      return null;
    }
    try {
      return (Id) rawId;
    } catch (Exception ignored) {
      return null;
    }
  }

  private static Object safeGetField(SObject row, String fieldName) {
    if (row == null) {
      return null;
    }
    try {
      return row.get(fieldName);
    } catch (Exception ignored) {
      return null;
    }
  }

  private static Boolean areValuesEqual(Object left, Object right) {
    return formatValue(left) == formatValue(right);
  }

  private static Integer clampScore(Integer raw) {
    if (raw == null || raw < 0) {
      return 0;
    }
    if (raw > 100) {
      return 100;
    }
    return raw;
  }

  private static String formatValue(Object value) {
    if (value == null) {
      return '';
    }
    if (value instanceof Date) {
      return ((Date) value).format();
    }
    if (value instanceof Datetime) {
      return ((Datetime) value).format('yyyy-MM-dd HH:mm');
    }
    return String.valueOf(value);
  }

  private static void validateObjectApiName(String objectApiName) {
    if (String.isBlank(objectApiName) || !Schema.getGlobalDescribe().containsKey(objectApiName)) {
      throw new AuraHandledException('Unknown object: ' + objectApiName);
    }
  }

  private static String describeException(Exception ex) {
    if (ex == null) {
      return 'Unknown error.';
    }
    String message = ex.getMessage();
    if (String.isBlank(message) || message == 'Script-thrown exception') {
      message = ex.getTypeName();
    }
    return message;
  }

  private static String truncateLongText(String value) {
    if (String.isBlank(value) || value.length() <= MAX_SNAPSHOT_LENGTH) {
      return value;
    }
    return value.substring(0, MAX_SNAPSHOT_LENGTH);
  }

  private class SurvivorSorter implements Comparator<RecordContext> {
    public Integer compare(RecordContext left, RecordContext right) {
      if (left.survivorScore != right.survivorScore) {
        return left.survivorScore > right.survivorScore ? -1 : 1;
      }
      if (left.relatedRecordCount != right.relatedRecordCount) {
        return left.relatedRecordCount > right.relatedRecordCount ? -1 : 1;
      }
      return String.valueOf(left.recordId).compareTo(String.valueOf(right.recordId));
    }
  }

  private class FieldProposalSorter implements Comparator<FieldProposal> {
    public Integer compare(FieldProposal left, FieldProposal right) {
      if (left.requiresReview != right.requiresReview) {
        return left.requiresReview ? -1 : 1;
      }
      return left.fieldLabel.toLowerCase().compareTo(right.fieldLabel.toLowerCase());
    }
  }

  private class RelationshipPlanSorter implements Comparator<RelationshipPlan> {
    public Integer compare(RelationshipPlan left, RelationshipPlan right) {
      if (left.priority != right.priority) {
        return left.priority < right.priority ? -1 : 1;
      }
      return left.relationshipLabel.toLowerCase().compareTo(right.relationshipLabel.toLowerCase());
    }
  }

  private class RelatedSummarySorter implements Comparator<RelatedSummary> {
    public Integer compare(RelatedSummary left, RelatedSummary right) {
      if (left.recordCount != right.recordCount) {
        return left.recordCount > right.recordCount ? -1 : 1;
      }
      return left.relationshipLabel.toLowerCase().compareTo(right.relationshipLabel.toLowerCase());
    }
  }
}

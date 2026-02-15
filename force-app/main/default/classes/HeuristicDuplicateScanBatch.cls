public with sharing class HeuristicDuplicateScanBatch implements Database.Batchable<SObject>, Database.Stateful {
  private static final Integer MAX_PREVIOUS_SCAN_ROWS_TO_CLEAR = 9000;

  private Id scanId;
  private String objectApiName;
  private String objectLabel;
  private Integer maxRecords;
  private Integer threshold;
  private Boolean clearPreviousResults;

  private Integer processedCount = 0;
  private List<CandidateRecord> candidates = new List<CandidateRecord>();

  private String displayField;
  private String firstNameField;
  private String lastNameField;
  private String companyField;
  private String phoneField;
  private String emailField;
  private String websiteField;
  private String cityField;
  private String streetField;
  private List<String> queryFields = new List<String>();
  private String orderByField;

  public HeuristicDuplicateScanBatch(
    Id scanId,
    String objectApiName,
    String objectLabel,
    Integer maxRecords,
    Integer threshold,
    Boolean clearPreviousResults
  ) {
    this.scanId = scanId;
    this.objectApiName = objectApiName;
    this.objectLabel = objectLabel;
    this.maxRecords = maxRecords;
    this.threshold = threshold;
    this.clearPreviousResults = clearPreviousResults;
  }

  public Database.QueryLocator start(Database.BatchableContext bc) {
    FieldPlan plan = buildFieldPlan(objectApiName);
    displayField = plan.displayField;
    firstNameField = plan.firstNameField;
    lastNameField = plan.lastNameField;
    companyField = plan.companyField;
    phoneField = plan.phoneField;
    emailField = plan.emailField;
    websiteField = plan.websiteField;
    cityField = plan.cityField;
    streetField = plan.streetField;
    queryFields = plan.queryFields;
    orderByField = plan.orderByField;

    update new Heuristic_Duplicate_Scan__c(
      Id = scanId,
      Status__c = 'Running',
      Object_Api_Name__c = objectApiName,
      Object_Label__c = objectLabel,
      Started_At__c = System.now(),
      Last_Heartbeat__c = System.now(),
      Processed_Accounts__c = 0,
      Total_Accounts__c = 0,
      Candidate_Pairs__c = 0,
      Flagged_Accounts__c = 0,
      Flagged_Groups__c = 0,
      Error_Message__c = null
    );

    String soql = 'SELECT ' + String.join(queryFields, ',') + ' FROM ' + objectApiName;
    if (!String.isBlank(orderByField)) {
      soql += ' ORDER BY ' + orderByField + ' DESC';
    }
    if (maxRecords != null && maxRecords > 0) {
      soql += ' LIMIT ' + String.valueOf(maxRecords);
    }

    return Database.getQueryLocator(soql);
  }

  public void execute(Database.BatchableContext bc, List<SObject> scope) {
    for (SObject row : scope) {
      candidates.add(toCandidate(row));
    }

    processedCount += scope.size();
    updateHeartbeat(processedCount);
  }

  public void finish(Database.BatchableContext bc) {
    String failure;
    try {
      if (clearPreviousResults == true) {
        clearPriorResults();
      }

      ScanComputation result = analyzeCandidates();
      persistResults(result);

      update new Heuristic_Duplicate_Scan__c(
        Id = scanId,
        Status__c = 'Completed',
        Completed_At__c = System.now(),
        Last_Heartbeat__c = System.now(),
        Total_Accounts__c = candidates.size(),
        Processed_Accounts__c = processedCount,
        Candidate_Pairs__c = result.candidatePairs,
        Flagged_Accounts__c = result.flaggedRecords,
        Flagged_Groups__c = result.flaggedGroups,
        Error_Message__c = null
      );
    } catch (Exception ex) {
      failure = describeException(ex);
    }

    if (!String.isBlank(failure)) {
      update new Heuristic_Duplicate_Scan__c(
        Id = scanId,
        Status__c = 'Failed',
        Completed_At__c = System.now(),
        Last_Heartbeat__c = System.now(),
        Total_Accounts__c = candidates.size(),
        Processed_Accounts__c = processedCount,
        Error_Message__c = failure
      );
    }
  }

  private void updateHeartbeat(Integer processed) {
    update new Heuristic_Duplicate_Scan__c(
      Id = scanId,
      Last_Heartbeat__c = System.now(),
      Processed_Accounts__c = processed
    );
  }

  private void clearPriorResults() {
    List<Heuristic_Duplicate_Scan__c> previous = [
      SELECT Id
      FROM Heuristic_Duplicate_Scan__c
      WHERE Object_Api_Name__c = :objectApiName AND Id != :scanId
      ORDER BY CreatedDate DESC
      LIMIT 200
    ];

    if (previous.isEmpty()) {
      return;
    }

    Set<Id> previousScanIds = new Set<Id>();
    for (Heuristic_Duplicate_Scan__c row : previous) {
      previousScanIds.add(row.Id);
    }

    deleteInChunks('Heuristic_Duplicate_Member__c', 'Scan__c', previousScanIds, MAX_PREVIOUS_SCAN_ROWS_TO_CLEAR);
    deleteInChunks('Heuristic_Duplicate_Group__c', 'Scan__c', previousScanIds, MAX_PREVIOUS_SCAN_ROWS_TO_CLEAR);
    deleteInChunks('Heuristic_Duplicate_Scan__c', 'Id', previousScanIds, 200);
  }

  private static Integer deleteInChunks(
    String objectName,
    String whereField,
    Set<Id> filterIds,
    Integer maxRows
  ) {
    Integer deleted = 0;
    while (deleted < maxRows && Limits.getDmlStatements() < 145) {
      Integer chunkSize = Math.min(200, maxRows - deleted);
      String soql =
        'SELECT Id FROM ' + objectName + ' WHERE ' + whereField + ' IN :filterIds LIMIT ' + String.valueOf(chunkSize);
      List<SObject> rows = Database.query(soql);
      if (rows.isEmpty()) {
        break;
      }

      Database.delete(rows, false);
      deleted += rows.size();
    }

    return deleted;
  }

  private ScanComputation analyzeCandidates() {
    ScanComputation output = new ScanComputation();
    output.groupByRecordId = new Map<Id, String>();
    output.bestScoreById = new Map<Id, Integer>();
    output.bestReasonById = new Map<Id, String>();
    output.candidateById = new Map<Id, CandidateRecord>();

    for (CandidateRecord candidate : candidates) {
      output.candidateById.put(candidate.id, candidate);
    }

    Map<String, List<CandidateRecord>> buckets = buildBuckets(candidates);
    Set<String> seenPairs = new Set<String>();
    Map<Id, Id> parents = new Map<Id, Id>();

    for (String key : buckets.keySet()) {
      List<CandidateRecord> bucketMembers = buckets.get(key);
      if (bucketMembers.size() < 2 || bucketMembers.size() > 70) {
        continue;
      }

      for (Integer i = 0; i < bucketMembers.size() - 1; i++) {
        CandidateRecord left = bucketMembers[i];
        for (Integer j = i + 1; j < bucketMembers.size(); j++) {
          CandidateRecord right = bucketMembers[j];
          String pairKey = orderedPairKey(left.id, right.id);
          if (seenPairs.contains(pairKey)) {
            continue;
          }

          seenPairs.add(pairKey);
          output.candidatePairs++;

          PairScore score = scorePair(left, right);
          if (score.value < threshold) {
            continue;
          }

          union(parents, left.id, right.id);
          trackBest(output.bestScoreById, output.bestReasonById, left.id, score);
          trackBest(output.bestScoreById, output.bestReasonById, right.id, score);
        }
      }
    }

    Map<Id, List<Id>> membersByRoot = new Map<Id, List<Id>>();
    for (Id memberId : parents.keySet()) {
      Id root = find(parents, memberId);
      if (!membersByRoot.containsKey(root)) {
        membersByRoot.put(root, new List<Id>());
      }
      membersByRoot.get(root).add(memberId);
    }

    List<Id> sortedRoots = new List<Id>();
    sortedRoots.addAll(membersByRoot.keySet());
    sortedRoots.sort();

    Integer counter = 1;
    for (Id rootId : sortedRoots) {
      List<Id> members = membersByRoot.get(rootId);
      if (members.size() < 2) {
        continue;
      }

      members.sort();
      String groupKey = buildGroupKey(counter);
      counter++;
      output.flaggedGroups++;

      for (Id memberId : members) {
        output.flaggedRecords++;
        output.groupByRecordId.put(memberId, groupKey);
      }
    }

    return output;
  }

  private void persistResults(ScanComputation result) {
    if (result.groupByRecordId.isEmpty()) {
      return;
    }

    Map<String, List<Id>> memberIdsByGroup = new Map<String, List<Id>>();
    for (Id recordId : result.groupByRecordId.keySet()) {
      String groupKey = result.groupByRecordId.get(recordId);
      if (!memberIdsByGroup.containsKey(groupKey)) {
        memberIdsByGroup.put(groupKey, new List<Id>());
      }
      memberIdsByGroup.get(groupKey).add(recordId);
    }

    List<String> sortedGroupKeys = new List<String>();
    sortedGroupKeys.addAll(memberIdsByGroup.keySet());
    sortedGroupKeys.sort();

    List<Heuristic_Duplicate_Group__c> groupsToInsert = new List<Heuristic_Duplicate_Group__c>();
    for (String groupKey : sortedGroupKeys) {
      List<Id> memberIds = memberIdsByGroup.get(groupKey);
      Integer topScore = 0;
      for (Id memberId : memberIds) {
        Integer score = result.bestScoreById.containsKey(memberId) ? result.bestScoreById.get(memberId) : 0;
        topScore = Math.max(topScore, score);
      }

      Heuristic_Duplicate_Group__c groupRow = new Heuristic_Duplicate_Group__c();
      groupRow.Scan__c = scanId;
      groupRow.Object_Api_Name__c = objectApiName;
      groupRow.Group_Key__c = groupKey;
      groupRow.Record_Count__c = memberIds.size();
      groupRow.Top_Score__c = topScore;
      groupRow.Summary__c = buildGroupSummary(memberIds, result.bestReasonById);
      groupsToInsert.add(groupRow);
    }

    insert groupsToInsert;

    Map<String, Id> groupIdByKey = new Map<String, Id>();
    for (Heuristic_Duplicate_Group__c insertedGroup : groupsToInsert) {
      groupIdByKey.put(insertedGroup.Group_Key__c, insertedGroup.Id);
    }

    List<Heuristic_Duplicate_Member__c> membersToInsert = new List<Heuristic_Duplicate_Member__c>();
    for (String groupKey : sortedGroupKeys) {
      List<Id> memberIds = memberIdsByGroup.get(groupKey);
      memberIds.sort();

      for (Id recordId : memberIds) {
        CandidateRecord candidate = result.candidateById.get(recordId);
        Heuristic_Duplicate_Member__c member = new Heuristic_Duplicate_Member__c();
        member.Scan__c = scanId;
        member.Group__c = groupIdByKey.get(groupKey);
        member.Object_Api_Name__c = objectApiName;
        member.Record_Id__c = String.valueOf(recordId);
        member.Display_Value__c = candidate == null ? String.valueOf(recordId) : candidate.displayValue;
        member.Score__c = result.bestScoreById.containsKey(recordId) ? result.bestScoreById.get(recordId) : 0;
        member.Reason__c = result.bestReasonById.get(recordId);
        member.Phone__c = candidate == null ? '' : candidate.phoneValue;
        member.City__c = candidate == null ? '' : candidate.cityValue;
        member.Website__c = candidate == null ? '' : candidate.websiteValue;
        membersToInsert.add(member);

        if (membersToInsert.size() == 200) {
          Database.insert(membersToInsert, false);
          membersToInsert.clear();
        }
      }
    }

    if (!membersToInsert.isEmpty()) {
      Database.insert(membersToInsert, false);
    }
  }

  private static String buildGroupSummary(List<Id> memberIds, Map<Id, String> reasonsById) {
    Set<String> reasons = new Set<String>();
    for (Id memberId : memberIds) {
      if (reasonsById.containsKey(memberId) && !String.isBlank(reasonsById.get(memberId))) {
        reasons.add(reasonsById.get(memberId));
      }
    }

    if (reasons.isEmpty()) {
      return 'Grouped by heuristic similarity.';
    }

    List<String> sortedReasons = new List<String>();
    sortedReasons.addAll(reasons);
    sortedReasons.sort();
    String combined = String.join(sortedReasons, ' | ');
    if (combined.length() > 1000) {
      return combined.substring(0, 997) + '...';
    }
    return combined;
  }

  private static Map<String, List<CandidateRecord>> buildBuckets(List<CandidateRecord> input) {
    Map<String, List<CandidateRecord>> out = new Map<String, List<CandidateRecord>>();
    for (CandidateRecord row : input) {
      addToBucket(out, keyFromName(row), row);
      addToBucket(out, keyFromPhone(row), row);
      addToBucket(out, keyFromEmail(row), row);
      addToBucket(out, keyFromDomain(row), row);
    }
    return out;
  }

  private static void addToBucket(Map<String, List<CandidateRecord>> out, String key, CandidateRecord row) {
    if (String.isBlank(key)) {
      return;
    }
    if (!out.containsKey(key)) {
      out.put(key, new List<CandidateRecord>());
    }
    out.get(key).add(row);
  }

  private static String keyFromName(CandidateRecord row) {
    if (String.isBlank(row.nameCompact) || row.nameCompact.length() < 4) {
      return null;
    }
    String prefix = row.nameCompact.substring(0, Math.min(6, row.nameCompact.length()));
    String cityPart = String.isBlank(row.cityNorm) ? '' : row.cityNorm;
    return 'N|' + prefix + '|' + cityPart;
  }

  private static String keyFromPhone(CandidateRecord row) {
    if (String.isBlank(row.phoneNorm) || row.phoneNorm.length() < 7) {
      return null;
    }
    return 'P|' + row.phoneNorm;
  }

  private static String keyFromEmail(CandidateRecord row) {
    if (String.isBlank(row.emailNorm)) {
      return null;
    }
    return 'E|' + row.emailNorm;
  }

  private static String keyFromDomain(CandidateRecord row) {
    if (String.isBlank(row.domainNorm)) {
      return null;
    }
    return 'D|' + row.domainNorm;
  }

  private static PairScore scorePair(CandidateRecord left, CandidateRecord right) {
    PairScore out = new PairScore();
    Integer score = 0;
    List<String> reasons = new List<String>();

    Integer namePoints = scoreName(left.nameNorm, left.nameCompact, right.nameNorm, right.nameCompact);
    score += namePoints;
    if (namePoints >= 50) {
      reasons.add('Name normalized exact');
    } else if (namePoints >= 35) {
      reasons.add('Name highly similar');
    }

    if (!String.isBlank(left.emailNorm) && left.emailNorm == right.emailNorm) {
      score += 35;
      reasons.add('Email exact');
    } else if (!String.isBlank(left.emailNorm) && !String.isBlank(right.emailNorm)) {
      score -= 15;
    }

    if (!String.isBlank(left.phoneNorm) && left.phoneNorm == right.phoneNorm) {
      score += 25;
      reasons.add('Phone exact');
    } else if (!String.isBlank(left.phoneNorm) && !String.isBlank(right.phoneNorm)) {
      score -= 10;
    }

    if (!String.isBlank(left.domainNorm) && left.domainNorm == right.domainNorm) {
      score += 18;
      reasons.add('Domain exact');
    } else if (!String.isBlank(left.domainNorm) && !String.isBlank(right.domainNorm)) {
      score -= 8;
    }

    if (!String.isBlank(left.cityNorm) && left.cityNorm == right.cityNorm) {
      score += 8;
      reasons.add('City exact');
    } else if (!String.isBlank(left.cityNorm) && !String.isBlank(right.cityNorm)) {
      score -= 4;
    }

    if (!String.isBlank(left.streetNorm) && left.streetNorm == right.streetNorm) {
      score += 5;
    }

    out.value = clamp(score);
    out.reason = reasons.isEmpty() ? 'Heuristic field similarity' : String.join(reasons, ', ');
    if (out.reason.length() > 1000) {
      out.reason = out.reason.substring(0, 997) + '...';
    }
    return out;
  }

  private static Integer scoreName(String leftName, String leftCompact, String rightName, String rightCompact) {
    if (String.isBlank(leftCompact) || String.isBlank(rightCompact)) {
      return 0;
    }

    if (leftCompact == rightCompact) {
      return 55;
    }

    Integer score = 0;
    Integer overlap = tokenOverlapPercent(leftName, rightName);
    score += (Integer) Math.round(((Decimal) overlap * 0.45));

    Integer prefixLen = commonPrefixLength(leftCompact, rightCompact);
    Integer maxLen = Math.max(leftCompact.length(), rightCompact.length());
    if (maxLen > 0) {
      Integer prefixPct = (Integer) Math.floor(((Decimal) prefixLen * 100) / maxLen);
      score += (Integer) Math.round(((Decimal) prefixPct * 0.10));
    }

    Integer levenshtein = levenshteinDistance(leftCompact, rightCompact);
    Integer distanceAllowance = Math.max(1, (Integer) Math.floor(((Decimal) maxLen) * 0.2));
    if (levenshtein <= distanceAllowance) {
      score += 18;
    }

    if (
      (leftCompact.contains(rightCompact) || rightCompact.contains(leftCompact)) &&
      Math.min(leftCompact.length(), rightCompact.length()) >= 6
    ) {
      score += 10;
    }

    return Math.min(score, 55);
  }

  private static Integer tokenOverlapPercent(String leftName, String rightName) {
    Set<String> leftTokens = tokenize(leftName);
    Set<String> rightTokens = tokenize(rightName);
    if (leftTokens.isEmpty() || rightTokens.isEmpty()) {
      return 0;
    }

    Integer matches = 0;
    for (String token : leftTokens) {
      if (rightTokens.contains(token)) {
        matches++;
      }
    }

    Integer denominator = Math.max(leftTokens.size(), rightTokens.size());
    if (denominator == 0) {
      return 0;
    }

    return (Integer) Math.floor(((Decimal) matches * 100) / denominator);
  }

  private static Set<String> tokenize(String value) {
    Set<String> tokens = new Set<String>();
    if (String.isBlank(value)) {
      return tokens;
    }

    for (String token : value.split(' ')) {
      if (!String.isBlank(token) && token.length() >= 2) {
        tokens.add(token);
      }
    }

    return tokens;
  }

  private static Integer commonPrefixLength(String left, String right) {
    Integer max = Math.min(left.length(), right.length());
    Integer count = 0;
    for (Integer i = 0; i < max; i++) {
      if (left.substring(i, i + 1) != right.substring(i, i + 1)) {
        break;
      }
      count++;
    }
    return count;
  }

  private static Integer levenshteinDistance(String left, String right) {
    if (left == right) {
      return 0;
    }
    if (String.isBlank(left)) {
      return right.length();
    }
    if (String.isBlank(right)) {
      return left.length();
    }

    Integer leftLen = left.length();
    Integer rightLen = right.length();
    List<Integer> prev = new List<Integer>();
    List<Integer> curr = new List<Integer>();

    for (Integer j = 0; j <= rightLen; j++) {
      prev.add(j);
      curr.add(0);
    }

    for (Integer i = 1; i <= leftLen; i++) {
      curr[0] = i;
      String leftChar = left.substring(i - 1, i);
      for (Integer j = 1; j <= rightLen; j++) {
        Integer cost = leftChar == right.substring(j - 1, j) ? 0 : 1;
        Integer insertCost = curr[j - 1] + 1;
        Integer deleteCost = prev[j] + 1;
        Integer replaceCost = prev[j - 1] + cost;
        curr[j] = Math.min(insertCost, Math.min(deleteCost, replaceCost));
      }

      for (Integer j = 0; j <= rightLen; j++) {
        prev[j] = curr[j];
      }
    }

    return prev[rightLen];
  }

  private static Integer clamp(Integer raw) {
    if (raw == null) {
      return 0;
    }
    if (raw < 0) {
      return 0;
    }
    if (raw > 100) {
      return 100;
    }
    return raw;
  }

  private static void trackBest(
    Map<Id, Integer> bestScoreById,
    Map<Id, String> bestReasonById,
    Id recordId,
    PairScore score
  ) {
    Integer current = bestScoreById.containsKey(recordId) ? bestScoreById.get(recordId) : -1;
    if (score.value > current) {
      bestScoreById.put(recordId, score.value);
      bestReasonById.put(recordId, score.reason);
    }
  }

  private String buildGroupKey(Integer counter) {
    String suffix = String.valueOf(counter);
    while (suffix.length() < 4) {
      suffix = '0' + suffix;
    }

    String scanToken = String.valueOf(scanId).right(4);
    return 'HDS-' + scanToken + '-' + suffix;
  }

  private static String orderedPairKey(Id leftId, Id rightId) {
    String left = String.valueOf(leftId);
    String right = String.valueOf(rightId);
    return left < right ? left + '|' + right : right + '|' + left;
  }

  private static Id find(Map<Id, Id> parent, Id idValue) {
    if (!parent.containsKey(idValue)) {
      parent.put(idValue, idValue);
      return idValue;
    }

    Id root = parent.get(idValue);
    if (root == idValue) {
      return root;
    }

    Id collapsed = find(parent, root);
    parent.put(idValue, collapsed);
    return collapsed;
  }

  private static void union(Map<Id, Id> parent, Id leftId, Id rightId) {
    Id leftRoot = find(parent, leftId);
    Id rightRoot = find(parent, rightId);
    if (leftRoot == rightRoot) {
      return;
    }

    if (String.valueOf(leftRoot) < String.valueOf(rightRoot)) {
      parent.put(rightRoot, leftRoot);
    } else {
      parent.put(leftRoot, rightRoot);
    }
  }

  private CandidateRecord toCandidate(SObject row) {
    CandidateRecord out = new CandidateRecord();
    out.id = (Id) row.get('Id');
    out.displayValue = deriveDisplayValue(row, out.id);
    out.nameNorm = normalizeWords(out.displayValue);
    out.nameCompact = compact(out.nameNorm);

    out.phoneValue = fieldValue(row, phoneField);
    out.phoneNorm = normalizePhone(out.phoneValue);

    out.emailValue = fieldValue(row, emailField);
    out.emailNorm = normalizeEmail(out.emailValue);

    out.websiteValue = fieldValue(row, websiteField);
    out.domainNorm = normalizeDomain(out.websiteValue, out.emailNorm);

    out.cityValue = fieldValue(row, cityField);
    out.cityNorm = compact(normalizeWords(out.cityValue));

    out.streetNorm = compact(normalizeWords(fieldValue(row, streetField)));

    return out;
  }

  private String deriveDisplayValue(SObject row, Id fallbackId) {
    String direct = fieldValue(row, displayField);
    if (!String.isBlank(direct)) {
      return direct;
    }

    String first = fieldValue(row, firstNameField);
    String last = fieldValue(row, lastNameField);
    String combined = (String.isBlank(first) ? '' : first + ' ') + (String.isBlank(last) ? '' : last);
    combined = combined.trim();
    if (!String.isBlank(combined)) {
      return combined;
    }

    String company = fieldValue(row, companyField);
    if (!String.isBlank(company)) {
      return company;
    }

    return String.valueOf(fallbackId);
  }

  private static String fieldValue(SObject row, String fieldApiName) {
    if (String.isBlank(fieldApiName)) {
      return '';
    }

    try {
      Object raw = row.get(fieldApiName);
      return raw == null ? '' : String.valueOf(raw);
    } catch (Exception ignored) {
      return '';
    }
  }

  private static FieldPlan buildFieldPlan(String objectName) {
    Map<String, Schema.SObjectField> fieldMap = Schema.getGlobalDescribe().get(objectName).getDescribe().fields.getMap();

    FieldPlan plan = new FieldPlan();
    Set<String> selected = new Set<String>();
    addField(plan.queryFields, selected, 'Id');

    plan.displayField = pickField(fieldMap, new List<String>{ 'Name', 'Subject', 'Title', 'Company', 'DeveloperName' });
    plan.firstNameField = pickField(fieldMap, new List<String>{ 'FirstName' });
    plan.lastNameField = pickField(fieldMap, new List<String>{ 'LastName' });
    plan.companyField = pickField(fieldMap, new List<String>{ 'Company' });

    plan.phoneField = pickField(fieldMap, new List<String>{ 'Phone', 'MobilePhone', 'HomePhone', 'OtherPhone', 'BusinessPhone' });
    plan.emailField = pickField(fieldMap, new List<String>{ 'Email', 'PersonEmail' });
    plan.websiteField = pickField(fieldMap, new List<String>{ 'Website' });

    plan.cityField = pickField(fieldMap, new List<String>{
      'BillingCity',
      'ShippingCity',
      'MailingCity',
      'OtherCity',
      'City'
    });

    plan.streetField = pickField(fieldMap, new List<String>{
      'BillingStreet',
      'ShippingStreet',
      'MailingStreet',
      'OtherStreet',
      'Street'
    });

    plan.orderByField = pickField(fieldMap, new List<String>{ 'LastModifiedDate', 'CreatedDate' });

    for (String candidate : new List<String>{
      plan.displayField,
      plan.firstNameField,
      plan.lastNameField,
      plan.companyField,
      plan.phoneField,
      plan.emailField,
      plan.websiteField,
      plan.cityField,
      plan.streetField,
      plan.orderByField
    }) {
      addField(plan.queryFields, selected, candidate);
    }

    return plan;
  }

  private static String pickField(Map<String, Schema.SObjectField> fieldMap, List<String> candidates) {
    for (String apiName : candidates) {
      if (!fieldMap.containsKey(apiName)) {
        continue;
      }

      Schema.DescribeFieldResult describeResult = fieldMap.get(apiName).getDescribe();
      if (!describeResult.isAccessible()) {
        continue;
      }

      return apiName;
    }

    return null;
  }

  private static void addField(List<String> fields, Set<String> selected, String apiName) {
    if (String.isBlank(apiName)) {
      return;
    }

    String key = apiName.toLowerCase();
    if (selected.contains(key)) {
      return;
    }

    fields.add(apiName);
    selected.add(key);
  }

  private static String normalizeWords(String value) {
    if (String.isBlank(value)) {
      return '';
    }

    String normalized = value.toLowerCase();
    normalized = normalized.replaceAll('[^a-z0-9]', ' ');
    normalized = normalized.replaceAll('\\s+', ' ').trim();
    return normalized;
  }

  private static String compact(String value) {
    if (String.isBlank(value)) {
      return '';
    }

    String out = value.replace(' ', '');
    out = stripLegalSuffixes(out);
    return out;
  }

  private static String stripLegalSuffixes(String value) {
    if (String.isBlank(value)) {
      return '';
    }

    String out = value;
    for (String suffix : new List<String>{ 'inc', 'llc', 'ltd', 'corp', 'co', 'company' }) {
      if (out.endsWith(suffix) && out.length() > suffix.length() + 2) {
        out = out.substring(0, out.length() - suffix.length());
      }
    }
    return out;
  }

  private static String normalizePhone(String value) {
    if (String.isBlank(value)) {
      return '';
    }

    String digits = value.replaceAll('[^0-9]', '');
    if (digits.length() > 10) {
      return digits.right(10);
    }
    return digits;
  }

  private static String normalizeEmail(String value) {
    if (String.isBlank(value)) {
      return '';
    }
    return value.trim().toLowerCase();
  }

  private static String normalizeDomain(String website, String emailNorm) {
    String value = String.isBlank(website) ? '' : website.toLowerCase().trim();
    if (!String.isBlank(value)) {
      if (value.startsWith('http://')) {
        value = value.substring(7);
      }
      if (value.startsWith('https://')) {
        value = value.substring(8);
      }
      if (value.startsWith('www.')) {
        value = value.substring(4);
      }

      Integer slashPos = value.indexOf('/');
      if (slashPos > -1) {
        value = value.substring(0, slashPos);
      }

      return value;
    }

    if (!String.isBlank(emailNorm) && emailNorm.contains('@')) {
      return emailNorm.substringAfter('@');
    }

    return '';
  }

  private static String describeException(Exception ex) {
    if (ex == null) {
      return 'Unknown error.';
    }

    String message = ex.getMessage();
    if (String.isBlank(message)) {
      message = ex.getTypeName();
    }

    if (message.length() > 32768) {
      return message.substring(0, 32765) + '...';
    }
    return message;
  }

  private class ScanComputation {
    public Integer candidatePairs = 0;
    public Integer flaggedRecords = 0;
    public Integer flaggedGroups = 0;
    public Map<Id, String> groupByRecordId;
    public Map<Id, Integer> bestScoreById;
    public Map<Id, String> bestReasonById;
    public Map<Id, CandidateRecord> candidateById;
  }

  private class PairScore {
    public Integer value;
    public String reason;
  }

  private class CandidateRecord {
    public Id id;
    public String displayValue;
    public String nameNorm;
    public String nameCompact;

    public String phoneValue;
    public String phoneNorm;

    public String emailValue;
    public String emailNorm;

    public String websiteValue;
    public String domainNorm;

    public String cityValue;
    public String cityNorm;

    public String streetNorm;
  }

  private class FieldPlan {
    public List<String> queryFields = new List<String>();
    public String displayField;
    public String firstNameField;
    public String lastNameField;
    public String companyField;
    public String phoneField;
    public String emailField;
    public String websiteField;
    public String cityField;
    public String streetField;
    public String orderByField;
  }
}

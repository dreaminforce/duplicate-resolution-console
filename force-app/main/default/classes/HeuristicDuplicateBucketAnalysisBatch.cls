public with sharing class HeuristicDuplicateBucketAnalysisBatch implements Database.Batchable<SObject>, Database.Stateful {
  private static final Integer MAX_BUCKET_SIZE = 70;

  private Id scanId;
  private String objectApiName;
  private String objectLabel;
  private Integer threshold;
  private Integer totalRecords;

  private String currentBucketKey;
  private List<CandidateRecord> currentBucket = new List<CandidateRecord>();
  private Boolean currentBucketOverflow = false;
  private Integer candidatePairs = 0;
  private String failure;

  public HeuristicDuplicateBucketAnalysisBatch(
    Id scanId,
    String objectApiName,
    String objectLabel,
    Integer threshold,
    Integer totalRecords
  ) {
    this.scanId = scanId;
    this.objectApiName = objectApiName;
    this.objectLabel = objectLabel;
    this.threshold = threshold == null ? 78 : threshold;
    this.totalRecords = totalRecords == null ? 0 : totalRecords;
  }

  public Database.QueryLocator start(Database.BatchableContext bc) {
    update new Heuristic_Duplicate_Scan__c(
      Id = scanId,
      Status__c = 'Running',
      Object_Api_Name__c = objectApiName,
      Object_Label__c = objectLabel,
      Last_Heartbeat__c = System.now(),
      Total_Accounts__c = totalRecords,
      Processed_Accounts__c = totalRecords
    );

    return Database.getQueryLocator([
      SELECT
        Id,
        Bucket_Key__c,
        Record_Id__c,
        Display_Value__c,
        Name_Normalized__c,
        Name_Compact__c,
        Phone__c,
        Phone_Normalized__c,
        Email_Normalized__c,
        Website__c,
        Domain_Normalized__c,
        City__c,
        City_Normalized__c,
        Street_Normalized__c
      FROM Heuristic_Duplicate_Candidate__c
      WHERE Scan__c = :scanId
      ORDER BY Bucket_Key__c ASC, Record_Id__c ASC
    ]);
  }

  public void execute(Database.BatchableContext bc, List<SObject> scope) {
    if (!String.isBlank(failure)) {
      return;
    }

    try {
      for (SObject source : scope) {
        Heuristic_Duplicate_Candidate__c row = (Heuristic_Duplicate_Candidate__c) source;
        if (String.isBlank(row.Bucket_Key__c) || String.isBlank(row.Record_Id__c)) {
          continue;
        }

        if (currentBucketKey != null && row.Bucket_Key__c != currentBucketKey) {
          analyzeCurrentBucket();
          currentBucket.clear();
          currentBucketOverflow = false;
        }

        currentBucketKey = row.Bucket_Key__c;
        if (currentBucketOverflow) {
          continue;
        }

        currentBucket.add(toCandidate(row));
        if (currentBucket.size() > MAX_BUCKET_SIZE) {
          currentBucket.clear();
          currentBucketOverflow = true;
        }
      }

      Database.delete(scope, false);
      update new Heuristic_Duplicate_Scan__c(
        Id = scanId,
        Last_Heartbeat__c = System.now(),
        Candidate_Pairs__c = candidatePairs
      );
    } catch (Exception ex) {
      failure = describeException(ex);
    }
  }

  public void finish(Database.BatchableContext bc) {
    try {
      if (String.isBlank(failure)) {
        analyzeCurrentBucket();
      }
    } catch (Exception ex) {
      failure = describeException(ex);
    }

    if (!String.isBlank(failure)) {
      update new Heuristic_Duplicate_Scan__c(
        Id = scanId,
        Status__c = 'Failed',
        Completed_At__c = System.now(),
        Last_Heartbeat__c = System.now(),
        Total_Accounts__c = totalRecords,
        Processed_Accounts__c = totalRecords,
        Candidate_Pairs__c = candidatePairs,
        Error_Message__c = failure
      );
      Database.executeBatch(new HeuristicDuplicateCandidateCleanupBatch(scanId), 2000);
      return;
    }

    if (Test.isRunningTest()) {
      HeuristicDuplicatePairConsolidationBatch.consolidateSynchronouslyForTest(
        scanId,
        objectApiName,
        objectLabel,
        totalRecords,
        candidatePairs
      );
      return;
    }

    Id consolidationJobId = Database.executeBatch(
      new HeuristicDuplicatePairConsolidationBatch(scanId, objectApiName, objectLabel, totalRecords, candidatePairs),
      1000
    );

    update new Heuristic_Duplicate_Scan__c(
      Id = scanId,
      Job_Id__c = String.valueOf(consolidationJobId),
      Last_Heartbeat__c = System.now(),
      Candidate_Pairs__c = candidatePairs
    );
  }

  private void analyzeCurrentBucket() {
    if (currentBucketOverflow || currentBucket.isEmpty()) {
      return;
    }

    Map<Id, CandidateRecord> candidatesById = new Map<Id, CandidateRecord>();
    for (CandidateRecord row : currentBucket) {
      candidatesById.put(row.id, row);
    }

    List<CandidateRecord> bucketMembers = new List<CandidateRecord>();
    bucketMembers.addAll(candidatesById.values());
    if (bucketMembers.size() < 2 || bucketMembers.size() > MAX_BUCKET_SIZE) {
      return;
    }

    Set<String> seenPairs = new Set<String>();
    List<PairMatch> matches = new List<PairMatch>();

    for (Integer i = 0; i < bucketMembers.size() - 1; i++) {
      CandidateRecord left = bucketMembers[i];
      for (Integer j = i + 1; j < bucketMembers.size(); j++) {
        CandidateRecord right = bucketMembers[j];
        String pairKey = orderedPairKey(left.id, right.id);
        if (seenPairs.contains(pairKey)) {
          continue;
        }

        seenPairs.add(pairKey);
        candidatePairs++;

        PairScore score = scorePair(left, right);
        if (score.value < threshold) {
          continue;
        }

        PairMatch match = new PairMatch();
        match.left = left;
        match.right = right;
        match.score = score;
        matches.add(match);
      }
    }

    persistPairs(matches);
  }

  private void persistPairs(List<PairMatch> matches) {
    if (matches.isEmpty()) {
      return;
    }

    Map<String, PairMatch> matchByKey = new Map<String, PairMatch>();
    for (PairMatch match : matches) {
      String pairKey = buildPairKey(match.left.id, match.right.id);
      if (!matchByKey.containsKey(pairKey) || match.score.value > matchByKey.get(pairKey).score.value) {
        matchByKey.put(pairKey, match);
      }
    }

    Set<String> pairKeys = matchByKey.keySet();
    Map<String, Heuristic_Duplicate_Pair__c> existingByKey = new Map<String, Heuristic_Duplicate_Pair__c>();
    for (Heuristic_Duplicate_Pair__c existing : [
      SELECT Id, Pair_Key__c, Score__c
      FROM Heuristic_Duplicate_Pair__c
      WHERE Pair_Key__c IN :pairKeys
    ]) {
      existingByKey.put(existing.Pair_Key__c, existing);
    }

    List<Heuristic_Duplicate_Pair__c> pairsToInsert = new List<Heuristic_Duplicate_Pair__c>();
    List<Heuristic_Duplicate_Pair__c> pairsToUpdate = new List<Heuristic_Duplicate_Pair__c>();
    for (String pairKey : matchByKey.keySet()) {
      PairMatch match = matchByKey.get(pairKey);
      Heuristic_Duplicate_Pair__c pairRow = existingByKey.get(pairKey);
      Boolean isUpdate = pairRow != null;

      if (isUpdate && toInteger(pairRow.Score__c) >= match.score.value) {
        continue;
      }

      if (!isUpdate) {
        pairRow = new Heuristic_Duplicate_Pair__c();
        pairRow.Pair_Key__c = pairKey;
        pairRow.Scan__c = scanId;
        pairRow.Object_Api_Name__c = objectApiName;
      }

      pairRow.Left_Record_Id__c = String.valueOf(match.left.id);
      pairRow.Right_Record_Id__c = String.valueOf(match.right.id);
      pairRow.Score__c = match.score.value;
      pairRow.Reason__c = match.score.reason;
      pairRow.Left_Display_Value__c = truncate(match.left.displayValue, 255);
      pairRow.Left_Phone__c = truncate(match.left.phoneValue, 80);
      pairRow.Left_City__c = truncate(match.left.cityValue, 120);
      pairRow.Left_Website__c = truncate(match.left.websiteValue, 255);
      pairRow.Right_Display_Value__c = truncate(match.right.displayValue, 255);
      pairRow.Right_Phone__c = truncate(match.right.phoneValue, 80);
      pairRow.Right_City__c = truncate(match.right.cityValue, 120);
      pairRow.Right_Website__c = truncate(match.right.websiteValue, 255);

      if (isUpdate) {
        pairsToUpdate.add(pairRow);
      } else {
        pairsToInsert.add(pairRow);
      }
    }

    if (!pairsToInsert.isEmpty()) {
      Database.insert(pairsToInsert, false);
    }
    if (!pairsToUpdate.isEmpty()) {
      Database.update(pairsToUpdate, false);
    }
  }

  private static CandidateRecord toCandidate(Heuristic_Duplicate_Candidate__c row) {
    CandidateRecord out = new CandidateRecord();
    out.id = (Id) row.Record_Id__c;
    out.displayValue = row.Display_Value__c;
    out.nameNorm = row.Name_Normalized__c;
    out.nameCompact = row.Name_Compact__c;
    out.phoneValue = row.Phone__c;
    out.phoneNorm = row.Phone_Normalized__c;
    out.emailNorm = row.Email_Normalized__c;
    out.websiteValue = row.Website__c;
    out.domainNorm = row.Domain_Normalized__c;
    out.cityValue = row.City__c;
    out.cityNorm = row.City_Normalized__c;
    out.streetNorm = row.Street_Normalized__c;
    return out;
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
    }

    if (!String.isBlank(left.domainNorm) && left.domainNorm == right.domainNorm) {
      score += 25;
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

    if (hasTokenSubset(leftName, rightName)) {
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

  private static Boolean hasTokenSubset(String leftName, String rightName) {
    Set<String> leftTokens = tokenize(leftName);
    Set<String> rightTokens = tokenize(rightName);
    if (leftTokens.size() < 2 || rightTokens.size() < 2 || leftTokens.size() == rightTokens.size()) {
      return false;
    }

    return leftTokens.size() < rightTokens.size()
      ? containsAllTokens(rightTokens, leftTokens)
      : containsAllTokens(leftTokens, rightTokens);
  }

  private static Boolean containsAllTokens(Set<String> source, Set<String> required) {
    for (String token : required) {
      if (!source.contains(token)) {
        return false;
      }
    }
    return true;
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

  private static String orderedPairKey(Id leftId, Id rightId) {
    String left = String.valueOf(leftId);
    String right = String.valueOf(rightId);
    return left < right ? left + '|' + right : right + '|' + left;
  }

  private String buildPairKey(Id leftId, Id rightId) {
    return String.valueOf(scanId) + '|' + orderedPairKey(leftId, rightId);
  }

  private static String truncate(String value, Integer maxLength) {
    if (value == null || maxLength == null || maxLength <= 0 || value.length() <= maxLength) {
      return value;
    }
    return value.substring(0, maxLength);
  }

  private static Integer toInteger(Object raw) {
    if (raw == null) {
      return 0;
    }
    if (raw instanceof Integer) {
      return (Integer) raw;
    }
    if (raw instanceof Long) {
      return Integer.valueOf(String.valueOf(raw));
    }
    if (raw instanceof Decimal) {
      return ((Decimal) raw).intValue();
    }
    return Integer.valueOf(String.valueOf(raw));
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

  private class PairScore {
    public Integer value;
    public String reason;
  }

  private class PairMatch {
    public CandidateRecord left;
    public CandidateRecord right;
    public PairScore score;
  }

  private class CandidateRecord {
    public Id id;
    public String displayValue;
    public String nameNorm;
    public String nameCompact;
    public String phoneValue;
    public String phoneNorm;
    public String emailNorm;
    public String websiteValue;
    public String domainNorm;
    public String cityValue;
    public String cityNorm;
    public String streetNorm;
  }
}

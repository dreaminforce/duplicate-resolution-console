public with sharing class HeuristicDuplicateCandidateCleanupBatch implements Database.Batchable<SObject> {
  private Id scanId;

  public HeuristicDuplicateCandidateCleanupBatch(Id scanId) {
    this.scanId = scanId;
  }

  public Database.QueryLocator start(Database.BatchableContext bc) {
    return Database.getQueryLocator([
      SELECT Id
      FROM Heuristic_Duplicate_Candidate__c
      WHERE Scan__c = :scanId
    ]);
  }

  public void execute(Database.BatchableContext bc, List<SObject> scope) {
    Database.delete(scope, false);
  }

  public void finish(Database.BatchableContext bc) {
    if (!Test.isRunningTest()) {
      Database.executeBatch(new HeuristicDuplicatePairCleanupBatch(scanId), 2000);
    }
  }
}

@IsTest
private class HeuristicDuplicateScanServiceTest {
  @IsTest
  static void startScan_forAccount_persistsGroupsAndMembers() {
    insert new List<Account>{
      new Account(Name = 'Blue Sky Consulting', Phone = '+1 (212) 555-0144', BillingCity = 'New York', Website = 'https://www.bluesky.example'),
      new Account(Name = 'BlueSky Consulting', Phone = '2125550144', BillingCity = 'New York', Website = 'bluesky.example'),
      new Account(Name = 'Red Valley Manufacturing', Phone = '4159991111', BillingCity = 'San Francisco', Website = 'redvalley.example')
    };

    Id scanId;
    Test.startTest();
    scanId = HeuristicDuplicateScanController.startScan('Account', 500, 75, true);
    Test.stopTest();

    Heuristic_Duplicate_Scan__c scan = [
      SELECT
        Status__c,
        Object_Api_Name__c,
        Object_Label__c,
        Flagged_Accounts__c,
        Flagged_Groups__c,
        Total_Accounts__c,
        Threshold__c,
        Max_Accounts__c,
        Completed_At__c
      FROM Heuristic_Duplicate_Scan__c
      WHERE Id = :scanId
      LIMIT 1
    ];

    System.assertEquals('Completed', scan.Status__c);
    System.assertEquals('Account', scan.Object_Api_Name__c);
    System.assertEquals(2, scan.Flagged_Accounts__c.intValue());
    System.assertEquals(1, scan.Flagged_Groups__c.intValue());
    System.assertEquals(3, scan.Total_Accounts__c.intValue());
    System.assertEquals(75, scan.Threshold__c.intValue());
    System.assertEquals(500, scan.Max_Accounts__c.intValue());
    System.assertNotEquals(null, scan.Completed_At__c);

    List<Heuristic_Duplicate_Group__c> groups = [
      SELECT Id, Group_Key__c, Record_Count__c, Top_Score__c, Scan__c, Object_Api_Name__c
      FROM Heuristic_Duplicate_Group__c
      WHERE Scan__c = :scanId
      ORDER BY Group_Key__c ASC
    ];

    System.assertEquals(1, groups.size());
    System.assertEquals(2, groups[0].Record_Count__c.intValue());
    System.assertEquals('Account', groups[0].Object_Api_Name__c);

    List<Heuristic_Duplicate_Member__c> members = [
      SELECT Id, Scan__c, Group__c, Record_Id__c, Display_Value__c, Score__c, Object_Api_Name__c
      FROM Heuristic_Duplicate_Member__c
      WHERE Scan__c = :scanId
      ORDER BY Display_Value__c ASC
    ];

    System.assertEquals(2, members.size());
    System.assertEquals('Account', members[0].Object_Api_Name__c);
    System.assertNotEquals(null, members[0].Record_Id__c);
    System.assertNotEquals(null, members[0].Score__c);

    HeuristicDuplicateScanService.ScanStatus status = HeuristicDuplicateScanController.getScanStatus(scanId);
    System.assertEquals(scanId, status.scanId);
    System.assertEquals('Completed', status.status);
    System.assertEquals('Account', status.objectApiName);
    System.assertEquals(2, status.flaggedRecords);
    System.assertEquals(1, status.flaggedGroups);

    List<HeuristicDuplicateScanService.DuplicateGroup> viewGroups = HeuristicDuplicateScanController.getGroupsForScan(scanId, 10);
    System.assertEquals(1, viewGroups.size());
    System.assertEquals(2, viewGroups[0].recordCount);
    System.assert(viewGroups[0].topScore >= 75);

    HeuristicDuplicateScanService.GroupDetail detail = HeuristicDuplicateScanController.getGroupDetail(viewGroups[0].groupId);
    System.assertEquals(viewGroups[0].groupKey, detail.groupKey);
    System.assertEquals('Account', detail.objectApiName);
    System.assertEquals(2, detail.records.size());
    System.assert(!detail.fieldNames.isEmpty());
  }

  @IsTest
  static void startScan_forContact_onlyMatchesWithinContactObject() {
    insert new List<Account>{
      new Account(Name = 'Northwind Global'),
      new Account(Name = 'North Wind Global')
    };

    Contact c1 = new Contact(FirstName = 'John', LastName = 'Smith', Email = 'john.smith@example.com', Phone = '2125550100', MailingCity = 'New York');
    Contact c2 = new Contact(FirstName = 'Jon', LastName = 'Smith', Email = 'john.smith@example.com', Phone = '(212) 555-0100', MailingCity = 'New York');
    Contact c3 = new Contact(FirstName = 'Elena', LastName = 'Stone', Email = 'elena.stone@example.com', Phone = '4153330000', MailingCity = 'San Jose');
    insert new List<Contact>{ c1, c2, c3 };

    Id scanId;
    Test.startTest();
    scanId = HeuristicDuplicateScanController.startScan('Contact', 1000, 70, true);
    Test.stopTest();

    Heuristic_Duplicate_Scan__c scan = [
      SELECT Status__c, Object_Api_Name__c, Flagged_Accounts__c, Flagged_Groups__c
      FROM Heuristic_Duplicate_Scan__c
      WHERE Id = :scanId
      LIMIT 1
    ];

    System.assertEquals('Completed', scan.Status__c);
    System.assertEquals('Contact', scan.Object_Api_Name__c);
    System.assertEquals(2, scan.Flagged_Accounts__c.intValue());
    System.assertEquals(1, scan.Flagged_Groups__c.intValue());

    List<Heuristic_Duplicate_Member__c> members = [
      SELECT Record_Id__c, Object_Api_Name__c
      FROM Heuristic_Duplicate_Member__c
      WHERE Scan__c = :scanId
    ];

    System.assertEquals(2, members.size());
    for (Heuristic_Duplicate_Member__c row : members) {
      System.assertEquals('Contact', row.Object_Api_Name__c);
      System.assert(row.Record_Id__c.startsWith('003'));
    }
  }

  @IsTest
  static void objectOptions_recentAndCancel_areAvailable() {
    List<HeuristicDuplicateScanService.ObjectOption> options = HeuristicDuplicateScanController.getObjectOptions();
    System.assert(!options.isEmpty());

    Boolean hasAccount = false;
    for (HeuristicDuplicateScanService.ObjectOption option : options) {
      if (option.objectApiName == 'Account') {
        hasAccount = true;
        break;
      }
    }
    System.assertEquals(true, hasAccount);

    Heuristic_Duplicate_Scan__c scan = new Heuristic_Duplicate_Scan__c(
      Status__c = 'Queued',
      Object_Api_Name__c = 'Account',
      Object_Label__c = 'Account',
      Max_Accounts__c = 100,
      Threshold__c = 80,
      Clear_Previous_Flags__c = true
    );
    insert scan;

    List<HeuristicDuplicateScanService.ScanStatus> recent = HeuristicDuplicateScanController.getRecentScans(5);
    System.assert(!recent.isEmpty());

    HeuristicDuplicateScanService.ActionResult cancelResult = HeuristicDuplicateScanController.cancelScan(scan.Id);
    System.assertEquals(false, cancelResult.success);
    System.assert(cancelResult.message.contains('No async job'));
  }

  @IsTest
  static void mergeRecords_forAccount_mergesSelectedChildren() {
    Account parent = new Account(Name = 'Merge Parent', Phone = '2125550101');
    Account child = new Account(Name = 'Merge Child', Phone = '2125550101');
    insert new List<Account>{ parent, child };

    HeuristicDuplicateScanService.ActionResult result = HeuristicDuplicateScanController.mergeRecords(
      'Account',
      parent.Id,
      new List<Id>{ child.Id }
    );

    System.assertEquals(true, result.success, result.message);
    System.assertEquals(1, result.processedCount);

    System.assertEquals(1, [SELECT COUNT() FROM Account WHERE Id = :parent.Id]);
    System.assertEquals(0, [SELECT COUNT() FROM Account WHERE Id = :child.Id]);
  }
}

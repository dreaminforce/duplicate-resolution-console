import { LightningElement, track } from 'lwc';
import { ShowToastEvent } from 'lightning/platformShowToastEvent';

import getObjectOptions from '@salesforce/apex/HeuristicDuplicateScanController.getObjectOptions';
import startScan from '@salesforce/apex/HeuristicDuplicateScanController.startScan';
import getScanStatus from '@salesforce/apex/HeuristicDuplicateScanController.getScanStatus';
import getRecentScans from '@salesforce/apex/HeuristicDuplicateScanController.getRecentScans';
import getGroupsForScan from '@salesforce/apex/HeuristicDuplicateScanController.getGroupsForScan';
import getGroupDetail from '@salesforce/apex/HeuristicDuplicateScanController.getGroupDetail';
import getMergeProposal from '@salesforce/apex/HeuristicDuplicateScanController.getMergeProposal';
import executeSoftMerge from '@salesforce/apex/HeuristicDuplicateScanController.executeSoftMerge';
import cancelScan from '@salesforce/apex/HeuristicDuplicateScanController.cancelScan';

const COMPARISON_VALUE_LIMIT = 160;
const RECORD_LINK_LABEL_LIMIT = 48;

export default class HeuristicDuplicateAdmin extends LightningElement {
  @track objectOptions = [];
  @track selectedObject;
  @track scanStatus;
  @track recentScans = [];
  @track groups = [];
  @track detailGroup;
  @track parentPickerOpen = false;
  @track parentOptions = [];
  @track selectedParentCandidate;
  @track mergeReview;

  loading = false;
  starting = false;
  mergeLoading = false;
  mergeExecuting = false;
  mergeReviewVisible = false;

  selectedScanId;
  maxRecords = 2000;
  scoreThreshold = 78;
  clearPreviousFlags = true;

  pollHandle;

  selectionByGroup = {};
  manualParentByGroup = {};
  detailSourceGroup;
  parentPickerGroupId;

  groupColumns = [
    {
      label: 'Record',
      fieldName: 'recordUrl',
      type: 'url',
      typeAttributes: { label: { fieldName: 'name' } }
    },
    { label: 'Score', fieldName: 'score', type: 'number', fixedWidth: 92 },
    { label: 'Phone', fieldName: 'phone', type: 'text' },
    { label: 'City', fieldName: 'city', type: 'text' },
    { label: 'Website', fieldName: 'website', type: 'text' },
    { label: 'Reason', fieldName: 'reason', type: 'text' }
  ];

  detailColumns = [
    {
      label: 'Record',
      fieldName: 'recordUrl',
      type: 'url',
      typeAttributes: { label: { fieldName: 'displayValue' } }
    },
    { label: 'Survivor', fieldName: 'parentBadge', type: 'text', fixedWidth: 88 },
    { label: 'Score', fieldName: 'score', type: 'number', fixedWidth: 92 },
    { label: 'Reason', fieldName: 'reason', type: 'text' }
  ];

  connectedCallback() {
    this.bootstrap();
  }

  disconnectedCallback() {
    this.stopPolling();
  }

  async bootstrap() {
    await this.loadObjectOptions();
    await this.loadRecentScans();
    await this.refreshSelectedScan();
  }

  get disableRunButton() {
    return this.starting || this.isCurrentScanRunning || !this.selectedObject;
  }

  get hasStatus() {
    return !!this.scanStatus;
  }

  get hasRecentScans() {
    return this.recentScans.length > 0;
  }

  get hasGroups() {
    return this.groups.length > 0;
  }

  get showCancelButton() {
    return this.isCurrentScanRunning;
  }

  get showSummaryView() {
    return !this.detailGroup;
  }

  get showDetailView() {
    return !!this.detailGroup;
  }

  get showDetailComparison() {
    return !!this.detailGroup && !this.mergeReviewVisible && !this.mergeLoading;
  }

  get isCurrentScanRunning() {
    if (!this.scanStatus) {
      return false;
    }

    const status = (this.scanStatus.status || '').toLowerCase();
    const asyncStatus = (this.scanStatus.asyncStatus || '').toLowerCase();
    return (
      status === 'queued' ||
      status === 'running' ||
      asyncStatus === 'queued' ||
      asyncStatus === 'processing' ||
      asyncStatus === 'preparing' ||
      asyncStatus === 'holding'
    );
  }

  get statusBadgeClass() {
    if (!this.scanStatus) {
      return 'status-badge';
    }

    const status = (this.scanStatus.status || '').toLowerCase();
    if (status === 'completed') {
      return 'status-badge success';
    }
    if (status === 'failed' || status === 'cancelled') {
      return 'status-badge error';
    }
    return 'status-badge running';
  }

  async loadObjectOptions() {
    try {
      const rows = await getObjectOptions();
      this.objectOptions = (rows || []).map((row) => ({
        label: row.objectLabel,
        value: row.objectApiName
      }));

      if (!this.selectedObject && this.objectOptions.length) {
        const defaultOption =
          this.objectOptions.find((opt) => opt.value === 'Account') ||
          this.objectOptions.find((opt) => opt.value === 'Contact') ||
          this.objectOptions[0];
        this.selectedObject = defaultOption.value;
      }
    } catch (error) {
      this.notifyError('Failed to load object options', error);
    }
  }

  handleObjectChange(event) {
    this.selectedObject = event.detail.value;
  }

  handleMaxRecordsChange(event) {
    this.maxRecords = Number(event.detail.value);
  }

  handleThresholdChange(event) {
    this.scoreThreshold = Number(event.detail.value);
  }

  handleClearFlagsChange(event) {
    this.clearPreviousFlags = event.detail.checked;
  }

  async handleRunNow() {
    this.starting = true;
    try {
      const scanId = await startScan({
        objectApiName: this.selectedObject,
        maxRecords: this.maxRecords,
        scoreThreshold: this.scoreThreshold,
        clearPreviousFlags: this.clearPreviousFlags
      });

      this.selectedScanId = scanId;
      this.detailGroup = null;
      this.detailSourceGroup = null;
      this.mergeReview = null;
      this.mergeReviewVisible = false;
      await this.refreshSelectedScan();
      await this.loadRecentScans();
      this.startPolling();
      this.notify('Scan started', 'Heuristic duplicate scan started in background.', 'success');
    } catch (error) {
      this.notifyError('Failed to start scan', error);
    } finally {
      this.starting = false;
    }
  }

  async handleRefresh() {
    await this.loadRecentScans();
    await this.refreshSelectedScan();
  }

  async handleCancel() {
    if (!this.selectedScanId) {
      return;
    }

    this.loading = true;
    try {
      const result = await cancelScan({ scanId: this.selectedScanId });
      this.notify(
        result.success ? 'Scan cancelled' : 'Cancel not available',
        result.message,
        result.success ? 'success' : 'warning'
      );
      await this.refreshSelectedScan();
      await this.loadRecentScans();
      if (!this.isCurrentScanRunning) {
        this.stopPolling();
      }
    } catch (error) {
      this.notifyError('Failed to cancel scan', error);
    } finally {
      this.loading = false;
    }
  }

  handleSelectRecent(event) {
    this.selectedScanId = event.currentTarget.dataset.scanId;
    this.detailGroup = null;
    this.detailSourceGroup = null;
    this.mergeReview = null;
    this.mergeReviewVisible = false;
    this.refreshSelectedScan();
  }

  async loadRecentScans() {
    try {
      const rows = await getRecentScans({ maxRows: 15 });
      this.recentScans = (rows || []).map((row) => ({
        ...row,
        statusLabel: row.asyncStatus ? `${row.status} (${row.asyncStatus})` : row.status,
        createdDateLabel: this.formatDate(row.createdDate),
        objectNameLabel: row.objectLabel || row.objectApiName || 'Unknown Object'
      }));

      if (!this.selectedScanId && this.recentScans.length) {
        this.selectedScanId = this.recentScans[0].scanId;
      }
    } catch (error) {
      this.notifyError('Failed to load recent scans', error);
    }
  }

  async refreshSelectedScan() {
    if (!this.selectedScanId) {
      this.scanStatus = null;
      this.groups = [];
      this.stopPolling();
      return;
    }

    this.loading = true;
    try {
      const [status, groups] = await Promise.all([
        getScanStatus({ scanId: this.selectedScanId }),
        getGroupsForScan({ scanId: this.selectedScanId, maxGroups: 40 })
      ]);

      this.scanStatus = {
        ...status,
        createdDateLabel: this.formatDate(status.createdDate),
        startedAtLabel: this.formatDate(status.startedAt),
        completedAtLabel: this.formatDate(status.completedAt),
        heartbeatLabel: this.formatDate(status.lastHeartbeat),
        objectNameLabel: status.objectLabel || status.objectApiName || 'Unknown Object'
      };

      this.selectedObject = status.objectApiName || this.selectedObject;

      this.groups = (groups || []).map((group) => ({
        ...group,
        sectionLabel: `${group.groupKey} (${group.recordCount})`,
        records: (group.records || []).map((record) => ({
          ...record,
          recordUrl: record.recordId ? `/${record.recordId}` : '#'
        }))
      }));

      if (this.detailGroup) {
        const latestDetail = this.groups.find((group) => String(group.groupId) === String(this.detailGroup.groupId));
        if (!latestDetail) {
          this.detailGroup = null;
          this.detailSourceGroup = null;
          this.mergeReview = null;
          this.mergeReviewVisible = false;
        }
      }

      if (this.isCurrentScanRunning) {
        this.startPolling();
      } else {
        this.stopPolling();
      }
    } catch (error) {
      this.notifyError('Failed to refresh selected scan', error);
      this.stopPolling();
    } finally {
      this.loading = false;
    }
  }

  async handleOpenDetail(event) {
    const groupId = event.target.dataset.groupId;
    if (!groupId) {
      return;
    }

    this.loading = true;
    try {
      const detail = await getGroupDetail({ groupId });
      this.detailSourceGroup = detail;
      this.detailGroup = this.mapDetailGroup(detail);
      this.mergeReviewVisible = false;
      if (this.mergeReview && this.mergeReview.groupId !== String(groupId)) {
        this.mergeReview = null;
      }
    } catch (error) {
      this.notifyError('Failed to load group detail', error);
    } finally {
      this.loading = false;
    }
  }

  handleBackToSummary() {
    this.detailGroup = null;
    this.detailSourceGroup = null;
    this.mergeReview = null;
    this.mergeReviewVisible = false;
  }

  buildFieldRows(fieldNames, records) {
    const rows = [];

    fieldNames.forEach((fieldName) => {
      const values = records.map((record) => ({
        recordId: record.recordId,
        cellClass: record.isEffectiveParent ? 'is-parent' : '',
        fullValue: this.normalizeFieldValue(record.fields && record.fields[fieldName]),
        displayValue: this.truncateFieldValue(record.fields && record.fields[fieldName])
      }));

      rows.push({
        name: fieldName,
        values
      });
    });

    return rows;
  }

  mapDetailGroup(detail) {
    const effectiveParentId = this.getEffectiveParentId(detail);
    const records = (detail.records || []).map((row) => ({
      ...row,
      recordUrl: row.recordId ? `/${row.recordId}` : '#',
      isEffectiveParent: !!effectiveParentId && row.recordId === effectiveParentId,
      parentBadge: effectiveParentId && row.recordId === effectiveParentId ? 'Yes' : ''
    }));

    return {
      ...detail,
      canMergeUi: records.length > 1,
      mergeDisabled: !effectiveParentId || records.length < 2,
      effectiveParentId,
      records,
      recordLinks: records.map((record) => ({
        recordId: record.recordId,
        recordUrl: record.recordUrl,
        linkLabel: this.truncateDisplayLabel(record.displayValue)
      })),
      detailFieldRows: this.buildFieldRows(detail.fieldNames || [], records)
    };
  }

  getEffectiveParentId(groupDetail) {
    if (!groupDetail || !groupDetail.groupId) {
      return null;
    }
    const firstRecordId =
      groupDetail.records && groupDetail.records.length ? groupDetail.records[0].recordId : null;
    return this.manualParentByGroup[String(groupDetail.groupId)] || firstRecordId || null;
  }

  handleDetailRowSelection(event) {
    const groupId = event.target.dataset.groupId;
    const selectedIds = (event.detail.selectedRows || []).map((row) => row.recordId);
    this.selectionByGroup = {
      ...this.selectionByGroup,
      [groupId]: selectedIds
    };
    this.clearMergeReviewForGroup(groupId);
  }

  handleSelectParentClick() {
    if (!this.detailGroup || !this.detailGroup.records || !this.detailGroup.records.length) {
      this.notify('No records', 'No records available in this group to select as survivor.', 'info');
      return;
    }

    const groupId = String(this.detailGroup.groupId);
    this.parentPickerGroupId = groupId;
    this.parentOptions = this.detailGroup.records.map((row) => ({
      label: `${row.displayValue} (${row.recordId})`,
      value: row.recordId
    }));
    this.selectedParentCandidate = this.getEffectiveParentId(this.detailGroup) || this.detailGroup.records[0].recordId;
    this.parentPickerOpen = true;
  }

  handleParentCandidateChange(event) {
    this.selectedParentCandidate = event.detail.value;
  }

  handleParentPickerCancel() {
    this.parentPickerOpen = false;
    this.parentOptions = [];
    this.selectedParentCandidate = null;
    this.parentPickerGroupId = null;
  }

  handleParentPickerConfirm() {
    if (!this.parentPickerGroupId || !this.selectedParentCandidate) {
      return;
    }

    this.manualParentByGroup = {
      ...this.manualParentByGroup,
      [this.parentPickerGroupId]: this.selectedParentCandidate
    };

    if (this.detailSourceGroup) {
      this.detailGroup = this.mapDetailGroup(this.detailSourceGroup);
    }

    this.clearMergeReviewForGroup(this.parentPickerGroupId);
    this.notify('Survivor selected', 'Survivor record selected for this group.', 'success');
    this.handleParentPickerCancel();
  }

  async handleReviewMerge() {
    if (!this.detailGroup) {
      return;
    }

    const groupId = String(this.detailGroup.groupId);
    if (this.mergeReview && this.mergeReview.groupId === groupId) {
      this.mergeReviewVisible = true;
      return;
    }

    const recordIds = this.getMergeCandidateIds(this.detailGroup);
    if (recordIds.length < 2) {
      this.notify('Select records', 'Choose at least two records before starting the merge review.', 'warning');
      return;
    }

    this.mergeReviewVisible = true;
    this.mergeLoading = true;
    try {
      const proposal = await getMergeProposal({
        objectApiName: this.detailGroup.objectApiName,
        recordIds,
        preferredSurvivorId: this.getEffectiveParentId(this.detailGroup)
      });

      this.manualParentByGroup = {
        ...this.manualParentByGroup,
        [groupId]: proposal.survivorRecordId
      };
      if (this.detailSourceGroup) {
        this.detailGroup = this.mapDetailGroup(this.detailSourceGroup);
      }
      this.mergeReview = this.mapMergeReview(proposal, groupId, this.detailGroup.groupKey);
    } catch (error) {
      this.mergeReviewVisible = false;
      this.notifyError('Failed to build merge review', error);
    } finally {
      this.mergeLoading = false;
    }
  }

  handleSelectSurvivorFromReview() {
    this.handleSelectParentClick();
  }

  handleMergeSelectionChange(event) {
    if (!this.mergeReview) {
      return;
    }

    const { fieldApiName, sourceRecordId } = event.detail;
    const updateRows = (rows) =>
      rows.map((row) => {
        if (row.fieldApiName !== fieldApiName) {
          return row;
        }

        const selectedCandidate = row.values.find((value) => value.recordId === sourceRecordId);
        return {
          ...row,
          selectedSourceRecordId: sourceRecordId,
          selectedValue: selectedCandidate ? selectedCandidate.value : '',
          selectedDisplayValue: selectedCandidate ? selectedCandidate.displayValue : ''
        };
      });

    const highRiskFields = updateRows(this.mergeReview.highRiskFields);
    const lowRiskFields = updateRows(this.mergeReview.lowRiskFields);
    this.mergeReview = {
      ...this.mergeReview,
      highRiskFields,
      lowRiskFields,
      previewFields: this.buildPreviewFields(highRiskFields, lowRiskFields)
    };
  }

  handleMergeReviewClose() {
    this.mergeReviewVisible = false;
  }

  async handleExecuteMerge() {
    if (!this.mergeReview) {
      return;
    }

    this.mergeExecuting = true;
    try {
      const survivorRecordId = this.getExecutableSurvivorId();
      if (!survivorRecordId) {
        this.notify('Select survivor', 'Choose a survivor record before executing the merge.', 'warning');
        return;
      }

      const fieldSelections = [...this.mergeReview.highRiskFields, ...this.mergeReview.lowRiskFields].map((row) => ({
        fieldApiName: row.fieldApiName,
        sourceRecordId: row.selectedSourceRecordId
      }));

      const result = await executeSoftMerge({
        objectApiName: this.detailGroup.objectApiName,
        survivorRecordId,
        loserRecordIds: this.mergeReview.recordIds.filter((recordId) => recordId !== survivorRecordId),
        fieldSelections
      });

      this.notify(
        result.success ? 'Soft merge completed' : 'Soft merge completed with errors',
        result.message,
        result.success ? 'success' : 'warning'
      );

      const updatedManual = { ...this.manualParentByGroup };
      delete updatedManual[this.mergeReview.groupId];
      this.manualParentByGroup = updatedManual;

      const updatedSelection = { ...this.selectionByGroup };
      delete updatedSelection[this.mergeReview.groupId];
      this.selectionByGroup = updatedSelection;

      this.mergeReview = null;
      this.mergeReviewVisible = false;
      this.detailGroup = null;
      this.detailSourceGroup = null;

      await this.refreshSelectedScan();
      await this.loadRecentScans();
    } catch (error) {
      this.notifyError('Soft merge failed', error);
    } finally {
      this.mergeExecuting = false;
    }
  }

  mapMergeReview(proposal, groupId, title) {
    const records = (proposal.records || []).map((record) => ({
      ...record,
      recordUrl: record.recordId ? `/${record.recordId}` : '#',
      linkLabel: this.truncateDisplayLabel(record.displayValue),
      scoreSummary: `S:${record.survivorScore} | C:${record.completenessScore} | R:${record.relatedRecordCount}`
    }));
    const highRiskFields = [];
    const lowRiskFields = [];

    (proposal.fields || []).forEach((field) => {
      const row = this.mapMergeFieldRow(field, records, proposal.survivorRecordId);
      if (field.requiresReview) {
        highRiskFields.push(row);
      } else {
        lowRiskFields.push(row);
      }
    });

    return {
      groupId,
      title: `${title} Resolution Review`,
      objectLabel: proposal.objectLabel,
      summary: proposal.summary,
      survivorRecordId: this.resolveProposalSurvivorId(proposal, records),
      survivorDisplayValue: proposal.survivorDisplayValue,
      reviewRequiredCount: proposal.reviewRequiredCount,
      lowRiskFieldCount: proposal.lowRiskFieldCount,
      relatedRecordCount: proposal.relatedRecordCount,
      warnings: proposal.warnings || [],
      records,
      highRiskFields,
      lowRiskFields,
      previewFields: this.buildPreviewFields(highRiskFields, lowRiskFields),
      relatedSummaries: (proposal.relatedSummaries || []).map((item) => ({
        ...item,
        key: `${item.childObjectApiName}-${item.fieldApiName}`
      })),
      recordIds: records.map((record) => record.recordId)
    };
  }

  mapMergeFieldRow(field, records, survivorRecordId) {
    const recommendedRecord = records.find((record) => record.recordId === field.recommendedSourceRecordId);
    const selectorOptions = records.map((record) => ({
      label: `${record.displayValue}${record.recordId === survivorRecordId ? ' (Survivor)' : ''}${
        record.recordId === field.recommendedSourceRecordId ? ' (Recommended)' : ''
      }`,
      value: record.recordId
    }));

    const values = records.map((record) => {
      const matchingCandidate = (field.candidates || []).find((candidate) => candidate.recordId === record.recordId);
      const value = this.normalizeFieldValue(matchingCandidate ? matchingCandidate.value : '');
      let cellClass = '';
      const meta = [];
      if (record.recordId === survivorRecordId) {
        cellClass = 'cell-survivor';
        meta.push('Survivor');
      }
      if (record.recordId === field.recommendedSourceRecordId) {
        cellClass = record.recordId === survivorRecordId ? 'cell-survivor cell-recommended' : 'cell-recommended';
        meta.push('Recommended');
      }
      return {
        recordId: record.recordId,
        value,
        fullValue: value,
        displayValue: this.truncateFieldValue(value),
        cellClass,
        metaLabel: meta.join(' | ')
      };
    });

    const selectedCandidate = values.find((value) => value.recordId === field.selectedSourceRecordId);
    const selectedValue = selectedCandidate ? selectedCandidate.value : '';
    return {
      fieldApiName: field.fieldApiName,
      fieldLabel: field.fieldLabel,
      recommendationReason: field.recommendationReason,
      recommendedSourceRecordId: field.recommendedSourceRecordId,
      recommendedSourceLabel: recommendedRecord ? recommendedRecord.displayValue : field.recommendedSourceRecordId,
      selectedSourceRecordId: field.selectedSourceRecordId,
      selectedValue,
      selectedDisplayValue: selectedCandidate ? selectedCandidate.displayValue : '',
      selectorOptions,
      values
    };
  }

  buildPreviewFields(highRiskFields, lowRiskFields) {
    return [...highRiskFields, ...lowRiskFields]
      .map((field) => ({
        fieldApiName: field.fieldApiName,
        fieldLabel: field.fieldLabel,
        selectedValue: field.selectedValue || '(blank)',
        selectedDisplayValue: field.selectedDisplayValue || '(blank)'
      }))
      .sort((left, right) => left.fieldLabel.localeCompare(right.fieldLabel));
  }

  getMergeCandidateIds(groupDetail) {
    const groupId = String(groupDetail.groupId);
    const selected = this.selectionByGroup[groupId] || [];
    const survivorId = this.getEffectiveParentId(groupDetail);
    const allRecordIds = (groupDetail.records || []).map((record) => record.recordId);
    const candidateIds = selected.length ? Array.from(new Set([survivorId, ...selected].filter(Boolean))) : allRecordIds;
    return candidateIds.length >= 2 ? candidateIds : allRecordIds;
  }

  clearMergeReviewForGroup(groupId) {
    if (this.mergeReview && this.mergeReview.groupId === String(groupId)) {
      this.mergeReview = null;
      this.mergeReviewVisible = false;
    }
  }

  getExecutableSurvivorId() {
    const reviewSurvivorId = this.mergeReview ? this.mergeReview.survivorRecordId : null;
    if (reviewSurvivorId) {
      return reviewSurvivorId;
    }
    return this.getEffectiveParentId(this.detailGroup);
  }

  resolveProposalSurvivorId(proposal, records) {
    if (proposal && proposal.survivorRecordId) {
      return proposal.survivorRecordId;
    }
    const flaggedSurvivor = (records || []).find((record) => record.isSurvivor);
    if (flaggedSurvivor) {
      return flaggedSurvivor.recordId;
    }
    return this.getEffectiveParentId(this.detailGroup) || ((records || [])[0] || {}).recordId || null;
  }

  startPolling() {
    if (this.pollHandle) {
      return;
    }

    this.pollHandle = window.setInterval(async () => {
      await this.refreshSelectedScan();
      await this.loadRecentScans();
    }, 5000);
  }

  stopPolling() {
    if (!this.pollHandle) {
      return;
    }

    window.clearInterval(this.pollHandle);
    this.pollHandle = null;
  }

  notify(title, message, variant) {
    this.dispatchEvent(
      new ShowToastEvent({
        title,
        message,
        variant
      })
    );
  }

  notifyError(title, error) {
    let message = 'Unknown error';
    if (error && error.body && error.body.message) {
      message = error.body.message;
    } else if (error && error.message) {
      message = error.message;
    }

    this.notify(title, message, 'error');
  }

  formatDate(raw) {
    if (!raw) {
      return '-';
    }

    try {
      return new Intl.DateTimeFormat(undefined, {
        year: 'numeric',
        month: 'short',
        day: '2-digit',
        hour: '2-digit',
        minute: '2-digit'
      }).format(new Date(raw));
    } catch (e) {
      return raw;
    }
  }

  normalizeFieldValue(value) {
    if (value === null || value === undefined || value === '') {
      return '';
    }
    return String(value);
  }

  truncateFieldValue(value) {
    const normalized = this.normalizeFieldValue(value);
    if (!normalized || normalized.length <= COMPARISON_VALUE_LIMIT) {
      return normalized;
    }
    return `${normalized.slice(0, COMPARISON_VALUE_LIMIT - 1).trimEnd()}...`;
  }

  truncateDisplayLabel(value) {
    const normalized = this.normalizeFieldValue(value);
    if (!normalized) {
      return 'Open record';
    }
    if (normalized.length <= RECORD_LINK_LABEL_LIMIT) {
      return normalized;
    }
    return `${normalized.slice(0, RECORD_LINK_LABEL_LIMIT - 1).trimEnd()}...`;
  }
}

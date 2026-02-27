import { LightningElement, track } from 'lwc';
import { ShowToastEvent } from 'lightning/platformShowToastEvent';

import getObjectOptions from '@salesforce/apex/HeuristicDuplicateScanController.getObjectOptions';
import startScan from '@salesforce/apex/HeuristicDuplicateScanController.startScan';
import getScanStatus from '@salesforce/apex/HeuristicDuplicateScanController.getScanStatus';
import getRecentScans from '@salesforce/apex/HeuristicDuplicateScanController.getRecentScans';
import getGroupsForScan from '@salesforce/apex/HeuristicDuplicateScanController.getGroupsForScan';
import getGroupDetail from '@salesforce/apex/HeuristicDuplicateScanController.getGroupDetail';
import mergeRecords from '@salesforce/apex/HeuristicDuplicateScanController.mergeRecords';
import cancelScan from '@salesforce/apex/HeuristicDuplicateScanController.cancelScan';

export default class HeuristicDuplicateAdmin extends LightningElement {
  static MERGEABLE_OBJECTS = ['Account', 'Contact', 'Lead', 'Case'];

  @track objectOptions = [];
  @track selectedObject;
  @track scanStatus;
  @track recentScans = [];
  @track groups = [];
  @track detailGroup;
  @track parentPickerOpen = false;
  @track parentOptions = [];
  @track selectedParentCandidate;

  loading = false;
  starting = false;

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
    { label: 'Parent', fieldName: 'parentBadge', type: 'text', fixedWidth: 88 },
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
    } catch (error) {
      this.notifyError('Failed to load group detail', error);
    } finally {
      this.loading = false;
    }
  }

  handleBackToSummary() {
    this.detailGroup = null;
    this.detailSourceGroup = null;
  }

  buildFieldRows(fieldNames, records) {
    const rows = [];

    fieldNames.forEach((fieldName) => {
      const values = records.map((record) => ({
        recordId: record.recordId,
        cellClass: record.isEffectiveParent ? 'is-parent' : '',
        value: record.fields?.[fieldName] || ''
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
      canMergeUi: HeuristicDuplicateAdmin.MERGEABLE_OBJECTS.includes(detail.objectApiName),
      mergeDisabled: !effectiveParentId,
      effectiveParentId,
      records,
      detailFieldRows: this.buildFieldRows(detail.fieldNames || [], records)
    };
  }

  getEffectiveParentId(groupDetail) {
    if (!groupDetail || !groupDetail.groupId) {
      return null;
    }
    return this.manualParentByGroup[String(groupDetail.groupId)] || null;
  }

  handleDetailRowSelection(event) {
    const groupId = event.target.dataset.groupId;
    const selectedIds = (event.detail.selectedRows || []).map((row) => row.recordId);
    this.selectionByGroup = {
      ...this.selectionByGroup,
      [groupId]: selectedIds
    };
  }

  handleSelectParentClick() {
    if (!this.detailGroup || !this.detailGroup.records || !this.detailGroup.records.length) {
      this.notify('No records', 'No records available in this group to select as parent.', 'info');
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

    this.notify('Parent selected', 'Parent record selected for this group.', 'success');
    this.handleParentPickerCancel();
  }

  async handleMergeClick() {
    if (!this.detailGroup) {
      return;
    }

    const groupId = String(this.detailGroup.groupId);
    const parentId = this.getEffectiveParentId(this.detailGroup);
    if (!parentId) {
      this.notify('Select parent', 'Select a parent record before merge.', 'warning');
      return;
    }

    const selected = this.selectionByGroup[groupId] || [];
    const children = selected.length
      ? selected.filter((id) => id !== parentId)
      : this.detailGroup.records.filter((record) => !record.isEffectiveParent).map((record) => record.recordId);

    if (!children.length) {
      this.notify('Nothing to merge', 'Select at least one child record.', 'info');
      return;
    }

    this.loading = true;
    try {
      const result = await mergeRecords({
        objectApiName: this.detailGroup.objectApiName,
        parentRecordId: parentId,
        childRecordIds: children
      });
      this.notify(
        result.success ? 'Merge completed' : 'Merge completed with errors',
        result.message,
        result.success ? 'success' : 'warning'
      );

      const updatedManual = { ...this.manualParentByGroup };
      delete updatedManual[groupId];
      this.manualParentByGroup = updatedManual;

      const updatedSelection = { ...this.selectionByGroup };
      delete updatedSelection[groupId];
      this.selectionByGroup = updatedSelection;

      this.detailGroup = null;
      this.detailSourceGroup = null;

      await this.refreshSelectedScan();
      await this.loadRecentScans();
    } catch (error) {
      this.notifyError('Merge failed', error);
    } finally {
      this.loading = false;
    }
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
}

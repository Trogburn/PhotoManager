using System.Collections.ObjectModel;
using System.Windows;
using System.Windows.Media;
using System.Windows.Media.Imaging;
using QnapPhotoManager.Infrastructure;
using QnapPhotoManager.Models;
using QnapPhotoManager.Services;

namespace QnapPhotoManager.ViewModels;

public enum WorkflowPage
{
    Configuration,
    DuplicateWork,
    DateWork
}

public sealed class MainViewModel : ObservableObject
{
    private readonly WorkflowStateMachine _workflow;
    private readonly AtomicArtifactStore _artifactStore;
    private readonly DateRepairService _dateRepairService;
    private readonly DuplicateWorkflowService _duplicateWorkflow;
    private readonly IConfirmationService _confirmationService;
    private string _scanRoot = @"\\TrogQNAP6HDD\PhotoWorkflowTest\WpfAcceptance\Input";
    private string _artifactRoot = "artifacts";
    private string _statusMessage = "Ready to configure a session.";
    private string? _dateReportPath;
    private DateReviewReport? _dateReport;
    private DateSnapshot? _dateSnapshot;
    private bool _duplicateSnapshotConfirmed;
    private bool _dateSnapshotConfirmed;
    private int _sampleCount = 25;
    private AppConfig? _duplicateConfig;
    private DuplicateWorkflowArtifacts? _duplicateArtifacts;
    private DuplicateReviewValidationResult? _duplicateReviewValidation;
    private bool _duplicateReviewerOpened;
    private string? _duplicateSnapshotName;
    private string? _dateSnapshotName;
    private WorkflowPage _currentPage = WorkflowPage.Configuration;
    private DateReviewRowViewModel? _selectedDateItem;
    private ImageSource? _datePreview;
    private string _dateEvidenceSummary = "Select a date proposal to inspect its evidence.";
    private bool _dateApplyCompleted;

    public MainViewModel(
        WorkflowStateMachine workflow,
        AtomicArtifactStore artifactStore,
        DateRepairService dateRepairService,
        DuplicateWorkflowService duplicateWorkflow,
        IConfirmationService confirmationService)
    {
        _workflow = workflow ?? throw new ArgumentNullException(nameof(workflow));
        _artifactStore = artifactStore ?? throw new ArgumentNullException(nameof(artifactStore));
        _dateRepairService = dateRepairService ?? throw new ArgumentNullException(nameof(dateRepairService));
        _duplicateWorkflow = duplicateWorkflow ?? throw new ArgumentNullException(nameof(duplicateWorkflow));
        _confirmationService = confirmationService ?? throw new ArgumentNullException(nameof(confirmationService));
        StartCommand = new RelayCommand(Start);
        ResetCommand = new RelayCommand(Reset);
        ScanDatesCommand = new RelayCommand(ScanDates);
        CreateDateSnapshotCommand = new RelayCommand(CreateDateSnapshot, CanCreateDateSnapshot);
        ApplyDatesCommand = new RelayCommand(ApplyDates, CanApplyDates);
        LoadUndoCommand = new RelayCommand(LoadUndo);
        UndoSelectedCommand = new RelayCommand(UndoSelected, CanUndoSelected);
        SampleDateReviewCommand = new RelayCommand(SampleDateReview);
        ConfigureDuplicatesCommand = new RelayCommand(ConfigureDuplicates, CanConfigureDuplicates);
        StartDateWorkCommand = new RelayCommand(StartDateWork, CanConfigureDuplicates);
        ScanDuplicatesCommand = new RelayCommand(ScanDuplicates, CanScanDuplicates);
        OpenDuplicateReviewerCommand = new RelayCommand(OpenDuplicateReviewer, CanOpenDuplicateReviewer);
        ValidateDuplicateReviewCommand = new RelayCommand(ValidateDuplicateReview, CanValidateDuplicateReview);
        DuplicateDryRunCommand = new RelayCommand(DuplicateDryRun, CanDuplicateDryRun);
        CopyDuplicateSnapshotNameCommand = new RelayCommand(CopyDuplicateSnapshotName);
        DuplicateApplyCommand = new RelayCommand(DuplicateApply, CanDuplicateApply);
        DuplicateVerifyCommand = new RelayCommand(DuplicateVerify, CanDuplicateVerify);
        LoadDuplicateUndoCommand = new RelayCommand(LoadDuplicateUndo);
        UndoSelectedDuplicatesCommand = new RelayCommand(UndoSelectedDuplicates, CanUndoSelectedDuplicates);
        RefreshSessionProperties();
    }

    public string ScanRoot
    {
        get => _scanRoot;
        set => SetProperty(ref _scanRoot, value);
    }

    public string ArtifactRoot
    {
        get => _artifactRoot;
        set => SetProperty(ref _artifactRoot, value);
    }

    public string WorkflowState => _workflow.Session.State.ToString();

    public string SessionId => _workflow.Session.Id.ToString("N");

    public bool IsConfigurationEditable =>
        _workflow.Session.State == QnapPhotoManager.Models.WorkflowState.Idle;

    public WorkflowPage CurrentPage => _currentPage;

    public Visibility ConfigurationPageVisibility =>
        _currentPage == WorkflowPage.Configuration ? Visibility.Visible : Visibility.Collapsed;

    public Visibility DuplicateWorkPageVisibility =>
        _currentPage == WorkflowPage.DuplicateWork ? Visibility.Visible : Visibility.Collapsed;

    public Visibility DateWorkPageVisibility =>
        _currentPage == WorkflowPage.DateWork ? Visibility.Visible : Visibility.Collapsed;

    public string StatusMessage
    {
        get => _statusMessage;
        private set => SetProperty(ref _statusMessage, value);
    }

    public RelayCommand StartCommand { get; }
    public RelayCommand ResetCommand { get; }
    public RelayCommand ScanDatesCommand { get; }
    public RelayCommand CreateDateSnapshotCommand { get; }
    public RelayCommand ApplyDatesCommand { get; }
    public RelayCommand LoadUndoCommand { get; }
    public RelayCommand UndoSelectedCommand { get; }
    public RelayCommand SampleDateReviewCommand { get; }
    public RelayCommand ConfigureDuplicatesCommand { get; }
    public RelayCommand StartDateWorkCommand { get; }
    public RelayCommand ScanDuplicatesCommand { get; }
    public RelayCommand OpenDuplicateReviewerCommand { get; }
    public RelayCommand ValidateDuplicateReviewCommand { get; }
    public RelayCommand DuplicateDryRunCommand { get; }
    public RelayCommand CopyDuplicateSnapshotNameCommand { get; }
    public RelayCommand DuplicateApplyCommand { get; }
    public RelayCommand DuplicateVerifyCommand { get; }
    public RelayCommand LoadDuplicateUndoCommand { get; }
    public RelayCommand UndoSelectedDuplicatesCommand { get; }

    public ObservableCollection<DateReviewRowViewModel> DateItems { get; } = [];
    public ObservableCollection<DateUndoRowViewModel> UndoItems { get; } = [];
    public ObservableCollection<DuplicateUndoRowViewModel> DuplicateUndoItems { get; } = [];
    public IReadOnlyList<string> DateDecisionOptions { get; } = ["Undecided", "Approve", "Skip"];

    public int SampleCount
    {
        get => _sampleCount;
        set => SetProperty(ref _sampleCount, Math.Clamp(value, 1, 1000));
    }

    public string DateReportPath => _dateReportPath ?? "No date evidence report loaded.";
    public string DateTimezonePolicy => _dateReport?.TimezonePolicy ?? string.Empty;

    public DateReviewRowViewModel? SelectedDateItem
    {
        get => _selectedDateItem;
        set
        {
            if (SetProperty(ref _selectedDateItem, value))
            {
                UpdateDateEvidencePreview();
            }
        }
    }

    public ImageSource? DatePreview => _datePreview;

    public string DateEvidenceSummary => _dateEvidenceSummary;

    public bool DuplicateSnapshotConfirmed
    {
        get => _duplicateSnapshotConfirmed;
        set
        {
            if (SetProperty(ref _duplicateSnapshotConfirmed, value))
            {
                _workflow.SetSnapshotConfirmed(value);
                if (_workflow.Session.State == QnapPhotoManager.Models.WorkflowState.RemediationReady)
                {
                    _duplicateWorkflow.ConfirmSnapshot(_workflow, value);
                }

                DuplicateApplyCommand.RaiseCanExecuteChanged();
            }
        }
    }

    public bool CanConfirmDuplicateSnapshot =>
        _duplicateArtifacts?.FreezePath is not null
        && _workflow.Session.State == QnapPhotoManager.Models.WorkflowState.RemediationReady;

    public bool CanConfirmDateSnapshot =>
        _dateSnapshot is not null
        && !_dateApplyCompleted
        && DateReviewDecisionPolicy.CanCreateSnapshot(DateItems);

    public bool DateSnapshotConfirmed
    {
        get => _dateSnapshotConfirmed;
        set
        {
            if (SetProperty(ref _dateSnapshotConfirmed, value))
            {
                ApplyDatesCommand.RaiseCanExecuteChanged();
            }
        }
    }

    public string DateSummary =>
        _dateReport is null
            ? "Run a read-only evidence scan to begin."
            : $"{DateItems.Count(item => item.Status == "Proposed")} proposed; " +
              $"{DateItems.Count(item => item.Status != "Proposed")} require review or have no evidence.";

    public string QuarantineRoot { get; set; } = @"\\TrogQNAP6HDD\PhotoWorkflowTest\WpfAcceptance\Quarantine";
    public string DuplicateArtifactSummary => _duplicateArtifacts is null
        ? "No duplicate workflow artifacts."
        : $"Artifacts ready: {Path.GetFileName(_duplicateArtifacts.ScanDirectory)} · " +
          $"Dry-run plan: {Path.GetFileName(_duplicateArtifacts.DryRunPath)}";

    public bool DuplicateReviewValidated => _duplicateReviewValidation?.IsValid == true;

    public string DuplicateReviewValidationSummary => _duplicateReviewValidation is null
        ? "Review has not been validated."
        : $"{_duplicateReviewValidation.ResolvedGroupCount} of {_duplicateReviewValidation.TotalGroupCount} groups resolved.";

    public string DuplicateSnapshotName =>
        _duplicateSnapshotName ?? "Run a duplicate dry-run to generate a snapshot name.";

    public string DateSnapshotName =>
        _dateSnapshotName ?? "Scan date evidence to generate a snapshot name.";

    private async void Start()
    {
        try
        {
            PathPolicy.ValidateScanRoot(ScanRoot);
            var session = _workflow.Session;
            if (session.State == QnapPhotoManager.Models.WorkflowState.Idle)
            {
                session = _workflow.TransitionTo(QnapPhotoManager.Models.WorkflowState.Configured, "Configuration accepted.");
            }

            var config = new AppConfig
            {
                ScanRoot = ScanRoot,
                ArtifactRoot = ArtifactRoot
            };
            var relativeName = Path.Combine(
                "sessions",
                $"{session.Id:N}",
                "config.json");
            await _artifactStore.WriteAsync(
                ArtifactRoot,
                relativeName,
                "session-config",
                config);

            StatusMessage = "Session configured. A scan adapter can now transition the workflow to Scanning.";
            RefreshSessionProperties();
        }
        catch (Exception exception) when (exception is ArgumentException or IOException or UnauthorizedAccessException)
        {
            StatusMessage = exception.Message;
        }
    }

    private async void ConfigureDuplicates()
    {
        try
        {
            _duplicateConfig = await _duplicateWorkflow.ConfigureAsync(
                _workflow, ScanRoot, QuarantineRoot, ArtifactRoot);
            SetPage(WorkflowPage.DuplicateWork);
            StatusMessage = "Duplicate workflow configured; scan remains read-only.";
            RefreshSessionProperties();
            RaiseDateCommandStates();
        }
        catch (Exception exception) { StatusMessage = exception.Message; }
    }

    private async void StartDateWork()
    {
        try
        {
            PathPolicy.ValidateScanRoot(ScanRoot);
            if (_workflow.Session.State == QnapPhotoManager.Models.WorkflowState.Idle)
            {
                _workflow.TransitionTo(QnapPhotoManager.Models.WorkflowState.Configured, "Date-only configuration accepted.");
            }

            var config = new AppConfig { ScanRoot = ScanRoot, ArtifactRoot = ArtifactRoot };
            await _artifactStore.WriteAsync(
                ArtifactRoot,
                Path.Combine("sessions", $"{_workflow.Session.Id:N}", "date-config.json"),
                "date-session-config",
                config);
            SetPage(WorkflowPage.DateWork);
            StatusMessage = "Date workflow configured. Scan is read-only.";
            RefreshSessionProperties();
            RaiseDateCommandStates();
        }
        catch (Exception exception) when (exception is ArgumentException or IOException or UnauthorizedAccessException)
        {
            StatusMessage = exception.Message;
        }
    }

    private async void ScanDuplicates()
    {
        try
        {
            InvalidateDuplicateReview();
            _duplicateConfig ??= await _duplicateWorkflow.ConfigureAsync(
                _workflow, ScanRoot, QuarantineRoot, ArtifactRoot);
            _duplicateArtifacts = await _duplicateWorkflow.PrepareAsync(
                _workflow, _duplicateConfig, fresh: false);
            StatusMessage = "Duplicate scan, classification, and review archive completed.";
            RefreshSessionProperties();
            RaiseDateCommandStates();
        }
        catch (Exception exception) { StatusMessage = exception.Message; }
    }

    private async void ValidateDuplicateReview()
    {
        try
        {
            if (_duplicateArtifacts is null)
                throw new InvalidOperationException("Run the duplicate scan before validating the review.");

            _duplicateReviewValidation = await _duplicateWorkflow.ValidateReviewAsync(_duplicateArtifacts);
            StatusMessage = _duplicateReviewValidation.TotalGroupCount == 0
                ? "No duplicate groups were found; no remediation is needed."
                : _duplicateReviewValidation.IsValid
                ? $"Duplicate review validated: {_duplicateReviewValidation.ResolvedGroupCount} of {_duplicateReviewValidation.TotalGroupCount} groups resolved."
                : $"Duplicate review incomplete: {_duplicateReviewValidation.ResolvedGroupCount} of {_duplicateReviewValidation.TotalGroupCount} groups resolved. " +
                  $"Unresolved: {string.Join(", ", _duplicateReviewValidation.UnresolvedGroupIds)}.";
            OnPropertyChanged(nameof(DuplicateReviewValidated));
            OnPropertyChanged(nameof(DuplicateReviewValidationSummary));
            RaiseDateCommandStates();
        }
        catch (Exception exception)
        {
            InvalidateDuplicateReview();
            StatusMessage = exception.Message;
        }
    }

    private async void DuplicateDryRun()
    {
        try
        {
            if (_duplicateConfig is null || _duplicateArtifacts is null)
                throw new InvalidOperationException("Configure and scan duplicates before dry-run.");
            _duplicateArtifacts = await _duplicateWorkflow.RunDryRunAsync(
                _workflow, _duplicateConfig, _duplicateArtifacts);
            _duplicateSnapshotName = CreateSnapshotName("duplicate");
            StatusMessage = "Dry-run completed and artifacts frozen. Confirm the snapshot before Apply.";
            RefreshSessionProperties();
            RaiseDateCommandStates();
        }
        catch (Exception exception) { StatusMessage = exception.Message; }
    }

    private void LoadDuplicateUndo()
    {
        _ = LoadDuplicateUndoAsync();
    }

    private async Task LoadDuplicateUndoAsync()
    {
        try
        {
            if (_duplicateConfig is null)
            {
                throw new InvalidOperationException("Configure duplicates before loading undo history.");
            }

            var entries = await _duplicateWorkflow.ReadActiveTransactionsAsync(_duplicateConfig);
            DuplicateUndoItems.Clear();
            foreach (var entry in entries)
            {
                DuplicateUndoItems.Add(new DuplicateUndoRowViewModel(entry, RaiseDateCommandStates));
            }

            StatusMessage = entries.Count == 0
                ? "No active duplicate quarantine transactions were found."
                : $"Loaded {entries.Count} active duplicate transaction(s). Select source path(s) to undo.";
            RaiseDateCommandStates();
        }
        catch (Exception exception) { StatusMessage = exception.Message; }
    }

    private async void UndoSelectedDuplicates()
    {
        try
        {
            if (_duplicateConfig is null || _duplicateArtifacts is null)
            {
                throw new InvalidOperationException("Configure duplicates and scan before selective undo.");
            }

            var selected = DuplicateUndoItems
                .Where(item => item.IsSelected)
                .Select(item => item.Source)
                .ToArray();
            if (selected.Length == 0)
            {
                throw new InvalidOperationException("Select at least one duplicate transaction to undo.");
            }

            if (!_confirmationService.Confirm(
                    $"Restore {selected.Length} selected duplicate file(s) to their source paths?",
                    "Confirm selective duplicate undo"))
            {
                StatusMessage = "Selective duplicate undo cancelled.";
                return;
            }

            var output = await _duplicateWorkflow.UndoSelectedAsync(
                _duplicateConfig, _duplicateArtifacts, selected);
            await LoadDuplicateUndoAsync();
            StatusMessage = $"Selective duplicate undo completed for {selected.Length} file(s). {output.Trim()}";
        }
        catch (Exception exception) { StatusMessage = exception.Message; }
    }

    private void OpenDuplicateReviewer()
    {
        try
        {
            if (_duplicateArtifacts is null)
            {
                throw new InvalidOperationException("Run the duplicate scan before opening the reviewer.");
            }

            InvalidateDuplicateReview();
            _duplicateWorkflow.OpenReviewer(_duplicateArtifacts);
            _duplicateReviewerOpened = true;
            StatusMessage = "Duplicate reviewer opened. Save all decisions there before running the dry-run.";
            ValidateDuplicateReviewCommand.RaiseCanExecuteChanged();
        }
        catch (Exception exception) { StatusMessage = exception.Message; }
    }

    private void CopyDuplicateSnapshotName()
    {
        if (_duplicateSnapshotName is null)
        {
            StatusMessage = "Run a duplicate dry-run before copying a snapshot name.";
            return;
        }

        Clipboard.SetText(_duplicateSnapshotName);
        StatusMessage = "Suggested QNAP snapshot name copied to the clipboard.";
    }

    private async void DuplicateApply()
    {
        try
        {
            if (!DuplicateSnapshotConfirmed)
                throw new InvalidOperationException("Check the explicit snapshot confirmation before Apply.");
            if (_duplicateConfig is null || _duplicateArtifacts is null)
                throw new InvalidOperationException("Run a duplicate dry-run before Apply.");
            if (!_confirmationService.Confirm(
                    "Apply will quarantine only explicitly reviewed files from the frozen snapshot. Continue?",
                    "Confirm duplicate apply"))
            {
                StatusMessage = "Apply cancelled.";
                return;
            }
            var log = await _duplicateWorkflow.ApplyAsync(
                _workflow, _duplicateConfig, _duplicateArtifacts, DuplicateSnapshotConfirmed);
            _duplicateArtifacts = _workflow.Session.DuplicateArtifacts ?? _duplicateArtifacts;
            StatusMessage = $"Duplicate apply completed. Log: {log}";
            RefreshSessionProperties();
            RaiseDateCommandStates();
        }
        catch (Exception exception) { StatusMessage = exception.Message; }
    }

    private async void DuplicateVerify()
    {
        try
        {
            if (_duplicateConfig is null || _duplicateArtifacts is null)
                throw new InvalidOperationException("Run duplicate Apply before verification.");
            var report = await _duplicateWorkflow.VerifyAsync(
                _workflow, _duplicateConfig, _duplicateArtifacts);
            SetPage(WorkflowPage.DateWork);
            StatusMessage = $"Duplicate verification passed. Report: {report}";
            RefreshSessionProperties();
        }
        catch (Exception exception) { StatusMessage = exception.Message; }
    }

    private void Reset()
    {
        _workflow.Reset();
        DateItems.Clear();
        UndoItems.Clear();
        _dateReport = null;
        _dateSnapshot = null;
        _dateReportPath = null;
        _duplicateConfig = null;
        _duplicateArtifacts = null;
        InvalidateDuplicateReview();
        _duplicateSnapshotName = null;
        _dateSnapshotName = null;
        DuplicateUndoItems.Clear();
        DuplicateSnapshotConfirmed = false;
        DateSnapshotConfirmed = false;
        _dateApplyCompleted = false;
        SelectedDateItem = null;
        SetPage(WorkflowPage.Configuration);
        StatusMessage = "Ready to configure a session.";
        RefreshSessionProperties();
        RaiseDateCommandStates();
        OnPropertyChanged(nameof(DateReportPath));
        OnPropertyChanged(nameof(DateSummary));
        OnPropertyChanged(nameof(CanConfirmDateSnapshot));
    }

    private async void ScanDates()
    {
        try
        {
            PathPolicy.ValidateScanRoot(ScanRoot);
            var result = await _dateRepairService.ScanAsync(ScanRoot, ArtifactRoot);
            _dateReportPath = result.ReportPath;
            _dateReport = result.Report;
            _dateSnapshot = null;
            _dateSnapshotName = CreateSnapshotName("dates");
            _dateApplyCompleted = false;
            DateSnapshotConfirmed = false;
            PopulateDateItems(result.Report.Items);

            if (_workflow.Session.State is global::QnapPhotoManager.Models.WorkflowState.Configured
                or global::QnapPhotoManager.Models.WorkflowState.ScanReady
                or global::QnapPhotoManager.Models.WorkflowState.Reviewing
                or global::QnapPhotoManager.Models.WorkflowState.DateReviewReady)
            {
                if (_workflow.Session.State == global::QnapPhotoManager.Models.WorkflowState.Configured)
                {
                    _workflow.TransitionTo(global::QnapPhotoManager.Models.WorkflowState.Scanning, "Date evidence scan started.");
                    _workflow.TransitionTo(global::QnapPhotoManager.Models.WorkflowState.ScanReady, "Date evidence scan completed.");
                }
                if (_workflow.Session.State == global::QnapPhotoManager.Models.WorkflowState.ScanReady)
                {
                    _workflow.TransitionTo(global::QnapPhotoManager.Models.WorkflowState.DateReviewReady, "Date evidence is ready for review.");
                }
                RefreshSessionProperties();
            }

            StatusMessage = "Read-only date evidence scan completed. No media was changed.";
            OnPropertyChanged(nameof(DateReportPath));
            OnPropertyChanged(nameof(DateSummary));
            OnPropertyChanged(nameof(DateSnapshotName));
            RaiseDateCommandStates();
        }
        catch (Exception exception) when (exception is ArgumentException
            or IOException or UnauthorizedAccessException or InvalidOperationException)
        {
            StatusMessage = exception.Message;
        }
    }

    private async void CreateDateSnapshot()
    {
        try
        {
            if (_dateReport is null || _dateReportPath is null)
            {
                throw new InvalidOperationException("Run a date evidence scan first.");
            }
            if (DateItems.Where(item => item.IsProposed).Any(item => !item.HasDecision))
            {
                throw new InvalidOperationException("Decide Approve or Skip for every proposed date before creating a snapshot.");
            }

            _dateSnapshot = await _dateRepairService.CreateSnapshotAsync(
                _dateReportPath, CreateApprovedDateReport(), ArtifactRoot);
            _dateSnapshotName ??= CreateSnapshotName("dates");
            _dateApplyCompleted = false;
            DateSnapshotConfirmed = false;
            StatusMessage = $"Snapshot created for {_dateSnapshot.Items.Count} proposed file(s). Check the confirmation box before apply.";
            OnPropertyChanged(nameof(DateSnapshotName));
            OnPropertyChanged(nameof(CanConfirmDateSnapshot));
            RaiseDateCommandStates();
        }
        catch (Exception exception) when (exception is IOException or InvalidOperationException)
        {
            DateSnapshotConfirmed = false;
            StatusMessage = exception.Message;
        }
    }

    private void SampleDateReview()
    {
        if (_dateReport is null)
        {
            StatusMessage = "Run a date evidence scan first.";
            return;
        }

        PopulateDateItems(_dateReport.Items);
        StatusMessage = $"Showing all {_dateReport.Items.Count} date-evidence item(s).";
        OnPropertyChanged(nameof(DateSummary));
        RaiseDateCommandStates();
    }

    private async void ApplyDates()
    {
        try
        {
            if (_dateReport is null || _dateReportPath is null || _dateSnapshot is null)
            {
                throw new InvalidOperationException("Create and confirm a snapshot before applying dates.");
            }
            if (DateItems.Where(item => item.IsProposed).Any(item => !item.HasDecision))
            {
                throw new InvalidOperationException("Decide Approve or Skip for every proposed date before applying.");
            }

            var decisions = DateItems.Select(item => item.ToDecision()).ToArray();
            var result = await _dateRepairService.ApplyAsync(
                _dateReportPath, _dateReport, _dateSnapshot, decisions, ArtifactRoot);
            StatusMessage = $"Applied {result.AppliedCount} date change(s); verification passed.";
            _dateApplyCompleted = true;
            OnPropertyChanged(nameof(CanConfirmDateSnapshot));
            RaiseDateCommandStates();
            LoadUndo();
        }
        catch (Exception exception) when (exception is IOException or InvalidOperationException)
        {
            StatusMessage = exception.Message;
        }
    }

    private void LoadUndo()
    {
        _ = LoadUndoAsync();
    }

    private async Task LoadUndoAsync()
    {
        try
        {
            var manifestPath = _dateRepairService.GetUndoManifestPath(ArtifactRoot);
            var entries = await _dateRepairService.ReadUndoEntriesAsync(manifestPath);
            UndoItems.Clear();
            foreach (var entry in entries.Reverse())
            {
                UndoItems.Add(new DateUndoRowViewModel(entry));
            }
            RaiseDateCommandStates();
        }
        catch (Exception exception) when (exception is IOException or UnauthorizedAccessException)
        {
            StatusMessage = exception.Message;
        }
    }

    private async void UndoSelected()
    {
        try
        {
            var manifestPath = _dateRepairService.GetUndoManifestPath(ArtifactRoot);
            var selected = UndoItems.Where(item => item.IsSelected)
                .Select(item => item.Path)
                .ToArray();
            await _dateRepairService.UndoAsync(manifestPath, selected, ArtifactRoot);
            StatusMessage = $"Undid {selected.Length} selected date change(s).";
            LoadUndo();
        }
        catch (Exception exception) when (exception is IOException or InvalidOperationException)
        {
            StatusMessage = exception.Message;
        }
    }

    private bool CanCreateDateSnapshot() =>
        _dateReport is not null && DateReviewDecisionPolicy.CanCreateSnapshot(DateItems);

    private bool CanApplyDates() =>
        !_dateApplyCompleted
        && DateReviewDecisionPolicy.CanApply(DateSnapshotConfirmed, _dateSnapshot, DateItems);

    private bool CanConfigureDuplicates() =>
        _workflow.Session.State == QnapPhotoManager.Models.WorkflowState.Idle;

    private bool CanScanDuplicates() =>
        _workflow.Session.State == QnapPhotoManager.Models.WorkflowState.Configured;

    private bool CanDuplicateDryRun() =>
        _duplicateArtifacts is not null
        && DuplicateReviewValidated
        && _duplicateReviewValidation?.TotalGroupCount > 0
        && _workflow.Session.State == QnapPhotoManager.Models.WorkflowState.Reviewing;

    private bool CanValidateDuplicateReview() =>
        _duplicateArtifacts is not null
        && _duplicateReviewerOpened
        && !DuplicateReviewValidated
        && _workflow.Session.State == QnapPhotoManager.Models.WorkflowState.Reviewing;

    private bool CanDuplicateApply() =>
        DuplicateSnapshotConfirmed
        && _duplicateArtifacts?.FreezePath is not null
        && _workflow.Session.State == QnapPhotoManager.Models.WorkflowState.RemediationReady;

    private bool CanOpenDuplicateReviewer() =>
        _duplicateArtifacts is not null
        && !DuplicateReviewValidated
        && _workflow.Session.State == QnapPhotoManager.Models.WorkflowState.Reviewing;

    private bool CanDuplicateVerify() =>
        _duplicateArtifacts?.ApplyLogPath is not null
        && File.Exists(_duplicateArtifacts.ApplyLogPath)
        && _workflow.Session.State == QnapPhotoManager.Models.WorkflowState.RemediationApplied;

    private bool CanUndoSelected() => UndoItems.Any(item => item.IsSelected);

    private bool CanUndoSelectedDuplicates() =>
        _duplicateConfig is not null
        && _duplicateArtifacts is not null
        && DuplicateUndoItems.Any(item => item.IsSelected);

    private void RaiseDateCommandStates()
    {
        CreateDateSnapshotCommand.RaiseCanExecuteChanged();
        ApplyDatesCommand.RaiseCanExecuteChanged();
        UndoSelectedCommand.RaiseCanExecuteChanged();
        DuplicateApplyCommand.RaiseCanExecuteChanged();
        DuplicateVerifyCommand.RaiseCanExecuteChanged();
        UndoSelectedDuplicatesCommand.RaiseCanExecuteChanged();
        OpenDuplicateReviewerCommand.RaiseCanExecuteChanged();
        ValidateDuplicateReviewCommand.RaiseCanExecuteChanged();
        ConfigureDuplicatesCommand.RaiseCanExecuteChanged();
        StartDateWorkCommand.RaiseCanExecuteChanged();
        ScanDuplicatesCommand.RaiseCanExecuteChanged();
        DuplicateDryRunCommand.RaiseCanExecuteChanged();
    }

    private void InvalidateDuplicateReview()
    {
        _duplicateReviewValidation = null;
        _duplicateReviewerOpened = false;
        OnPropertyChanged(nameof(DuplicateReviewValidated));
        OnPropertyChanged(nameof(DuplicateReviewValidationSummary));
        DuplicateDryRunCommand?.RaiseCanExecuteChanged();
        ValidateDuplicateReviewCommand?.RaiseCanExecuteChanged();
    }

    internal void LoadDateReviewForTests(DateReviewReport report, string reportPath = "review.json")
    {
        _dateReport = report;
        _dateReportPath = reportPath;
        _dateSnapshot = null;
        _dateApplyCompleted = false;
        DateSnapshotConfirmed = false;
        PopulateDateItems(report.Items);
        OnPropertyChanged(nameof(DateSummary));
        OnPropertyChanged(nameof(DateTimezonePolicy));
        RaiseDateCommandStates();
    }

    internal void MarkDateSnapshotForTests(DateSnapshot snapshot)
    {
        _dateSnapshot = snapshot;
        OnPropertyChanged(nameof(CanConfirmDateSnapshot));
        RaiseDateCommandStates();
    }

    private void PopulateDateItems(IEnumerable<DateReviewItem> items)
    {
        DateItems.Clear();
        foreach (var item in items)
        {
            DateItems.Add(new DateReviewRowViewModel(item, RaiseDateCommandStates));
        }
        SelectedDateItem = DateItems.FirstOrDefault();
    }

    private DateReviewReport CreateApprovedDateReport()
    {
        if (_dateReport is null)
        {
            throw new InvalidOperationException("Run a date evidence scan first.");
        }

        return new DateReviewReport
        {
            SchemaVersion = _dateReport.SchemaVersion,
            GeneratedAtUtc = _dateReport.GeneratedAtUtc,
            DryRun = _dateReport.DryRun,
            Policy = _dateReport.Policy,
            TimezonePolicy = _dateReport.TimezonePolicy,
            FutureToleranceUtc = _dateReport.FutureToleranceUtc,
            Items = DateItems.Where(item => item.IsApproved).Select(item => item.Item).ToList()
        };
    }

    private void UpdateDateEvidencePreview()
    {
        _datePreview = null;
        if (_selectedDateItem is null)
        {
            _dateEvidenceSummary = "Select a date proposal to inspect its evidence.";
        }
        else
        {
            _dateEvidenceSummary =
                $"Source: {_selectedDateItem.Source}; raw value: {_selectedDateItem.RawValue}; " +
                $"timezone: {_selectedDateItem.TimezoneDescription}. {_selectedDateItem.Reason}";
            try
            {
                var image = new BitmapImage();
                image.BeginInit();
                image.CacheOption = BitmapCacheOption.OnLoad;
                image.UriSource = new Uri(_selectedDateItem.Path, UriKind.Absolute);
                image.EndInit();
                image.Freeze();
                _datePreview = image;
            }
            catch (Exception)
            {
                _dateEvidenceSummary += " Preview unavailable for this file.";
            }
        }

        OnPropertyChanged(nameof(DatePreview));
        OnPropertyChanged(nameof(DateEvidenceSummary));
    }

    private void RefreshSessionProperties()
    {
        OnPropertyChanged(nameof(WorkflowState));
        OnPropertyChanged(nameof(SessionId));
        OnPropertyChanged(nameof(IsConfigurationEditable));
        OnPropertyChanged(nameof(CanConfirmDuplicateSnapshot));
        OnPropertyChanged(nameof(DuplicateArtifactSummary));
        OnPropertyChanged(nameof(DuplicateReviewValidated));
        OnPropertyChanged(nameof(DuplicateReviewValidationSummary));
        OnPropertyChanged(nameof(DuplicateSnapshotName));
        OnPropertyChanged(nameof(DateSnapshotName));
        OnPropertyChanged(nameof(DateTimezonePolicy));
        OnPropertyChanged(nameof(CanConfirmDateSnapshot));
    }

    private void SetPage(WorkflowPage page)
    {
        if (_currentPage == page)
        {
            return;
        }

        _currentPage = page;
        OnPropertyChanged(nameof(CurrentPage));
        OnPropertyChanged(nameof(ConfigurationPageVisibility));
        OnPropertyChanged(nameof(DuplicateWorkPageVisibility));
        OnPropertyChanged(nameof(DateWorkPageVisibility));
    }

    private string CreateSnapshotName(string operation) =>
        $"QPM-{(operation == "duplicate" ? "DUP" : "DT")}-{SessionId[..8]}-{DateTimeOffset.UtcNow:yyMMdd-HHmmss}";
}

public sealed class DateReviewRowViewModel(DateReviewItem item, Action decisionChanged) : ObservableObject
{
    private string _decision = item.Status.Equals("Proposed", StringComparison.OrdinalIgnoreCase)
        ? "Undecided"
        : "Skip";

    public DateReviewItem Item => item;
    public string Path => item.Path;
    public string FileName => System.IO.Path.GetFileName(item.Path);
    public string Status => item.Status;
    public string Confidence => item.Confidence;
    public string Source => item.Source ?? string.Empty;
    public string ProposedCaptureTimeUtc => item.ProposedCaptureTimeUtc ?? string.Empty;
    public string ProposedLocalTime =>
        DateTimeOffset.TryParse(item.ProposedCaptureTimeUtc, out var proposed)
            ? proposed.ToLocalTime().ToString("g")
            : string.Empty;
    public string CurrentCreationTimeUtc => item.CurrentCreationTimeUtc;
    public string CurrentLastWriteTimeUtc => item.CurrentLastWriteTimeUtc;
    public string SizeDescription => item.Size == 0 ? "(unknown)" : $"{item.Size:N0} bytes";
    public string RawValue => item.RawValue ?? "(none)";
    public string ParsedFilenameToken => item.ParsedFilenameToken ?? "(none)";
    public string TimezoneDescription => string.IsNullOrWhiteSpace(item.TimezoneOffset)
        ? item.TimezoneKind ?? "unspecified"
        : $"{item.TimezoneKind} ({item.TimezoneOffset})";
    public string Policy => item.Policy;
    public string Reason => item.Reason;
    public bool IsProposed => item.Status.Equals("Proposed", StringComparison.OrdinalIgnoreCase);
    public bool HasDecision => !string.Equals(Decision, "Undecided", StringComparison.OrdinalIgnoreCase);
    public bool IsApproved => string.Equals(Decision, "Approve", StringComparison.OrdinalIgnoreCase);
    public string Decision
    {
        get => _decision;
        set
        {
            if (SetProperty(ref _decision, value))
            {
                OnPropertyChanged(nameof(IsApproved));
                OnPropertyChanged(nameof(HasDecision));
                decisionChanged();
            }
        }
    }

    public DateDecision ToDecision()
    {
        if (!HasDecision)
        {
            throw new InvalidOperationException($"A date decision is still required for {Path}.");
        }

        return new DateDecision(Path, IsApproved ? "approve" : "skip");
    }
}

public sealed class DateUndoRowViewModel(DateUndoEntry entry) : ObservableObject
{
    private bool _isSelected;

    public string Path => entry.Path;
    public string AppliedAt => entry.AfterCreationTimeUtc.ToLocalTime().ToString("g");
    public bool IsSelected
    {
        get => _isSelected;
        set => SetProperty(ref _isSelected, value);
    }
}

public sealed class DuplicateUndoRowViewModel(
    DuplicateTransactionEntry entry,
    Action selectionChanged) : ObservableObject
{
    private bool _isSelected;

    public string Source => entry.Source;
    public string Destination => entry.Destination;
    public string MovedAt => entry.TransactionUtc.ToLocalTime().ToString("g");
    public string Status => entry.Status;

    public bool IsSelected
    {
        get => _isSelected;
        set
        {
            if (SetProperty(ref _isSelected, value))
            {
                selectionChanged();
            }
        }
    }
}

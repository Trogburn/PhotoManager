using QnapPhotoManager.Infrastructure;
using QnapPhotoManager.Models;
using QnapPhotoManager.Services;

namespace QnapPhotoManager.ViewModels;

public sealed class DateReviewRowViewModel : ObservableObject
{
    private readonly Action<DateReviewRowViewModel> _decisionChanged;
    private readonly Func<bool> _canChangeDecision;
    private string _decision;
    private string? _chosenDate;
    private string? _chosenSourceLabel;

    public DateReviewRowViewModel(
        DateReviewItem item,
        Action<DateReviewRowViewModel> decisionChanged,
        Func<bool>? canChangeDecision = null)
    {
        Item = item;
        _decisionChanged = decisionChanged;
        _canChangeDecision = canChangeDecision ?? (() => true);
        _decision = IsReviewable ? "Undecided" : "Skip";
        ApproveCommand = new RelayCommand(() => ApplyDecision("Approve"), () => CanChangeDecision() && IsProposed);
        SkipCommand = new RelayCommand(() => ApplyDecision("Skip"), () => CanChangeDecision() && IsReviewable);
        SourceChoices = DateEvidencePresentation.ChoosableSources(item)
            .Select(choice => new DateSourceChoiceViewModel(
                choice.Label,
                choice.DateValue,
                () => ChooseSource(choice.Label, choice.DateValue),
                CanChangeDecision))
            .ToArray();
    }

    public DateReviewItem Item { get; }
    public RelayCommand ApproveCommand { get; }
    public RelayCommand SkipCommand { get; }
    public IReadOnlyList<DateSourceChoiceViewModel> SourceChoices { get; }
    public string Path => Item.Path;
    public string FileName => System.IO.Path.GetFileName(Item.Path);
    public string Status => Item.Status;
    public string Confidence => Item.Confidence;
    public string EvidenceKind => DateEvidencePresentation.EvidenceKind(Item);
    public string ClassifierLabel => $"{Confidence} · {EvidenceKind}";
    public string Source => Item.Source ?? string.Empty;
    public string ProposedCaptureTimeUtc => DateEvidencePresentation.CompactUtc(ChosenDate ?? Item.ProposedCaptureTimeUtc);
    public string ProposedLocalTime => DateEvidencePresentation.CompactLocal(ChosenDate ?? Item.ProposedCaptureTimeUtc);
    public string DecisionHeadline => DateEvidencePresentation.BuildHeadline(Item);
    public IReadOnlyList<DateEvidenceRow> EvidenceRows => DateEvidencePresentation.BuildRows(Item);
    public string ReviewHint => IsConflict
        ? "These capture dates disagree. Review the photo, then choose the date that looks right, or Skip to leave the file unchanged."
        : string.Empty;
    public string DecisionStatusLine =>
        IsReviewable
            ? string.IsNullOrWhiteSpace(ProposedLocalTime)
                ? $"{ClassifierLabel} · {DecisionLabel}"
                : $"{ClassifierLabel} · Proposed {ProposedLocalTime} · {DecisionLabel}"
            : $"{ClassifierLabel} · {DecisionLabel}";
    public string CurrentCreationTimeUtc => DateEvidencePresentation.CompactUtc(Item.CurrentCreationTimeUtc);
    public string CurrentLastWriteTimeUtc => DateEvidencePresentation.CompactUtc(Item.CurrentLastWriteTimeUtc);
    public string SizeDescription => Item.Size == 0 ? "(unknown)" : $"{Item.Size:N0} bytes";
    public string RawValue => Item.RawValue ?? "(none)";
    public string ParsedFilenameToken => Item.ParsedFilenameToken ?? "(none)";
    public string TimezoneDescription => string.IsNullOrWhiteSpace(Item.TimezoneOffset)
        ? Item.TimezoneKind ?? "unspecified"
        : $"{Item.TimezoneKind} ({Item.TimezoneOffset})";
    public string Policy => Item.Policy;
    public string Reason => Item.Reason;
    public bool IsProposed => Item.Status.Equals("Proposed", StringComparison.OrdinalIgnoreCase);
    public bool IsConflict => Item.Status.Equals("Conflict", StringComparison.OrdinalIgnoreCase);
    public bool IsReviewable => IsProposed || IsConflict;
    public bool IsAlreadyApplied => Item.Status.Equals("AlreadyApplied", StringComparison.OrdinalIgnoreCase);
    public bool HasDecision => !string.Equals(Decision, "Undecided", StringComparison.OrdinalIgnoreCase);
    public bool IsApproved => string.Equals(Decision, "Approve", StringComparison.OrdinalIgnoreCase);
    public bool IsSkipped => string.Equals(Decision, "Skip", StringComparison.OrdinalIgnoreCase);
    public string DecisionLabel => IsProposed
        ? HasDecision ? Decision : "Undecided"
        : IsConflict
            ? !HasDecision
                ? DateEvidencePresentation.StatusLabel(Item)
                : IsApproved ? $"Use {_chosenSourceLabel}" : "Skip"
            : DateEvidencePresentation.StatusLabel(Item);
    internal string? ChosenDate => _chosenDate;
    internal string? ChosenSourceLabel => _chosenSourceLabel;
    public bool CanChangeDecision() => _canChangeDecision();

    public void RaiseDecisionCommandStates()
    {
        ApproveCommand.RaiseCanExecuteChanged();
        SkipCommand.RaiseCanExecuteChanged();
        foreach (var choice in SourceChoices)
        {
            choice.ChooseCommand.RaiseCanExecuteChanged();
        }
    }

    public string Decision
    {
        get => _decision;
        set => ApplyDecision(value);
    }

    internal void RestoreDecision(string decision, string? chosenDate, string? chosenSourceLabel)
    {
        _chosenDate = chosenDate;
        _chosenSourceLabel = chosenSourceLabel;
        ApplyDecision(decision);
    }

    private void ChooseSource(string label, string dateValue)
    {
        if (!CanChangeDecision())
        {
            return;
        }

        _chosenDate = dateValue;
        _chosenSourceLabel = label;
        ApplyDecision("Approve");
    }

    private void ApplyDecision(string decision)
    {
        if (!CanChangeDecision())
        {
            return;
        }

        if (!string.Equals(decision, "Approve", StringComparison.OrdinalIgnoreCase))
        {
            _chosenDate = null;
            _chosenSourceLabel = null;
        }

        if (SetProperty(ref _decision, decision, nameof(Decision)))
        {
            OnPropertyChanged(nameof(IsApproved));
            OnPropertyChanged(nameof(IsSkipped));
            OnPropertyChanged(nameof(HasDecision));
            OnPropertyChanged(nameof(DecisionLabel));
            OnPropertyChanged(nameof(DecisionStatusLine));
            OnPropertyChanged(nameof(ProposedLocalTime));
            OnPropertyChanged(nameof(ProposedCaptureTimeUtc));
        }

        _decisionChanged(this);
    }

    public DateDecision ToDecision()
    {
        if (!HasDecision)
        {
            throw new InvalidOperationException($"A date decision is still required for {Path}.");
        }

        if (IsConflict && IsApproved)
        {
            if (string.IsNullOrWhiteSpace(_chosenDate))
            {
                throw new InvalidOperationException($"Choose EXIF or filename for {Path}.");
            }

            return new DateDecision(Path, "manual", _chosenDate);
        }

        return new DateDecision(Path, IsApproved ? "approve" : "skip");
    }
}

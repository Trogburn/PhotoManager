using QnapPhotoManager.ViewModels;

namespace QnapPhotoManager.Services;

public static class DateReviewDecisionPolicy
{
    public static bool HasCompleteProposedDecisions(IEnumerable<DateReviewRowViewModel> items)
    {
        ArgumentNullException.ThrowIfNull(items);
        var proposed = items.Where(item => item.IsProposed).ToArray();
        return proposed.Length > 0 && proposed.All(item => item.HasDecision);
    }

    public static bool HasApprovedProposal(IEnumerable<DateReviewRowViewModel> items)
    {
        ArgumentNullException.ThrowIfNull(items);
        return items.Any(item => item.IsApproved);
    }

    public static bool CanCreateSnapshot(IEnumerable<DateReviewRowViewModel> items) =>
        HasCompleteProposedDecisions(items) && HasApprovedProposal(items);

    public static bool CanApply(
        bool snapshotConfirmed,
        object? snapshot,
        IEnumerable<DateReviewRowViewModel> items) =>
        snapshotConfirmed && snapshot is not null && CanCreateSnapshot(items);
}

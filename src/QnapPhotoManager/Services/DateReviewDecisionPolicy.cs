using QnapPhotoManager.ViewModels;

namespace QnapPhotoManager.Services;

public static class DateReviewDecisionPolicy
{
    public static bool HasCompleteProposedDecisions(IEnumerable<DateReviewRowViewModel> items)
    {
        ArgumentNullException.ThrowIfNull(items);
        var reviewable = items.Where(item => item.IsReviewable).ToArray();
        return reviewable.Length > 0 && reviewable.All(item => item.HasDecision);
    }

    public static bool HasApprovedProposal(IEnumerable<DateReviewRowViewModel> items)
    {
        ArgumentNullException.ThrowIfNull(items);
        return items.Any(item => item.IsApproved);
    }

    public static bool CanCreateSnapshot(IEnumerable<DateReviewRowViewModel> items) =>
        HasCompleteProposedDecisions(items) && HasApprovedProposal(items);

    public static bool IsSkipOnlyReviewComplete(IEnumerable<DateReviewRowViewModel> items) =>
        HasCompleteProposedDecisions(items) && !HasApprovedProposal(items);

    public static bool CanApply(
        bool snapshotConfirmed,
        object? snapshot,
        IEnumerable<DateReviewRowViewModel> items) =>
        snapshotConfirmed && snapshot is not null && CanCreateSnapshot(items);
}

namespace QnapPhotoManager.ViewModels;

internal sealed record RetainedDateDecision(
    string Decision,
    string? ChosenDate,
    string? ChosenSourceLabel);
